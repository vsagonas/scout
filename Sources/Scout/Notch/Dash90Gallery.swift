import SwiftUI

// Gallery scenes `dash90-*`: the whole dashboard row in the 90s look (quiet, busy, Edit Nook), each restyled
// panel LARGE (the real 140 pt panel drawn at 2.4 times), and the header at a wide and a narrow width. Synthetic data only.
// Render with `scripts/gallery.sh dash90`.

@MainActor
enum Dash90Gallery {
    nonisolated private static let big: CGFloat = 2.4

    /// One panel at 2.4 times its size, on black, in its plastic face.
    static func panel<V: View>(_ name: String, span: Int, scale: CGFloat = big, stripe: Color? = nil, @ViewBuilder _ content: @escaping () -> V) {
        let w = FeatureGallery.widgetWidth(span)
        let h = NookMetrics.widgetHeight
        Gallery.register("dash90-\(name)", size: CGSize(width: w * scale + 40, height: h * scale + 40), backdrop: .window) {
            content()
                .frame(width: w, height: h)
                .nookPanelFace(tint: stripe)
                .environment(\.colorScheme, Look.contentScheme)   // the open notch's scheme: dark, or the light preset's (a forced .dark drew white ink on the paper)
                .scaleEffect(scale)
                .frame(width: w * scale, height: h * scale)
                .padding(20)
                .background(Color.black)
        }
    }

    private static func service(_ track: NowPlayingTrack?) -> NowPlayingService {
        let s = NowPlayingService()
        s.showSample(track)
        return s
    }

    private static func scene(_ name: String, height: CGFloat, width: CGFloat = DashGallery.wide, workspace: WorkspaceKind = .nook, agents: Int = 3,
                              playing: Bool = false, live: [any LivePanelSource] = [], layout: [WidgetKind]? = nil,
                              editing: Bool = false, widthCap: CGFloat? = nil, notchRect: Bool = false) {
        Gallery.register("dash90-\(name)", size: CGSize(width: width, height: height)) {
            let _ = DashGallery.seed(agents: agents, playing: playing, live: live)
            NotchScene(size: CGSize(width: width, height: height), open: true, workspace: workspace, editing: editing, layout: layout,
                       live: NookLive(playing: playing, openTodos: 0, agents: agents), widthCap: widthCap, showNotchRect: notchRect)
        }
    }

    static func register() {
        // The whole row.
        scene("row-quiet", height: 290, agents: 3, notchRect: true)
        scene("row-busy", height: 290, agents: 3, playing: true,
              live: [DashGallery.meeting(in: nil), DashGallery.download(), DashGallery.timer()], layout: [.agents, .askAI, .pulse, .today], notchRect: true)
        scene("row-pinned", height: 290, agents: 2, layout: [.agents, .askAI, .calendar, .weather, .notes, .todo])
        scene("row-pinned2", height: 290, agents: 0, layout: [.clipboard, .timer, .pomodoro, .shortcuts, .quickApps])
        // The live panels beside a default panel (the grid's first lines, both presets).
        scene("row-live", height: 290, agents: 0, live: [DashGallery.meeting(in: 12), DashGallery.download(), DashGallery.timer()], layout: [.pulse])
        scene("row-edit", height: 390, agents: 3, layout: [.agents, .askAI, .today, .weather], editing: true)
        // The header at a wide and a narrow width (the camera housing outlined).
        scene("header-wide", height: 120, workspace: .calendar, agents: 0, notchRect: true)
        scene("header-narrow", height: 120, width: 760, workspace: .agents, agents: 0, widthCap: 680, notchRect: true)
        scene("header-edit", height: 130, agents: 0, layout: [.today], editing: true, notchRect: true)

        // Each restyled panel, large.
        let noon = Calendar.current.date(bySettingHour: 12, minute: 41, second: 0, of: Date()) ?? Date()
        let meetings = [LiveSamples.event("Design review", start: noon.addingTimeInterval(19 * 60), length: 3600, link: LiveSamples.meet),
                        LiveSamples.event("Dentist", start: noon.addingTimeInterval(4 * 3600), length: 1800, color: "#F97316")]
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: noon)
        let todos = [TodoTask(title: "Pay the electricity bill", day: yesterday), TodoTask(title: "Reply to Marta", day: noon), TodoTask(title: "Water the plants")]
        let battery = BatteryState(level: 82, isCharging: false, isPluggedIn: false, isCharged: false, minutesRemaining: 250)
        panel("today-empty", span: 4) { TodayWidgetView(events: [], tasks: [], now: noon, fixedBattery: battery) }
        panel("today-charging", span: 4) {
            TodayWidgetView(events: [], tasks: [], now: noon, fixedBattery: BatteryState(level: 64, isCharging: true, isPluggedIn: true, isCharged: false, minutesRemaining: 54))
        }
        panel("today-low", span: 4) {
            TodayWidgetView(events: [], tasks: [], now: noon, fixedBattery: BatteryState(level: 12, isCharging: false, isPluggedIn: false, isCharged: false, minutesRemaining: 38))
        }
        panel("today-busy", span: 4) { TodayWidgetView(events: meetings, tasks: todos, now: noon) }
        panel("today-meetings", span: 4) { TodayWidgetView(events: meetings, tasks: [], now: noon) }
        panel("today-join", span: 4) {
            TodayWidgetView(events: [LiveSamples.event("Weekly planning", start: noon.addingTimeInterval(-6 * 60), length: 3600, link: LiveSamples.zoom)], tasks: [TodoTask(title: "Book the train")], now: noon)
        }
        panel("pulse-cards", span: 4) { PulseWidgetView(style: .cards, metrics: [.cpu, .memory], battery: battery) }   // the order: readings, their graphs, SSD + battery, network
        panel("pulse-cards-net", span: 4) { PulseWidgetView(style: .cards, metrics: [.cpu, .network], battery: battery) }   // Network as a reading: its own small line under its graph, no second network line
        panel("pulse-rings", span: 4) { PulseWidgetView(style: .rings, metrics: [.cpu, .memory, .gpu, .network]) }
        panel("pulse-list", span: 4) { PulseWidgetView(style: .list, metrics: [.cpu, .memory, .gpu, .disk, .network]) }
        panel("askai-idle", span: 4) { AskAIWidgetView(store: AIChatStore(demo: .conversation), draft: AskAINotchDraft()) }
        panel("askai-typing", span: 4) {
            let draft = AskAINotchDraft()
            let _ = { draft.text = "What is the capital of Portugal?" }()
            AskAIWidgetView(store: AIChatStore(demo: .conversation), draft: draft)
        }
        panel("askai-busy", span: 4) { AskAIWidgetView(store: AIChatStore(demo: .thinking), draft: AskAINotchDraft()) }
        panel("askai-answer", span: 4) { AskAIWidgetView(store: AIChatStore(demo: .quick), draft: AskAINotchDraft()) }   // a quick answer, shown inside the panel
        // The live panels.
        panel("live-downloads", span: 4) { DashGallery.download().makeView() }
        panel("live-downloads-unknown", span: 4) { LiveSamples.downloads(LiveDownloadsSnapshot(downloads: [LiveSamples.transfer("Backup.zip", fraction: nil)])).makeView() }
        panel("live-downloads-done", span: 4) {
            LiveSamples.downloads(LiveDownloadsSnapshot(done: LiveSamples.transfer("Scout-0.1.0.zip", fraction: 1, total: 75_000_000), doneAt: Date())).makeView()
        }
        panel("live-recording", span: 4) { LiveSamples.recording(mic: true).makeView() }
        panel("live-timer", span: 4) {
            LiveSamples.timer(LiveTimerSnapshot(timers: [ClockTimer(label: "Tea", duration: 300, endDate: Date().addingTimeInterval(187.6))])).makeView()
        }
        panel("live-pomodoro", span: 4) { DashGallery.timer().makeView() }
        panel("live-meeting", span: 4) { DashGallery.meeting(in: 12).makeView() }
        panel("live-meeting-now", span: 4) { DashGallery.meeting(in: nil).makeView() }
        panel("live-bluetooth", span: 4) {
            LiveSamples.bluetooth([LiveSamples.connection(BluetoothInfo(name: "AirPods Pro", kind: .airPodsPro, left: 82, right: 64, caseLevel: 17))]).makeView()
        }
        panel("live-bluetooth-low", span: 4) {
            LiveSamples.bluetooth([LiveSamples.connection(BluetoothInfo(name: "AirPods Pro", kind: .airPodsPro, left: 14, right: 31, caseLevel: 60), ago: 600)]).makeView()
        }
        panel("live-todos", span: 4) {
            LiveSamples.todos([LiveSamples.todo("Pay the electricity bill", days: -1), LiveSamples.todo("Reply to Marta", days: 0), LiveSamples.todo("Water the plants"), LiveSamples.todo("Book the dentist")]).makeView()
        }
        // Now playing, and the other pinned panels.
        panel("media-compact", span: 5) { MediaWidgetView(service: service(NowPlayingService.sampleTrack), layout: "compact") }
        panel("media-expanded", span: 5) { MediaWidgetView(service: service(NowPlayingService.sampleTrack), layout: "expanded") }
        panel("media-narrow", span: 4) { MediaWidgetView(service: service(NowPlayingService.sampleTrack), layout: "compact") }
        panel("media-empty", span: 5) { MediaWidgetView(service: service(nil), layout: "compact") }
        panel("calendar", span: 4) { CalendarWidgetView() }
        panel("timer-idle", span: 3) { TimerWidgetView(clock: .demo(running: false)) }
        panel("timer", span: 3) { TimerWidgetView(clock: .demo(running: true)) }
        panel("pomodoro", span: 3) { PomodoroWidgetView(clock: .demo(running: true)) }
        panel("todo", span: 4) { TodoWidgetView() }
        panel("notes", span: 4) { NotesWidgetView() }
        panel("clipboard", span: 5) { ClipboardWidgetView() }
        panel("shortcuts", span: 4) { ShortcutsWidgetView(preview: ["Morning routine", "Resize images", "Start focus", "Log water", "Send standup", "Tidy desktop"]) }
        panel("quickapps", span: 3) { QuickAppsWidgetView() }
        panel("prompter", span: 4) { PrompterWidgetView() }
        panel("tray", span: 3) { TrayWidgetView() }
        panel("weather", span: 3) { WeatherWidgetView() }
        panel("volume", span: 3, stripe: Retro.Ink.lime) { VolumeWidgetView() }
    }
}
