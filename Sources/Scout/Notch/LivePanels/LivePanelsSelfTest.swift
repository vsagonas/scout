import AppKit
import SwiftUI

// `live.selftest?out=<file>`: runs synthetic scenarios against the live panels (which panels are live, in which order, how
// the clock moves them, that a tick alone never republishes) plus the Clock service's save and restore, and writes JSON.
// Nothing shows on the screen and no service of the owner's is read, except the last scenario that builds the real
// sources in a scripted run (sample data only).
//
// Run it headless, your own binary, stopped by pid:
//   build/Scout.app/Contents/MacOS/Scout --automation --headless --run "scout://live.selftest?out=/path/live.json" & PID=$!

@MainActor
private final class LiveWorldClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var fileThere: Set<String> = []   // names of finished downloads whose file exists
}

/// Six synthetic panels on hand-set feeds and a hand-set clock.
@MainActor
private final class LiveWorld {
    let time = LiveWorldClock()
    let recording = LiveFeed(LiveRecordingSnapshot())
    let meeting = LiveFeed(LiveMeetingSnapshot(enabled: true))
    let timer = LiveFeed(LiveTimerSnapshot())
    let downloads: LiveFeed<LiveDownloadsSnapshot>
    let bluetooth = LiveFeed<[BluetoothConnection]>([])
    let todos = LiveFeed(LiveTodosSnapshot())
    let panels: LivePanels
    let meetingPanel: LiveMeetingPanel
    let downloadsPanel: LiveDownloadsPanel
    var completed: [UUID] = []

    var now: Date { time.now }

    init() {
        let time = self.time
        let clock: () -> Date = { time.now }
        downloads = LiveFeed(LiveDownloadsSnapshot(), merge: LiveDownloadsPanel.merge(finished: { time.fileThere.contains($0.name) }, clock: clock))
        let recordingPanel = LiveRecordingPanel(feed: recording, clock: clock) {}
        meetingPanel = LiveMeetingPanel(feed: meeting, clock: clock) { _ in }
        let timerPanel = LiveTimerPanel(feed: timer, clock: clock, actions: LiveSamples.noActions)
        downloadsPanel = LiveDownloadsPanel(feed: downloads, clock: clock)
        let bluetoothPanel = LiveBluetoothPanel(feed: bluetooth, clock: clock)
        let todosPanel = LiveTodosPanel(feed: todos) { _ in }
        panels = LivePanels(sources: [recordingPanel, meetingPanel, timerPanel, downloadsPanel, bluetoothPanel, todosPanel], now: clock, heartbeat: false)
    }

    func event(_ title: String, start: TimeInterval, length: TimeInterval, link: String? = nil, allDay: Bool = false) -> CalEvent {
        LiveSamples.event(title, start: now.addingTimeInterval(start), length: length, link: link, allDay: allDay)
    }

    func todo(_ title: String, days: Int? = nil) -> LiveTodo {
        let today = Calendar.current.startOfDay(for: now)
        return LiveTodo(id: UUID(), title: title, day: days.flatMap { Calendar.current.date(byAdding: .day, value: $0, to: today) })
    }

    func connection(_ info: BluetoothInfo, ago: TimeInterval) -> BluetoothConnection {
        BluetoothConnection(info: info, since: ago >= 1e9 ? .distantPast : now.addingTimeInterval(-ago))
    }
}

@MainActor
enum LivePanelsSelfTest {
    static func register() {
        DebugCommands.register("live.selftest") { params in
            guard ScoutRuntime.isAutomation else { return }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("live-selftest.json")
            Task { @MainActor in
                let json = await run()
                try? json.write(to: out, atomically: true, encoding: .utf8)
            }
        }
    }

    private static let rec = "live.recording", meet = "live.meeting", timer = "live.timer", downloads = "live.downloads"
    private static let blue = "live.bluetooth", todos = "live.todos"
    private static let long: TimeInterval = 1e9   // "already connected before Scout looked"

    static func run() async -> String {
        var results: [[String: Any]] = []
        var w = LiveWorld()

        func fresh() { w.panels.stop(); w = LiveWorld() }
        func step(_ name: String, _ expect: [String], also: @autoclosure () -> [(String, Bool)] = []) {
            w.panels.recompute()
            let got = w.panels.live.map(\.id)
            var problems: [String] = got == expect ? [] : ["order was \(got)"]
            problems += also().filter { !$0.1 }.map { "failed: \($0.0)" }
            results.append(["scenario": name, "live": got, "expected": expect, "pass": problems.isEmpty, "problems": problems])
        }
        func note(_ name: String, _ checks: [(String, Bool)]) {
            let problems = checks.filter { !$0.1 }.map { "failed: \($0.0)" }
            results.append(["scenario": name, "pass": problems.isEmpty, "problems": problems])
        }

        // 1. Nothing is happening: nothing is live.
        step("nothing live", [])

        // 2. A recording, a meeting in progress and to-dos: recording first (100), then the meeting (90), then to-dos (10).
        w.recording.set(LiveRecordingSnapshot(isRecording: true, startDate: w.now.addingTimeInterval(-60), withMic: true))
        w.meeting.set(LiveMeetingSnapshot(enabled: true, events: [w.event("Design review", start: -600, length: 1800, link: LiveSamples.zoom)]))
        w.todos.set(LiveTodosSnapshot(open: [w.todo("Reply"), w.todo("Book the dentist")]))
        step("recording + meeting now + to-dos", [rec, meet, todos], also: [
            ("meeting priority 90 while in progress", w.meetingPanel.priority == 90),
            ("meeting opens the calendar", w.meetingPanel.expandTo == .calendar),
            ("recording opens nothing", w.panels.all.first { $0.id == rec }?.expandTo == nil),
        ])

        // 3. The meeting enters its hour, starts, ends: the clock alone moves it.
        fresh()
        w.meeting.set(LiveMeetingSnapshot(enabled: true, events: [w.event("Weekly planning", start: 61 * 60, length: 1800, link: LiveSamples.meet)]))
        step("meeting 61 min away: not yet", [])
        w.time.now += 2 * 60
        step("meeting 59 min away: live, priority 70", [meet], also: [("priority 70", w.meetingPanel.priority == 70),
                                                                         ("wakes at its start", w.meetingPanel.nextWake(after: w.now) != nil)])
        w.time.now += 59 * 60
        step("meeting started: priority 90", [meet], also: [("priority 90", w.meetingPanel.priority == 90)])
        w.time.now += 31 * 60
        step("meeting over", [])

        // 4. What never counts as a meeting.
        fresh()
        w.meeting.set(LiveMeetingSnapshot(enabled: false, events: [w.event("Standup", start: 300, length: 900)]))
        step("calendar off: never live", [])
        w.meeting.set(LiveMeetingSnapshot(enabled: true, events: [w.event("Holiday", start: -3600, length: 86_400, allDay: true)]))
        step("all-day event: not a meeting", [])
        w.meeting.set(LiveMeetingSnapshot(enabled: true, events: [w.event("Working hours", start: -3600, length: 9 * 3600)]))
        step("event of 9 hours: not a meeting", [])

        // 5. Two meetings overlap: the one with a call link.
        w.meeting.set(LiveMeetingSnapshot(enabled: true, events: [w.event("Desk time", start: -1200, length: 3600),
                                                                  w.event("Sync call", start: -300, length: 1800, link: LiveSamples.zoom)]))
        step("overlapping meetings: the one with a call link", [meet], also: [
            ("picked the call", LiveMeetingPanel.pick(w.meeting.value, now: w.now)?.event.title == "Sync call")])

        // 6. Timers and the Pomodoro.
        fresh()
        w.timer.set(LiveTimerSnapshot(timers: [ClockTimer(label: "Laundry", duration: 2400, endDate: nil, pausedRemaining: 1500)]))
        step("timer paused: still live", [timer], also: [("shows as paused", LiveTimerPanel.shown(w.timer.value, now: w.now)?.endDate == nil)])
        w.timer.set(LiveTimerSnapshot(pomodoro: PomodoroState(phase: .work, endDate: nil, pausedRemaining: 600, sessions: 1)))
        step("Pomodoro paused: live", [timer], also: [("shows the Pomodoro", LiveTimerPanel.shown(w.timer.value, now: w.now)?.symbol == "leaf")])
        w.timer.set(LiveTimerSnapshot(timers: [ClockTimer(label: "Tea", duration: 300, endDate: w.now.addingTimeInterval(100)),
                                               ClockTimer(label: "Soon", duration: 60, endDate: w.now.addingTimeInterval(30))]))
        step("two timers: the soonest, one more", [timer], also: [
            ("soonest first", LiveTimerPanel.shown(w.timer.value, now: w.now)?.label == "Soon"),
            ("one more", LiveTimerPanel.shown(w.timer.value, now: w.now)?.more == 1)])
        w.timer.set(LiveTimerSnapshot())
        step("timer cancelled", [])

        // 7. Priority order of the middle panels.
        w.timer.set(LiveTimerSnapshot(timers: [ClockTimer(label: "Tea", duration: 300, endDate: w.now.addingTimeInterval(100))]))
        w.downloads.set(LiveDownloadsSnapshot(downloads: [LiveSamples.transfer("Setup.dmg", fraction: 0.4)]))
        w.todos.set(LiveTodosSnapshot(open: [w.todo("Reply")]))
        step("timer, downloads, to-dos in priority order", [timer, downloads, todos])

        // 8. Downloads: running, finishing with its file, finishing without it, conversions.
        fresh()
        w.downloads.set(LiveDownloadsSnapshot(downloads: [LiveSamples.transfer("Quarterly report.pdf", fraction: 0.5)]))
        step("download running", [downloads], also: [("opens nothing", w.downloadsPanel.expandTo == nil)])
        w.time.fileThere = ["Quarterly report.pdf"]
        w.downloads.set(LiveDownloadsSnapshot())
        step("download finished: 'Done' for a moment", [downloads], also: [("Done names the file", w.downloads.value.done?.name == "Quarterly report.pdf")])
        w.time.now += 3
        step("Done after 3 s: still there", [downloads])
        w.time.now += 2
        step("Done after 5 s: gone", [])
        w.time.fileThere = []
        w.downloads.set(LiveDownloadsSnapshot(downloads: [LiveSamples.transfer("Cancelled.zip", fraction: 0.2)]))
        w.downloads.set(LiveDownloadsSnapshot())
        step("download cancelled (no file): gone at once", [])
        w.downloads.set(LiveDownloadsSnapshot(conversions: 2))
        step("conversions only: live, opens the Tray", [downloads], also: [("expandTo tray", w.downloadsPanel.expandTo == .tray)])
        w.downloads.set(LiveDownloadsSnapshot(downloads: [LiveSamples.transfer("Setup.dmg", fraction: 0.4)], conversions: 1))
        step("download + conversion: opens nothing", [downloads], also: [("expandTo nil", w.downloadsPanel.expandTo == nil)])

        // 9. Bluetooth.
        fresh()
        w.bluetooth.set([w.connection(.airPodsPro, ago: 2)])
        step("headset connected a moment ago", [blue])
        w.time.now += 61
        step("a minute later: gone", [])
        w.bluetooth.set([w.connection(BluetoothInfo(name: "Magic Keyboard", kind: .keyboard, single: 15), ago: long)])
        step("keyboard battery 15 %", [blue])
        w.bluetooth.set([w.connection(BluetoothInfo(name: "Magic Keyboard", kind: .keyboard, single: 50), ago: long)])
        step("keyboard battery 50 %: gone", [])
        w.bluetooth.set([w.connection(BluetoothInfo(name: "AirPods Pro", kind: .airPodsPro, left: 90, right: 90, caseLevel: 10), ago: long)])
        step("only the case is low: not an alarm", [])
        w.bluetooth.set([w.connection(BluetoothInfo(name: "AirPods Pro", kind: .airPodsPro, left: 12, right: 90, caseLevel: 60), ago: long)])
        step("one earbud at 12 %", [blue])
        w.bluetooth.set([w.connection(BluetoothInfo(name: "Magic Mouse", kind: .mouse, single: 80), ago: 2)])
        step("a mouse connecting is not a headset", [])

        // 10. To-dos only.
        fresh()
        w.todos.set(LiveTodosSnapshot(open: [w.todo("Later", days: 3), w.todo("Today", days: 0), w.todo("Overdue", days: -2), w.todo("No day")]))
        let order = LiveTodosPanel.ordered(w.todos.value.open, now: w.now).map(\.title)
        step("to-dos only", [todos], also: [("overdue, today, undated, later", order == ["Overdue", "Today", "No day", "Later"])])
        w.todos.set(LiveTodosSnapshot())
        step("all to-dos done", [])

        // 11. Everything at once, then: ticks never republish, a change republishes once.
        fresh()
        w.recording.set(LiveRecordingSnapshot(isRecording: true, startDate: w.now, withMic: false))
        w.meeting.set(LiveMeetingSnapshot(enabled: true, events: [w.event("Review", start: -60, length: 1800, link: LiveSamples.zoom)]))
        w.timer.set(LiveTimerSnapshot(timers: [ClockTimer(label: "Tea", duration: 300, endDate: w.now.addingTimeInterval(500))]))
        w.downloads.set(LiveDownloadsSnapshot(downloads: [LiveSamples.transfer("Setup.dmg", fraction: 0.4)]))
        w.bluetooth.set([w.connection(.airPodsPro, ago: 5)])
        w.todos.set(LiveTodosSnapshot(open: [w.todo("Reply")]))
        step("all six, in priority order", [rec, meet, timer, downloads, blue, todos])
        let before = w.panels.publishCount
        for _ in 0..<5 { w.time.now += 1; w.panels.recompute() }
        note("ticks alone never republish", [("publish count unchanged", w.panels.publishCount == before)])
        w.todos.set(LiveTodosSnapshot())
        step("last to-do done: one republish", [rec, meet, timer, downloads, blue], also: [("exactly one more publish (was \(before), now \(w.panels.publishCount))", w.panels.publishCount == before + 1)])
        w.panels.recompute()
        note("recompute with nothing new", [("still one more publish", w.panels.publishCount == before + 1)])

        // 12. A feed that changes reaches the coordinator on its own (no recompute call).
        fresh()
        w.todos.set(LiveTodosSnapshot(open: [w.todo("Reply")]))
        try? await Task.sleep(nanoseconds: 250_000_000)
        note("a feed change republishes by itself", [("to-dos live without recompute", w.panels.live.map(\.id) == [todos])])
        w.panels.stop()

        // 13. The Clock service saves timers, stopwatch and Pomodoro, and restores them at the next launch.
        results += await clockSaveRestore()

        // 14. The real sources in a scripted run: sample data only (the to-dos), nothing else is happening.
        let real = LivePanels()
        note("real sources, scripted run: only the sample to-dos (the radio is silent)", [("live == [todos]", real.live.map(\.id) == [todos]),
                                                                    ("seven sources, radio among them", real.all.count == 7 && real.all.contains { $0.id == "live.radio" })])
        real.stop()
        w.panels.stop()

        // 15. Every panel in the 8-bit look and in the minimal look: drawn, the two differ, and its controls work.
        results += await LivePanelsLookTest.run()

        let passed = results.filter { $0["pass"] as? Bool == true }.count
        let report: [String: Any] = ["ok": passed == results.count, "passed": passed, "failed": results.count - passed, "scenarios": results]
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Clock: save, relaunch, restore

    private static func clockSaveRestore() async -> [[String: Any]] {
        var results: [[String: Any]] = []
        func note(_ name: String, _ checks: [(String, Bool)]) {
            let problems = checks.filter { !$0.1 }.map { "failed: \($0.0)" }
            results.append(["scenario": name, "pass": problems.isEmpty, "problems": problems])
        }
        func settle() async { try? await Task.sleep(nanoseconds: 300_000_000) }

        let file = JSONFile<ClockSaved>("live-selftest-clock.json")
        try? FileManager.default.removeItem(at: file.url)
        defer { try? FileManager.default.removeItem(at: file.url) }

        // "Before the quit": a timer for 5 min, one for an hour, a paused one, a Pomodoro focus, a running stopwatch with a lap.
        let t0 = Date()
        let first = ClockService(demo: true, stateFile: file)
        first.addTimer(seconds: 300, label: "Tea")
        first.addTimer(seconds: 3600, label: "Laundry")
        let paused = first.addTimer(seconds: 1800, label: "Paused one", start: false)
        first.startPomodoro()
        first.toggleStopwatch()
        first.lapStopwatch()
        await settle()

        // Relaunch at once: everything is as it was.
        let again = ClockService(demo: true, stateFile: file, restoreAt: Date())
        let sameRunning = zip(first.timers.filter(\.isRunning), again.timers.filter(\.isRunning)).allSatisfy {
            abs(($0.endDate ?? .distantPast).timeIntervalSince($1.endDate ?? .distantFuture)) < 1.5 && $0.label == $1.label
        }
        note("clock: relaunch at once restores timers, stopwatch, Pomodoro", [
            ("three timers", again.timers.count == 3),
            ("labels", again.timers.map(\.label) == first.timers.map(\.label)),
            ("running ones keep their end dates", sameRunning),
            ("paused one keeps its remaining time", again.timers.first { $0.id == paused.id }.map { $0.isPaused && abs(($0.pausedRemaining ?? 0) - 1800) < 2 } == true),
            ("Pomodoro running with its end date", again.pomodoro.isRunning && abs((again.pomodoro.endDate ?? .distantPast).timeIntervalSince(first.pomodoro.endDate ?? .distantFuture)) < 1.5),
            ("stopwatch running with its lap", again.stopwatch.isRunning && again.stopwatch.laps.count == 1),
            ("nothing marked finished", again.ended.isEmpty),
            ("no ringing", again.ringing.isEmpty),
        ])
        await settle()

        // Relaunch ten minutes later: the 5-minute timer ended while Scout was closed; the rest continues.
        let later = ClockService(demo: true, stateFile: file, restoreAt: t0.addingTimeInterval(10 * 60))
        note("clock: a timer that ended while closed is marked finished, quietly", [
            ("Tea is finished", later.ended.map(\.title) == ["Tea"]),
            ("Tea is gone from the running timers", later.timers.map(\.label) == ["Laundry", "Paused one"]),
            ("Pomodoro continues", later.pomodoro.isRunning),
            ("no sound or ringing", later.ringing.isEmpty),
        ])
        let nowLater = t0.addingTimeInterval(10 * 60)
        let panelState = LiveTimerSnapshot(timers: later.timers, pomodoro: later.pomodoro, pomodoroTotal: later.duration(of: later.pomodoro.phase), ended: later.ended)
        let shown = LiveTimerPanel.shown(panelState, now: nowLater)
        note("clock: the timer panel shows the finished timer for a minute", [
            ("finished first", shown?.finished?.title == "Tea"),
            ("others still running", shown?.more == 3),
            ("gone after 61 s", LiveTimerPanel.shown(panelState, now: nowLater.addingTimeInterval(61))?.finished == nil),
        ])
        await settle()

        // Relaunch two hours later: the hour timer and the Pomodoro focus ended too; the paused timer is untouched.
        let muchLater = ClockService(demo: true, stateFile: file, restoreAt: t0.addingTimeInterval(2 * 3600))
        note("clock: relaunch two hours later", [
            ("Laundry and the focus session finished", Set(muchLater.ended.map(\.title)) == ["Laundry", "Focus session"]),
            ("paused timer untouched", muchLater.timers.map(\.label) == ["Paused one"] && muchLater.timers.first.map { abs(($0.pausedRemaining ?? 0) - 1800) < 2 } == true),
            ("Pomodoro moved on to a break, one session counted", muchLater.pomodoro.phase == .shortBreak && muchLater.pomodoro.sessions == 1 && !muchLater.pomodoro.isActive),
            ("stopwatch still counts", muchLater.stopwatch.isRunning),
            ("no ringing", muchLater.ringing.isEmpty),
        ])
        await settle()

        // The user dismisses a finished line.
        let id = muchLater.ended.first?.id ?? ""
        muchLater.dismissEnded(id)
        note("clock: dismissing a finished line", [("one left", muchLater.ended.count == 1)])
        return results
    }
}
