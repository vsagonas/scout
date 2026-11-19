import SwiftUI

/// Made-up agents for the AgentNook pictures and tests (never real transcripts): every state, every prop, helpers and to-dos.
@MainActor
enum AgentNookSamples {
    private static func step(_ i: Int, _ tool: String, _ summary: String, done: Bool = true, failed: Bool = false) -> AgentStep {
        AgentStep(id: "n\(i)\(tool)", tool: tool, summary: summary, at: Date().addingTimeInterval(Double(-60 + i * 9)), done: done, failed: failed)
    }

    private static func todos(_ done: Int, _ total: Int) -> [AgentTodo] {
        (0..<total).map { i in
            AgentTodo(text: "Step \(i + 1)", active: ["Reading the router", "Adding the route", "Writing the tests", "Running the suite", "Updating the notes"][i % 5],
                      status: i < done ? .completed : (i == done ? .inProgress : .pending))
        }
    }

    private static func session(_ id: String, _ agent: AgentKind, _ project: String, _ state: AgentState, steps: [AgentStep] = [], todos list: [AgentTodo] = [],
                                helpers: Int = 0, message: String = "", note: String = "", turnEnded: Bool = false) -> AgentSession {
        let now = Date()
        var s = AgentSession(id: id, agent: agent, cwd: "/Users/you/Dev/\(project)", title: "Work on \(project)", state: state,
                             startedAt: now.addingTimeInterval(-Double(abs(id.hashValue % 3000)) - 600), lastEventAt: now)
        s.turnStartedAt = now.addingTimeInterval(-300)
        s.scanned = true
        s.steps = steps
        s.todos = list
        s.subagents = helpers
        s.lastMessage = message
        s.note = note
        if state == .done || turnEnded { s.finishedAt = now.addingTimeInterval(-120) }   // a turn that ended (a waiting agent with a finish time FINISHED)
        return s
    }

    /// One agent of the given look (and prop), for a single room.
    static func one(_ look: AgentNookLook, prop: AgentNookProp? = .pencil, kind: AgentKind = .claude, project: String = "site", helpers: Int = 2,
                    todos total: Int = 5, done: Int = 2, message: String = "I'll fix the three footer links, then run the linter.") -> AgentSession {
        let tool: String
        switch prop {
        case .pencil?: tool = "Edit"
        case .wrench?: tool = "Bash"
        case .magnifier?: tool = "Grep"
        case .globe?: tool = "WebSearch"
        case nil: tool = "Task"
        }
        let list = total > 0 ? todos(look == .finished ? total : done, total) : []
        switch look {
        case .working: return session("one-working", kind, project, .working, steps: [step(1, "Read", "a.swift"), step(2, tool, "x", done: false)], todos: list, helpers: helpers, message: message)
        case .needsYou: return session("one-needs", kind, project, .waiting, steps: [step(1, "Read", "a.swift")], todos: list, helpers: helpers, message: "May I run the migration?", note: "Asking you: Which region?")
        case .finished: return session("one-done", kind, project, .done, steps: [step(1, "Read", "a.swift"), step(2, "Edit", "a.swift")], todos: list, helpers: helpers, message: "All done. The summary is in notes/summary.md.")
        case .stopped: return session("one-stopped", kind, project, .done, steps: [step(1, "Read", "a.swift"), step(2, "Bash", "swift test", failed: true)], todos: list, helpers: helpers, message: "The tests failed twice, so I stopped.")
        case .idle: return session("one-idle", kind, project, .idle, steps: [], todos: [], helpers: helpers)
        }
    }

    /// Up to nine agents in every state; the first ones are the most varied, so a short list still tells the story.
    static func sessions(_ count: Int) -> [AgentSession] {
        let list: [AgentSession] = [
            session("nk-1", .claude, "site", .working, steps: [step(1, "Read", "footer.html"), step(2, "Edit", "footer.html", done: false)], todos: todos(2, 5), helpers: 2,
                    message: "I'll fix the three footer links, then run the linter."),
            session("nk-2", .codex, "api", .working, steps: [step(1, "Read", "router.rs"), step(2, "Bash", "cargo test", done: false)], todos: todos(1, 3), helpers: 4,
                    message: "The health endpoint answers 200, so the route goes into the router next."),
            session("nk-3", .claude, "notes", .waiting, steps: [step(1, "Read", "research.md")], helpers: 0, message: "Which region should the bucket move to?",
                    note: "Asking you: Which region?"),
            session("nk-4", .claude, "scout", .working, steps: [step(1, "Grep", "ConvertFormat", done: false)], todos: todos(3, 4), helpers: 1, message: "Looking for where the format is chosen."),
            session("nk-5", .claude, "docs", .waiting, steps: [step(1, "Read", "changelog.md"), step(2, "Write", "changelog.md")], todos: todos(4, 4), helpers: 0, message: "Changelog is tidy.",
                    note: "Finished: waiting for your next message", turnEnded: true),
            session("nk-6", .codex, "infra", .working, steps: [step(1, "WebSearch", "bucket regions", done: false)], todos: todos(0, 2), helpers: 3, message: "Checking which regions are cheapest."),
            session("nk-7", .claude, "worker", .waiting, steps: [step(1, "Read", "queue.ts"), step(2, "Bash", "npm test", failed: true)], todos: todos(2, 6), helpers: 0, message: "The tests failed twice.",
                    note: "Finished: waiting for your next message", turnEnded: true),
            session("nk-8", .codex, "sandbox", .idle),
            session("nk-9", .codex, "web", .working, steps: [step(1, "Edit", "index.html", done: false)], todos: todos(5, 8), helpers: 7, message: "Updating the landing page."),
        ]
        return Array(list.prefix(count))
    }

    /// A store of its own for a picture (never the shared one); a held request makes its agent ask.
    static func store(_ name: String, _ sessions: [AgentSession], asking: String? = nil) -> AgentsStore {
        let store = AgentsStore(directory: AppPaths.folder("agentnook-\(name)"))
        let held = asking.map { [AgentPending(sessionID: $0, kind: .permission, tool: "Bash", summary: "terraform apply", detail: "terraform apply", questions: [], rawToolInput: nil, agent: .codex)] } ?? []
        store.loadSessions(sessions, pending: held)
        store.previewDoneToday(sessions.isEmpty ? 0 : 5)
        return store
    }
}

/// The black notch behind a picture, and the panel as the dashboard's cell draws it (rounded, a little lighter).
struct AgentNookCell<Content: View>: View {
    var cells: Int
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(width: AgentNookLayout.width(cells: cells), height: NookMetrics.widgetHeight)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.075)))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// A sheet of pictures on black, each with a small caption.
struct AgentNookSheet<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.black)
            .notchContent()
    }
}

struct AgentNookCaption: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.45)) }
}

@MainActor
enum AgentNookGallery {
    static func register() {
        critters()
        rooms()
        helpers()
        panels()
        emptyHouse()
        highlight()
        dashboard()
        AgentTVGallery.register()   // tv-*: Agent TV and the den
        AgentBigFaceGallery.register()   // agents-bigface-*: the big figures wear their face's headwear
    }

    private static func sheet<V: View>(_ name: String, _ width: CGFloat, _ height: CGFloat, @ViewBuilder _ content: @escaping () -> V) {
        Gallery.register("agentnook-\(name)", size: CGSize(width: width, height: height), backdrop: .window) { AgentNookSheet(content: content) }
    }

    // MARK: The scout, large

    private static func critters() {
        let poses: [(AgentNookLook, String)] = AgentNookLook.allCases.map { ($0, $0.title) }
        sheet("critter-states", 1330, 440) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach([AgentKind.claude, .codex], id: \.self) { kind in
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(poses, id: \.1) { look, title in
                            VStack(spacing: 4) {
                                AgentNookCritter(kind: kind, pose: look.pose, prop: .pencil)
                                    .frame(width: 240, height: 156)
                                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
                                AgentNookCaption("\(kind.title) · \(title)")
                            }
                        }
                    }
                }
            }
        }
        sheet("critter-props", 1330, 230) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(([nil] + AgentNookProp.allCases.map(Optional.some)).enumerated()), id: \.offset) { _, prop in
                    VStack(spacing: 4) {
                        AgentNookCritter(kind: .claude, pose: .typing, prop: prop)
                            .frame(width: 240, height: 156)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
                        AgentNookCaption(prop.map { "\($0)" } ?? "no prop (thinking)")
                    }
                }
            }
        }
        sheet("props-large", 640, 150) {
            HStack(spacing: 16) {
                ForEach(AgentNookProp.allCases, id: \.self) { prop in
                    AgentNookPropView(prop: prop).frame(width: 120, height: 120).background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.10, green: 0.13, blue: 0.2)))
                }
            }
        }
    }

    // MARK: Rooms

    private static func models(_ looks: [AgentNookLook], kind: AgentKind = .claude) -> [AgentNookRoomModel] {
        looks.enumerated().map { i, look in
            let props: [AgentNookProp] = [.pencil, .wrench, .magnifier, .globe]
            return AgentNookRoomModel(AgentNookSamples.one(look, prop: props[i % 4], kind: i % 2 == 0 ? kind : (kind == .claude ? .codex : .claude), project: ["site", "api", "notes", "worker", "sandbox"][i % 5], helpers: [2, 4, 0, 1, 0][i % 5]),
                                      needsYou: look == .needsYou)
        }
    }

    private static func rooms() {
        let looks = AgentNookLook.allCases
        // Real size, in a row, then the same two sheets three times larger.
        sheet("rooms-roomy", 5 * 150 + 28, 150) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(models(looks)) { m in
                    VStack(spacing: 3) {
                        AgentNookRoom(model: m, style: .roomy).frame(width: 140, height: 105)
                        AgentNookCaption(m.look.title)
                    }
                }
            }
        }
        sheet("rooms-roomy-zoom", 5 * 336 + 28, 310) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(models(looks)) { m in
                    VStack(spacing: 3) {
                        AgentNookRoom(model: m, style: .roomy).frame(width: 140, height: 105).scaleEffect(2.3, anchor: .topLeading).frame(width: 322, height: 242, alignment: .topLeading)
                        AgentNookCaption(m.look.title)
                    }
                }
            }
        }
        sheet("rooms-compact", 5 * 90 + 28, 150) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(models(looks)) { m in
                    VStack(spacing: 3) {
                        AgentNookRoom(model: m, style: .compact).frame(width: 78, height: 105)
                        AgentNookCaption(m.look.title)
                    }
                }
            }
        }
        sheet("rooms-compact-zoom", 5 * 217 + 28, 340) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(models(looks)) { m in
                    VStack(spacing: 3) {
                        AgentNookRoom(model: m, style: .compact).frame(width: 78, height: 105).scaleEffect(2.6, anchor: .topLeading).frame(width: 203, height: 273, alignment: .topLeading)
                        AgentNookCaption(m.look.title)
                    }
                }
            }
        }
        // The same states in the other kind's colour, and a wide room with everything.
        sheet("rooms-wide", 3 * 290 + 28, 150) {
            HStack(alignment: .top, spacing: 8) {
                ForEach([AgentNookLook.working, .needsYou, .finished]) { look in
                    VStack(spacing: 3) {
                        AgentNookRoom(model: AgentNookRoomModel(AgentNookSamples.one(look, prop: .magnifier, kind: .codex, helpers: 6, todos: 7, done: 3), needsYou: look == .needsYou), style: .roomy)
                            .frame(width: 188, height: 105)
                        AgentNookCaption("\(look.title) · wide room, 6 helpers")
                    }
                }
            }
        }
        // Frames of the motion (Reduce Motion off: bob, blink, typing, wave) and of the fades (Reduce Motion on).
        let moving = [0.0, 0.5, 1.0, 4.3].map { AgentNookClock(t: $0, motion: true) }
        let fading = [0.0, 0.75, 1.5].map { AgentNookClock(t: $0, motion: false) }
        sheet("motion-frames", 4 * 150 + 28, 5 * 125 + 60) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(looks) { look in
                    HStack(spacing: 8) {
                        let m = AgentNookRoomModel(AgentNookSamples.one(look, prop: .wrench, helpers: 2, todos: 4, done: 1), needsYou: look == .needsYou)
                        ForEach(Array(moving.enumerated()), id: \.offset) { _, c in AgentNookRoom(model: m, style: .roomy, clock: c).frame(width: 140, height: 105) }
                    }
                }
                AgentNookCaption("Reduce Motion off: bob, blink, typing, wave (t = 0, 0.5, 1.0, 4.3 s)")
            }
        }
        sheet("fade-frames", 3 * 150 + 28, 5 * 125 + 60) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(looks) { look in
                    HStack(spacing: 8) {
                        let m = AgentNookRoomModel(AgentNookSamples.one(look, prop: .wrench, helpers: 2, todos: 4, done: 1), needsYou: look == .needsYou)
                        ForEach(Array(fading.enumerated()), id: \.offset) { _, c in AgentNookRoom(model: m, style: .roomy, clock: c).frame(width: 140, height: 105) }
                    }
                }
                AgentNookCaption("Reduce Motion on: only fades (t = 0, 0.75, 1.5 s)")
            }
        }
    }

    // MARK: Helpers

    private static func helpers() {
        let counts = [0, 1, 3, 7]
        sheet("helpers", 4 * 150 + 28, 2 * 130 + 20) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach([AgentNookLook.working, .idle]) { look in
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(counts, id: \.self) { n in
                            VStack(spacing: 3) {
                                AgentNookRoom(model: AgentNookRoomModel(AgentNookSamples.one(look, prop: .wrench, helpers: n, todos: 0, done: 0), needsYou: false), style: .roomy).frame(width: 140, height: 105)
                                AgentNookCaption("\(n) helper\(n == 1 ? "" : "s") · \(look == .working ? "awake" : "asleep")")
                            }
                        }
                    }
                }
            }
        }
        sheet("helpers-compact", 4 * 90 + 28, 150) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(counts, id: \.self) { n in
                    VStack(spacing: 3) {
                        AgentNookRoom(model: AgentNookRoomModel(AgentNookSamples.one(.working, prop: .wrench, helpers: n, todos: 3, done: 1), needsYou: false), style: .compact).frame(width: 78, height: 105)
                        AgentNookCaption("\(n) helper\(n == 1 ? "" : "s")")
                    }
                }
            }
        }
    }

    // MARK: The panel at every width

    private static func panels() {
        let counts = [1, 3, 6, 9]
        for cells in [3, 4, 6, 10, 16] {
            let stores = counts.map { n in AgentNookSamples.store("p\(cells)-\(n)", AgentNookSamples.sessions(n), asking: n >= 6 ? "nk-6" : nil) }
            let width = AgentNookLayout.width(cells: cells) + 28
            sheet(String(format: "panels-c%02d", cells), width, 4 * (NookMetrics.widgetHeight + 24) + 28) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(counts.enumerated()), id: \.offset) { i, n in
                        VStack(alignment: .leading, spacing: 3) {
                            AgentNookCaption("\(cells) cells · \(n) agent\(n == 1 ? "" : "s")")
                            AgentNookCell(cells: cells) { AgentNookPanelView(store: stores[i]) }
                        }
                    }
                }
            }
        }
    }

    private static func emptyHouse() {
        for cells in [3, 8, 16] {
            let empty = AgentNookSamples.store("empty\(cells)", [])
            sheet(String(format: "empty-c%02d", cells), AgentNookLayout.width(cells: cells) + 28, NookMetrics.widgetHeight + 50) {
                VStack(alignment: .leading, spacing: 3) {
                    AgentNookCaption("The empty house · \(cells) cells")
                    AgentNookCell(cells: cells) { AgentNookPanelView(store: empty) }
                }
            }
        }
    }

    private static func highlight() {
        let store = AgentNookSamples.store("highlight", AgentNookSamples.sessions(4))
        sheet("highlighted", AgentNookLayout.width(cells: 8) + 28, NookMetrics.widgetHeight + 50) {
            VStack(alignment: .leading, spacing: 3) {
                AgentNookCaption("The first room glows for a moment (a highlighted agent)")
                AgentNookCell(cells: 8) { AgentNookPanelView(store: store, highlighted: "nk-3") }
            }
        }
    }

    // MARK: Inside the real dashboard

    private static func dashboard() {
        func scene(_ name: String, agents: Int, asking: Bool = false, layout: [WidgetKind], cap: CGFloat? = nil) {
            let store = AgentNookSamples.store("dash-\(name)", AgentNookSamples.sessions(agents), asking: asking ? "nk-6" : nil)
            let size = CGSize(width: DashGallery.wide, height: 290)
            Gallery.register("agentnook-dash-\(name)", size: size) {
                let _ = DashPreview.seed(store)
                NotchScene(size: size, open: true, workspace: .nook, layout: layout, live: NookLive(playing: false, openTodos: 0, agents: agents),
                           prepare: { nook in
                    nook.viewOverride = { item in item == .panel(.agents) ? AnyView(AgentNookPanelView(store: store)) : nil }
                }, widthCap: cap, showNotchRect: false)
            }
        }
        scene("3agents", agents: 3, layout: [.agents, .askAI, .pulse, .today])
        scene("6agents-asking", agents: 6, asking: true, layout: [.agents, .askAI, .pulse, .today])
        scene("narrow", agents: 4, layout: [.agents, .askAI, .pulse, .today], cap: 640)
        scene("empty", agents: 0, layout: [.agents, .askAI, .pulse, .today])
    }
}

/// The other panels of a dashboard picture read the shared stores; this gives them something to show.
@MainActor
enum DashPreview {
    static func seed(_ store: AgentsStore) {
        AgentsStore.shared.loadSessions(store.sessions, pending: store.pending)
        AgentsStore.shared.previewDoneToday(store.sessions.isEmpty ? 0 : 5)
    }
}

extension AgentNookLook: Identifiable { var id: String { title } }
