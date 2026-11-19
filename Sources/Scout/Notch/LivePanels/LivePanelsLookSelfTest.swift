import AppKit
import SwiftUI

// Part of `live.selftest`: each live panel in the 8-bit look and in the minimal look (the owner's switch, 2026-11-16). For each look the panel's real
// view is hosted offscreen and drawn: it must not be blank, the two looks must differ (so the switch really reaches the panel), and a real click on
// every control the panel marks (`liveControl`) must do its job (Stop, pause, Join, a to-do's circle, the radio's pause and stop). Synthetic data
// only; nothing shows on the screen, no service is read, no sound, no camera, no network.

@MainActor
enum LivePanelsLookTest {
    private struct Case {
        var name: String
        var cells: Int
        var make: () -> AnyView
        /// What the clicks did, as a number to compare with `expect` after every control has been clicked once.
        var done: () -> Int
        var expect: Int
    }

    static func run() async -> [[String: Any]] {
        var results: [[String: Any]] = []
        func note(_ name: String, _ checks: [(String, Bool)]) {
            let problems = checks.filter { !$0.1 }.map { "failed: \($0.0)" }
            results.append(["scenario": name, "pass": problems.isEmpty, "problems": problems])
        }

        let savedLook = UserDefaults.standard.object(forKey: Retro.styleKey)
        defer { Pref.set(savedLook, Retro.styleKey) }
        var pictures: [String: [Bool: Data]] = [:]

        for eightBit in [true, false] {
            Pref.set(eightBit, Retro.styleKey)
            let look = eightBit ? "8-bit" : "minimal"
            var stopped = 0, toggled = 0, joined = 0, completed = 0, paused = 0, radioStopped = 0
            let now = Date()
            let cases: [Case] = [
                Case(name: "recording", cells: 4, make: {
                    LiveRecordingPanel(feed: LiveFeed(LiveRecordingSnapshot(isRecording: true, startDate: now.addingTimeInterval(-754), withMic: true)), clock: { now }) { stopped += 1 }.makeView()
                }, done: { stopped }, expect: 1),
                Case(name: "timer", cells: 4, make: {
                    let timer = ClockTimer(label: "Tea", duration: 300, endDate: now.addingTimeInterval(187))
                    return LiveTimerPanel(feed: LiveFeed(LiveTimerSnapshot(timers: [timer])), clock: { now },
                                          actions: LiveTimerActions(toggleTimer: { _ in toggled += 1 }, togglePomodoro: {}, dismissEnded: { _ in })).makeView()
                }, done: { toggled }, expect: 1),
                Case(name: "meeting", cells: 4, make: {
                    let event = LiveSamples.event("Weekly planning", start: now.addingTimeInterval(11 * 60), length: 1800, link: LiveSamples.zoom)
                    return LiveMeetingPanel(feed: LiveFeed(LiveMeetingSnapshot(enabled: true, events: [event])), clock: { now }) { _ in joined += 1 }.makeView()
                }, done: { joined }, expect: 1),
                Case(name: "to-dos", cells: 4, make: {
                    let items = [LiveSamples.todo("Reply to Marta", days: 0), LiveSamples.todo("Book the dentist")]
                    return LiveTodosPanel(feed: LiveFeed(LiveTodosSnapshot(open: items))) { _ in completed += 1 }.makeView()
                }, done: { completed }, expect: 2),
                Case(name: "radio", cells: 4, make: {
                    let snapshot = RadioLiveSnapshot(station: "Aurora FM", place: "Reykjavik, Iceland", quality: "MP3 128k", song: "Cold Harbour - Northern Hours", state: .playing)
                    return RadioLivePanel(feed: LiveFeed(snapshot), actions: RadioLiveActions(togglePause: { paused += 1 }, stop: { radioStopped += 1 })).makeView()
                }, done: { paused * 10 + radioStopped }, expect: 11),
                Case(name: "downloads", cells: 4, make: {
                    LiveSamples.downloads(LiveDownloadsSnapshot(downloads: [LiveSamples.transfer("Quarterly report.pdf", fraction: 0.62, total: 48_000_000)])).makeView()
                }, done: { 0 }, expect: 0),
                Case(name: "bluetooth", cells: 4, make: {
                    LiveSamples.bluetooth([LiveSamples.connection(.airPodsPro)]).makeView()
                }, done: { 0 }, expect: 0),
            ]
            for c in cases {
                let rig = MiniBoomRig(c.make(), size: CGSize(width: CGFloat(c.cells) * NookMetrics.cell, height: NookMetrics.widgetHeight))
                try? await Task.sleep(nanoseconds: 350_000_000)
                let picture = rig.picture()
                pictures[c.name, default: [:]][eightBit] = picture?.bytes
                for rect in rig.controls { await rig.click(rect) }
                let controls = rig.controls.count
                let did = c.done()
                rig.close()
                note("live panel \(c.name), \(look) look: it draws, and its controls work", [
                    ("the \(look) look is the one drawing", Retro.is8bit == eightBit),
                    ("the panel is drawn (not blank)", (picture?.busy ?? 0) > 400),
                    ("a click on each marked control does its job", did == c.expect),
                    ("the controls are found: \(c.expect == 0 ? "none expected" : "some")", c.expect == 0 ? controls == 0 : controls > 0),
                ])
            }
        }
        for name in ["recording", "timer", "meeting", "to-dos", "radio", "downloads", "bluetooth"] {
            let both = pictures[name] ?? [:]
            note("live panel \(name): the minimal look is another picture than the 8-bit one", [
                ("both looks were drawn", both[true] != nil && both[false] != nil),
                ("the two pictures differ", both[true] != both[false]),
            ])
        }
        return results
    }
}
