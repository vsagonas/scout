import CoreServices
import Foundation

/// Finds the agent sessions running on this Mac by themselves: it watches the transcript folders Claude Code
/// (`~/.claude/projects/<project>/<session>.jsonl`) and Codex (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`) write while
/// they work, and reads each recently changed file as it grows. READ ONLY: nothing is ever written there.
///
/// A session counts as active while its file changed in the last `activeWindow`. New files arrive through FSEvents (and a
/// slow sweep as a safety net); the files already followed are checked every `interval` seconds. The first time a file is
/// seen only its last few MB are read; after that only the new bytes. Nothing from a transcript is kept beyond the short
/// summaries in `TranscriptState`, in memory.
///
/// A helper (subagent) is never a session of its own. Claude Code writes each helper's transcript into
/// `<project>/<session>/subagents/agent-<id>.jsonl` (next to an `agent-<id>.meta.json`), every line marked `isSidechain: true`; the
/// parent's own transcript already says how many helpers work (Agent/Task tool calls and their task notifications). So nothing under
/// a `subagents` folder is ever tracked, whichever way the file would arrive (first sweep, FSEvents, the slow sweep), and a file whose
/// lines are all sidechain lines is not shown either.
final class AgentScanner: @unchecked Sendable {
    struct Source: Equatable, Sendable {
        var agent: AgentKind
        var root: URL
    }

    enum Access: Equatable, Sendable { case unknown, ok, missing, denied }

    struct Status: Equatable, Sendable {
        var access: [AgentKind: Access] = [:]
        var tracked = 0
        var sessions = 0
        var watching = false        // the FSEvents stream is running
        var lastSweep: Date?
    }

    let activeWindow: TimeInterval
    let waitingWindow: TimeInterval
    let interval: TimeInterval
    private let initialTail: UInt64 = 3_000_000
    private let maxRead: UInt64 = 16_000_000

    private let queue = DispatchQueue(label: "scout.agents.scanner", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var stream: FSEventStreamRef?
    private var sources: [Source] = []
    private var files: [String: Tracked] = [:]
    private var dirty: Set<String> = []
    private var lastSweep = Date.distantPast
    private var lastDelivered: [AgentSession] = []
    private var lastStatus = Status()
    private var access: [AgentKind: Access] = [:]
    private var running = false

    /// The queue `onChange` is called on (the main queue; tests use their own).
    var callbackQueue: DispatchQueue = .main
    /// Called on `callbackQueue` when the sessions or the status change.
    var onChange: (@Sendable (_ sessions: [AgentSession], _ status: Status) -> Void)?

    init(activeWindow: TimeInterval = 600, waitingWindow: TimeInterval = 120, interval: TimeInterval = 1.0) {
        self.activeWindow = activeWindow
        self.waitingWindow = waitingWindow
        self.interval = interval
    }

    private final class Tracked {
        let path: String
        let agent: AgentKind
        let fileID: String
        var state: TranscriptState
        var offset: UInt64 = 0
        var carry = Data()
        var dropFirst = false
        var initialized = false
        var mtime: Date
        /// When the session last did something: the file's time when a read brought a line with its own `timestamp` (a turn, a tool's
        /// progress, a request). Lines without one are bookkeeping (last-prompt, cost-state, mode, session-owner…) that VS Code writes into
        /// every chat it reopens on a restart: they change the file but say nothing about the agent, so they leave this as it was.
        /// Nil: nothing real seen yet.
        var activity: Date?

        init(path: String, agent: AgentKind, mtime: Date) {
            self.path = path
            self.agent = agent
            self.mtime = mtime
            state = TranscriptState(agent: agent)
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            // Codex names its files rollout-<timestamp>-<uuid>; the session id is the uuid.
            fileID = agent == .codex && name.count >= 36 ? String(name.suffix(36)) : name
        }

        var sessionID: String { state.codexID ?? fileID }
    }

    // MARK: Control

    func setSources(_ new: [Source]) {
        queue.async { [self] in
            guard new != sources else { return }
            sources = new
            files = files.filter { entry in new.contains { entry.value.path.hasPrefix($0.root.path) } }
            restartStream()
            lastSweep = .distantPast
            if running { tickNow() }
        }
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.2, repeating: interval, leeway: .milliseconds(200))
            t.setEventHandler { [weak self] in self?.tickNow() }
            t.resume()
            timer = t
            restartStream()
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            timer?.cancel()
            timer = nil
            stopStream()
            files = [:]
            dirty = []
            lastDelivered = []
            lastStatus = Status()
        }
    }

    /// One full pass right now (tests): sweep, read, prune, and return the sessions. Delivers nothing.
    func scanNow(now: Date = Date()) -> [AgentSession] {
        queue.sync {
            sweepAll(now)
            lastSweep = now
            return refreshAndBuild(now)
        }
    }

    var currentStatus: Status { queue.sync { makeStatus(sessions: lastDelivered.count) } }

    // MARK: The pass

    private func tickNow() {
        let now = Date()
        let dirs = dirty
        dirty = []
        for d in dirs { sweepDirectory(URL(fileURLWithPath: d), now: now) }
        let every: TimeInterval = stream != nil ? 20 : 4
        if now.timeIntervalSince(lastSweep) >= every {
            sweepAll(now)
            lastSweep = now
            if stream == nil { restartStream() }
        }
        let sessions = refreshAndBuild(now)
        let status = makeStatus(sessions: sessions.count)
        guard sessions != lastDelivered || status != lastStatus else { return }
        lastDelivered = sessions
        lastStatus = status
        guard let onChange else { return }
        callbackQueue.async { onChange(sessions, status) }
    }

    private func makeStatus(sessions: Int) -> Status {
        Status(access: access, tracked: files.count, sessions: sessions, watching: stream != nil, lastSweep: lastSweep == .distantPast ? nil : lastSweep)
    }

    /// How long a finished agent stays before it is taken as closed.
    static let closedAfter: TimeInterval = 300

    // MARK: Open chats

    /// Claude Code keeps one small file per running chat in `~/.claude/sessions/<pid>.json` (its process id and the session it has open).
    /// A session named there whose process still runs is OPEN: it shows however long it has been quiet, and from the first look after Scout
    /// starts.
    /// A chat that is closed leaves as before.
    struct OpenChat: Equatable, Sendable {
        var sessionID: String
        var pid: Int32
        var status: String
    }

    /// The open chats in the registry folder next to `root` (`~/.claude/projects` → `~/.claude/sessions`).
    static func openChats(registry: URL, alive: (Int32) -> Bool = OpenChatProcess.isRunning) -> [String: OpenChat] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: registry.path) else { return [:] }
        var out: [String: OpenChat] = [:]
        for name in names where name.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: registry.appendingPathComponent(name).path), data.count < 64_000,
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = o["sessionId"] as? String, !id.isEmpty, let pid = (o["pid"] as? NSNumber)?.int32Value, pid > 0, alive(pid) else { continue }
            out[id] = OpenChat(sessionID: id, pid: pid, status: o["status"] as? String ?? "")
        }
        return out
    }

    /// The registry folder for a source (Claude Code only; Codex keeps none).
    static func registry(for source: Source) -> URL? {
        source.agent == .claude ? source.root.deletingLastPathComponent().appendingPathComponent("sessions") : nil
    }

    /// Makes sure every open chat's transcript is followed, however old the file (it may have been quiet for hours).
    private func trackOpenChats(_ open: [String: OpenChat], _ now: Date) {
        let tracked = Set(files.values.map(\.sessionID))
        let missing = open.keys.filter { !tracked.contains($0) }
        guard !missing.isEmpty else { return }
        for source in sources where source.agent == .claude {
            guard let projects = try? FileManager.default.contentsOfDirectory(atPath: source.root.path) else { continue }
            for id in missing {
                for project in projects {
                    let url = source.root.appendingPathComponent(project).appendingPathComponent(id + ".jsonl")
                    guard files[url.path] == nil, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                          let mtime = attrs[.modificationDate] as? Date else { continue }
                    files[url.path] = Tracked(path: url.path, agent: .claude, mtime: mtime)
                    break
                }
            }
        }
    }

    private func refreshAndBuild(_ now: Date) -> [AgentSession] {
        let open = sources.compactMap(Self.registry(for:)).reduce(into: [String: OpenChat]()) { $0.merge(Self.openChats(registry: $1)) { a, _ in a } }
        trackOpenChats(open, now)
        let cutoff = now.addingTimeInterval(-activeWindow)
        for (path, t) in files {
            guard refresh(t) else { files[path] = nil; continue }
            if t.mtime < cutoff, open[t.sessionID] == nil { files[path] = nil }   // an open chat stays followed however quiet
        }
        var best: [String: AgentSession] = [:]
        for t in files.values where !t.state.isHelperTranscript && (t.state.sawActivity || !t.state.cwd.isEmpty) {
            // Only real lines count: a file changed by bookkeeping alone (a VS Code restart reopening old chats) brings nobody back.
            let isOpen = open[t.sessionID] != nil
            guard let active = t.activity ?? (isOpen ? t.mtime : nil), isOpen || now.timeIntervalSince(active) <= activeWindow else { continue }
            // A finished agent (its turn over) with nothing new for five minutes is taken as closed and leaves; a new line brings it back.
            // Nothing tells Scout that a session window was closed, so this is the sign.
            // One that died mid-turn
            // goes when its file is older than `activeWindow`.
            if t.state.turnEnded, !isOpen, now.timeIntervalSince(active) > Self.closedAfter { continue }
            var s = t.state.session(id: t.sessionID, mtime: active, now: now, waitingWindow: waitingWindow)
            // Claude Code says the chat is busy (a long build or tool run writes nothing for many minutes): it works, it is not stuck.
            // A finished turn wins.
            if let chat = open[t.sessionID], chat.status == "busy", !t.state.turnEnded, s.state == .idle { s.state = .working }
            // Helpers at work: also the ones whose own transcript (<session>/subagents/) changed lately. The transcript's own record of a
            // background helper can lie before the part Scout read when it started (a long chat's file is hundreds of MB), and then no helper
            // showed under its agent.
            if t.agent == .claude { s.subagents = max(s.subagents, Self.activeHelperFiles(next: t.path, now: now)) }
            if let old = best[s.id], old.lastEventAt >= s.lastEventAt { continue }
            best[s.id] = s
        }
        return Array(best.values.sorted { $0.lastEventAt > $1.lastEventAt }.prefix(16))
    }

    // MARK: Finding files

    private static func accessState(_ error: Error) -> Access {
        let ns = error as NSError
        if ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT)) { return .missing }
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError, under.domain == NSPOSIXErrorDomain, under.code == Int(ENOENT) { return .missing }
        return .denied
    }

    private func sweepAll(_ now: Date) {
        for source in sources {
            switch source.agent {
            case .claude: sweepClaude(source.root, now)
            case .codex: sweepCodex(source.root, now)
            }
        }
    }

    private func sweepClaude(_ root: URL, _ now: Date) {
        do {
            let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
            access[.claude] = .ok
            for child in children {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                if values?.isDirectory == true { sweepDirectory(child, now: now) } else { consider(child, .claude, values?.contentModificationDate, now) }
            }
        } catch {
            access[.claude] = Self.accessState(error)
        }
    }

    private func sweepCodex(_ root: URL, _ now: Date) {
        let fm = FileManager.default
        do {
            let years = try fm.contentsOfDirectory(atPath: root.path)
            access[.codex] = .ok
            let cutoffDay = Calendar.current.startOfDay(for: now.addingTimeInterval(-activeWindow - 86_400))
            for y in years.compactMap({ Int($0) }) {
                for m in ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(String(y)).path)) ?? []).compactMap({ Int($0) }) {
                    let monthDir = root.appendingPathComponent(String(y)).appendingPathComponent(String(format: "%02d", m))
                    for d in ((try? fm.contentsOfDirectory(atPath: monthDir.path)) ?? []).compactMap({ Int($0) }) {
                        var comps = DateComponents(); comps.year = y; comps.month = m; comps.day = d
                        guard let day = Calendar.current.date(from: comps), day >= cutoffDay else { continue }
                        sweepDirectory(monthDir.appendingPathComponent(String(format: "%02d", d)), now: now)
                    }
                }
            }
        } catch {
            access[.codex] = Self.accessState(error)
        }
    }

    /// Looks at the `.jsonl` files of one folder.
    private func sweepDirectory(_ dir: URL, now: Date) {
        guard let agent = agentFor(dir.path), !isHelperPath(dir.path) else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        for entry in entries where entry.pathExtension == "jsonl" {
            let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            if values?.isDirectory == true { continue }
            consider(entry, agent, values?.contentModificationDate, now)
        }
    }

    private func agentFor(_ path: String) -> AgentKind? {
        sources.first { path == $0.root.path || path.hasPrefix($0.root.path + "/") }?.agent
    }

    /// Every file that can become a session goes through here.
    private func consider(_ url: URL, _ agent: AgentKind, _ mtime: Date?, _ now: Date) {
        guard url.pathExtension == "jsonl", !isHelperPath(url.path), let mtime, files[url.path] == nil, now.timeIntervalSince(mtime) <= activeWindow else { return }
        files[url.path] = Tracked(path: url.path, agent: agent, mtime: mtime)
    }

    /// Folder names Claude Code keeps a session's helpers in (below the project folder).
    static let helperFolders: Set<String> = ["subagents"]

    /// A helper whose transcript changed within this long is taken as at work.
    static let helperActiveWindow: TimeInterval = 120

    /// How many of a Claude Code session's helpers wrote to their own transcript lately: `<project>/<session>.jsonl` keeps its helpers in
    /// `<project>/<session>/subagents/*.jsonl`. Only names and modification dates are read.
    static func activeHelperFiles(next sessionFile: String, now: Date) -> Int {
        let folder = URL(fileURLWithPath: sessionFile).deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return 0 }
        return items.filter { url in
            guard url.pathExtension == "jsonl", let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return false }
            return now.timeIntervalSince(m) <= helperActiveWindow
        }.count
    }

    /// True when `path` is inside a helper folder, counted from the watched folder down (a watched folder that happens to be called
    /// `subagents` is still fine).
    static func isHelperPath(_ path: String, below root: String) -> Bool {
        guard path.hasPrefix(root) else { return false }
        return path.dropFirst(root.count).split(separator: "/").contains { helperFolders.contains(String($0)) }
    }

    private func isHelperPath(_ path: String) -> Bool {
        guard let source = sources.first(where: { path == $0.root.path || path.hasPrefix($0.root.path + "/") }) else { return false }
        return Self.isHelperPath(path, below: source.root.path)
    }

    // MARK: Reading

    /// Reads what a file gained since last time. False when the file is gone.
    private func refresh(_ t: Tracked) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: t.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return false }
        t.mtime = (attributes[.modificationDate] as? Date) ?? t.mtime
        if size < t.offset {           // the file was replaced or shortened: start over
            t.state = TranscriptState(agent: t.agent)
            t.offset = 0; t.carry = Data(); t.initialized = false; t.dropFirst = false
        }
        let first = !t.initialized   // the first read of this file (or of its new contents after it was replaced)
        if !t.initialized {
            t.initialized = true
            if size > initialTail { t.offset = size - initialTail; t.dropFirst = true }
        }
        guard size > t.offset else { return true }
        if size - t.offset > maxRead { t.offset = size - maxRead; t.carry = Data(); t.dropFirst = true }
        guard let handle = FileHandle(forReadingAtPath: t.path) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: t.offset)
            guard let chunk = try handle.read(upToCount: Int(size - t.offset)), !chunk.isEmpty else { return true }
            t.offset += UInt64(chunk.count)
            t.carry.append(chunk)
        } catch {
            return true
        }
        var start = t.carry.startIndex
        var sawStamp = false, lastStamped = false
        while let newline = t.carry[start...].firstIndex(of: 0x0A) {
            let line = t.carry[start..<newline]
            start = t.carry.index(after: newline)
            if t.dropFirst { t.dropFirst = false; continue }
            guard !line.isEmpty else { continue }
            let data = Data(line)
            lastStamped = t.state.noteStamp(data)
            sawStamp = sawStamp || lastStamped
            if TranscriptState.isInteresting(data, agent: t.agent) { t.state.ingest(data) }
        }
        // The first read of a file (Scout just started, or the file just came back into view) whose last lines are bookkeeping: the
        // session last did something when its last real line says, not when the file changed. Every later read with a real line: now.
        if first {
            t.activity = lastStamped ? t.mtime : t.state.lastStampAt.map { min($0, t.mtime) }
        } else if sawStamp {
            t.activity = t.mtime
        }
        t.carry = Data(t.carry[start...])
        if t.carry.count > 20_000_000 { t.carry = Data(); t.dropFirst = true }
        return true
    }

    // MARK: FSEvents

    private func stopStream() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    private func restartStream() {
        stopStream()
        guard running else { return }
        let paths = sources.map(\.root.path).filter { FileManager.default.isReadableFile(atPath: $0) }
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let scanner = Unmanaged<AgentScanner>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            scanner.changed(Array(list.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        if FSEventStreamStart(s) { stream = s } else { FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
    }

    /// Runs on the scanner queue (the stream's dispatch queue).
    fileprivate func changed(_ paths: [String]) {
        guard running else { return }
        markDirty(paths)
        tickNow()
    }

    /// The folders to look at again after file events. Anything in a helper folder (a helper's transcript, its meta file, the folder
    /// itself being made) is not a session's business and marks nothing.
    private func markDirty(_ paths: [String]) {
        for p in paths where !isHelperPath(p) {
            if p.hasSuffix(".jsonl") { dirty.insert((p as NSString).deletingLastPathComponent) } else { dirty.insert(p) }
        }
    }

    /// Tests: what a stream callback for `paths` would do, without a stream. Marks the folders, looks at them, and returns the sessions.
    func scanAfterChanges(_ paths: [String], now: Date = Date()) -> [AgentSession] {
        queue.sync {
            markDirty(paths)
            let dirs = dirty
            dirty = []
            for d in dirs { sweepDirectory(URL(fileURLWithPath: d), now: now) }
            return refreshAndBuild(now)
        }
    }
}

/// Whether a process still runs (the open-chat registry can keep the file of a chat whose process crashed). `kill(pid, 0)` sends nothing:
/// 0 = it runs; EPERM = it runs but is not ours to signal (the sandbox may say so too, then the registry file alone counts).
enum OpenChatProcess {
    static func isRunning(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
