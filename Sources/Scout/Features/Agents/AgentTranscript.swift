import Foundation

/// Plain text helpers that are safe on any thread (the transcript reader runs off the main thread).
enum AgentText {
    static func shorten(_ s: String, _ n: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > n ? String(flat.prefix(n - 1)) + "…" : flat
    }

    /// A short line for a tool call: the command, the file, the pattern…
    static func toolSummary(tool: String, input: [String: Any]?) -> String {
        guard let input else { return tool }
        func base(_ key: String) -> String? { (input[key] as? String).map { ($0 as NSString).lastPathComponent } }
        switch tool {
        case "Bash": return (input["command"] as? String).map { $0.replacingOccurrences(of: "\n", with: " ") } ?? "Bash"
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit": return base("file_path") ?? base("notebook_path") ?? tool
        case "Grep", "Glob": return (input["pattern"] as? String) ?? tool
        case "WebFetch": return (input["url"] as? String) ?? tool
        case "WebSearch": return (input["query"] as? String) ?? tool
        case "Task", "Agent": return (input["description"] as? String) ?? (input["subagent_type"] as? String) ?? tool
        case "TodoWrite": return String(localized: "Updating the to-do list")
        default:
            if let command = input["command"] as? String { return command }
            if let first = input.values.compactMap({ $0 as? String }).first { return String(first.prefix(120)) }
            return tool
        }
    }

    /// Words that end in a full stop without ending the sentence.
    private static let abbreviations: Set<String> = ["e.g", "i.e", "etc", "vs", "mr", "mrs", "ms", "dr", "no", "fig", "approx", "cf", "st"]

    /// The FIRST SENTENCE of an agent's message, on one line, and nothing else (the dashboard shows only this, and the scanner
    /// keeps only this in memory, never the whole text). A sentence ends at . ! ? followed by a space or the end, or at the first
    /// line break; markdown marks, list bullets and quote marks in front are dropped; a file name (`a.swift`), a number (3.5)
    /// or an abbreviation (e.g.) does not end it. Over `limit` characters it ends with an ellipsis.
    static func firstSentence(_ text: String, limit: Int = 140) -> String {
        // The first paragraph, joined onto one line (a sentence may wrap across lines), but never past the first heading,
        // bullet or code fence after it.
        var line = ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(raw).trimmingCharacters(in: .whitespaces)
            let isMark = trimmed.hasPrefix("```") || (!trimmed.isEmpty && trimmed.allSatisfy { "-=*_#> |".contains($0) })
            if line.isEmpty {
                if trimmed.isEmpty || isMark { continue }
            } else if trimmed.isEmpty || isMark || trimmed.hasPrefix("#") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                break
            }
            line += (line.isEmpty ? "" : " ") + trimmed
            if line.count > 400 { break }
        }
        while let first = line.first, "#>*-+•·_ `\"".contains(first) { line.removeFirst() }
        if let marker = line.range(of: #"^\d{1,2}[.)]\s+"#, options: .regularExpression) { line.removeSubrange(marker) }   // "2. " in a numbered list
        line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
        let chars = Array(line)
        var end = chars.count
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "." || c == "!" || c == "?" {
                var j = i
                while j + 1 < chars.count, ".!?".contains(chars[j + 1]) { j += 1 }
                let atEnd = j + 1 >= chars.count
                let spaced = !atEnd && (chars[j + 1] == " " || chars[j + 1] == "\"" || chars[j + 1] == ")")
                if atEnd || spaced {
                    var k = i
                    while k > 0, chars[k - 1] != " " { k -= 1 }
                    let word = String(chars[k..<i]).lowercased()
                    let abbreviation = c == "." && (abbreviations.contains(word) || (word.count == 1 && word.first?.isLetter == true))
                    if !abbreviation { end = j + 1; break }
                }
                i = j
            }
            i += 1
        }
        let sentence = String(chars[0..<min(end, chars.count)]).trimmingCharacters(in: .whitespaces)
        return sentence.count > limit ? String(sentence.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : sentence
    }
}

/// What one transcript file says about its session, built line by line.
///
/// Claude Code (`~/.claude/projects/<project>/<session>.jsonl`), one JSON object per line. Fields relied on:
/// `type` (user, assistant, ai-title, last-prompt; everything else is skipped), `cwd`, `timestamp`, `isSidechain`, `isMeta`,
/// `message.content` (a string, or blocks: `text`, `tool_use` {id, name, input}, `tool_result` {tool_use_id, is_error}),
/// `message.stop_reason` (`end_turn` ends a turn), `aiTitle`, `lastPrompt`.
///
/// Codex (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`): `{timestamp, type, payload}` with `type` session_meta, turn_context,
/// event_msg and response_item. Fields relied on: `payload.id`, `payload.cwd`, `payload.type` (task_started, task_complete,
/// turn_aborted, user_message, agent_message, exec_command_begin/end, patch_apply_begin/end, mcp_tool_call_begin/end,
/// web_search_begin/end, plan_update, function_call, function_call_output, local_shell_call, custom_tool_call(_output)),
/// `payload.message`, `payload.call_id`, `payload.command`, `payload.plan`.
///
/// Only short summaries (a prompt, a tool's name and one-line input, the first sentence of the last answer) are kept, in memory.
struct TranscriptState {
    var agent: AgentKind
    var cwd = ""
    var title = ""
    var fallbackTitle = ""
    var started: Date?
    var turnStart: Date?
    var lastLineAt: Date?
    /// The newest `timestamp` any line of the file carries (bookkeeping lines carry none). See `AgentScanner.Tracked.activity`.
    var lastStampAt: Date?
    var turnEnded = false
    /// The turn ended because the person interrupted it (Esc, or Enter with a new message while the agent worked): not a finish, so no
    /// "finished" message is shown for it.
    var interrupted = false
    var sawActivity = false
    /// Lines that said they are a helper's own (`isSidechain`); skipped. A file with only such lines is a helper's transcript, not a session.
    var sidechainLines = 0
    var steps: [AgentStep] = []
    var openIDs: Set<String> = []
    var helperIDs: Set<String> = []
    /// Helpers started in the background (`run_in_background`): their tool call ends at once ("launched") and the turn may end too, but
    /// they work on until a task notification says they are done.
    /// When each started.
    var backgroundHelpers: [String: Date] = [:]
    var todos: [AgentTodo] = []
    var lastMessage = ""
    var questionID: String?
    var question: String?
    /// Codex: the session's own id from its first line.
    var codexID: String?

    init(agent: AgentKind) { self.agent = agent }

    /// Only a helper's lines so far: this file is a helper's transcript, never an agent of its own.
    var isHelperTranscript: Bool { sidechainLines > 0 && !sawActivity && cwd.isEmpty }

    // MARK: Feeding lines

    /// One transcript line (without its newline).
    mutating func ingest(_ line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        switch agent {
        case .claude: ingestClaude(object)
        case .codex: ingestCodex(object)
        }
        if steps.count > 60 { steps.removeFirst(steps.count - 60) }
    }

    /// Notes the line's own `timestamp` (read without decoding the line, so it is cheap for every line). True when it has one.
    /// Claude Code writes the line's own timestamp after its message (a message may quote others), Codex writes it first.
    @discardableResult
    mutating func noteStamp(_ line: Data) -> Bool {
        guard let when = Self.stamp(in: line, agent: agent) else { return false }
        if lastStampAt == nil || when > lastStampAt! { lastStampAt = when }
        return true
    }

    static func stamp(in line: Data, agent: AgentKind) -> Date? {
        let key = Data("\"timestamp\":\"".utf8)
        guard let r = line.range(of: key, options: agent == .claude ? .backwards : [], in: line.startIndex..<line.endIndex) else { return nil }
        let start = r.upperBound
        let end = line.index(start, offsetBy: 40, limitedBy: line.endIndex) ?? line.endIndex
        guard let quote = line[start..<end].firstIndex(of: 0x22) else { return nil }
        return date(String(decoding: line[start..<quote], as: UTF8.self))
    }

    /// True when a line is worth parsing at all (the big blobs and bookkeeping lines are skipped without decoding).
    static func isInteresting(_ line: Data, agent: AgentKind) -> Bool {
        if line.count > 2_000_000 { return false }
        let markers: [String] = agent == .claude
            ? ["\"user\"", "\"assistant\"", "\"ai-title\"", "\"last-prompt\""]
            : ["\"session_meta\"", "\"event_msg\"", "\"response_item\"", "\"turn_context\""]
        return markers.contains { line.range(of: Data($0.utf8)) != nil }
    }

    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoPlain = ISO8601DateFormatter()

    static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    private mutating func note(_ when: Date?) {
        guard let when else { return }
        if started == nil { started = when }
        if lastLineAt == nil || when > lastLineAt! { lastLineAt = when }
    }

    // MARK: Steps

    private mutating func open(_ id: String, tool: String, summary: String, at: Date?) {
        guard !id.isEmpty else { return }
        if !steps.contains(where: { $0.id == id }) {
            steps.append(AgentStep(id: id, tool: tool, summary: AgentText.shorten(summary, 120), at: at ?? Date(), done: false))
        }
        openIDs.insert(id)
        sawActivity = true
    }

    private mutating func close(_ id: String, failed: Bool = false) {
        if let i = steps.firstIndex(where: { $0.id == id }) { steps[i].done = true; steps[i].failed = failed }
        openIDs.remove(id)
        helperIDs.remove(id)
        if id == questionID { question = nil; questionID = nil }
    }

    /// The turn is over: nothing is running any more.
    private mutating func finishTurn() {
        turnEnded = true
        for i in steps.indices { steps[i].done = true }
        openIDs.removeAll()
        helperIDs.removeAll()
    }

    private mutating func prompt(_ text: String, at: Date?) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        title = AgentText.shorten(clean, 90)
        turnStart = at ?? turnStart
        turnEnded = false
        interrupted = false
        sawActivity = true
        question = nil
        questionID = nil
        steps.append(AgentStep(id: UUID().uuidString, tool: "Prompt", summary: AgentText.shorten(clean, 90), at: at ?? Date(), done: true))
    }

    // MARK: Claude Code

    private mutating func ingestClaude(_ o: [String: Any]) {
        let type = o["type"] as? String ?? ""
        if type == "ai-title" { if let t = o["aiTitle"] as? String, !t.isEmpty { fallbackTitle = AgentText.shorten(t, 90) }; return }
        if type == "last-prompt" { if fallbackTitle.isEmpty, let t = o["lastPrompt"] as? String { fallbackTitle = AgentText.shorten(t, 90) }; return }
        guard type == "user" || type == "assistant" else { return }
        if (o["isSidechain"] as? Bool) == true { sidechainLines += 1; return }       // a helper's own lines (a helper's own file, or inline in older Claude Code versions)
        let when = Self.date(o["timestamp"])
        note(when)
        if let c = o["cwd"] as? String, !c.isEmpty { cwd = c }
        guard let message = o["message"] as? [String: Any] else { return }
        if type == "assistant" {
            claudeAssistant(message, at: when)
        } else {
            claudeUser(message, meta: (o["isMeta"] as? Bool) == true, at: when)
        }
    }

    private mutating func claudeAssistant(_ message: [String: Any], at when: Date?) {
        sawActivity = true
        let blocks = (message["content"] as? [[String: Any]]) ?? []
        for block in blocks {
            switch block["type"] as? String ?? "" {
            case "text":
                if let t = block["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lastMessage = AgentText.firstSentence(t) }
            case "tool_use":
                let id = block["id"] as? String ?? ""
                let name = block["name"] as? String ?? "Tool"
                let input = block["input"] as? [String: Any]
                switch name {
                case "AskUserQuestion":
                    let first = ((input?["questions"] as? [[String: Any]])?.first?["question"] as? String) ?? String(localized: "A question")
                    question = AgentText.shorten(first, 120)
                    questionID = id
                    openIDs.insert(id)
                case "ExitPlanMode":
                    question = String(localized: "A plan is ready for your approval")
                    questionID = id
                    openIDs.insert(id)
                default:
                    if name == "TodoWrite", let list = AgentTodo.parse(input?["todos"]) { todos = list }
                    if name == "Agent" || name == "Task" {
                        if (input?["run_in_background"] as? Bool) == true { backgroundHelpers[id] = when ?? Date() } else { helperIDs.insert(id) }
                    }
                    open(id, tool: name, summary: AgentText.toolSummary(tool: name, input: input), at: when)
                }
            default:
                break
            }
        }
        // `end_turn` closes a turn; a tool call or an unfinished message keeps it open.
        let stop = message["stop_reason"] as? String
        if stop == "end_turn" || stop == "stop_sequence" || stop == "max_tokens" { finishTurn(); interrupted = false } else { turnEnded = false }
    }

    private mutating func claudeUser(_ message: [String: Any], meta: Bool, at when: Date?) {
        var texts: [String] = []
        if let s = message["content"] as? String {
            texts.append(s)
        } else if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks {
                switch block["type"] as? String ?? "" {
                case "tool_result":
                    if let id = block["tool_use_id"] as? String { close(id, failed: (block["is_error"] as? Bool) == true) }
                case "text":
                    if let t = block["text"] as? String { texts.append(t) }
                default:
                    break
                }
            }
        }
        // A background helper's notification: done, failed or stopped, it leaves the floor. It also wakes the agent for a turn of its own
        // (the agent answers it), so a finished agent is at work again from this line on, and that turn is timed from here, not from its
        // last prompt. Without this the answer ("Received.") looked like a turn of the old prompt that ended two seconds after it began.
        for t in texts where t.contains("<task-notification>") {
            guard (Self.between(t, "<status>", "</status>") ?? "completed") != "running" else { continue }
            if let tool = Self.between(t, "<tool-use-id>", "</tool-use-id>") { backgroundHelpers[tool] = nil }
            if turnEnded { turnStart = when ?? turnStart; turnEnded = false; interrupted = false; sawActivity = true }
        }
        guard !meta, !texts.isEmpty else { return }
        let text = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[Request interrupted by user") { finishTurn(); interrupted = true; return }
        if text.hasPrefix("<command-name>") {
            let name = Self.between(text, "<command-name>", "</command-name>") ?? "command"
            let args = Self.between(text, "<command-args>", "</command-args>") ?? ""
            prompt(args.isEmpty ? name : "\(name) \(args)", at: when)
            return
        }
        for skipped in ["<local-command-", "<system-reminder>", "<bash-", "Caveat:", "<command-", "<task-notification>"] where text.hasPrefix(skipped) { return }
        prompt(text, at: when)
    }

    private static func between(_ s: String, _ a: String, _ b: String) -> String? {
        guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return nil }
        return String(s[r1.upperBound..<r2.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Codex

    private static func commandText(_ any: Any?) -> String {
        if let s = any as? String { return s }
        guard let parts = any as? [String], !parts.isEmpty else { return "" }
        if parts.count >= 3, ["bash", "sh", "zsh"].contains((parts[0] as NSString).lastPathComponent), parts[1].hasPrefix("-") { return parts[2] }
        return parts.joined(separator: " ")
    }

    private mutating func ingestCodex(_ o: [String: Any]) {
        let type = o["type"] as? String ?? ""
        let when = Self.date(o["timestamp"])
        note(when)
        let p = o["payload"] as? [String: Any] ?? [:]
        switch type {
        case "session_meta":
            if let c = p["cwd"] as? String, !c.isEmpty { cwd = c }
            if let i = p["id"] as? String, !i.isEmpty { codexID = i }
            if started == nil, let t = Self.date(p["timestamp"]) { started = t }
        case "turn_context":
            if let c = p["cwd"] as? String, !c.isEmpty { cwd = c }
        case "event_msg":
            codexEvent(p, at: when)
        case "response_item":
            codexItem(p, at: when)
        default:
            break
        }
    }

    private mutating func codexEvent(_ p: [String: Any], at when: Date?) {
        let callID = p["call_id"] as? String ?? ""
        switch p["type"] as? String ?? "" {
        case "task_started", "turn_started":
            turnEnded = false; turnStart = when ?? turnStart; sawActivity = true
        case "task_complete", "turn_complete":
            if let m = p["last_agent_message"] as? String, !m.isEmpty { lastMessage = AgentText.firstSentence(m) }
            finishTurn()
        case "turn_aborted":
            finishTurn()
        case "user_message":
            if let m = p["message"] as? String { prompt(m, at: when) }
        case "agent_message":
            if let m = p["message"] as? String, !m.isEmpty { lastMessage = AgentText.firstSentence(m) }
        case "exec_command_begin":
            open(callID, tool: "Bash", summary: Self.commandText(p["command"]), at: when)
        case "exec_command_end":
            close(callID, failed: ((p["exit_code"] as? Int) ?? 0) != 0)
        case "patch_apply_begin":
            let first = (p["changes"] as? [String: Any])?.keys.sorted().first.map { ($0 as NSString).lastPathComponent } ?? String(localized: "files")
            open(callID, tool: "Edit", summary: first, at: when)
        case "patch_apply_end":
            close(callID, failed: (p["success"] as? Bool) == false)
        case "mcp_tool_call_begin":
            let inv = p["invocation"] as? [String: Any]
            open(callID, tool: "MCP", summary: [inv?["server"] as? String, inv?["tool"] as? String].compactMap { $0 }.joined(separator: " · "), at: when)
        case "mcp_tool_call_end":
            close(callID)
        case "web_search_begin":
            open(callID, tool: "WebSearch", summary: (p["query"] as? String) ?? String(localized: "web search"), at: when)
        case "web_search_end":
            close(callID)
        case "plan_update":
            if let list = p["plan"] as? [[String: Any]] { todos = Self.codexPlan(list) }
        default:
            break
        }
    }

    private static func codexPlan(_ list: [[String: Any]]) -> [AgentTodo] {
        list.compactMap { item in
            guard let step = item["step"] as? String else { return nil }
            let status = (item["status"] as? String).flatMap(AgentTodo.Status.init(rawValue:)) ?? .pending
            return AgentTodo(text: step, active: step, status: status)
        }
    }

    private mutating func codexItem(_ p: [String: Any], at when: Date?) {
        let callID = (p["call_id"] as? String) ?? (p["id"] as? String) ?? ""
        switch p["type"] as? String ?? "" {
        case "function_call":
            let name = p["name"] as? String ?? "tool"
            let args = (p["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
            if name == "update_plan", let list = args?["plan"] as? [[String: Any]] { todos = Self.codexPlan(list); return }
            let command = args?["command"] ?? args?["cmd"]
            let shell = ["shell", "container.exec", "exec_command", "shell_command"].contains(name)
            let summary = Self.commandText(command)
            open(callID, tool: shell ? "Bash" : name, summary: summary.isEmpty ? ((args?["path"] as? String) ?? name) : summary, at: when)
        case "local_shell_call":
            open(callID, tool: "Bash", summary: Self.commandText((p["action"] as? [String: Any])?["command"]), at: when)
        case "custom_tool_call":
            let name = p["name"] as? String ?? "tool"
            var summary = name
            if let input = p["input"] as? String, let r = input.range(of: "*** Update File: ") ?? input.range(of: "*** Add File: ") {
                summary = (String(input[r.upperBound...].prefix { $0 != "\n" }) as NSString).lastPathComponent
            }
            open(callID, tool: name == "apply_patch" ? "Edit" : name, summary: summary, at: when)
        case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
            close(callID)
        default:
            break
        }
    }

    // MARK: The session this adds up to

    /// `mtime` is when the file last changed. A finished turn is "waiting for you" for `waitingWindow` seconds, then done.
    func session(id: String, mtime: Date, now: Date, waitingWindow: TimeInterval, stuckAfter: TimeInterval = 600) -> AgentSession {
        let idle = max(0, now.timeIntervalSince(mtime))
        var s = AgentSession(id: id, agent: agent, cwd: cwd)
        s.title = title.isEmpty ? fallbackTitle : title
        s.startedAt = started ?? mtime
        s.lastEventAt = mtime
        s.turnStartedAt = turnStart ?? started ?? mtime
        s.steps = steps
        s.todos = todos
        s.lastMessage = lastMessage
        // Helpers at work: the ones the agent waits for, and the background ones (one that never reported back counts for 3 hours at most).
        let latest = lastLineAt ?? mtime
        s.subagents = helperIDs.count + backgroundHelpers.values.filter { latest.timeIntervalSince($0) < 3 * 3600 }.count
        if let question, questionID != nil {
            s.state = .waiting
            s.note = AgentNote.asking(question)
        } else if turnEnded && interrupted {
            s.state = .idle   // interrupted, not finished: no "your move" message beside the notch; the next prompt makes it work again
        } else if turnEnded {
            s.finishedAt = lastLineAt ?? mtime
            if idle < waitingWindow {
                s.state = .waiting
                s.note = AgentNote.finished
            } else {
                s.state = .done
            }
        } else if !sawActivity || idle > stuckAfter {
            s.state = .idle
        } else {
            s.state = .working
        }
        return s
    }
}
