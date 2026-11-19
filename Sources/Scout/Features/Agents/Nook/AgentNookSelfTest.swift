import AppKit
import SwiftUI

/// Self-test of the AgentNook, OFFSCREEN (nothing shows, the pointer never moves, the owner's Scout is never involved). It runs
/// headless, as its own build:
///   build/Scout.app/Contents/MacOS/Scout --automation --headless --run "scout://agentnook.selftest?out=/path/agentnook.txt" & PID=$!
/// then wait for the file and `kill $PID`. It checks the state → look mapping, the props, the helpers and the to-do blocks, the
/// order of the rooms, how many rooms fit from 3 to 16 cells, the empty house, and a real click on a room and on the "+N" door.
@MainActor
enum AgentNookSelfTest {
    /// Called from `HeadlessChecks.registerAll()`.
    static func register() {
        AgentTVSelfTest.register()   // agenttv.selftest: Agent TV and the den (channel, ON AIR, NO SIGNAL, widths, spots, clicks, the keys)
        DebugCommands.register("agentnook.selftest") { params in
            guard ScoutRuntime.isAutomation else { return }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("agentnook-selftest.txt")
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
            lines.append("agentnook selftest \(ok ? "ok  " : "FAIL") \(tag)\(name)\(ok || detail.isEmpty ? "" : "  (\(detail))")")
        }

        mutating func note(_ text: String) { lines.append("agentnook selftest note \(text)") }
    }

    static func run(out: URL) async {
        var r = Report()
        looks(&r)
        props(&r)
        helpers(&r)
        blocks(&r)
        sentences(&r)
        order(&r)
        layout(&r)
        rows(&r)
        helpersUnder(&r)
        scale(&r)
        empty(&r)
        motion(&r)
        pixels(&r)
        faces(&r)
        bigFigures(&r)
        await fits(&r)
        await clicks(&r)
        await minimal(&r)
        await closedNotch(&r)
        let savedSize = UserDefaults.standard.object(forKey: Look.scaleKey)
        let savedPreset = UserDefaults.standard.object(forKey: Look.presetKey)
        for preset in ["light", "dark"] {   // the owner uses the light colours
            UserDefaults.standard.set(preset, forKey: Look.presetKey)
            for size in ["normal", "large", "xlarge"] {   // every Size setting: the owner's notch is not the normal size
                UserDefaults.standard.set(size, forKey: Look.scaleKey)
                r.tag = "[\(preset) \(size)] "
                await tvCorner(&r, out: out)
            }
        }
        UserDefaults.standard.set(savedPreset, forKey: Look.presetKey)
        r.tag = ""
        UserDefaults.standard.set(savedSize, forKey: Look.scaleKey)
        await askAIToAgents(&r)
        r.lines.append("agentnook selftest done: \(r.failed == 0 ? "all passed" : "\(r.failed) FAILED")")
        try? r.lines.joined(separator: "\n").appending("\n").write(to: out, atomically: true, encoding: .utf8)
    }

    // MARK: Looks

    private static func session(_ state: AgentState, steps: [AgentStep] = [], helpers: Int = 0, todos: [AgentTodo] = []) -> AgentSession {
        var s = AgentSession(id: "t-\(UUID().uuidString.prefix(6))", agent: .claude, cwd: "/Users/you/Dev/site", title: "Fix the footer links", state: state)
        s.steps = steps
        s.subagents = helpers
        s.todos = todos
        return s
    }

    private static func step(_ tool: String, done: Bool = false, failed: Bool = false) -> AgentStep {
        AgentStep(id: UUID().uuidString, tool: tool, summary: "x", at: Date(), done: done, failed: failed)
    }

    private static func looks(_ r: inout Report) {
        let table: [(AgentNookLook, AgentNookLook.Light, AgentNookLook.Flag?, AgentNookLook.Pose, Bool)] = [
            (.working, .lampOn, nil, .typing, false),
            (.needsYou, .amber, .amber, .doorWave, false),
            (.finished, .daylight, .green, .holdingCheck, false),
            (.stopped, .dim, .red, .dizzy, false),
            (.idle, .dark, nil, .asleep, true),
        ]
        for (look, light, flag, pose, moon) in table {
            r.check("look \(look.title): light, flag, pose, moon", look.light == light && look.flag == flag && look.pose == pose && look.hasMoon == moon,
                    "light \(look.light) flag \(String(describing: look.flag)) pose \(look.pose) moon \(look.hasMoon)")
        }
        r.check("working session looks working", AgentNookLook.of(session(.working, steps: [step("Bash")]), needsYou: false) == .working)
        r.check("a waiting session needs you", AgentNookLook.of(session(.waiting), needsYou: false) == .needsYou)
        r.check("a held request makes any session need you", AgentNookLook.of(session(.working), needsYou: true) == .needsYou)
        r.check("done looks finished", AgentNookLook.of(session(.done, steps: [step("Edit", done: true)]), needsYou: false) == .finished)
        r.check("done after a failed step looks stopped", AgentNookLook.of(session(.done, steps: [step("Bash", done: true, failed: true)]), needsYou: false) == .stopped)
        r.check("idle after a failed step looks stopped", AgentNookLook.of(session(.idle, steps: [step("Bash", done: true, failed: true)]), needsYou: false) == .stopped)
        r.check("a failed step earlier in the turn does not stop a working agent",
                AgentNookLook.of(session(.working, steps: [step("Bash", done: true, failed: true), step("Edit")]), needsYou: false) == .working)
        r.check("a later good step clears the failure", AgentNookLook.of(session(.done, steps: [step("Bash", done: true, failed: true), step("Edit", done: true)]), needsYou: false) == .finished)
        r.check("idle looks idle", AgentNookLook.of(session(.idle), needsYou: false) == .idle)
    }

    // MARK: Props

    private static func props(_ r: inout Report) {
        let cases: [(String, AgentNookProp?)] = [("Bash", .wrench), ("MCP", .wrench), ("shell", .wrench), ("Edit", .pencil), ("Write", .pencil), ("MultiEdit", .pencil),
                                                  ("Read", .magnifier), ("Grep", .magnifier), ("Glob", .magnifier), ("WebSearch", .globe), ("WebFetch", .globe), ("Task", nil)]
        for (tool, expected) in cases {
            r.check("prop for \(tool)", AgentNookProp.of(tool: tool) == expected, "\(String(describing: AgentNookProp.of(tool: tool)))")
        }
        r.check("the prop follows the step running now", AgentNookProp.of(session(.working, steps: [step("Read", done: true), step("Edit")])) == .pencil)
        r.check("no prop while it only thinks", AgentNookProp.of(session(.working, steps: [step("Read", done: true)])) == nil)
        r.check("no prop when it does not work", AgentNookProp.of(session(.done, steps: [step("Edit")])) == nil)
    }

    // MARK: Helpers and blocks

    private static func helpers(_ r: inout Report) {
        let expected: [(Int, Int, Int)] = [(0, 0, 0), (1, 1, 0), (3, 3, 0), (4, 4, 0), (5, 4, 1), (7, 4, 3), (12, 4, 8)]
        for (n, drawn, more) in expected {
            let m = AgentNookRoomModel(session(.working, helpers: n), needsYou: false)
            r.check("\(n) helpers: \(drawn) drawn and \(more > 0 ? "+\(more)" : "no +N")", m.helpersDrawn == drawn && m.helpersMore == more, "drawn \(m.helpersDrawn) more \(m.helpersMore)")
        }
        let narrow = AgentNookRoomModel(session(.working, helpers: 7), needsYou: false).helperSlots(available: 42, mini: 7.5, spacing: 2.5, label: 11)
        r.check("a narrow compact room draws fewer helpers so +N stays whole", narrow.drawn == 3 && narrow.more == 4, "\(narrow)")
        let roomy = AgentNookRoomModel(session(.working, helpers: 7), needsYou: false).helperSlots(available: 120, mini: 11, spacing: 3, label: 14)
        r.check("a roomy room draws four helpers and +3", roomy.drawn == 4 && roomy.more == 3, "\(roomy)")
        r.check("helpers are awake while the agent works", AgentNookRoomModel(session(.working, helpers: 2), needsYou: false).helpersAwake)
        r.check("helpers sleep when it does not", !AgentNookRoomModel(session(.idle, helpers: 2), needsYou: false).helpersAwake
                && !AgentNookRoomModel(session(.done, helpers: 2), needsYou: false).helpersAwake)
    }

    private static func todos(_ done: Int, _ total: Int) -> [AgentTodo] {
        (0..<total).map { AgentTodo(text: "t\($0)", active: "t\($0)", status: $0 < done ? .completed : ($0 == done ? .inProgress : .pending)) }
    }

    private static func blocks(_ r: inout Report) {
        let working = AgentNookRoomModel(session(.working, todos: todos(2, 5)), needsYou: false)
        r.check("5 to-dos, 2 done: two filled, one current, two empty", working.blocks(cap: 8) == [.done, .done, .current, .todo, .todo] && working.progressText == "2/5",
                "\(working.blocks(cap: 8)) \(String(describing: working.progressText))")
        let finished = AgentNookRoomModel(session(.done, todos: todos(4, 4)), needsYou: false)
        r.check("all done: every block filled", finished.blocks(cap: 8) == Array(repeating: .done, count: 4) && finished.progressText == "4/4")
        let none = AgentNookRoomModel(session(.working), needsYou: false)
        r.check("no to-dos: no shelf", none.blocks(cap: 8).isEmpty && none.progressText == nil)
        let long = AgentNookRoomModel(session(.working, todos: todos(10, 20)), needsYou: false)
        let longBlocks = long.blocks(cap: 8)
        r.check("20 to-dos, 10 done: eight blocks, half filled", longBlocks.count == 8 && longBlocks.filter { $0 == .done }.count == 4 && long.progressText == "10/20", "\(longBlocks)")
        let waiting = AgentNookRoomModel(session(.waiting, todos: todos(1, 3)), needsYou: false)
        r.check("a room that is not working has no \"current\" block", !waiting.blocks(cap: 8).contains(.current))
    }

    private static func sentences(_ r: inout Report) {
        let cases: [(String, String)] = [("Done. The summary is in notes/summary.md.", "Done."), ("I'll fix the three footer links, then run the linter.", "I'll fix the three footer links, then run the linter."),
                                         ("See notes/summary.md for it", "See notes/summary.md for it"), ("Which region? us-east or eu-west", "Which region?"),
                                         ("First line\nsecond line. Third", "First line second line."), ("", "")]
        for (input, expected) in cases {
            r.check("first sentence of «\(input.replacingOccurrences(of: "\n", with: "⏎"))»", AgentNookText.firstSentence(input) == expected, AgentNookText.firstSentence(input))
        }
    }

    // MARK: Order and layout

    /// One fixed order everywhere: the first started on the left; a change of state moves nobody; when not all fit, the ones that need you
    /// show, still in that order
    private static func order(_ r: inout Report) {
        AgentFoundOrder.reset()
        let sessions = AgentNookSamples.sessions(9)
        let held = AgentPending(sessionID: "nk-6", kind: .permission, tool: "Bash", summary: "terraform apply", detail: "", questions: [], rawToolInput: nil, agent: .codex)
        let models = AgentNookPanelView.models(sessions, pending: [held])
        r.check("every agent gets a room", models.count == 9)
        let fixed = sessions.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }.map(\.id)
        r.check("the rooms stand in the fixed order: the first started on the left", models.map(\.id) == fixed, "\(models.map(\.id))")
        var changed = sessions
        for i in changed.indices { changed[i].state = changed[i].state == .working ? .waiting : .working }
        r.check("  a change of state moves nobody", AgentNookPanelView.models(changed, pending: []).map(\.id) == fixed)
        let three = AgentTileMetrics.keepOrder(models, limit: 3) { AgentTileMetrics.need($0.look) }
        let needing = models.filter { $0.look == .needsYou }
        r.check("  when only three fit, the rooms that need you are among them, still in the fixed order",
                three.count == 3 && needing.allSatisfy { m in three.contains { $0.id == m.id } } && three.map(\.id) == fixed.filter { id in three.contains { $0.id == id } },
                "\(three.map(\.id)), needing \(needing.map(\.id))")
        let four = Array(sessions.prefix(4))
        let faces = AgentWingSummary.make(sessions: four, pending: []).faces.map(\.id)
        let rooms = AgentNookPanelView.models(four, pending: []).map(\.id)
        let stations = AgentDenStation.stations(four, pending: []).map(\.id)
        r.check("the faces, the TV's rooms and the den's stations stand in the same order", faces == rooms && rooms == stations, "faces \(faces) rooms \(rooms) stations \(stations)")
        let six = AgentWingSummary.make(sessions: sessions, pending: [held])
        r.check("  with more agents than faces, the one that needs you has a face, and the faces keep the order", six.faces.contains { $0.id == "nk-6" }
                && six.faces.map(\.id) == fixed.filter { id in six.faces.contains { $0.id == id } } && six.moreFaces == 9 - six.faces.count, "\(six.faces.map(\.id)) +\(six.moreFaces)")
    }

    private static func layout(_ r: inout Report) {
        r.note("rooms on the glass at each width (cells: agents -> style, shown, +N door, room width)")
        for cells in [3, 4, 6, 10, 16] {
            var cols: [String] = []
            for count in [0, 1, 2, 3, 4, 6, 9] {
                let w = AgentTVLayout.width(cells: cells)
                let p = AgentTVLayout.plan(panelWidth: w, count: count)
                let door = p.more > 0 ? AgentNookLayout.gap + AgentNookLayout.doorWidth : 0
                let used = CGFloat(p.shown) * p.roomWidth + CGFloat(max(0, p.shown - 1)) * AgentNookLayout.gap + door
                let name = "\(cells) cells, \(count) agents"
                r.check("\(name): rooms and door add up", p.shown + p.more == count, "shown \(p.shown) more \(p.more)")
                r.check("\(name): fits the glass", count == 0 || used <= p.rooms.width + 0.5 || p.shown == 1, "used \(used) of \(p.rooms.width)")
                r.check("\(name): at least one room", count == 0 || p.shown >= 1)
                r.check("\(name): room width in range", count == 0 || p.roomWidth <= (p.style == .roomy ? AgentNookLayout.roomyMax : AgentNookLayout.compactMax) + 0.01)
                cols.append("\(count): \(p.style == .roomy ? "roomy" : "compact") \(p.shown)\(p.more > 0 ? " +\(p.more)" : "") @\(Int(p.roomWidth))")
            }
            r.note("\(cells) cells: " + cols.joined(separator: " | "))
        }
        let w3 = AgentTVLayout.plan(panelWidth: AgentTVLayout.width(cells: 3), count: 9)
        r.check("3 cells, 9 agents: one room and a +N door", w3.shown == 1 && w3.more == 8, "\(w3)")
        let w16 = AgentTVLayout.plan(panelWidth: AgentTVLayout.width(cells: 16), count: 6)
        r.check("16 cells, 6 agents: all six compact, no door", w16.style == .compact && w16.shown == 6 && w16.more == 0, "\(w16)")
        let w10 = AgentTVLayout.plan(panelWidth: AgentTVLayout.width(cells: 10), count: 3)
        r.check("10 cells, 3 agents: all three, no door", w10.shown == 3 && w10.more == 0, "\(w10)")
        let w3one = AgentTVLayout.plan(panelWidth: AgentTVLayout.width(cells: 3), count: 1)
        r.check("3 cells, 1 agent: one roomy room", w3one.style == .roomy && w3one.shown == 1 && w3one.more == 0, "\(w3one)")
        r.check("the wide console starts at 10 cells", !AgentTVLayout.plan(panelWidth: AgentTVLayout.width(cells: 9), count: 1).wide
                && AgentTVLayout.plan(panelWidth: AgentTVLayout.width(cells: 10), count: 1).wide)
    }

    private static func rows(_ r: inout Report) {
        let big = CGSize(width: 140, height: 105)
        let all = AgentNookRoomRows.plan(helpers: 3, todos: 4, style: .roomy, size: big)
        r.check("a roomy room keeps the scout its space", all.bunk && all.shelf, "\(all)")
        let nothing = AgentNookRoomRows.plan(helpers: 0, todos: 0, style: .roomy, size: big)
        r.check("no helpers, no to-dos: no bunk, no shelf, the sentence fits", !nothing.bunk && !nothing.shelf && nothing.sentence, "\(nothing)")
        let compact = AgentNookRoomRows.plan(helpers: 2, todos: 3, style: .compact, size: CGSize(width: 78, height: 105))
        r.check("a compact room has no sentence", !compact.sentence && compact.bunk && compact.shelf, "\(compact)")
        let wide = AgentNookRoomRows.plan(helpers: 2, todos: 3, style: .roomy, size: CGSize(width: 188, height: 105))
        r.check("a wide room puts the bunk and the shelf side by side", wide.combined && !wide.side, "\(wide)")
        let widest = AgentNookRoomRows.plan(helpers: 2, todos: 3, style: .roomy, size: CGSize(width: 280, height: 105))
        r.check("a very wide room puts the column of details beside the scout", widest.side && widest.bunk && widest.shelf && widest.sentence, "\(widest)")
        let sideNone = AgentNookRoomRows.plan(helpers: 0, todos: 0, style: .roomy, size: CGSize(width: 280, height: 105))
        r.check("no helpers, no to-dos: no bunk and no shelf even in the column", sideNone.side && !sideNone.bunk && !sideNone.shelf, "\(sideNone)")
    }

    // MARK: The helpers stand right under their agent (the dashboard's rooms)

    /// The first and last column and row where two renders differ (nil when nothing does).
    private static func difference(_ a: [UInt8]?, _ b: [UInt8]?, width: Int) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        guard let a, let b, a.count == b.count, width > 0 else { return nil }
        var box: (minX: Int, maxX: Int, minY: Int, maxY: Int)?
        for i in stride(from: 0, to: a.count, by: 4) where abs(Int(a[i]) - Int(b[i])) > 8 || abs(Int(a[i + 1]) - Int(b[i + 1])) > 8 || abs(Int(a[i + 2]) - Int(b[i + 2])) > 8 {
            let x = (i / 4) % width, y = (i / 4) / width
            box = box.map { (min($0.minX, x), max($0.maxX, x), min($0.minY, y), max($0.maxY, y)) } ?? (x, x, y, y)
        }
        return box
    }

    private static func helpersUnder(_ r: inout Report) {
        // The arithmetic: the row is centred on the figure and starts under its body, in every state and at every pixel size and room width.
        var inside = true, centred = true, standing = true, covers = true, hops = true, picture = true
        var detail = ""
        for look in AgentNookLook.allCases {
            let box = AgentPixelWorld.figureBox(look), size = AgentPixelWorld.pictureSize(look)
            let pic = AgentNookCritter.picture(look: look, prop: .pencil, clock: .still)
            if pic.w != size.w || pic.h != size.h { picture = false; detail = "\(look) picture \(pic.w)x\(pic.h) table \(size)" }
            // the table agrees with the picture: the figure (the only 16 wide sprite) stands where the table says
            let figures = pic.placements.filter { $0.sprite.width == AgentPixelSprites.figureWidth }
            if figures.count != 1 || figures[0].x != box.x || figures[0].y != box.y || figures[0].sprite.height != box.h { picture = false; detail = "\(look) figure \(figures.map { "\($0.x),\($0.y),\($0.sprite.height)" }) table \(box)" }
            for px in [1, 1.5, 2, 2.5, 3] as [CGFloat] {
                for (mini, spacing, padding) in [(12, 3, 4), (8, 2.5, 2)] as [(CGFloat, CGFloat, CGFloat)] {
                    for inner in [64, 72, 98, 132, 220] as [CGFloat] {
                        for drawn in 1...4 {
                            let hw = CGFloat(drawn) * mini + CGFloat(drawn - 1) * spacing
                            let bw = hw + 2 * padding + (drawn == 4 ? spacing + 14 : 0)
                            guard bw <= inner else { continue }
                            let left = AgentNookHelperPlace.bunkLeft(look, px: px, inner: inner, padding: padding, helpersWidth: hw, bunkWidth: bw)
                            if left < 0 || left + bw > inner { inside = false; detail = "\(look) px \(px) inner \(inner) drawn \(drawn): left \(left) bunk \(bw)" }
                            let middle = AgentNookHelperPlace.pictureLeft(look, px: px, inner: inner) + AgentNookHelperPlace.figureMiddle(look, px: px)
                            let wanted = middle - padding - hw / 2
                            if wanted >= 0, wanted + bw <= inner, abs(left + padding + hw / 2 - middle) > 0.26 { centred = false; detail = "\(look) px \(px) inner \(inner) drawn \(drawn): centre \(left + padding + hw / 2) figure \(middle)" }
                        }
                    }
                }
                let awake = look == .working
                let top = AgentNookHelperPlace.rowTop(look, px: px, awake: awake, hop: 1.5), over = AgentNookHelperPlace.overlap(look, px: px, awake: awake, hop: 1.5)
                let feet = CGFloat(box.y + box.h) * px
                if top < feet + (awake ? px : 0) - 0.001 { covers = false; detail = "\(look) px \(px): row top \(top) feet \(feet)" }
                if awake, top - 1.5 < feet - 0.001 { hops = false; detail = "\(look) px \(px): a hop reaches \(top - 1.5), the body ends at \(feet)" }
                let standsOnFloor = box.y + box.h == size.h
                if standsOnFloor != (over == 0) { standing = false; detail = "\(look) px \(px): overlap \(over)" }
            }
        }
        r.check("the table of the figure's place and the picture sizes match the real pictures (all five looks)", picture, detail)
        r.check("the helpers' row stays inside the room, at every pixel size and width, with its +N", inside, detail)
        r.check("and the helpers (not the +N) are centred on the agent's figure whenever the row fits that way", centred, detail)
        r.check("the row starts at the figure's bottom edge: standing agents' rows hang under their feet, the desk's and the beanbag's stand in front of the furniture", covers && standing, detail)
        r.check("awake helpers rest a step lower, so a hop never lands on the agent", hops, detail)

        // The pictures: a room with one helper and the same room with three differ in the helpers' row only, and that row is centred under
        // the figure in the real drawing (the planks and the helpers; rendered at 2x like the owner's screen, where every cell is whole pixels).
        let size = CGSize(width: 140, height: 105)
        for look in AgentNookLook.allCases {
            func room(_ helpers: Int) -> [UInt8]? {
                let model = AgentNookRoomModel(AgentNookSamples.one(look, prop: .pencil, kind: .claude, project: "site", helpers: helpers, todos: 0, done: 0), needsYou: look == .needsYou)
                return rendered(AgentNookRoom(model: model, style: .roomy, reserveRow: true, shared: true), size: size, scale: 2)
            }
            let plan = AgentNookRoomRows.plan(helpers: 3, todos: 0, style: .roomy, size: size, needsRow: true)
            let m = AgentNookRoomRows.metrics(.roomy)
            let middle = m.pad + AgentNookHelperPlace.pictureLeft(look, px: plan.px, inner: size.width - 2 * m.pad) + AgentNookHelperPlace.figureMiddle(look, px: plan.px)
            guard let box = difference(room(1), room(3), width: Int(size.width) * 2) else { r.check("\(look): three helpers differ from one", false); continue }
            let centre = CGFloat(box.minX + box.maxX + 1) / 4   // pixels at 2x
            r.check("\(look): the helpers' row is drawn centred under the figure (row middle \(centre) pt, figure \(middle) pt)", abs(centre - middle) <= 1.5, "\(box)")
        }
    }

    private static func scale(_ r: inout Report) {
        // One pixel size for every scout of a screen, a multiple of half a point.
        for (style, size) in [(AgentNookLayout.Style.roomy, CGSize(width: 88, height: 75)), (.compact, CGSize(width: 54, height: 75)), (.compact, CGSize(width: 66, height: 100)), (.roomy, CGSize(width: 102, height: 100)), (.compact, CGSize(width: 83, height: 100))] {
            let px = AgentNookRoomRows.scoutPixel(style: style, size: size, needsRow: true)
            let withRow = AgentNookRoomRows.plan(helpers: 3, todos: 4, style: style, size: size, needsRow: true)
            let without = AgentNookRoomRows.plan(helpers: 0, todos: 0, style: style, size: size, needsRow: true)
            r.check("\(style) room \(Int(size.width))x\(Int(size.height)): a room with helpers and a counter and one without have the same scout size (\(px) pt)",
                    withRow.px == without.px && withRow.px == px && AgentPixel.isCrisp(px) && withRow.bunk && withRow.shelf, "\(withRow.px) \(without.px)")
        }
        r.check("the scout is as big as fits: bigger in a taller room", AgentNookRoomRows.scoutPixel(style: .roomy, size: CGSize(width: 102, height: 100), needsRow: true) > AgentNookRoomRows.scoutPixel(style: .roomy, size: CGSize(width: 88, height: 75), needsRow: true))
        // A counter is never clipped: blocks go first, then the number stays, then both.
        let model = AgentNookRoomModel(AgentNookSamples.sessions(1)[0], needsYou: false)
        let text = model.progressText ?? "2/5"
        let number = RetroPixelLayout.width(text, pixel: 1)
        let full = AgentNookShelf.blocksThatFit(total: 5, text: text, cap: 5, block: 5, pixel: 1, available: 200)
        let narrow = AgentNookShelf.blocksThatFit(total: 5, text: text, cap: 5, block: 5, pixel: 1, available: number + 9)
        let numberOnly = AgentNookShelf.blocksThatFit(total: 5, text: text, cap: 5, block: 5, pixel: 1, available: number + 1)
        let none = AgentNookShelf.blocksThatFit(total: 5, text: text, cap: 5, block: 5, pixel: 1, available: number - 1)
        r.check("a counter with room shows every block and the number", full == 5, "\(String(describing: full))")
        r.check("a counter with little room drops blocks before the number", (narrow ?? 99) < 5 && (narrow ?? 0) >= 0, "\(String(describing: narrow))")
        r.check("a counter with room for the number only keeps the number", numberOnly == 0, "\(String(describing: numberOnly))")
        r.check("a counter that cannot show its number whole shows nothing (never half of it)", none == nil, "\(String(describing: none))")
        // A room is drawn whole or not at all: the rooms and the door always fit the glass.
        for cells in 3...16 { for count in [2, 3, 4, 6, 9] {
            let p = AgentTVLayout.plan(panelWidth: AgentTVLayout.width(cells: cells), count: count)
            let door = p.more > 0 ? AgentNookLayout.gap + AgentNookLayout.doorWidth : 0
            let used = CGFloat(p.shown) * p.roomWidth + CGFloat(max(0, p.shown - 1)) * AgentNookLayout.gap + door
            r.check("\(cells) cells, \(count) agents: \(p.shown) whole rooms of at least \(Int(AgentNookLayout.compactMin)) pt and the door fit (\(Int(used)) of \(Int(p.rooms.width)))",
                    p.shown == 1 || (used <= p.rooms.width + 0.5 && p.roomWidth >= AgentNookLayout.compactMin - 0.5), "\(p)")
        } }
    }

    // MARK: The empty house and the clock

    private static func empty(_ r: inout Report) {
        r.check("no agents, no rooms", AgentNookPanelView.models([], pending: []).isEmpty)
        let plan = AgentNookLayout.plan(panelWidth: AgentNookLayout.width(cells: 6), count: 0)
        r.check("the empty house shows no rooms and no door", plan.shown == 0 && plan.more == 0)
        r.check("the empty house says its line", AgentNookEmptyRoom.line == "Nobody home yet. Agents move in by themselves.")
    }

    private static func motion(_ r: inout Report) {
        r.check("no clock while the notch is closed", !AgentNookPanelView.isRunning(appeared: true, open: false, fixed: false, scripted: false))
        r.check("no clock while the panel is not on screen", !AgentNookPanelView.isRunning(appeared: false, open: true, fixed: false, scripted: false))
        r.check("the clock runs while it is on screen and the notch is open", AgentNookPanelView.isRunning(appeared: true, open: true, fixed: false, scripted: false))
        r.check("a picture or a test never runs a clock", !AgentNookPanelView.isRunning(appeared: true, open: true, fixed: false, scripted: true)
                && !AgentNookPanelView.isRunning(appeared: true, open: true, fixed: true, scripted: false))
        r.check("the Mac's sampler is held only on screen with the notch open", AgentTVLoadBars.wantsSampler(appeared: true, open: true, gallery: false)
                && !AgentTVLoadBars.wantsSampler(appeared: true, open: false, gallery: false) && !AgentTVLoadBars.wantsSampler(appeared: false, open: true, gallery: false))
        let still = AgentNookClock.still
        r.check("a still picture has one frame and no blink", still.frame() == 0 && !still.blinking())
        let reduced = AgentNookClock(t: 1.3, motion: false)
        r.check("Reduce Motion: one frame, no blink, but the lamp can fade", reduced.frame() == 0 && AgentNookClock(t: 9.9, motion: false).frame() == 0 && !reduced.blinking(phase: 2.9)
                && reduced.pulse(period: 4) != AgentNookClock(t: 3.1, motion: false).pulse(period: 4))
        r.check("Reduce Motion off: the second frame comes and goes", AgentNookClock(t: 0.1, motion: true).frame() == 0 && AgentNookClock(t: 0.6, motion: true).frame() == 1
                && AgentNookClock(t: 1.1, motion: true).frame() == 0)
        r.check("Reduce Motion off: it blinks now and then", AgentNookClock(t: 4.3, motion: true).blinking() && !AgentNookClock(t: 1, motion: true).blinking())
    }

    // MARK: The pixels

    // MARK: Faces and the closed notch's wings (the owner, 2026-11-16)

    private static func faces(_ r: inout Report) {
        let palette = PixelPalette.world(.claude)
        var frames: [AgentFaceMood: [PixelSprite]] = [:]
        var bursts: [AgentFaceMood: [PixelSprite]] = [:]
        for mood in AgentFaceMood.allCases {
            frames[mood] = (0..<60).map { AgentFaceArt.frame(mood, tick: $0) }
            bursts[mood] = (0..<60).map { AgentFaceArt.frame(mood, tick: $0, burst: true) }
        }
        let every = frames.values.flatMap { $0 } + bursts.values.flatMap { $0 }
        r.check("every face frame is 12 x 12 cells, rectangular, and uses only palette letters",
                every.allSatisfy { $0.width == 12 && $0.height == 12 && $0.isRectangular && $0.letters.isSubset(of: palette.letters) && $0.letters.isSubset(of: PixelPalette.world(.codex).letters) })
        r.check("a face is an 18 pt square, crisp at 2x, and fits the wing (22 pt)",
                AgentFaceArt.side == 18 && AgentPixel.isCrisp(AgentFaceArt.px) && AgentFaceArt.side <= LEDStyle.wingHeight)
        let moods = AgentFaceMood.allCases.map { AgentFaceArt.frame($0, tick: 1).rows.joined() }
        r.check("the five moods are five different faces", Set(moods).count == 5)
        r.check("a face wears its agent's colour: the body is the kind's tint and the two kinds differ",
                palette.color("b") != PixelPalette.world(.codex).color("b"))
        // Working: the mouth stays still, the eyes blink and glance.
        let working = frames[.working]!
        let mouths = Set((working + bursts[.working]!).map { $0.rows[8...9].joined() })
        r.check("a working face never moves its mouth", mouths.count == 1, "\(mouths.count) shapes")
        r.check("the mouth moves only for a couple of seconds when something happens", AgentFaceArt.burstSeconds >= 1.5 && AgentFaceArt.burstSeconds <= 3.5)
        for mood in [AgentFaceMood.asking, .finished, .stopped, .idle] {
            r.check("  \(String(describing: mood)): a still picture after the burst", Set(frames[mood]!.map { $0.rows.joined() }).count == 1)
        }
        func eyesOpen(_ s: PixelSprite) -> Bool { s.rows[3...6].joined().contains("w") }
        let blinks = working.indices.filter { !eyesOpen(working[$0]) }
        r.check("  it blinks now and then (not on every step, not never)", !blinks.isEmpty && blinks.count <= 5, "\(blinks)")
        let sparks = Set([0, 8, 16, 24].compactMap { tick in working[tick].rows[4].firstIndex(of: "w").map { working[tick].rows[4].distance(from: working[tick].rows[4].startIndex, to: $0) } })
        r.check("  and its eyes glance left, ahead and right", sparks.count == 3, "\(sparks)")
        // Asking: wide eyes, the amber ring (the outline turns amber or orange), a calling mouth.
        let asking = bursts[.asking]!
        r.check("an asking face has wide eyes and an amber ring instead of the dark outline",
                asking[1].letters.contains("A") && asking[3].letters.contains("O") && !asking[1].letters.contains("o") && asking[1].rows[3].contains("w")
                    && frames[.asking]![5].letters.contains("A") && !frames[.asking]![5].letters.contains("o"))
        r.check("  during the burst its mouth calls (an o and an open one alternate), then it waits with a still o",
                asking[1].rows[8...9].joined() != asking[3].rows[8...9].joined() && frames[.asking]![3].rows[8...9].joined() == frames[.asking]![1].rows[8...9].joined())
        // Finished, stopped, idle.
        let finished = bursts[.finished]!
        r.check("a finished face smiles with happy eyes (a short laugh during the burst)", finished[2].rows[9] != finished[0].rows[9] && !eyesOpen(finished[2]) && !eyesOpen(frames[.finished]![0]))
        let stopped = bursts[.stopped]!
        r.check("a stopped face has dizzy eyes that swap between an X and a plus during the burst", stopped[0].rows[4...6] != stopped[2].rows[4...6] && !eyesOpen(stopped[0]))
        r.check("an idle face sleeps: eyes shut, and no step changes it", Set(frames[.idle]!.map { $0.rows.joined() }).count == 1 && !eyesOpen(frames[.idle]![0]))
        let ids = (1...8).map { "agent-\($0)" }
        let given = AgentFaceArt.variants(for: ids)
        r.check("every agent its own face: eight agents wear eight different faces", Set(given.values).count == 8, "\(given)")
        r.check("  and an agent keeps its face whatever the order", AgentFaceArt.variants(for: ids.reversed()) == given && AgentFaceArt.variants(for: Array(ids.prefix(3)))["agent-1"] != nil)
        let picks = (0..<8).map { AgentFaceArt.variant(style: $0 % AgentFaceArt.styleCount, colour: $0, skin: $0) }
        r.check("  eight faces with different features are eight different pictures", Set(picks.map { AgentFaceArt.frame(.working, tick: 1, variant: $0).rows.joined() + "\(AgentFaceArt.shade($0))" }).count == 8
                && (0..<AgentFaceArt.variantCount).allSatisfy { AgentFaceArt.frame(.asking, tick: 3, burst: true, variant: $0).isRectangular })
        r.check("  every agent's face differs from the others' in all three features while there are few agents (wear, colour, skin)",
                given.values.allSatisfy { a in given.values.filter { $0 != a }.allSatisfy { AgentFaceArt.difference(a, $0) >= 2 } }, "\(given)")
        r.check("  the head colours are palette letters every face palette has", AgentFaceArt.colours.allSatisfy { PixelPalette.face(.claude, variant: 0).color($0) != nil })
        r.check("the mood follows the nook's look (the one rule for \"needs you\")",
                AgentFaceMood(.needsYou) == .asking && AgentFaceMood(.working) == .working && AgentFaceMood(.finished) == .finished
                    && AgentFaceMood(.stopped) == .stopped && AgentFaceMood(.idle) == .idle)
        // Time: a step is 0.2 s (0.4 s with Reduce Motion), and the phase moves faces out of step.
        r.check("a step lasts 0.2 s, 0.4 s when Reduce Motion is on",
                AgentFaceArt.tick(at: 0.65) == 3 && AgentFaceArt.tick(at: 1.0) == 5 && AgentFaceArt.tick(at: 0.9, calm: true) == 2 && AgentFaceArt.tick(at: 0.5, phase: 0.53) == 5)
        // The view: 18 pt, the kind's colour in the middle, transparent corners.
        let host = NSHostingView(rootView: AgentFaceIcon(agent: .claude, mood: .working, frozenAt: 0).fixedSize())
        r.check("the face icon is 18 x 18 pt", abs(host.fittingSize.width - 18) < 0.5 && abs(host.fittingSize.height - 18) < 0.5, "\(host.fittingSize)")
        func centre(_ agent: AgentKind) -> (r: Double, g: Double, b: Double, cornerAlpha: Double)? {
            let renderer = ImageRenderer(content: AgentFaceIcon(agent: agent, mood: .finished, frozenAt: 0.4).background(Color.clear))
            renderer.scale = 2
            guard let cg = renderer.cgImage, cg.width == 36, cg.height == 36 else { return nil }
            var data = [UInt8](repeating: 0, count: 36 * 36 * 4)
            guard let ctx = CGContext(data: &data, width: 36, height: 36, bitsPerComponent: 8, bytesPerRow: 36 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 36, height: 36))
            func px(_ x: Int, _ y: Int) -> (Double, Double, Double, Double) {
                let i = (y * 36 + x) * 4
                let a = Double(data[i + 3]) / 255
                return a > 0 ? (Double(data[i]) / 255 / a, Double(data[i + 1]) / 255 / a, Double(data[i + 2]) / 255 / a, a) : (0, 0, 0, 0)
            }
            let c = px(18, 22)   // the middle of the face between the eyes and the mouth (row 7): the body colour
            return (c.0, c.1, c.2, px(0, 0).3)
        }
        if let claude = centre(.claude), let codex = centre(.codex) {
            let tint = Retro.rgb(AgentKind.claude.tint)
            r.check("drawn: the claude face is its sand-orange body on a transparent square (corners clear)",
                    abs(claude.r - Double(tint.r)) < 0.08 && abs(claude.g - Double(tint.g)) < 0.08 && claude.cornerAlpha == 0, "\(claude)")
            r.check("  and the codex face is green", codex.g > codex.r + 0.12, "\(codex)")
        } else {
            r.check("the face icon renders", false)
        }
        // The summary and the two wings.
        let store = AgentsStore(directory: AppPaths.folder("agentface-test"))
        var list = AgentSession.synthetic(6)
        list[2].lastMessage = "I changed the footer links, ran the linter and everything passes, so it is your move now to look at the page."
        store.loadSessions(list)
        let summary = AgentWingSummary.make(sessions: store.sessions, pending: store.pending)
        r.check("the left wing has four faces and \"+2\" (six sessions, every one of them counts): the asking one among them, in the fixed order",
                summary.faces.count == 4 && summary.moreFaces == 2 && summary.faces.contains { $0.mood == .asking && $0.agent == .codex }
                && summary.faces.map(\.id) == AgentTileMetrics.ordered(store.sessions).map(\.id).filter { id in summary.faces.contains { $0.id == id } },
                "\(summary.faces) +\(summary.moreFaces)")
        let left = NSHostingView(rootView: AgentWingLeft(store: store, frozenAt: 0).fixedSize())
        r.check("  the left wing is as high as a face and well inside the 120 pt a wing can hold", left.fittingSize.height <= 19 && left.fittingSize.width <= 100, "\(left.fittingSize)")
        r.check("the right wing says what the asking agent asks (no timer anywhere)", { if case .message("Which region?", asks: true) = summary.right { return true } else { return false } }(), "\(summary.right)")
        let waiting = AgentsStore(directory: AppPaths.folder("agentface-test-waiting"))
        waiting.loadSessions([list[3], list[2]])
        let turn = AgentWingSummary.make(sessions: waiting.sessions, pending: [])
        r.check("a working agent without a to-do list shows no timer: the message of the agent that waits takes its place",
                { if case .message(let text, asks: false) = turn.right { return text.hasPrefix("I changed the footer links") } else { return false } }(), "\(turn.right)")
        AgentWingRight.lastRevealed = ""   // a fresh wing: nothing said yet
        let right = NSHostingView(rootView: AgentWingRight(store: waiting).fixedSize())
        // Said once, a wing built again (the notch opened and closed) does not say it again (the owner, 2026-11-18).
        AgentWingRight.lastRevealed = AgentWingRight.key(turn.right)
        let again = NSHostingView(rootView: AgentWingRight(store: waiting).fixedSize())
        r.check("  a message already shown does not come back when the wing is built again (open and close the notch)", again.fittingSize.width < 1, "\(again.fittingSize)")
        AgentWingRight.lastRevealed = ""
        r.check("  the message is two lines at most and fits the wing (under \(Int(AgentWingRight.messageWidth)) pt wide, under 30 pt high)",
                right.fittingSize.width <= AgentWingRight.messageWidth + 0.5 && right.fittingSize.height <= 30 && right.fittingSize.height >= 18, "\(right.fittingSize)")
        // The owner, 2026-11-18: a long sentence shows whole on its two lines, the wing widens for it; a short one stays narrow.
        let long = "The new release is in review at the store, and it goes live by itself when it is approved, so nothing waits on you now."
        let longW = AgentWingRight.textWidth(long)
        r.check("  a long sentence (\(long.count) letters) fits whole on two lines: the box widens to \(Int(longW)) pt",
                longW > AgentWingRight.minTextWidth && longW <= AgentWingRight.maxTextWidth && AgentWingRight.lines(long, width: longW) <= 2, "\(longW)")
        let longView = NSHostingView(rootView: AgentWingRight.messageProbe(long).fixedSize())
        r.check("    and drawn by SwiftUI it is still two lines (not three, nothing cut)", longView.fittingSize.height <= 30 && longView.fittingSize.height >= 18, "\(longView.fittingSize)")
        let snug = AgentWingRight.usedWidth(long, width: longW)
        r.check("    no empty space: the box is the longer line itself (\(Int(snug)) of \(Int(longW)) pt)", longW - snug <= 2.5, "\(snug) / \(longW)")
        r.check("  a short one (\"Done.\") stays one narrow line", AgentWingRight.textWidth("Done.") < 40 && AgentWingRight.lines("Done.", width: AgentWingRight.textWidth("Done.")) == 1)
        let quiet = AgentsStore(directory: AppPaths.folder("agentface-test-quiet"))
        quiet.loadSessions([list[3]])
        r.check("  with nobody waiting and no to-do list the right wing is empty (the timer is gone)", AgentWingSummary.make(sessions: quiet.sessions, pending: []).right == .none)
    }

    /// Every sprite table is rectangular and uses only letters its palette has; a pixel is a multiple of half a point.
    private static func pixels(_ r: inout Report) {
        let palettes = AgentKind.allCases.map { PixelPalette.world($0) }
        for (name, sprite) in AgentPixelSprites.all {
            r.check("sprite \(name) is rectangular (\(sprite.width) x \(sprite.height))", sprite.isRectangular && sprite.width > 0 && sprite.height > 0,
                    "rows \(Set(sprite.rows.map(\.count)))")
            let missing = palettes.flatMap { p in sprite.letters.filter { p.color($0) == nil } }
            r.check("sprite \(name) uses only its palette", missing.isEmpty, "\(Set(missing))")
        }
        let main = [AgentPixelSprites.scout, AgentPixelSprites.scoutBlink, AgentPixelSprites.scoutHappy, AgentPixelSprites.scoutDizzy, AgentPixelSprites.scoutSeated]
        r.check("the main scout is 16 x 16 (up to 24 x 24)", main.allSatisfy { $0.width == 16 && $0.height >= 14 && $0.height <= 24 } && AgentPixelSprites.scoutAsleep.width <= 24,
                "\(main.map { "\($0.width)x\($0.height)" })")
        r.check("a helper is 8 x 8", AgentPixelSprites.miniAwake.width == 8 && AgentPixelSprites.miniAwake.height == 8 && AgentPixelSprites.miniAsleep.width == 8 && AgentPixelSprites.miniAsleep.height == 8)
        r.check("a prop is 8 x 8", AgentNookProp.allCases.allSatisfy { AgentPixelSprites.prop($0).width == 8 && AgentPixelSprites.prop($0).height == 8 })
        for kind in AgentKind.allCases {
            let p = PixelPalette.world(kind)
            r.check("\(kind.title): the outline is darker than the body, the highlight lighter", Retro.luminance(p.color("o")!) < Retro.luminance(p.color("b")!) && Retro.luminance(p.color("h")!) > Retro.luminance(p.color("b")!)
                    && Retro.luminance(p.color("s")!) < Retro.luminance(p.color("b")!))
        }
        // Each state has its own picture, each differs from the others, and a second frame differs from the first only where it should.
        let pictures = AgentNookLook.allCases.map { AgentPixelWorld.picture(look: $0, prop: .pencil, frame: 0, blink: false) }
        let sheets = pictures.map { $0.placements.map { "\($0.sprite.rows.joined()) \($0.x),\($0.y)" }.joined(separator: "|") }
        r.check("the five states are five different pictures", Set(sheets).count == 5)
        for look in AgentNookLook.allCases {
            let a = AgentPixelWorld.picture(look: look, prop: .pencil, frame: 0, blink: false), b = AgentPixelWorld.picture(look: look, prop: .pencil, frame: 1, blink: false)
            let differs = zip(a.placements, b.placements).contains { $0.x != $1.x || $0.y != $1.y || $0.sprite != $1.sprite }
            r.check("\(look.title): a second frame exists (it only shows while Reduce Motion is off)", differs)
        }
        let withProp = AgentPixelWorld.picture(look: .working, prop: .globe, frame: 0, blink: false).placements.contains { $0.sprite == AgentPixelSprites.globe }
        let thinking = AgentPixelWorld.picture(look: .working, prop: nil, frame: 0, blink: false).placements.contains { $0.sprite == AgentPixelSprites.textLines }
        r.check("the step's prop is on the computer's screen, text lines while it only thinks", withProp && thinking)
        for (cell, ok) in [(0.5, true), (1.0, true), (1.5, true), (2.0, true), (3.0, true), (1.25, false), (2.2, false)] {
            r.check("a pixel of \(cell) pt \(ok ? "lands on whole device pixels at 2x" : "does not")", AgentPixel.isCrisp(CGFloat(cell)) == ok)
        }
        var allCrisp = true
        for w in stride(from: 20.0, through: 300.0, by: 7.3) { for h in stride(from: 20.0, through: 140.0, by: 5.9) {
            for pic in pictures where !AgentPixel.isCrisp(AgentPixel.size(grid: (pic.w, pic.h), in: CGSize(width: w, height: h))) { allCrisp = false }
        } }
        r.check("the pixel size the rooms choose is always a multiple of half a point", allCrisp)
        r.check("the room's wall cell is whole device pixels", AgentPixel.isCrisp(AgentNookWall.cell))
    }

    // MARK: The big figures wear their face and move it like the wing's

    /// The pixels of `view` drawn offscreen at scale 1 on black (RGBA bytes), or nil.
    private static func rendered<V: View>(_ view: V, size: CGSize, scale: CGFloat = 1) -> [UInt8]? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).background(Color.black))
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return data
    }

    /// How many pixels look pink (the magenta of a head's hair or bow; the cheeks, the skins and the reds do not), -1 when nothing rendered.
    private static func pinkPixels(_ data: [UInt8]?) -> Int {
        guard let data else { return -1 }
        var n = 0
        for i in stride(from: 0, to: data.count, by: 4) {
            let red = Int(data[i]), green = Int(data[i + 1]), blue = Int(data[i + 2])
            if red > 150 && green < 110 && blue > 80 && blue < 190 && red - green > 100 { n += 1 }
        }
        return n
    }

    private static func bigFigures(_ r: inout Report) {
        let palettes = AgentKind.allCases.map { PixelPalette.world($0) }
        let looks = AgentNookLook.allCases
        let headX = AgentPixelSprites.headColumn
        func figure(_ look: AgentNookLook, _ v: Int, tick: Int? = nil, burst: Bool = false, shut: Bool = false) -> PixelSprite {
            AgentPixelSprites.figure(look, tick: tick, burst: burst, eyesShut: shut, variant: v)
        }
        func count(_ s: PixelSprite, _ letter: Character) -> Int { s.grid.joined().filter { $0 == letter }.count }
        func headRegion(_ s: PixelSprite) -> PixelSprite { PixelSprite(grid: (0..<12).map { y in (headX..<(headX + 12)).map { s[$0, y] } }) }
        func silhouette(_ s: PixelSprite) -> [[Bool]] { s.grid.map { $0.map { $0 != "." } } }
        func mini(_ look: AgentNookLook, _ v: Int, tick: Int, burst: Bool) -> PixelSprite { AgentFaceArt.frame(AgentFaceMood(look), tick: tick, burst: burst, variant: v) }
        let steps: [(tick: Int?, burst: Bool, shut: Bool)] = [(nil, false, false), (nil, false, true), (0, false, false), (1, true, false), (8, false, false), (17, false, false), (26, true, false)]

        // Every pose of every one of the 384 faces, at rest, blinking and on several steps of the beat.
        var shapes = true, palette = true, antenna = true, headIsMini = true, bareShape = true, restIsMini = true
        var worst = ""
        for look in looks {
            let seated = look == .working || look == .idle
            for v in 0..<AgentFaceArt.variantCount {
                for step in steps {
                    let s = figure(look, v, tick: step.tick, burst: step.burst, shut: step.shut)
                    if !(s.isRectangular && s.width == 16 && s.height == (seated ? 14 : 16)) { shapes = false; worst = "shape \(look) \(v)" }
                    if !palettes.allSatisfy({ p in s.letters.allSatisfy { p.color($0) != nil } }) { palette = false; worst = "palette \(look) \(v)" }
                    // Nothing above the head's top row and nothing beside the head over its 12 rows: row 0 is the head's top.
                    let outside = (0..<12).contains { y in (0..<16).contains { x in (x < headX || x >= headX + 12) && s[x, y] != "." } }
                    if outside || !s.rows[0].contains(where: { $0 != "." }) { antenna = false; worst = "antenna \(look) \(v) \(step)" }
                    // A bare head has the mini face's outline: the silhouette of the head's 12 x 12 cells is the bare face's.
                    if AgentFaceArt.style(v) == 0 && silhouette(headRegion(s)) != silhouette(AgentFaceArt.base) { bareShape = false; worst = "outline \(look) \(v)" }
                    // With a step the head IS the wing's frame of that step (the same eyes, mouth, outline and headwear).
                    if let tick = step.tick, headRegion(s) != mini(look, v, tick: tick, burst: step.burst) { headIsMini = false; worst = "head \(look) \(v) \(step)" }
                }
                // At rest: a working head looks to the right, at its computer; the others are their mood's still face.
                if headRegion(figure(look, v)) != mini(look, v, tick: look == .working ? AgentFaceArt.restTick : 0, burst: false) { restIsMini = false; worst = "rest \(look) \(v)" }
            }
        }
        r.check("every big figure of every pose and face is rectangular (16 wide, 14 seated or asleep and 16 standing), at rest and on every step", shapes, worst)
        r.check("  and uses only palette letters", palette, worst)
        r.check("  and has NO antenna: nothing stands above the head's top row or beside the head's 12 rows, and the top row is the head's", antenna, worst)
        r.check("  and a bare head has the mini face's outline (the same square with cut corners) in every pose and on every step", bareShape, worst)
        r.check("  and on every step its head IS the mini face's frame of that step (eyes, mouth, outline, headwear), for all 384 faces", headIsMini, worst)
        r.check("  and at rest it is the mini face's still frame (a working head looks to the right)", restIsMini, worst)
        r.check("the bare head's top row is 8 cells wide like the mini face's and sits in the figure's columns 4 to 11", AgentFaceArt.base.rows[0].filter { $0 != "." }.count == 8
                && figure(.finished, 0).rows[0] == "....oooooooo....", "\(figure(.finished, 0).rows[0])")

        // The faces move like the wing's: the same steps, eyes glance and blink, the mouth per mood, the burst.
        func eyes(_ s: PixelSprite) -> [String] { Array(headRegion(s).rows[3...6]) }
        func faceMouth(_ face: PixelSprite) -> [String] { Array(face.rows[8...9]) }
        func mouth(_ s: PixelSprite) -> [String] { faceMouth(headRegion(s)) }
        let working = (0..<60).map { figure(.working, 0, tick: $0) }
        r.check("a working big figure's eyes differ between two ticks (a glance to the right at 8, ahead at 16, to the left at 24)",
                Set([1, 8, 24].map { eyes(working[$0]).joined() }).count == 3 && eyes(working[1]) == eyes(working[16]) && eyes(working[8]) != eyes(working[1]))
        let shut = working.indices.filter { !eyes(working[$0]).joined().contains("w") }
        r.check("  it blinks now and then (steps 0, 17, 34, 51), not on every step", shut == [0, 17, 34, 51], "\(shut)")
        r.check("  and a working one never moves its mouth, as in the wing", Set(working.map { mouth($0).joined() }).count == 1
                && mouth(working[0]) == faceMouth(mini(.working, 0, tick: 0, burst: false)))
        for look in [AgentNookLook.needsYou, .finished, .stopped, .idle] {
            let still = (0..<60).map { figure(look, 0, tick: $0) }
            r.check("  \(look.title): still after the burst, whatever the step", Set(still.map { $0.rows.joined() }).count == 1)
        }
        func burst(_ look: AgentNookLook) -> [PixelSprite] { (0..<8).map { figure(look, 0, tick: $0, burst: true) } }
        r.check("  an asking one calls during the burst (an o and an open mouth alternate, the ring swaps amber and orange), like the wing's, then waits with the o",
                mouth(burst(.needsYou)[0]) != mouth(burst(.needsYou)[2]) && burst(.needsYou)[0].letters.contains("A") && burst(.needsYou)[2].letters.contains("O")
                && mouth(figure(.needsYou, 0, tick: 5)) == mouth(burst(.needsYou)[0]) && mouth(burst(.needsYou)[2]) == faceMouth(mini(.needsYou, 0, tick: 2, burst: true)))
        r.check("  a finished one laughs during the burst (a smile and an open mouth alternate), like the wing's, then smiles",
                mouth(burst(.finished)[0]) != mouth(burst(.finished)[2]) && mouth(burst(.finished)[2]) == faceMouth(mini(.finished, 0, tick: 2, burst: true))
                && mouth(figure(.finished, 0, tick: 5)) == mouth(burst(.finished)[2]))
        r.check("  a stopped one's dizzy crosses swap during the burst (an X and a plus), like the wing's, then stay crosses",
                eyes(burst(.stopped)[0]) != eyes(burst(.stopped)[2]) && eyes(burst(.stopped)[0]) == eyes(figure(.stopped, 0, tick: 0))
                && mouth(burst(.stopped)[0]) == faceMouth(mini(.stopped, 0, tick: 0, burst: true)))
        r.check("  a sleeping one's eyes stay shut on every step", (0..<60).allSatisfy { !eyes(figure(.idle, 0, tick: $0)).joined().contains("w") })
        // The clock: the wing's beat, slower under Reduce Motion, each agent on its own start, nothing in a still picture.
        r.check("a still clock gives no step (the picture rests)", AgentNookClock.still.faceStep(burst: true) == nil)
        r.check("the clock's step is the wing's: 0.2 s a step, 0.4 s with Reduce Motion, and the burst flag goes with it",
                AgentNookClock(t: 10.05, motion: true).faceStep(burst: false) == AgentFaceStep(tick: AgentFaceArt.tick(at: 10.05), burst: false)
                && AgentNookClock(t: 10.05, motion: false).faceStep(burst: true) == AgentFaceStep(tick: AgentFaceArt.tick(at: 10.05, calm: true), burst: true)
                && AgentFaceArt.tick(at: 10.05, calm: true) < AgentFaceArt.tick(at: 10.05))
        let own = AgentFaceArt.phase(for: "agent-a")
        r.check("  and a shifted clock gives each agent its own start, the same as its wing face (phase \(own))",
                AgentNookClock(t: 50, motion: true).shifted(own).faceStep(burst: false)?.tick == AgentFaceArt.tick(at: 50, phase: own)
                && AgentNookClock(t: 0.15, motion: true).shifted(0).faceStep(burst: false)?.tick != AgentNookClock(t: 0.15, motion: true).shifted(0.1).faceStep(burst: false)?.tick)
        // The pictures: the figure of the agent's face on that step, and only the head moves from one step to the next.
        for look in looks {
            let step0 = AgentFaceStep(tick: 1, burst: true), step1 = AgentFaceStep(tick: 8, burst: false)
            let a = AgentPixelWorld.picture(look: look, prop: .pencil, frame: 0, blink: false, variant: 40, face: step0)
            let b = AgentPixelWorld.picture(look: look, prop: .pencil, frame: 0, blink: false, variant: 40, face: step1)
            let wants = [figure(look, 40, tick: 1, burst: true), figure(look, 40, tick: 8)]
            let changed = zip(a.placements, b.placements).filter { $0.sprite != $1.sprite || $0.x != $1.x || $0.y != $1.y }.count
            r.check("\(look.title): the picture holds the figure of that step, and from one step to the next nothing but the head changes",
                    a.placements.contains { $0.sprite == wants[0] } && b.placements.contains { $0.sprite == wants[1] } && changed <= 1 && a.placements.count == b.placements.count,
                    "changed \(changed)")
        }
        let moving = AgentNookCritter.picture(look: .working, prop: .pencil, clock: AgentNookClock(t: 1.01, motion: true), variant: 40)
        let later = AgentNookCritter.picture(look: .working, prop: .pencil, clock: AgentNookClock(t: 1.61, motion: true), variant: 40)
        let resting = AgentNookCritter.picture(look: .working, prop: .pencil, clock: .still, variant: 40)
        r.check("the Critter's picture moves its face with the clock (glances 1.6 s later) and rests with a still clock",
                moving.placements.first?.sprite != later.placements.first?.sprite && resting.placements.first?.sprite == figure(.working, 40), "")

        // Headwear: each style adds its own cells in its own colour, with the small face's accents; a bare head adds nothing.
        var accents = true, colourCells = true, bareAddsNothing = true, differs = true
        let expected: [Int: (cells: Int, accent: Character, accentCells: Int)] = [1: (24, "w", 0), 2: (23, "w", 1), 3: (18, "w", 10), 4: (12, "d", 8), 5: (8, "w", 1)]
        for look in looks {
            for colour in 0..<AgentFaceArt.colourCount {
                let letter = AgentFaceArt.colours[colour]
                let bare = figure(look, AgentFaceArt.variant(style: 0, colour: colour, skin: 3))
                if bare != figure(look, 0) { bareAddsNothing = false }
                for style in 1..<AgentFaceArt.styleCount {
                    let s = figure(look, AgentFaceArt.variant(style: style, colour: colour, skin: 3))
                    let want = expected[style]!
                    if count(s, letter) - count(bare, letter) != want.cells { colourCells = false }
                    if count(s, want.accent) - count(bare, want.accent) != want.accentCells { accents = false }
                    if s == bare { differs = false }
                }
            }
        }
        r.check("a bare head adds nothing: the figure is the same in every colour and skin", bareAddsNothing)
        r.check("every style puts its cells in its colour on the big head (hair 24, cap 23, beanie 18, headphones 12 in two cups, bow 8), in every pose", colourCells)
        r.check("  with the small face's accents: the cap's white button, the beanie's white band, the headphones' dark band, the bow's white knot", accents)
        r.check("  and every style in every colour is its own picture", differs
                && Set((0..<AgentFaceArt.colourCount).map { figure(.working, AgentFaceArt.variant(style: 1, colour: $0, skin: 0)).rows.joined() }).count == AgentFaceArt.colourCount
                && Set((0..<AgentFaceArt.styleCount).map { figure(.finished, AgentFaceArt.variant(style: $0, colour: 5, skin: 0)).rows.joined() }).count == AgentFaceArt.styleCount)

        // The pictures: the figure of the agent's face is in each one, and nothing drawn after it covers its headwear (the bubble, the arm, the
        // badge, the desk and the computer, the beanbag), at both frames.
        var inPicture = true, uncovered = true, sizesKept = true
        for look in looks {
            for v in (0..<AgentFaceArt.variantCount).filter({ AgentFaceArt.skin($0) == 0 }) {
                for frame in [0, 1] {
                    let pic = AgentPixelWorld.picture(look: look, prop: .pencil, frame: frame, blink: false, variant: v)
                    let plain = AgentPixelWorld.picture(look: look, prop: .pencil, frame: frame, blink: false)
                    if pic.w != plain.w || pic.h != plain.h || pic.w > AgentNookRoomRows.scene.w || pic.h > AgentNookRoomRows.scene.h { sizesKept = false }
                    let want = figure(look, v), bare = figure(look, 0)
                    guard let at = pic.placements.firstIndex(where: { $0.sprite == want }) else { inPicture = false; continue }
                    let place = pic.placements[at]
                    for y in 0..<want.height { for x in 0..<want.width where want[x, y] != bare[x, y] {
                        for later in pic.placements[(at + 1)...] where later.sprite[place.x + x - later.x, place.y + y - later.y] != "." { uncovered = false }
                    } }
                }
            }
        }
        r.check("every picture of every pose holds the agent's own figure, at both frames, in every headwear and colour", inPicture)
        r.check("  and nothing drawn after it (bubble, arm, badge, desk, computer, beanbag) covers its headwear", uncovered)
        r.check("  and the pictures keep their sizes (the same as for a bare head, inside the 30 x 24 scene)", sizesKept)
        // Helpers wear the same square top (no tuft).
        r.check("a helper has a square top, no tuft: the first row is at least 4 cells wide and no wider than the second",
                [AgentPixelSprites.miniAwake, AgentPixelSprites.miniAsleep].allSatisfy { s in
                    let top = s.rows[0].filter { $0 != "." }.count, second = s.rows[1].filter { $0 != "." }.count
                    return top >= 4 && top <= second }, "\(AgentPixelSprites.miniAwake.rows[0])")

        // Drawn: the Critter (the TV's figure), a TV room and the den's station all show the pink hair (or bow) of a pink-haired agent, none for a
        // bare head, and the moving Critter draws differently on two steps.
        let hair = AgentFaceArt.variant(style: 1, colour: 7, skin: 2), bow = AgentFaceArt.variant(style: 5, colour: 7, skin: 2), bare = AgentFaceArt.variant(style: 0, colour: 7, skin: 2)
        var drawn = true, detail = ""
        for look in looks {
            let session = AgentNookSamples.one(look, prop: .globe, kind: .claude, project: "site", helpers: 0, todos: 0, done: 0)
            let model = AgentNookRoomModel(session, needsYou: look == .needsYou)
            let station = AgentDenStation(session, needsYou: look == .needsYou)
            func views(_ v: Int) -> [Int] {
                [pinkPixels(rendered(AgentNookCritter(kind: .claude, variant: v, pose: look.pose, prop: .globe, pixel: 3), size: CGSize(width: 140, height: 105))),
                 pinkPixels(rendered(AgentNookRoom(model: model, style: .roomy, variant: v), size: CGSize(width: 140, height: 105))),
                 pinkPixels(rendered(AgentNookRoom(model: model, style: .compact, variant: v), size: CGSize(width: 78, height: 105))),
                 pinkPixels(rendered(AgentDenStationView(station: station, spot: AgentDenSpot(index: 0, rect: .zero, px: 3, row: 0), clock: .still, selected: false, glow: false, variant: v) {},
                                     size: CGSize(width: 44 * 3, height: 36 * 3 + 22)))]
            }
            let plain = views(bare), withHair = views(hair), withBow = views(bow)
            for (i, name) in ["the Critter", "a roomy TV room", "a compact TV room", "the den's station"].enumerated() {
                if plain[i] < 0 || withHair[i] - plain[i] < 20 || withBow[i] - plain[i] < 4 { drawn = false; detail += " \(look) \(name): bare \(plain[i]) hair \(withHair[i]) bow \(withBow[i]);" }
            }
        }
        r.check("drawn: the figure in the Critter, in both TV rooms and in the den's station shows its agent's pink hair or bow, in every pose, and a bare head none", drawn, detail)
        let size = CGSize(width: 140, height: 105)
        let first = rendered(AgentNookCritter(kind: .claude, variant: hair, pose: .typing, prop: .globe, clock: AgentNookClock(t: 1.01, motion: true), pixel: 3), size: size)
        let second = rendered(AgentNookCritter(kind: .claude, variant: hair, pose: .typing, prop: .globe, clock: AgentNookClock(t: 1.61, motion: true), pixel: 3), size: size)
        let reduced = rendered(AgentNookCritter(kind: .claude, variant: hair, pose: .typing, prop: .globe, clock: AgentNookClock(t: 1.01, motion: false), pixel: 3), size: size)
        let reducedLater = rendered(AgentNookCritter(kind: .claude, variant: hair, pose: .typing, prop: .globe, clock: AgentNookClock(t: 3.21, motion: false), pixel: 3), size: size)
        r.check("drawn: a working figure's face moves with the clock (two steps draw differently), and with Reduce Motion too, only slower",
                first != nil && first != second && reduced != nil && reduced != reducedLater)
    }

    // MARK: A real click

    @MainActor private final class Rig {
        let size: CGSize
        let panel: NSPanel
        let navigator = NotchNavigator()
        let store: AgentsStore
        var frames: [String: CGRect] = [:]

        init(store: AgentsStore, width: CGFloat = 520) {
            size = CGSize(width: width, height: 140)
            self.store = store
            panel = NSPanel(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            let view = AgentNookPanelView(store: store).reportingFrames { [unowned self] in self.frames = $0 }
                .environment(\.notchNavigator, navigator)
                .frame(width: size.width, height: size.height)
                .background(Color.black)
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

        /// How much of the picture is not black (a blank picture means nothing drew).
        func litFraction() -> Double {
            guard let hosting = panel.contentView, let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return 0 }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            var lit = 0, total = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                    total += 1
                    if let c = rep.colorAt(x: x, y: y), c.redComponent + c.greenComponent + c.blueComponent > 0.18 { lit += 1 }
                }
            }
            return total == 0 ? 0 : Double(lit) / Double(total)
        }

        func close() { panel.contentView = nil; panel.orderOut(nil) }
    }

    /// Nothing may stick out of the glass at any width (the roof once pushed the rooms 8 pt to the right at 3 cells).
    /// The real closed notch on the owner's 16-inch MacBook (notch 185 x 32 pt): every face sits LEFT of the camera, the island is exactly
    /// the notch and the faces, and an empty right wing moves nothing. Build 257 slid the faces 26 pt right, under the camera, once the
    /// message stepped aside.
    private static func closedNotch(_ r: inout Report) async {
        let all = AgentSession.synthetic(6)
        for (count, rest) in [(1, true), (2, true), (4, true), (2, false)] {
            let store = AgentsStore(directory: AppPaths.folder("agentnook-test-closed-\(count)-\(rest)"))
            store.loadSessions(Array(all.prefix(count)))
            let size = CGSize(width: 560, height: 60)
            let model = NotchScreenModel(geometry: .sample16, panelSize: size)
            let center = LiveActivityCenter()
            if rest {
                center.show(LiveActivity(id: "agents.main", kind: .agent, expiresAfter: nil, onTap: nil,
                                         leading: { AgentWingLeft(store: store, frozenAt: 0.6) }, trailing: { EmptyView() }))
            } else {
                center.show(AgentsStore.wings(store: store, expiresAfter: nil))
            }
            let root = NotchRootView(model: model, center: center, navigator: NotchNavigator(), nook: NookStore(persist: false, layout: nil), styleOverride: .classic)
            let panel = NSPanel(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: root)
            hosting.frame = CGRect(origin: .zero, size: size)
            panel.contentView = hosting
            panel.orderFrontRegardless()
            for _ in 0..<14 { try? await Task.sleep(nanoseconds: 90_000_000); hosting.layoutSubtreeIfNeeded() }
            let island = model.islandRect
            let notch = CGRect(x: (size.width - 185) / 2, y: 0, width: 185, height: 32)
            let faces = CGFloat(count) * 18 + CGFloat(count - 1) * 3
            let name = "\(count) agent\(count == 1 ? "" : "s")\(rest ? "" : " with news on the right")"
            r.check("closed notch, \(name): left of the camera it is exactly the faces, 14 pt around them and the 6 pt shoulder",
                    abs((notch.minX - island.minX) - (faces + 14 + 6)) <= 1.5, "island \(island) notch \(notch)")
            if rest {
                r.check("  nothing on the right: only the shoulder past the camera", abs((island.maxX - notch.maxX) - 6) <= 1.5, "island \(island)")
            } else {
                r.check("  the news widens the right side only", island.maxX - notch.maxX > 26, "island \(island)")
            }
            // Pixels: nothing bright under the camera housing, the faces bright beside it.
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                let scale = CGFloat(rep.pixelsWide) / size.width
                func lit(_ rect: CGRect) -> Int {
                    var n = 0
                    for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
                        for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { continue }
                            if c.redComponent + c.greenComponent + c.blueComponent > 0.45 { n += 1 }
                        }
                    }
                    return n
                }
                let under = lit(notch.insetBy(dx: 1, dy: 1))
                let beside = lit(CGRect(x: island.minX + 6, y: 4, width: max(1, notch.minX - island.minX - 6), height: 24))
                r.check("  no face under the camera housing", under == 0, "\(under) bright pixels under it")
                r.check("  the faces show beside it", beside > count * 40, "\(beside) bright pixels")
            }
            panel.orderOut(nil)
        }
    }

    /// The open dashboard with the Agent TV first: a little bigger, the same shape, its glass rim about `cornerGap` from the island's left
    /// edge. The picture is saved next to the report for a look.
    private static func tvCorner(_ r: inout Report, out: URL) async {
        let store = AgentsStore(directory: AppPaths.folder("agentnook-test-tvcorner"))
        store.loadSessions(Array(AgentSession.synthetic(6).prefix(4)))
        let size = CGSize(width: 1300, height: 760)
        let model = NotchScreenModel(geometry: .sample16, panelSize: size)
        model.isOpen = true
        let nook = NookStore(persist: false, layout: [.agents, .askAI, .pulse])
        nook.liveOverride = NookLive(playing: false, openTodos: 0, agents: 4)   // like the owner's dashboard: the TV with its knobs at the side
        nook.viewOverride = { item in item == .panel(.agents) ? AnyView(AgentNookPanelView(store: store)) : nil }
        let root = NotchRootView(model: model, center: LiveActivityCenter(), navigator: NotchNavigator(), nook: nook, styleOverride: .classic,
                                 widthCapOverride: 1040, openHeightOverride: 32 + 6 + NookMetrics.widgetHeight + 16)   // tight like the owner's: the header, the row, the margins
        let panel = NSPanel(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.orderFrontRegardless()
        for _ in 0..<16 { try? await Task.sleep(nanoseconds: 90_000_000); hosting.layoutSubtreeIfNeeded() }
        let island = model.islandRect
        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: out.deletingLastPathComponent().appendingPathComponent("tv-corner-\(Look.preset.rawValue)-\(Look.size.rawValue).png")) }
            let scale = CGFloat(rep.pixelsWide) / size.width
            // What the owner sees on the light paper: the TV's rim (its mask, a shade deeper than the paper: a dark edge at the top left, a pale
            // one at the bottom right; the set's glass is light in the light preset, no longer black), measured in the picture from the island's left
            // edge and from its bottom edge; the two gaps must match.
            if Look.preset == .light {
                func lum(_ x: Int, _ y: Int) -> CGFloat? {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
                    return c.redComponent * 0.299 + c.greenComponent * 0.587 + c.blueComponent * 0.114
                }
                let rowY = Int((island.minY + (32 + 6 + 60) * Look.scale) * scale)
                // From outside the island: where the paper begins (the island's edge), then the first dark pixel (the TV's rim).
                let xs = Array(Int((island.minX - 6) * scale)..<Int((island.minX + 140 * Look.scale) * scale))
                let paperX = xs.first { (lum($0, rowY) ?? 0) > 0.8 }
                let rimX = paperX.flatMap { p in xs.first { $0 > p && (lum($0, rowY) ?? 1) < 0.91 } }   // paper reads 0.94; the mask's edges 0.9 and below
                if let paperX, let rimX {
                    let colX = rimX + Int(40 * scale)
                    let ys = Array(stride(from: Int((island.maxY + 6) * scale), to: Int((island.maxY - 140 * Look.scale) * scale), by: -1))
                    let paperY = ys.first { (lum(colX, $0) ?? 0) > 0.8 }
                    let rimY = paperY.flatMap { p in ys.first { $0 < p && (lum(colX, $0) ?? 1) < 0.91 } }
                    let leftGap = CGFloat(rimX - paperX) / scale
                    let bottomGap = (paperY.flatMap { p in rimY.map { CGFloat(p - $0) / scale } }) ?? -1
                    // The screen only ever reaches LEFT: when the left border is already the narrower one it stays where it is.
                    let reached = (AgentNookPanelView.lastMeasure?.reach ?? 0) > 0
                    r.check("in the picture (light paper): the TV's rim is as far from the island's left edge as from its bottom edge (or nearer, untouched)",
                            bottomGap > 0 && (reached ? abs(leftGap - bottomGap) <= 2.5 * Look.scale : leftGap <= bottomGap + 1),
                            String(format: "left %.1f pt, bottom %.1f pt, %@", leftGap, bottomGap, reached ? "reached" : "untouched"))   // the bevel's lit bottom edge reads ~1.5 pt in
                } else {
                    r.check("in the picture (light paper): the TV's rim was found", false, "no dark rim on the row")
                }
            }
            // The rule, in the content's own space as the TV laid itself out: the rim's gap to the island's left edge equals its gap to the
            // bottom edge (the rim is the set's outer dark edge: on the light paper that is the border the owner sees).
            if let m = AgentNookPanelView.lastMeasure {
                let well = CRTSetLayout(size: m.panel.size, compact: false, extendLeft: m.reach).well
                let left = m.panel.minX + well.minX - AgentNookPanelView.islandShoulder, bottom = m.content.height - (m.panel.minY + well.maxY)
                r.check("the Agent TV's screen frame: the same border left and down (it reaches left only when the left border is the wider)",
                        m.reach > 0 ? abs(left - bottom) <= 1 : left <= bottom + 1,
                        "left \(left) bottom \(bottom) reach \(m.reach) panel \(m.panel) content \(m.content)")
            } else {
                r.check("the Agent TV measured itself in the open notch", false, "no measure")
            }
        }
        panel.orderOut(nil)
    }

    /// From the Ask AI tab to the CPU tab with a real click on its key, on the real navigator: the island takes the den's full height
    private static func askAIToAgents(_ r: inout Report) async {
        let nav = NotchNavigator.shared
        let size = CGSize(width: 1200, height: 760)
        let model = NotchScreenModel(geometry: .sample16, panelSize: size)
        model.isOpen = true
        nav.open(.askAI)
        let root = NotchRootView(model: model, center: LiveActivityCenter(), navigator: nav, nook: NookStore(persist: false, layout: nil), styleOverride: .classic)
        let panel = NSPanel(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.orderFrontRegardless()
        func settle(_ n: Int) async { for _ in 0..<n { try? await Task.sleep(nanoseconds: 100_000_000); hosting.layoutSubtreeIfNeeded() } }
        func click(_ p: CGPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x, y: size.height - p.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) { panel.sendEvent(e) }
            }
        }
        await settle(12)
        let before = model.islandRect.height
        let state0 = "owner \(String(describing: nav.heightOwner)) height \(String(describing: nav.workspaceHeight))"
        guard let key = model.panelRects["tab.agents"] else {
            r.check("Ask AI then the CPU tab key: the key is there", false, "rects \(model.panelRects.keys.sorted())")
            panel.orderOut(nil); nav.forceClose(); return
        }
        click(CGPoint(x: key.midX, y: key.midY))
        var trace: [String] = []
        for i in 0..<20 {
            await settle(1)
            if i % 4 == 0 { trace.append("\(Int(model.islandRect.height))/\(String(describing: nav.heightOwner))/\(nav.workspaceHeight.map { String(Int($0)) } ?? "nil")") }
        }
        let after = model.islandRect.height
        let want = AgentDenLayout.islandHeight()
        r.check("Ask AI, then a real click on the CPU tab key: the island takes the den's full height", nav.workspace == .agents && abs(after - want) <= 2,
                "before \(Int(before)) (\(state0)) after \(Int(after)) want \(Int(want)); workspace \(nav.workspace); trace \(trace.joined(separator: " "))")
        // Quick back and forth, with Ask AI holding a height of its own (with a key it asks for its conversation height): CPU, Ask AI, CPU.
        if let ask = model.panelRects["tab.askAI"], let cpu = model.panelRects["tab.agents"] {
            for gap in [UInt64(60_000_000), 300_000_000] {
                click(CGPoint(x: ask.midX, y: ask.midY))
                try? await Task.sleep(nanoseconds: 30_000_000)
                nav.requestHeight(520, resizeMax: .greatestFiniteMagnitude, by: .askAI)
                try? await Task.sleep(nanoseconds: gap)
                click(CGPoint(x: cpu.midX, y: cpu.midY))
                await settle(18)
                let h = model.islandRect.height
                r.check("  CPU, Ask AI, back to CPU after \(gap / 1_000_000) ms: the den's full height again", nav.workspace == .agents && abs(h - want) <= 2,
                        "island \(Int(h)) want \(Int(want)); owner \(String(describing: nav.heightOwner)) height \(nav.workspaceHeight.map { String(Int($0)) } ?? "nil")")
            }
        }
        panel.orderOut(nil)
        nav.forceClose()
        nav.workspace = .nook
    }

    private static func fits(_ r: inout Report) async {
        for cells in [3, 4, 6, 10, 16] {
            for count in [1, 3, 9] {
                let width = AgentNookLayout.width(cells: cells)
                let rig = Rig(store: AgentNookSamples.store("fit\(cells)-\(count)", AgentNookSamples.sessions(count)), width: width)
                try? await Task.sleep(nanoseconds: 350_000_000)
                let plan = AgentTVLayout.plan(panelWidth: width, count: count)
                let fitted = AgentTileMetrics.keepOrder(AgentNookPanelView.models(rig.store.sessions, pending: rig.store.pending), limit: plan.shown) { AgentTileMetrics.need($0.look) }
                let rooms = fitted.compactMap { rig.frames[$0.id] }
                // The rooms stand on the glass of the set (the kit's set or the wide console), so they must stay on it.
                let inside = !rooms.isEmpty && rooms.allSatisfy { $0.minX >= plan.glass.minX - 0.5 && $0.maxX <= plan.glass.maxX + 0.5 && $0.maxY <= plan.glass.maxY + 0.5 }
                let door = rig.frames["door"].map { $0.maxX <= plan.glass.maxX + 0.5 } ?? (plan.more == 0)
                r.check("\(cells) cells, \(count) agents: every room (and the door) stays on the glass", inside && door, "frames \(rooms.map { "\(Int($0.minX))-\(Int($0.maxX))" }) of \(Int(width))")
                rig.close()
            }
        }
    }

    private static func clicks(_ r: inout Report) async {
        let sessions = AgentNookSamples.sessions(9)
        let store = AgentNookSamples.store("selftest", sessions)
        let rig = Rig(store: store)
        defer { rig.close() }
        try? await Task.sleep(nanoseconds: 700_000_000)
        let all = AgentNookPanelView.models(store.sessions, pending: store.pending)
        let plan = AgentTVLayout.plan(panelWidth: rig.size.width, count: all.count)
        let models = AgentTileMetrics.keepOrder(all, limit: plan.shown) { AgentTileMetrics.need($0.look) }   // the rooms that fit
        r.check("the rooms are on the panel, one per fitted agent", models.allSatisfy { rig.frames[$0.id] != nil } && (plan.more == 0 || rig.frames["door"] != nil),
                "frames \(rig.frames.keys.sorted()) plan \(plan)")
        r.check("  the rooms that fit include every one that needs you, in the fixed order", all.filter { $0.look == .needsYou }.allSatisfy { m in models.contains { $0.id == m.id } }
                && models.map(\.id) == all.map(\.id).filter { id in models.contains { $0.id == id } }, "\(models.map(\.id))")
        r.check("the panel draws something", rig.litFraction() > 0.08, "lit \(rig.litFraction())")
        guard let second = models.dropFirst().first, let frame = rig.frames[second.id] else {
            r.check("a room can be clicked", false, "no frame for the second room")
            return
        }
        // Hovering changes nothing but the edge.
        rig.post(.mouseMoved, CGPoint(x: frame.midX, y: frame.midY))
        try? await Task.sleep(nanoseconds: 200_000_000)
        r.check("hovering a room opens nothing", rig.store.focusID == nil && rig.navigator.workspace == .nook && !rig.navigator.isOpen)
        rig.click(CGPoint(x: frame.midX, y: frame.midY))
        try? await Task.sleep(nanoseconds: 300_000_000)
        r.check("a click on a room picks that agent and opens the Agents view", rig.store.focusID == second.id && rig.navigator.workspace == .agents && rig.navigator.isOpen,
                "focus \(rig.store.focusID ?? "nil") workspace \(rig.navigator.workspace) open \(rig.navigator.isOpen)")
        if let door = rig.frames["door"] {
            rig.navigator.workspace = .nook
            rig.store.focusID = nil
            rig.click(CGPoint(x: door.midX, y: door.maxY - 12))
            try? await Task.sleep(nanoseconds: 300_000_000)
            r.check("a click on the +N door opens the Agents view", rig.navigator.workspace == .agents, "workspace \(rig.navigator.workspace)")
        } else {
            r.check("the +N door is there when agents are left out", plan.more == 0, "plan \(plan)")
        }
    }
    // MARK: The minimal look (8-bit style off)

    /// The plain rows panel and the old wing, with the style switch turned off here and put back: the rows say what they must in the right order,
    /// they fit the 140 pt panel at every width, a real click on a row picks that agent, and the wing is the cpu symbol with two numbers.
    private static func minimal(_ r: inout Report) async {
        guard Retro.is8bit else { r.note("minimal look skipped: the look is forced by SCOUT_8BIT"); return }
        Pref.set(false, Retro.styleKey)
        defer { Pref.set(nil, Retro.styleKey) }
        r.tag = "[minimal] "
        defer { r.tag = "" }
        r.check("the style switch is off for these checks", !Retro.is8bit)

        let sessions = AgentNookSamples.sessions(9)
        let held = AgentPending(sessionID: "nk-6", kind: .permission, tool: "Bash", summary: "terraform apply", detail: "terraform apply", questions: [], rawToolInput: nil, agent: .codex)
        let rows = AgentMiniRow.rows(sessions, pending: [held])
        r.check("every agent gets a row, in the fixed order (the TV's and the den's)", rows.count == 9 && rows.map(\.id) == AgentTileMetrics.ordered(sessions).map(\.id), "\(rows.map(\.id))")
        r.check("the rows follow the one rule for \"needs you\"", rows.allSatisfy { row in
            let s = sessions.first { $0.id == row.id }!
            return (row.look == .needsYou) == AgentWingSummary.asks(s, pending: [held])
        })
        let heldRow = rows.first { $0.id == "nk-6" }
        r.check("a held request's row says what it wants", heldRow?.line == "Wants to use Bash: terraform apply", heldRow?.line ?? "-")
        let working = rows.first { $0.id == "nk-1" }
        r.check("a working row says its latest sentence, its helpers and its to-do progress", working?.line == "I'll fix the three footer links, then run the linter." && working?.helpers == 2 && working?.progress == "2/5", "\(String(describing: working))")
        r.check("an agent without to-dos has no progress", rows.first { $0.id == "nk-3" }?.progress == nil)
        r.check("a state dot has one colour per state, five in all", Set(AgentNookLook.allCases.map { AgentMini.color($0) }).count == 5)
        r.check("the panel's fact is the working count, else the agents", AgentMiniPanelLayout.fact(rows) == "4 working" && AgentMiniPanelLayout.fact(Array(rows.filter { $0.look == .idle })) == "Agents: 1", AgentMiniPanelLayout.fact(rows))

        // The panel follows the dashboard's grid (no title line, the grid's insets and "+N more"), so a 140 pt panel holds five one-line rows.
        let table: [(CGFloat, Int, Int, Int, Bool)] = [(150, 3, 3, 0, true), (150, 4, 3, 1, true), (150, 0, 0, 0, true), (300, 4, 4, 0, false), (300, 5, 5, 0, false), (300, 9, 4, 5, false), (800, 1, 1, 0, false)]
        for (width, count, shown, more, stacked) in table {
            let p = AgentMiniPanelLayout.plan(width: width, count: count)
            r.check("\(Int(width)) pt, \(count) agents: \(shown) rows\(more > 0 ? " and +\(more)" : "")\(stacked ? ", two lines each" : "")", p.shown == shown && p.more == more && p.stacked == stacked, "\(p)")
        }
        var fits = true
        for cells in [3, 4, 5, 6, 10, 16] { for count in [0, 1, 2, 3, 4, 5, 9] {
            let p = AgentMiniPanelLayout.plan(width: AgentNookLayout.width(cells: cells), count: count)
            let used = CGFloat(p.shown) * (p.rowHeight + AgentMiniPanelLayout.gap) + (p.more > 0 ? AgentMiniPanelLayout.moreLine + AgentMiniPanelLayout.gap : 0)
            let room = NookMetrics.widgetHeight - AgentMiniPanelLayout.padding.top - AgentMiniPanelLayout.padding.bottom - AgentMiniPanelLayout.header + AgentMiniPanelLayout.gap
            if used > room + 0.01 || p.shown + p.more != count || (count > 0 && p.shown < 1) { fits = false }
        } }
        r.check("at 3 to 16 cells the rows (and the +N line) fit the 140 pt panel and none is lost", fits)

        // Drawn: every shown row has its frame inside the panel, the +N line is there when agents are left out, and a click picks an agent.
        for cells in [3, 6, 16] { for count in [0, 1, 3, 9] {
            let width = AgentNookLayout.width(cells: cells)
            let rig = Rig(store: AgentNookSamples.store("min\(cells)-\(count)", AgentNookSamples.sessions(count)), width: width)
            try? await Task.sleep(nanoseconds: 350_000_000)
            let plan = AgentMiniPanelLayout.plan(width: width, count: count)
            let list = AgentTileMetrics.keepOrder(AgentMiniRow.rows(rig.store.sessions, pending: rig.store.pending), limit: plan.shown) { AgentTileMetrics.need($0.look) }
            let shown = list.compactMap { rig.frames[$0.id] }
            let inside = shown.count == plan.shown && shown.allSatisfy { $0.minX >= -0.5 && $0.maxX <= width + 0.5 && $0.maxY <= NookMetrics.widgetHeight + 0.5 }
            let door = rig.frames["door"].map { $0.maxY <= NookMetrics.widgetHeight + 0.5 } ?? (plan.more == 0)
            r.check("\(cells) cells, \(count) agents: every row (and the +N line) stands inside the panel", inside && door,
                    "expected \(list.map(\.id)) frames \(rig.frames.map { "\($0.key) \(Int($0.value.minX)),\(Int($0.value.minY)) \(Int($0.value.width))x\(Int($0.value.height))" }.sorted()) plan \(plan)")
            r.check("  and the panel draws something", rig.litFraction() > 0.005, "lit \(rig.litFraction())")   // the panel is black now: only its words and dots light
            rig.close()
        } }
        let store = AgentNookSamples.store("min-click", sessions)
        let rig = Rig(store: store, width: AgentNookLayout.width(cells: 6))
        defer { rig.close() }
        try? await Task.sleep(nanoseconds: 700_000_000)
        let plan6 = AgentMiniPanelLayout.plan(width: AgentNookLayout.width(cells: 6), count: store.sessions.count)
        let list = AgentTileMetrics.keepOrder(AgentMiniRow.rows(store.sessions, pending: store.pending), limit: plan6.shown) { AgentTileMetrics.need($0.look) }
        guard let second = list.dropFirst().first, let frame = rig.frames[second.id] else { r.check("a row can be clicked", false, "frames \(rig.frames.keys.sorted())"); return }
        rig.post(.mouseMoved, CGPoint(x: frame.midX, y: frame.midY))
        try? await Task.sleep(nanoseconds: 200_000_000)
        r.check("hovering a row opens nothing", store.focusID == nil && rig.navigator.workspace == .nook && !rig.navigator.isOpen)
        rig.click(CGPoint(x: frame.midX, y: frame.midY))
        try? await Task.sleep(nanoseconds: 300_000_000)
        r.check("a click on a row picks that agent and opens the Agents view", store.focusID == second.id && rig.navigator.workspace == .agents && rig.navigator.isOpen, "focus \(store.focusID ?? "nil") workspace \(rig.navigator.workspace)")
        if let door = rig.frames["door"] {
            rig.navigator.workspace = .nook
            store.focusID = nil
            rig.click(CGPoint(x: door.minX + 10, y: door.midY))
            try? await Task.sleep(nanoseconds: 300_000_000)
            r.check("a click on the +N line opens the Agents view", rig.navigator.workspace == .agents, "workspace \(rig.navigator.workspace)")
        } else {
            r.check("the +N line is there when agents are left out", false)
        }

        // The wing: the cpu symbol, the number at work and the number that need you (the summary's faces stay for the 8-bit wing).
        var list6 = AgentSession.synthetic(6)
        list6[2].lastMessage = "I changed the footer links."
        let wings = AgentsStore(directory: AppPaths.folder("agentmini-wing"))
        wings.loadSessions(list6)
        let summary = AgentWingSummary.make(sessions: wings.sessions, pending: wings.pending)
        let wing = NSHostingView(rootView: AgentWingLeft(store: wings).fixedSize())
        r.check("the left wing is small: a symbol and two numbers, as high as a face and under 60 pt wide", wing.fittingSize.height <= 19 && wing.fittingSize.width <= 60 && wing.fittingSize.width >= 36, "\(wing.fittingSize)")
        r.check("  it counts the agents at work and those that need you", summary.working == 3 && summary.needs == 1 && summary.faces.count == 4, "working \(summary.working) needs \(summary.needs)")
        let quiet = AgentsStore(directory: AppPaths.folder("agentmini-wing-quiet"))
        quiet.loadSessions([])
        let glyph = NSHostingView(rootView: AgentWingLeft(store: quiet).fixedSize())
        r.check("  nobody home: only the symbol", glyph.fittingSize.width <= 18 && glyph.fittingSize.height <= 19, "\(glyph.fittingSize)")
    }
}
