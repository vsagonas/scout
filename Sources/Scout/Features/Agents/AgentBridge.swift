import Foundation
import Network

/// Holds one hook request open until it can be answered. The hook (curl) waits on it.
final class HookResponder: @unchecked Sendable {
    private let lock = NSLock()
    private var sendBody: ((String) -> Void)?
    private var closed = false
    var onClose: (() -> Void)?

    init(send: @escaping (String) -> Void) { sendBody = send }

    /// Answer the hook (once). An empty body means "no decision": the agent asks in its terminal as usual.
    func respond(_ body: String) {
        let send: ((String) -> Void)? = lock.withLock { let s = sendBody; sendBody = nil; closed = true; return s }
        send?(body)
    }

    var isOpen: Bool { lock.withLock { !closed } }

    /// The other side hung up (the agent was answered in the terminal, or timed out).
    func peerClosed() {
        let was = lock.withLock { let c = closed; closed = true; sendBody = nil; return c }
        if !was { onClose?() }
    }
}

/// A tiny local HTTP server for the agent hooks: 127.0.0.1 only, one shared secret.
///
/// `POST /hook/<claude|codex>/<Event>`            progress event: answered at once with an empty body.
/// `POST /hook/<claude|codex>/PermissionRequest`  held until Allow / Deny (or hang-up); the body is the decision JSON.
/// `POST /hook/claude/PreToolUse/question`        held until the question is answered; the body is the answer JSON.
/// Every request carries the `x-scout-token` header (a random key kept in `<directory>/token`).
final class AgentBridge: @unchecked Sendable {
    static let tokenHeader = AgentHooks.tokenHeader

    let directory: URL
    let defaultPort: UInt16
    private(set) var port: UInt16 = 0
    private(set) var token: String
    /// True when the default port was busy and Scout listens on another one.
    private(set) var usingFallbackPort = false
    /// Why the bridge could not listen (nil while it runs or has not tried).
    private(set) var failure: String?
    private var listener: NWListener?
    private var starting = false
    private let queue = DispatchQueue(label: "scout.agents.bridge")
    private let lock = NSLock()
    /// Called on the bridge queue for every valid hook post: (agent, event named in the URL, mode, body, responder).
    var handler: (@Sendable (_ agent: AgentKind, _ event: String, _ mode: String, _ body: Data, _ responder: HookResponder) -> Void)?
    /// Scripted runs only: answers `GET /debug/status` (with the key) so a test can read the state of a build whose folder it cannot open.
    var debugStatus: (@Sendable () -> String)?
    /// Called on the main queue when the bridge starts, falls back to another port, fails or stops.
    var onChange: (@Sendable () -> Void)?

    /// `fixedToken` (scripted runs only, `--agents-token <key>`) lets a test that cannot read the app's folder
    /// (a sandboxed build) know the key; real runs always use the random key kept in `<directory>/token`.
    init(directory: URL, defaultPort: UInt16 = AgentHooks.defaultPort, fixedToken: String? = nil) {
        self.directory = directory
        self.defaultPort = defaultPort
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let fixedToken, fixedToken.count >= 16 { token = fixedToken; return }
        let tokenFile = directory.appendingPathComponent("token")
        if let saved = try? String(contentsOf: tokenFile, encoding: .utf8), saved.trimmingCharacters(in: .whitespacesAndNewlines).count >= 16 {
            token = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            try? token.write(to: tokenFile, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        }
    }

    var isRunning: Bool { lock.withLock { port != 0 } }

    /// The port a snippet should name right now: the live port, or the one Scout will try first.
    var advertisedPort: UInt16 { lock.withLock { port != 0 ? port : defaultPort } }

    private var savedPort: UInt16 {
        UInt16((try? String(contentsOf: directory.appendingPathComponent("port"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    /// Starts listening: the default port first, then the port used last time (so a pasted config stays valid), then any free one.
    func start() {
        let proceed = lock.withLock { () -> Bool in
            guard listener == nil, !starting else { return false }
            starting = true
            failure = nil
            return true
        }
        guard proceed else { return }
        // defaultPort 0 means "any free port" (tests).
        var candidates: [UInt16] = defaultPort == 0 ? [] : [defaultPort]
        let saved = savedPort
        if saved > 1024, saved != defaultPort { candidates.append(saved) }
        candidates.append(0)
        attempt(candidates, index: 0)
    }

    private func attempt(_ candidates: [UInt16], index: Int) {
        guard index < candidates.count else {
            lock.withLock { starting = false; failure = failure ?? String(localized: "Scout could not open a local port.") }
            notify()
            return
        }
        let wanted = candidates[index]
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.requiredInterfaceType = .loopback
        let nwPort = wanted == 0 ? NWEndpoint.Port.any : (NWEndpoint.Port(rawValue: wanted) ?? .any)
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        guard let l = try? NWListener(using: params) else { attempt(candidates, index: index + 1); return }
        let done = OnceFlag()
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l else { return }
            switch state {
            case .ready:
                guard done.take(), let p = l.port?.rawValue else { return }
                self.lock.withLock {
                    self.port = p
                    self.starting = false
                    self.usingFallbackPort = self.defaultPort != 0 && p != self.defaultPort
                    self.failure = nil
                }
                try? String(p).write(to: self.directory.appendingPathComponent("port"), atomically: true, encoding: .utf8)
                self.notify()
            case .failed(let error):
                guard done.take() else { return }
                l.cancel()
                self.lock.withLock { self.failure = "\(error)"; self.listener = nil }
                self.attempt(candidates, index: index + 1)
            case .waiting(let error):
                // Sandbox without the server entitlement, or the address is taken: try the next candidate.
                guard done.take() else { return }
                l.cancel()
                self.lock.withLock { self.failure = "\(error)"; self.listener = nil }
                self.attempt(candidates, index: index + 1)
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        lock.withLock { listener = l }
        l.start(queue: queue)
    }

    func stop() {
        let l = lock.withLock { let x = listener; listener = nil; port = 0; starting = false; usingFallbackPort = false; return x }
        l?.cancel()
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("port"))
        notify()
    }

    private func notify() {
        guard let onChange else { return }
        DispatchQueue.main.async { onChange() }
    }

    /// Lets only the first state change act on a listener.
    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func take() -> Bool { lock.withLock { let was = taken; taken = true; return !was } }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data(), sentContinue: false)
    }

    private func read(_ connection: NWConnection, buffer: Data, sentContinue: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            var continued = sentContinue
            if let request = HTTPRequest.parse(buf) {
                self.route(request, connection)
            } else if isComplete || error != nil || buf.count > 16_000_000 {
                connection.cancel()
            } else {
                // curl may wait for "100 Continue" before it sends a large body.
                if !continued, HTTPRequest.expectsContinue(buf) {
                    continued = true
                    connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                }
                self.read(connection, buffer: buf, sentContinue: continued)
            }
        }
    }

    private func route(_ request: HTTPRequest, _ connection: NWConnection) {
        func reply(_ status: Int, _ body: String) {
            let text = status == 200 ? "OK" : (status == 401 ? "Unauthorized" : "Not Found")
            let head = "HTTP/1.1 \(status) \(text)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data((head + body).utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        }
        guard request.headers[Self.tokenHeader] == token else { reply(401, ""); return }
        if request.path == "/ping" { reply(200, "scout"); return }
        if request.method == "GET", request.path == "/debug/status", let debugStatus { reply(200, debugStatus()); return }
        let parts = request.path.split(separator: "/").map(String.init)
        guard request.method == "POST", parts.count >= 3, parts[0] == "hook", let agent = AgentKind(rawValue: parts[1]) else { reply(404, ""); return }
        let event = parts[2]
        let mode = event == "PermissionRequest" ? "permission" : (parts.count > 3 && parts[3] == "question" ? "question" : "")
        guard mode.isEmpty else {
            // A waiting hook: hold the line until the notch answers (or the hook hangs up).
            let responder = HookResponder { body in reply(200, body) }
            handler?(agent, event, mode, request.body, responder)
            watchPeer(connection, responder)
            return
        }
        // A progress event: answer at once so the agent never waits on Scout's main thread.
        reply(200, "")
        handler?(agent, event, mode, request.body, HookResponder { _ in })
    }

    private func watchPeer(_ connection: NWConnection, _ responder: HookResponder) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil { responder.peerClosed() } else { self?.watchPeer(connection, responder) }
        }
    }
}

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    /// True when the headers are in and ask for "100 Continue" before the body.
    static func expectsContinue(_ data: Data) -> Bool {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: data[data.startIndex..<split.lowerBound], as: UTF8.self).lowercased()
        return head.contains("\r\nexpect: 100-continue")
    }

    /// Parses a complete request (headers and the whole body), or nil when more bytes are needed.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<split.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = split.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let body = data[bodyStart..<(bodyStart + length)]
        let target = String(first[1])
        let comps = URLComponents(string: "http://x" + target)
        var query: [String: String] = [:]
        comps?.queryItems?.forEach { query[$0.name] = $0.value ?? "" }
        return HTTPRequest(method: String(first[0]), path: comps?.path ?? target, query: query, headers: headers, body: Data(body))
    }
}
