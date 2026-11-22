import Combine
import SwiftUI
import UniformTypeIdentifiers

// A3 — the Nook: the DASHBOARD, one screen of panels in a row, edit mode with a palette.
// It is a minimal, live "what is happening on my Mac right now", agentic first: the Agents panel (with the Mac's CPU and memory)
// and the Ask AI line are always there; everything else shows only while it is live (music playing, a meeting about to start, a
// timer running, a download, a recording, AirPods just connected, to-dos due today) and is gone when it stops. Panels the user
// pins with the "+" menu stay. A panel that has a detail EXPANDS into it when it is clicked (or the pointer rests on it).

/// One thing in the dashboard's row: a pinned panel, an agent tab's panel (full edition), the Now Playing panel while something
/// plays, or a live panel from `LivePanels` (shown only while it is live).
enum NookItem: Hashable, Identifiable {
    case panel(WidgetKind)
    case tab(String)
    case nowPlaying
    case live(String)

    var id: String {
        switch self {
        case .panel(let kind): kind.rawValue
        case .tab(let id): "tab.\(id)"
        case .nowPlaying: "live.nowPlaying"
        case .live(let id): id
        }
    }

    @MainActor var defaultSpan: Int {
        switch self {
        case .panel(let kind): kind.defaultSpan
        case .tab: NookMetrics.tabSpan
        case .nowPlaying: WidgetKind.media.defaultSpan
        case .live(let id): LivePanelLookup.source(id)?.span ?? 4
        }
    }

    var kind: WidgetKind? {
        if case .panel(let kind) = self { return kind }
        return nil
    }

    @MainActor var title: String {
        switch self {
        case .panel(let kind): kind.title
        case .tab(let id): Registry.agentTabTitle(id)
        case .nowPlaying: String(localized: "Now playing")
        case .live(let id): LivePanelLookup.source(id)?.title ?? String(localized: "Live")
        }
    }

    /// The detail this panel grows into (an agent tab grows into its terminal), nil = the panel only has its own controls.
    @MainActor var detail: WorkspaceKind? {
        switch self {
        case .panel(let kind): kind.detail
        case .tab: nil
        case .nowPlaying: .music
        case .live(let id): LivePanelLookup.source(id)?.expandTo
        }
    }

    @MainActor var hasDetail: Bool {
        if case .tab = self { return true }
        return detail != nil
    }

    /// Every panel lights up under the pointer, also the ones that only have their own keys
    @MainActor var highlightsOnHover: Bool { true }
}

/// Finds a live panel by id (the real ones, or the preview ones a gallery scene or self-test hands the store).
@MainActor
enum LivePanelLookup {
    static var override: [any LivePanelSource]?

    static var current: [any LivePanelSource] { override ?? LivePanels.shared.live }

    static func source(_ id: String) -> (any LivePanelSource)? {
        (override ?? (LivePanels.shared.live + LivePanels.shared.all)).first { $0.id == id }
    }
}

/// What is alive right now (the part the dashboard decides on itself; `LivePanels` decides the rest). Gallery and
/// self-tests: `NookStore.liveOverride` stands in for the services.
struct NookLive: Equatable {
    var playing = false
    /// Open to-dos in all (kept for older scenes).
    var openTodos = 0
    var agents = 0
}

@MainActor
final class NookStore: ObservableObject {
    static let shared = NookStore()

    @Published private(set) var layout: [WidgetKind]
    @Published var isEditing = false
    /// The widget being dragged right now (from the row or from the palette).
    @Published var dragging: WidgetKind?
    private let persist: Bool
    /// Gallery only: pretend this is what plays, what is open and what runs.
    var liveOverride: NookLive?
    /// The ids of the agent tabs to show as panels (full edition). Self-tests and the gallery replace it.
    var tabIDs: () -> [String] = { Registry.agentTabIDs() }
    /// Gallery and self-tests: a panel's view instead of the real one (a stub with a button, say).
    var viewOverride: ((NookItem) -> AnyView?)?
    /// Where each panel is ("panel.<id>" → rect in the notch panel's space), reported by the cells. Not published: it changes with every layout.
    var panelRects: [String: CGRect] = [:]
    /// The panel the pointer was last on: the island's expand animation grows from it.
    var lastPanel: String?
    /// Where the buttons inside the panels are (`nookControl()`), for the self-tests.
    var controlRects: [CGRect] = []
    /// How wide the grid is right now (the cells report it): "+" uses it to say when a pinned panel has no room.
    var gridWidth: CGFloat = 0
    private var cancellables = Set<AnyCancellable>()
    private var lastSignature = ""

    static let layoutKey = "nook.layout"
    static let migratedKey = "nook.liveDashboard1"
    /// Once: the CPU and memory graph and the Today panel join a saved dashboard (the owner, 2026-11-15).
    static let pulseTodayKey = "nook.pulseToday1"
    static let backupKey = "nook.layout.beforeLive"

    init(persist: Bool = true, layout: [WidgetKind]? = nil) {
        self.persist = persist
        var migrated = false
        if let layout {
            self.layout = layout
        } else if persist, let saved = UserDefaults.standard.stringArray(forKey: "nook.layout") {
            // Once: a layout saved by an earlier build moves to the live dashboard (the Agents panel and the Ask AI line; the
            // rest shows while it is live or is pinned with "+"). The old list is kept under "nook.layout.beforeLive" so nothing is
            // lost. After that every change the user makes is saved and comes back as it was.
            if !Pref.bool(Self.migratedKey, false) {
                Pref.set(true, Self.migratedKey)
                Pref.set(saved, Self.backupKey)
                self.layout = WidgetKind.defaultLayout
                migrated = true
            } else {
                var seen = Set<WidgetKind>()
                let kept = saved.compactMap(WidgetKind.init(rawValue:)).filter { $0.isAvailable && seen.insert($0).inserted }
                // A saved list that names nothing this build knows (damaged, or from another edition) is not an empty dashboard.
                self.layout = (kept.isEmpty && !saved.isEmpty) ? WidgetKind.defaultLayout : kept
                migrated = kept.isEmpty && !saved.isEmpty
            }
        } else {
            if persist { Pref.set(true, Self.migratedKey) }
            self.layout = WidgetKind.defaultLayout
        }
        if persist, !Pref.bool(Self.pulseTodayKey, false) {
            Pref.set(true, Self.pulseTodayKey)
            let missing = [WidgetKind.pulse, .today].filter { !self.layout.contains($0) }
            if !missing.isEmpty { self.layout += missing; migrated = true }
        }
        if migrated { save() }
        if persist { watchServices() }
    }

    // MARK: Watching what is live (the open notch sizes itself from it, so the store tells everyone when it changes)

    private func watchServices() {
        lastSignature = signature()
        var changes: [AnyPublisher<Void, Never>] = [
            NowPlayingService.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            AgentsStore.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            LivePanels.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            Timer.publish(every: 15, on: .main, in: .common).autoconnect().map { _ in () }.eraseToAnyPublisher(),
        ]
        changes.append(Registry.agentTabChanges())
        Publishers.MergeMany(changes).sink { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.recheck() } }
        }.store(in: &cancellables)
    }

    /// What decides the row, as one string: the views are told only when it changes (a service publishes far more often).
    private func signature() -> String {
        let now = computeLive()
        return "\(now.playing)|\(now.agents)|\(LivePanelLookup.current.map(\.id).joined(separator: ","))|\(Registry.agentTabIDs().joined(separator: ","))"
    }

    private func recheck() {
        let current = signature()
        if current != lastSignature {
            lastSignature = current
            objectWillChange.send()
        }
    }

    private func save() {
        guard persist else { return }
        UserDefaults.standard.set(layout.map(\.rawValue), forKey: "nook.layout")
    }

    var palette: [WidgetKind] { WidgetKind.available.filter { !layout.contains($0) } }

    func add(_ kind: WidgetKind, at index: Int? = nil) {
        guard !layout.contains(kind) else { return }
        layout.insert(kind, at: min(max(0, index ?? layout.count), layout.count))
        save()
    }

    func remove(_ kind: WidgetKind) {
        layout.removeAll { $0 == kind }
        save()
    }

    /// Puts `kind` at `index` (counted before removing it), adding it when it is not in the row yet.
    func place(_ kind: WidgetKind, at index: Int) {
        if let from = layout.firstIndex(of: kind) {
            guard from != index else { return }
            layout.remove(at: from)
            layout.insert(kind, at: min(max(0, index > from ? index - 1 : index), layout.count))
            save()
        } else {
            add(kind, at: index)
        }
    }

    func restoreDefaults() {
        layout = WidgetKind.defaultLayout
        save()
    }

    func beginEditing(navigator: NotchNavigator? = nil) {
        let nav = navigator ?? NotchNavigator.shared
        isEditing = true
        nav.hold("nook-edit")
        nav.open(.nook)
    }

    func endEditing(navigator: NotchNavigator? = nil) {
        let nav = navigator ?? NotchNavigator.shared
        isEditing = false
        dragging = nil
        nav.release("nook-edit")
    }

    // MARK: What shows (the pinned panels, plus whatever is live right now)

    func live() -> NookLive { liveOverride ?? computeLive() }

    private func computeLive() -> NookLive {
        NookLive(playing: NowPlayingService.shared.isPlaying, openTodos: TodoStore.shared.openCount, agents: AgentsStore.shared.sessions.count)
    }

    /// The panels of what is live right now: the music while something plays (unless the Media panel is pinned), then the
    /// live panels (`LivePanels`, already in their order), each unless it is the same as a pinned panel.
    func liveItems() -> [NookItem] {
        var items: [NookItem] = []
        if live().playing, !layout.contains(.media) { items.append(.nowPlaying) }
        // Today shows the day's meetings and to-dos itself, so their live panels stay away while it is pinned.
        let byToday: Set<String> = layout.contains(.today) ? ["live.meeting", "live.todos"] : []
        items += LivePanelLookup.current.filter { !byToday.contains($0.id) }.map { NookItem.live($0.id) }
        return items
    }

    /// The panels in the row right now, left to right: the pinned panels in their order (Edit Nook shows only these), with the
    /// agent tabs (full edition) right after the Agents panel, and the live panels after the pinned ones.
    var row: [NookItem] {
        var pinned = layout.map(NookItem.panel)
        if isEditing { return pinned }
        let tabs = tabIDs().map(NookItem.tab)
        if !tabs.isEmpty { pinned.insert(contentsOf: tabs, at: pinned.firstIndex(of: .panel(.agents)).map { $0 + 1 } ?? 0) }
        return pinned + liveItems()
    }

    /// The widths (in cells) of what is in the row, for the width of the open notch.
    @MainActor var sizingSpans: [Int] { row.map(\.defaultSpan) }

    /// The least room a panel takes in the row when the others need the room: the agents dashboard shrinks to 3 cells, and a
    /// live panel (or the music) gives up one cell. With music, a meeting and a download live, a
    /// full row dropped the download, while the panels could simply be a little narrower.
    @MainActor private func minSpan(_ item: NookItem) -> Int {
        guard !isEditing else { return item.defaultSpan }
        switch item {
        case .panel(.agents): return 3
        case .panel(.pulse): return 4   // its extra cell (two in the minimal look) holds the GPU reading; without it the panel is what it was (CPU and memory)
        case .live, .nowPlaying: return item.defaultSpan > 3 ? item.defaultSpan - 1 : item.defaultSpan
        default: return item.defaultSpan
        }
    }

    /// The widths (in cells) of the panels in `shown` for a row `width` wide. Each panel has its own width; when they do not
    /// fit, first the music, then the live panels from the last one back, give up one cell each, only as many as needed. The
    /// agents dashboard takes what is left (3 to 16 cells; with no agent running, a calm 5 so the Mac's CPU and memory fit
    /// beside "No agents running").
    @MainActor func spans(for shown: [NookItem], width: CGFloat) -> [NookItem: Int] {
        guard !isEditing else { return Dictionary(shown.map { ($0, $0.defaultSpan) }, uniquingKeysWith: { a, _ in a }) }
        var spans = Dictionary(shown.map { ($0, $0 == .panel(.agents) ? 3 : $0.defaultSpan) }, uniquingKeysWith: { a, _ in a })
        let gaps = CGFloat(max(0, shown.count - 1)) * NookMetrics.spacing
        func used() -> CGFloat { CGFloat(spans.values.reduce(0, +)) * NookMetrics.cell + gaps }
        let livePanels = shown.filter { if case .live = $0 { return true } else { return false } }
        // The Pulse panel's extra cells (the GPU reading) come only out of room the row has to spare: they are the first to go, before the Agents
        // panel's fourth cell, the music or a live panel has to give up anything, so a row that fitted before this reading is laid out as it was.
        let pulse = NookItem.panel(.pulse)
        if let pulseSpan = spans[pulse], pulseSpan > minSpan(pulse) {
            let agentsRoom = spans[.panel(.agents)] != nil ? NookMetrics.cell : 0
            if used() + agentsRoom > width + 0.5 { spans[pulse] = minSpan(pulse) }
        }
        for item in shown.filter({ $0 == .nowPlaying }) + livePanels.reversed() where used() > width + 0.5 {
            spans[item] = minSpan(item)
        }
        if spans[.panel(.agents)] != nil {
            let free = width - used() + 3 * NookMetrics.cell
            spans[.panel(.agents)] = max(3, min(live().agents == 0 ? 5 : 16, Int(free / NookMetrics.cell)))
        }
        return spans
    }

    /// A panel's width in cells in this row (see `spans(for:width:)`).
    func span(of item: NookItem, in shown: [NookItem], width: CGFloat) -> Int {
        spans(for: shown, width: width)[item] ?? item.defaultSpan
    }

    /// The panels that fit in `width`, and how many are left out. Pinned panels have first claim on the room, then agent tabs,
    /// then the live panels. (The CPU and memory graph no longer steps aside when the row is tight: the owner wants it there.)
    func visible(in width: CGFloat) -> (shown: [NookItem], hidden: Int) {
        fitting(row, in: width)
    }

    /// How many rows of panels a grid `height` tall holds: one at the default 180 pt notch, one more for each further panel height, at
    /// most `maxRows`.
    static func rowCount(height: CGFloat) -> Int {
        min(maxRows, max(1, Int((height + NookMetrics.spacing) / (NookMetrics.widgetHeight + NookMetrics.spacing))))
    }

    /// At most three rows of widgets.
    static let maxRows = 3

    /// The island's open height for `rows` rows of panels: the 180 pt notch holds one, each more row adds a panel and a gap.
    static func rowsHeight(_ rows: Int) -> CGFloat {
        CGFloat(NotchPrefs.defaultOpenHeight) + CGFloat(max(0, rows - 1)) * (NookMetrics.widgetHeight + NookMetrics.spacing)
    }

    /// How wide a row of these panels is drawn.
    func rowWidth(_ items: [NookItem], width: CGFloat) -> CGFloat {
        let spans = spans(for: items, width: width)
        return CGFloat(items.reduce(0) { $0 + (spans[$1] ?? $1.defaultSpan) }) * NookMetrics.cell + CGFloat(max(0, items.count - 1)) * NookMetrics.spacing
    }

    /// The panels in rows: the first row as `visible(in:)` fills it, and what does not fit there goes on in the next rows (each filled the
    /// same way), as many rows as `maxRows`. `hidden`: what still does not fit.
    /// Strictly in order, left to right: the first panel that does not fit ends the row and starts the next one, so a smaller panel never
    /// jumps ahead of a bigger one and nothing swaps places while the notch's width changes.
    /// Pinned panels come first, then
    /// agent tabs, then the live panels, as in `visible(in:)`.
    func rows(in width: CGFloat, maxRows: Int) -> (rows: [[NookItem]], hidden: Int) {
        func rank(_ item: NookItem) -> Int {
            switch item {
            case .panel: 0
            case .tab: 1
            case .nowPlaying, .live: 2
            }
        }
        let ordered = row.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        var out: [[NookItem]] = [[]]
        var used: CGFloat = 0
        var placed = 0
        for item in ordered {
            let w = CGFloat(minSpan(item)) * NookMetrics.cell
            let needed = w + (out[out.count - 1].isEmpty ? 0 : NookMetrics.spacing)
            if used + needed > width + 0.5, !out[out.count - 1].isEmpty {
                guard out.count < max(1, maxRows) else { break }
                out.append([])
                used = 0
                if w > width + 0.5 { break }
                out[out.count - 1].append(item)
                used = w
            } else if used + needed <= width + 0.5 {
                out[out.count - 1].append(item)
                used += needed
            } else {
                break   // wider than a whole row
            }
            placed += 1
        }
        // Inside each row the panels keep the row's own order (a live panel after the pinned ones).
        let rows = out.map { picked in row.filter { picked.contains($0) } }
        return (rows, row.count - placed)
    }

    private func fitting(_ candidates: [NookItem], in width: CGFloat) -> (shown: [NookItem], hidden: Int) {
        func rank(_ item: NookItem) -> Int {
            switch item {
            case .panel: 0
            case .tab: 1
            case .nowPlaying, .live: 2
            }
        }
        let claimOrder = candidates.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        var used: CGFloat = 0
        var chosen = Set<NookItem>()
        for item in claimOrder {
            let w = CGFloat(minSpan(item)) * NookMetrics.cell
            let needed = w + (chosen.isEmpty ? 0 : NookMetrics.spacing)
            if used + needed > width + 0.5 { continue }
            used += needed
            chosen.insert(item)
        }
        let shown = candidates.filter { chosen.contains($0) }
        return (shown, candidates.count - shown.count)
    }
}

private struct NookStoreKey: EnvironmentKey {
    @MainActor static var defaultValue: NookStore { NookStore.shared }
}

private struct NotchNavigatorKey: EnvironmentKey {
    @MainActor static var defaultValue: NotchNavigator { NotchNavigator.shared }
}

extension EnvironmentValues {
    var nookStore: NookStore {
        get { self[NookStoreKey.self] }
        set { self[NookStoreKey.self] = newValue }
    }

    /// The navigator of the notch this view is in (the gallery and the self-tests have their own).
    var notchNavigator: NotchNavigator {
        get { self[NotchNavigatorKey.self] }
        set { self[NotchNavigatorKey.self] = newValue }
    }
}

struct NookWorkspaceView: View {
    @Environment(\.nookStore) private var store

    var body: some View { NookGrid(store: store) }
}

struct NookGrid: View {
    @ObservedObject var store: NookStore
    @AppStorage("nook.dividers") private var dividers = false
    // The row follows what plays, what is open and what runs.
    @ObservedObject private var playing = NowPlayingService.shared
    @ObservedObject private var todos = TodoStore.shared
    @ObservedObject private var agents = AgentsStore.shared
    #if !APPSTORE
    @ObservedObject private var tabs = AgentTabStore.shared
    #endif
    @Environment(\.notchNavigator) private var navigator

    var body: some View {
        GeometryReader { geo in
            // The panels that do not fit the first row go on in a second and a third row (at most `NookStore.maxRows`). The grid asks the
            // island for exactly that room (`rowsHeight`).
            let grid = store.rows(in: geo.size.width, maxRows: NookStore.maxRows)
            let fit = (shown: grid.rows.flatMap { $0 }, hidden: grid.hidden)
            let several = grid.rows.count > 1
            VStack(spacing: 10) {
                VStack(spacing: NookMetrics.spacing) {
                    ForEach(Array(grid.rows.enumerated()), id: \.offset) { r, rowItems in
                        let full = store.rowWidth(rowItems, width: geo.size.width) >= geo.size.width - NookMetrics.cell
                        HStack(spacing: dividers ? 0 : NookMetrics.spacing) {
                            ForEach(Array(rowItems.enumerated()), id: \.element) { index, item in
                                if dividers, index > 0 {
                                    Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1, height: NookMetrics.widgetHeight - 28)
                                        .padding(.horizontal, NookMetrics.spacing / 2)
                                }
                                NookWidgetCell(store: store, item: item, index: grid.rows.prefix(r).reduce(0) { $0 + $1.count } + index, dividers: dividers,
                                               span: store.span(of: item, in: rowItems, width: geo.size.width),
                                               first: index == 0, last: index == rowItems.count - 1 && (full || !several),
                                               topRow: r == 0, bottomRow: r == grid.rows.count - 1)
                            }
                            if store.isEditing, r == grid.rows.count - 1 { NookEndDropZone(store: store) }
                        }
                        // The second and third rows start at the left.
                        .frame(maxWidth: .infinity, alignment: (store.isEditing || several) ? .leading : .center)
                    }
                }
                .onChange(of: grid.rows.count, initial: true) { _, rows in
                    if rows > 1 { navigator.requestHeight(NookStore.rowsHeight(rows), resizeMax: nil, by: .nook) } else { navigator.releaseHeight(by: .nook) }
                }
                .animation(Theme.quick, value: store.layout)
                .animation(Theme.quick, value: fit.shown)
                if store.isEditing {
                    NookPalette(store: store, hidden: fit.hidden)
                        .transition(.opacity)
                } else if store.layout.isEmpty {
                    emptyState
                } else if fit.shown.isEmpty {
                    dormantState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onChange(of: geo.size.width, initial: true) { _, width in store.gridWidth = width }
        }
        .onPreferenceChange(NotchRectKey.self) { rects in store.panelRects = rects.filter { $0.key.hasPrefix("panel.") } }
        .onPreferenceChange(NookControlKey.self) { store.controlRects = $0 }
    }

    /// Everything in the layout is dormant (nothing playing, no open to-dos, no agents).
    private var dormantState: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz").font(.system(size: 20)).foregroundStyle(.secondary)
            Text("Nothing to show right now").font(.system(size: 13, weight: .medium))
            Button("Edit Nook") { store.beginEditing(navigator: navigator) }.buttonStyle(.retro(compact: true))
        }
        .frame(maxWidth: .infinity, maxHeight: NookMetrics.widgetHeight)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.grid.2x2").font(.system(size: 20)).foregroundStyle(.secondary)
            Text("No widgets yet").font(.system(size: 13, weight: .medium))
            Button("Edit Nook") { store.beginEditing(navigator: navigator) }.buttonStyle(.retro(compact: true))
        }
        .frame(maxWidth: .infinity, maxHeight: NookMetrics.widgetHeight)
    }
}

extension NookStore {
    /// A panel (by its item id) grows into its detail, exactly as a click on it does.
    func expand(itemID id: String, navigator: NotchNavigator) {
        guard let item = row.first(where: { $0.id == id }) else { return }
        expand(item, navigator: navigator)
    }

    func expand(_ item: NookItem, navigator: NotchNavigator) {
        guard !isEditing else { return }
        lastPanel = "panel.\(item.id)"
        switch item {
        case .tab(let id): Registry.expandAgentTab(id)
        default: if let detail = item.detail { navigator.expand(detail) }
        }
    }
}

private struct NookWidgetCell: View {
    @ObservedObject var store: NookStore
    @Environment(\.notchNavigator) private var navigator
    let item: NookItem
    let index: Int
    let dividers: Bool
    let span: Int
    /// Pictures: the panel drawn as if the pointer were on it.
    @Environment(\.nookPreviewHover) private var previewHover
    /// The first and the last panel of the row: their hover runs out to the island's edge.
    let first: Bool
    let last: Bool
    /// The top and the bottom row of the grid: only the bottom row's hover runs past the island's bottom edge, so a hover in the first row
    /// never bleeds over the row under it;
    /// rows under the first meet the one above halfway in the gap.
    var topRow = true
    var bottomRow = true
    @State private var hover = false

    init(store: NookStore, item: NookItem, index: Int, dividers: Bool, span: Int, first: Bool = false, last: Bool = false, topRow: Bool = true, bottomRow: Bool = true) {
        self.topRow = topRow
        self.bottomRow = bottomRow
        self.store = store
        self.item = item
        self.index = index
        self.dividers = dividers
        self.span = span
        self.first = first
        self.last = last
    }

    private var width: CGFloat { CGFloat(span) * NookMetrics.cell }
    private var expandable: Bool { item.hasDetail && !store.isEditing }

    @ViewBuilder private var content: some View {
        if let custom = store.viewOverride?(item) {
            custom
        } else {
            switch item {
            case .panel(let kind): Registry.widgetView(kind)
            case .tab(let id): Registry.agentTabPanel(id)
            case .nowPlaying: AnyView(MediaWidgetView())
            case .live(let id): LivePanelLookup.source(id)?.makeView() ?? AnyView(EmptyView())
            }
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Dash90.radius, style: .circular)
        ZStack {
            content
                .frame(width: width, height: NookMetrics.widgetHeight)
                .environment(\.dash90Editing, store.isEditing)
                .allowsHitTesting(!store.isEditing)
                .opacity(item.kind.map { store.dragging == $0 } == true ? 0.35 : 1)
        }
        .frame(width: width, height: NookMetrics.widgetHeight)
        .modifier(NookPanelFace(flat: dividers, tint: Dash90.stripe(item), bare: item == .panel(.agents) || (Retro.is8bit && item == .live("live.radio"))))   // the radio deck is its own plastic body too (it reaches into the corner)
        .overlay { if item.highlightsOnHover && !store.isEditing { highlight() } }
        .overlay { if store.isEditing { editOverlay(shape) } }
        .contentShape(shape)
        .onTapGesture { if expandable { store.expand(item, navigator: navigator) } }
        .contextMenu { if !store.isEditing { panelMenu } }
        .onHover { inside in
            hover = inside
            if inside { store.lastPanel = "panel.\(item.id)" }
        }
        .reportRect("panel.\(item.id)")
        .modifier(NookDragModifier(item: item, store: store, index: index))
        .animation(Theme.quick, value: hover)
    }

    /// The hover highlight: a square column of the one screen, the panel and half the gap on each side (neighbours meet), from the header line
    /// down; the outer panels' columns and every bottom run past the island's edge and its outline trims them, so every hover follows the
    /// island's corners.
    /// Resting the pointer never opens a panel (the owner, 2026-11-15).
    private func highlight() -> some View {
        let half = NookMetrics.spacing / 2 + (dividers ? 0.5 : 0)
        return Rectangle().fill(hover || previewHover == item.id ? Look.hoverWash : Color.clear)
            .padding(.leading, -(first ? 400 : half))
            .padding(.trailing, -(last ? 400 : half))
            .padding(.top, topRow ? -6 : -half)
            .padding(.bottom, bottomRow ? -400 : -half)
            .allowsHitTesting(false)
    }

    /// Right-click on a panel: open it full size, take it off the dashboard (a pinned panel), or keep the music there.
    @ViewBuilder private var panelMenu: some View {
        if let detail = item.detail { Button("Open \(detail.title) full size") { store.expand(item, navigator: navigator) } }
        if let kind = item.kind {
            Button("Remove from dashboard") { withAnimation(Theme.quick) { store.remove(kind) } }
            Button("\(kind.title) settings…") { SettingsWindowController.shared.show(kind.settingsPane) }
        }
        if case .nowPlaying = item { Button("Keep on the dashboard") { withAnimation(Theme.quick) { store.add(.media) } } }
        Divider()
        Button("Edit Nook") { store.beginEditing(navigator: navigator) }
        #if !APPSTORE
        Divider()
        AgentTabMenuItems(store: AgentTabStore.shared)   // the "+" menu that held these is gone (owner, 2026-11-15)
        #endif
    }

    private func editOverlay(_ shape: RoundedRectangle) -> some View {
        ZStack(alignment: .topLeading) {
            shape.strokeBorder(Theme.accent.opacity(hover ? 0.95 : 0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            if let kind = item.kind {
                Button { withAnimation(Theme.quick) { store.remove(kind) } } label: {
                    Image(systemName: "minus").font(.system(size: 9, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .retroBevel(.raised, cornerRadius: 4, depth: 1.25, face: Retro.Ink.red)
                }
                .buttonStyle(.plain)
                .padding(5)
                .help("Remove \(kind.title)")
            }
        }
        .contentShape(shape)
        .onTapGesture { if let kind = item.kind { SettingsWindowController.shared.show(kind.settingsPane) } }
        .help("Click for \(item.title) settings, drag to move")
    }
}

/// The panel's face: the open notch's own colour, flat, so the dashboard is one screen (`Dash90.screen`); with the "dividers" setting
/// thin lines stand between the panels.
private struct NookPanelFace: ViewModifier {
    let flat: Bool
    var tint: Color?
    /// The panel is its own plastic body (Agent TV is a whole television): it gets no second face around it.
    var bare = false

    @ViewBuilder func body(content: Content) -> some View {
        if bare {
            content
        } else if flat {
            content.clipShape(RoundedRectangle(cornerRadius: Dash90.radius, style: .circular))
        } else {
            content.nookPanelFace(tint: tint)
        }
    }
}

/// Dragging a panel (to move it) only exists in Edit Nook; the rest of the time a press on a panel is a click.
private struct NookDragModifier: ViewModifier {
    let item: NookItem
    @ObservedObject var store: NookStore
    let index: Int

    @ViewBuilder func body(content: Content) -> some View {
        if store.isEditing, let kind = item.kind {
            content
                .onDrag {
                    store.dragging = kind
                    return NSItemProvider(object: kind.rawValue as NSString)
                }
                .onDrop(of: [.plainText], delegate: NookSlotDrop(store: store, index: index))
        } else {
            content
        }
    }
}

private struct NookSlotDrop: DropDelegate {
    let store: NookStore
    let index: Int

    func validateDrop(info: DropInfo) -> Bool { store.isEditing && store.dragging != nil }

    func dropEntered(info: DropInfo) {
        guard let kind = store.dragging else { return }
        withAnimation(Theme.quick) { store.place(kind, at: index) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        store.dragging = nil
        return true
    }
}

private struct NookEndDropZone: View {
    @ObservedObject var store: NookStore

    var body: some View {
        RoundedRectangle(cornerRadius: Dash90.radius, style: .circular)
            .strokeBorder(Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .overlay(Image(systemName: "plus").foregroundStyle(.secondary))
            .frame(minWidth: 36, maxWidth: .infinity)
            .frame(height: NookMetrics.widgetHeight)
            .onDrop(of: [.plainText], delegate: NookEndDrop(store: store))
    }
}

private struct NookEndDrop: DropDelegate {
    let store: NookStore

    func validateDrop(info: DropInfo) -> Bool { store.isEditing && store.dragging != nil }

    func dropEntered(info: DropInfo) {
        guard let kind = store.dragging else { return }
        withAnimation(Theme.quick) { store.place(kind, at: store.layout.count) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        store.dragging = nil
        return true
    }
}

/// The strip under the row in edit mode: the widgets that are not in the Nook. Drop a widget here to remove it.
private struct NookPalette: View {
    @ObservedObject var store: NookStore
    let hidden: Int
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(store.palette.isEmpty ? "All widgets are on the dashboard" : "Drag a widget up to add it")
                    .font(.system(size: 11, weight: .medium))
                Text(hidden > 0 ? "\(hidden) more won't fit: make the notch wider" : "Drop one here to remove it")
                    .font(.system(size: 10))
                    .foregroundStyle(hidden > 0 ? Color.orange : Color.secondary)
            }
            .frame(width: 190, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.palette) { kind in
                        RetroKeyFace(tint: Retro.Ink.plasticMid, compact: false) {
                            HStack(spacing: 5) {
                                Image(systemName: kind.symbol).font(.system(size: 11, weight: .semibold))
                                Text(kind.title).font(.system(size: 11, weight: .bold))
                            }
                        }
                        .onDrag {
                            store.dragging = kind
                            return NSItemProvider(object: kind.rawValue as NSString)
                        }
                        .onTapGesture { withAnimation(Theme.quick) { store.add(kind) } }
                        .help("Drag into the row, or click to add")
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .lookWell()
        .retroBevel(.sunken, cornerRadius: 8, depth: 1.5, face: Look.well(dark: targeted ? Color(red: 0.16, green: 0.15, blue: 0.10) : Color(red: 0.06, green: 0.06, blue: 0.07), hot: targeted))   // a dark bar in the dark preset, the light well in the light one
        .onDrop(of: [.plainText], isTargeted: $targeted) { _ in
            if let kind = store.dragging, store.layout.contains(kind) {
                withAnimation(Theme.quick) { store.remove(kind) }
            }
            store.dragging = nil
            return true
        }
    }
}

private struct NookPreviewHoverKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// Gallery only: the id of the dashboard panel to draw as hovered.
    var nookPreviewHover: String? {
        get { self[NookPreviewHoverKey.self] }
        set { self[NookPreviewHoverKey.self] = newValue }
    }
}
