import SwiftUI

/// The rooms' frames in the panel's own space (the self-test clicks them).
struct AgentNookFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// Agent TV, the Agents panel of the dashboard: a chunky 90s CRT television that fills its cell (the kit's `CRTSet`, and from 10 cells on
/// a wide console). The agents' rooms stand on its screen, the one that needs you first; an on-screen display along the top of the glass
/// names the room in focus ("CH 02 NOTES": the one that needs you, else the busiest) and carries the Mac's CPU and memory as two small
/// LED bars. The ON AIR lamp on the set is lit while any agent needs you. Nobody home: the set is switched off
///
/// A click on a room picks that agent and opens the Agents view (the den); a click anywhere else on the set opens it too. Same init
/// shape as `AgentsWidgetView`; the type keeps the name it had as the house, other code and the tests use it.
///
/// Motion: with Reduce Motion ON only soft fades (the lamp breathes, the typing dots fade); with it off, a tiny
/// bob and a blink. NO timer runs unless the panel is on screen and the notch is open. Hovering only brightens a room's edge.
struct AgentNookPanelView: View {
    @ObservedObject private var store: AgentsStore
    @Environment(\.notchNavigator) private var navigator
    /// An agent id: that room glows for a moment.
    var highlighted: String?
    /// Gallery and tests: draw this one moment instead of running the clock.
    private var fixedClock: AgentNookClock?
    /// Gallery: a fixed reading of the Mac's load (cpu, memory) instead of the sampler.
    private var fixedLoad: (cpu: Double, memory: Double)?
    /// Tests: told where the rooms are.
    private var onFrames: (([String: CGRect]) -> Void)?

    @State private var appeared = false
    @State private var open = false
    @State private var glowID: String?
    @State private var glowTask: Task<Void, Never>?

    @MainActor init(store: AgentsStore? = nil, highlighted: String? = nil) {
        _store = ObservedObject(wrappedValue: store ?? AgentsStore.shared)
        self.highlighted = highlighted
        _glowID = State(initialValue: highlighted)
    }

    /// The same panel drawn at one moment (a frozen picture of the motion).
    func frozen(_ clock: AgentNookClock) -> AgentNookPanelView { var copy = self; copy.fixedClock = clock; return copy }

    func reportingFrames(_ report: @escaping ([String: CGRect]) -> Void) -> AgentNookPanelView { var copy = self; copy.onFrames = report; return copy }

    /// Pictures: the Mac's load as these two fractions.
    func load(cpu: Double, memory: Double) -> AgentNookPanelView { var copy = self; copy.fixedLoad = (cpu, memory); return copy }

    // MARK: What it shows

    /// One model per agent, in the one fixed order (the first started on the left; `AgentTileMetrics.ordered`).
    static func models(_ sessions: [AgentSession]) -> [AgentNookRoomModel] {
        AgentTileMetrics.ordered(sessions).map(AgentNookRoomModel.init)
    }

    private var rooms: [AgentNookRoomModel] { Self.models(store.sessions) }

    /// The open island's content size in its own space (nil in pictures without the island): the TV lines up with its corner.
    @Environment(\.notchContentSize) private var contentSize

    /// Timers run only while this is on screen and the notch is open; a gallery or test picture never runs one.
    private var running: Bool { Self.isRunning(appeared: appeared, open: open, fixed: fixedClock != nil, scripted: ScoutRuntime.isScripted) }

    static func isRunning(appeared: Bool, open: Bool, fixed: Bool, scripted: Bool) -> Bool { appeared && open && !fixed && !scripted }

    private func clock(at date: Date) -> AgentNookClock {
        if let fixedClock { return fixedClock }
        guard running else { return .still }
        return AgentNookClock(t: date.timeIntervalSinceReferenceDate, motion: !ScoutRuntime.reduceMotion)
    }

    var body: some View {
        Group {
            if Retro.is8bit { tvBody } else { AgentMiniPanel(store: store, lit: glowID) }   // the minimal look: plain rows (AgentMiniViews.swift)
        }
        .coordinateSpace(name: "agentnook")
        .onPreferenceChange(AgentNookFramesKey.self) { frames in onFrames?(frames) }
        .notchContent(screen: Retro.is8bit)   // the 8-bit TV is a picture: dark glass inside the light preset too
        .onAppear { appeared = true; open = navigator.isOpen; if glowID != nil { fade() } }
        .onDisappear { appeared = false; glowTask?.cancel(); glowTask = nil }
        .onReceive(navigator.$isOpen) { open = $0 }
        .onChange(of: highlighted) { _, id in flash(id) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Retro.is8bit ? "Agent TV" : "Agents")
    }

    /// When the TV is the first panel its screen reaches left until its rim stands as far from the island's left edge as it stands from the
    /// island's bottom edge: the same border left and down. Only the screen grows, only in width, only to the left; the set, its height and its
    /// knobs stay.
    /// Measured in the content's own space, so the Size setting's scaling cannot throw it off (it once cut the left rim).
    /// Self-tests: what the TV measured last (its frame in the content's space, the content's size, the reach).
    nonisolated(unsafe) static var lastMeasure: (panel: CGRect, content: CGSize, reach: CGFloat)?

    /// The gaps are the screen frame's (the set's dark rim around the glass): with the knobs under the screen it is already far from the
    /// bottom and nothing moves; with the knobs at its side the screen frame ends up the same distance from both edges.
    /// The open island's visible left wall stands this far inside its frame (its top shoulders: `NotchRootView.topRadius` when open).
    static let islandShoulder: CGFloat = 12

    static func reach(panel me: CGRect, content: CGSize, rim: CGFloat) -> CGFloat {
        let well = CRTSetLayout(size: me.size, compact: false).well
        let left = me.minX + well.minX - islandShoulder, bottom = content.height - (me.minY + well.maxY)
        guard content.width > 0, me.minX >= 0, me.minX < 80, bottom > 0 else { return 0 }
        return max(0, left - bottom)
    }

    /// The 8-bit look: the CRT set with the rooms on its glass.
    private var tvBody: some View {
        GeometryReader { geo in
            let me = geo.frame(in: .named("notchContent"))
            let rim: CGFloat = 6   // the set's frame to its glass rim (`CRTSetLayout.bezel`)
            let reach = contentSize.map { Self.reach(panel: me, content: $0, rim: rim) } ?? 0   // the glass's left edge moves out by this
            let _ = { if let c = contentSize { Self.lastMeasure = (me, c, reach) } }()
            let width = geo.size.width
            let height = geo.size.height
            let list = rooms
            let plan = AgentTVLayout.plan(panelWidth: width, count: list.count)
            let focus = AgentTVChannel.focus(list)
            let onAir = AgentTVChannel.onAir(list)
            TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !running)) { context in
                let clock = clock(at: context.date)
                Group {
                    if plan.wide {
                        AgentTVConsole(badge: pixelLabel("AGENT TV"), onAir: onAir) { screen(list, plan: plan, focus: focus, clock: clock) }
                    } else {
                        CRTSet(badge: pixelLabel("AGENT TV"), compact: false, powerOn: !list.isEmpty, onAir: onAir, reflection: list.isEmpty ? pixelLabel("NO AGENTS") : nil) { screen(list, plan: plan, focus: focus, clock: clock) }   // nobody home: the set is off, NO AGENTS faint on its glass
                    }
                }
                .environment(\.crtGlassExtendLeft, plan.wide ? 0 : reach)
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                .onTapGesture { navigator.open(.agents) }   // a click on the set itself opens the full view; a room's own button comes first
            }
        }
    }

    private func pick(_ id: String) {
        store.focusID = id
        navigator.open(.agents)
    }

    // MARK: The picture on the glass

    @ViewBuilder
    private func screen(_ list: [AgentNookRoomModel], plan: AgentTVLayout.Plan, focus: AgentTVChannel.Pick?, clock: AgentNookClock) -> some View {
        VStack(spacing: 0) {
            osd(focus: focus, glassWidth: plan.glass.width)
                .frame(height: AgentTVLayout.band)
            if list.isEmpty {
                Look.isLight ? CRTDrawing.paperGlass : Color.black   // the wide console's empty glass (a small set is switched off instead): black, pale in the light preset
            } else {
                // The rooms that fit: the ones that need you, still in the fixed order.
                let shown = AgentTileMetrics.keepOrder(list, limit: plan.shown) { AgentTileMetrics.need($0.look) }
                HStack(alignment: .bottom, spacing: AgentNookLayout.gap) {
                    ForEach(shown) { model in
                        AgentNookRoomButton(model: model, style: plan.style, clock: clock.shifted(AgentFaceArt.phase(for: model.id)), glow: glowID == model.id, reserveRow: shown.contains { $0.helpers > 0 || $0.todoTotal > 0 }, reserveHelpers: shown.contains { $0.helpers > 0 },
                                            shared: true, variant: AgentFaceArt.variants(for: store.sessions.map(\.id))[model.id] ?? 0) { pick(model.id) }
                            .frame(width: plan.roomWidth)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: AgentNookFramesKey.self, value: [model.id: proxy.frame(in: .named("agentnook"))])
                            })
                    }
                    if plan.more > 0 {
                        AgentNookDoor(more: plan.more, height: min(76, plan.rooms.height * 0.84)) { navigator.open(.agents) }
                            .frame(width: AgentNookLayout.doorWidth)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: AgentNookFramesKey.self, value: ["door": proxy.frame(in: .named("agentnook"))])
                            })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.horizontal, AgentTVLayout.margin)
                .padding(.bottom, AgentTVLayout.margin)
            }
        }
        .background {
            // ONE wall behind every room and the on-screen display, right up to the TV's border; nobody home keeps the black glass.
            if list.isEmpty {
                Look.isLight ? CRTDrawing.paperGlass : Color.black
            } else {
                AgentNookWall(look: .working, style: plan.style, clock: clock, showLamp: false, moonRow: 3, floor: false, cozy: true)
            }
        }
    }

    /// The on-screen display along the top of the glass: the channel and the project of the room in focus at the left, the Mac's CPU and
    /// memory as two LED bars at the right. What does not fit goes in order: the project, then the long labels.
    private func osd(focus: AgentTVChannel.Pick?, glassWidth: CGFloat) -> some View {
        ViewThatFits(in: .horizontal) {
            osdRow(focus, name: true, labels: .full)
            osdRow(focus, name: false, labels: .full)
            osdRow(focus, name: false, labels: .letters)
        }
        .padding(.horizontal, 13)   // clear of the glass's round corners (20 pt, like the island's)
        .padding(.top, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func osdRow(_ focus: AgentTVChannel.Pick?, name: Bool, labels: AgentTVLoadBars.Labels) -> some View {
        HStack(spacing: 6) {
            RetroOSD(focus.map { AgentTVChannel.channelText($0.channel) } ?? "CH --", pixel: 1.5, color: Retro.Ink.phosphorGreen)
            if name, let focus { RetroOSD(focus.project.uppercased(), pixel: 1.5, color: Retro.Ink.osdWhite).lineLimit(1) }
            Spacer(minLength: 4)
            // No CPU and memory bars on the TV any more.
        }
    }

    // MARK: The glow of a highlighted room

    private func flash(_ id: String?) {
        glowTask?.cancel()
        withAnimation(.easeOut(duration: 0.25)) { glowID = id }
        if id != nil { fade() }
    }

    /// The glow lasts a moment (a one-shot wait, cancelled when the panel goes away). Pictures keep it.
    private func fade() {
        guard !ScoutRuntime.isScripted else { return }
        glowTask?.cancel()
        glowTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.7)) { glowID = nil }
        }
    }
}


/// What the empty set says, in the owner's words.
enum AgentNookEmptyRoom {
    static let line = String(localized: "Nobody home yet. Agents move in by themselves.")
}

// MARK: - Pieces of the screen

/// A room as a button: a click does what a row of the Agents panel does. Hovering only brightens the edge.
struct AgentNookRoomButton: View {
    var model: AgentNookRoomModel
    var style: AgentNookLayout.Style
    var clock: AgentNookClock
    var glow: Bool
    var reserveRow: Bool?
    var reserveHelpers: Bool?
    /// The room stands on the TV's one shared wall (no wall or frame of its own).
    var shared = false
    /// Its agent's own skin.
    var variant = 0
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            AgentNookRoom(model: model, style: style, clock: clock, glow: glow, hover: hover, reserveRow: reserveRow, reserveHelpers: reserveHelpers, variant: variant, shared: shared)
        }
        .buttonStyle(StillButtonStyle())
        .onHover { hover = $0 }
        .help("\(model.project): \(model.look.title)")
        .animation(.easeOut(duration: 0.3), value: glow)
    }
}

/// The "+N" door for the agents that do not fit: a small arched wooden door in pixels, "+N" in pixel digits on it.
struct AgentNookDoor: View {
    var more: Int
    var height: CGFloat = 76
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Canvas { context, size in
                var ctx = context
                let px = AgentNookWall.cell
                let cols = Int(AgentNookLayout.doorWidth / px)
                let rows = max(8, Int(height / px))
                let top = Int(size.height / px) - rows
                let o = CGPoint(x: 0, y: CGFloat(top) * px)
                let wood = PixelPalette.rgb(0.55, 0.36, 0.22), dark = PixelPalette.rgb(0.34, 0.21, 0.14), light = PixelPalette.rgb(0.74, 0.52, 0.31)
                let edge = Color.black.opacity(0.85)
                for r in 0..<rows {
                    // the arch: the top rows are narrower
                    let inset = r == 0 ? 6 : (r == 1 ? 4 : (r == 2 ? 3 : (r == 3 ? 2 : (r < 6 ? 1 : 0))))
                    let w = cols - 2 * inset
                    AgentPixel.fill(&ctx, x: inset, y: r, w: w, h: 1, origin: o, px: px, edge)
                    if w > 2 && r > 0 { AgentPixel.fill(&ctx, x: inset + 1, y: r, w: w - 2, h: 1, origin: o, px: px, (r % 6 == 0 ? dark : (hover ? light : wood))) }
                }
                AgentPixel.fill(&ctx, x: 1, y: rows - 1, w: cols - 2, h: 1, origin: o, px: px, edge)
                // planks
                for x in [5, 10] { AgentPixel.fill(&ctx, x: x, y: 5, w: 1, h: rows - 6, origin: o, px: px, dark) }
                AgentPixel.fill(&ctx, x: cols - 4, y: rows / 2 + 2, w: 2, h: 2, origin: o, px: px, Color(red: 1.0, green: 0.84, blue: 0.2))
                let label = "+\(more)"
                let tw = AgentPixel.textWidth(label)
                AgentPixel.text(&ctx, label, x: max(2, (cols - tw) / 2), y: 8, origin: o, px: px, AgentNookInk.cream)
            }
            .frame(width: AgentNookLayout.doorWidth, height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("More agents: \(more)")
        .accessibilityLabel("More agents: \(more)")
    }
}
