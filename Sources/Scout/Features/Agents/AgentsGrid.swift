import SwiftUI

/// The one order of every row of agents, and who shows when not everyone fits.
enum AgentTileMetrics {
    /// Every row of agents (the closed notch's faces, the header's faces, the TV's rooms, the den's stations, the plain list) in ONE
    /// fixed order: the order Scout found them in (`AgentFoundOrder`), the first found on the left (or on top), a new one joins on the right,
    /// and nobody changes places when its state changes.
    /// It used to sort by who needs you, so agents swapped places all day, and the faces sorted
    /// by their latest step.
    static func ordered(_ sessions: [AgentSession]) -> [AgentSession] {
        AgentFoundOrder.sorted(sessions)
    }

    /// How much an agent needs you (lower = more): a question, at work, finished, asleep. It only chooses WHO shows when not
    /// everyone fits; the row keeps the fixed order.
    static func urgency(_ s: AgentSession) -> Int {
        if AgentWingSummary.asks(s) { return 0 }
        switch s.state {
        case .working: return 1
        case .waiting, .done: return 2
        case .idle: return 3
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

    private var rows: [AgentSession] { AgentTileMetrics.ordered(store.sessions) }
    private func needsYou(_ s: AgentSession) -> Bool { s.state == .waiting }

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
