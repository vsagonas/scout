import SwiftUI

/// Gallery scenes `island-*`: the closed island on a mock menu strip for each kind of display (a pill, a drawn island, a classic notch with
/// round bubbles), made with faked geometry (nobody here has the new Mac). The strip has its real height, the housing is drawn where it is (a
/// black capsule for the pill, the black notch for the notch, nothing for a display without a cutout: its bar is plain), and on it the REAL
/// root view draws the closed island. Light and dark come with every picture; the three sizes and both looks come from the environment:
///   SCOUT_SCALE=normal|large|xlarge  SCOUT_8BIT=1|0  SCOUT_REDUCE_MOTION=1|0  scripts/gallery.sh island build/gallery-island/<name>
/// `island-variants` is the ONE sheet to choose sizes from (outer diameter, ring width, face cell, gap), for the pill, the drawn island at bars of
/// 24 and 37 pt and the classic notch.
@MainActor
enum IslandGallery {
    static func register() {
        for display in IslandSamples.displays {
            Gallery.register("island-\(display.name)-states", size: CGSize(width: stripWidth, height: statesHeight(display.geometry, music: display.music))) {
                IslandStatesSheet(display: display)
            }
        }
        Gallery.register("island-1x", size: CGSize(width: stripWidth, height: 3 * (IslandSamples.notch37.stripHeight + 24) + 24)) {
            IslandOneXSheet()
        }
        Gallery.register("island-variants", size: IslandVariantsSheet.size) {
            IslandVariantsSheet()
        }
    }

    nonisolated static let stripWidth: CGFloat = 900
    static func rowHeight(_ geometry: NotchGeometry) -> CGFloat { geometry.stripHeight + 24 }
    static func statesHeight(_ geometry: NotchGeometry, music: Bool) -> CGFloat {
        CGFloat(IslandStatesSheet.rows(music: music).count) * rowHeight(geometry) + 24
    }
}

/// Made-up agents and displays for the island's pictures and tests (never real transcripts).
@MainActor
enum IslandSamples {
    struct Display {
        var name: String
        var title: String
        var geometry: NotchGeometry
        /// Music can show beside the drawn island (on a pill it waits for its own capsule and filter; on a notch it keeps the classic drawing).
        var music: Bool
    }

    /// The drawn island at a bar of 37 pt (the classic notch's menu bar): 108.8 by 32, 2.5 pt below the top edge.
    static let none37 = NotchGeometry(kind: .none, size: CGSize(width: 108.8, height: 32), topInset: 2.5, noneShape: .island, stripHeight: 37)
    /// The drawn island at the lowest bar the rules allow (22 pt): 61.2 by 18, 2 pt below the top edge. Its bubbles are 18 pt, the smallest there is.
    static let none22 = NotchGeometry(kind: .none, size: CGSize(width: 61.2, height: 18), topInset: 2, noneShape: .island, stripHeight: 22)
    /// The classic 16 inch notch in a 37 pt strip, set to round bubbles (the tests' taller strip).
    static let notch37 = NotchGeometry(kind: .notch, size: CGSize(width: 185, height: 32), agentStyle: .bubbles, stripHeight: 37)
    /// The classic notch as a 16 inch MacBook Pro shows it at 1728 points wide: 185 by 32 in a 33 pt menu bar, set to round bubbles.
    static let notch33 = NotchGeometry(kind: .notch, size: CGSize(width: 185, height: 32), agentStyle: .bubbles, stripHeight: 33)

    static let displays: [Display] = [
        Display(name: "pill", title: "Pill, 16 inch (58 by 31, strip 48)", geometry: .samplePill16, music: false),
        Display(name: "pilltall", title: "Pill, the tall stress case (59 by 40, strip 56)", geometry: .samplePillTall, music: false),
        Display(name: "none24", title: "Drawn island, bar 24 (68 by 20)", geometry: .sampleNone, music: true),
        Display(name: "none37", title: "Drawn island, bar 37 (108.8 by 32)", geometry: none37, music: true),
        Display(name: "notch", title: "Classic notch 185 by 32, round bubbles, menu bar 33", geometry: notch33, music: false),
        Display(name: "none22", title: "Drawn island, bar 22 (61.2 by 18), the smallest", geometry: none22, music: true),
    ]

    static let projects = ["site", "api", "notes", "scout", "docs", "infra", "app", "shop", "blog"]
    static let kinds: [AgentKind] = [.claude, .codex, .claude, .claude, .codex, .claude, .codex, .claude, .claude]

    /// Agent number `index` in the given look; ids are "ag-<index>", started in index order (the first started stands outermost).
    static func session(_ index: Int, _ look: AgentNookLook, todos: (done: Int, total: Int)? = nil) -> AgentSession {
        let now = Date()
        var s = AgentSession(id: "ag-\(index)", agent: kinds[index % kinds.count], cwd: "/Users/you/Dev/\(projects[index % projects.count])",
                             title: "Task \(index + 1)", state: .working, startedAt: now.addingTimeInterval(Double(-3000 + index * 100)), lastEventAt: now)
        s.turnStartedAt = now.addingTimeInterval(-200)
        switch look {
        case .working:
            s.steps = [AgentStep(id: "s\(index)", tool: "Bash", summary: "swift build", at: now.addingTimeInterval(-3), done: false)]
        case .needsYou:
            s.state = .waiting
            s.note = AgentNote.asking("Which region?")
            s.lastMessage = "The bucket can move to eu-west-1 or us-east-1."
        case .finished:
            s.state = .waiting
            s.finishedAt = now.addingTimeInterval(-40)
            s.note = AgentNote.finished
            s.lastMessage = "The summary is in notes/summary.md."
        case .stopped:
            s.state = .done
            s.finishedAt = now.addingTimeInterval(-60)
            s.steps = [AgentStep(id: "f\(index)", tool: "Bash", summary: "swift build", at: now.addingTimeInterval(-61), done: true, failed: true)]
        case .idle:
            s.state = .idle
        }
        if let todos {
            s.todos = (0..<todos.total).map { i in
                AgentTodo(text: "Step \(i + 1)", active: "Doing step \(i + 1)", status: i < todos.done ? .completed : (i == todos.done ? .inProgress : .pending))
            }
        }
        return s
    }

    static func sessions(_ looks: [AgentNookLook]) -> [AgentSession] { looks.enumerated().map { session($0.offset, $0.element) } }

    static func store(_ looks: [AgentNookLook]) -> AgentsStore {
        let store = AgentsStore()
        store.loadSessions(sessions(looks))
        return store
    }
}

/// A mock menu strip with a housing on it and the real root view drawing the closed island; the objects it needs are made here.
struct IslandStrip: View {
    let geometry: NotchGeometry
    let width: CGFloat
    @ObservedObject var model: NotchScreenModel
    @ObservedObject var center: LiveActivityCenter
    @ObservedObject var navigator: NotchNavigator
    @ObservedObject var nook: NookStore
    @Environment(\.colorScheme) private var scheme

    @MainActor
    init(geometry: NotchGeometry, width: CGFloat = IslandGallery.stripWidth, store: AgentsStore? = nil, extra: [LiveActivity] = [], hovered: String? = nil) {
        self.geometry = geometry
        self.width = width
        let model = NotchScreenModel(geometry: geometry, panelSize: CGSize(width: width, height: geometry.stripHeight))
        model.hoveredHit = hovered
        let center = LiveActivityCenter()
        if let store { center.show(AgentsStore.wings(store: store, expiresAfter: nil)) }
        for activity in extra { center.show(activity) }
        self.model = model
        self.center = center
        navigator = NotchNavigator()
        nook = NookStore(persist: false, layout: nil)
    }

    var body: some View {
        ZStack(alignment: .top) {
            IslandMockBar(geometry: geometry, width: width, menus: true)
            NotchRootView(model: model, center: center, navigator: navigator, nook: nook, styleOverride: .classic)
                .modifier(NotchLeftToRight())
        }
        .frame(width: width, height: geometry.stripHeight, alignment: .top)
    }
}

/// The strip and the housing, without the island: a bar of the display's real height; a black capsule where a pill is; the black notch for a
/// notch; for a display without a cutout nothing (the drawn island is the island's own).
struct IslandMockBar: View {
    let geometry: NotchGeometry
    let width: CGFloat
    var menus = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let housing = geometry.housingRect(panelWidth: width)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(scheme == .dark ? Color.black.opacity(0.28) : Color.white.opacity(0.42)).frame(width: width, height: geometry.stripHeight)
            if menus {
                HStack(spacing: 14) {
                    Image(systemName: "square.grid.2x2.fill").font(.system(size: 13))
                    Text(verbatim: "App").font(.system(size: 12, weight: .bold))
                    Text(verbatim: "File").font(.system(size: 12))
                    Text(verbatim: "Edit").font(.system(size: 12))
                    Spacer()
                    Image(systemName: "wifi").font(.system(size: 12))
                    Text(verbatim: "Fri 15 Nov  10:41").font(.system(size: 12))
                }
                .foregroundStyle(scheme == .dark ? Color.white : Color.black)
                .padding(.horizontal, 14)
                .frame(width: width, height: geometry.stripHeight)
            }
            switch geometry.kind {
            case .pill:
                Capsule().fill(Color.black).frame(width: housing.width, height: housing.height).padding(.leading, housing.minX).padding(.top, housing.minY)
            case .notch:
                UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous).fill(Color.black)
                    .frame(width: housing.width, height: housing.height).padding(.leading, housing.minX).padding(.top, housing.minY)
            case .none:
                EmptyView()
            }
        }
        .frame(width: width, height: geometry.stripHeight, alignment: .topLeading)
    }
}

/// One display, every state of the closed island, one strip each.
private struct IslandStatesSheet: View {
    let display: IslandSamples.Display
    @Environment(\.colorScheme) private var scheme

    struct Row {
        var title: String
        var looks: [AgentNookLook]
        var todos: (done: Int, total: Int)?
        var radio = false
        var hovered: String?
        var music = false
    }

    static func rows(music: Bool) -> [Row] {
        var rows = [
            Row(title: "At rest", looks: []),
            Row(title: "1 agent at work", looks: [.working]),
            Row(title: "4 agents at work", looks: [.working, .working, .working, .working]),
            Row(title: "6 agents (the four that need you most, then +2)", looks: [.working, .working, .finished, .working, .stopped, .idle]),
            Row(title: "One needs you, with its question", looks: [.working, .needsYou]),
            Row(title: "One finished, with its message", looks: [.working, .finished]),
            Row(title: "Progress of the busiest agent", looks: [.working], todos: (2, 5)),
            Row(title: "Stopped, asleep and at work", looks: [.stopped, .idle, .working]),
            Row(title: "A bubble under the pointer", looks: [.working, .needsYou], hovered: "bubble.ag-0"),
            Row(title: "The radio beside the agents", looks: [.working, .needsYou], radio: true),
        ]
        if music { rows.append(Row(title: "Music on the drawn island (no agents)", looks: [], music: true)) }
        return rows
    }

    var body: some View {
        let geometry = display.geometry
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.rows(music: display.music).enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "\(display.title): \(row.title)").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(scheme == .dark ? Color.white.opacity(0.85) : Color.black.opacity(0.8)).padding(.leading, 8)
                    IslandStrip(geometry: geometry, store: stored(row), extra: extras(row), hovered: row.hovered)
                }
                .frame(width: IslandGallery.stripWidth, height: IslandGallery.rowHeight(geometry), alignment: .top)
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func stored(_ row: Row) -> AgentsStore? {
        guard !row.looks.isEmpty else { return nil }
        let store = AgentsStore()
        var list = IslandSamples.sessions(row.looks)
        if let todos = row.todos, !list.isEmpty { list[0] = IslandSamples.session(0, row.looks[0], todos: todos) }
        store.loadSessions(list)
        return store
    }

    private func extras(_ row: Row) -> [LiveActivity] {
        var list: [LiveActivity] = []
        if row.radio { list.append(RadioNotchPresenter.sample()) }
        if row.music { list.append(SampleActivities.make(.media)) }
        return list
    }
}

/// The same four agents on a 1x display (rendered on the gallery's 2x bitmap, so each point is two pixels): the rules for whole pixels.
private struct IslandOneXSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach([IslandSamples.displays[0], IslandSamples.displays[2], IslandSamples.displays[4]], id: \.name) { display in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "\(display.title), a 1x display: 4 agents, one asks").font(.system(size: 10, weight: .semibold)).padding(.leading, 8)
                    IslandStrip(geometry: display.geometry, store: IslandSamples.store([.working, .needsYou, .finished, .working]))
                        .environment(\.displayScale, 1)
                }
                .frame(width: IslandGallery.stripWidth, height: IslandGallery.rowHeight(display.geometry), alignment: .top)
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The sheet to choose sizes from: for each display, the outer diameter (the rule's value and two others), the ring width (1, 1.5, 2 pt), the
/// face cell (1.0, 1.5, 2.0 pt) and the gap (3, 4, 6 pt), each tried alone while the rest follows the rule. A face whose corners leave the disc
/// is marked.
private struct IslandVariantsSheet: View {
    static let cellWidth: CGFloat = 520
    static let labelWidth: CGFloat = 110

    struct Block {
        var title: String
        var geometry: NotchGeometry
        var diameters: [CGFloat]
    }

    static let blocks: [Block] = [
        Block(title: "Pill 16 inch", geometry: .samplePill16, diameters: [31, 28, 24]),
        Block(title: "Drawn island, bar 24", geometry: .sampleNone, diameters: [20, 18, 16]),
        Block(title: "Drawn island, bar 37", geometry: IslandSamples.none37, diameters: [32, 28, 24]),
        Block(title: "Classic notch, menu bar 33", geometry: IslandSamples.notch33, diameters: [32, 30, 28]),
    ]

    static var size: CGSize {
        let rowHeight: CGFloat = 70
        let height = CGFloat(16) + CGFloat(blocks.count) * (22 + 4 * (rowHeight + 4) + 12)
        return CGSize(width: labelWidth + 3 * cellWidth + 24, height: height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Self.blocks.enumerated()), id: \.offset) { _, block in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: block.title).font(.system(size: 13, weight: .bold))
                    let rule = IslandRows.diameter(geometry: block.geometry, sizeFactor: 1)
                    row("outer diameter", block, variants: block.diameters.map { Variant(diameter: $0, ring: IslandTuning.ringWidth, cell: nil, gap: IslandTuning.gap) })
                    row("ring width", block, variants: [1, 1.5, 2].map { Variant(diameter: rule, ring: $0, cell: nil, gap: IslandTuning.gap) })
                    row("face cell", block, variants: [1, 1.5, 2].map { Variant(diameter: rule, ring: IslandTuning.ringWidth, cell: $0, gap: IslandTuning.gap) })
                    row("gap", block, variants: [3, 4, 6].map { Variant(diameter: rule, ring: IslandTuning.ringWidth, cell: nil, gap: $0) })
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    struct Variant {
        var diameter: CGFloat
        var ring: CGFloat
        var cell: CGFloat?
        var gap: CGFloat
    }

    private func row(_ title: String, _ block: Block, variants: [Variant]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(verbatim: title).font(.system(size: 11, weight: .semibold)).frame(width: Self.labelWidth, alignment: .leading)
            ForEach(Array(variants.enumerated()), id: \.offset) { _, variant in
                VariantStrip(geometry: block.geometry, width: Self.cellWidth, variant: variant)
            }
        }
    }
}

/// One variant: a mock strip with the housing, four bubbles (at work, asking, finished, stopped) left of it and a news capsule right of it.
private struct VariantStrip: View {
    let geometry: NotchGeometry
    let width: CGFloat
    let variant: IslandVariantsSheet.Variant
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let faces = [AgentWingSummary.Face(id: "a", agent: .claude, mood: .working, variant: 5), AgentWingSummary.Face(id: "b", agent: .codex, mood: .asking, variant: 17),
                     AgentWingSummary.Face(id: "c", agent: .claude, mood: .finished, variant: 40), AgentWingSummary.Face(id: "d", agent: .codex, mood: .stopped, variant: 77)]
        let d = variant.diameter
        let inner = AgentBubbleMetrics.innerDiameter(outer: d, ring: variant.ring)
        let cell = variant.cell ?? AgentBubbleMetrics.faceCell(inner: inner, scale: 2)
        let layout = IslandRows.layout(geometry: geometry, panelWidth: width, sizeFactor: 1, left: IslandRows.bubblePieces(ids: faces.map(\.id), more: false, diameter: d),
                                       right: [IslandRows.Piece(name: "capsule.news", width: 1)], gap: variant.gap, diameter: d)
        let fits = AgentBubbleMetrics.faceFits(cell: cell, inner: inner)
        VStack(alignment: .leading, spacing: 2) {
            ZStack(alignment: .topLeading) {
                IslandMockBar(geometry: geometry, width: width)
                if geometry.kind == .none {
                    Capsule().fill(Color.black).frame(width: layout.housing.width, height: layout.housing.height)
                        .padding(.leading, layout.housing.minX).padding(.top, layout.housing.minY)
                }
                ForEach(Array(layout.left.enumerated()), id: \.offset) { index, placed in
                    AgentBubble(face: faces[index], label: "", diameter: d, ringWidth: variant.ring, displayScale: 2, frozenAt: 0.6, cell: cell)
                        .padding(.leading, placed.rect.minX).padding(.top, placed.rect.minY)
                }
                if let capsule = layout.right.first {
                    IslandCapsule(height: d, scale: 1) {
                        HStack(spacing: 4) {
                            Circle().fill(Color.orange).frame(width: 7, height: 7)
                            Text(verbatim: "Which region?").font(.system(size: 9.5, weight: .medium)).foregroundStyle(Color.orange)
                        }
                    }
                    .padding(.leading, capsule.rect.minX).padding(.top, capsule.rect.minY)
                }
            }
            .frame(width: width, height: geometry.stripHeight, alignment: .topLeading)
            .environment(\.colorScheme, .dark)
            Text(verbatim: "outer \(trim(d)) · ring \(trim(variant.ring)) · cell \(trim(cell)) · gap \(trim(variant.gap))\(fits ? "" : "  FACE CORNERS OUTSIDE THE DISC")")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(fits ? (scheme == .dark ? Color.white.opacity(0.7) : Color.black.opacity(0.65)) : Color.red)
        }
        .frame(width: width, height: 70, alignment: .top)
    }

    private func trim(_ v: CGFloat) -> String { v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", Double(v)) }
}
