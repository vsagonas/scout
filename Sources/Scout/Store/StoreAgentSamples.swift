import SwiftUI

// Made-up agent sessions for the App Store scenes (Claude Code and Codex, plausible project names, never a real
// transcript). The scenes show the real views (the Nook's Agents dashboard, the grid, the wings, the cards) on
// these sessions. Nothing here reads ~/.claude or ~/.codex.

@MainActor
enum StoreAgents {
    /// The four sessions that are alive in most scenes: three work, one asks a question.
    static let live = ["website", "api", "ios-app", "infra"]
    /// The grid: the four above, one more at work and three that finished (two full rows of four tiles).
    static let grid = ["website", "api", "ios-app", "infra", "search", "docs", "billing", "scripts"]

    private static func todos(_ labels: [(text: String, active: String)], done: Int) -> [AgentTodo] {
        labels.enumerated().map { i, label in
            AgentTodo(text: label.text, active: label.active, status: i < done ? .completed : (i == done ? .inProgress : .pending))
        }
    }

    static func session(_ name: String) -> AgentSession {
        let now = Date()
        func step(_ i: Int, _ tool: String, _ summary: String, done: Bool = true) -> AgentStep {
            AgentStep(id: "\(name)-\(i)", tool: tool, summary: summary, at: now.addingTimeInterval(Double(-60 + i * 9)), done: done)
        }
        func make(_ agent: AgentKind, _ title: String, _ state: AgentState, started: TimeInterval, turn: TimeInterval) -> AgentSession {
            var s = AgentSession(id: "store-\(name)", agent: agent, cwd: "/Users/you/Dev/\(name)", title: title, state: state,
                                 startedAt: now.addingTimeInterval(-started), lastEventAt: now)
            s.turnStartedAt = now.addingTimeInterval(-turn)
            s.scanned = true
            return s
        }
        switch name {
        case "website":
            var s = make(.claude, "Fix the mobile menu", .working, started: 1500, turn: 252)
            s.todos = todos([("Read the menu code", "Reading the menu code"), ("Fix the toggle", "Fixing the toggle"), ("Update the styles", "Updating the styles"),
                             ("Write the tests", "Writing the tests"), ("Run the suite", "Running the suite"), ("Update the notes", "Updating the notes")], done: 3)
            s.steps = [step(1, "Read", "Menu.tsx"), step(2, "Edit", "Menu.tsx"), step(3, "Bash", "npm test", done: false)]
            return s
        case "api":
            var s = make(.codex, "Add the health endpoint", .working, started: 900, turn: 96)
            s.subagents = 2
            s.todos = todos([("Add the route", "Adding the route"), ("Write the handler", "Writing code"), ("Add the tests", "Adding the tests")], done: 1)
            s.steps = [step(1, "Read", "routes.ts"), step(2, "Edit", "health.ts", done: false)]
            return s
        case "ios-app":
            var s = make(.claude, "Fix the login crash", .working, started: 2400, turn: 560)
            s.todos = todos([("Reproduce the crash", "Reproducing the crash"), ("Find the cause", "Finding the cause"), ("Fix the session check", "Fixing the session check"),
                             ("Add a test", "Adding a test"), ("Run the tests", "Running tests")], done: 4)
            s.steps = [step(1, "Edit", "Session.swift"), step(2, "Bash", "npm run test:auth", done: false)]
            return s
        case "infra":
            var s = make(.claude, "Move the storage bucket", .waiting, started: 800, turn: 380)
            s.lastEventAt = now.addingTimeInterval(-20)
            s.note = "Asking you: Which region?"
            return s
        case "search":
            var s = make(.claude, "Speed up the index", .working, started: 1900, turn: 430)
            s.subagents = 1
            s.todos = todos([("Profile the query", "Profiling the query"), ("Add the index", "Adding the index"), ("Benchmark it", "Benchmarking"), ("Update the docs", "Updating the docs")], done: 2)
            s.steps = [step(1, "Grep", "buildIndex"), step(2, "Bash", "npm run bench", done: false)]
            return s
        case "docs":
            var s = make(.claude, "Tidy the changelog", .done, started: 4000, turn: 700)
            s.finishedAt = now.addingTimeInterval(-300)
            s.lastMessage = "Changelog is tidy."
            s.todos = todos([("Read the entries", "Reading the entries"), ("Group by release", "Grouping by release"), ("Fix the links", "Fixing the links"),
                             ("Check the headings", "Checking the headings")], done: 4)
            return s
        case "scripts":
            var s = make(.codex, "Rename the deploy scripts", .done, started: 5200, turn: 2000)
            s.finishedAt = now.addingTimeInterval(-1500)
            s.lastMessage = "Scripts are renamed."
            s.todos = todos([("List the scripts", "Listing the scripts"), ("Rename them", "Renaming them")], done: 2)
            return s
        default:
            var s = make(.claude, "Update the invoice emails", .done, started: 3000, turn: 760)
            s.finishedAt = now.addingTimeInterval(-540)
            s.lastMessage = "Invoice emails are updated."
            s.todos = todos([("Edit the template", "Editing the template"), ("Check the preview", "Checking the preview"), ("Run the tests", "Running the tests")], done: 3)
            return s
        }
    }

    static func sessions(_ names: [String]) -> [AgentSession] { names.map(session) }

    /// Claude Code asks to run a command (Allow, Always allow, Deny).
    static func permission(for name: String = "website") -> AgentPending {
        AgentPending(sessionID: "store-\(name)", kind: .permission, tool: "Bash", summary: "npm run build", detail: "npm run build", questions: [], rawToolInput: nil,
                     agent: .claude,
                     permissionSuggestions: Data("[{\"type\":\"addRules\",\"rules\":[{\"toolName\":\"Bash\",\"ruleContent\":\"npm run build\"}],\"behavior\":\"allow\",\"destination\":\"localSettings\"}]".utf8))
    }

    /// Claude Code asks which region (one tap on an option answers; only Claude Code asks questions through the hooks).
    static func question(for name: String = "infra") -> AgentPending {
        AgentPending(sessionID: "store-\(name)", kind: .question, tool: "AskUserQuestion", summary: "Which region?", detail: "",
                     questions: [AgentQuestion(question: "Which region should the bucket move to?", header: "Region",
                                               options: [.init(label: "eu-west-1", detail: ""), .init(label: "us-east-1", detail: ""), .init(label: "Keep as is", detail: "")],
                                               multiSelect: false)],
                     rawToolInput: nil, agent: .claude)
    }

    /// The shared store (the Nook's dashboard and the Agents workspace read it) holds exactly these sessions.
    static func loadShared(_ names: [String], pending: [AgentPending] = [], doneToday: Int = 6) {
        let store = AgentsStore.shared
        store.loadSessions(sessions(names), pending: pending)
        store.previewDoneToday(doneToday)
        store.previewScan(.init(access: [.claude: .ok, .codex: .ok], tracked: names.count, sessions: names.count, watching: true, lastSweep: Date()))
    }

    /// A store of its own for the wings and the cards.
    static func store(_ folder: String, names: [String], pending: [AgentPending] = []) -> AgentsStore {
        let store = AgentsStore(directory: AppPaths.folder(folder))
        store.loadSessions(sessions(names), pending: pending)
        store.previewDoneToday(6)
        return store
    }

    /// The closed notch's readout, built the way the app builds it (the glyph and counts on the left, the project that
    /// needs you on the right, one line per agent while the pointer rests on the notch).
    static func wings(_ store: AgentsStore) -> LiveActivity {
        LiveActivity(id: "agents.main", kind: .agent, onTap: nil, leading: {
            AgentWingLeft(store: store)
        }, trailing: {
            AgentWingRight(store: store)
        }).withDetail {
            AgentWingDetail(store: store)
        }
    }

    /// A card under the closed notch for a request waiting on an answer.
    static func card(_ request: AgentPending, store: AgentsStore) -> NotchCard {
        NotchCard(id: "agent.pending.\(request.id)", kind: .agent, duration: 600) {
            PendingView(request: request, store: store, compact: true)
        }
    }
}
