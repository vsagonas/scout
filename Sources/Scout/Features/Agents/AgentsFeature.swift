import SwiftUI

@MainActor
enum AgentsFeature {
    /// Adds Agents to a SAVED workspace list that lacks it (a list saved while the App Store edition hid Agents).
    /// Nothing saved = everything is on. Edits the saved text itself, so workspaces another edition leaves out stay in it.
    static func enableInNotch() {
        let raw = Pref.string("notch.workspaces", "")
        var parts = raw.split(separator: ",").map(String.init)
        guard parts.contains(where: { WorkspaceKind(rawValue: $0) != nil }), !parts.contains(WorkspaceKind.agents.rawValue) else { return }
        parts.append(WorkspaceKind.agents.rawValue)
        Pref.set(parts.joined(separator: ","), "notch.workspaces")
    }

    /// Once: a list saved before the App Store edition had Agents gets it, so the owner finds it in the notch.
    /// Switching it off later sticks.
    private static func addToSavedWorkspaceListOnce() {
        let flag = "agents.notch.listMigrated"
        guard !Pref.bool(flag, false) else { return }
        Pref.set(true, flag)
        enableInNotch()
    }

    /// Once: a Nook layout saved before the agents dashboard existed gets it, first, so the owner finds it. Removing it later sticks.
    private static func addToSavedNookOnce() {
        let flag = "agents.nook.migrated"
        guard !Pref.bool(flag, false) else { return }
        Pref.set(true, flag)
        guard UserDefaults.standard.stringArray(forKey: "nook.layout") != nil else { return }   // nothing saved: the default layout has it
        NookStore.shared.add(.agents, at: 0)
    }

    static func start() {
        addToSavedWorkspaceListOnce()
        addToSavedNookOnce()
        startCore()
        AgentsAutoOpen.shared.start()   // the notch opens by itself when an agent needs you, comes back after a long task or fails
    }

    /// `--headless`: the store, the scanner, the bridge and the debug commands, and nothing on screen.
    static func startHeadless() { startCore() }

    private static func startCore() {
        AgentsStore.shared.start()
        // Debug commands exist in scripted runs only (never in the shipped app): a `scout://` link must not be
        // able to answer a permission request.
        guard ScoutRuntime.isAutomation else { return }
        // scout://agents.demo shows sample sessions, a permission card and the activity.
        DebugCommands.register("agents.demo") { _ in
            let store = AgentsStore.shared
            store.loadSamples()
            if let p = store.pending.first {
                LiveActivityCenter.shared.present(NotchCard(id: "agent.pending.\(p.id)", kind: .agent, duration: 30, onTap: { NotchNavigator.shared.open(.agents) }) {
                    PendingView(request: p, store: store, compact: true)
                })
            }
            store.refreshActivity()
            NotchNavigator.shared.open(.agents)
        }
        // Automation only, read only: what the transcript reader sees in a folder (default the real ~/.claude/projects) on a FIRST look, as
        // Scout does when it starts. Short ids and states, never the content (the owner's chats stay private).
        DebugCommands.register("agents.probe") { params in
            guard ScoutRuntime.isAutomation, let out = params["out"] else { return }
            let root = params["root"].map { URL(fileURLWithPath: $0) } ?? AgentAccess.defaultRoot(for: .claude)
            let scanner = AgentScanner()
            scanner.setSources([.init(agent: .claude, root: root)])
            let open = AgentScanner.openChats(registry: root.deletingLastPathComponent().appendingPathComponent("sessions"))
            let lines = scanner.scanNow().map { "\($0.id.prefix(8)) \($0.state) open=\(open[$0.id] != nil) quiet=\(Int(Date().timeIntervalSince($0.lastEventAt)))s" }
            let head = "open chats in the registry: " + open.keys.map { String($0.prefix(8)) }.sorted().joined(separator: " ")
            try? ([head] + lines).joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
        DebugCommands.register("agents.open") { _ in NotchNavigator.shared.open(.agents) }
        DebugCommands.register("agents.clear") { _ in AgentsStore.shared.clearSamples(); AgentsStore.shared.refreshActivity() }
        // scout://agents.status?out=<file> writes the bridge port, sessions, pending requests and the last hook calls as JSON.
        // With `log=1` the same JSON (one line) goes to the system log instead: a sandboxed build can't write where a shell can read.
        DebugCommands.register("agents.status") { params in
            let object = AgentsStore.shared.statusObject()
            if params["log"] != nil {
                if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) { NSLog("Scout agents.status %@", String(decoding: data, as: UTF8.self)) }
                return
            }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("agents-status.json")
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: out) }
        }
        // scout://agents.decide?index=0&decision=allow|always|deny|ask|answer[&text=…] answers the pending request at `index`.
        DebugCommands.register("agents.decide") { params in
            let ok = AgentsStore.shared.debugDecide(index: Int(params["index"] ?? "0") ?? 0, decision: params["decision"] ?? "allow", text: params["text"])
            NSLog("Scout agents.decide \(params["decision"] ?? "allow"): \(ok ? "answered" : "nothing pending")")
        }
        // scout://agents.snippet?agent=claude|codex&out=<file> writes the hooks block the App Store edition shows.
        DebugCommands.register("agents.snippet") { params in
            let agent = AgentKind(rawValue: params["agent"] ?? "claude") ?? .claude
            let text = AgentsStore.shared.snippet(agent)
            if params["log"] != nil {
                let flat = (try? JSONSerialization.jsonObject(with: Data(text.utf8))).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes]) }
                NSLog("Scout agents.snippet %@", flat.map { String(decoding: $0, as: UTF8.self) } ?? "")
                return
            }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("agents-snippet.json")
            try? text.write(to: out, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Self-tests (a TEMPORARY base folder only: never the real ~/.claude or ~/.codex)

    private static func sandbox(_ name: String) -> URL {
        let url = AppPaths.folder("SelfTest").appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    nonisolated private static func spin(until condition: () -> Bool, timeout: TimeInterval = 8) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03)) }
        return condition()
    }

    final class ReplyLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }

    static func registerSelfTests() {
        registerProtocolTests()
        registerStoreTests()
        registerScannerTests()
        registerDashboardTests()
        #if !APPSTORE
        registerInstallerTests()
        registerBridgeTests()
        #endif
    }

    // MARK: Both editions

    private static func registerProtocolTests() {
        FeaturesSelfTest.add("agents: the hooks block is valid JSON, one inline command per event, fail-open shaped") {
            let port: UInt16 = 47231, token = "0123456789abcdef0123456789abcdef"
            for agent in AgentKind.allCases {
                let text = AgentHooks.snippet(agent, port: port, token: token)
                guard let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], let hooks = json["hooks"] as? [String: [[String: Any]]] else { print("  \(agent) block is not JSON"); return false }
                let commands = hooks.values.flatMap { $0 }.flatMap { ($0["hooks"] as? [[String: Any]] ?? []) }.compactMap { $0["command"] as? String }
                guard commands.count == AgentHooks.entries(for: agent).count, !text.contains("scout-hook") else { print("  \(agent): \(commands.count) commands"); return false }
                for entry in AgentHooks.entries(for: agent) {
                    let c = AgentHooks.command(agent, entry, port: port, token: token)
                    guard c.contains("http://127.0.0.1:\(port)/hook/\(agent.rawValue)/\(entry.path)"), c.contains("x-scout-token: \(token)"), c.hasPrefix("/usr/bin/curl") else { print("  bad command \(c)"); return false }
                    if entry.waits {
                        guard c.hasSuffix("exit 0"), c.contains("grep -m1 '^{'"), c.contains("-m \(AgentHooks.waitSeconds)"), entry.timeout == 600 else { print("  waiting command shape: \(c)"); return false }
                    } else {
                        guard c.hasSuffix(">/dev/null 2>&1 || true"), c.contains("-m 2") || c.contains("-m 1") else { print("  fire command shape: \(c)"); return false }
                    }
                    guard AgentHooks.isScouts(command: c), AgentHooks.port(inCommand: c) == port else { return false }
                }
            }
            // Claude Code: the permission event and the AskUserQuestion matcher are there.
            let claude = AgentHooks.entries(for: .claude)
            return claude.contains { $0.event == "PermissionRequest" && $0.waits } && claude.contains { $0.event == "PreToolUse" && $0.matcher == "AskUserQuestion" && $0.mode == "question" }
        }
        FeaturesSelfTest.add("agents: tool summaries, TodoWrite, suggestions, the HTTP parser and the decision JSON") {
            guard AgentEvent.summary(tool: "Edit", input: ["file_path": "/a/b/Converter.swift"]) == "Converter.swift",
                  AgentEvent.summary(tool: "Bash", input: ["command": "swift build\n-c release"]) == "swift build -c release",
                  AgentEvent.summary(tool: "Grep", input: ["pattern": "TODO"]) == "TODO" else { return false }
            let todo = "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"a\",\"tool_name\":\"TodoWrite\",\"tool_input\":{\"todos\":[{\"content\":\"A\",\"status\":\"completed\",\"activeForm\":\"Doing A\"},{\"content\":\"B\",\"status\":\"in_progress\",\"activeForm\":\"Doing B\"},{\"content\":\"C\",\"status\":\"pending\",\"activeForm\":\"Doing C\"}]}}"
            guard let e = AgentEvent.parse(agent: .claude, data: Data(todo.utf8)), e.todos?.count == 3, e.todos?[1].status == .inProgress, e.todos?[1].active == "Doing B" else { print("  todos"); return false }
            guard let named = AgentEvent.parse(agent: .codex, data: Data("{\"session_id\":\"a\"}".utf8), fallbackName: "Stop"), named.name == "Stop",
                  AgentEvent.parse(agent: .codex, data: Data("{\"session_id\":\"a\"}".utf8)) == nil else { print("  fallback name"); return false }
            let perm = "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"a\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf node_modules\"},\"permission_suggestions\":[{\"type\":\"addRules\",\"rules\":[{\"toolName\":\"Bash\",\"ruleContent\":\"rm -rf node_modules\"}],\"behavior\":\"allow\",\"destination\":\"localSettings\"}]}"
            guard let p = AgentEvent.parse(agent: .claude, data: Data(perm.utf8)), p.permissionSuggestions != nil else { print("  suggestions"); return false }
            let request = AgentPending(sessionID: "a", kind: .permission, tool: "Bash", summary: "", detail: "", questions: [], rawToolInput: nil, agent: .claude, permissionSuggestions: p.permissionSuggestions)
            guard let always = request.alwaysAllow, always.label == "Bash(rm -rf node_modules)" else { print("  always label"); return false }
            let body = AgentsStore.permissionBody(allow: true, updates: always.updates)
            guard body.contains("\"updatedPermissions\":[{"), body.contains("\"behavior\":\"allow\""), body.contains("\"destination\":\"localSettings\""), body.contains("\"hookEventName\":\"PermissionRequest\"") else { print("  always body \(body)"); return false }
            var codex = request; codex.agent = .codex
            guard codex.alwaysAllow == nil else { return false }
            guard AgentsStore.permissionBody(allow: true) == "{\"hookSpecificOutput\":{\"decision\":{\"behavior\":\"allow\"},\"hookEventName\":\"PermissionRequest\"}}" else { print("  allow body \(AgentsStore.permissionBody(allow: true))"); return false }
            let raw = "POST /hook/codex/PermissionRequest HTTP/1.1\r\nHost: x\r\nX-Scout-Token: abc\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\nhello"
            guard HTTPRequest.expectsContinue(Data("POST /hook/x HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 9\r\n\r\n".utf8)),
                  let r = HTTPRequest.parse(Data(raw.utf8)), r.method == "POST", r.path == "/hook/codex/PermissionRequest",
                  r.headers["x-scout-token"] == "abc", String(decoding: r.body, as: UTF8.self) == "hello" else { return false }
            return HTTPRequest.parse(Data("POST /hook HTTP/1.1\r\nContent-Length: 10\r\n\r\nshort".utf8)) == nil
        }
    }

    // MARK: The scanner (synthetic transcripts only)

    nonisolated private static func jsonLine(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    /// A tiny Claude Code transcript writer for the tests.
    private final class SyntheticClaude {
        let url: URL
        let id: String
        let cwd: String
        private var n = 0
        /// When set, every line is stamped with this moment (a test that needs real gaps between lines).
        var clock: Date?
        init(root: URL, project: String, cwd: String, id: String = UUID().uuidString.lowercased()) {
            self.id = id
            self.cwd = cwd
            let dir = root.appendingPathComponent(project, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent(id + ".jsonl")
        }
        func append(_ text: String) {
            if let handle = try? FileHandle(forWritingTo: url) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(text.utf8)) }
            else { try? text.write(to: url, atomically: true, encoding: .utf8) }
        }
        private func base(_ type: String) -> [String: Any] {
            n += 1
            let stamp = clock.map { TranscriptState.isoFractional.string(from: $0) } ?? "2026-11-15T10:00:\(String(format: "%02d", n % 60)).000Z"
            return ["type": type, "sessionId": id, "cwd": cwd, "isSidechain": false, "uuid": "u\(n)", "timestamp": stamp]
        }
        func prompt(_ text: String) { var o = base("user"); o["message"] = ["role": "user", "content": text]; append(AgentsFeature.jsonLine(o) + "\n") }
        func tool(_ id: String, _ name: String, _ input: [String: Any], text: String? = nil) {
            var o = base("assistant")
            var blocks: [[String: Any]] = []
            if let text { blocks.append(["type": "text", "text": text]) }
            blocks.append(["type": "tool_use", "id": id, "name": name, "input": input])
            o["message"] = ["role": "assistant", "content": blocks, "stop_reason": "tool_use"]
            append(AgentsFeature.jsonLine(o) + "\n")
        }
        func result(_ id: String, error: Bool = false) {
            var o = base("user")
            o["message"] = ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "ok", "is_error": error]]]
            append(AgentsFeature.jsonLine(o) + "\n")
        }
        func finish(_ text: String) {
            var o = base("assistant")
            o["message"] = ["role": "assistant", "content": [["type": "text", "text": text]], "stop_reason": "end_turn"]
            append(AgentsFeature.jsonLine(o) + "\n")
        }
        func raw(_ type: String, _ extra: [String: Any]) { var o = base(type); for (k, v) in extra { o[k] = v }; append(AgentsFeature.jsonLine(o) + "\n") }
    }

    private static func registerScannerTests() {
        FeaturesSelfTest.add("agents scan: a Claude transcript becomes a session (prompt, tool running, to-dos, helpers, question, interrupt, turn end, idle, drop-off)") {
            let root = sandbox("scan-claude")
            let scanner = AgentScanner()
            scanner.setSources([.init(agent: .claude, root: root), .init(agent: .codex, root: root.appendingPathComponent("none"))])
            let t = SyntheticClaude(root: root, project: "-Users-me-Dev-site", cwd: "/Users/me/Dev/site")
            t.raw("ai-title", ["aiTitle": "Fix the footer"])
            t.prompt("Fix the footer links")
            t.tool("t1", "Bash", ["command": "swift build -c release"], text: "Building first.")
            var now = Date()
            guard var s = scanner.scanNow(now: now).first, s.id == t.id, s.agent == .claude, s.scanned else { print("  no session"); return false }
            guard s.project == "site", s.title == "Fix the footer links", s.state == .working, s.currentStep?.tool == "Bash", s.currentStep?.summary == "swift build -c release" else {
                print("  first look: \(s.project) \(s.title) \(s.state) \(String(describing: s.currentStep))"); return false }
            // To-dos and a helper agent.
            t.tool("t2", "TodoWrite", ["todos": [["content": "A", "status": "completed", "activeForm": "Doing A"], ["content": "B", "status": "in_progress", "activeForm": "Doing B"], ["content": "C", "status": "pending", "activeForm": "Doing C"]]])
            t.result("t2")
            t.tool("t3", "Agent", ["description": "Explore the tray code", "subagent_type": "Explore"])
            s = scanner.scanNow(now: now).first ?? s
            guard s.todos.count == 3, s.todosDone == 1, s.currentTodo == "Doing B", s.subagents == 1, s.currentStep?.tool == "Agent" else { print("  todos/helpers: \(s.todos.count) \(s.subagents) \(String(describing: s.currentStep))"); return false }
            t.result("t3"); t.result("t1")
            s = scanner.scanNow(now: now).first ?? s
            guard s.subagents == 0, s.currentStep == nil, s.steps.filter({ $0.tool == "Bash" }).first?.done == true else { print("  results"); return false }
            // A helper started in the background stays on the floor after its "launched" result, until its task notification says it is done.
            t.tool("b1", "Agent", ["description": "Audit the store text", "subagent_type": "general-purpose", "run_in_background": true])
            t.result("b1")
            s = scanner.scanNow(now: now).first ?? s
            guard s.subagents == 1 else { print("  background helper after its launch: \(s.subagents)"); return false }
            t.prompt("<task-notification>\n<task-id>x1</task-id>\n<tool-use-id>b1</tool-use-id>\n<status>completed</status>\n</task-notification>")
            s = scanner.scanNow(now: now).first ?? s
            guard s.subagents == 0, s.title == "Fix the footer links" else { print("  background helper after its notification: \(s.subagents) \(s.title)"); return false }
            // A question waiting for you.
            t.tool("q1", "AskUserQuestion", ["questions": [["question": "Which framework?", "header": "F", "options": [["label": "React", "description": ""]], "multiSelect": false]]])
            s = scanner.scanNow(now: now).first ?? s
            guard s.state == .waiting, s.note == "Asking you: Which framework?" else { print("  question: \(s.state) \(s.note)"); return false }
            t.result("q1")
            s = scanner.scanNow(now: now).first ?? s
            guard s.state == .working else { print("  answered question: \(s.state)"); return false }
            // A half-written line is not read until it is complete.
            let half = jsonLine(["type": "assistant", "cwd": "/Users/me/Dev/site", "message": ["role": "assistant", "content": [["type": "text", "text": "Done."]], "stop_reason": "end_turn"]])
            t.append(String(half.prefix(half.count / 2)))
            guard scanner.scanNow(now: now).first?.state == .working else { print("  half line"); return false }
            t.append(String(half.dropFirst(half.count / 2)) + "\n")
            s = scanner.scanNow(now: now).first ?? s
            guard s.state == .waiting, s.note.hasPrefix("Finished"), s.lastMessage == "Done.", s.finishedAt != nil else { print("  turn end: \(s.state) \(s.note)"); return false }
            // After a while it is done, and when its file is old it drops off.
            now = Date().addingTimeInterval(150)
            guard scanner.scanNow(now: now).first?.state == .done else { print("  not done"); return false }
            guard scanner.scanNow(now: Date().addingTimeInterval(700)).isEmpty else { print("  did not drop off"); return false }
            // An interrupted turn (Esc, or Enter with a new message) is NOT a finish: idle, with no "your move" message (the owner, 2026-11-18).
            let t2 = SyntheticClaude(root: root, project: "-Users-me-Dev-notes", cwd: "/Users/me/Dev/notes")
            t2.prompt("Summarise"); t2.tool("a", "Read", ["file_path": "/x/research.md"])
            guard scanner.scanNow().first(where: { $0.id == t2.id })?.state == .working else { return false }
            t2.prompt("[Request interrupted by user for tool use]")
            guard let interrupted = scanner.scanNow().first(where: { $0.id == t2.id }), interrupted.state == .idle, interrupted.title == "Summarise" else { print("  interrupt"); return false }
            let interruptedWing = AgentWingSummary.make(sessions: [interrupted], pending: [])
            guard interruptedWing.right == .none else { print("  an interrupted turn put \(interruptedWing.right) beside the notch"); return false }
            // Meta lines and command wrappers are not prompts; a slash command is.
            t2.raw("user", ["isMeta": true, "message": ["role": "user", "content": "Caveat: generated by tools"]])
            t2.prompt("<local-command-stdout>output</local-command-stdout>")
            t2.prompt("<command-name>/review</command-name><command-args>the diff</command-args>")
            guard scanner.scanNow().first(where: { $0.id == t2.id })?.title == "/review the diff" else { print("  command prompt"); return false }
            return true
        }
        FeaturesSelfTest.add("agents scan: an OPEN chat (Claude Code's sessions registry) shows from the first look however long it has been quiet; a closed one leaves") {
            let base = sandbox("scan-open")
            let root = base.appendingPathComponent("projects"), registry = base.appendingPathComponent("sessions")
            try? FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
            let hoursAgo = Date().addingTimeInterval(-3 * 3600)
            let open = SyntheticClaude(root: root, project: "-Users-me-Dev-open", cwd: "/Users/me/Dev/open")
            open.clock = hoursAgo; open.prompt("Long ago"); open.finish("Done long ago.")
            let closed = SyntheticClaude(root: root, project: "-Users-me-Dev-closed", cwd: "/Users/me/Dev/closed")
            closed.clock = hoursAgo; closed.prompt("Also long ago"); closed.finish("Done.")
            for u in [open.url, closed.url] { try? FileManager.default.setAttributes([.modificationDate: hoursAgo], ofItemAtPath: u.path) }
            // The open chat's process is this run itself (it runs); the closed chat left a stale file whose process does not run.
            let mine = AgentsFeature.jsonLine(["pid": Int(getpid()), "sessionId": open.id, "status": "idle", "cwd": "/Users/me/Dev/open"])
            let stale = AgentsFeature.jsonLine(["pid": 999_999, "sessionId": closed.id, "status": "idle", "cwd": "/Users/me/Dev/closed"])
            try? mine.write(to: registry.appendingPathComponent("\(getpid()).json"), atomically: true, encoding: .utf8)
            try? stale.write(to: registry.appendingPathComponent("999999.json"), atomically: true, encoding: .utf8)
            let chats = AgentScanner.openChats(registry: registry)
            guard chats.keys.sorted() == [open.id] else { print("  open chats: \(chats.keys.sorted())"); return false }
            let scanner = AgentScanner()   // a fresh scanner: Scout has just started
            scanner.setSources([.init(agent: .claude, root: root)])
            let first = scanner.scanNow()
            guard first.map(\.id) == [open.id] else { print("  first look: \(first.map(\.id)) (open \(open.id))"); return false }
            // A busy chat whose transcript has been quiet for 20 minutes (a long build): working, not stuck (the owner, 2026-11-19).
            let longRun = SyntheticClaude(root: root, project: "-Users-me-Dev-build", cwd: "/Users/me/Dev/build")
            let twentyAgo = Date().addingTimeInterval(-20 * 60)
            longRun.clock = twentyAgo; longRun.prompt("Build the release"); longRun.tool("b1", "Bash", ["command": "make release"])
            try? FileManager.default.setAttributes([.modificationDate: twentyAgo], ofItemAtPath: longRun.url.path)
            let busy = AgentsFeature.jsonLine(["pid": Int(getpid()), "sessionId": longRun.id, "status": "busy", "cwd": "/Users/me/Dev/build"])
            try? busy.write(to: registry.appendingPathComponent("busy-\(getpid()).json"), atomically: true, encoding: .utf8)
            let withBusy = scanner.scanNow()
            guard withBusy.first(where: { $0.id == longRun.id })?.state == .working else { print("  a busy chat quiet for 20 min: \(String(describing: withBusy.first(where: { $0.id == longRun.id })?.state))"); return false }
            try? FileManager.default.removeItem(at: registry.appendingPathComponent("busy-\(getpid()).json"))
            // The chat is closed (its registry file goes): it leaves.
            try? FileManager.default.removeItem(at: registry.appendingPathComponent("\(getpid()).json"))
            guard scanner.scanNow().isEmpty else { print("  a closed chat stayed"); return false }
            return true
        }
        FeaturesSelfTest.add("agents scan: only the tail of a big file is read first, then only what is appended; a replaced file starts over") {
            let root = sandbox("scan-claude-big")
            let t = SyntheticClaude(root: root, project: "p", cwd: "/Users/me/Dev/big")
            let filler = String(repeating: "x", count: 900)
            var blob = ""
            for i in 0..<4200 { blob += "{\"type\":\"api-request-blob\",\"i\":\(i),\"x\":\"\(filler)\"}\n" }   // about 3.8 MB the scanner skips
            t.append(blob)
            t.prompt("The big one")
            t.tool("b1", "Grep", ["pattern": "TODO"])
            let scanner = AgentScanner()
            scanner.setSources([.init(agent: .claude, root: root)])
            guard let s = scanner.scanNow().first, s.title == "The big one", s.currentStep?.summary == "TODO" else { print("  big file tail"); return false }
            try? FileManager.default.removeItem(at: t.url)
            t.append("")
            t.prompt("Fresh start")
            guard let again = scanner.scanNow().first, again.title == "Fresh start", again.steps.count == 1 else { print("  replaced: \(scanner.scanNow().first?.title ?? "-")"); return false }
            return true
        }
        FeaturesSelfTest.add("agents scan: a Codex rollout becomes a session (cwd, prompt, command running, plan, finished turn)") {
            let root = sandbox("scan-codex")
            // TODAY's day folder and time: the scanner reads only the folders of the last day or so, so a fixed date made this check fail from the third day on (2026-11-17)
            let today = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            let ymd = String(format: "%04d-%02d-%02d", today.year ?? 2026, today.month ?? 1, today.day ?? 1)
            let utc = DateFormatter()
            utc.locale = Locale(identifier: "en_US_POSIX")
            utc.timeZone = TimeZone(identifier: "UTC")
            utc.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.000'Z'"
            let stamp = utc.string(from: Date())
            let day = root.appendingPathComponent(ymd.replacingOccurrences(of: "-", with: "/"), isDirectory: true)
            try? FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
            let uuid = "0199aaaa-bbbb-cccc-dddd-eeeeffff0001"
            let url = day.appendingPathComponent("rollout-\(ymd)T10-00-00-\(uuid).jsonl")
            func write(_ type: String, _ payload: [String: Any]) {
                let l = jsonLine(["timestamp": stamp, "type": type, "payload": payload]) + "\n"
                if let h = try? FileHandle(forWritingTo: url) { defer { try? h.close() }; _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(l.utf8)) } else { try? l.write(to: url, atomically: true, encoding: .utf8) }
            }
            write("session_meta", ["id": uuid, "cwd": "/Users/me/Dev/api", "originator": "codex_cli_rs", "timestamp": stamp])
            write("event_msg", ["type": "task_started"])
            write("event_msg", ["type": "user_message", "message": "Add the health endpoint"])
            write("event_msg", ["type": "plan_update", "plan": [["step": "Read the router", "status": "completed"], ["step": "Add the route", "status": "in_progress"]]])
            write("response_item", ["type": "function_call", "name": "shell", "arguments": "{\"command\":[\"bash\",\"-lc\",\"cargo test\"]}", "call_id": "c1"])
            let scanner = AgentScanner()
            scanner.setSources([.init(agent: .codex, root: root)])
            guard var s = scanner.scanNow().first, s.id == uuid, s.agent == .codex, s.project == "api", s.title == "Add the health endpoint", s.state == .working,
                  s.currentStep?.tool == "Bash", s.currentStep?.summary == "cargo test", s.todos.count == 2, s.currentTodo == "Add the route" else { print("  codex: \(scanner.scanNow().map { "\($0.id) \($0.state) \($0.title)" })"); return false }
            write("response_item", ["type": "function_call_output", "call_id": "c1", "output": "ok"])
            write("event_msg", ["type": "task_complete", "last_agent_message": "The endpoint is in."])
            s = scanner.scanNow().first ?? s
            return s.state == .waiting && s.lastMessage == "The endpoint is in." && s.currentStep == nil
        }
        FeaturesSelfTest.add("agents scan: the store merges a scanned session with its hook session, keeps held requests, and drops what vanished") {
            let store = AgentsStore(directory: sandbox("agents-scan-store"))
            let replies = ReplyLog()
            @MainActor func hook(_ json: String, mode: String = "") {
                let r = HookResponder { replies.add($0) }
                if let e = AgentEvent.parse(agent: .claude, data: Data(json.utf8)) { store.receive(e, mode: mode, responder: r) }
            }
            var scan = AgentSession(id: "m1", agent: .claude, cwd: "/Users/me/Dev/merge")
            scan.title = "From the transcript"; scan.state = .working; scan.scanned = true
            scan.todos = [AgentTodo(text: "A", active: "Doing A", status: .inProgress)]
            scan.steps = [AgentStep(id: "t1", tool: "Bash", summary: "make", at: Date(), done: false)]
            store.applyScan([scan], status: AgentScanner.Status())
            guard store.sessions.count == 1, store.sessions[0].scanned, store.sessions[0].state == .working else { print("  not added"); return false }
            // A permission arrives over the hook for the same session id: ONE session, waiting, request held.
            hook("{\"session_id\":\"m1\",\"cwd\":\"/Users/me/Dev/merge\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"make\"}}", mode: "permission")
            guard store.sessions.count == 1, store.pending.count == 1, store.sessions[0].state == .waiting, store.sessions[0].scanned, store.sessions[0].lastHookAt != nil else { print("  hook merge: \(store.sessions.count)"); return false }
            store.applyScan([scan], status: AgentScanner.Status())   // the transcript still says working: the held request wins
            guard store.sessions[0].state == .waiting, store.sessions[0].title == "From the transcript", store.sessions[0].todos.count == 1 else { print("  held request lost"); return false }
            store.decide(store.pending[0].id, .allow)
            guard store.sessions.count == 1, replies.all.last == AgentsStore.permissionBody(allow: true) else { return false }
            // Gone from the scan: the session goes (it was only ever scanned or hooked-and-scanned, and nothing is held).
            store.applyScan([], status: AgentScanner.Status())
            guard store.sessions.isEmpty else { print("  vanished session stayed"); return false }
            // A hook-only session is not touched by scans; one the hooks ended stays gone until its file changes again.
            hook("{\"session_id\":\"h1\",\"cwd\":\"/Users/me/Dev/hookonly\",\"hook_event_name\":\"SessionStart\"}")
            store.applyScan([], status: AgentScanner.Status())
            guard store.sessions.map(\.id) == ["h1"] else { return false }
            var ended = scan; ended.id = "e1"; ended.lastEventAt = Date().addingTimeInterval(-30)
            hook("{\"session_id\":\"e1\",\"hook_event_name\":\"SessionEnd\"}")
            store.applyScan([ended], status: AgentScanner.Status())
            guard !store.sessions.contains(where: { $0.id == "e1" }) else { print("  ended session came back"); return false }
            ended.lastEventAt = Date().addingTimeInterval(5)
            store.applyScan([ended], status: AgentScanner.Status())
            return store.sessions.contains { $0.id == "e1" }
        }
        FeaturesSelfTest.add("agents scan: a file created after the scanner started is found by itself (FSEvents or the sweep)") {
            let root = sandbox("scan-claude-live")
            try? FileManager.default.createDirectory(at: root.appendingPathComponent("p"), withIntermediateDirectories: true)
            let box = ReplyLog()
            let scanner = AgentScanner(interval: 0.5)
            scanner.callbackQueue = DispatchQueue(label: "scout.test.scan")
            scanner.onChange = { sessions, _ in box.add(sessions.map { "\($0.project):\($0.state.title)" }.joined(separator: ",")) }
            scanner.setSources([.init(agent: .claude, root: root)])
            scanner.start()
            defer { scanner.stop() }
            _ = spin(until: { false }, timeout: 0.6)
            let t = SyntheticClaude(root: root, project: "p", cwd: "/Users/me/Dev/live")
            t.prompt("Live one")
            t.tool("l1", "Edit", ["file_path": "/x/y/Live.swift"])
            guard spin(until: { box.all.contains("live:Working") }, timeout: 9) else { print("  not found: \(box.all)"); return false }
            t.finish("Finished.")
            guard spin(until: { box.all.last == "live:Needs you" }, timeout: 4) else { print("  turn end not seen: \(box.all.suffix(2))"); return false }
            return true
        }
        FeaturesSelfTest.add("agents scan: a helper's transcript (under <session>/subagents) is never an agent: not by the first sweep, a file event or the slow sweep") {
            let root = sandbox("scan-claude-helpers")
            let project = "-Users-me-Dev-site"
            let parent = SyntheticClaude(root: root, project: project, cwd: "/Users/me/Dev/site")
            parent.prompt("Fix the footer links")
            parent.tool("h1", "Agent", ["description": "Explore the tray code", "subagent_type": "Explore"])
            // Claude Code's own layout: <project>/<session>/subagents/agent-<id>.jsonl (every line a sidechain line) and agent-<id>.meta.json.
            let folder = root.appendingPathComponent(project).appendingPathComponent(parent.id).appendingPathComponent("subagents", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            func helperLine(_ type: String, sidechain: Bool, _ text: String) -> String {
                let message: [String: Any] = type == "user" ? ["role": "user", "content": text]
                    : ["role": "assistant", "content": [["type": "text", "text": text]], "stop_reason": "end_turn"]
                return jsonLine(["type": type, "sessionId": parent.id, "agentId": "x", "cwd": "/Users/me/Dev/site", "isSidechain": sidechain,
                                 "timestamp": "2026-11-15T10:00:30.000Z", "message": message]) + "\n"
            }
            let flagged = folder.appendingPathComponent("agent-aaa1.jsonl"), unflagged = folder.appendingPathComponent("agent-bbb2.jsonl")
            let meta = folder.appendingPathComponent("agent-aaa1.meta.json")
            try? (helperLine("user", sidechain: true, "Look at the tray") + helperLine("assistant", sidechain: true, "Received.")).write(to: flagged, atomically: true, encoding: .utf8)
            // A helper file whose lines carry no sidechain mark at all: only its place says what it is.
            try? (helperLine("user", sidechain: false, "Look at the store") + helperLine("assistant", sidechain: false, "Received.")).write(to: unflagged, atomically: true, encoding: .utf8)
            try? "{\"agentType\":\"Explore\"}".write(to: meta, atomically: true, encoding: .utf8)
            func only(_ list: [AgentSession], _ what: String) -> Bool {
                guard list.count == 1, list[0].id == parent.id, list[0].project == "site" else { print("  \(what): \(list.map { "\($0.id) \($0.project)" })"); return false }
                return true
            }
            let scanner = AgentScanner()
            scanner.setSources([.init(agent: .claude, root: root)])
            guard only(scanner.scanNow(), "first sweep") else { return false }
            // Two helper transcripts were just written (and the parent's own file names one helper): two helpers at work.
            guard let first = scanner.scanNow().first, first.subagents == 2 else { print("  the parent's helper count \(String(describing: scanner.scanNow().first?.subagents))"); return false }
            guard scanner.currentStatus.tracked == 1 else { print("  tracked \(scanner.currentStatus.tracked)"); return false }
            // File events as FSEvents delivers them: the helper's file, its meta file, the folder itself, the session folder.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: flagged.path)
            guard only(scanner.scanAfterChanges([flagged.path, meta.path, unflagged.path, folder.path, folder.deletingLastPathComponent().path]), "file events") else { return false }
            guard scanner.currentStatus.tracked == 1 else { print("  tracked after events \(scanner.currentStatus.tracked)"); return false }
            // A helper that starts after the scanner is following: its new file, then a change in it.
            let late = folder.appendingPathComponent("agent-ccc3.jsonl")
            try? helperLine("user", sidechain: true, "A new helper").write(to: late, atomically: true, encoding: .utf8)
            guard only(scanner.scanAfterChanges([late.path]), "a new helper") else { return false }
            try? (helperLine("user", sidechain: true, "A new helper") + helperLine("assistant", sidechain: true, "Received.")).write(to: late, atomically: true, encoding: .utf8)
            guard only(scanner.scanAfterChanges([late.path]), "its change") else { return false }
            // The slow sweep, and a scanner that starts after all of it.
            guard only(scanner.scanNow(), "slow sweep") else { return false }
            let fresh = AgentScanner()
            fresh.setSources([.init(agent: .claude, root: root)])
            guard only(fresh.scanNow(), "a new scanner") else { return false }
            // Another layout: a file in the project folder whose lines are all sidechain lines is a helper's, not a session; one with a real prompt is.
            let strayID = UUID().uuidString.lowercased()
            let stray = root.appendingPathComponent(project).appendingPathComponent(strayID + ".jsonl")
            try? helperLine("user", sidechain: true, "Stray helper line").write(to: stray, atomically: true, encoding: .utf8)
            guard only(fresh.scanNow(), "a sidechain-only file") else { return false }
            let real = SyntheticClaude(root: root, project: project, cwd: "/Users/me/Dev/notes", id: strayID)
            real.prompt("A real prompt")
            guard fresh.scanNow().contains(where: { $0.id == strayID && $0.title == "A real prompt" }) else { print("  a real prompt in that file did not show"); return false }
            // A helper folder is told apart by its place below the watched folder only.
            guard AgentScanner.isHelperPath("/r/p/s/subagents/agent-1.jsonl", below: "/r"), AgentScanner.isHelperPath("/r/p/s/subagents", below: "/r"),
                  !AgentScanner.isHelperPath("/r/p/s.jsonl", below: "/r"), !AgentScanner.isHelperPath("/subagents/p/s.jsonl", below: "/subagents") else { print("  helper path rule"); return false }
            return true
        }
        FeaturesSelfTest.add("agents scan: a helper whose own transcript changed lately counts under its agent, even when the agent's file says nothing of it") {
            // The helper's start can lie before the part
            // of a very long chat file that Scout read when it started.
            let root = sandbox("scan-claude-helper-files")
            let chat = SyntheticClaude(root: root, project: "-Users-me-Dev-long", cwd: "/Users/me/Dev/long")
            chat.clock = Date(); chat.prompt("Work on it")
            let helpers = chat.url.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
            try? FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
            let fresh = helpers.appendingPathComponent("agent-aaa.jsonl"), stale = helpers.appendingPathComponent("agent-bbb.jsonl")
            try? "{}\n".write(to: fresh, atomically: true, encoding: .utf8)
            try? "{}\n".write(to: stale, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: stale.path)
            let scanner = AgentScanner()
            scanner.setSources([.init(agent: .claude, root: root)])
            guard let found = scanner.scanNow().first(where: { $0.id == chat.id }) else { print("  the chat did not show"); return false }
            guard found.subagents == 1 else { print("  helpers \(found.subagents) (one at work, one quiet for 10 minutes)"); return false }
            guard scanner.scanNow().count == 1 else { print("  a helper's file became an agent of its own"); return false }
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: fresh.path)
            guard scanner.scanNow().first(where: { $0.id == chat.id })?.subagents == 0 else { print("  a quiet helper still counted"); return false }
            return true
        }
        FeaturesSelfTest.add("agents scan: bookkeeping lines alone (a VS Code restart reopening old chats) bring nobody back; a real line does") {
            // On a restart VS Code
            // writes lines without a timestamp of their own (last-prompt, cost-state, mode, session-owner) into every chat it reopens.
            let root = sandbox("scan-claude-restart")
            let hourAgo = Date().addingTimeInterval(-3_600)
            let done = SyntheticClaude(root: root, project: "-Users-me-Dev-old", cwd: "/Users/me/Dev/old")
            done.clock = hourAgo; done.prompt("Tidy the notes"); done.finish("Done.")
            let cut = SyntheticClaude(root: root, project: "-Users-me-Dev-cut", cwd: "/Users/me/Dev/cut")
            cut.clock = hourAgo; cut.prompt("Rename the files")
            for chat in [done, cut] { try? FileManager.default.setAttributes([.modificationDate: hourAgo], ofItemAtPath: chat.url.path) }
            let scanner = AgentScanner()
            scanner.setSources([.init(agent: .claude, root: root)])
            guard scanner.scanNow().isEmpty else { print("  old chats showed before the restart"); return false }
            for chat in [done, cut] {
                for o: [String: Any] in [["type": "last-prompt", "lastPrompt": "Rename the files", "sessionId": chat.id],
                                         ["type": "session-owner", "accountUuid": "a", "organizationUuid": "o"],
                                         ["type": "cost-state", "totalCostUSD": 0, "startTime": 0], ["type": "mode", "mode": "default"]] {
                    chat.append(AgentsFeature.jsonLine(o) + "\n")
                }
            }
            let afterEvents = scanner.scanAfterChanges([done.url.path, cut.url.path])
            guard afterEvents.isEmpty, scanner.scanNow().isEmpty else { print("  after the restart: \(scanner.scanNow().map(\.title))"); return false }
            let fresh = AgentScanner()
            fresh.setSources([.init(agent: .claude, root: root)])
            guard fresh.scanNow().isEmpty else { print("  a scanner started after the restart: \(fresh.scanNow().map(\.title))"); return false }
            // The person writes in one of them: it is back, for both scanners.
            cut.clock = Date(); cut.prompt("Go on")
            guard let back = scanner.scanNow().first(where: { $0.id == cut.id }), back.state == .working else { print("  a real line did not bring it back"); return false }
            guard fresh.scanNow().contains(where: { $0.id == cut.id }), !fresh.scanNow().contains(where: { $0.id == done.id }) else { print("  the fresh scanner after a real line"); return false }
            // Bookkeeping in a chat Scout already follows does not keep a finished one: it leaves when its last real line is five minutes old.
            let live = SyntheticClaude(root: root, project: "-Users-me-Dev-live", cwd: "/Users/me/Dev/live")
            let sixAgo = Date().addingTimeInterval(-360)
            live.clock = sixAgo; live.prompt("Fix it"); live.finish("Fixed.")
            try? FileManager.default.setAttributes([.modificationDate: sixAgo], ofItemAtPath: live.url.path)
            let late = AgentScanner()
            late.setSources([.init(agent: .claude, root: root)])
            _ = late.scanNow()
            live.append(AgentsFeature.jsonLine(["type": "cost-state", "totalCostUSD": 0]) + "\n")
            guard !late.scanNow().contains(where: { $0.id == live.id }) else { print("  bookkeeping kept a chat that finished six minutes ago"); return false }
            return true
        }
        FeaturesSelfTest.add("agents scan: a quick answer is no finished task, a notification wakes the agent for a turn of its own, and no finish drops a card") {
            let root = sandbox("scan-claude-quick")
            let scanner = AgentScanner()
            scanner.setSources([.init(agent: .claude, root: root)])
            let base = Date().addingTimeInterval(-3_000)
            // A new session whose first turn ends two seconds after its prompt.
            let quick = SyntheticClaude(root: root, project: "-Users-me-Dev-quick", cwd: "/Users/me/Dev/quick")
            quick.clock = base; quick.prompt("Hello")
            guard let working = scanner.scanNow().first(where: { $0.id == quick.id }), working.state == .working, !working.wasQuickTurn else { print("  new session not working"); return false }
            quick.clock = base.addingTimeInterval(2); quick.finish("Received.")
            guard let done = scanner.scanNow().first(where: { $0.id == quick.id }), done.state == .waiting, done.wasQuickTurn, (done.turnSeconds ?? 99) < 3 else {
                print("  quick turn: \(String(describing: scanner.scanNow().first(where: { $0.id == quick.id })?.turnSeconds))"); return false }
            // A long turn is a finished task.
            let long = SyntheticClaude(root: root, project: "-Users-me-Dev-long", cwd: "/Users/me/Dev/long")
            long.clock = base; long.prompt("Build it")
            long.clock = base.addingTimeInterval(95); long.finish("Built.")
            guard let longDone = scanner.scanNow().first(where: { $0.id == long.id }), !longDone.wasQuickTurn, (longDone.turnSeconds ?? 0) > 90 else { print("  long turn"); return false }
            // The agent finished long ago; a background helper's notification wakes it, and it answers within seconds.
            long.tool("b1", "Agent", ["description": "Audit", "subagent_type": "general-purpose", "run_in_background": true])
            long.result("b1")
            long.clock = base.addingTimeInterval(100); long.finish("Waiting for the audit.")
            long.clock = base.addingTimeInterval(1_000)
            long.prompt("<task-notification>\n<task-id>x1</task-id>\n<tool-use-id>b1</tool-use-id>\n<status>completed</status>\n</task-notification>")
            guard let woken = scanner.scanNow().first(where: { $0.id == long.id }), woken.state == .working, woken.subagents == 0, woken.title == "Build it" else {
                print("  woken: \(String(describing: scanner.scanNow().first(where: { $0.id == long.id })?.state))"); return false }
            guard abs(woken.turnStartedAt.timeIntervalSince(base.addingTimeInterval(1_000))) < 1 else { print("  the woken turn is timed from the notification"); return false }
            long.clock = base.addingTimeInterval(1_002); long.finish("Received.")
            guard let answered = scanner.scanNow().first(where: { $0.id == long.id }), answered.state == .waiting, answered.wasQuickTurn, answered.lastMessage == "Received." else {
                print("  answered: \(String(describing: scanner.scanNow().first(where: { $0.id == long.id })?.turnSeconds))"); return false }
            // The store: no card drops when an agent finishes, a quick answer or a long task (the owner, 2026-11-18: only the wing's two lines).
            let store = AgentsStore(directory: sandbox("agents-quick-store"), isShared: true)
            let center = LiveActivityCenter.shared
            let before = center.cards.count
            var run = working; run.scanned = true
            store.applyScan([run], status: AgentScanner.Status())
            var end = done; end.scanned = true
            store.applyScan([end], status: AgentScanner.Status())
            var longRun = longDone; longRun.state = .working; longRun.finishedAt = nil; longRun.scanned = true
            store.applyScan([longRun], status: AgentScanner.Status())
            var longEnd = longDone; longEnd.scanned = true
            store.applyScan([longEnd], status: AgentScanner.Status())
            guard center.cards.count == before, !center.cards.contains(where: { $0.id.hasPrefix("agent.done.") }) else { print("  a finish dropped a card"); return false }
            return true
        }
        FeaturesSelfTest.add("agents scan: folder access is told apart (readable, missing)") {
            let root = sandbox("scan-access")
            return AgentAccess.probe(root) == .ok && AgentAccess.probe(root.appendingPathComponent("nope")) == .missing
                && AgentAccess.defaultRoot(for: .claude).path.hasSuffix("/.claude/projects") && AgentAccess.defaultRoot(for: .codex).path.hasSuffix("/.codex/sessions")
        }
    }

    private static func registerDashboardTests() {
        FeaturesSelfTest.add("agents: the wings show a face per agent and the latest message of one that waits (no timer)") {
            let all = AgentSession.synthetic(6)
            let working = AgentWingSummary.make(sessions: [all[0], all[1], all[3]], pending: [])
            guard working.working == 3, working.needs == 0, working.right == .progress(done: 2, total: 5), working.lines.count == 3,
                  working.faces.count == 3, working.faces.allSatisfy({ $0.mood == .working }), working.moreFaces == 0 else { print("  working: \(working)"); return false }
            let asking = AgentWingSummary.make(sessions: [all[0], all[1], all[5]], pending: [])
            guard asking.working == 2, asking.needs == 1, asking.right == .message("Which region?", asks: true), asking.lines.first?.attention == true,
                  asking.faces.count == 3, asking.faces.contains(where: { $0.mood == .asking && $0.agent == .codex }) else { print("  asking: \(asking)"); return false }   // faces keep the fixed order
            let held = AgentPending(sessionID: "syn-1", kind: .permission, tool: "Bash", summary: "make", detail: "make", questions: [], rawToolInput: nil, agent: .claude)
            let permission = AgentWingSummary.make(sessions: [all[0], all[1]], pending: [held])
            guard permission.working == 1, permission.needs == 1, permission.right == .message("Wants to use Bash: make", asks: true),
                  permission.faces.contains(where: { $0.id == "syn-1" && $0.mood == .asking }) else { print("  permission: \(permission)"); return false }
            let noList = AgentWingSummary.make(sessions: [all[3]], pending: [])
            guard noList.right == .none, noList.faces.count == 1, noList.faces[0].mood == .working else { print("  no list, no timer: \(noList)"); return false }
            let turn = AgentWingSummary.make(sessions: [all[2]], pending: [])
            guard turn.right == .message("The summary is in notes/summary.md.", asks: false), turn.working == 0, turn.needs == 0, turn.faces.first?.mood == .finished else { print("  turn end: \(turn)"); return false }
            let mixed = AgentWingSummary.make(sessions: [all[0], all[2]], pending: [])
            guard mixed.right == .message("The summary is in notes/summary.md.", asks: false), mixed.faces.map(\.mood) == [.working, .finished] else { print("  mixed: \(mixed)"); return false }
            let crowd = AgentWingSummary.make(sessions: all, pending: [])
            guard crowd.faces.count == 4, crowd.moreFaces == 2, crowd.faces.contains(where: { $0.mood == .asking }) else { print("  crowd: \(crowd)"); return false }   // the one asking is among the four
            let done = AgentWingSummary.make(sessions: [all[4]], pending: [])
            guard done.right == .allDone, done.faces.count == 1, done.faces[0].mood == .finished else { print("  all done: \(done)"); return false }
            let none = AgentWingSummary.make(sessions: [], pending: [])
            return none.right == .none && none.faces.isEmpty && none.moreFaces == 0
        }
        FeaturesSelfTest.add("nook: the dashboard is Agents + Ask AI, music and live panels appear while live, the agents panel takes the freed room") {
            func panels(_ kinds: [WidgetKind]) -> [NookItem] { kinds.map(NookItem.panel) }
            LivePanelLookup.override = []
            defer { LivePanelLookup.override = nil }
            guard WidgetKind.defaultLayout == [.agents, .askAI, .pulse, .today] else { print("  default \(WidgetKind.defaultLayout)"); return false }
            // The widths below are measured on the two always-pinned panels (the default also pins the graph and Today).
            let store = NookStore(persist: false, layout: [.agents, .askAI])
            store.tabIDs = { [] }
            // Music plays: it joins the row, and the agents panel gives it room.
            store.liveOverride = NookLive(playing: true, agents: 2)
            var fit = store.visible(in: 988)
            guard fit.shown == panels([.agents, .askAI]) + [.nowPlaying], store.span(of: .panel(.agents), in: fit.shown, width: 988) == 10 else {
                print("  playing: \(fit.shown) \(store.span(of: .panel(.agents), in: fit.shown, width: 988))"); return false
            }
            // Nothing live: the agents panel takes the rest of the row; with no agent it is a calm 5 cells.
            store.liveOverride = NookLive(playing: false, agents: 2)
            fit = store.visible(in: 988)
            guard fit.shown == panels([.agents, .askAI]), store.span(of: .panel(.agents), in: fit.shown, width: 988) == 15 else { print("  quiet: \(fit.shown)"); return false }
            store.liveOverride = NookLive(playing: false, agents: 0)
            guard store.span(of: .panel(.agents), in: store.visible(in: 988).shown, width: 988) == 5 else { print("  no agents"); return false }
            // A pinned Media panel is always there (and music does not add a second one); unpinned it was only live.
            let pinned = NookStore(persist: false, layout: [.agents, .askAI, .media])
            pinned.tabIDs = { [] }
            pinned.liveOverride = NookLive(playing: true, agents: 1)
            guard pinned.row == panels([.agents, .askAI, .media]) else { print("  pinned playing: \(pinned.row)"); return false }
            pinned.liveOverride = NookLive(playing: false, agents: 1)
            guard pinned.row == panels([.agents, .askAI, .media]) else { print("  pinned idle: \(pinned.row)"); return false }
            // Live panels come after the pinned ones, in their order; a full row drops the last live ones, never a pinned panel.
            let meeting = PreviewLivePanel(id: "live.meeting", title: "Up next", symbol: "calendar", span: 4, expandTo: .calendar) { Color.clear }
            let download = PreviewLivePanel(id: "live.downloads", title: "Downloads", symbol: "arrow.down.circle", span: 11) { Color.clear }
            let timer = PreviewLivePanel(id: "live.timer", title: "Timer", symbol: "timer", span: 2) { Color.clear }
            LivePanelLookup.override = [meeting, download, timer]
            store.liveOverride = NookLive(playing: true, agents: 2)
            fit = store.visible(in: 988)
            guard fit.shown == panels([.agents, .askAI]) + [.nowPlaying, .live("live.meeting"), .live("live.timer")], fit.hidden == 1 else { print("  live: \(fit.shown) hidden \(fit.hidden)"); return false }
            guard NookItem.live("live.meeting").detail == .calendar, NookItem.live("live.timer").detail == nil, NookItem.live("live.meeting").defaultSpan == 4 else { print("  expandTo"); return false }
            LivePanelLookup.override = []
            // Edit Nook shows only the pinned panels.
            store.isEditing = true
            let editing = store.visible(in: 1200).shown
            store.isEditing = false
            guard editing == panels([.agents, .askAI]) else { print("  editing \(editing)"); return false }
            let crowded = NookStore(persist: false, layout: [.agents, .pulse, .calendar, .todo, .media])
            crowded.tabIDs = { [] }
            crowded.liveOverride = NookLive(playing: false, agents: 2)
            // The CPU and memory graph stays (the owner wants it); the last pinned panel that does not fit is left out instead.
            guard crowded.visible(in: 988).shown == panels([.agents, .pulse, .calendar, .todo]) else { print("  pulse stays: \(crowded.visible(in: 988).shown)"); return false }
            guard crowded.visible(in: 1300).shown.contains(.panel(.pulse)) else { print("  pulse stays when there is room"); return false }
            return true
        }
    }

    private static func registerStoreTests() {
        FeaturesSelfTest.add("agents: the store builds sessions, holds permissions and questions, and answers them") {
            let store = AgentsStore(directory: sandbox("agents-store"))
            let replies = ReplyLog()
            @MainActor func send(_ json: String, mode: String = "") -> HookResponder {
                let r = HookResponder { replies.add($0) }
                if let e = AgentEvent.parse(agent: .claude, data: Data(json.utf8)) { store.receive(e, mode: mode, responder: r) }
                return r
            }
            func event(_ name: String, _ extra: String = "") -> String { "{\"session_id\":\"s1\",\"cwd\":\"/Users/me/Dev/Scout\",\"hook_event_name\":\"\(name)\"\(extra)}" }
            _ = send(event("SessionStart"))
            _ = send(event("UserPromptSubmit", ",\"prompt\":\"Fix the footer links\""))
            _ = send(event("PreToolUse", ",\"tool_name\":\"Bash\",\"tool_use_id\":\"t1\",\"tool_input\":{\"command\":\"swift build\"}"))
            guard let s = store.sessions.first, s.state == .working, s.title == "Fix the footer links", s.project == "Scout", s.steps.count == 2,
                  s.steps[1].summary == "swift build", !s.steps[1].done, s.currentStep?.summary == "swift build" else { print("  session: \(store.sessions)"); return false }
            _ = send(event("PostToolUse", ",\"tool_name\":\"Bash\",\"tool_use_id\":\"t1\""))
            guard store.sessions[0].steps[1].done, store.sessions[0].currentStep == nil, replies.all == ["", "", "", ""] else { print("  replies: \(replies.all)"); return false }
            // The agent's own to-do list becomes the progress line.
            _ = send(event("PreToolUse", ",\"tool_name\":\"TodoWrite\",\"tool_use_id\":\"t2\",\"tool_input\":{\"todos\":[{\"content\":\"A\",\"status\":\"completed\",\"activeForm\":\"Doing A\"},{\"content\":\"B\",\"status\":\"in_progress\",\"activeForm\":\"Doing B\"}]}"))
            guard store.sessions[0].todosDone == 1, store.sessions[0].todos.count == 2, store.sessions[0].currentTodo == "Doing B" else { print("  todos"); return false }
            // Permission: held (no reply yet), the session waits, Allow answers it.
            let before = replies.all.count
            _ = send(event("PermissionRequest", ",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf build\"},\"permission_suggestions\":[{\"type\":\"addRules\",\"rules\":[{\"toolName\":\"Bash\",\"ruleContent\":\"rm -rf build\"}],\"behavior\":\"allow\",\"destination\":\"localSettings\"}]"), mode: "permission")
            guard store.pending.count == 1, store.pending[0].summary == "rm -rf build", store.sessions[0].state == .waiting, replies.all.count == before, store.waitingCount == 1 else { print("  not held"); return false }
            store.decide(store.pending[0].id, .allow)
            guard store.pending.isEmpty, store.sessions[0].state == .working, replies.all.last == AgentsStore.permissionBody(allow: true) else { print("  allow: \(replies.all.last ?? "")"); return false }
            // Always allow echoes the agent's suggestion; Deny carries a message; "ask in terminal" answers with nothing.
            _ = send(event("PermissionRequest", ",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm i\"},\"permission_suggestions\":[{\"type\":\"addRules\",\"rules\":[{\"toolName\":\"Bash\",\"ruleContent\":\"npm i\"}],\"behavior\":\"allow\",\"destination\":\"localSettings\"}]"), mode: "permission")
            store.decide(store.pending[0].id, .alwaysAllow)
            guard let always = replies.all.last, always.contains("\"updatedPermissions\""), always.contains("\"ruleContent\":\"npm i\"") else { print("  always: \(replies.all.last ?? "")"); return false }
            _ = send(event("PermissionRequest", ",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/etc/hosts\",\"content\":\"x\"}"), mode: "permission")
            store.decide(store.pending[0].id, .deny)
            guard let denied = replies.all.last, denied.contains("\"behavior\":\"deny\""), denied.contains("\"message\"") else { return false }
            _ = send(event("PermissionRequest", ",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}"), mode: "permission")
            store.decide(store.pending[0].id, .ask)
            guard replies.all.last == "" else { return false }
            // A permission that the terminal answered: the tool's PostToolUse clears the card.
            _ = send(event("PermissionRequest", ",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"make\"}"), mode: "permission")
            guard store.pending.count == 1 else { return false }
            _ = send(event("PostToolUse", ",\"tool_name\":\"Bash\",\"tool_use_id\":\"t9\",\"tool_input\":{\"command\":\"make\"}"))
            guard store.pending.isEmpty, replies.all.last == "", store.sessions[0].state == .working else { print("  stale permission stayed"); return false }
            // The question goes back as updatedInput with the answers (a label, joined labels, or typed text).
            let question = ",\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"questions\":[{\"question\":\"Which framework?\",\"header\":\"Framework\",\"options\":[{\"label\":\"React\",\"description\":\"UI\"},{\"label\":\"Vue\",\"description\":\"UI\"}],\"multiSelect\":false}]}"
            _ = send(event("PreToolUse", question), mode: "question")
            guard store.pending.count == 1, store.pending[0].kind == .question, store.pending[0].questions[0].options.count == 2 else { print("  no question"); return false }
            store.decide(store.pending[0].id, .answers(["Which framework?": "React"]))
            guard let answer = replies.all.last, answer.contains("\"permissionDecision\":\"allow\""), answer.contains("\"answers\":{\"Which framework?\":\"React\"}"), answer.contains("\"questions\"") else { print("  answer: \(replies.all.last ?? "")"); return false }
            _ = send(event("PreToolUse", question), mode: "question")
            store.decide(store.pending[0].id, .answers(["Which framework?": "Svelte, please"]))
            guard replies.all.last?.contains("\"answers\":{\"Which framework?\":\"Svelte, please\"}") == true else { return false }
            // The permission event for AskUserQuestion itself is passed through to the terminal.
            _ = send(event("PermissionRequest", ",\"tool_name\":\"AskUserQuestion\",\"tool_input\":{}"), mode: "permission")
            guard store.pending.isEmpty, replies.all.last == "" else { return false }
            // Helpers are counted; Stop makes the session wait for you and keeps the last message; the next prompt starts a new turn.
            _ = send(event("SubagentStart", ",\"agent_id\":\"x\""))
            _ = send(event("SubagentStart", ",\"agent_id\":\"y\""))
            _ = send(event("SubagentStop", ",\"agent_id\":\"x\""))
            guard store.sessions[0].subagents == 1 else { return false }
            _ = send(event("Stop", ",\"last_assistant_message\":\"All done.\""))
            guard store.sessions[0].state == .waiting, store.sessions[0].note.hasPrefix("Finished"), store.sessions[0].lastMessage == "All done.", store.sessions[0].finishedAt != nil else { print("  stop: \(store.sessions[0].state) \(store.sessions[0].note)"); return false }
            _ = send(event("Notification", ",\"notification_type\":\"idle_prompt\",\"message\":\"Claude is waiting for your input\""))
            guard store.sessions[0].state == .waiting, store.sessions[0].note.hasPrefix("Finished") else { print("  idle notice changed a finished session"); return false }
            _ = send(event("UserPromptSubmit", ",\"prompt\":\"One more thing\""))
            guard store.sessions[0].state == .working, store.sessions[0].finishedAt == nil, store.sessions[0].title == "One more thing" else { return false }
            _ = send(event("Notification", ",\"notification_type\":\"permission_prompt\",\"message\":\"Claude needs your permission\""))
            guard store.sessions[0].state == .waiting, store.waitingCount == 1 else { return false }
            _ = send(event("SessionEnd"))
            return store.sessions.isEmpty
        }
    }

    #if !APPSTORE
    // MARK: Full edition: the installer

    nonisolated private static let token = "feedfacefeedfacefeedfacefeedface"

    private static func registerInstallerTests() {
        FeaturesSelfTest.add("agents: connect merges, is idempotent, backs up, and disconnect removes only Scout's entries") {
            let base = sandbox("agents-base")
            let claude = base.appendingPathComponent(".claude", isDirectory: true)
            try? FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
            let existing = """
            {"model":"opus","permissions":{"allow":["Bash(ls)"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/usr/local/bin/my-guard"}]}],"Stop":[{"hooks":[{"type":"command","command":"say done"},{"type":"command","command":"\\"/Users/x/scout/agents/scout-hook\\" claude"}]}]}}
            """
            try? existing.write(to: claude.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
            guard AgentInstaller.state(.claude, base: base, port: 47231, token: token) == .outdated else { print("  old script entry not seen"); return false }
            do {
                try AgentInstaller.connect(.claude, base: base, port: 47231, token: token)
                try AgentInstaller.connect(.claude, base: base, port: 47231, token: token)   // twice: still one set of entries
            } catch { print("  connect threw \(error)"); return false }
            guard let data = try? Data(contentsOf: claude.appendingPathComponent("settings.json")),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let hooks = json["hooks"] as? [String: Any] else { return false }
            let text = String(decoding: data, as: UTF8.self)
            func scoutCount(_ event: String) -> Int {
                (hooks[event] as? [[String: Any]] ?? []).flatMap { ($0["hooks"] as? [[String: Any]] ?? []) }.filter { AgentHooks.isScouts(command: $0["command"] as? String ?? "") }.count
            }
            guard json["model"] as? String == "opus", (json["permissions"] as? [String: Any]) != nil,
                  text.contains("/usr/local/bin/my-guard"), text.contains("say done"), !text.contains("scout-hook"),
                  scoutCount("PreToolUse") == 2, scoutCount("PermissionRequest") == 1, scoutCount("Stop") == 1, scoutCount("SessionStart") == 1,
                  AgentInstaller.state(.claude, base: base, port: 47231, token: token) == .connected,
                  AgentInstaller.state(.claude, base: base, port: 51000, token: token) == .outdated else { print("  after connect: unexpected content", scoutCount("PreToolUse"), scoutCount("Stop"), text.count); return false }
            let backups = ((try? FileManager.default.contentsOfDirectory(atPath: claude.path)) ?? []).filter { $0.contains("scout-backup") }
            guard !backups.isEmpty else { print("  no backup"); return false }
            // A port change: Update rewrites Scout's entries only.
            do { try AgentInstaller.connect(.claude, base: base, port: 51000, token: token) } catch { return false }
            guard AgentInstaller.state(.claude, base: base, port: 51000, token: token) == .connected else { return false }
            do { try AgentInstaller.disconnect(.claude, base: base) } catch { return false }
            guard let after = try? String(contentsOf: claude.appendingPathComponent("settings.json"), encoding: .utf8) else { return false }
            return !after.contains("x-scout-token") && after.contains("/usr/local/bin/my-guard") && after.contains("say done") && after.contains("\"opus\"")
                && !AgentInstaller.isConnected(.claude, base: base)
                && AgentInstaller.state(.claude, base: base, port: 51000, token: token) == .notConnected
        }
        FeaturesSelfTest.add("agents: a broken settings file is left alone; Codex gets hooks.json") {
            let base = sandbox("agents-base-2")
            let claude = base.appendingPathComponent(".claude", isDirectory: true)
            try? FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
            let broken = "{ this is not json"
            try? broken.write(to: claude.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
            var threw = false
            do { try AgentInstaller.connect(.claude, base: base, port: 47231, token: token) } catch { threw = true }
            let untouched = (try? String(contentsOf: claude.appendingPathComponent("settings.json"), encoding: .utf8)) == broken
            do { try AgentInstaller.connect(.codex, base: base, port: 47231, token: token) } catch { return false }
            let codex = (try? String(contentsOf: base.appendingPathComponent(".codex/hooks.json"), encoding: .utf8)) ?? ""
            return threw && untouched && codex.contains("PermissionRequest") && codex.contains("/hook/codex/PermissionRequest") && !codex.contains("Notification") && !codex.contains("AskUserQuestion")
        }
    }

    // MARK: Full edition: the real hook commands against a real bridge

    /// What the bridge handler saw, and the responder it is holding (touched from the bridge queue and the test).
    final class HeldBox: @unchecked Sendable {
        struct Record { var agent: AgentKind; var event: String; var mode: String; var body: String }
        private let lock = NSLock()
        private var _records: [Record] = []
        private var _responder: HookResponder?
        private var _closed = false
        var records: [Record] { lock.withLock { _records } }
        var responder: HookResponder? { lock.withLock { _responder } }
        var closed: Bool { lock.withLock { _closed } }
        func record(_ r: Record) { lock.withLock { _records.append(r) } }
        func hold(_ r: HookResponder) { lock.withLock { _responder = r } }
        func clearResponder() { lock.withLock { _responder = nil } }
        func markClosed() { lock.withLock { _closed = true } }
    }

    /// Runs a hook command exactly as the agent does: through `/bin/sh -c`, the hook JSON on stdin.
    nonisolated private static func launch(_ command: String, input: String) -> (process: Process, output: Pipe, started: Date) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        let stdin = Pipe(), out = Pipe()
        p.standardInput = stdin
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { print("  launch failed: \(error)") }
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
        return (p, out, Date())
    }

    private static func registerBridgeTests() {
        FeaturesSelfTest.add("agents: the real hook commands over HTTP (events, held answers, hang-up, bad key, junk reply, no bridge)") {
            let dir = sandbox("agents-bridge")
            let bridge = AgentBridge(directory: dir, defaultPort: 0)
            let held = HeldBox()
            bridge.handler = { agent, event, mode, body, responder in
                held.record(.init(agent: agent, event: event, mode: mode, body: String(decoding: body, as: UTF8.self)))
                if mode.isEmpty { responder.respond("") } else { held.hold(responder) }
            }
            bridge.start()
            guard spin(until: { bridge.isRunning }, timeout: 5) else { print("  bridge did not start: \(bridge.failure ?? "?")"); return false }
            defer { bridge.stop() }
            let port = bridge.port
            func command(_ agent: AgentKind, _ event: String, mode: String = "") -> String {
                let entry = AgentHooks.entries(for: agent).first { $0.event == event && $0.mode == mode } ?? AgentHooks.Entry(event: event, matcher: nil, mode: mode, timeout: 5)
                return AgentHooks.command(agent, entry, port: port, token: bridge.token)
            }
            // A plain event reaches the handler with its body; the hook ends quickly with NO output and exit 0.
            let plain = launch(command(.codex, "SessionStart"), input: "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"s1\"}")
            guard spin(until: { !plain.process.isRunning }, timeout: 6), plain.process.terminationStatus == 0, plain.output.fileHandleForReading.readDataToEndOfFile().isEmpty else { print("  plain event failed"); return false }
            guard held.records.count == 1, held.records[0].agent == .codex, held.records[0].event == "SessionStart", held.records[0].mode == "", held.records[0].body.contains("SessionStart") else { print("  handler saw \(held.records)"); return false }
            // A body bigger than one read still arrives whole.
            let big = String(repeating: "x", count: 300_000)
            let large = launch(command(.claude, "PostToolUse"), input: "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"s1\",\"tool_response\":\"\(big)\"}")
            guard spin(until: { !large.process.isRunning }, timeout: 8), held.records.count == 2, held.records[1].body.count > 300_000 else { print("  big body"); return false }
            // A permission waits for an answer: the hook prints exactly what we respond with, and nothing else.
            let permCommand = command(.claude, "PermissionRequest", mode: "permission")
            let perm = launch(permCommand, input: "{\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\"}")
            guard spin(until: { held.responder != nil }, timeout: 6) else { print("  nothing held"); return false }
            guard perm.process.isRunning else { print("  permission hook ended before an answer"); return false }
            held.responder?.respond(AgentsStore.permissionBody(allow: true))
            guard spin(until: { !perm.process.isRunning }, timeout: 6), perm.process.terminationStatus == 0 else { return false }
            let out = String(decoding: perm.output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard out == AgentsStore.permissionBody(allow: true), held.records.last?.mode == "permission" else { print("  allow output: \(out)"); return false }
            // The question path is its own URL and waits too.
            held.clearResponder()
            let ask = launch(command(.claude, "PreToolUse", mode: "question"), input: "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"AskUserQuestion\"}")
            guard spin(until: { held.responder != nil }, timeout: 6), held.records.last?.mode == "question", held.records.last?.event == "PreToolUse" else { print("  question not held"); return false }
            held.responder?.respond("")
            guard spin(until: { !ask.process.isRunning }, timeout: 6), ask.process.terminationStatus == 0, ask.output.fileHandleForReading.readDataToEndOfFile().isEmpty else { print("  empty answer misbehaved"); return false }
            // The agent gets answered in its terminal: the hook hangs up and the bridge notices.
            held.clearResponder()
            let hung = launch(permCommand, input: "{\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\"}")
            guard spin(until: { held.responder != nil }, timeout: 6) else { return false }
            held.responder?.onClose = { held.markClosed() }
            _ = Shell.run("/usr/bin/pkill", ["-f", "127.0.0.1:\(port)/hook/claude/PermissionRequest"])
            guard spin(until: { held.closed }, timeout: 6) else { print("  hang-up not noticed"); return false }
            _ = hung
            // A wrong key is refused (nothing reaches the handler).
            let count = held.records.count
            let bad = Shell.run("/usr/bin/curl", ["-s", "-m", "3", "-o", "/dev/null", "-w", "%{http_code}", "-X", "POST", "-H", "x-scout-token: nope", "--data-binary", "{}",
                                                  "http://127.0.0.1:\(port)/hook/claude/Stop"])
            guard bad == "401", held.records.count == count else { print("  wrong key answered \(bad ?? "nil")"); return false }
            // Something else answering with junk on a waiting hook: still no output (only a JSON object is passed on).
            held.clearResponder()
            let junk = launch(permCommand, input: "{\"hook_event_name\":\"PermissionRequest\"}")
            guard spin(until: { held.responder != nil }, timeout: 6) else { return false }
            held.responder?.respond("<html>not scout</html>")
            guard spin(until: { !junk.process.isRunning }, timeout: 6), junk.process.terminationStatus == 0,
                  junk.output.fileHandleForReading.readDataToEndOfFile().isEmpty else { print("  junk reply leaked"); return false }
            // Scout not running: every command exits 0 with empty output, fast.
            bridge.stop()
            for (cmd, label) in [(command(.claude, "PermissionRequest", mode: "permission"), "permission"), (command(.claude, "PreToolUse", mode: "question"), "question"),
                                 (command(.claude, "UserPromptSubmit"), "event"), (command(.claude, "SessionEnd"), "end")] {
                let lonely = launch(cmd, input: "{\"hook_event_name\":\"X\"}")
                guard spin(until: { !lonely.process.isRunning }, timeout: 4), lonely.process.terminationStatus == 0,
                      lonely.output.fileHandleForReading.readDataToEndOfFile().isEmpty, Date().timeIntervalSince(lonely.started) < 2.5 else { print("  \(label) hook misbehaved without a bridge"); return false }
            }
            return true
        }
        FeaturesSelfTest.add("agents: the bridge falls back when its port is busy, and keeps the token") {
            let dirA = sandbox("agents-port-a"), dirB = sandbox("agents-port-b")
            let first = AgentBridge(directory: dirA, defaultPort: 0)
            first.start()
            guard spin(until: { first.isRunning }, timeout: 5) else { return false }
            defer { first.stop() }
            let second = AgentBridge(directory: dirB, defaultPort: first.port)   // its "default" is taken
            second.start()
            guard spin(until: { second.isRunning }, timeout: 8), second.port != first.port, second.usingFallbackPort, second.advertisedPort == second.port else {
                print("  fallback: running \(second.isRunning) port \(second.port) vs \(first.port) failure \(second.failure ?? "-")"); return false
            }
            defer { second.stop() }
            let again = AgentBridge(directory: dirB, defaultPort: first.port)
            return again.token == second.token && !first.usingFallbackPort
        }
    }
    #endif

    // MARK: Gallery

    private static func previewGrid(_ name: String, _ count: Int, pending: [AgentPending] = []) -> AgentsStore {
        let store = AgentsStore(directory: AppPaths.folder(name))
        store.loadSessions(AgentSession.synthetic(count), pending: pending)
        store.previewDoneToday(5)
        store.previewScan(.init(access: [.claude: .ok, .codex: .ok], tracked: count, sessions: count, watching: true, lastSweep: Date()))
        return store
    }

    private static func previewStore(_ name: String, selecting: String? = nil, pending: [AgentPending]? = nil) -> AgentsStore {
        let store = AgentsStore(directory: AppPaths.folder(name))
        store.loadSamples(pending: pending, selecting: selecting)
        store.previewBridge(.init(running: true, port: AgentHooks.defaultPort, fallback: false, failure: nil))
        store.previewScan(.init(access: [.claude: .ok, .codex: .missing], tracked: 3, sessions: 3, watching: true, lastSweep: Date()))
        return store
    }

    static func registerGallery() {
        enableInNotch()   // the gallery's isolated settings may hold a list saved without Agents
        AgentsAutoOpenGallery.register()   // auto-*: the notch opening by itself over the Agents view, and the lit dashboard row
        AgentNookGallery.register()   // the AgentNook pictures (Features/Agents/Nook)
        let permission = AgentPending(sessionID: "demo-1", kind: .permission, tool: "Bash", summary: "rm -rf node_modules && npm install",
                                      detail: "rm -rf node_modules && npm install", questions: [], rawToolInput: nil, agent: .claude,
                                      permissionSuggestions: Data("[{\"type\":\"addRules\",\"rules\":[{\"toolName\":\"Bash\",\"ruleContent\":\"npm install\"}],\"behavior\":\"allow\",\"destination\":\"localSettings\"}]".utf8))
        let question = AgentPending(sessionID: "demo-1", kind: .question, tool: "AskUserQuestion", summary: "Which library?", detail: "",
                                    questions: [AgentQuestion(question: "Which date library should I use?", header: "Library",
                                                              options: [.init(label: "Foundation", detail: ""), .init(label: "swift-datetime", detail: ""), .init(label: "Keep as is", detail: "")], multiSelect: false)],
                                    rawToolInput: nil, agent: .claude)
        let working = previewStore("agents-preview", pending: [])
        let waiting = previewStore("agents-preview-2", selecting: "demo-2")
        let asking = previewStore("agents-preview-3", pending: [question])
        let permissionStore = previewStore("agents-preview-4", pending: [permission])
        let done = previewStore("agents-preview-5", selecting: "demo-3", pending: [])
        let empty = AgentsStore(directory: AppPaths.folder("agents-preview-6"))
        let freshBridge = AgentsStore(directory: AppPaths.folder("agents-preview-7"))
        freshBridge.previewBridge(.init(running: true, port: 51893, fallback: true, failure: nil))
        // The detail view of one session (clicking a tile opens it).
        FeatureGallery.workspace("agents-workspace", height: 150) { AgentsWorkspaceView(store: working, detail: "demo-1") }
        FeatureGallery.workspace("agents-workspace-waiting", height: 150) { AgentsWorkspaceView(store: waiting, detail: "demo-2") }
        FeatureGallery.workspace("agents-workspace-permission", height: 205) { AgentsWorkspaceView(store: permissionStore, detail: "demo-1") }
        FeatureGallery.workspace("agents-workspace-question", height: 205) { AgentsWorkspaceView(store: asking, detail: "demo-1") }
        FeatureGallery.workspace("agents-workspace-done", height: 150) { AgentsWorkspaceView(store: done, detail: "demo-3") }
        // The multi view: every session on the Mac, one live tile each (the island grows to fit the rows).
        let askPermission = AgentPending(sessionID: "syn-1", kind: .permission, tool: "Bash", summary: "npm run lint && npm run build", detail: "npm run lint && npm run build",
                                         questions: [], rawToolInput: nil, agent: .claude)
        let grid1 = previewGrid("agents-preview-g1", 1)
        let grid3 = previewGrid("agents-preview-g3", 3)
        let grid6 = previewGrid("agents-preview-g6", 6)
        let gridAsk = previewGrid("agents-preview-gask", 6, pending: [askPermission])
        let gridAsk3 = previewGrid("agents-preview-gask3", 3, pending: [askPermission])
        func gridHeight(_ s: AgentsStore) -> CGFloat { AgentTileMetrics.islandHeight(sessions: s.sessions, pending: s.pending, width: 988) - 59 }
        FeatureGallery.workspace("agents-grid-1", width: 988, height: gridHeight(grid1)) { AgentsWorkspaceView(store: grid1) }
        FeatureGallery.workspace("agents-grid-3", width: 988, height: gridHeight(grid3)) { AgentsWorkspaceView(store: grid3) }
        FeatureGallery.workspace("agents-grid-6", width: 988, height: gridHeight(grid6)) { AgentsWorkspaceView(store: grid6) }
        FeatureGallery.workspace("agents-grid-asking", width: 988, height: gridHeight(gridAsk)) { AgentsWorkspaceView(store: gridAsk) }
        FeatureGallery.workspace("agents-grid-asking-3", width: 988, height: gridHeight(gridAsk3)) { AgentsWorkspaceView(store: gridAsk3) }
        // The Nook as the agentic dashboard: what plays, what is open and what runs decide what shows.
        func nook(_ name: String, live: NookLive, sessions: Int, asking: Bool = false, playing: Bool) {
            let store = previewGrid("agents-preview-n-\(name)", sessions, pending: asking ? [askPermission] : [])
            let row = NookStore(persist: false, layout: WidgetKind.defaultLayout)
            row.liveOverride = live
            FeatureGallery.workspace("nook-agentic-\(name)", width: 988, height: 150) {
                let _ = AgentsStore.shared.loadSessions(store.sessions, pending: store.pending)
                let _ = AgentsStore.shared.previewDoneToday(sessions == 0 ? 0 : 5)
                let _ = NowPlayingService.shared.showSample(playing ? NowPlayingService.sampleTrack : nil)
                NookGrid(store: row)
            }
        }
        nook("music-3agents", live: NookLive(playing: true, openTodos: 0, agents: 3), sessions: 3, playing: true)
        nook("todos-asking", live: NookLive(playing: false, openTodos: 4, agents: 1), sessions: 1, asking: true, playing: false)
        nook("quiet-2agents", live: NookLive(playing: false, openTodos: 0, agents: 2), sessions: 2, playing: false)
        nook("everything", live: NookLive(playing: true, openTodos: 4, agents: 3), sessions: 3, playing: true)
        nook("empty", live: NookLive(playing: false, openTodos: 0, agents: 0), sessions: 0, playing: false)
        // The widget at three widths.
        FeatureGallery.widget("agents-widget-3cells", span: 3) { AgentsWidgetView(store: grid3) }
        FeatureGallery.widget("agents-widget-6cells", span: 6) { AgentsWidgetView(store: gridAsk3) }
        FeatureGallery.widget("agents-widget-12cells", span: 12) { AgentsWidgetView(store: grid6) }
        FeatureGallery.widget("agents-widget-empty", span: 3) { AgentsWidgetView(store: empty) }
        FeatureGallery.workspace("agents-workspace-empty", height: 150) { AgentsWorkspaceView(store: empty) }
        // The real open notch (header, 200 pt) around the workspace, and taller while a request waits.
        Gallery.register("agents-notch-open", size: CGSize(width: 1120, height: 330)) {
            let _ = AgentsStore.shared.loadSamples(pending: [], selecting: "demo-1")
            NotchScene(size: CGSize(width: 1120, height: 330), open: true, workspace: .agents, openHeight: 200)
        }
        // The CPU tab with an agent's window open under the den, at its real height (the den 419 + the window 250).
        Gallery.register("agents-notch-open-window", size: CGSize(width: 1120, height: 720)) {
            let _ = AgentsStore.shared.loadSamples(pending: [], selecting: "demo-1")
            // An announcement opens its agent's window from the first frame (a focus id is only taken once the view is on screen, after the picture).
            let _ = { AgentsStore.shared.announcement = AgentAnnouncement(sessionID: "demo-1", kind: .finished(minutes: 2), at: Date()) }()
            NotchScene(size: CGSize(width: 1120, height: 720), open: true, workspace: .agents, openHeight: AgentDenLayout.islandHeight(extra: AgentDenLayout.drawerHeight))
        }
        Gallery.register("agents-notch-open-permission", size: CGSize(width: 1120, height: 380)) {
            let _ = AgentsStore.shared.loadSamples(pending: [permission], selecting: "demo-1")
            NotchScene(size: CGSize(width: 1120, height: 380), open: true, workspace: .agents, openHeight: 262)
        }
        Gallery.register("agents-notch-open-question", size: CGSize(width: 1120, height: 380)) {
            let _ = AgentsStore.shared.loadSamples(pending: [question], selecting: "demo-1")
            NotchScene(size: CGSize(width: 1120, height: 380), open: true, workspace: .agents, openHeight: 262)
        }
        Gallery.register("agents-permission-card", size: CGSize(width: 440, height: 220)) {
            PendingView(request: permission, store: working, compact: true).background(GlassBackground(cornerRadius: 22))
        }
        Gallery.register("agents-question-card", size: CGSize(width: 440, height: 190)) {
            PendingView(request: question, store: working, compact: true).background(GlassBackground(cornerRadius: 22))
        }
        // The closed notch: left the glyph and counts, right the most important session, and (hovering) one line per agent.
        let all6 = AgentSession.synthetic(6)
        func wingsStore(_ name: String, _ picks: [Int], done: Bool = false) -> AgentsStore {
            let store = AgentsStore(directory: AppPaths.folder(name))
            var list = picks.map { all6[$0] }
            if done { for i in list.indices { list[i].state = .done; list[i].note = ""; list[i].finishedAt = Date().addingTimeInterval(-200) } }
            store.loadSessions(list)
            return store
        }
        func wings(_ name: String, _ store: AgentsStore, frozenAt: Double = 0.6) {
            Gallery.register(name, size: CGSize(width: 480, height: 170), backdrop: .screenTop) {
                VStack(spacing: 6) {
                    ZStack {
                        UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous).fill(Color.black).frame(width: 450, height: 34)
                        // As the closed notch lays them out: each wing 130 pt wide, the content at its own size, 10 pt in from the edge.
                        HStack(spacing: 0) {
                            AgentWingLeft(store: store, frozenAt: frozenAt).fixedSize().padding(.leading, 10).frame(width: 130, alignment: .leading)
                            Spacer().frame(width: 190)
                            AgentWingRight(store: store).fixedSize().padding(.trailing, 10).frame(width: 130, alignment: .trailing)
                        }
                        .frame(width: 450)
                    }
                    AgentWingDetail(store: store).padding(.horizontal, 14).padding(.vertical, 10)
                        .background(UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18, style: .continuous).fill(Color.black))
                }
                .environment(\.colorScheme, .dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        wings("agents-wings-1-working", wingsStore("agents-preview-w1", [0]))
        wings("agents-wings-3-working", wingsStore("agents-preview-w3", [0, 1, 3]))
        wings("agents-wings-needs-you", wingsStore("agents-preview-w4", [0, 1, 5]))
        wings("agents-wings-all-done", wingsStore("agents-preview-w5", [4, 2], done: true))
        wings("agents-wings-your-move", wingsStore("agents-preview-w6", [0, 2]))
        wings("agents-wings-timerless", wingsStore("agents-preview-w7", [3, 2]))
        wings("agents-wings-six", wingsStore("agents-preview-w8", [0, 1, 2, 3, 4, 5]))
        // The REAL closed notch (NotchRootView) at the 16-inch notch, the camera housing outlined in red: nothing may sit inside it.
        func closedNotch(_ name: String, _ store: AgentsStore, rest: Bool = false) {
            Gallery.register(name, size: CGSize(width: 520, height: 44), backdrop: .screenTop) {
                AgentsClosedNotchPreview(store: store, size: CGSize(width: 520, height: 44), rest: rest)
            }
        }
        closedNotch("agents-notch-closed-1-rest", wingsStore("agents-preview-c1", [0]), rest: true)
        closedNotch("agents-notch-closed-2-rest", wingsStore("agents-preview-c2", [0, 1]), rest: true)
        closedNotch("agents-notch-closed-4-rest", wingsStore("agents-preview-c4", [0, 1, 3, 5]), rest: true)
        closedNotch("agents-notch-closed-2-news", wingsStore("agents-preview-c2n", [0, 1]))
        closedNotch("agents-notch-closed-6-news", wingsStore("agents-preview-c6", [0, 1, 2, 3, 4, 5]))
        // The owner, 2026-11-18: the two-line message shows the whole sentence, the wing exactly as wide as it needs (no empty space).
        for (name, message) in [("long", "The new release is in review at the store, and it goes live by itself when it is approved, so nothing waits on you now."),
                                ("mid", "I changed the footer links and pushed the branch.")] {
            Gallery.register("agents-notch-closed-\(name)", size: CGSize(width: 1000, height: 44), backdrop: .screenTop) {
                let store = AgentsStore(directory: AppPaths.folder("agents-preview-\(name)"))
                let _ = {
                    var waiting = all6[2]
                    waiting.state = .waiting; waiting.note = "Finished: waiting for your next message"; waiting.lastMessage = message
                    waiting.finishedAt = Date().addingTimeInterval(-20)
                    store.loadSessions([all6[0], waiting])
                }()
                AgentsClosedNotchPreview(store: store, size: CGSize(width: 1000, height: 44), rest: false)
            }
        }
        AgentFaceGallery.register()
        // The Settings page: the edition's own wording, and both wordings in either build.
        // Settings leads with "Scout finds Claude Code and Codex sessions by itself"; the App Store edition may have to ask once.
        let deniedStore = AgentsStore(directory: AppPaths.folder("agents-preview-8"))
        deniedStore.previewScan(.init(access: [.claude: .denied, .codex: .missing], tracked: 0, sessions: 0, watching: false, lastSweep: Date()))
        FeatureGallery.settings("agents-scan-settings", height: 1280) { AgentsSettingsPane(store: grid3) }
        FeatureGallery.settings("agents-scan-settings-denied", height: 1280) { AgentsSettingsPane(store: deniedStore) }
        FeatureGallery.workspace("agents-scan-empty-denied", width: 988, height: 150) { AgentsWorkspaceView(store: deniedStore) }
        FeatureGallery.workspace("agents-scan-empty", width: 988, height: 150) { AgentsWorkspaceView(store: empty) }
        FeatureGallery.settings("agents-settings", height: 1180) { AgentsSettingsPane(store: working) }
        FeatureGallery.settings("agents-settings-paste", height: 1180) { AgentsSettingsPane(manual: true, store: working) }
        FeatureGallery.settings("agents-settings-paste-busy-port", height: 1180) { AgentsSettingsPane(manual: true, store: freshBridge) }
        #if !APPSTORE
        FeatureGallery.settings("agents-settings-connect", height: 780) { AgentsSettingsPane(manual: false, store: working) }
        FeatureGallery.settings("settings-agents", height: 1100) { AgentsSettingsPane(store: working) }
        #endif
    }
}

/// The real closed notch with the agents' wings, as the owner's 16-inch MacBook draws it (notch 185 × 32 pt), the camera housing outlined in red.
struct AgentsClosedNotchPreview: View {
    let size: CGSize
    @ObservedObject var model: NotchScreenModel
    @ObservedObject var center: LiveActivityCenter
    @ObservedObject var navigator: NotchNavigator
    @ObservedObject var nook: NookStore

    /// `rest`: the right wing has stepped aside (nothing new), as the notch sits most of the time.
    init(store: AgentsStore, size: CGSize, rest: Bool = false) {
        self.size = size
        self.model = NotchScreenModel(geometry: .sample16, panelSize: size)
        let center = LiveActivityCenter()
        if rest {
            center.show(LiveActivity(id: "agents.main", kind: .agent, expiresAfter: nil, onTap: nil, leading: { AgentWingLeft(store: store, frozenAt: 0.6) }, trailing: { EmptyView() }))
        } else {
            center.show(AgentsStore.wings(store: store, expiresAfter: nil))
        }
        self.center = center
        self.navigator = NotchNavigator()
        self.nook = NookStore(persist: false, layout: nil)
    }

    var body: some View {
        ZStack(alignment: .top) {
            MockMenuBar(notch: .sample16)
            NotchRootView(model: model, center: center, navigator: navigator, nook: nook, styleOverride: .classic)
            Rectangle().strokeBorder(Color.red, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .frame(width: NotchGeometry.sample16.size.width, height: NotchGeometry.sample16.size.height)
                .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }
}
