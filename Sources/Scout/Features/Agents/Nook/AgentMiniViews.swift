import SwiftUI

// The minimal look of the Agents.
// With `Retro.is8bit` OFF the pictures (Agent TV, the den, the pixel faces) give way to plain things: a list with one
// row per agent on the dashboard, a calm grid of cards with a plain detail card in the full view, and the old wing (a small cpu symbol and
// two numbers). Flat dark shapes, hairlines, the system font, SF Symbols; no new movement, fades only. The ONE rule for "needs you" is
// still `AgentWingSummary.asks` (through `AgentNookLook`), the order is still the one that needs you first.

/// The colour and the word of an agent's state in the minimal look.
enum AgentMini {
    /// Working = the app's accent, needs you = orange, finished = green, stopped = red, idle = grey.
    static func color(_ look: AgentNookLook) -> Color {
        switch look {
        case .working: Theme.accent
        case .needsYou: .orange
        case .finished: .green
        case .stopped: .red
        case .idle: Color.gray
        }
    }

    static func word(_ look: AgentNookLook) -> String {
        switch look {
        case .working: String(localized: "Working")
        case .needsYou: String(localized: "Needs you")
        case .finished: String(localized: "Done")
        case .stopped: String(localized: "Stopped")
        case .idle: String(localized: "Idle")
        }
    }

    static let calmTitle = String(localized: "No agents running")
    static let calmDetail = String(localized: "Claude Code and Codex show up here by themselves.")
    static let calmDetailShort = String(localized: "Agents show up here by themselves.")
}

// MARK: - What a row says

/// One agent as a plain row or card says it (a value, so it can be compared and tested).
struct AgentMiniRow: Identifiable, Equatable {
    var id: String
    var kind: AgentKind
    var project: String
    var look: AgentNookLook
    /// What it is doing, or its latest sentence; what it asks while it needs you.
    var line: String
    var helpers: Int
    var todoDone: Int
    var todoTotal: Int

    var progress: String? { todoTotal > 0 ? "\(todoDone)/\(todoTotal)" : nil }

    init(_ s: AgentSession) {
        id = s.id
        kind = s.agent
        project = s.project
        look = AgentNookLook.of(s)
        line = AgentWingSummary.asks(s) ? AgentNookText.firstSentence(AgentWingSummary.waitingLine(s)) : AgentNookText.sentence(s)
        helpers = max(0, s.subagents)
        todoDone = s.todosDone
        todoTotal = s.todos.count
    }

    /// One row per agent, in the one fixed order (the first started on top).
    static func rows(_ sessions: [AgentSession]) -> [AgentMiniRow] {
        AgentTileMetrics.ordered(sessions).map(AgentMiniRow.init)
    }

    var accessibilityText: String {
        var parts = [project, AgentMini.word(look)]
        if helpers > 0 { parts.append(String(localized: "Helpers: \(helpers)")) }
        if progress != nil { parts.append(String(localized: "To-dos: \(todoDone) of \(todoTotal)")) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - The dashboard panel

/// How many plain rows the 140 pt panel holds (pure arithmetic, so the self-test can check it). The panel follows the dashboard's grid
/// (`DashGrid`): its insets, no title,
/// so its first row stands at the top where every panel's first line does; one grid row per agent, the grid's "+N more" and empty line.
enum AgentMiniPanelLayout {
    static let padding = DashGrid.inset
    /// No title line.
    static let header: CGFloat = 0
    static let gap: CGFloat = 3
    static let moreLine: CGFloat = DashGrid.moreHeight
    /// A row's own room at each side (its hover wash): the rows reach out by it, so the dot stands at the panel's inset like every first letter.
    static let rowPadding: CGFloat = 5
    /// Under this width a row takes two lines (the project, then what it does).
    static let stackedBelow: CGFloat = 230
    /// From these widths the row also says its helpers, and the header the Mac's load.
    static let helpersFrom: CGFloat = 330
    static let loadFrom: CGFloat = 330

    /// The quiet fact at the right of the title when nobody needs you: how many work, else how many agents there are.
    static func fact(_ rows: [AgentMiniRow]) -> String {
        let working = rows.filter { $0.look == .working }.count
        return working > 0 ? String(localized: "\(working) working") : String(localized: "Agents: \(rows.count)")
    }

    struct Plan: Equatable {
        var stacked: Bool
        var shown: Int
        var more: Int
        var rowHeight: CGFloat
    }

    static func plan(width: CGFloat, height: CGFloat = NookMetrics.widgetHeight, count: Int) -> Plan {
        let stacked = width < stackedBelow
        let rowHeight: CGFloat = stacked ? 30 : DashGrid.rowHeight
        let avail = height - padding.top - padding.bottom - header
        func fit(_ room: CGFloat) -> Int { max(0, Int(((room + gap) / (rowHeight + gap)).rounded(.down))) }
        if count <= fit(avail) { return Plan(stacked: stacked, shown: count, more: 0, rowHeight: rowHeight) }
        let n = max(1, fit(avail - moreLine - gap))
        return Plan(stacked: stacked, shown: n, more: count - n, rowHeight: rowHeight)
    }
}

/// The Agents panel of the dashboard without the TV: a title, then one plain row per agent (a state dot, the project, one line of what it
/// does, the helpers and the to-do progress where there is room), the ones that need you first, "+N more" when the rest do not fit, a calm
/// line when no agent is found. A click on a row picks that agent and opens the Agents view; a click anywhere else on the panel opens it too.
/// It paints its own flat face (the dashboard gives the TV none).
struct AgentMiniPanel: View {
    @ObservedObject var store: AgentsStore
    @Environment(\.notchNavigator) private var navigator
    /// An agent id: its row lights for a moment.
    var lit: String?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let rows = AgentMiniRow.rows(store.sessions)
            let plan = AgentMiniPanelLayout.plan(width: w, height: geo.size.height, count: rows.count)
            VStack(alignment: .leading, spacing: 0) {
                if rows.isEmpty {
                    calm(width: w)
                } else {
                    VStack(alignment: .leading, spacing: AgentMiniPanelLayout.gap) {
                        ForEach(AgentTileMetrics.keepOrder(rows, limit: plan.shown) { AgentTileMetrics.need($0.look) }) { row in
                            AgentMiniRowButton(row: row, stacked: plan.stacked, width: w, lit: lit == row.id || store.flashed.contains(row.id)) {
                                store.focusID = row.id
                                navigator.open(.agents)
                            }
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: AgentNookFramesKey.self, value: [row.id: proxy.frame(in: .named("agentnook"))])
                            })
                        }
                        if plan.more > 0 {
                            Button { navigator.open(.agents) } label: {
                                DashMore(count: plan.more)
                                    .padding(.leading, AgentMiniPanelLayout.rowPadding)
                                    .frame(height: AgentMiniPanelLayout.moreLine, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: AgentNookFramesKey.self, value: ["door": proxy.frame(in: .named("agentnook"))])
                            })
                        }
                    }
                    .padding(.horizontal, -AgentMiniPanelLayout.rowPadding)
                }
                Spacer(minLength: 0)
            }
            .padding(AgentMiniPanelLayout.padding)
            .frame(width: w, height: geo.size.height, alignment: .topLeading)
        }
        // No face of its own: it lies on the island like every other panel, so the glass shows through
        .contentShape(Rectangle())
        .onTapGesture { navigator.open(.agents) }
        .notchContent()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agents")
    }

    /// No agent found: the grid's empty line where the first row would stand.
    private func calm(width w: CGFloat) -> some View {
        DashEmpty(symbol: "cpu", title: .verbatim(AgentMini.calmTitle), detail: .verbatim(w < AgentMiniPanelLayout.stackedBelow ? AgentMini.calmDetailShort : AgentMini.calmDetail))
    }
}

/// One plain row of the panel as a button. Hovering only brightens it.
struct AgentMiniRowButton: View {
    var row: AgentMiniRow
    var stacked: Bool
    var width: CGFloat
    var lit: Bool
    var action: () -> Void
    @State private var hover = false

    private var asks: Bool { row.look == .needsYou }
    private var showHelpers: Bool { row.helpers > 0 && width >= (stacked ? 190 : AgentMiniPanelLayout.helpersFrom) }
    private var nameWidth: CGFloat { width >= 330 ? 84 : 64 }

    var body: some View {
        Button(action: action) {
            Group {
                if stacked {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            dot
                            Text(row.project).font(DashGrid.rowTitle).lineLimit(1)
                            Spacer(minLength: 2)
                            meta.layoutPriority(1)
                        }
                        Text(row.line).font(DashGrid.rowText).foregroundStyle(asks ? Color.orange : NotchInk.secondary)
                            .lineLimit(1).truncationMode(.tail).padding(.leading, 12)
                    }
                } else {
                    HStack(spacing: 6) {
                        dot
                        Text(row.project).font(DashGrid.rowTitle).lineLimit(1).frame(width: nameWidth, alignment: .leading)
                        Text(row.line).font(DashGrid.rowText).foregroundStyle(asks ? Color.orange : NotchInk.secondary)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 2)
                        meta.layoutPriority(1)
                    }
                }
            }
            .padding(.horizontal, AgentMiniPanelLayout.rowPadding)
            .frame(height: stacked ? 30 : DashGrid.rowHeight)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(asks ? Color.orange.opacity(0.14) : (hover ? Look.ink(0.06) : Color.clear)))
            .agentLit(lit, radius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("\(row.project): \(AgentMini.word(row.look))")
        .accessibilityLabel(row.accessibilityText)
    }

    private var dot: some View { Circle().fill(AgentMini.color(row.look)).frame(width: 6, height: 6) }

    /// The helpers and the to-do progress, small, at the right.
    private var meta: some View {
        HStack(spacing: 6) {
            if showHelpers {
                HStack(spacing: 2) {
                    Image(systemName: "person.2").font(.system(size: 8.5, weight: .medium))
                    Text("\(row.helpers)")
                }
                .help("Helpers: \(row.helpers)")
            }
            if let progress = row.progress { Text(progress) }
        }
        .font(DashGrid.infoFont(.semibold)).lineLimit(1)
        .foregroundStyle(NotchInk.secondary)
        .fixedSize()
    }
}

// MARK: - The full Agents view

/// How tall the minimal full view is (the island height adds the header on top).
enum AgentMiniLayout {
    static let cardHeight: CGFloat = 92
    static let compactHeight: CGFloat = 58
}

/// The Agents view in the minimal look: a list of the agents at the left (one row each, in the fixed order; a click picks one) and, at the
/// right, the picked agent's whole history down to the island's bottom edge (the first agent while none is picked): its state and time, its
/// latest message, the step it is on, its to-do list, its helpers and its steps.
/// The rows and the card report their frames like the den does (`agentden` space).
struct AgentMiniView: View {
    @ObservedObject var store: AgentsStore
    var detailID: String?
    var banner: AgentAnnouncement?
    var empty = AgentDenEmptyNote()
    var onSelect: (String?) -> Void = { _ in }

    static let margin: CGFloat = 12
    static let gap: CGFloat = 8

    /// The list column: about a third of the view, never narrower than a readable row nor wider than it needs.
    static func listWidth(for width: CGFloat) -> CGFloat { min(340, max(220, (width - 3 * margin) * 0.32)) }

    /// The agent whose history shows on the right: the one picked, else the first in the fixed order.
    static func shownID(_ rows: [AgentMiniRow], picked: String?) -> String? {
        if let picked, rows.contains(where: { $0.id == picked }) { return picked }
        return rows.first?.id
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let rows = AgentMiniRow.rows(store.sessions)
            let shown = Self.shownID(rows, picked: detailID)
            let detail = shown.flatMap { id in store.sessions.first { $0.id == id } }
            let listWidth = Self.listWidth(for: size.width)
            let inner = max(0, size.height - 2 * Self.margin)
            Group {
                if rows.isEmpty {
                    emptyState
                } else {
                    // The list at the left, the history at the right, both down to the island's bottom edge (pulling the notch down gives both more).
                    HStack(alignment: .top, spacing: Self.margin) {
                        list(rows, selected: shown)
                            .frame(width: listWidth, height: inner, alignment: .top)
                        if let detail {
                            AgentMiniDetail(session: detail, banner: banner?.sessionID == detail.id ? banner : nil, fills: true, onClose: nil)
                                .frame(maxWidth: .infinity)
                                .frame(height: inner, alignment: .top)
                                .denFrame("window")
                        }
                    }
                    .padding(Self.margin)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(Rectangle())
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agents")
    }

    /// "3 agents · 1 needs you · 2 working", then one row per agent in the fixed order (the one shown is lit).
    private func list(_ rows: [AgentMiniRow], selected: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(Self.summary(rows)).font(.system(size: 11, weight: .semibold)).foregroundStyle(NotchInk.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Self.gap) {
                    ForEach(rows) { row in
                        AgentMiniCard(row: row, session: store.sessions.first { $0.id == row.id }, selected: row.id == selected, lit: store.flashed.contains(row.id), compact: true) {
                            if row.id != selected { onSelect(row.id) }   // the one shown stays as it is, nothing animates again
                        }
                        .frame(maxWidth: .infinity)
                        .denFrame(row.id)
                    }
                }
            }
        }
    }

    static func summary(_ rows: [AgentMiniRow]) -> String {
        var parts = [String(localized: "Agents: \(rows.count)")]
        let needs = rows.filter { $0.look == .needsYou }.count, working = rows.filter { $0.look == .working }.count
        if needs > 0 { parts.append(String(localized: "Needs you: \(needs)")) }
        if working > 0 { parts.append(String(localized: "Working: \(working)")) }
        return parts.joined(separator: " · ")
    }

    /// No agent found: one calm card with the line and, when there is something to do about it, a plain button.
    private var emptyState: some View {
        let note = empty.opensSettings
        return NotchEmptyState(symbol: "cpu", message: Text(verbatim: AgentMini.calmTitle),
                               detail: note ? Text("Start Claude Code or Codex and every session shows up here by itself, with its progress. Nothing to connect.") : Text(verbatim: empty.line),
                               actionTitle: empty.keyTitle.map { Text(verbatim: $0) }, action: empty.action)
            .denFrame("emptynote")
    }
}

/// One agent as a card: its project, its state, what it does (or asks), the to-do progress, the helpers and how long.
struct AgentMiniCard: View {
    var row: AgentMiniRow
    var session: AgentSession?
    var selected: Bool
    var lit: Bool
    /// While a detail card is open the cards shrink to two lines (the project and its state, what it does) so the whole list stays in view.
    var compact = false
    var action: () -> Void
    @State private var hover = false

    private var asks: Bool { row.look == .needsYou }
    private var tint: Color { AgentMini.color(row.look) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    AgentGlyph(agent: row.kind, size: 11)
                    Text(row.project).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    HStack(spacing: 4) {
                        Circle().fill(tint).frame(width: 6, height: 6)
                        Text(AgentMini.word(row.look)).font(.system(size: 10, weight: .medium)).foregroundStyle(asks ? Color.orange : NotchInk.secondary).lineLimit(1)
                    }
                    .fixedSize()
                }
                Text(row.line).font(.system(size: 11)).foregroundStyle(asks ? Color.orange : NotchInk.secondary)
                    .lineLimit(compact ? 1 : 2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: compact ? 0 : 28, alignment: .topLeading)
                if !compact { Spacer(minLength: 0) }
                if !compact { HStack(spacing: 8) {
                    if row.todoTotal > 0 {
                        ZStack(alignment: .leading) {
                            Capsule().fill(NotchInk.tileStrong)
                            GeometryReader { g in Capsule().fill(tint).frame(width: g.size.width * CGFloat(row.todoDone) / CGFloat(max(1, row.todoTotal))) }
                        }
                        .frame(width: 40, height: 4)
                        Text(row.progress ?? "").font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(NotchInk.secondary)
                    }
                    if row.helpers > 0 {
                        Label("\(row.helpers)", systemImage: "person.2").labelStyle(.titleAndIcon)
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(NotchInk.secondary)
                            .help("Helpers: \(row.helpers)")
                    }
                    Spacer(minLength: 0)
                    if let session { elapsed(session) }
                }
                .lineLimit(1) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: compact ? AgentMiniLayout.compactHeight : AgentMiniLayout.cardHeight)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(asks ? Color.orange.opacity(0.12) : Look.ink(hover ? 0.085 : 0.06)))
            .agentLit(lit, radius: 10)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Theme.accent.opacity(0.9) : (asks ? Color.orange.opacity(0.45) : Retro.hairline), lineWidth: selected ? 1.2 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("\(row.project): \(AgentMini.word(row.look))")
        .accessibilityLabel(row.accessibilityText)
    }

    @ViewBuilder private func elapsed(_ s: AgentSession) -> some View {
        switch AgentDenWindow.clockMode(row.look) {
        case .running: AgentElapsed(start: s.turnStartedAt).font(.system(size: 10)).foregroundStyle(NotchInk.tertiary)
        case .fixed: AgentElapsed(start: s.turnStartedAt, end: s.finishedAt ?? s.lastEventAt).font(.system(size: 10)).foregroundStyle(NotchInk.tertiary)
        case .none: EmptyView()
        }
    }
}

/// The plain detail card of one agent, beside the grid: a header with a close button, its state and time, the banner of an automatic
/// opening, the latest message, the step it is on, its to-do list, its helpers and the last steps.
struct AgentMiniDetail: View {
    let session: AgentSession
    var banner: AgentAnnouncement?
    /// Fills the height it is given and lists the whole history (all the steps and to-dos kept), scrolling inside.
    var fills = false
    /// Nil: no close key (the full view always shows one agent).
    var onClose: (() -> Void)?
    @State private var contentHeight: CGFloat = 400

    private var look: AgentNookLook { AgentNookLook.of(session) }
    private var tint: Color { AgentMini.color(look) }

    private var message: String {
        if !session.lastMessage.isEmpty { return session.lastMessage }
        if !session.title.isEmpty { return session.title }
        return String(localized: "No message yet.")
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            ScrollView(.vertical, showsIndicators: false) {
                content.background(GeometryReader { proxy in Color.clear.preference(key: AgentMiniHeightKey.self, value: proxy.size.height) })
            }
            .frame(maxHeight: fills ? .infinity : contentHeight)
            .onPreferenceChange(AgentMiniHeightKey.self) { contentHeight = $0 }
        }
        .frame(maxHeight: fills ? .infinity : nil, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Look.ink(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Retro.hairline, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(session.project), \(AgentMini.word(look))")
    }

    private var header: some View {
        HStack(spacing: 7) {
            AgentGlyph(agent: session.agent, size: 12)
            Text(session.project).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(session.agent.title).font(.system(size: 10.5)).foregroundStyle(NotchInk.tertiary).lineLimit(1)
            Spacer(minLength: 4)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(NotchInk.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(NotchInk.tile))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Back to all agents")
                .accessibilityLabel("Close the card")
                .denFrame("close")
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let banner { AgentBanner(announcement: banner, session: session).denFrame("banner") }
            stateLine
            if banner == nil || session.lastMessage.isEmpty {
                Text(message).font(.system(size: 12)).lineSpacing(2).foregroundStyle(NotchInk.primary).fixedSize(horizontal: false, vertical: true)
            }
            if look == .working || look == .needsYou, let step = session.currentStep { currentStep(step) }
            if !session.todos.isEmpty { todos }
            if session.subagents > 0 { helpers }
            recent
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stateLine: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(AgentMini.word(look)).font(.system(size: 11, weight: .semibold)).foregroundStyle(look == .needsYou ? Color.orange : NotchInk.primary)
            switch AgentDenWindow.clockMode(look) {
            case .running: AgentElapsed(start: session.turnStartedAt).font(.system(size: 11)).foregroundStyle(NotchInk.secondary)
            case .fixed: AgentElapsed(start: session.turnStartedAt, end: session.finishedAt ?? session.lastEventAt).font(.system(size: 11)).foregroundStyle(NotchInk.secondary)
            case .none: EmptyView()
            }
            Spacer(minLength: 0)
        }
    }

    private func currentStep(_ step: AgentStep) -> some View {
        HStack(spacing: 7) {
            Image(systemName: toolSymbol(step.tool)).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 14)
            Text(step.tool).font(.system(size: 11, weight: .semibold))
            Text(step.summary).font(.system(size: 11, design: step.tool == "Bash" ? .monospaced : .default)).foregroundStyle(NotchInk.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.accent.opacity(0.12)))
    }

    /// The agent's own to-do list: a slim bar with "2 of 5", then the items (done ones ticked, the one it is on lit), at most six.
    private var todos: some View {
        let total = session.todos.count, done = session.todosDone
        let shown = Array(session.todos.prefix(fills ? 60 : 6))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    Capsule().fill(NotchInk.tileStrong)
                    GeometryReader { g in Capsule().fill(tint).frame(width: g.size.width * CGFloat(done) / CGFloat(max(1, total))) }
                }
                .frame(width: 70, height: 4)
                Text("\(done) of \(total)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                Spacer(minLength: 0)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { _, todo in
                HStack(spacing: 6) {
                    Image(systemName: todo.status == .completed ? "checkmark.circle.fill" : (todo.status == .inProgress ? "circle.inset.filled" : "circle"))
                        .font(.system(size: 10)).foregroundStyle(todo.status == .completed ? Color.green : (todo.status == .inProgress ? Theme.accent : NotchInk.tertiary)).frame(width: 14)
                    Text(todo.status == .inProgress ? todo.active : todo.text).font(.system(size: 11))
                        .foregroundStyle(todo.status == .pending ? NotchInk.secondary : NotchInk.primary).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            if total > shown.count { Text("+\(total - shown.count) more").font(.system(size: 10)).foregroundStyle(NotchInk.tertiary).padding(.leading, 20) }
        }
    }

    private var helpers: some View {
        Label("Helpers: \(session.subagents)", systemImage: "person.2")
            .font(.system(size: 11, weight: .medium)).foregroundStyle(NotchInk.secondary)
    }

    /// The last finished steps, small.
    @ViewBuilder private var recent: some View {
        let steps = Array(session.steps.filter { $0.done && $0.tool != "Prompt" }.suffix(fills ? 60 : 5).reversed())
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(steps) { step in
                    HStack(spacing: 6) {
                        Image(systemName: step.failed ? "exclamationmark.triangle.fill" : toolSymbol(step.tool)).font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(step.failed ? Color.orange : NotchInk.tertiary).frame(width: 14)
                        Text(step.tool).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(NotchInk.secondary).frame(width: 50, alignment: .leading)
                        Text(step.summary).font(.system(size: 10.5, design: step.tool == "Bash" ? .monospaced : .default)).foregroundStyle(NotchInk.tertiary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

private struct AgentMiniHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - The automatic opening's banner

/// What the notch says when it opens by itself, in the minimal look: a flat card with the state's symbol and one bold line ("infra needs you",
/// "site finished after 12 min", "api stopped with an error"), the failed step for an error, and the first words of the latest message.
struct AgentMiniBanner: View {
    let announcement: AgentAnnouncement
    let session: AgentSession

    private var symbol: String {
        switch announcement.kind {
        case .needsYou: "questionmark.circle.fill"
        case .finished: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch announcement.kind {
        case .needsYou: .orange
        case .finished: .green
        case .error: .red
        }
    }

    private var failedStep: String? {
        guard announcement.kind == .error, let step = session.steps.last(where: { $0.failed }) else { return nil }
        return String(localized: "\(step.tool) \(step.summary) failed")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(tint).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(AgentBanner.headline(announcement, project: session.project)).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint).lineLimit(1)
                if let failedStep { Text(failedStep).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(NotchInk.secondary).lineLimit(1) }
                if !session.lastMessage.isEmpty {
                    Text(session.lastMessage).font(.system(size: 11)).foregroundStyle(NotchInk.primary.opacity(0.9)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.13)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AgentBanner.headline(announcement, project: session.project))
    }
}
