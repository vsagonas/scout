import SwiftUI

// Gallery scenes for the live panels (names start with `live-`): every panel with its edge cases, drawn at the dashboard's
// real size (span × 50 pt wide, 140 pt tall, 20 pt corners) on a stand-in for the open island, in light and dark.
// All data here is synthetic.

/// Synthetic panels for galleries and self-tests: nothing reads a service.
@MainActor
enum LiveSamples {
    static let zoom = "https://zoom.us/j/9988776655"
    static let meet = "https://meet.google.com/abc-defg-hij"

    static func event(_ title: String, start: Date, length: TimeInterval, link: String? = nil, color: String = "#3B82F6", allDay: Bool = false) -> CalEvent {
        CalEvent(id: "sample-\(title)-\(Int(start.timeIntervalSince1970))", title: title, start: start, end: start.addingTimeInterval(length), isAllDay: allDay,
                 location: link, notes: nil, url: nil, calendarID: "Work", calendarTitle: "Work", colorHex: color)
    }

    static func meeting(_ events: [CalEvent], enabled: Bool = true, clock: @escaping () -> Date = Date.init) -> LiveMeetingPanel {
        LiveMeetingPanel(feed: LiveFeed(LiveMeetingSnapshot(enabled: enabled, events: events)), clock: clock) { _ in }
    }

    static func transfer(_ name: String, fraction: Double?, total: Int64 = 480_000_000) -> LiveTransfer {
        LiveTransfer(id: "/sample/\(name)", name: name, bytes: Int64(Double(total) * (fraction ?? 0.37)), total: fraction == nil ? nil : total, speed: 8_000_000)
    }

    static func downloads(_ snapshot: LiveDownloadsSnapshot, clock: @escaping () -> Date = Date.init) -> LiveDownloadsPanel {
        LiveDownloadsPanel(feed: LiveFeed(snapshot, merge: LiveDownloadsPanel.merge(finished: { _ in true }, clock: clock)), clock: clock)
    }

    static func recording(mic: Bool, since: TimeInterval = 754, clock: @escaping () -> Date = Date.init) -> LiveRecordingPanel {
        let snapshot = LiveRecordingSnapshot(isRecording: true, startDate: clock().addingTimeInterval(-since), withMic: mic)
        return LiveRecordingPanel(feed: LiveFeed(snapshot), clock: clock) {}
    }

    static func bluetooth(_ connections: [BluetoothConnection], clock: @escaping () -> Date = Date.init) -> LiveBluetoothPanel {
        LiveBluetoothPanel(feed: LiveFeed(connections), clock: clock)
    }

    static func connection(_ info: BluetoothInfo, ago: TimeInterval = 8, clock: () -> Date = Date.init) -> BluetoothConnection {
        BluetoothConnection(info: info, since: clock().addingTimeInterval(-ago))
    }

    static let noActions = LiveTimerActions(toggleTimer: { _ in }, togglePomodoro: {}, dismissEnded: { _ in })

    static func timer(_ snapshot: LiveTimerSnapshot, clock: @escaping () -> Date = Date.init) -> LiveTimerPanel {
        LiveTimerPanel(feed: LiveFeed(snapshot), clock: clock, actions: noActions)
    }

    static func todos(_ items: [LiveTodo], clock: @escaping () -> Date = Date.init) -> LiveTodosPanel {
        LiveTodosPanel(feed: LiveFeed(LiveTodosSnapshot(open: items))) { _ in }
    }

    static func todo(_ title: String, days: Int? = nil) -> LiveTodo {
        let today = Calendar.current.startOfDay(for: Date())
        return LiveTodo(id: UUID(), title: title, day: days.flatMap { Calendar.current.date(byAdding: .day, value: $0, to: today) })
    }
}

/// The open island's floor with panels on it: tiles the way the dashboard draws them.
struct LiveStage: View {
    let panels: [any LivePanelSource]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: NookMetrics.spacing) {
            ForEach(panels, id: \.id) { panel in
                panel.makeView()
                    .frame(width: CGFloat(panel.span) * NookMetrics.cell, height: NookMetrics.widgetHeight)
                    .nookPanelFace()
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(scheme == .dark ? Color.black : Color(white: 0.96)))
        .padding(6)
    }
}

@MainActor
enum LivePanelsGallery {
    private static func size(_ cells: Int) -> CGSize {
        CGSize(width: CGFloat(cells) * NookMetrics.cell + 40, height: NookMetrics.widgetHeight + 40)
    }

    private static func add(_ name: String, cells: Int = 4, _ panels: @escaping @MainActor () -> [any LivePanelSource]) {
        Gallery.register("live-\(name)", size: size(cells), backdrop: .wallpaper) { LiveStage(panels: panels()) }
    }

    static func register() {
        registerMeeting()
        registerDownloads()
        registerRecordingAndBluetooth()
        registerTimerAndTodos()
        // Three panels side by side at the real size: a meeting, a download and a timer (12 cells, 8 pt between).
        Gallery.register("live-row", size: CGSize(width: 12 * NookMetrics.cell + 2 * NookMetrics.spacing + 40, height: NookMetrics.widgetHeight + 40)) {
            LiveStage(panels: [
                LiveSamples.meeting([LiveSamples.event("Weekly planning", start: Date().addingTimeInterval(11 * 60 + 40), length: 1800, link: LiveSamples.zoom)]),
                LiveSamples.downloads(LiveDownloadsSnapshot(downloads: [LiveSamples.transfer("Scout-1.0.zip", fraction: 0.43)])),
                LiveSamples.timer(LiveTimerSnapshot(timers: [ClockTimer(label: "Tea", duration: 300, endDate: Date().addingTimeInterval(187.6))])),
            ])
        }
        // All six at once at the widest the dashboard will show: 24 cells.
        Gallery.register("live-row-all", size: CGSize(width: 24 * NookMetrics.cell + 5 * NookMetrics.spacing + 40, height: NookMetrics.widgetHeight + 40)) {
            LiveStage(panels: allSix())
        }
    }

    static func allSix() -> [any LivePanelSource] {
        let now = Date()
        return [
            LiveSamples.recording(mic: true),
            LiveSamples.meeting([LiveSamples.event("Design review", start: now.addingTimeInterval(-10 * 60), length: 30 * 60, link: LiveSamples.meet, color: "#A855F7")]),
            LiveSamples.timer(LiveTimerSnapshot(pomodoro: PomodoroState(phase: .work, endDate: now.addingTimeInterval(14 * 60 + 12.6), sessions: 2), pomodoroTotal: 25 * 60)),
            LiveSamples.downloads(LiveDownloadsSnapshot(downloads: [LiveSamples.transfer("Quarterly report.pdf", fraction: 0.62, total: 48_000_000)])),
            LiveSamples.bluetooth([LiveSamples.connection(.airPodsPro)]),
            LiveSamples.todos([LiveSamples.todo("Reply to Marta", days: 0), LiveSamples.todo("Book the dentist")]),
        ]
    }

    // MARK: Meeting

    private static func registerMeeting() {
        add("meeting-soon") {
            [LiveSamples.meeting([LiveSamples.event("Weekly planning", start: Date().addingTimeInterval(11 * 60 + 40), length: 1800, link: LiveSamples.zoom)])]
        }
        add("meeting-now") {
            [LiveSamples.meeting([LiveSamples.event("Design review", start: Date().addingTimeInterval(-10 * 60), length: 30 * 60, link: LiveSamples.meet, color: "#A855F7")])]
        }
        add("meeting-long-title") {
            [LiveSamples.meeting([LiveSamples.event("Quarterly roadmap and budget review with the platform, design and growth leads", start: Date().addingTimeInterval(25 * 60 + 20),
                                                    length: 3600, link: LiveSamples.zoom, color: "#F97316")])]
        }
        add("meeting-no-link") {
            [LiveSamples.meeting([LiveSamples.event("Lunch with Maya", start: Date().addingTimeInterval(8 * 60 + 30), length: 3600, color: "#22C55E")])]
        }
        add("meeting-last-minute") {
            [LiveSamples.meeting([LiveSamples.event("Standup", start: Date().addingTimeInterval(44.5), length: 900, link: LiveSamples.zoom)])]
        }
        add("meeting-long-left") {
            [LiveSamples.meeting([LiveSamples.event("Workshop", start: Date().addingTimeInterval(-20 * 60), length: 2 * 3600 + 3000, link: LiveSamples.meet)])]
        }
    }

    // MARK: Downloads

    private static func registerDownloads() {
        add("downloads-one") {
            [LiveSamples.downloads(LiveDownloadsSnapshot(downloads: [LiveSamples.transfer("Quarterly report.pdf", fraction: 0.43, total: 48_000_000)]))]
        }
        add("downloads-long-name") {
            [LiveSamples.downloads(LiveDownloadsSnapshot(downloads: [LiveSamples.transfer("Annual-financial-statements-and-board-minutes-2026-final-v3.pdf", fraction: 0.8, total: 120_000_000)]))]
        }
        add("downloads-many") {
            [LiveSamples.downloads(LiveDownloadsSnapshot(downloads: [
                LiveSamples.transfer("Scout-1.0.zip", fraction: 0.64, total: 75_000_000),
                LiveSamples.transfer("Holiday photos.zip", fraction: 0.2, total: 900_000_000),
                LiveSamples.transfer("Setup.dmg", fraction: 0.05, total: 300_000_000),
            ]))]
        }
        add("downloads-unknown-size") {
            [LiveSamples.downloads(LiveDownloadsSnapshot(downloads: [LiveSamples.transfer("Unconfirmed 481726.crdownload", fraction: nil)]))]
        }
        add("downloads-convert") {
            [LiveSamples.downloads(LiveDownloadsSnapshot(conversions: 1))]
        }
        add("downloads-convert-many") {
            [LiveSamples.downloads(LiveDownloadsSnapshot(conversions: 3))]
        }
        add("downloads-mixed") {
            [LiveSamples.downloads(LiveDownloadsSnapshot(downloads: [LiveSamples.transfer("Scout-1.0.zip", fraction: 0.9, total: 75_000_000)], conversions: 2))]
        }
        add("downloads-done") {
            [LiveSamples.downloads(LiveDownloadsSnapshot(done: LiveSamples.transfer("Quarterly report.pdf", fraction: 1, total: 48_000_000), doneAt: Date()))]
        }
    }

    // MARK: Recording, Bluetooth

    private static func registerRecordingAndBluetooth() {
        add("recording") { [LiveSamples.recording(mic: true)] }
        add("recording-no-mic") { [LiveSamples.recording(mic: false, since: 3725)] }
        add("bluetooth-airpods") { [LiveSamples.bluetooth([LiveSamples.connection(.airPodsPro)])] }
        add("bluetooth-low") {
            [LiveSamples.bluetooth([LiveSamples.connection(BluetoothInfo(name: "AirPods Pro", kind: .airPodsPro, left: 14, right: 41, caseLevel: 8), ago: 3600)])]
        }
        add("bluetooth-keyboard-low") {
            [LiveSamples.bluetooth([LiveSamples.connection(BluetoothInfo(name: "Magic Keyboard", kind: .keyboard, single: 12), ago: 3600)])]
        }
        add("bluetooth-headphones") {
            [LiveSamples.bluetooth([LiveSamples.connection(BluetoothInfo(name: "AirPods Max", kind: .airPodsMax, single: 71))])]
        }
        add("bluetooth-no-battery") {
            [LiveSamples.bluetooth([LiveSamples.connection(BluetoothInfo(name: "Sound Blaster Pro Wireless Headset", kind: .headphones))])]
        }
        add("bluetooth-two") {
            [LiveSamples.bluetooth([LiveSamples.connection(.airPodsPro), LiveSamples.connection(BluetoothInfo(name: "Magic Mouse", kind: .mouse, single: 9), ago: 7200)])]
        }
    }

    // MARK: Timer, to-dos

    private static func registerTimerAndTodos() {
        add("timer-running") {
            [LiveSamples.timer(LiveTimerSnapshot(timers: [ClockTimer(label: "Tea", duration: 300, endDate: Date().addingTimeInterval(187.6))]))]
        }
        add("timer-paused") {
            [LiveSamples.timer(LiveTimerSnapshot(timers: [ClockTimer(label: "Laundry", duration: 2400, endDate: nil, pausedRemaining: 1500)]))]
        }
        add("timer-no-label") {
            [LiveSamples.timer(LiveTimerSnapshot(timers: [ClockTimer(label: "", duration: 600, endDate: Date().addingTimeInterval(412.6))]))]
        }
        add("timer-long-label-more") {
            [LiveSamples.timer(LiveTimerSnapshot(timers: [
                ClockTimer(label: "Proofread the chapter on notch geometry", duration: 1500, endDate: Date().addingTimeInterval(1330.6)),
                ClockTimer(label: "Tea", duration: 300, endDate: Date().addingTimeInterval(1900)),
            ], pomodoro: PomodoroState(phase: .work, endDate: Date().addingTimeInterval(600), sessions: 1)))]
        }
        add("timer-pomodoro") {
            [LiveSamples.timer(LiveTimerSnapshot(pomodoro: PomodoroState(phase: .work, endDate: Date().addingTimeInterval(14 * 60 + 12.6), sessions: 2), pomodoroTotal: 25 * 60))]
        }
        add("timer-pomodoro-break") {
            [LiveSamples.timer(LiveTimerSnapshot(pomodoro: PomodoroState(phase: .shortBreak, endDate: Date().addingTimeInterval(3 * 60 + 5.6), sessions: 3), pomodoroTotal: 5 * 60))]
        }
        add("timer-pomodoro-paused") {
            [LiveSamples.timer(LiveTimerSnapshot(pomodoro: PomodoroState(phase: .work, endDate: nil, pausedRemaining: 9 * 60 + 41, sessions: 0), pomodoroTotal: 25 * 60))]
        }
        add("timer-finished") {
            let now = Date()
            return [LiveSamples.timer(LiveTimerSnapshot(ended: [ClockEnded(id: "t1", title: "Tea", symbol: "timer", duration: 300,
                                                                            endedAt: now.addingTimeInterval(-3 * 3600), shownUntil: now.addingTimeInterval(50))]))]
        }
        add("timer-finished-running") {
            let now = Date()
            return [LiveSamples.timer(LiveTimerSnapshot(timers: [ClockTimer(label: "Tea", duration: 300, endDate: now.addingTimeInterval(120))],
                                                         ended: [ClockEnded(id: "p1", title: "Focus session", symbol: "leaf", duration: 1500,
                                                                            endedAt: now.addingTimeInterval(-1800), shownUntil: now.addingTimeInterval(50))]))]
        }
        add("todos") {
            [LiveSamples.todos([LiveSamples.todo("Reply to Marta about Sunday", days: 0), LiveSamples.todo("Review the ring settings page", days: 0), LiveSamples.todo("Book the dentist")])]
        }
        add("todos-overdue") {
            [LiveSamples.todos([LiveSamples.todo("Book the dentist"), LiveSamples.todo("Water the plants", days: 2), LiveSamples.todo("Pay the electricity bill", days: -2),
                                LiveSamples.todo("Reply to Marta", days: 0), LiveSamples.todo("Send the invoice", days: -1), LiveSamples.todo("Plan the trip")])]
        }
        add("todos-one") { [LiveSamples.todos([LiveSamples.todo("Call the bank")])] }
        add("todos-long-titles") {
            [LiveSamples.todos([LiveSamples.todo("Write the long and thorough reply to the whole committee about the budget", days: -1),
                                LiveSamples.todo("Prepare the slides for the quarterly all-hands presentation on Friday", days: 0),
                                LiveSamples.todo("Renew the passport", days: nil), LiveSamples.todo("Order new running shoes")])]
        }
    }
}
