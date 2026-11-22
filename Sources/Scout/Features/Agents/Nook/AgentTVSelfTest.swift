import AppKit
import SwiftUI

/// Self-test of Agent TV and the den, OFFSCREEN (nothing shows, the pointer never moves, the owner's Scout is never involved). It runs
/// headless, as its own build:
///   build/Scout.app/Contents/MacOS/Scout --automation --headless --run "scout://agenttv.selftest?out=/path/agenttv.txt" & PID=$!
/// then wait for the file and `kill $PID`. It checks the channel in focus, ON AIR, NO SIGNAL, the rooms on the glass at every width from 3
/// to 16 cells, the den's spots for 1, 3, 6 and 9 agents, the window by the hour, and with real clicks: an agent in the den opens its
/// window and the den stays, and the automatic opening lands on its agent with the banner.
@MainActor
enum AgentTVSelfTest {
    /// Called from `AgentNookSelfTest.register()`.
    static func register() {
        DebugCommands.register("agenttv.selftest") { params in
            guard ScoutRuntime.isAutomation else { return }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("agenttv-selftest.txt")
            Task { @MainActor in await run(out: out) }
        }
    }

    private struct Report {
        var lines: [String] = []
        var failed = 0

        /// Put in front of every check name (the minimal look's run says so).
        var tag = ""

        mutating func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failed += 1 }
            lines.append("agenttv selftest \(ok ? "ok  " : "FAIL") \(tag)\(name)\(ok || detail.isEmpty ? "" : "  (\(detail))")")
        }

        mutating func note(_ text: String) { lines.append("agenttv selftest note \(text)") }
    }

    static func run(out: URL) async {
        var r = Report()
        channel(&r)
        oneRule(&r)
        widths(&r)
        spots(&r)
        fills(&r)
        sky(&r)
        pure(&r)
        await MainActor.run { helpersUnder(&r) }
        await renders(&r)
        await clicks(&r)
        await stayPut(&r)
        await stayPutInIsland(&r)
        await fillsIsland(&r)
        await automatic(&r)
        await minimal(&r)
        r.lines.append("agenttv selftest done: \(r.failed == 0 ? "all passed" : "\(r.failed) FAILED")")
        try? r.lines.joined(separator: "\n").appending("\n").write(to: out, atomically: true, encoding: .utf8)
    }

    // MARK: The channel in focus, ON AIR

    private static func model(_ id: String, _ look: AgentNookLook, helpers: Int = 0, todos: Int = 0) -> AgentNookRoomModel {
        var s = AgentSession(id: id, agent: .claude, cwd: "/Users/you/Dev/\(id)", title: "x", state: .idle)
        s.subagents = helpers
        s.todos = (0..<todos).map { AgentTodo(text: "t\($0)", active: "t\($0)", status: .pending) }
        switch look {
        case .working: s.state = .working
        case .needsYou: s.state = .waiting
        case .finished: s.state = .done
        case .stopped: s.state = .done; s.steps = [AgentStep(id: "f", tool: "Bash", summary: "x", at: Date(), done: true, failed: true)]
        case .idle: s.state = .idle
        }
        return AgentNookRoomModel(s)
    }

    private static func channel(_ r: inout Report) {
        let rooms = [model("a", .needsYou), model("b", .working, helpers: 1), model("c", .working, helpers: 3), model("d", .finished)]
        let pick = AgentTVChannel.focus(rooms)
        r.check("the channel in focus is the room that needs you", pick?.id == "a" && pick?.channel == 1 && pick?.project == "a", "\(String(describing: pick))")
        let busy = AgentTVChannel.focus([model("a", .finished), model("b", .working, helpers: 1), model("c", .working, helpers: 3), model("d", .idle)])
        r.check("without one that needs you, the busiest working room (most helpers) is in focus", busy?.id == "c" && busy?.channel == 3, "\(String(describing: busy))")
        let tie = AgentTVChannel.focus([model("a", .working, todos: 2), model("b", .working, todos: 5), model("c", .working, todos: 5)])
        r.check("a tie goes to the room with more to do, then to the first", tie?.id == "b", "\(String(describing: tie))")
        let none = AgentTVChannel.focus([model("a", .finished), model("b", .idle)])
        r.check("nobody working: the first room", none?.id == "a" && none?.channel == 1)
        r.check("no rooms: no channel", AgentTVChannel.focus([]) == nil)
        r.check("the channel reads like a set's own display", AgentTVChannel.channelText(2) == "CH 02" && AgentTVChannel.channelText(12) == "CH 12")
        r.check("ON AIR is lit while any agent needs you", AgentTVChannel.onAir(rooms))
        r.check("ON AIR is dark when nobody does", !AgentTVChannel.onAir([model("a", .working), model("b", .finished), model("c", .stopped), model("d", .idle)]))
        r.check("ON AIR is dark with nobody home", !AgentTVChannel.onAir([]))
    }

    // MARK: One rule for "needs you"

    /// A session in the state the app really sees: `.waiting` with or without a finish time, with or without a failed last step.
    private static func waiting(_ id: String, finished: Bool, failed: Bool = false) -> AgentSession {
        var s = AgentSession(id: id, agent: .claude, cwd: "/Users/you/Dev/\(id)", title: "x", state: .waiting)
        s.turnStartedAt = Date().addingTimeInterval(-12 * 60 - 30)
        if finished { s.finishedAt = Date().addingTimeInterval(-30); s.note = "Finished: waiting for your next message" }
        s.steps = [AgentStep(id: "s", tool: "Bash", summary: "swift test", at: Date(), done: true, failed: failed)]
        return s
    }

    private static func oneRule(_ r: inout Report) {
        let finished = waiting("fin", finished: true), stopped = waiting("stop", finished: true, failed: true), asking = waiting("ask", finished: false)
        let sessions = [finished, stopped, asking]
        let expected: [(String, AgentNookLook)] = [("fin", .finished), ("stop", .stopped), ("ask", .needsYou)]
        let models = AgentNookPanelView.models(sessions)
        let stations = AgentDenStation.stations(sessions)
        for (id, look) in expected {
            let name = look == .finished ? "a turn that ended (waiting with a finish time) FINISHED" : (look == .stopped ? "a turn that ended on a failed step STOPPED"
                        : "a wait with no finish time (a question) NEEDS YOU")
            let session = sessions.first { $0.id == id }!
            r.check("\(name): the set's room", models.first { $0.id == id }?.look == look, "\(String(describing: models.first { $0.id == id }?.look))")
            r.check("  the den's station", stations.first { $0.id == id }?.room.look == look, "\(String(describing: stations.first { $0.id == id }?.room.look))")
            r.check("  the window", AgentNookLook.of(session) == look, "\(AgentNookLook.of(session))")
        }
        r.check("the set's rooms and the den's stations stand in the same fixed order, whatever each one is doing", models.map(\.id) == stations.map(\.id)
                && models.map(\.id) == AgentTileMetrics.ordered(sessions).map(\.id), "\(models.map(\.id)) / \(stations.map(\.id))")
        r.check("ON AIR follows the one rule: a finished turn does not light it, a question does",
                !AgentTVChannel.onAir(AgentNookPanelView.models([finished, stopped])) && AgentTVChannel.onAir(AgentNookPanelView.models([finished, asking])))
        r.check("the room that needs you is in focus, not the finished one", AgentTVChannel.focus(AgentNookPanelView.models([finished, asking]))?.id == "ask")
        let fin = stations.first { $0.id == "fin" }, stop = stations.first { $0.id == "stop" }
        r.check("a finished or stopped turn shows how long it took (about 12 min), the TV's counter", fin?.tookSeconds != nil && abs((fin?.tookSeconds ?? 0) - 12 * 60) < 5 && stop?.tookSeconds != nil)
        r.check("an asking one has no finished time on a TV", stations.first { $0.id == "ask" }?.tookSeconds == nil)
        r.check("the window's clock: running while working or asking, a fixed duration when finished or stopped",
                AgentDenWindow.clockMode(.working) == .running && AgentDenWindow.clockMode(.needsYou) == .running && AgentDenWindow.clockMode(.finished) == .fixed
                && AgentDenWindow.clockMode(.stopped) == .fixed && AgentDenWindow.clockMode(.idle) == .none)
        r.check("the window's progress bar is one colour: lit segments count like the kit's, never red",
                AgentDenProgress.lit(value: 1, segments: 4) == 4 && AgentDenProgress.lit(value: 0.5, segments: 4) == 2 && AgentDenProgress.lit(value: 0, segments: 4) == 0)
        r.check("the window's state word follows: DONE, STOPPED, NEEDS YOU",
                AgentDenWindow.stateWord(.finished).word == "DONE" && AgentDenWindow.stateWord(.stopped).word == "STOPPED" && AgentDenWindow.stateWord(.needsYou).word == "NEEDS YOU")
    }

    // MARK: The rooms on the glass at every width

    private static func widths(_ r: inout Report) {
        var shownAt9: [Int] = []
        for cells in 3...16 {
            let w = AgentTVLayout.width(cells: cells)
            for count in [0, 1, 2, 3, 4, 6, 9] {
                let p = AgentTVLayout.plan(panelWidth: w, count: count)
                let door = p.more > 0 ? AgentNookLayout.gap + AgentNookLayout.doorWidth : 0
                let used = CGFloat(p.shown) * p.roomWidth + CGFloat(max(0, p.shown - 1)) * AgentNookLayout.gap + door
                let ok = p.shown + p.more == count && (count == 0 || p.shown >= 1) && (count == 0 || used <= p.rooms.width + 0.5 || p.shown == 1)
                r.check("\(cells) cells, \(count) agents: \(p.shown) rooms\(p.more > 0 ? " and a +\(p.more) door" : "") fit the glass", ok, "used \(used) of \(p.rooms.width)")
                r.check("\(cells) cells, \(count) agents: the glass is inside the panel", p.glass.minX >= 0 && p.glass.maxX <= w && p.glass.maxY <= AgentTVLayout.height, "\(p.glass)")
                if count == 9 { shownAt9.append(p.shown) }
            }
        }
        r.note("rooms shown for 9 agents, 3 to 16 cells: \(shownAt9)")
        r.check("the wider the panel, the more rooms (9 agents)", shownAt9 == shownAt9.sorted() && shownAt9.first == 1 && (shownAt9.last ?? 0) >= 8, "\(shownAt9)")
        let three = AgentTVLayout.plan(panelWidth: AgentTVLayout.width(cells: 3), count: 6)
        r.check("3 cells: one room and a +N door", three.shown == 1 && three.more == 5)
        let wide = AgentTVLayout.plan(panelWidth: AgentTVLayout.width(cells: 16), count: 9)
        r.check("16 cells, 9 agents: all nine rooms, no door", wide.shown == 9 && wide.more == 0, "\(wide.shown) +\(wide.more)")
        for cells in 10...16 {
            let p = AgentTVLayout.plan(panelWidth: AgentTVLayout.width(cells: cells), count: 3)
            r.check("\(cells) cells: a wide console, the glass is no longer than \(Int(AgentTVLayout.glassMax)) pt and the speaker takes the rest",
                    p.wide && p.glass.width <= AgentTVLayout.glassMax + 0.5 && p.speaker >= AgentTVLayout.consoleSpeakerMin - 0.5 && p.strip == AgentTVLayout.consoleStrip, "\(p.glass.width) speaker \(p.speaker)")
        }
        r.check("up to 9 cells it is the kit's set", (3...9).allSatisfy { !AgentTVLayout.plan(panelWidth: AgentTVLayout.width(cells: $0), count: 1).wide })
        r.check("the glass is never stretched longer than the console allows: at most 4.5 to 1", (10...16).allSatisfy {
            let g = AgentTVLayout.plan(panelWidth: AgentTVLayout.width(cells: $0), count: 1).glass; return g.width / g.height <= 4.6
        })
    }

    // MARK: The den's spots

    private static func spots(_ r: inout Report) {
        for size in [CGSize(width: 960, height: 360), CGSize(width: 1240, height: 360), CGSize(width: 620, height: 360), CGSize(width: 960, height: 420)] {
            for count in 1...9 {
                for window in [false, true] {
                    let right = AgentDenLayout.rightEdge(width: size.width, window: window)
                    let spots = AgentDenLayout.spots(count: count, size: size, rightEdge: right)
                    let valid = spots.count == count && AgentDenLayout.isValid(spots, in: size, rightEdge: right)
                    let crisp = spots.allSatisfy { AgentPixel.isCrisp($0.px) && $0.px >= 0.5 }
                    if count == 1 || count == 3 || count == 6 || count == 9 || !valid || !crisp {
                        r.check("den \(Int(size.width)) wide, \(count) agent\(count == 1 ? "" : "s")\(window ? ", window open" : ""): all inside the room and the rug, none overlapping, nothing under the window, whole-pixel sizes", valid && crisp,
                                "\(spots.map { "\(Int($0.rect.minX)),\(Int($0.rect.minY)) \(Int($0.rect.width))x\(Int($0.rect.height))" }) right \(Int(right))")
                    }
                }
            }
        }
        let size = CGSize(width: 960, height: 360)
        for n in [1, 3, 6, 9] {
            let spots = AgentDenLayout.spots(count: n, size: size)
            r.note("\(n) agents: \(spots.count) spots, pixel \(spots.first?.px ?? 0) pt, rows \(Set(spots.map(\.row)).count)")
        }
        let nine = AgentDenLayout.spots(count: 9, size: size)
        r.check("nine agents stand in two rows, the first ones in front", Set(nine.map(\.row)) == [0, 1] && nine.prefix(5).allSatisfy { $0.row == 0 } && nine.suffix(4).allSatisfy { $0.row == 1 })
        r.check("a few agents get big pixels, nine get small ones", (AgentDenLayout.spots(count: 1, size: size).first?.px ?? 0) > (nine.first?.px ?? 9))
        let three = AgentDenLayout.spots(count: 3, size: size)
        r.check("three agents are one row, left to right in order", Set(three.map(\.row)) == [0] && three[0].rect.minX < three[1].rect.minX && three[1].rect.minX < three[2].rect.minX)
        r.check("the den's height holds the notch's rule: about 340 to 380 pt", AgentDenLayout.baseHeight >= 340 && AgentDenLayout.baseHeight <= 380
                && AgentDenLayout.islandHeight() == AgentDenLayout.baseHeight + AgentDenLayout.chrome && AgentDenLayout.islandHeight() >= 320)
        r.check("a banner asks the island for more room", AgentDenLayout.extraHeight(banner: true) > AgentDenLayout.extraHeight(banner: false))
    }

    // MARK: The room fills the island

    /// The den fills the whole open notch down to its bottom edge (the owner asked twice, 2026-11-22): the
    /// island is asked for the base height plus `chrome`, and under its real header the den is given more than the base height. The room is laid
    /// out to all of it in whole cells; the stations keep their sizes, a single or front row stands on the longer floor, a back row stays put.
    private static func fills(_ r: inout Report) {
        let header = NotchGeometry.sample16.classicSize.height
        let inset = header + 2   // the open island's header and the gap above the den (the den takes the island edge to edge under it)
        let fill = AgentDenLayout.fillHeight(inset: inset)
        let whole = AgentDenLayout.wholeCells(fill)
        let cell = AgentDenArt.roomCell
        r.check("a picture or a test with no island keeps the base height; the notch's header leaves the den more, and the island holds exactly that",
                AgentDenLayout.fillHeight(inset: nil) == AgentDenLayout.baseHeight && AgentDenLayout.wholeCells(AgentDenLayout.baseHeight) == AgentDenLayout.baseHeight
                && fill > AgentDenLayout.baseHeight && fill + inset == AgentDenLayout.islandHeight(), "fill \(fill) inset \(inset) island \(AgentDenLayout.islandHeight())")
        r.check("a header taller than the island's own allowance never makes the den shorter than the base height", AgentDenLayout.fillHeight(inset: AgentDenLayout.chrome + 10) == AgentDenLayout.baseHeight)
        r.check("the room is drawn in whole cells: \(Int(fill)) pt becomes \(Int(whole)) pt (\(Int(whole / cell)) rows), under one cell is left over, a hair under a whole number still counts",
                whole.truncatingRemainder(dividingBy: cell) == 0 && fill - whole >= 0 && fill - whole < cell && AgentDenPlan(size: CGSize(width: 960, height: whole)).rows == Int(whole / cell)
                && AgentDenLayout.wholeCells(whole - 0.001) == whole && AgentDenLayout.wholeCells(whole + cell - 0.5) == whole, "whole \(whole) rows \(AgentDenPlan(size: CGSize(width: 960, height: whole)).rows)")
        for width in [CGFloat(960), 640, 1040] {
            for count in [1, 3, 6, 9] {
                let base = AgentDenLayout.spots(count: count, size: CGSize(width: width, height: AgentDenLayout.baseHeight))
                let size = CGSize(width: width, height: whole)
                let tall = AgentDenLayout.spots(count: count, size: size)
                let sameSize = base.count == tall.count && zip(base, tall).allSatisfy { $0.px == $1.px && $0.rect.size == $1.rect.size && $0.rect.minX == $1.rect.minX && $0.row == $1.row }
                let front = tall.filter { $0.row == 0 }, back = tall.filter { $0.row == 1 }
                let frontOnBottom = !front.isEmpty && front.allSatisfy { abs($0.rect.maxY - (whole - AgentDenLayout.bottomMargin)) < 0.01 }
                let backStays = zip(base.filter { $0.row == 1 }, back).allSatisfy { $0.rect == $1.rect }
                let crisp = tall.allSatisfy { AgentPixel.isCrisp($0.px) }
                r.check("room \(Int(width)) x \(Int(whole)), \(count) agent\(count == 1 ? "" : "s"): the sizes and spacing of the base den, the front row \(Int(AgentDenLayout.bottomMargin)) pt above the new bottom, a back row where it stood, whole-pixel sizes",
                        sameSize && frontOnBottom && backStays && crisp && AgentDenLayout.isValid(tall, in: size),
                        "pixel \(tall.first?.px ?? 0) vs \(base.first?.px ?? 0), lowest \(tall.map(\.rect.maxY).max() ?? 0) of \(whole), rows \(Set(tall.map(\.row)))")
            }
        }
    }

    /// The den inside the island's own numbers (its header 32 pt and 2 pt above the den, an island of 419 pt), on a rig as tall as an open window needs:
    /// the closed den is the whole 384 pt room, 1 pt under the island's header, and picking an agent leaves every agent where it stood while the
    /// window takes the 250 pt the island gives it.
    private static func stayPutInIsland(_ r: inout Report) async {
        guard Retro.is8bit else { return }
        let inset = NotchGeometry.sample16.classicSize.height + 2
        let store = AgentNookSamples.store(AgentNookSamples.sessions(5))
        let tall = AgentDenLayout.islandHeight(extra: AgentDenLayout.drawerHeight) - inset
        let rig = Rig(size: CGSize(width: 960, height: tall)) { rig in
            AgentsWorkspaceView(store: store).reportingFrames { rig.frames = $0 }
                .environment(\.notchBodyInset, inset).environment(\.notchOpenMaxHeight, AgentDenLayout.islandHeight(extra: AgentDenLayout.drawerHeight) + 40)
        }
        defer { rig.close() }
        await settle(0.8)
        let whole = AgentDenLayout.wholeCells(AgentDenLayout.fillHeight(inset: inset))
        let lift = AgentDenLayout.fillHeight(inset: inset) - whole
        let ids = AgentDenStation.stations(store.sessions).map(\.id)
        let before = ids.compactMap { rig.frames[$0] }
        guard ids.count >= 3, let target = rig.frames[ids[1]] else { r.check("in the island's own numbers, picking an agent keeps the others in place", false, "no frames"); return }
        let lowest = before.map(\.maxY).max() ?? 0
        r.check("in the island's own numbers the closed den's plates stand \(Int(AgentDenLayout.bottomMargin)) pt above the room's bottom (\(Int(whole)) pt, \(lift) pt under the header)",
                abs(lowest - (lift + whole - AgentDenLayout.bottomMargin)) < 0.5, "lowest \(lowest) want \(lift + whole - AgentDenLayout.bottomMargin)")
        rig.click(CGPoint(x: target.midX, y: target.minY + target.height * 0.4))
        await settle(0.6)
        let after = ids.compactMap { rig.frames[$0] }
        let moved = zip(before, after).map { abs($0.minY - $1.minY) + abs($0.minX - $1.minX) }.max() ?? 99
        let window = rig.frames["window"]
        r.check("in the island's own numbers, picking an agent opens its window and leaves every agent where it stood; the window takes the island's 250 pt",
                window != nil && before.count == after.count && moved < 0.5 && abs((window?.height ?? 0) - AgentDenLayout.drawerHeight) < 0.5 && abs((window?.maxY ?? 0) - tall) < 0.5,
                "moved up to \(moved) pt, window \(String(describing: window)) of \(tall)")
        // A short screen cuts the island below the den's height: the room still ends exactly at the island's bottom edge (what is left over under a
        // cell goes above it), so no strip of the island's own black shows under it.
        for short in [CGFloat(236), 237, 238, 301] {
            let shortRig = Rig(size: CGSize(width: 960, height: short)) { _ in AgentsWorkspaceView(store: store).environment(\.notchBodyInset, inset).environment(\.notchOpenMaxHeight, short + inset) }
            await settle(0.6)
            let bottom = shortRig.brightness(CGRect(x: 100, y: short - 1.5, width: 700, height: 1.4))   // the last row of points: the panelling or the carpet, never the rig's black
            r.check("a short island (\(Int(short)) pt for the den, \(Int(short + inset)) pt in all): the room reaches its bottom edge", bottom > 0.08, "brightness of the last points \(bottom)")
            shortRig.close()
        }
    }

    /// The den in the REAL open notch (its header, its navigator, the height the Agents view asks for), read pixel by pixel, with 0, 1, 3 and 9
    /// agents at the three sizes, and under an open window: the rows at the bottom of the island are the room's art and never the island's flat
    /// surface, and the room ends in whole cells (the rug's dark border lies exactly two cells, 6 points of the content, above the bottom edge).
    private static func fillsIsland(_ r: inout Report) async {
        guard Retro.is8bit else { return }
        let forced = ProcessInfo.processInfo.environment["SCOUT_SCALE"] != nil
        let savedSize = UserDefaults.standard.object(forKey: Look.scaleKey)
        defer { if let savedSize { UserDefaults.standard.set(savedSize, forKey: Look.scaleKey) } else { UserDefaults.standard.removeObject(forKey: Look.scaleKey) } }
        let nav = NotchNavigator.shared
        let store = AgentsStore.shared
        // The shared store's scanner reads the scripted run's own, empty folders and would empty the made-up agents within seconds: it is switched off here.
        let scanWas = UserDefaults.standard.object(forKey: AgentsStore.Key.scan)
        Pref.set(false, AgentsStore.Key.scan)
        defer { Pref.set(scanWas, AgentsStore.Key.scan) }
        try? await Task.sleep(nanoseconds: 400_000_000)
        defer { store.focusID = nil; store.announcement = nil; store.clearSamples(); nav.forceClose(); nav.workspace = .nook }
        func srgb(_ color: Color) -> NSColor { NSColor(color).usingColorSpace(.sRGB) ?? .black }
        func same(_ a: NSColor, _ b: NSColor, _ tolerance: CGFloat) -> Bool {
            max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent)) <= tolerance
        }
        let surface = srgb(Look.surface)
        let border = srgb(PixelPalette.world(.claude).color("o") ?? .black)   // the rug's dark outer border, the last art before the carpet's two rows
        for size in forced ? [Look.size] : Look.Size.allCases {
            if !forced { Pref.set(size.rawValue, Look.scaleKey) }
            let f = size.factor
            for (count, window) in [(0, false), (1, false), (3, false), (9, false), (6, true)] {
                store.focusID = nil
                store.announcement = nil
                store.loadSessions(AgentNookSamples.sessions(count))
                // The window opens the way an automatic opening does: the store holds that agent's banner and focus, so there is no click to time.
                if window { store.announcement = AgentAnnouncement(sessionID: "nk-1", kind: .needsYou, at: Date()); store.focusID = "nk-1" }
                nav.open(.agents)
                let panelSize = CGSize(width: 1560, height: 1200)
                let model = NotchScreenModel(geometry: .sample16, panelSize: panelSize)
                model.isOpen = true
                let root = NotchRootView(model: model, center: LiveActivityCenter(), navigator: nav, nook: NookStore(persist: false, layout: nil), styleOverride: .classic)
                let panel = NSPanel(contentRect: CGRect(x: -20000, y: -20000, width: panelSize.width, height: panelSize.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                let hosting = NSHostingView(rootView: AnyView(root.environment(\.agentDenTime, AgentTVGallery.day)))   // the day's colours, whatever the hour
                hosting.frame = CGRect(origin: .zero, size: panelSize)
                panel.contentView = hosting
                panel.orderFrontRegardless()
                for _ in 0..<(window ? 20 : 12) { try? await Task.sleep(nanoseconds: 100_000_000); hosting.layoutSubtreeIfNeeded() }
                let want = (window ? AgentDenLayout.islandHeight(extra: AgentDenLayout.drawerHeight + AgentDenLayout.extraHeight(banner: true)) : AgentDenLayout.islandHeight()) * f
                let island = model.islandRect
                var flat: [String] = []
                var cells = ""
                var whole = true
                if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(panelSize.width * 2), pixelsHigh: Int(panelSize.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                              hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                    rep.size = panelSize
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    let pixels = LookSelfTest.Pixels(rep: rep, points: panelSize)
                    // Rows 2, 6, 12 and 20 content points above the island's bottom edge (the old strip was 25 tall), across the middle of the
                    // island (the rounded corners are not in it): the share of pixels that are not the island's own surface. Under a window only the
                    // first two (its black glass screens end 12 pt above the bottom).
                    for above in window ? [2.0, 6.0] : [2.0, 6.0, 12.0, 20.0] {
                        let y = island.maxY - CGFloat(above) * f
                        var art = 0, total = 0
                        var x = island.minX + island.width * 0.2
                        while x < island.maxX - island.width * 0.2 {
                            total += 1
                            if let c = pixels.color(CGPoint(x: x, y: y)), !same(c, surface, 0.06) { art += 1 }
                            x += 3
                        }
                        let share = total == 0 ? 0 : Double(art) / Double(total)
                        if share < 0.9 { flat.append("\(Int(above)) pt above the bottom: \(Int(share * 100)) % art") }
                    }
                    // Whole cells: walking up from the bottom edge, the first row of the rug's dark border is 2 cells (6 content points) above it.
                    if !window {
                        var measured: [String] = []
                        for fraction in [0.3, 0.5, 0.7] {
                            let x = island.minX + island.width * fraction
                            var above = 0.25
                            var found: Double?
                            while above < 30 * Double(f) {
                                if let c = pixels.color(CGPoint(x: x, y: island.maxY - CGFloat(above))), same(c, border, 0.05) { found = above; break }
                                above += 0.25
                            }
                            let distance = (found ?? 99) / Double(f)   // in content points: 6 is two whole cells (the pixel row's own width is 0.5 pt at 1x)
                            measured.append(String(format: "%.1f", distance))
                            if abs(distance - 2 * Double(AgentDenArt.roomCell)) > 0.9 { whole = false }
                        }
                        cells = measured.joined(separator: ", ")
                    }
                }
                let label = "the real notch at size \(size.title), \(count) agent\(count == 1 ? "" : "s")\(window ? ", a window open under the den" : "")"
                r.check("\(label): the island is \(Int(want)) pt tall and the picture reaches its bottom edge (no flat strip under it)",
                        abs(island.height - want) <= 2 && flat.isEmpty && store.sessions.count == count && (!window || store.shownDetailID == "nk-1"),
                        "island \(Int(island.height)) want \(Int(want)); shown \(String(describing: store.shownDetailID)) asked \(nav.workspaceHeight.map { String(Int($0)) } ?? "nil"); agents \(store.sessions.count), focus \(String(describing: store.focusID)), banner \(store.announcement != nil), workspace \(nav.workspace); \(flat.joined(separator: "; "))")
                if !window {
                    r.check("\(label): the room ends in whole cells (the rug's border 6 pt above the bottom edge)", whole, "distances in content points \(cells)")
                }
                // The view goes away for good before the next one starts: a view that lingers would still answer to the store and to the navigator.
                hosting.rootView = AnyView(EmptyView())
                panel.orderOut(nil)
                panel.contentView = nil
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    // MARK: The window and the clock

    private static func sky(_ r: inout Report) {
        let table: [(Int, Bool)] = [(0, false), (5, false), (6, false), (7, true), (12, true), (18, true), (19, false), (23, false)]
        for (hour, day) in table { r.check("the window shows \(day ? "day" : "night") at \(hour):00", AgentDenSky.isDay(hour: hour) == day) }
        func at(_ h: Int, _ m: Int) -> Date { AgentTVGallery.moment(hour: h, minute: m) }
        let three = AgentDenSky.clockAngles(at(3, 0)), half = AgentDenSky.clockAngles(at(9, 30)), pm = AgentDenSky.clockAngles(at(15, 0))
        r.check("the wall clock's hands: 3:00, 9:30, 15:00", abs(three.hour - 90) < 0.01 && three.minute == 0 && abs(half.hour - 285) < 0.01 && half.minute == 180 && abs(pm.hour - 90) < 0.01)
        let tookChecks: [(TimeInterval, String, String)] = [(45, "45", "SEC"), (12 * 60, "12", "MIN"), (59 * 60 + 40, "59", "MIN"), (150 * 60, "3", "HRS")]
        for (seconds, digits, unit) in tookChecks {
            let t = AgentDenStation.took(seconds)
            r.check("a task of \(Int(seconds)) s took \(digits) \(unit)", t.digits == digits && t.unit == unit, "\(t)")
        }
    }

    // MARK: The pure parts of a station

    private static func pure(_ r: inout Report) {
        let sessions = AgentNookSamples.sessions(9)
        let stations = AgentDenStation.stations(sessions)
        let fixed = sessions.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }.map(\.id)
        r.check("every agent gets a station, in the fixed order (the first started on the left), the one that asks too", stations.count == 9
                && stations.map(\.id) == fixed && stations.contains { $0.id == "nk-3" && $0.room.look == .needsYou }, "\(stations.map(\.id))")
        let done = stations.first { $0.room.look == .finished }
        r.check("a finished task knows how long it took", done?.tookSeconds != nil && (done?.tookSeconds ?? 0) > 0)
        r.check("a working agent has no time on a TV", stations.filter { $0.room.look == .working }.allSatisfy { $0.tookSeconds == nil })
        for (count, drawn, more) in [(0, 0, 0), (1, 1, 0), (3, 3, 0), (4, 4, 0), (5, 3, 2), (7, 3, 4), (12, 3, 9)] {
            let row = AgentDenLayout.helperRow(count: count)
            r.check("\(count) helpers on the floor row: \(drawn) drawn and \(more > 0 ? "+\(more)" : "no +N")", row.drawn == drawn && row.more == more, "\(row)")
            let need = row.drawn * 9 - 1 + (row.more > 0 ? 1 + AgentPixel.textWidth("+\(row.more)") : 0)
            r.check("  the row and its +N fit the station's \(AgentDenLayout.cells.w) cells", row.drawn == 0 || need <= AgentDenLayout.cells.w, "need \(need)")
        }
        r.check("the den knows the five looks of a station", Set(stations.map(\.room.look)) == Set(AgentNookLook.allCases))
        let plan = AgentDenPlan(size: CGSize(width: 960, height: 360))
        r.check("the wall has room for its fixtures: window, posters, sign, shelf in order, all inside", plan.window < plan.posterA && plan.posterA < plan.sign && plan.sign < plan.posterB && plan.posterB < plan.shelf
                && plan.shelf + 23 < plan.cols && plan.rail < plan.wallRows, "\(plan)")
        let narrow = AgentDenPlan(size: CGSize(width: 620, height: 360))
        r.check("and in a narrow den too", narrow.window - 19 > 0 && narrow.posterA + 14 < narrow.sign - 24 && narrow.sign + 24 < narrow.posterB - 10 && narrow.posterB + 10 < narrow.shelf - 23 && narrow.shelf + 23 < narrow.cols, "\(narrow)")
        let kitSet = AgentTVLoadBars.wantsSampler(appeared: true, open: true, gallery: false)
        r.check("the wall meter and the set's bars hold the Mac's sampler only on screen with the notch open", kitSet && !AgentTVLoadBars.wantsSampler(appeared: true, open: false, gallery: false) && !AgentTVLoadBars.wantsSampler(appeared: false, open: true, gallery: false))
        r.check("the den's clock runs only on screen with the notch open, never in a picture or a test", AgentNookPanelView.isRunning(appeared: true, open: true, fixed: false, scripted: false)
                && !AgentNookPanelView.isRunning(appeared: true, open: false, fixed: false, scripted: false) && !AgentNookPanelView.isRunning(appeared: true, open: true, fixed: true, scripted: false)
                && !AgentNookPanelView.isRunning(appeared: true, open: true, fixed: false, scripted: true))
    }

    // MARK: The helpers stand right under their agent (the den)

    /// One station drawn at `px` points a cell, as RGBA pixels (a still clock: the first frame, no hop).
    @MainActor private static func stationPixels(_ look: AgentNookLook, helpers: Int, px: CGFloat) -> [UInt8]? {
        let session = AgentNookSamples.one(look, prop: .pencil, kind: .claude, project: "site", helpers: helpers, todos: 0, done: 0)
        let station = AgentDenStation(session)
        let view = Canvas { ctx, _ in
            var c = ctx
            AgentDenArt.drawStation(&c, station, kind: .claude, prop: .pencil, clock: .still, origin: .zero, px: px, selected: false, hover: false, glow: false)
        }
        .frame(width: CGFloat(AgentDenArt.station.w) * px, height: CGFloat(AgentDenArt.station.h) * px).background(Color.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return nil }
        var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        guard let ctx = CGContext(data: &data, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return data
    }

    @MainActor private static func helpersUnder(_ r: inout Report) {
        // The arithmetic, for 1 to 14 helpers in every state: the row stays inside the station's cells with its +N, is an even number of cells
        // wide (so its middle is a cell edge, like the figure's), is centred on the figure whenever it can be, starts at the figure's bottom
        // edge and (for awake helpers) rests a row lower so a hop never lands on the agent.
        var inside = true, even = true, centred = true, under = true, hops = true, floor = true
        var detail = ""
        for look in AgentNookLook.allCases {
            let place = AgentDenArt.pictureOrigin(look), box = AgentPixelWorld.figureBox(look)
            let middle = place.x + box.x + AgentPixelSprites.figureWidth / 2, bottom = place.y + box.y + box.h
            for count in 1...14 {
                let row = AgentDenLayout.helperRow(count: count)
                let spot = AgentDenLayout.helperSpot(look: look, drawn: row.drawn, more: row.more)
                let tail = row.more > 0 ? 2 + AgentPixel.textWidth("+\(row.more)") : 0
                if spot.left < 1 || spot.left + spot.width + tail > AgentDenLayout.cells.w - 1 { inside = false; detail = "\(look) \(count): \(spot)" }
                if spot.width % 2 != 0 || spot.width != row.drawn * 8 + (row.drawn - 1) * spot.gap { even = false; detail = "\(look) \(count): \(spot)" }
                let wanted = middle - spot.width / 2
                if wanted >= 1, wanted + spot.width + tail <= AgentDenLayout.cells.w - 1, spot.left != wanted { centred = false; detail = "\(look) \(count): \(spot) wanted \(wanted)" }
                if spot.top < bottom || (look == .working) != (spot.top > bottom) { under = false; detail = "\(look) \(count): top \(spot.top) bottom \(bottom)" }
                if look == .working, spot.top - 1 < bottom { hops = false }
                if spot.top + 8 > AgentDenArt.station.h || (row.more > 0 && spot.label != spot.left + spot.width + 2) { floor = false; detail = "\(look) \(count): \(spot)" }
            }
        }
        r.check("the den's helper row stays inside the station (1 to 14 helpers, every state), +N included", inside, detail)
        r.check("  an even number of cells wide, so it can sit exactly on the figure's middle", even, detail)
        r.check("  centred on the agent's figure whenever it fits that way, shifted inside the station when it does not", centred, detail)
        r.check("  and it starts at the figure's bottom edge (a row lower for the awake ones at the desk)", under, detail)
        r.check("  a hop (one row up) never lands on the agent", hops)
        r.check("  and the helpers and the +N stay in the station's 36 rows", floor, detail)
        // The pixels: what three helpers add to a station is exactly the row the arithmetic says, centred under the figure.
        let px: CGFloat = 4
        for look in AgentNookLook.allCases {
            let spot = AgentDenLayout.helperSpot(look: look, drawn: 3, more: 0)
            let box = AgentPixelWorld.figureBox(look), place = AgentDenArt.pictureOrigin(look)
            let width = AgentDenArt.station.w * Int(px)
            guard let bare = stationPixels(look, helpers: 0, px: px), let withHelpers = stationPixels(look, helpers: 3, px: px), bare.count == withHelpers.count else {
                r.check("\(look): a station with and without helpers renders", false); continue
            }
            var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
            for i in stride(from: 0, to: bare.count, by: 4) where abs(Int(bare[i]) - Int(withHelpers[i])) > 8 || abs(Int(bare[i + 1]) - Int(withHelpers[i + 1])) > 8 || abs(Int(bare[i + 2]) - Int(withHelpers[i + 2])) > 8 {
                let x = (i / 4) % width, y = (i / 4) / width
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
            let figureMiddle = CGFloat(place.x + box.x + AgentPixelSprites.figureWidth / 2) * px
            let rowMiddle = CGFloat(minX + maxX + 1) / 2
            let shifted = spot.left + spot.width / 2 != place.x + box.x + AgentPixelSprites.figureWidth / 2   // the row left the station: only its height is checked then
            r.check("\(look): three helpers are drawn in a row \(spot.width) cells wide, centred under the figure, below its feet",
                    maxX >= 0 && minY >= (place.y + box.y + box.h) * Int(px) && abs(CGFloat(maxX + 1 - minX) / px - CGFloat(spot.width)) <= 1 && (shifted || abs(rowMiddle - figureMiddle) <= px),
                    "pixels \(minX)...\(maxX) x \(minY)...\(maxY), figure middle \(figureMiddle), row middle \(rowMiddle)")
        }
    }

    // MARK: Offscreen windows

    @MainActor private final class Rig {
        let size: CGSize
        let panel: NSPanel
        let navigator = NotchNavigator()
        var frames: [String: CGRect] = [:]

        init<V: View>(size: CGSize, _ make: (Rig) -> V) {
            self.size = size
            panel = NSPanel(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            let view = make(self).environment(\.notchNavigator, navigator).frame(width: size.width, height: size.height).background(Color.black)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = CGRect(origin: .zero, size: size)
            panel.contentView = hosting
            panel.orderFrontRegardless()
        }

        func post(_ type: NSEvent.EventType, _ p: CGPoint) {
            let location = CGPoint(x: p.x, y: size.height - p.y)
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return }
            panel.sendEvent(event)
        }

        func click(_ p: CGPoint) { post(.leftMouseDown, p); post(.leftMouseUp, p) }
        func click(_ frame: CGRect) { click(CGPoint(x: frame.midX, y: frame.midY)) }

        /// The picture's average brightness in a rectangle (0 black, 1 white).
        func brightness(_ rect: CGRect) -> Double {
            guard let hosting = panel.contentView, let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return 0 }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let sx = CGFloat(rep.pixelsWide) / size.width, sy = CGFloat(rep.pixelsHigh) / size.height
            var sum = 0.0, n = 0.0
            for y in stride(from: Int(rect.minY * sy), to: Int(rect.maxY * sy), by: 3) {
                for x in stride(from: Int(rect.minX * sx), to: Int(rect.maxX * sx), by: 3) {
                    if let c = rep.colorAt(x: x, y: y) { sum += Double(c.redComponent + c.greenComponent + c.blueComponent) / 3; n += 1 }
                }
            }
            return n == 0 ? 0 : sum / n
        }

        /// The share of lit, grey pixels in a rectangle (TV snow is grey; the den's wall is blue, its clock cream).
        func greyShare(_ rect: CGRect) -> Double {
            guard let hosting = panel.contentView, let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return 1 }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let sx = CGFloat(rep.pixelsWide) / size.width, sy = CGFloat(rep.pixelsHigh) / size.height
            var grey = 0.0, n = 0.0
            for y in stride(from: Int(rect.minY * sy), to: Int(rect.maxY * sy), by: 2) {
                for x in stride(from: Int(rect.minX * sx), to: Int(rect.maxX * sx), by: 2) {
                    guard let c = rep.colorAt(x: x, y: y) else { continue }
                    let r = Double(c.redComponent), g = Double(c.greenComponent), b = Double(c.blueComponent)
                    n += 1
                    if (r + g + b) / 3 > 0.15 && abs(r - b) < 0.04 && abs(g - b) < 0.04 { grey += 1 }
                }
            }
            return n == 0 ? 0 : grey / n
        }

        /// The brightest pixel in a rectangle (0 black, 1 white).
        func peak(_ rect: CGRect) -> Double {
            guard let hosting = panel.contentView, let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return 0 }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let sx = CGFloat(rep.pixelsWide) / size.width, sy = CGFloat(rep.pixelsHigh) / size.height
            var most = 0.0
            for y in stride(from: max(0, Int(rect.minY * sy)), to: min(rep.pixelsHigh, Int(rect.maxY * sy)), by: 1) {
                for x in stride(from: max(0, Int(rect.minX * sx)), to: min(rep.pixelsWide, Int(rect.maxX * sx)), by: 1) {
                    if let c = rep.colorAt(x: x, y: y) { most = max(most, Double(c.redComponent + c.greenComponent + c.blueComponent) / 3) }
                }
            }
            return most
        }

        /// How green the greenest pixel in a rectangle is (green above the mean of red and blue): the channel's phosphor letters are green, snow is grey.
        func greenness(_ rect: CGRect) -> Double {
            guard let hosting = panel.contentView, let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return 1 }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let sx = CGFloat(rep.pixelsWide) / size.width, sy = CGFloat(rep.pixelsHigh) / size.height
            var most = 0.0
            for y in stride(from: Int(rect.minY * sy), to: Int(rect.maxY * sy), by: 1) {
                for x in stride(from: Int(rect.minX * sx), to: Int(rect.maxX * sx), by: 1) {
                    if let c = rep.colorAt(x: x, y: y) { most = max(most, Double(c.greenComponent) - Double(c.redComponent + c.blueComponent) / 2) }
                }
            }
            return most
        }

        func close() { panel.contentView = nil; panel.orderOut(nil) }
    }

    private static func settle(_ seconds: Double = 0.5) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    /// A day's window is bright, a night's dark; the empty den is empty (a note only when the folders cannot be read); the empty TV is switched off.
    private static func renders(_ r: inout Report) async {
        let store = AgentNookSamples.store(AgentNookSamples.sessions(3))
        var levels: [Double] = []
        for time in [AgentTVGallery.day, AgentTVGallery.night] {
            let rig = Rig(size: CGSize(width: 960, height: 360)) { rig in
                AgentDenView(store: store, fixedClock: .still, fixedLoad: (0.4, 0.6), onFrames: { rig.frames = $0 }).environment(\.agentDenTime, time)
            }
            await settle()
            levels.append(rig.brightness(CGRect(x: 70, y: 36, width: 70, height: 60)))   // the window's glass
            rig.close()
        }
        r.check("the window is brighter by day than by night", levels[0] > levels[1] + 0.12, "day \(levels[0]) night \(levels[1])")
        let empty = AgentNookSamples.store([])
        let rig = Rig(size: CGSize(width: 960, height: 360)) { rig in AgentDenView(store: empty, fixedClock: .still, fixedLoad: (0.4, 0.6), onFrames: { rig.frames = $0 }) }
        await settle()
        let tv = AgentDenArt.emptyFrame(size: rig.size, px: AgentDenArt.roomCell)
        let glass = tv.insetBy(dx: tv.width * 0.12, dy: tv.height * 0.14)
        // No lit glass where the TV stood, no note, no agents.
        r.check("nobody home: the den is empty (no TV snow, no note)", rig.greyShare(glass) < 0.2 && rig.frames["emptynote"] == nil && rig.frames.keys.filter { $0.hasPrefix("nk-") }.isEmpty,
                "grey \(rig.greyShare(glass)) frames \(rig.frames.keys.sorted())")
        // White pixel capitals in the middle of the floor.
        let wallBottom = CGFloat(AgentDenPlan(size: rig.size).wallRows) * AgentDenArt.roomCell
        let floorMiddle = CGRect(x: rig.size.width / 2 - 90, y: wallBottom, width: 180, height: rig.size.height - wallBottom)
        r.check("nobody home: the den says NO AGENTS on its floor", rig.peak(floorMiddle) > 0.85, "brightest \(rig.peak(floorMiddle))")
        rig.close()
        let denied = AgentNookSamples.store([])
        denied.previewScan(.init(access: [.claude: .denied, .codex: .missing], tracked: 0, sessions: 0, watching: false, lastSweep: Date()))
        let deniedRig = Rig(size: CGSize(width: 960, height: 360)) { rig in
            AgentDenView(store: denied, empty: AgentsWorkspaceView.emptyNote(store: denied), fixedClock: .still, fixedLoad: (0.4, 0.6), onFrames: { rig.frames = $0 })
        }
        await settle()
        r.check("the folders cannot be read: the empty den still shows its line and the key", deniedRig.frames["emptynote"] != nil && deniedRig.frames["emptykey"] != nil, "frames \(deniedRig.frames.keys.sorted())")
        if let note = deniedRig.frames["emptynote"] {
            let above = CGRect(x: deniedRig.size.width / 2 - 90, y: CGFloat(AgentDenPlan(size: deniedRig.size).wallRows) * AgentDenArt.roomCell, width: 180, height: max(1, note.minY - CGFloat(AgentDenPlan(size: deniedRig.size).wallRows) * AgentDenArt.roomCell))
            r.check("  and no NO AGENTS words on its floor then (the note says it)", deniedRig.peak(above) < 0.85, "brightest \(deniedRig.peak(above))")
        }
        deniedRig.close()
        // The TV with nobody home: switched off, black shiny glass, nothing written.
        let panelRig = Rig(size: CGSize(width: AgentTVLayout.width(cells: 6), height: AgentTVLayout.height)) { _ in AgentNookPanelView(store: empty).frozen(.still).load(cpu: 0.4, memory: 0.5) }
        await settle()
        let glassMiddle = CGRect(x: 60, y: 60, width: 110, height: 50), band = CGRect(x: 20, y: 6, width: 120, height: 18)
        r.check("nobody home: the set is off (dark glass)", panelRig.brightness(glassMiddle) < 0.12, "\(panelRig.brightness(glassMiddle))")
        // The words are there, but faint.
        let glow = panelRig.peak(CGRect(x: 30, y: 40, width: 170, height: 80))
        r.check("nobody home: NO AGENTS lies faintly on the glass, like a reflection", glow > 0.12 && glow < 0.5, "brightest \(glow)")
        r.check("nobody home: nothing written on the glass, no channel", panelRig.greenness(band) < 0.12, "green \(panelRig.greenness(band))")
        panelRig.close()
    }

    // MARK: Real clicks

    private static func clicks(_ r: inout Report) async {
        let store = AgentNookSamples.store(AgentNookSamples.sessions(6))
        let rig = Rig(size: CGSize(width: 960, height: 420)) { rig in AgentsWorkspaceView(store: store).reportingFrames { rig.frames = $0 } }
        defer { rig.close() }
        await settle(0.8)
        let ids = AgentDenStation.stations(store.sessions).map(\.id)
        // The minimal look always shows one agent's history beside the list (the first while none is picked); the den shows none until a click.
        let minimal = !Retro.is8bit
        r.check(minimal ? "every agent has its row, and the first one's history shows beside the list" : "every agent has its spot in the den",
                ids.allSatisfy { rig.frames[$0] != nil } && (minimal ? rig.frames["window"] != nil : rig.frames["window"] == nil), "frames \(rig.frames.keys.sorted())")
        let before = ids.compactMap { rig.frames[$0] }
        guard ids.count >= 3, let target = rig.frames[ids[2]] else { r.check("an agent can be clicked", false, "no frame"); return }
        // Hovering changes nothing but the cursor.
        rig.post(.mouseMoved, CGPoint(x: target.midX, y: target.midY))
        await settle(0.2)
        r.check("hovering an agent opens nothing", store.shownDetailID == nil && (minimal || rig.frames["window"] == nil))
        rig.click(CGPoint(x: target.midX, y: target.minY + target.height * 0.4))
        await settle(0.5)
        r.check("a click on an agent opens its detail in a window", store.shownDetailID == ids[2] && store.selectedID == ids[2] && rig.frames["window"] != nil, "shown \(String(describing: store.shownDetailID))")
        let stillThere = ids.allSatisfy { rig.frames[$0] != nil }
        if Retro.is8bit {
            r.check("and the den stays on screen above it (every agent still has its spot; the window lies UNDER them, across the den's width)", stillThere && ids.allSatisfy { id in
                guard let f = rig.frames[id], let w = rig.frames["window"] else { return false }
                return f.maxY <= w.minY + 1
            } && (rig.frames["window"].map { $0.width >= rig.size.width - 24 } ?? false), "frames \(rig.frames.keys.sorted()) window \(String(describing: rig.frames["window"]))")
            r.check("  the window shows the agent's whole workflow", rig.frames["workflow"].map { w in rig.frames["window"]?.contains(CGPoint(x: w.midX, y: w.midY)) ?? false } ?? false)
            // The island's walls stand 12 pt inside the view and its bottom corners are round: the panels and the close key keep inside them
            let wall = AgentNookPanelView.islandShoulder
            if let flow = rig.frames["workflow"], let close = rig.frames["close"] {
                r.check("  the workflow panel and the close key stand inside the island's walls and clear of its bottom corners",
                        flow.maxX <= rig.size.width - wall - 4 && close.maxX <= rig.size.width - wall - 2 && close.minX >= wall && flow.maxY <= rig.size.height - 10,
                        "workflow \(flow) close \(close) size \(rig.size)")
            } else {
                r.check("  the workflow panel and the close key stand inside the island's walls", false, "frames \(rig.frames.keys.sorted())")
            }
        } else {
            r.check("and the cards stay on screen beside it (every agent still has its card, the detail does not cover them)", stillThere && ids.allSatisfy { id in
                guard let f = rig.frames[id], let w = rig.frames["window"] else { return false }
                return f.maxX <= w.minX + 1
            }, "frames \(rig.frames.keys.sorted())")
        }
        if minimal {
            r.check("the list stays where it is (nothing re-lays itself)", ids.compactMap { rig.frames[$0] } == before)
            r.check("no close key: the history always shows one agent", rig.frames["close"] == nil, "frames \(rig.frames.keys.sorted())")
        } else {
            // This rig's island cannot grow (a fixed 420 pt): the den gives the window room. Where the island can grow, nobody moves (below).
            r.check("in a short island the den gives the window room", ids.compactMap { rig.frames[$0] } != before)
        }
        if minimal {
        } else if let w = rig.frames["window"], let close = rig.frames["close"] {
            r.check("the window sits inside the den and its close key inside the window", rig.frames.keys.contains("close") && w.contains(close) && w.maxX <= rig.size.width + 0.5 && w.maxY <= rig.size.height + 0.5, "\(w) \(close)")
            rig.click(close)
            await settle(0.5)
            r.check("the close key goes back to the den: no window, nothing shown", store.shownDetailID == nil && rig.frames["window"] == nil, "shown \(String(describing: store.shownDetailID))")
        } else {
            r.check("the window has a close key", false, "frames \(rig.frames.keys.sorted())")
        }
        // Another agent switches the window; a second click on the open one changes nothing;
        // its close key closes it.
        if let first = rig.frames[ids[0]] {
            rig.click(first)
            await settle(0.4)
            let opened = store.shownDetailID == ids[0]
            if let again = rig.frames[ids[0]], let other = rig.frames[ids[1]] {
                rig.click(other)
                await settle(0.4)
                let switched = store.shownDetailID == ids[1]
                if let second = rig.frames[ids[1]] {
                    rig.click(second)
                    await settle(0.4)
                    r.check("a click on another agent switches the window, a second click on the open one keeps it as it is", opened && switched && store.shownDetailID == ids[1] && again.width > 0, "shown \(String(describing: store.shownDetailID))")
                }
            }
        }
        // The dashboard's click path: a focus id picks the agent.
        store.focusID = ids[3]
        await settle(0.5)
        r.check("a focus id (a click on the dashboard's TV) opens that agent's window and is used up", store.shownDetailID == ids[3] && store.focusID == nil && rig.frames["window"] != nil, "shown \(String(describing: store.shownDetailID))")
    }

    /// With room
    /// for the window under the den, a click leaves every agent exactly where it stood.
    private static func stayPut(_ r: inout Report) async {
        guard Retro.is8bit else { return }
        let store = AgentNookSamples.store(AgentNookSamples.sessions(5))
        let tall = AgentDenLayout.baseHeight + AgentDenLayout.drawerHeight
        let rig = Rig(size: CGSize(width: 960, height: tall)) { rig in
            AgentsWorkspaceView(store: store).reportingFrames { rig.frames = $0 }.environment(\.notchOpenMaxHeight, tall + AgentDenLayout.chrome + 40)
        }
        defer { rig.close() }
        await settle(0.8)
        let ids = AgentDenStation.stations(store.sessions).map(\.id)
        let before = ids.compactMap { rig.frames[$0] }
        guard ids.count >= 3, let target = rig.frames[ids[1]] else { r.check("picking an agent keeps the others in place", false, "no frames"); return }
        rig.click(CGPoint(x: target.midX, y: target.minY + target.height * 0.4))
        await settle(0.6)
        let after = ids.compactMap { rig.frames[$0] }
        let moved = zip(before, after).map { abs($0.minY - $1.minY) + abs($0.minX - $1.minX) }.max() ?? 99
        r.check("picking an agent opens its window and leaves every agent where it stood", rig.frames["window"] != nil && before.count == after.count && moved < 0.5,
                "moved up to \(moved) pt, window \(String(describing: rig.frames["window"]))")
    }

    // MARK: The automatic opening

    private static func automatic(_ r: inout Report) async {
        let id = "nk-3"
        let store = AgentNookSamples.store(Array(AgentNookSamples.sessions(7)))
        store.announcement = AgentAnnouncement(sessionID: id, kind: .needsYou, at: Date())
        store.focusID = id
        let rig = Rig(size: CGSize(width: 960, height: 480)) { rig in AgentsWorkspaceView(store: store).reportingFrames { rig.frames = $0 } }
        await settle(0.8)
        r.check("automatic opening (needs you): the den lands on its agent with the banner", store.shownDetailID == id && store.focusID == nil && rig.frames["window"] != nil && rig.frames["banner"] != nil,
                "shown \(String(describing: store.shownDetailID)) frames \(rig.frames.keys.sorted())")
        r.check("  the den is still there, and the agent's spot too", rig.frames[id] != nil && rig.frames.keys.filter { $0.hasPrefix("nk-") }.count == 7)
        rig.close()
        let head = AgentBanner.headline(AgentAnnouncement(sessionID: "x", kind: .needsYou, at: Date()), project: "infra")
        r.check("the pager says who needs you", head == "infra needs you", head)
        r.check("the pager's LCD is amber for a question", AgentBanner.lcd(.needsYou) == Retro.Ink.phosphorAmber)
    }

    // MARK: The minimal look (8-bit style off)

    /// The same real clicks in the minimal look (the style switch is turned off here and put back): a row in the list picks the agent whose
    /// history fills the right side, and the automatic opening lands on its agent with the flat banner.
    private static func minimal(_ r: inout Report) async {
        guard Retro.is8bit else { r.note("minimal look skipped: the look is forced by SCOUT_8BIT"); return }
        Pref.set(false, Retro.styleKey)
        defer { Pref.set(nil, Retro.styleKey) }
        r.tag = "[minimal] "
        defer { r.tag = "" }
        r.check("the style switch is off for these checks", !Retro.is8bit)
        await clicks(&r)
        await automatic(&r)
        // The empty full view: a calm card with its line and, when there is something to do, a plain button.
        let empty = AgentNookSamples.store([])
        let rig = Rig(size: CGSize(width: 960, height: 360)) { rig in AgentsWorkspaceView(store: empty).reportingFrames { rig.frames = $0 } }
        await settle(0.6)
        r.check("nobody home: one calm card and no agent cards", rig.frames["emptynote"] != nil && rig.frames.keys.filter { $0.hasPrefix("nk-") }.isEmpty, "frames \(rig.frames.keys.sorted())")
        r.check("  and the picture is not blank", rig.brightness(CGRect(x: 300, y: 100, width: 360, height: 160)) > 0.02, "\(rig.brightness(CGRect(x: 300, y: 100, width: 360, height: 160)))")
        rig.close()
        // The list at the left and the history at the right, both down to the bottom edge; a taller notch gives both more
        var heights: [CGFloat] = []
        for height in [CGFloat(420), 640] {
            let full = AgentNookSamples.store(AgentNookSamples.sessions(6))
            let fullRig = Rig(size: CGSize(width: 960, height: height)) { rig in AgentsWorkspaceView(store: full).reportingFrames { rig.frames = $0 } }
            await settle(0.7)
            let rowIDs = AgentMiniRow.rows(full.sessions).map(\.id)
            if let window = fullRig.frames["window"], let firstRow = rowIDs.first.flatMap({ fullRig.frames[$0] }) {
                let rowsLeft = rowIDs.compactMap { fullRig.frames[$0] }.allSatisfy { $0.maxX <= window.minX + 1 }
                r.check("height \(Int(height)): the history fills down to the bottom edge, the rows stand at its left in one column",
                        window.maxY >= height - AgentMiniView.margin - 2 && window.minY <= AgentMiniView.margin + 2 && rowsLeft
                        && rowIDs.compactMap({ fullRig.frames[$0] }).allSatisfy { abs($0.minX - firstRow.minX) < 1 }, "window \(window) row \(firstRow)")
                heights.append(window.height)
            } else {
                r.check("height \(Int(height)): the history shows", false, "frames \(fullRig.frames.keys.sorted())")
            }
            fullRig.close()
        }
        r.check("a taller notch gives the history all of it", heights.count == 2 && heights[1] >= heights[0] + 200, "\(heights)")
        r.check("the list column is about a third, 220 to 340 pt", AgentMiniView.listWidth(for: 960) >= 220 && AgentMiniView.listWidth(for: 960) <= 340 && AgentMiniView.listWidth(for: 500) == 220)
        // The flat banner says the same words as the pager.
        let head = AgentBanner.headline(AgentAnnouncement(sessionID: "x", kind: .needsYou, at: Date()), project: "infra")
        r.check("the flat banner uses the same headline", head == "infra needs you", head)
    }
}
