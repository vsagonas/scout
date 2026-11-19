import Foundation

/// The one hook protocol both editions speak. Each hook is a self-contained shell one-liner (inline `curl`),
/// so there is no script file to install and the same text can be pasted into an agent's settings by hand.
///
/// - Events that only report progress post and forget: `curl -s -m 2 … >/dev/null 2>&1 || true`.
///   The bridge answers at once, and the hook prints NOTHING (a plain stdout would be added to the agent's
///   context on SessionStart and UserPromptSubmit).
/// - Events that wait for you (a permission, a question) print the bridge's answer, but only when it is a JSON
///   object (`grep '^{'`), and always exit 0.
/// - Fail open: Scout not running, not answering, a wrong port, a timeout: empty output and exit 0, so the agent
///   goes on and asks in its own terminal as usual.
enum AgentHooks {
    /// A fixed, unusual port so a pasted config stays valid across launches.
    static let defaultPort: UInt16 = 47231
    /// Scripted runs (`--automation`) use their own port so they never fight the owner's Scout.
    static let automationPort: UInt16 = 47931
    static let tokenHeader = "x-scout-token"
    /// The longest a waiting hook holds the line. The agent's own `timeout` for these hooks is 600 s.
    static let waitSeconds = 590

    /// One hook registration.
    struct Entry: Equatable {
        var event: String
        var matcher: String?
        /// "" = post and forget · "permission" = wait for Allow / Deny · "question" = wait for the answers.
        var mode: String
        var timeout: Int
        var waits: Bool { !mode.isEmpty }
        /// Path under /hook/<agent>/ (the permission event is waiting by its name).
        var path: String { mode == "question" ? "\(event)/question" : event }
    }

    static func entries(for agent: AgentKind) -> [Entry] {
        func e(_ event: String, _ matcher: String? = nil, mode: String = "", timeout: Int = 5) -> Entry { Entry(event: event, matcher: matcher, mode: mode, timeout: timeout) }
        switch agent {
        case .claude:
            return [e("SessionStart"), e("SessionEnd", timeout: 2), e("UserPromptSubmit"),
                    e("PreToolUse"), e("PreToolUse", "AskUserQuestion", mode: "question", timeout: 600),
                    e("PostToolUse"), e("PostToolUseFailure"), e("Notification"), e("Stop"),
                    e("SubagentStart"), e("SubagentStop"),
                    e("PermissionRequest", mode: "permission", timeout: 600)]
        case .codex:
            return [e("SessionStart"), e("SessionEnd", timeout: 2), e("UserPromptSubmit"), e("PreToolUse"), e("PostToolUse"),
                    e("SubagentStart"), e("SubagentStop"), e("Stop"),
                    e("PermissionRequest", mode: "permission", timeout: 600)]
        }
    }

    static func url(_ agent: AgentKind, _ entry: Entry, port: UInt16) -> String {
        "http://127.0.0.1:\(port)/hook/\(agent.rawValue)/\(entry.path)"
    }

    /// The shell command for one registration.
    static func command(_ agent: AgentKind, _ entry: Entry, port: UInt16, token: String) -> String {
        let target = url(agent, entry, port: port)
        let header = "-H '\(tokenHeader): \(token)'"
        if entry.waits {
            return "/usr/bin/curl -s -f --connect-timeout 1 -m \(waitSeconds) \(header) --data-binary @- \(target) 2>/dev/null | /usr/bin/grep -m1 '^{'; exit 0"
        }
        let limit = entry.event == "SessionEnd" ? 1 : 2
        return "/usr/bin/curl -s -m \(limit) \(header) --data-binary @- \(target) >/dev/null 2>&1 || true"
    }

    /// `{ "SessionStart": [ { "matcher"?, "hooks": [ { type, command, timeout } ] } ], … }`, as values (the installer merges these).
    static func hooksObject(_ agent: AgentKind, port: UInt16, token: String) -> [String: [[String: Any]]] {
        var result: [String: [[String: Any]]] = [:]
        for entry in entries(for: agent) {
            var group: [String: Any] = ["hooks": [["type": "command", "command": command(agent, entry, port: port, token: token), "timeout": entry.timeout] as [String: Any]]]
            if let matcher = entry.matcher { group["matcher"] = matcher }
            result[entry.event, default: []].append(group)
        }
        return result
    }

    private static func quoted(_ s: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(s)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    /// The text the App Store edition shows (and the full edition can copy): a complete `{ "hooks": { … } }` block,
    /// in the order of the agent's lifecycle, two-space indented, ready to paste into settings.json / hooks.json.
    static func snippet(_ agent: AgentKind, port: UInt16, token: String) -> String {
        let all = entries(for: agent)
        var events: [String] = []
        for e in all where !events.contains(e.event) { events.append(e.event) }
        var lines = ["{", "  \"hooks\": {"]
        for (ei, event) in events.enumerated() {
            lines.append("    \(quoted(event)): [")
            let group = all.filter { $0.event == event }
            for (gi, e) in group.enumerated() {
                lines.append("      {")
                if let matcher = e.matcher { lines.append("        \"matcher\": \(quoted(matcher)),") }
                lines.append("        \"hooks\": [")
                lines.append("          {")
                lines.append("            \"type\": \"command\",")
                lines.append("            \"command\": \(quoted(command(agent, e, port: port, token: token))),")
                lines.append("            \"timeout\": \(e.timeout)")
                lines.append("          }")
                lines.append("        ]")
                lines.append("      }" + (gi < group.count - 1 ? "," : ""))
            }
            lines.append("    ]" + (ei < events.count - 1 ? "," : ""))
        }
        lines += ["  }", "}"]
        return lines.joined(separator: "\n")
    }

    /// True for a hook command Scout wrote (this protocol, or the older script-based entry).
    static func isScouts(command: String) -> Bool {
        command.contains(tokenHeader) || command.contains("scout-hook")
    }

    /// The port inside one of Scout's commands, or nil for an older script-based entry.
    static func port(inCommand command: String) -> UInt16? {
        guard let range = command.range(of: "http://127.0.0.1:") else { return nil }
        let digits = command[range.upperBound...].prefix { $0.isNumber }
        return UInt16(digits)
    }
}
