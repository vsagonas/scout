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
        AgentsAutoOpen.shared.start()   // the notch opens by itself when an agent needs you
    }

    /// `--headless`: the store, the scanner and the debug commands, and nothing on screen.
    static func startHeadless() { startCore() }

    private static func startCore() {
        AgentsStore.shared.start()
        // Debug commands exist in scripted runs only (never in the shipped app).
        guard ScoutRuntime.isAutomation else { return }
        // scout://agents.demo shows sample sessions and the activity.
        DebugCommands.register("agents.demo") { _ in
            let store = AgentsStore.shared
            store.loadSamples()
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
        // scout://agents.status?out=<file> writes what the transcript reader found (folders, sessions) as JSON.
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

    static func registerSelfTests() {
        registerSummaryTests()
        registerScannerTests()
        registerDashboardTests()
    }

    /// A thread-safe list of what a scanner reported (its callback runs on another queue).
    final class SeenLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }

    // MARK: The reader's own helpers

    private static func registerSummaryTests() {
        FeaturesSelfTest.add("agents: tool summaries (the command, the file, the pattern) for the steps of a session") {
            AgentText.toolSummary(tool: "Edit", input: ["file_path": "/a/b/Converter.swift"]) == "Converter.swift"
                && AgentText.toolSummary(tool: "Bash", input: ["command": "swift build\n-c release"]) == "swift build -c release"
                && AgentText.toolSummary(tool: "Grep", input: ["pattern": "TODO"]) == "TODO"
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
            guard var s = scanner.scanNow(now: now).first, s.id == t.id, s.agent == .claude else { print("  no session"); return false }
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
            let interruptedWing = AgentWingSummary.make(sessions: [interrupted])
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
        FeaturesSelfTest.add("agents scan: the store takes what the scanner found, keeps it up to date, and drops what vanished") {
            let store = AgentsStore()
            var scan = AgentSession(id: "m1", agent: .claude, cwd: "/Users/me/Dev/merge")
            scan.title = "From the transcript"; scan.state = .working
            scan.todos = [AgentTodo(text: "A", active: "Doing A", status: .inProgress)]
            scan.steps = [AgentStep(id: "t1", tool: "Bash", summary: "make", at: Date(), done: false)]
            store.applyScan([scan], status: AgentScanner.Status())
            guard store.sessions.count == 1, store.sessions[0].state == .working, store.sessions[0].todos.count == 1 else { print("  not added"); return false }
            // The transcript says it asks a question: the one session now waits, with what it asks.
            var asking = scan; asking.state = .waiting; asking.note = AgentNote.asking("Which region?")
            store.applyScan([asking], status: AgentScanner.Status())
            guard store.sessions.count == 1, store.sessions[0].state == .waiting, AgentWingSummary.asks(store.sessions[0]), store.waitingCount == 1,
                  store.sessions[0].title == "From the transcript" else { print("  question not taken"); return false }
            // Gone from the scan: the session goes.
            store.applyScan([], status: AgentScanner.Status())
            return store.sessions.isEmpty
        }
        FeaturesSelfTest.add("agents scan: a file created after the scanner started is found by itself (FSEvents or the sweep)") {
            let root = sandbox("scan-claude-live")
            try? FileManager.default.createDirectory(at: root.appendingPathComponent("p"), withIntermediateDirectories: true)
            let box = SeenLog()
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
            let store = AgentsStore(isShared: true)
            let center = LiveActivityCenter.shared
            let before = center.cards.count
            store.applyScan([working], status: AgentScanner.Status())
            store.applyScan([done], status: AgentScanner.Status())
            var longRun = longDone; longRun.state = .working; longRun.finishedAt = nil
            store.applyScan([longRun], status: AgentScanner.Status())
            store.applyScan([longDone], status: AgentScanner.Status())
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
            let working = AgentWingSummary.make(sessions: [all[0], all[1], all[3]])
            guard working.working == 3, working.needs == 0, working.right == .progress(done: 2, total: 5), working.lines.count == 3,
                  working.faces.count == 3, working.faces.allSatisfy({ $0.mood == .working }), working.moreFaces == 0 else { print("  working: \(working)"); return false }
            let asking = AgentWingSummary.make(sessions: [all[0], all[1], all[5]])
            guard asking.working == 2, asking.needs == 1, asking.right == .message("Which region?", asks: true), asking.lines.first?.attention == true,
                  asking.faces.count == 3, asking.faces.contains(where: { $0.mood == .asking && $0.agent == .codex }) else { print("  asking: \(asking)"); return false }   // faces keep the fixed order
            let noList = AgentWingSummary.make(sessions: [all[3]])
            guard noList.right == .none, noList.faces.count == 1, noList.faces[0].mood == .working else { print("  no list, no timer: \(noList)"); return false }
            let turn = AgentWingSummary.make(sessions: [all[2]])
            guard turn.right == .message("The summary is in notes/summary.md.", asks: false), turn.working == 0, turn.needs == 0, turn.faces.first?.mood == .finished else { print("  turn end: \(turn)"); return false }
            let mixed = AgentWingSummary.make(sessions: [all[0], all[2]])
            guard mixed.right == .message("The summary is in notes/summary.md.", asks: false), mixed.faces.map(\.mood) == [.working, .finished] else { print("  mixed: \(mixed)"); return false }
            let crowd = AgentWingSummary.make(sessions: all)
            guard crowd.faces.count == 4, crowd.moreFaces == 2, crowd.faces.contains(where: { $0.mood == .asking }) else { print("  crowd: \(crowd)"); return false }   // the one asking is among the four
            let done = AgentWingSummary.make(sessions: [all[4]])
            guard done.right == .allDone, done.faces.count == 1, done.faces[0].mood == .finished else { print("  all done: \(done)"); return false }
            let none = AgentWingSummary.make(sessions: [])
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

    // MARK: Gallery

    private static func previewGrid(_ count: Int) -> AgentsStore {
        let store = AgentsStore()
        store.loadSessions(AgentSession.synthetic(count))
        store.previewDoneToday(5)
        store.previewScan(.init(access: [.claude: .ok, .codex: .ok], tracked: count, sessions: count, watching: true, lastSweep: Date()))
        return store
    }

    private static func previewStore(selecting: String? = nil) -> AgentsStore {
        let store = AgentsStore()
        store.loadSamples(selecting: selecting)
        store.previewScan(.init(access: [.claude: .ok, .codex: .missing], tracked: 3, sessions: 3, watching: true, lastSweep: Date()))
        return store
    }

    static func registerGallery() {
        enableInNotch()   // the gallery's isolated settings may hold a list saved without Agents
        AgentsAutoOpenGallery.register()   // auto-*: the notch opening by itself over the Agents view, and the lit dashboard row
        AgentNookGallery.register()   // the AgentNook pictures (Features/Agents/Nook)
        let working = previewStore()
        let waiting = previewStore(selecting: "demo-2")
        let done = previewStore(selecting: "demo-3")
        let empty = AgentsStore()
        // The Agents workspace with one agent's window open.
        FeatureGallery.workspace("agents-workspace", height: 150) { AgentsWorkspaceView(store: working, detail: "demo-1") }
        FeatureGallery.workspace("agents-workspace-waiting", height: 150) { AgentsWorkspaceView(store: waiting, detail: "demo-2") }
        FeatureGallery.workspace("agents-workspace-done", height: 150) { AgentsWorkspaceView(store: done, detail: "demo-3") }
        // The Agents workspace with 1, 3 and 6 sessions.
        let grid1 = previewGrid(1)
        let grid3 = previewGrid(3)
        let grid6 = previewGrid(6)
        FeatureGallery.workspace("agents-grid-1", width: 988, height: 142) { AgentsWorkspaceView(store: grid1) }
        FeatureGallery.workspace("agents-grid-3", width: 988, height: 142) { AgentsWorkspaceView(store: grid3) }
        FeatureGallery.workspace("agents-grid-6", width: 988, height: 246) { AgentsWorkspaceView(store: grid6) }
        // The Nook as the agentic dashboard: what plays, what is open and what runs decide what shows.
        func nook(_ name: String, live: NookLive, sessions: Int, asking: Bool = false, playing: Bool) {
            let store = previewGrid(sessions)
            if asking { store.loadSessions([AgentSession.synthetic(6)[5]]) }   // the one that asks a question
            let row = NookStore(persist: false, layout: WidgetKind.defaultLayout)
            row.liveOverride = live
            FeatureGallery.workspace("nook-agentic-\(name)", width: 988, height: 150) {
                let _ = AgentsStore.shared.loadSessions(store.sessions)
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
        FeatureGallery.widget("agents-widget-6cells", span: 6) { AgentsWidgetView(store: grid3) }
        FeatureGallery.widget("agents-widget-12cells", span: 12) { AgentsWidgetView(store: grid6) }
        FeatureGallery.widget("agents-widget-empty", span: 3) { AgentsWidgetView(store: empty) }
        FeatureGallery.workspace("agents-workspace-empty", height: 150) { AgentsWorkspaceView(store: empty) }
        // The real open notch (header, 200 pt) around the workspace.
        Gallery.register("agents-notch-open", size: CGSize(width: 1120, height: 330)) {
            let _ = AgentsStore.shared.loadSamples(selecting: "demo-1")
            NotchScene(size: CGSize(width: 1120, height: 330), open: true, workspace: .agents, openHeight: 200)
        }
        // The closed notch: left the glyph and counts, right the most important session, and (hovering) one line per agent.
        let all6 = AgentSession.synthetic(6)
        func wingsStore(_ picks: [Int], done: Bool = false) -> AgentsStore {
            let store = AgentsStore()
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
        wings("agents-wings-1-working", wingsStore([0]))
        wings("agents-wings-3-working", wingsStore([0, 1, 3]))
        wings("agents-wings-needs-you", wingsStore([0, 1, 5]))
        wings("agents-wings-all-done", wingsStore([4, 2], done: true))
        wings("agents-wings-your-move", wingsStore([0, 2]))
        wings("agents-wings-timerless", wingsStore([3, 2]))
        wings("agents-wings-six", wingsStore([0, 1, 2, 3, 4, 5]))
        // The REAL closed notch (NotchRootView) at the 16-inch notch, the camera housing outlined in red: nothing may sit inside it.
        func closedNotch(_ name: String, _ store: AgentsStore, rest: Bool = false) {
            Gallery.register(name, size: CGSize(width: 520, height: 44), backdrop: .screenTop) {
                AgentsClosedNotchPreview(store: store, size: CGSize(width: 520, height: 44), rest: rest)
            }
        }
        closedNotch("agents-notch-closed-1-rest", wingsStore([0]), rest: true)
        closedNotch("agents-notch-closed-2-rest", wingsStore([0, 1]), rest: true)
        closedNotch("agents-notch-closed-4-rest", wingsStore([0, 1, 3, 5]), rest: true)
        closedNotch("agents-notch-closed-2-news", wingsStore([0, 1]))
        closedNotch("agents-notch-closed-6-news", wingsStore([0, 1, 2, 3, 4, 5]))
        // The owner, 2026-11-18: the two-line message shows the whole sentence, the wing exactly as wide as it needs (no empty space).
        for (name, message) in [("long", "The new release is in review at the store, and it goes live by itself when it is approved, so nothing waits on you now."),
                                ("mid", "I changed the footer links and pushed the branch.")] {
            Gallery.register("agents-notch-closed-\(name)", size: CGSize(width: 1000, height: 44), backdrop: .screenTop) {
                let store = AgentsStore()
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
        // The Settings page leads with "Scout finds Claude Code and Codex sessions by itself"; the App Store edition may have to ask once.
        let deniedStore = AgentsStore()
        deniedStore.previewScan(.init(access: [.claude: .denied, .codex: .missing], tracked: 0, sessions: 0, watching: false, lastSweep: Date()))
        FeatureGallery.settings("agents-scan-settings", height: 460) { AgentsSettingsPane(store: grid3) }
        FeatureGallery.settings("agents-scan-settings-denied", height: 500) { AgentsSettingsPane(store: deniedStore) }
        FeatureGallery.workspace("agents-scan-empty-denied", width: 988, height: 150) { AgentsWorkspaceView(store: deniedStore) }
        FeatureGallery.workspace("agents-scan-empty", width: 988, height: 150) { AgentsWorkspaceView(store: empty) }
        FeatureGallery.settings("agents-settings", height: 460) { AgentsSettingsPane(store: working) }
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
