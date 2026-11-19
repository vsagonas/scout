import SwiftUI

/// The frames of the den's parts in its own space (the self-test clicks them): the stations by agent id, "window", "banner", "close",
/// and the window's answer keys as "key.Allow", "key.Deny" and so on.
struct AgentDenFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

extension View {
    /// Reports this view's frame in the den's space under `name`.
    func denFrame(_ name: String) -> some View {
        background(GeometryReader { proxy in Color.clear.preference(key: AgentDenFramesKey.self, value: [name: proxy.frame(in: .named("agentden"))]) })
    }
}

/// What the empty Agents view says: one calm line, and a key when there is something to do about it. The 8-bit den shows it only when
/// something must be done (`asksAction`, the folders cannot be read yet); otherwise the empty room says nothing.
/// The minimal look always shows it.
struct AgentDenEmptyNote {
    var line = AgentNookEmptyRoom.line
    /// The key's words (already in the person's language: `String(localized:)`).
    var keyTitle: String?
    /// True when the key opens Agents settings (nothing is running): the minimal look then says the longer hint. Never read from `keyTitle`'s words.
    var opensSettings = false
    var asksAction = false
    var action: (() -> Void)?
}

/// The big vintage place: the Agents view as ONE 90s den seen from the front, in 8-bit pixels. Wood panelling, wallpaper, a shelf with a
/// lava lamp, two posters, a neon sign, a wall clock with the real time, a window with day or night by the real hour, a rug. Every agent
/// has its own station and you can tell its state at a glance: at a chunky computer while it works, by a ringing phone with its hand up
/// when it needs you, holding its check by the TV (and how long the task took) when it finished, dizzy by a smoking machine when it
/// stopped, asleep on a beanbag when idle; its helpers sit in front. A click on an agent opens its window beside the den (the den stays
/// on screen). Nobody home: the den stays empty (a line and a key only while Scout cannot read the agents' folders).
///
/// Motion: Reduce Motion ON: one frame and soft fades only (the lamp, the neon, the phone's ring, the nightlight).
/// OFF: a second frame (bob, typing hands, wave, hop). No timer runs unless the view is on screen with the notch open; the wall clock
/// ticks once a minute. Hovering only brightens a station's cursor.
struct AgentDenView: View {
    @ObservedObject var store: AgentsStore
    @Environment(\.notchNavigator) private var navigator
    @Environment(\.agentDenTime) private var fixedTime
    /// The agent whose window is open (nil: just the den).
    var detailID: String?
    var banner: AgentAnnouncement?
    var empty = AgentDenEmptyNote()
    var onSelect: (String?) -> Void = { _ in }
    /// The tallest the open island can be (nil in pictures and tests): the den keeps its height when the window fits under it.
    @Environment(\.notchOpenMaxHeight) private var openMax
    /// Gallery and tests: draw this one moment instead of running the clock, and a fixed reading of the Mac's load.
    var fixedClock: AgentNookClock?
    var fixedLoad: (cpu: Double, memory: Double)?
    /// Tests: told where the parts are.
    var onFrames: (([String: CGRect]) -> Void)?

    @State private var appeared = false
    @State private var open = false
    /// The den's height while no window is open: an open window keeps it, so nobody moves.
    @State private var closedHeight: CGFloat?

    private var running: Bool { AgentNookPanelView.isRunning(appeared: appeared, open: open, fixed: fixedClock != nil || fixedTime != nil, scripted: ScoutRuntime.isScripted) }

    private func clock(at date: Date) -> AgentNookClock {
        if let fixedClock { return fixedClock }
        guard running else { return .still }
        return AgentNookClock(t: date.timeIntervalSinceReferenceDate, motion: !ScoutRuntime.reduceMotion)
    }

    var body: some View {
        Group {
            if Retro.is8bit {
                denBody
            } else {
                AgentMiniView(store: store, detailID: detailID, banner: banner, empty: empty, onSelect: onSelect)   // the minimal look (AgentMiniViews.swift)
            }
        }
        .coordinateSpace(name: "agentden")
        .onPreferenceChange(AgentDenFramesKey.self) { frames in onFrames?(frames) }
        .notchContent(screen: Retro.is8bit)   // the 8-bit TV is a picture: dark glass inside the light preset too
        .onAppear { appeared = true; open = navigator.isOpen }
        .onDisappear { appeared = false }
        .onReceive(navigator.$isOpen) { open = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Retro.is8bit ? "Agent TV den" : "Agents")
    }

    /// The 8-bit look: the den.
    private var denBody: some View {
        GeometryReader { geo in
            let full = geo.size
            let stations = AgentDenStation.stations(store.sessions, pending: store.pending)
            let detail = detailID.flatMap { id in store.sessions.first { $0.id == id } }
            let variants = AgentFaceArt.variants(for: store.sessions.map(\.id))
            // An open agent's window lies UNDER the den, across its whole width: the den keeps the top, its agents the whole rug. The den keeps
            // its own height while the window is open, whatever the island's height on the way: cut to "what is left above the window" it
            // shrank to 200 pt the moment an agent was clicked and grew back with the island, and every agent re-laid out, like a reload.
            // Only the window's part grows.
            // Where the island cannot grow enough (a short screen, a picture's fixed panel) the den gives the window room, down to 200 pt.
            // Picking an agent never moves the others: the den keeps its full height while the window opens under it, and only where the
            // island cannot hold even a short window (160 pt) does it give room
            let room = openMax.map { $0 - AgentDenLayout.chrome } ?? full.height
            let closedDen = min(full.height, AgentDenLayout.baseHeight)
            let size = CGSize(width: full.width, height: detail == nil ? closedDen
                              : min(closedHeight ?? closedDen, max(200, room - AgentDenLayout.shortestWindow)))
            let spots = AgentDenLayout.spots(count: stations.count, size: size, rightEdge: AgentDenLayout.rightEdge(width: size.width, window: false))
            VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                backdrop(size)
                TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !running)) { context in
                    let clock = clock(at: context.date)
                    ZStack(alignment: .topLeading) {
                        Canvas { ctx, canvas in
                            var c = ctx
                            AgentDenArt.drawGlow(&c, size: canvas, clock: clock, night: night)
                            if stations.isEmpty { AgentDenArt.drawEmptyDen(&c, size: canvas, clock: clock, px: AgentDenArt.roomCell, note: empty.asksAction) }
                        }
                        ForEach(Array(stations.enumerated()), id: \.element.id) { i, station in
                            if let spot = spots.first(where: { $0.index == i }) {
                                AgentDenStationView(station: station, spot: spot, clock: clock.shifted(AgentFaceArt.phase(for: station.id)), selected: station.id == detail?.id, glow: store.flashed.contains(station.id),
                                                    variant: variants[station.id] ?? 0) {
                                    // The agent already open stays as it is: a second tap closed its window and the room animated again,
                                    // which looked broken.
                                    // The window's own close key closes it.
                                    if station.id != detailID { onSelect(station.id) }
                                }
                                .frame(width: spot.rect.width, height: spot.rect.height)
                                .denFrame(station.id)
                                .position(x: spot.rect.midX, y: spot.rect.midY)
                            }
                        }
                    }
                }
                if stations.isEmpty && empty.asksAction { emptyNote(size) }
                // No CPU and memory plate on the den's wall any more.
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipShape(Rectangle())
                if let detail {
                    // Edge to edge under the den, down to the island's bottom (its rounded corners trim the window): an 8 pt margin showed a
                    // strip of the island under it, a black line on dark
                    AgentDenWindow(session: detail, store: store, banner: banner?.sessionID == detail.id ? banner : nil, below: true) { onSelect(nil) }
                        .frame(width: full.width, height: max(80, full.height - size.height), alignment: .top)
                        .denFrame("window")
                        .transition(.opacity)
                }
            }
            .frame(width: full.width, height: full.height, alignment: .topLeading)
            .onAppear { if detail == nil { closedHeight = closedDen } }
            .onChange(of: closedDen) { _, height in if detail == nil { closedHeight = height } }
        }
    }

    /// Whether the window is showing night (the real hour, or the picture's fixed time).
    private var night: Bool { !AgentDenSky.isDay(fixedTime ?? Date()) }

    /// The room and what hangs in it: they change once a minute (the clock) and at the hours of sunrise and sunset.
    @ViewBuilder private func backdrop(_ size: CGSize) -> some View {
        if let fixedTime {
            room(size, date: fixedTime)
        } else {
            TimelineView(.everyMinute) { context in room(size, date: context.date) }
        }
    }

    private func room(_ size: CGSize, date: Date) -> some View {
        let isNight = !AgentDenSky.isDay(date)
        return ZStack {
            Canvas { ctx, canvas in var c = ctx; AgentDenArt.drawRoom(&c, size: canvas, night: isNight) }
            Canvas { ctx, canvas in var c = ctx; AgentDenArt.drawDecor(&c, size: canvas, date: date, night: isNight) }
        }
        .frame(width: size.width, height: size.height)
        .drawingGroup(opaque: true)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The Mac's CPU and memory on a small wall plate: two labelled LED bars.
    private var wallMeter: some View {
        AgentTVLoadBars(labels: .full, bar: CGSize(width: 40, height: 8), segments: 8, pixel: 1.5, spacing: 4, vertical: true, fixed: fixedLoad)
            .padding(.horizontal, 7).padding(.vertical, 6)
            .background(Color.clear.retroBevel(.raised, cornerRadius: 3, depth: 1.5, face: Retro.Ink.plasticDark))
            .accessibilityLabel("Mac load")
    }

    /// The line where the empty den's TV used to stand, and its key (only when something must be done; always inside the den).
    private func emptyNote(_ size: CGSize) -> some View {
        let tv = AgentDenArt.emptyFrame(size: size, px: AgentDenArt.roomCell)
        // Wide enough for the long line (the folders cannot be read yet) to stay on one line in a den of the usual width.
        let width = min(size.width - 2 * AgentDenLayout.sideMargin, 780)
        let x = min(max(AgentDenLayout.sideMargin, tv.midX - width / 2), size.width - AgentDenLayout.sideMargin - width)
        // The room under the TV, down to the rug's inner frame: the line and its key stand on the rug's field, never on its border
        // (a line that wraps in a narrow den grows upward, toward the TV).
        let top = tv.maxY + 3
        let room = max(40, size.height - AgentDenLayout.bottomMargin - 4 - top)
        return VStack(spacing: 6) {
            Text(empty.line)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white.opacity(0.94))
                .multilineTextAlignment(.center).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color.clear.retroBevel(.sunken, cornerRadius: 3, depth: 1.5, face: Color(red: 0.07, green: 0.07, blue: 0.09)))
            if let title = empty.keyTitle, let action = empty.action {
                Button(title, action: action).buttonStyle(.retro(tint: Retro.Ink.plasticMid)).denFrame("emptykey")
            }
        }
        .frame(width: width)
        .denFrame("emptynote")
        .frame(height: room, alignment: .bottom)
        .offset(x: x, y: top)
    }
}

/// One agent's station: the picture (the agent and what it touches), and under it a name plate with the project in pixel capitals.
/// A click opens the agent's window; hovering only shows the cursor.
struct AgentDenStationView: View {
    var station: AgentDenStation
    var spot: AgentDenSpot
    var clock: AgentNookClock
    var selected: Bool
    var glow: Bool
    /// Its own skin (`AgentFaceArt.variants`).
    var variant = 0
    var action: () -> Void
    @State private var hover = false
    /// True for the couple of seconds after the station appears or its look changes: the face moves its mouth then, like the wing's face.
    @State private var burst = true

    private var room: AgentNookRoomModel { station.room }

    var body: some View {
        let px = spot.px
        Button(action: action) {
            VStack(spacing: 0) {
                Canvas { ctx, size in
                    var c = ctx
                    AgentDenArt.drawStation(&c, station, kind: room.kind, prop: room.prop, clock: clock, origin: .zero, px: px, selected: selected, hover: hover, glow: glow,
                                            variant: variant, burst: burst)
                }
                .frame(width: CGFloat(AgentDenArt.station.w) * px, height: CGFloat(AgentDenArt.station.h) * px)
                .task(id: room.look) {
                    burst = true
                    try? await Task.sleep(nanoseconds: UInt64(AgentFaceArt.burstSeconds * 1_000_000_000))
                    if !Task.isCancelled { burst = false }
                }
                plate(px: px)
                    .frame(height: AgentDenLayout.plateHeight)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(StillButtonStyle())   // an agent stays solid under a held click
        .onHover { hover = $0 }
        .help("\(room.project): \(room.look.title)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(room.accessibilityText)
    }

    /// The name plate: a wooden plate, the kind's colour as a small block, the project in pixel capitals and a lamp for the state.
    private func plate(px: CGFloat) -> some View {
        let pixel: CGFloat = px >= 4 ? 2 : 1.5
        let width = CGFloat(AgentDenArt.station.w) * px
        let name = AgentNookRoom.fit(room.project, pixel: pixel, width: max(30, width - 36))
        let lamp: Color = {
            switch room.look {
            case .working: Retro.Ink.ledGreen
            case .needsYou: Retro.Ink.ledYellow
            case .finished: Retro.Ink.teal
            case .stopped: Retro.Ink.ledRed
            case .idle: Color(white: 0.45)
            }
        }()
        return HStack(spacing: 5) {
            Rectangle().fill(room.kind.tint).frame(width: pixel * 2, height: pixel * 5)
            RetroPixelText(name, pixel: pixel, color: Retro.Ink.osdWhite)
            Rectangle().fill(lamp).frame(width: pixel * 2.5, height: pixel * 2.5)
        }
        .padding(.horizontal, 6)
        .frame(height: 7 * pixel + 8)
        .background(Rectangle().fill(PixelPalette.rgb(0.34, 0.21, 0.14)))
        .overlay(Rectangle().strokeBorder(selected ? Color(red: 1.0, green: 0.84, blue: 0.20) : PixelPalette.rgb(0.16, 0.10, 0.07), lineWidth: selected ? 2 : 1.5))
        .fixedSize()
    }
}
