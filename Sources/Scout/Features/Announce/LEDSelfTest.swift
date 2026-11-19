import AppKit
import Combine
import SwiftUI

/// `scout://led.selftest?out=<file>` (headless runs): the LED announcement board, with synthetic agents only. It runs as its own
/// build, offscreen:
///   build/Scout.app/Contents/MacOS/Scout --automation --headless --run "scout://led.selftest?out=<file>" & PID=$!
/// then wait for the file and `kill $PID`. A fake clock drives the ticker, the queue and the agent watcher; the centre posts into its
/// own `LiveActivityCenter`, so nothing reaches the screen and nothing is written to the owner's settings (scripted runs read an
/// isolated defaults domain, and the one key the test flips is put back).
@MainActor
enum LEDSelfTest {
    static func register() {
        DebugCommands.register("led.selftest") { params in
            guard ScoutRuntime.isAutomation else { return }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("led-selftest.txt")
            Task { @MainActor in await run(out: out) }
        }
    }

    // MARK: Fake time

    /// A clock that only moves when the test says so; `schedule` queues work that `advance` runs in order.
    @MainActor private final class Clock {
        struct Item { var due: Date; var id: Int; var work: @MainActor () -> Void }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        private(set) var items: [Item] = []
        private var nextID = 0

        /// Timers waiting right now.
        var pending: Int { items.count }

        func schedule(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
            let id = nextID
            nextID += 1
            items.append(Item(due: now.addingTimeInterval(seconds), id: id, work: work))
            return { [weak self] in self?.items.removeAll { $0.id == id } }
        }

        func advance(by seconds: TimeInterval) {
            let target = now.addingTimeInterval(seconds)
            while let next = items.filter({ $0.due <= target }).min(by: { $0.due < $1.due }) {
                items.removeAll { $0.id == next.id }
                now = max(now, next.due)
                next.work()
            }
            now = target
        }

        var notchOpen = false

        func env(reduceMotion: Bool = false, forceScroll: Bool = false, scripted: Bool = false) -> LEDAnnouncements.Env {
            var env = LEDAnnouncements.Env()
            env.now = { [unowned self] in now }
            env.schedule = { [unowned self] seconds, work in schedule(seconds, work) }
            env.reduceMotion = { reduceMotion }
            env.forceScroll = { forceScroll }
            env.isScripted = scripted
            env.isNotchOpen = { [unowned self] in notchOpen }
            return env
        }
    }

    @MainActor private final class Checker {
        var lines: [String] = []
        var failed = 0

        func callAsFunction(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failed += 1 }
            lines.append("led selftest \(ok ? "ok  " : "FAIL") \(name)\(ok || detail.isEmpty ? "" : "  (\(detail))")")
        }
    }

    static func run(out: URL) async {
        let check = Checker()
        // What the real shared pieces did by themselves before the test touched anything: nothing.
        check("nothing was posted by itself in this scripted run", LEDAnnouncements.shared.log.isEmpty && !LEDAnnouncements.shared.isBusy)
        check("the agent watcher is not running in a scripted run", !LEDAgentWatcher.shared.isRunning)

        fontChecks(check)
        tickerChecks(check)
        modeChecks(check)
        queueChecks(check)
        agentChecks(check)
        await wiringChecks(check)
        switchChecks(check)
        signFrameChecks(check)

        check("still nothing posted by the shared centre", LEDAnnouncements.shared.log.isEmpty && LEDAgentWatcher.shared.isRunning == false)
        check.lines.append("led selftest done: \(check.failed == 0 ? "all passed" : "\(check.failed) FAILED")")
        for line in check.lines { print(line) }
        fflush(stdout)
        try? check.lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
    }

    // MARK: 1. The font

    private static func fontChecks(_ check: Checker) {
        let wanted = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789") + Array(".,:;!?-+/'\"()%&#@*") + [LEDFont.heart, LEDFont.star, LEDFont.smile, LEDFont.arrow, LEDFont.check, LEDFont.note, LEDFont.creature]
        check("the font table has no malformed glyph", LEDFont.malformedCount == 0, "\(LEDFont.malformedCount) bad")
        check("every wanted character is in the font (\(wanted.count))", wanted.allSatisfy { LEDFont.hasGlyph($0) }, "missing \(wanted.filter { !LEDFont.hasGlyph($0) })")
        let supported = LEDFont.supported
        check("every supported character has a glyph of 7 rows by 5 columns", supported.allSatisfy { ch in
            let g = LEDFont.glyph(ch)
            return g.rows.count == 7 && g.rows.allSatisfy { $0.count == 5 } && g.columns.count == 5
        })
        check("every character except the space is lit somewhere; the space is blank", supported.allSatisfy { $0 == " " ? LEDFont.glyph($0).isBlank : !LEDFont.glyph($0).isBlank })
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        check("no two letters or digits share one glyph", Set(letters.map { LEDFont.glyph($0).columns.map(\.bits) }).count == letters.count)
        check("lowercase draws the capital", LEDFont.glyph("a") == LEDFont.glyph("A") && LEDFont.glyph("z") == LEDFont.glyph("Z"))
        check("aliases draw the cute glyph (❤️ ✔)", LEDFont.glyph("❤️") == LEDFont.glyph(LEDFont.heart) && LEDFont.glyph("✔") == LEDFont.glyph(LEDFont.check))
        check("an accented letter draws its plain letter", LEDFont.glyph("é") == LEDFont.glyph("E"))
        let unknown: [Character] = ["§", "Ж", "😀", "\u{1}", "€"]
        check("an unknown character is a blank glyph of the right size", unknown.allSatisfy { LEDFont.glyph($0).isBlank && LEDFont.glyph($0).rows.count == 7 && !LEDFont.hasGlyph($0) })
        check("the cute glyphs keep their own colour", LEDFont.glyph(LEDFont.heart).accent == .heart && LEDFont.glyph("A").accent == .none
              && LEDFont.glyph(LEDFont.heart).columns.contains { $0.accent == .heart })
        // Text to columns.
        let ab = LEDFont.columns("AB")
        check("text to columns: two letters are 5 + 1 + 5 columns", ab.count == 11 && LEDFont.width("AB") == 11)
        check("  the first five columns are the A, the sixth is dark, the last five are the B",
              Array(ab[0..<5]) == LEDFont.glyph("A").columns && ab[5] == .blank && Array(ab[6..<11]) == LEDFont.glyph("B").columns)
        check("  no dark column after the last letter; an empty text has no columns", LEDFont.columns("").isEmpty && LEDFont.columns("A").count == 5 && LEDFont.width("") == 0)
        check("  columns carry bit 0 for the top row", LEDFont.glyph("T").columns.allSatisfy { $0.bits & 1 != 0 } && !LEDFont.glyph(".").columns.contains { $0.bits & 1 != 0 })
        check("  seven letters are 41 columns (a wing's most)", LEDFont.width("WELCOME") == 41 && LEDSchedule.maxWindow == 41)
        check("  an unknown character keeps its place as a blank (3 characters stay 17 columns)", LEDFont.columns("A§B").count == 17 && LEDFont.columns("A§B")[6..<11].allSatisfy { $0 == .blank })
    }

    // MARK: 2. The ticker (Step and Scroll)

    private static func tickerChecks(_ check: Checker) {
        // Paging.
        check("paging: whole words stay together (WELCOME NOTES ♥ → WELCOME | NOTES ♥)", LEDPaging.pages("WELCOME NOTES \(LEDFont.heart)", capacity: 7) == ["WELCOME", "NOTES \(LEDFont.heart)"], "\(LEDPaging.pages("WELCOME NOTES \(LEDFont.heart)", capacity: 7))")
        check("  a short text is one part", LEDPaging.pages("BYE API", capacity: 7) == ["BYE API"])
        check("  a long word is cut in even pieces (14 letters → 7 + 7)", LEDPaging.pages("ABCDEFGHIJKLMN", capacity: 7) == ["ABCDEFG", "HIJKLMN"])
        check("  a hyphen ends a piece (SCOUT-DASH → SCOUT- | DASH)", LEDPaging.pages("SCOUT-DASH", capacity: 7) == ["SCOUT-", "DASH"], "\(LEDPaging.pages("SCOUT-DASH", capacity: 7))")
        let long = "WELCOME ABCDEFGHIJKLMN \(LEDFont.heart)"
        let parts = LEDPaging.pages(long, capacity: 7)
        check("  every part fits the board and no letter is lost", parts.allSatisfy { $0.count <= 7 } && parts.joined().filter { $0 != " " } == long.filter { $0 != " " }, "\(parts)")

        // Step mode: the letters light up in place.
        let step = LEDSchedule(text: "WELCOME NOTES \(LEDFont.heart)", mode: .step)
        check("step: a 15-character message pages in two parts on a 41-column board", step.pages.count == 2 && step.window == 41 && step.pages.allSatisfy { $0.count == 41 })
        let first = step.pages[0]
        check("step: nothing is lit before the message starts", step.frame(at: -1).litCount == 0)
        var inPlace = true
        var monotonic = true
        var lastLit = 0
        var t = 0.0
        while t < step.lightDuration(page: 0) {
            let f = step.frame(at: t)
            for i in 0..<41 where f.columns[i] != .blank && f.columns[i] != first[i] { inPlace = false }   // a lit column is the final one, never moved
            if f.litCount < lastLit { monotonic = false }
            lastLit = f.litCount
            t += 0.01
        }
        check("step: columns light up in place, left to right, none moves", inPlace && monotonic)
        check("step: the first moments show only the first columns", step.frame(at: 0.0).litCount > 0 && step.frame(at: 0.0).litCount < step.frame(at: step.lightDuration(page: 0) / 2).litCount)
        let lightEnd = step.lightDuration(page: 0)
        check("step: fully lit once the lighting is done, and it holds without changing",
              step.frame(at: lightEnd + 0.05).columns == first && step.frame(at: lightEnd + 0.9).columns == first && step.frame(at: lightEnd + 0.05).hot == nil)
        check("step: a column that has just lit is white-hot while the page lights up", step.frame(at: lightEnd / 2).hot != nil)
        check("step: lighting a full part takes under a second", lightEnd > 0.5 && lightEnd < 1.0, "\(lightEnd)")
        let dark = step.pageStart(1) - 0.05
        check("step: a dark breath between two parts, then the next part lights in place", step.frame(at: dark).litCount == 0
              && step.frame(at: step.pageStart(1) + 0.01).litCount > 0
              && step.frame(at: step.pageStart(1) + step.lightDuration(page: 1) + 0.05).columns == step.pages[1])
        check("step: it ends after its natural time (a few seconds) and then shows nothing", step.duration > 3 && step.duration < 8 && step.frame(at: step.duration + 0.1).finished && step.frame(at: step.duration + 0.1).litCount == 0, "\(step.duration)")
        let narrow = LEDSchedule(text: "BYE", mode: .step)
        check("step: a short message gets a narrow board, not the whole wing", narrow.window == 17 && narrow.pages[0].count == 17, "\(narrow.window)")
        let uneven = LEDSchedule(text: "WELCOME API", mode: .step)
        let apiPage = uneven.pages[1]
        check("step: a shorter part sits in the middle of the board", uneven.window == 41 && apiPage.prefix(12).allSatisfy { $0 == .blank } && apiPage[12] == LEDFont.glyph("A").columns[0] && apiPage[(12 + 17)...].allSatisfy { $0 == .blank })
        let timed = LEDSchedule(text: "WELCOME NOTES \(LEDFont.heart)", mode: .step, seconds: 7)
        check("step: a requested number of seconds is the message's time", abs(timed.duration - 7) < 0.05, "\(timed.duration)")
        let quick = LEDSchedule(text: "HELLO", mode: .step, seconds: 3)
        check("step: a short request still shows every letter", quick.frame(at: quick.lightDuration(page: 0) + 0.05).litCount > 0 && abs(quick.duration - 3) < 0.05, "\(quick.duration)")

        // Scroll mode: a marquee, right to left, one column at a time.
        let scroll = LEDSchedule(text: "AB", mode: .scroll)
        let text = LEDFont.columns("AB")
        let speed = LEDSchedule.scrollColumnsPerSecond
        check("scroll: the board is the full 41 columns and shows nothing at the start", scroll.window == 41 && scroll.frame(at: 0).litCount == 0)
        var offsetsRight = true
        for k in 1...12 {
            let f = scroll.frame(at: Double(k) / speed + 0.001)
            // After k steps the text's first column is k columns in from the right edge.
            if f.columns[41 - k] != text[0] { offsetsRight = false }
            if k >= 2, f.columns[41 - k + 1] != text[1] { offsetsRight = false }
        }
        check("scroll: the text comes in from the right, one column per step", offsetsRight)
        let early = scroll.frame(at: 10.5 / speed)
        let later = scroll.frame(at: 11.5 / speed)
        check("scroll: each step moves everything one column to the left", Array(later.columns[0..<40]) == Array(early.columns[1..<41]))
        check("scroll: the time is (board + text columns) / speed, and it ends blank", abs(scroll.duration - Double(41 + text.count) / speed) < 0.001 && scroll.frame(at: scroll.duration + 0.1).finished)
        let last = scroll.frame(at: Double(41 + text.count - 1) / speed + 0.001)
        check("scroll: the last column sits in the left edge just before the end", last.columns[0] == text[text.count - 1] && last.litCount == text[text.count - 1].bits.nonzeroBitCount)
        let fast = LEDSchedule(text: "WELCOME NOTES \(LEDFont.heart)", mode: .scroll, seconds: 4)
        check("scroll: a requested number of seconds sets the speed", abs(fast.duration - 4) < 0.01, "\(fast.duration)")
        let normal = LEDSchedule(text: "WELCOME NOTES \(LEDFont.heart)", mode: .scroll)
        check("scroll: a welcome takes a few seconds", normal.duration > 3 && normal.duration < 9, "\(normal.duration)")
    }

    // MARK: 3. Which mode

    private static func modeChecks(_ check: Checker) {
        check("mode: Reduce Motion on → Step", LEDMode.resolve(reduceMotion: true, forceScroll: false) == .step)
        check("mode: Reduce Motion off → Scroll", LEDMode.resolve(reduceMotion: false, forceScroll: false) == .scroll)
        check("mode: the switch forces Scroll with Reduce Motion on", LEDMode.resolve(reduceMotion: true, forceScroll: true) == .scroll)
        check("mode: the switch changes nothing with Reduce Motion off", LEDMode.resolve(reduceMotion: false, forceScroll: true) == .scroll)
        let before = UserDefaults.standard.object(forKey: LEDSettings.scrollKey)
        defer { if let before { UserDefaults.standard.set(before, forKey: LEDSettings.scrollKey) } else { UserDefaults.standard.removeObject(forKey: LEDSettings.scrollKey) } }
        UserDefaults.standard.removeObject(forKey: LEDSettings.scrollKey)
        check("mode: the Settings switch is off until the person turns it on", LEDSettings.forceScroll == false)
        UserDefaults.standard.set(true, forKey: LEDSettings.scrollKey)
        check("mode: the Settings switch reads its saved value", LEDSettings.forceScroll == true)
        UserDefaults.standard.set(false, forKey: LEDSettings.scrollKey)

        // The centre follows both.
        for (reduce, force, expect) in [(true, false, LEDMode.step), (false, false, .scroll), (true, true, .scroll)] {
            let clock = Clock()
            let center = LiveActivityCenter()
            let hub = LEDAnnouncements(center: center, env: clock.env(reduceMotion: reduce, forceScroll: force))
            hub.post("HELLO", tint: .orange)
            check("mode: the centre plays Reduce Motion \(reduce ? "on" : "off") with the switch \(force ? "on" : "off") as \(expect.rawValue)", hub.currentPlayback?.schedule.mode == expect, "\(String(describing: hub.currentPlayback?.schedule.mode))")
        }
        let clock = Clock()
        let hub = LEDAnnouncements(center: LiveActivityCenter(), env: clock.env(reduceMotion: true))
        hub.post("HELLO", tint: .orange, mode: .scroll)
        check("mode: a message can ask for its own mode (the debug command)", hub.currentPlayback?.schedule.mode == .scroll)
    }

    // MARK: 4. The queue

    private static func queueChecks(_ check: Checker) {
        let clock = Clock()
        let center = LiveActivityCenter()
        let hub = LEDAnnouncements(center: center, env: clock.env(reduceMotion: true))
        check("queue: no timer exists while nothing shows", clock.pending == 0 && !hub.isBusy)

        // A lower-priority agent wing is showing; the announcement takes the wings and gives them back.
        center.show(LiveActivity(id: "agents.main", kind: .agent, leading: { Text("a") }, trailing: { Text("b") }))
        hub.post("ALPHA", tint: .orange, symbol: "sparkles")
        hub.post("BETA", tint: .green)
        hub.post("GAMMA", tint: .blue, seconds: 3)
        check("queue: the first message shows at once, the others wait in order", hub.current?.text == "ALPHA" && hub.queue.map(\.text) == ["BETA", "GAMMA"])
        check("queue: it is an `announcement` activity in the centre, above the agents' wings", center.primary?.kind == .announcement && center.primary?.id == LEDAnnouncements.activityID
              && LiveActivityKind.announcement.defaultPriority > LiveActivityKind.agent.defaultPriority)
        check("queue: the kind has a title and a symbol, and a switch in Settings",
              LiveActivityKind.announcement.title == "Announcements" && !LiveActivityKind.announcement.symbol.isEmpty && LiveActivityKind.allCases.filter(\.listedInSettings).contains(.announcement))
        check("queue: only one timer runs while a message shows (its end)", clock.pending == 1)
        let alpha = hub.currentPlayback?.schedule.duration ?? 0
        let expires = center.activities.first { $0.id == LEDAnnouncements.activityID }?.expiresAt
        check("queue: the activity has its own expiry just after its natural end", expires.map { $0 > Date().addingTimeInterval(alpha) && $0 < Date().addingTimeInterval(alpha + 2.5) } ?? false)   // the centre's own expiry runs on the real clock
        let startA = clock.now
        clock.advance(by: alpha - 0.1)
        check("queue: it stays until its time is up", hub.current?.text == "ALPHA" && center.primary?.kind == .announcement)
        clock.advance(by: 0.15)
        check("queue: then the wing goes back to what it showed", center.primary?.id == "agents.main" && hub.current == nil)
        check("queue: a short gap, then the next message", hub.log.filter { $0.kind == .shown }.count == 1 && clock.pending == 1)
        clock.advance(by: LEDAnnouncements.gap - 0.2)
        check("queue: nothing shows during the gap", center.primary?.id == "agents.main" && hub.current == nil)
        clock.advance(by: 0.2)
        check("queue: the second message starts after the gap", hub.current?.text == "BETA" && hub.queue.map(\.text) == ["GAMMA"])
        let shown = hub.log.filter { $0.kind == .shown }
        let spacing = shown.count == 2 ? shown[1].at.timeIntervalSince(startA.addingTimeInterval(alpha)) : -1
        check("queue: the gap is exactly \(LEDAnnouncements.gap) s", abs(spacing - LEDAnnouncements.gap) < 0.01, "\(spacing)")
        let beta = hub.currentPlayback?.schedule.duration ?? 0
        clock.advance(by: beta + LEDAnnouncements.gap + 0.01)
        check("queue: the third message follows, shown for the seconds it asked", hub.current?.text == "GAMMA" && abs((hub.currentPlayback?.schedule.duration ?? 0) - 3) < 0.05)
        clock.advance(by: 3.05)
        check("queue: after the last one the wing is back and no timer is left", hub.current == nil && center.primary?.id == "agents.main" && clock.pending == 0 && !hub.isBusy)
        check("queue: the order shown was ALPHA, BETA, GAMMA", hub.log.filter { $0.kind == .shown }.map(\.text) == ["ALPHA", "BETA", "GAMMA"])

        // No repeat within 10 s.
        let t0 = clock.now
        hub.post("ALPHA", tint: .orange)
        check("repeat: the same text within 10 s of its last post is not shown again", hub.current == nil && hub.log.last?.kind == .skipped("repeat"))
        clock.advance(by: 20)
        hub.post("DELTA", tint: .orange)
        clock.advance(by: 3)
        hub.post("DELTA", tint: .orange)
        check("repeat: a text that is showing is not queued again", hub.queue.isEmpty && hub.log.last?.kind == .skipped("repeat"))
        clock.advance(by: 20)
        hub.post("DELTA", tint: .orange)
        check("repeat: after 10 s the same text is welcome again", hub.current?.text == "DELTA")
        _ = t0
        clock.advance(by: 12)
        hub.post("ECHO", tint: .orange)
        hub.post("ECHO", tint: .orange)
        check("repeat: a text already waiting is not queued twice", hub.queue.count + (hub.current?.text == "ECHO" ? 1 : 0) == 1)
        hub.post("ECHO", tint: .orange, repeating: true)
        check("repeat: the Test button may repeat a text", hub.queue.filter { $0.text == "ECHO" }.count == 1)
        hub.clear()
        check("clear: everything goes, the wing is back, no timer is left", hub.current == nil && hub.queue.isEmpty && center.primary?.id == "agents.main" && clock.pending == 0)

        // An open notch shows no wings: messages wait for it to close.
        let open = Clock()
        let openHub = LEDAnnouncements(center: LiveActivityCenter(), env: open.env())
        open.notchOpen = true
        openHub.post("WAITING", tint: .orange)
        check("open notch: a message waits while the notch is open, with no timer", openHub.current == nil && openHub.queue.count == 1 && open.pending == 0 && openHub.center.primary == nil && openHub.isBusy)
        open.advance(by: 10)
        openHub.resume()
        check("open notch: resuming while it is still open changes nothing", openHub.current == nil && openHub.queue.count == 1)
        open.notchOpen = false
        openHub.resume()
        check("open notch: when it closes the message plays", openHub.current?.text == "WAITING" && openHub.center.primary?.kind == .announcement)
        openHub.clear()
        open.notchOpen = true
        openHub.post("OLD NEWS", tint: .orange)
        open.advance(by: LEDAnnouncements.staleAfter + 5)
        open.notchOpen = false
        openHub.resume()
        check("open notch: a message that waited too long is dropped, not announced late", openHub.current == nil && openHub.queue.isEmpty && openHub.log.last?.kind == .skipped("stale"))
        // The queue is bounded.
        for i in 0..<14 { hub.post("MSG \(i)", tint: .orange) }
        check("queue: it never grows past \(LEDAnnouncements.queueLimit) waiting messages", hub.queue.count <= LEDAnnouncements.queueLimit && hub.current?.text == "MSG 0", "\(hub.queue.count)")
        hub.clear()
        hub.post("   ", tint: .orange)
        check("queue: an empty text posts nothing", hub.current == nil && hub.queue.isEmpty)

        // Scripted runs.
        let scripted = LEDAnnouncements(center: LiveActivityCenter(), env: clock.env(scripted: true))
        scripted.post("HELLO", tint: .orange)
        check("scripted: nothing shows in a scripted run by itself", scripted.current == nil && scripted.queue.isEmpty && scripted.center.primary == nil && scripted.log.last?.kind == .skipped("scripted"))
        scripted.allowInScriptedRuns = true
        scripted.post("HELLO", tint: .orange)
        check("scripted: it shows when a test or gallery asks", scripted.current?.text == "HELLO" && scripted.center.primary?.kind == .announcement)
    }

    // MARK: 5. New agents

    private static func session(_ name: String, kind: AgentKind = .claude) -> AgentSession {
        AgentSession(id: "led-\(name)", agent: kind, cwd: "/Users/you/Dev/\(name)")
    }

    private static func agentChecks(_ check: Checker) {
        let clock = Clock()
        let hub = LEDAnnouncements(center: LiveActivityCenter(), env: clock.env())
        var wenv = LEDAgentWatcher.Env()
        wenv.now = { [unowned clock] in clock.now }
        wenv.schedule = { [unowned clock] seconds, work in clock.schedule(seconds, work) }
        wenv.isScripted = false
        let watcher = LEDAgentWatcher(announcements: hub, env: wenv)
        func said() -> [String] { hub.log.filter { $0.kind == .shown }.map(\.text) }
        let hold = LEDAgentWatcher.welcomeHold + 0.5
        let byeHold = LEDAgentWatcher.byeHold + 0.5

        let site = session("site"), api = session("api", kind: .codex), notes = session("notes"), docs = session("docs", kind: .codex)
        // The first scan after launch: the baseline, never announced.
        watcher.process(sessions: [site, api], loaded: true)
        check("agents: the first scan's agents are not announced", said().isEmpty)
        clock.advance(by: 5)
        watcher.process(sessions: [site, api, notes], loaded: true)
        check("agents: nor is one that shows up in the 10 s after the first load", said().isEmpty)
        clock.advance(by: 6)
        watcher.process(sessions: [site, api, notes, docs], loaded: true)
        check("agents: a newcomer is not welcomed at once (it waits a few seconds)", said().isEmpty, "\(said())")
        clock.advance(by: hold)
        check("agents: a later one is welcomed in its kind's tint (WELCOME DOCS ♥)", said() == ["WELCOME DOCS \(LEDFont.heart)"] && hub.current?.tint == AgentKind.codex.tint && hub.currentPlayback?.tint == AgentKind.codex.tint, "\(said())")
        check("agents: and the right wing carries that kind's glyph", hub.current?.symbol == AgentKind.codex.symbol)
        watcher.process(sessions: [site, api, notes, docs], loaded: true)
        watcher.process(sessions: [docs, site, api, notes], loaded: true)
        check("agents: it is welcomed once", said().count == 1)

        clock.advance(by: 30)
        watcher.process(sessions: [site, notes, docs], loaded: true)
        check("agents: a goodbye waits (a restart would say only WELCOME)", said().count == 1, "\(said())")
        clock.advance(by: byeHold)
        check("agents: one that goes away gets its goodbye (BYE API)", said().last == "BYE API" && said().count == 2, "\(said())")
        clock.advance(by: 60)
        watcher.process(sessions: [site, api, notes, docs], loaded: true)
        check("agents: one that left and came back within 5 minutes is not welcomed again", said().count == 2, "\(said())")

        clock.advance(by: 30)
        watcher.process(sessions: [site, api, notes], loaded: true)
        clock.advance(by: byeHold)
        check("agents: DOCS leaves too (BYE DOCS)", said().last == "BYE DOCS" && said().count == 3)
        clock.advance(by: 320)
        watcher.process(sessions: [site, api, notes, docs], loaded: true)
        clock.advance(by: hold)
        check("agents: a session that wakes up again after more than 5 minutes is the same agent, not welcomed twice", said().last == "BYE DOCS" && said().count == 3, "\(said())")
        watcher.process(sessions: [site, api, notes], loaded: true)
        clock.advance(by: 7 * 3600)
        watcher.process(sessions: [site, api, notes, docs], loaded: true)
        clock.advance(by: hold)
        check("agents: after hours away it counts as new again", said().last == "WELCOME DOCS \(LEDFont.heart)" && said().count == 5, "\(said())")

        // Names are cut to 14 characters; every character the board can't draw is a dash.
        let longName = session("a_very_long_project_name_indeed")
        clock.advance(by: 20)
        watcher.process(sessions: [site, api, notes, docs, longName], loaded: true)
        clock.advance(by: hold)
        let longSaid = said().last ?? ""
        check("agents: a project name is cut to 14 characters", LEDAgentWatcher.label("a_very_long_project_name_indeed").count <= 14 && longSaid.hasPrefix("WELCOME A-VERY-LONG-PR"), longSaid)
        check("agents: and written in capitals", LEDAgentWatcher.label("notes") == "NOTES" && LEDAgentWatcher.label("my_site") == "MY-SITE")

        // A session that shows up already finished is never welcomed, and leaves without a goodbye.
        let base = [site, api, notes, docs, longName]
        let count = said().count
        var over = session("over")
        over.state = .waiting
        over.finishedAt = clock.now
        over.turnStartedAt = clock.now.addingTimeInterval(-300)
        clock.advance(by: 20)
        watcher.process(sessions: base + [over], loaded: true)
        clock.advance(by: hold)
        check("agents: one that shows up already finished is not welcomed", said().count == count, "\(said())")
        watcher.process(sessions: base, loaded: true)
        check("agents: and leaves without a goodbye", said().count == count, "\(said())")
        // A new session whose first turn is a quick answer comes and goes: no welcome, no goodbye.
        var quick = session("quick")
        quick.state = .working
        watcher.process(sessions: base + [quick], loaded: true)
        clock.advance(by: 2)
        quick.state = .waiting
        quick.finishedAt = clock.now
        quick.turnStartedAt = clock.now.addingTimeInterval(-2)
        watcher.process(sessions: base + [quick], loaded: true)
        clock.advance(by: hold)
        check("agents: a new session that answers within seconds is not welcomed", said().count == count, "\(said())")
        watcher.process(sessions: base, loaded: true)
        check("agents: and gets no goodbye either", said().count == count, "\(said())")
        // One that is gone before the hold is over is never welcomed.
        var blink = session("blink")
        blink.state = .working
        watcher.process(sessions: base + [blink], loaded: true)
        clock.advance(by: 2)
        watcher.process(sessions: base, loaded: true)
        clock.advance(by: hold)
        check("agents: one that is gone before its welcome gets neither welcome nor goodbye", said().count == count, "\(said())")
        // A session still at work after the hold is welcomed, with a long first turn finished later or not.
        var stays = session("stays")
        stays.state = .working
        watcher.process(sessions: base + [stays], loaded: true)
        clock.advance(by: hold)
        check("agents: one that is still there after the hold is welcomed (WELCOME STAYS ♥)", said().last == "WELCOME STAYS \(LEDFont.heart)" && said().count == count + 1, "\(said())")
        clock.advance(by: 30)
        watcher.process(sessions: base, loaded: true)
        clock.advance(by: byeHold)
        check("agents: and gets its goodbye", said().last == "BYE STAYS", "\(said())")
        // A restart: the agent's session goes and the same project comes back as a new session: WELCOME only, never BYE then WELCOME.
        let before = said().count
        var again = AgentSession(id: "led-stays-2", agent: .claude, cwd: "/Users/you/Dev/stays")
        again.state = .working
        var first = AgentSession(id: "led-stays-1", agent: .claude, cwd: "/Users/you/Dev/stays")
        first.state = .working
        clock.advance(by: 20)
        watcher.process(sessions: base + [first], loaded: true)
        clock.advance(by: hold)
        let welcomedFirst = said().count == before + 1
        clock.advance(by: 30)
        watcher.process(sessions: base, loaded: true)
        clock.advance(by: 8)
        watcher.process(sessions: base + [again], loaded: true)
        clock.advance(by: byeHold + hold)
        check("agents: a restarted agent (its project back as a new session) gets only WELCOME, no BYE", welcomedFirst && Array(said().dropFirst(before + 1)) == ["WELCOME STAYS \(LEDFont.heart)"], "\(said().dropFirst(before))")
        // One of two sessions of the same project closes: the project is still here, no goodbye.
        let count2 = said().count
        var twin = AgentSession(id: "led-stays-3", agent: .claude, cwd: "/Users/you/Dev/stays")
        twin.state = .working
        watcher.process(sessions: base + [again, twin], loaded: true)
        clock.advance(by: hold)
        watcher.process(sessions: base + [again], loaded: true)
        clock.advance(by: byeHold)
        check("agents: one of two sessions of a project closes: no goodbye (the project is still here)", !said().dropFirst(count2).contains("BYE STAYS"), "\(said().dropFirst(count2))")
        // An agent whose turn is over is put away after
        // five minutes while its chat may still be open; that is resting, not leaving: no goodbye. One that vanishes at work still gets it.
        do {
            let restHub = LEDAnnouncements(center: LiveActivityCenter(), env: clock.env())
            let rest = LEDAgentWatcher(announcements: restHub, env: wenv)
            func restSaid() -> [String] { restHub.log.filter { $0.kind == .shown }.map(\.text) }
            let other = session("other"), working = session("scout")
            var finished = session("scout")
            finished.state = .done
            finished.finishedAt = clock.now
            rest.process(sessions: [other, working], loaded: true)
            clock.advance(by: 11)
            rest.process(sessions: [other, working], loaded: true)
            rest.process(sessions: [other, finished], loaded: true)
            clock.advance(by: 330)
            rest.process(sessions: [other], loaded: true)
            clock.advance(by: byeHold)
            rest.process(sessions: [other], loaded: true)
            check("agents: one whose turn was over and that is put away (resting) gets no goodbye", !restSaid().contains { $0.hasPrefix("BYE") }, "\(restSaid())")
            let busy = session("busy")
            rest.process(sessions: [other, busy], loaded: true)
            clock.advance(by: hold)
            rest.process(sessions: [other, busy], loaded: true)
            clock.advance(by: 30)
            rest.process(sessions: [other], loaded: true)
            clock.advance(by: byeHold)
            rest.process(sessions: [other], loaded: true)
            check("  one that vanishes while at work still gets its goodbye (BYE BUSY)", restSaid().last == "BYE BUSY", "\(restSaid())")
        }
        watcher.process(sessions: base, loaded: true)

        // The first load that comes late: the fallback ends the baseline.
        let clock2 = Clock()
        let hub2 = LEDAnnouncements(center: LiveActivityCenter(), env: clock2.env())
        var wenv2 = LEDAgentWatcher.Env()
        wenv2.now = { [unowned clock2] in clock2.now }
        wenv2.schedule = { [unowned clock2] seconds, work in clock2.schedule(seconds, work) }
        wenv2.isScripted = false
        let watcher2 = LEDAgentWatcher(announcements: hub2, env: wenv2)
        watcher2.process(sessions: [site], loaded: false)
        clock2.advance(by: 4)
        watcher2.process(sessions: [site, notes], loaded: false)
        check("agents: before the first load shows, a newcomer is baseline", hub2.log.isEmpty)
        clock2.advance(by: 16)
        watcher2.process(sessions: [site, notes, docs], loaded: false)
        clock2.advance(by: hold)
        check("agents: if the first load never shows, the baseline ends by itself", hub2.log.filter { $0.kind == .shown }.map(\.text) == ["WELCOME DOCS \(LEDFont.heart)"])

        // A finished agent while the notch was in use.
        let clock3 = Clock()
        let hub3 = LEDAnnouncements(center: LiveActivityCenter(), env: clock3.env())
        var wenv3 = LEDAgentWatcher.Env()
        wenv3.now = { [unowned clock3] in clock3.now }
        wenv3.schedule = { [unowned clock3] seconds, work in clock3.schedule(seconds, work) }
        wenv3.isScripted = false
        let watcher3 = LEDAgentWatcher(announcements: hub3, env: wenv3)
        watcher3.process(sessions: [], loaded: true)
        clock3.advance(by: 11)
        var finished = session("docs")
        finished.state = .waiting
        finished.finishedAt = clock3.now
        var asking = session("infra", kind: .codex)
        asking.state = .waiting
        var working = session("site")
        working.state = .working
        let all = [finished, asking, working]
        watcher3.process(sessions: all, loaded: true)
        hub3.clear()
        watcher3.processFlashes(["led-docs"], sessions: all, loaded: true)
        check("agents: a finished agent whose row was lit is announced (DOCS DONE ✓)", hub3.current?.text == "DOCS DONE \(LEDFont.check)")
        hub3.clear()
        clock3.advance(by: 30)
        watcher3.processFlashes(["led-docs", "led-infra", "led-site"], sessions: all, loaded: true)
        check("agents: an agent that needs you or still works gets no DONE", hub3.current == nil && hub3.queue.isEmpty)
        watcher3.processFlashes(["led-docs", "led-infra", "led-site"], sessions: all, loaded: true)
        check("agents: a row that stays lit is announced once", hub3.current == nil)
        check("agents: DONE counts only after the baseline", { () -> Bool in
            let c = Clock()
            let h = LEDAnnouncements(center: LiveActivityCenter(), env: c.env())
            var e = LEDAgentWatcher.Env(); e.now = { [unowned c] in c.now }; e.schedule = { [unowned c] seconds, work in c.schedule(seconds, work) }; e.isScripted = false
            let w = LEDAgentWatcher(announcements: h, env: e)
            w.processFlashes(["led-docs"], sessions: all, loaded: true)
            return h.current == nil
        }())
    }

    // MARK: 6. The real wiring: a store's own changes reach the watcher

    private static func wiringChecks(_ check: Checker) async {
        let clock = Clock()
        let hub = LEDAnnouncements(center: LiveActivityCenter(), env: clock.env())
        var wenv = LEDAgentWatcher.Env()
        wenv.now = { [unowned clock] in clock.now }
        wenv.schedule = { [unowned clock] seconds, work in clock.schedule(seconds, work) }
        wenv.isScripted = false
        wenv.loaded = { _ in true }
        let watcher = LEDAgentWatcher(announcements: hub, env: wenv)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("led-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AgentsStore()   // its own, not the shared one: it never reads
        func settle() async { try? await Task.sleep(nanoseconds: 120_000_000) }
        func said() -> [String] { hub.log.filter { $0.kind == .shown }.map(\.text) }

        watcher.start(store: store)
        check("wiring: the watcher runs for a real run", watcher.isRunning)
        store.loadSessions([session("site")])
        await settle()
        clock.advance(by: 11)
        store.loadSessions([session("site"), session("notes")])
        await settle()
        clock.advance(by: LEDAgentWatcher.welcomeHold + 0.5)
        await settle()
        check("wiring: the store's own change makes a welcome", said() == ["WELCOME NOTES \(LEDFont.heart)"], "\(said())")
        clock.advance(by: 15)
        store.loadSessions([session("notes")])
        await settle()
        clock.advance(by: LEDAgentWatcher.byeHold + 0.5)
        await settle()
        check("wiring: and a goodbye", said().last == "BYE SITE", "\(said())")
        var done = session("notes")
        done.state = .waiting
        done.finishedAt = clock.now
        store.loadSessions([done])
        await settle()
        clock.advance(by: 15)
        store.flash("led-notes", seconds: 0.2)
        await settle()
        check("wiring: a lit row of a finished agent makes DONE", said().last == "NOTES DONE \(LEDFont.check)", "\(said())")
        // The real navigator: a message posted while the notch is open plays when it closes.
        let navigator = NotchNavigator()
        let watched = Clock()
        let watchedHub = LEDAnnouncements(center: LiveActivityCenter(), env: watched.env())
        watched.notchOpen = true
        navigator.isOpen = true
        watchedHub.watchNotch(navigator)
        watchedHub.post("AFTER CLOSE", tint: .orange)
        check("wiring: a message posted while the notch is open waits", watchedHub.current == nil && watchedHub.queue.count == 1)
        watched.notchOpen = false
        navigator.isOpen = false
        await settle()
        check("wiring: closing the notch plays it", watchedHub.current?.text == "AFTER CLOSE")
        watchedHub.clear()
        watcher.stop()
        clock.advance(by: 40)
        store.loadSessions([])
        await settle()
        check("wiring: a stopped watcher says nothing more", !said().contains("BYE NOTES"))
        store.clearFlashes()
    }

    // MARK: 7. The switch in Settings › Live Activities

    // MARK: 8. The plastic sign frame (the 90s look)

    private static func signFrameChecks(_ check: Checker) {
        let dots = CGFloat(LEDFont.rows) * LEDStyle.wingPitch
        check("sign frame: the dots keep their size (pitch 2.65 pt, seven rows) and fit the black plate with room to spare",
              LEDStyle.wingPitch == 2.65 && abs(dots - 18.55) < 1e-9 && dots < LEDStyle.signPlateHeight && LEDStyle.signPlateHeight < LEDStyle.wingHeight, "\(dots) in \(LEDStyle.signPlateHeight)")
        check("  the frame is the wing's height, so the closed notch's strip is as tall as before", LEDStyle.signSize(columns: 41).height == LEDStyle.wingHeight && LEDStyle.wingHeight == 22)
        check("  even seven letters (41 columns) fit the wing beside the notch", LEDStyle.signSize(columns: 41).width <= LEDStyle.wingRoom, "\(LEDStyle.signSize(columns: 41).width)")
        // The drawn wing has the size the numbers say: ask a hosting view how big the sign is.
        var playback = LEDPlayback(schedule: LEDSchedule(text: "WELCOME", mode: .step), start: Date(), tint: Retro.Ink.teal, frozenAt: nil)
        playback.frozenAt = playback.schedule.lightDuration(page: 0) + 0.3
        let columns = playback.frame(at: playback.start).columns.count
        let hosting = NSHostingView(rootView: LEDWingLeft(playback: playback))
        let fit = hosting.fittingSize
        let want = LEDStyle.signSize(columns: columns)
        // A hosting view rounds its size up to whole points, so the comparison allows one.
        check("  the drawn sign is that size (the letters were not shrunk to make room for the frame)", abs(fit.width - want.width) < 1 && abs(fit.height - want.height) < 1, "\(fit) vs \(want)")
        check("  a short message makes a short sign", LEDStyle.signSize(columns: 11).width < LEDStyle.signSize(columns: 41).width)
    }

    private static func switchChecks(_ check: Checker) {
        let key = LiveActivityKind.announcement.enabledKey
        let before = UserDefaults.standard.object(forKey: key)
        defer { if let before { UserDefaults.standard.set(before, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.removeObject(forKey: key)
        let clock = Clock()
        let center = LiveActivityCenter()
        let hub = LEDAnnouncements(center: center, env: clock.env())
        check("switch: Announcements is on until the person turns it off", center.isEnabled(.announcement))
        UserDefaults.standard.set(false, forKey: key)
        hub.post("HELLO", tint: .orange)
        check("switch: the kind switched off posts nothing", !center.isEnabled(.announcement) && hub.current == nil && hub.queue.isEmpty && center.activities.isEmpty && hub.log.last?.kind == .skipped("off") && clock.pending == 0)
        let watcherHub = LEDAnnouncements(center: center, env: clock.env())
        var wenv = LEDAgentWatcher.Env()
        wenv.now = { [unowned clock] in clock.now }
        wenv.isScripted = false
        let watcher = LEDAgentWatcher(announcements: watcherHub, env: wenv)
        watcher.process(sessions: [], loaded: true)
        clock.advance(by: 11)
        watcher.process(sessions: [session("site")], loaded: true)
        check("switch: a new agent is not welcomed on the board either", watcherHub.current == nil && center.activities.isEmpty)
        UserDefaults.standard.set(true, forKey: key)
        hub.post("HELLO", tint: .orange)
        hub.post("WORLD", tint: .orange)
        check("switch: back on, messages show", hub.current?.text == "HELLO" && center.primary?.kind == .announcement)
        UserDefaults.standard.set(false, forKey: key)
        clock.advance(by: (hub.currentPlayback?.schedule.duration ?? 0) + 0.1)
        clock.advance(by: LEDAnnouncements.gap + 0.1)
        check("switch: turned off while a message waited, the waiting one is dropped", hub.current == nil && hub.queue.isEmpty && center.primary == nil, "\(hub.current?.text ?? "-")")
        check("switch: nothing is left ticking", clock.pending == 0)
    }
}
