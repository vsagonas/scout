import Foundation
import SwiftUI

enum AgentKind: String, Sendable, CaseIterable {
    case claude, codex

    var title: String { self == .claude ? "Claude Code" : "Codex" }
    var symbol: String { self == .claude ? "sparkles" : "chevron.left.forwardslash.chevron.right" }
    var tint: Color { self == .claude ? Color(red: 0.93, green: 0.55, blue: 0.38) : Color(red: 0.45, green: 0.78, blue: 0.62) }
}

/// One line of the agent's own to-do list (Claude Code's TodoWrite tool).
struct AgentTodo: Equatable, Sendable {
    enum Status: String, Sendable { case pending, inProgress = "in_progress", completed }
    var text: String
    var active: String
    var status: Status

    static func parse(_ raw: Any?) -> [AgentTodo]? {
        guard let list = raw as? [[String: Any]] else { return nil }
        return list.compactMap { item in
            guard let text = (item["content"] as? String) ?? (item["subject"] as? String) else { return nil }
            let status = (item["status"] as? String).flatMap(Status.init(rawValue:)) ?? .pending
            return AgentTodo(text: text, active: (item["activeForm"] as? String) ?? text, status: status)
        }
    }
}

struct AgentStep: Identifiable, Equatable {
    var id: String
    var tool: String
    var summary: String
    var at: Date
    var done: Bool
    var failed = false
}

enum AgentState: Equatable {
    case idle, working, waiting, done

    var title: String {
        switch self {
        case .idle: String(localized: "Idle")
        case .working: String(localized: "Working")
        case .waiting: String(localized: "Needs you")
        case .done: String(localized: "Done")
        }
    }

    var color: Color {
        switch self {
        case .idle: .gray
        case .working: .blue
        case .waiting: .orange
        case .done: .green
        }
    }
}

/// What `AgentSession.note` holds. The note is a stable CODE (so a test or a comparison never depends on the language); the words a person
/// reads come from `text(_:)`, in the language of the Mac.
enum AgentNote {
    static let finished = "Finished: waiting for your next message"
    static let askingPrefix = "Asking you:"

    static func asking(_ question: String) -> String { "\(askingPrefix) \(question)" }

    /// The question inside an asking note (nil for any other note).
    static func question(_ note: String) -> String? {
        guard note.hasPrefix(askingPrefix) else { return nil }
        let q = String(note.dropFirst(askingPrefix.count)).trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? nil : q
    }

    /// The words for the screen.
    static func text(_ note: String) -> String {
        if note == finished { return String(localized: "Finished: waiting for your next message") }
        if let question = question(note) { return String(localized: "Asking you: \(question)") }
        return note
    }
}

struct AgentSession: Identifiable, Equatable {
    var id: String
    var agent: AgentKind
    var cwd: String
    var title: String = ""
    var state: AgentState = .idle
    var startedAt = Date()
    var lastEventAt = Date()
    var steps: [AgentStep] = []
    var lastMessage = ""
    var subagents = 0
    /// When the current turn (the last prompt) began, and when it finished: the elapsed time shows from these.
    var turnStartedAt = Date()
    var finishedAt: Date?
    var todos: [AgentTodo] = []
    /// Why it waits for you, as a code (`AgentNote`): never shown as it is, `AgentNote.text` gives the words.
    var note = ""

    /// How long the finished turn took (nil while it runs).
    var turnSeconds: TimeInterval? { finishedAt.map { $0.timeIntervalSince(turnStartedAt) } }

    /// A turn that ended almost at once is a quick answer ("Received."), not a task that finished: no card says so.
    static let quickTurn: TimeInterval = 8
    var wasQuickTurn: Bool { (turnSeconds ?? .infinity) < Self.quickTurn }

    var project: String { cwd.isEmpty ? String(localized: "Session") : (cwd as NSString).lastPathComponent }
    var currentStep: AgentStep? { steps.last(where: { !$0.done && $0.tool != "Prompt" }) }
    var todosDone: Int { todos.filter { $0.status == .completed }.count }
    var currentTodo: String? { todos.first(where: { $0.status == .inProgress })?.active }
}

extension AgentSession {
    static func samples() -> [AgentSession] {
        let now = Date()
        func step(_ i: Int, _ tool: String, _ summary: String, done: Bool = true) -> AgentStep {
            AgentStep(id: "s\(i)", tool: tool, summary: summary, at: now.addingTimeInterval(Double(-90 + i * 12)), done: done)
        }
        var a = AgentSession(id: "demo-1", agent: .claude, cwd: "/Users/you/Dev/Scout", title: "Add the Tray conversions", state: .working,
                             startedAt: now.addingTimeInterval(-900), lastEventAt: now)
        a.turnStartedAt = now.addingTimeInterval(-252)
        a.lastMessage = "Wiring the converter into the workspace now."
        a.subagents = 1
        a.todos = [AgentTodo(text: "Read the Tray code", active: "Reading the Tray code", status: .completed),
                   AgentTodo(text: "Add the converter", active: "Adding the converter", status: .completed),
                   AgentTodo(text: "Wire it into the workspace", active: "Wiring it into the workspace", status: .inProgress),
                   AgentTodo(text: "Run the gallery", active: "Running the gallery", status: .pending),
                   AgentTodo(text: "Write the notes", active: "Writing the notes", status: .pending)]
        a.steps = [step(1, "Read", "TrayStore.swift"), step(2, "Grep", "ConvertFormat"), step(3, "Edit", "Converter.swift"),
                   step(4, "Bash", "swift build"), step(5, "Edit", "TrayWorkspace.swift"), step(6, "Bash", "scripts/gallery.sh tray", done: false)]
        var b = AgentSession(id: "demo-2", agent: .codex, cwd: "/Users/you/Dev/site", title: "Fix the footer links", state: .waiting,
                             startedAt: now.addingTimeInterval(-300), lastEventAt: now.addingTimeInterval(-20))
        b.turnStartedAt = now.addingTimeInterval(-96)
        b.steps = [step(1, "Read", "footer.html"), step(2, "Edit", "footer.html"), step(3, "Bash", "npm run lint", done: false)]
        var c = AgentSession(id: "demo-3", agent: .claude, cwd: "/Users/you/Dev/notes", title: "Summarise the research", state: .done,
                             startedAt: now.addingTimeInterval(-3600), lastEventAt: now.addingTimeInterval(-1200))
        c.turnStartedAt = now.addingTimeInterval(-1500)
        c.finishedAt = now.addingTimeInterval(-1200)
        c.lastMessage = "Done. The summary is in notes/summary.md."
        c.steps = [step(1, "Read", "research.md"), step(2, "Write", "summary.md")]
        return [a, b, c]
    }

    /// Up to six made-up sessions (the gallery and tests; never real transcripts). The 1st works, the 6th asks a question.
    static func synthetic(_ count: Int) -> [AgentSession] {
        let now = Date()
        func step(_ i: Int, _ tool: String, _ summary: String, done: Bool = true) -> AgentStep {
            AgentStep(id: "x\(i)\(tool)", tool: tool, summary: summary, at: now.addingTimeInterval(Double(-60 + i * 9)), done: done)
        }
        func todos(_ done: Int, _ total: Int) -> [AgentTodo] {
            (0..<total).map { i in AgentTodo(text: "Step \(i + 1)", active: ["Reading the router", "Adding the route", "Writing the tests", "Running the suite", "Updating the notes"][i % 5],
                                            status: i < done ? .completed : (i == done ? .inProgress : .pending)) }
        }
        var list: [AgentSession] = []
        var a = AgentSession(id: "syn-1", agent: .claude, cwd: "/Users/you/Dev/site", title: "Fix the footer links", state: .working, startedAt: now.addingTimeInterval(-1500), lastEventAt: now)
        a.turnStartedAt = now.addingTimeInterval(-252); a.lastMessage = "I'll fix the three footer links, then run the linter."; a.todos = todos(2, 5); a.steps = [step(1, "Read", "footer.html"), step(2, "Edit", "footer.html"), step(3, "Bash", "npm run lint", done: false)]
        list.append(a)
        var b = AgentSession(id: "syn-2", agent: .codex, cwd: "/Users/you/Dev/api", title: "Add the health endpoint", state: .working, startedAt: now.addingTimeInterval(-900), lastEventAt: now)
        b.turnStartedAt = now.addingTimeInterval(-96); b.lastMessage = "The health endpoint answers 200 with the build version, so the route goes into the router next."; b.subagents = 2; b.todos = todos(1, 3); b.steps = [step(1, "Read", "router.rs"), step(2, "Edit", "router.rs", done: false)]
        list.append(b)
        var c = AgentSession(id: "syn-3", agent: .claude, cwd: "/Users/you/Dev/notes", title: "Summarise the research", state: .waiting, startedAt: now.addingTimeInterval(-3000), lastEventAt: now.addingTimeInterval(-40))
        c.turnStartedAt = now.addingTimeInterval(-640); c.finishedAt = now.addingTimeInterval(-40); c.note = "Finished: waiting for your next message"; c.lastMessage = "The summary is in notes/summary.md."
        list.append(c)
        var d = AgentSession(id: "syn-4", agent: .claude, cwd: "/Users/you/Dev/scout", title: "Add the Tray conversions", state: .working, startedAt: now.addingTimeInterval(-2400), lastEventAt: now)
        d.turnStartedAt = now.addingTimeInterval(-1210); d.steps = [step(1, "Grep", "ConvertFormat"), step(2, "Bash", "swift build", done: false)]
        list.append(d)
        var e = AgentSession(id: "syn-5", agent: .claude, cwd: "/Users/you/Dev/docs", title: "Tidy the changelog", state: .done, startedAt: now.addingTimeInterval(-4000), lastEventAt: now.addingTimeInterval(-300))
        e.turnStartedAt = now.addingTimeInterval(-700); e.finishedAt = now.addingTimeInterval(-300); e.lastMessage = "Changelog is tidy."; e.todos = todos(4, 4)
        list.append(e)
        var f = AgentSession(id: "syn-6", agent: .codex, cwd: "/Users/you/Dev/infra", title: "Move the bucket", state: .waiting, startedAt: now.addingTimeInterval(-800), lastEventAt: now.addingTimeInterval(-20))
        f.turnStartedAt = now.addingTimeInterval(-380); f.note = "Asking you: Which region?"; f.lastMessage = "The bucket can move to eu-west-1 or us-east-1."
        list.append(f)
        return Array(list.prefix(count))
    }
}
