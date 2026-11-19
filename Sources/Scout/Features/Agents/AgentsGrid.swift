import SwiftUI

/// Sizes shared by the multi view and the height it asks the island for.
enum AgentTileMetrics {
    static let spacing: CGFloat = 8
    static let base: CGFloat = 96
    static let withRequest: CGFloat = 134
    /// The header row, the open notch's own header and paddings, and this view's paddings (see NotchRootView.openContent).
    static let chrome: CGFloat = 37 + 22 + 24 + 22
    static let tallest: CGFloat = 470

    /// 2 to 4 columns by width; a few sessions don't stretch into columns they cannot fill.
    static func columns(width: CGFloat, count: Int) -> Int {
        let byWidth = width >= 820 ? 4 : (width >= 560 ? 3 : 2)
        return min(byWidth, max(2, count))
    }

    /// Every row of agents (the closed notch's faces, the header's faces, the TV's rooms, the den's stations, the grid, the plain list) in ONE
    /// fixed order: the order Scout found them in (`AgentFoundOrder`), the first found on the left (or on top), a new one joins on the right,
    /// and nobody changes places when its state changes.
    /// It used to sort by who needs you, so agents swapped places all day, and the faces sorted
    /// by their latest step.
    static func ordered(_ sessions: [AgentSession], pending: [AgentPending] = []) -> [AgentSession] {
        AgentFoundOrder.sorted(sessions)
    }

    /// How much an agent needs you (lower = more): a held request, a question, at work, finished, asleep. It only chooses WHO shows when not
    /// everyone fits; the row keeps the fixed order.
    static func urgency(_ s: AgentSession, pending: [AgentPending]) -> Int {
        if pending.contains(where: { $0.sessionID == s.id }) { return 0 }
        if AgentWingSummary.asks(s, pending: pending) { return 1 }
        switch s.state {
        case .working: return 2
        case .waiting, .done: return 3
        case .idle: return 4
        }
    }

    /// The `limit` of `items` (already in the fixed order) that need you most, still in the fixed order (ties keep it too).
    static func keepOrder<T>(_ items: [T], limit: Int, need: (T) -> Int) -> [T] {
        guard items.count > limit else { return items }
        let picked = Set(items.indices.sorted { (need(items[$0]), $0) < (need(items[$1]), $1) }.prefix(max(0, limit)))
        return items.indices.filter { picked.contains($0) }.map { items[$0] }
    }

    /// The urgency of a room, a station or a row by its look.
    static func need(_ look: AgentNookLook) -> Int {
        switch look {
        case .needsYou: return 0
        case .working: return 1
        case .finished, .stopped: return 2
        case .idle: return 3
        }
    }

    static func height(of session: AgentSession, pending: [AgentPending]) -> CGFloat {
        pending.contains { $0.sessionID == session.id } ? withRequest : base
    }

    /// The island height (header included) that shows every row of tiles, within reason.
    static func islandHeight(sessions: [AgentSession], pending: [AgentPending], width: CGFloat) -> CGFloat {
        let tiles = ordered(sessions, pending: pending)
        guard !tiles.isEmpty else { return 0 }
        let cols = columns(width: width, count: tiles.count)
        var total: CGFloat = 0
        var index = 0
        var rows = 0
        while index < tiles.count {
            total += tiles[index..<min(index + cols, tiles.count)].map { height(of: $0, pending: pending) }.max() ?? base
            index += cols
            rows += 1
        }
        return min(contentHeight(sessions: sessions, pending: pending, width: width), tallest)
    }

    /// The island height that shows every row, with no cap (what the resize grip may reach).
    static func contentHeight(sessions: [AgentSession], pending: [AgentPending], width: CGFloat) -> CGFloat {
        let tiles = ordered(sessions, pending: pending)
        guard !tiles.isEmpty else { return 0 }
        let cols = columns(width: width, count: tiles.count)
        var total: CGFloat = 0
        var index = 0
        var rows = 0
        while index < tiles.count {
            total += tiles[index..<min(index + cols, tiles.count)].map { height(of: $0, pending: pending) }.max() ?? base
            index += cols
            rows += 1
        }
        return chrome + total + spacing * CGFloat(max(0, rows - 1))
    }
}

/// One live tile per session: who, what state, what it is doing now, how far it is.
struct AgentTile: View {
    let session: AgentSession
    @ObservedObject var store: AgentsStore
    var onOpen: () -> Void

    private var requests: [AgentPending] { store.pending.filter { $0.sessionID == session.id } }
    private var needsAnswer: Bool { !requests.isEmpty }
    private var attention: Bool { needsAnswer || session.state == .waiting }
    private var tint: Color { attention ? .orange : (session.state == .working ? Theme.accent : (session.state == .done ? .green : .gray)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                AgentGlyph(agent: session.agent, size: 12)
                Text(session.project).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 2)
                badge
            }
            activity
            progress
            if let request = requests.first { answer(request) }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if session.subagents > 0 {
                    Label("Helpers: \(session.subagents)", systemImage: "person.2")
                        .font(.system(size: 9.5, weight: .medium)).foregroundStyle(NotchInk.secondary)
                }
                Spacer(minLength: 0)
                Text(session.agent.title).font(.system(size: 9.5)).foregroundStyle(NotchInk.tertiary)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: AgentTileMetrics.height(of: session, pending: store.pending))
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(tint.opacity(attention ? 0.16 : 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(tint.opacity(attention ? 0.55 : 0.18), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onTapGesture(perform: onOpen)
    }

    private var badge: some View {
        HStack(spacing: 4) {
            Circle().fill(needsAnswer ? Color.orange : session.state.color).frame(width: 6, height: 6)
            Text(verbatim: needsAnswer ? String(localized: "Needs you") : session.state.title).font(.system(size: 10, weight: .medium)).foregroundStyle(attention ? Color.orange : NotchInk.secondary)
            if session.state == .working || session.state == .waiting {
                AgentElapsed(start: session.turnStartedAt).font(.system(size: 10)).foregroundStyle(NotchInk.tertiary)
            } else if session.state == .done, let end = session.finishedAt {
                AgentElapsed(start: session.turnStartedAt, end: end).font(.system(size: 10)).foregroundStyle(NotchInk.tertiary)
            }
        }
    }

    /// The tool running now (or what it waits for), on one line.
    @ViewBuilder private var activity: some View {
        if let request = requests.first {
            Text(verbatim: request.kind == .permission && !request.tool.isEmpty ? "\(request.tool): \(request.summary)" : request.summary)
                .font(.system(size: 11, design: request.kind == .permission ? .monospaced : .default)).foregroundStyle(Color.orange).lineLimit(1)
        } else if session.state == .waiting {
            (session.note.isEmpty ? Text("Waiting for you") : Text(verbatim: AgentNote.text(session.note))).font(.system(size: 11)).foregroundStyle(Color.orange).lineLimit(1)
        } else if session.state == .working {
            HStack(spacing: 5) {
                AgentSpinner(size: 9)
                if let step = session.currentStep {
                    Text(step.tool).font(.system(size: 11, weight: .semibold))
                    Text(step.summary).font(.system(size: 11, design: step.tool == "Bash" ? .monospaced : .default)).foregroundStyle(NotchInk.secondary).lineLimit(1)
                } else {
                    Text("Thinking…").font(.system(size: 11)).foregroundStyle(NotchInk.secondary)
                }
            }
        } else {
            Text(session.lastMessage.isEmpty ? (session.title.isEmpty ? session.state.title : session.title) : session.lastMessage)
                .font(.system(size: 11)).foregroundStyle(NotchInk.secondary).lineLimit(1)
        }
    }

    /// The agent's own to-do list as a bar and "2 of 5 · item"; the latest prompt when it has none.
    @ViewBuilder private var progress: some View {
        if !session.todos.isEmpty {
            let total = session.todos.count, done = session.todosDone
            HStack(spacing: 6) {
                ZStack(alignment: .leading) {
                    Capsule().fill(NotchInk.tileStrong)
                    GeometryReader { g in Capsule().fill(tint).frame(width: g.size.width * CGFloat(done) / CGFloat(max(1, total))) }
                }
                .frame(width: 44, height: 4)
                Text("\(done) of \(total)").font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                (session.currentTodo.map { Text(verbatim: $0) } ?? (done == total ? Text("All done") : Text(verbatim: ""))).font(.system(size: 10.5)).foregroundStyle(NotchInk.secondary).lineLimit(1)
            }
        } else if !session.title.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "text.bubble").font(.system(size: 8.5)).foregroundStyle(NotchInk.tertiary)
                Text(session.title).font(.system(size: 10.5)).foregroundStyle(NotchInk.secondary).lineLimit(1)
            }
        }
    }

    /// Answer in place (hooks connected): Allow / Deny, or the question's options.
    @ViewBuilder private func answer(_ request: AgentPending) -> some View {
        if request.kind == .permission {
            HStack(spacing: 6) {
                Button("Allow") { store.decide(request.id, .allow) }.buttonStyle(AgentPillStyle(prominent: true, onDark: true))
                Button("Deny") { store.decide(request.id, .deny) }.buttonStyle(AgentPillStyle(onDark: true))
                Spacer(minLength: 0)
            }
        } else if let q = request.questions.first {
            let single = request.questions.count == 1 && !q.multiSelect
            HStack(spacing: 5) {
                ForEach(Array(q.options.prefix(3).enumerated()), id: \.offset) { _, option in
                    Button(option.label) {
                        if single { store.decide(request.id, .answers([q.question: option.label])) } else { onOpen() }
                    }
                    .buttonStyle(AgentPillStyle(onDark: true)).lineLimit(1)
                }
                if q.options.count > 3 || !single { Button("More…", action: onOpen).buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(NotchInk.secondary) }
                Spacer(minLength: 0)
            }
        }
    }
}

/// The Agents workspace's first view: every session on the Mac, one tile each.
struct AgentsGridView: View {
    @ObservedObject var store: AgentsStore
    let width: CGFloat
    var onOpen: (String) -> Void

    private var tiles: [AgentSession] { AgentTileMetrics.ordered(store.sessions, pending: store.pending) }

    private var summary: String {
        let needs = Set(store.pending.map(\.sessionID)).union(store.sessions.filter { $0.state == .waiting }.map(\.id)).count
        let working = store.sessions.filter { $0.state == .working }.count
        var parts = [String(localized: "Agents: \(store.sessions.count)")]
        if needs > 0 { parts.append(String(localized: "Needs you: \(needs)")) }
        if working > 0 { parts.append(String(localized: "Working: \(working)")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let cols = AgentTileMetrics.columns(width: width, count: tiles.count)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(summary).font(.system(size: 11, weight: .semibold)).foregroundStyle(NotchInk.secondary)
                Spacer(minLength: 0)
                MachineLoadLine(style: .full)
                if store.scanStatus.watching || store.sessions.contains(where: \.scanned) {
                    Label("Found automatically", systemImage: "dot.radiowaves.left.and.right").labelStyle(.titleAndIcon)
                        .font(.system(size: 10)).foregroundStyle(NotchInk.tertiary)
                }
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: AgentTileMetrics.spacing, alignment: .topLeading), count: cols),
                          alignment: .leading, spacing: AgentTileMetrics.spacing) {
                    ForEach(tiles) { s in AgentTile(session: s, store: store) { onOpen(s.id) } }
                }
            }
        }
    }
}

/// The dashboard's centrepiece, the agentic panel: the cpu glyph and "Agents" with the totals, the Mac's own CPU and memory
/// beside them (one agentic + machine monitor), then ONE MINIMAL LINE per agent: a state dot, the project, the first sentence of
/// the agent's latest message (the current step while there is no message yet), and at most one small detail on the right
/// ("needs you", or the progress 2/5). Tool names, helpers, timers and bars live in the expanded Agents view.
/// It widens to the room the other panels leave; a click on the panel (or on a line, which also picks that agent) opens it.
struct AgentsWidgetView: View {
    @ObservedObject private var store: AgentsStore
    @Environment(\.notchNavigator) private var navigator

    @MainActor init(store: AgentsStore? = nil) { _store = ObservedObject(wrappedValue: store ?? AgentsStore.shared) }

    private var rows: [AgentSession] { AgentTileMetrics.ordered(store.sessions, pending: store.pending) }
    private func needsYou(_ s: AgentSession) -> Bool { s.state == .waiting || store.pending.contains { $0.sessionID == s.id } }

    /// The first sentence of the newest message; the step it is on while there is none; the prompt or state as a last resort.
    static func sentence(_ s: AgentSession) -> String {
        if !s.lastMessage.isEmpty { return s.lastMessage }
        if let step = s.currentStep { return "\(step.tool) \(step.summary)" }
        if let todo = s.currentTodo { return todo }
        return s.title.isEmpty ? s.state.title : s.title
    }

    /// The one small thing on the right of a line.
    private func detail(_ s: AgentSession) -> (text: String, attention: Bool)? {
        if needsYou(s) { return (String(localized: "needs you"), true) }
        if !s.todos.isEmpty { return ("\(s.todosDone)/\(s.todos.count)", false) }
        return nil
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let stacked = w < 250
            let rowHeight: CGFloat = stacked ? 31 : 21
            let capacity = max(1, Int((geo.size.height - 20 - 22 - 4) / rowHeight))
            let overflow = rows.count > capacity
            let shown = Array(rows.prefix(overflow ? max(1, capacity - 1) : capacity))
            VStack(alignment: .leading, spacing: 4) {
                totals(width: w)
                if rows.isEmpty {
                    Spacer(minLength: 0)
                    Text("No agents running").font(.system(size: 11, weight: .medium)).foregroundStyle(NotchInk.secondary).frame(maxWidth: .infinity)
                    Text("Claude Code and Codex show up here by themselves").font(.system(size: 9.5)).foregroundStyle(NotchInk.tertiary)
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                } else {
                    ForEach(shown) { s in row(s, stacked: stacked) }
                    if overflow { Text("+\(rows.count - shown.count) more").font(.system(size: 9.5, weight: .medium)).foregroundStyle(NotchInk.tertiary).padding(.leading, 4) }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .notchContent()
    }

    private func totals(width w: CGFloat) -> some View {
        let running = store.sessions.count
        let needs = store.sessions.filter(needsYou).count
        return HStack(spacing: 6) {
            Image(systemName: "cpu").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
            Text("Agents").font(.system(size: 12, weight: .semibold)).layoutPriority(2)
            if running > 0 {
                if w >= 360 {
                    Text("\(running) running").font(.system(size: 10.5, weight: .medium)).foregroundStyle(NotchInk.secondary)
                    if needs > 0 { Text("· Needs you: \(needs)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.orange) }
                    if w >= 480 { Text("· \(store.doneToday) done today").font(.system(size: 10.5)).foregroundStyle(NotchInk.tertiary) }
                } else if w >= 250 {
                    Text("\(running)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(NotchInk.secondary)
                    if needs > 0 { Circle().fill(Color.orange).frame(width: 6, height: 6) }
                }
            }
            Spacer(minLength: 4)
            MachineLoadLine(style: MachineLoadLine.style(forWidth: w)).fixedSize()
        }
        .lineLimit(1)
        .frame(height: 18)
    }

    private func row(_ s: AgentSession, stacked: Bool) -> some View {
        let attention = needsYou(s)
        let extra = detail(s)
        let lit = store.flashed.contains(s.id)   // the notch was in use when this agent needed you: its row lights up for a moment
        return Button { store.focusID = s.id; navigator.open(.agents) } label: {
            Group {
                if stacked {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            dot(s, attention)
                            Text(s.project).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 2)
                            if let extra { detailText(extra) }
                        }
                        Text(Self.sentence(s)).font(.system(size: 10)).foregroundStyle(attention ? Color.orange : NotchInk.secondary)
                            .lineLimit(1).truncationMode(.tail).padding(.leading, 12)
                    }
                } else {
                    HStack(spacing: 6) {
                        dot(s, attention)
                        Text(s.project).font(.system(size: 11, weight: .semibold)).lineLimit(1).frame(width: 84, alignment: .leading)
                        Text(Self.sentence(s)).font(.system(size: 10)).foregroundStyle(attention ? Color.orange : NotchInk.secondary)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 2)
                        if let extra { detailText(extra) }
                    }
                }
            }
            .padding(.horizontal, 5)
            .frame(height: stacked ? 29 : 19)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(attention ? Color.orange.opacity(0.15) : Color.clear))
            .agentLit(lit, radius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dot(_ s: AgentSession, _ attention: Bool) -> some View {
        Circle().fill(attention ? Color.orange : s.state.color).frame(width: 6, height: 6)
    }

    private func detailText(_ d: (text: String, attention: Bool)) -> some View {
        Text(d.text).font(.system(size: 10, weight: .semibold)).monospacedDigit().lineLimit(1).fixedSize()
            .foregroundStyle(d.attention ? Color.orange : NotchInk.secondary)
    }
}

/// When Scout first found each agent: the order every row of agents keeps.
/// Agents found at the same moment go by when they started; one that is gone gives up its
/// place (the shared store says so), so if it comes back it joins at the end.
enum AgentFoundOrder {
    private static var rank: [String: Int] = [:]
    private static var next = 0

    static func sorted(_ sessions: [AgentSession]) -> [AgentSession] {
        let fresh = sessions.filter { rank[$0.id] == nil }.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
        for s in fresh { rank[s.id] = next; next += 1 }
        return sessions.sorted { (rank[$0.id] ?? 0) < (rank[$1.id] ?? 0) }
    }

    /// Agents that left the shared store give up their places (only those: a picture's or a test's own agents are never touched).
    static func forget(_ ids: Set<String>) {
        for id in ids { rank[id] = nil }
    }

    /// Self-tests: nobody found yet.
    static func reset() { rank = [:]; next = 0 }
}
