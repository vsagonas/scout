import SwiftUI

@MainActor
enum CalendarFeature {
    static func start() {
        // Only starts EventKit work when the user turned Calendar on (or in scripted runs, with sample events).
        CalendarService.shared.start()
        DebugCommands.register("calendar.demo") { params in
            let minutes = Double(params["minutes"] ?? "") ?? 3
            CalendarService.shared.demo(minutesBefore: minutes)
        }
        DebugCommands.register("calendar.open") { _ in NotchNavigator.shared.open(.calendar) }
        DebugCommands.register("calendar.join") { _ in
            if let next = CalendarService.shared.nextEvent { LiveActivityCenter.shared.present(CalendarService.startCard(next)) }
        }
    }

    static func registerGallery() {
        FeatureGallery.widget("calendar-widget", span: 4) { CalendarWidgetView() }
        // Today (meetings and to-dos in one; the date, time and year when nothing is on), with fixed data and a fixed moment.
        let noon = Calendar.current.date(bySettingHour: 12, minute: 41, second: 0, of: Date()) ?? Date()
        let meetings = [LiveSamples.event("Design review", start: noon.addingTimeInterval(19 * 60), length: 3600, link: LiveSamples.meet),
                        LiveSamples.event("Dentist", start: noon.addingTimeInterval(4 * 3600), length: 1800, color: "#F97316")]
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: noon)
        let todos = [TodoTask(title: "Pay the electricity bill", day: yesterday), TodoTask(title: "Reply to Marta", day: noon),
                     TodoTask(title: "Book the train tickets"), TodoTask(title: "Water the plants")]
        FeatureGallery.widget("today-busy", span: 4) { TodayWidgetView(events: meetings, tasks: todos, now: noon) }
        FeatureGallery.widget("today-todos", span: 4) { TodayWidgetView(events: [], tasks: todos, now: noon) }
        FeatureGallery.widget("today-meetings", span: 4) { TodayWidgetView(events: meetings, tasks: [], now: noon) }
        FeatureGallery.widget("today-empty", span: 4) {
            TodayWidgetView(events: [], tasks: [], now: noon, fixedBattery: BatteryState(level: 82, isCharging: false, isPluggedIn: false, isCharged: false, minutesRemaining: 250))
        }
        FeatureGallery.widget("today-empty-charging", span: 4) {
            TodayWidgetView(events: [], tasks: [], now: noon, fixedBattery: BatteryState(level: 64, isCharging: true, isPluggedIn: true, isCharged: false, minutesRemaining: 54))
        }
        FeatureGallery.widget("today-empty-low", span: 4) {
            TodayWidgetView(events: [], tasks: [], now: noon, fixedBattery: BatteryState(level: 12, isCharging: false, isPluggedIn: false, isCharged: false, minutesRemaining: 38))
        }
        registerMergedGallery()
        Gallery.register("calendar-join-card", size: CGSize(width: 380, height: 90)) {
            JoinCardView(event: CalendarSamples.events()[1], link: CalendarSamples.events()[1].link)
                .background(GlassBackground(cornerRadius: 22))
        }
        Gallery.register("calendar-countdown", size: CGSize(width: 420, height: 90), backdrop: .screenTop) {
            ZStack {
                Capsule().fill(Color.black).frame(width: 330, height: 34)
                let soon = Date().addingTimeInterval(300)
                let e = CalEvent(id: "x", title: "Design review", start: soon, end: soon.addingTimeInterval(3600), isAllDay: false,
                                 location: "https://meet.google.com/abc-defg-hij", notes: nil, url: nil, calendarID: "Work",
                                 calendarTitle: "Work", colorHex: "#3B82F6")
                HStack {
                    CalendarService.countdownActivity(e, now: Date()).leading
                    Spacer().frame(width: 190)
                    CalendarService.countdownActivity(e, now: Date()).trailing
                }
            }
        }
        FeatureGallery.settings("settings-calendar", height: 760) { CalendarSettingsPane() }
    }

    /// The Calendar tab with the to-dos in it, on its own and in the
    /// real island. Render one look at a time: `SCOUT_8BIT=0`, `SCOUT_PRESET=light`, `SCOUT_SCALE=large`.
    private static func registerMergedGallery() {
        let inView = NotchPrefs.calendarHeight - 54   // the view's own room under the header and above the bottom edge
        let sampleDay = { (offset: Int) in Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: Date())) ?? Date() }
        // The island itself: the Calendar tab on show, the To-dos entry (it opens the same view), a narrow island, and a taller one.
        func island(_ name: String, workspace: WorkspaceKind, width: CGFloat? = nil, height: CGFloat = 700, openHeight: CGFloat? = nil) {
            Gallery.register(name, size: CGSize(width: 1560, height: height)) {
                let _ = DashGallery.seed(agents: 2, playing: false, live: [])
                NotchScene(size: CGSize(width: 1560, height: height), open: true, workspace: workspace, live: NookLive(playing: false, openTodos: 0, agents: 2),
                           widthCap: width, openHeight: openHeight, showNotchRect: true)
            }
        }
        island("calendar-merged-island", workspace: .calendar)
        island("calendar-merged-island-todos-entry", workspace: .todo)
        island("calendar-merged-island-narrow", workspace: .calendar, width: 680)
        island("calendar-merged-island-medium", workspace: .calendar, width: 860)
        island("calendar-merged-island-tall", workspace: .calendar, height: 700, openHeight: 420)
        // The view alone, at the room the island gives it, for the states the island cannot be asked for.
        FeatureGallery.workspace("calendar-merged-allopen", width: 988, height: inView) { CalendarWorkspaceView(previewAllOpen: true) }
        FeatureGallery.workspace("calendar-merged-composer", width: 988, height: inView) { CalendarWorkspaceView(previewComposing: true) }
        FeatureGallery.workspace("calendar-merged-composer-narrow", width: 628, height: inView) { CalendarWorkspaceView(previewComposing: true) }
        FeatureGallery.workspace("calendar-merged-day-later", width: 988, height: inView) { CalendarWorkspaceView(previewDay: sampleDay(2)) }
        FeatureGallery.workspace("calendar-merged-day-empty", width: 988, height: inView) { CalendarWorkspaceView(previewDay: sampleDay(9)) }
        FeatureGallery.workspace("calendar-merged-calendar-off", width: 988, height: inView) { CalendarWorkspaceView(previewAccess: .off) }
        FeatureGallery.workspace("calendar-merged-calendar-denied-narrow", width: 628, height: inView) { CalendarWorkspaceView(previewAccess: .denied) }
        // A long list, long titles and an overdue one: nothing runs off the column, the list scrolls.
        let today = sampleDay(0)
        let crowded = TodoStore(preview: [
            TodoTask(title: "Write the long and thorough reply to the whole committee about next year's budget and the hiring plan", day: today),
            TodoTask(title: "Renew the passport", day: today), TodoTask(title: "Call the bank about the card", day: sampleDay(-2)),
            TodoTask(title: "Water the plants", day: today), TodoTask(title: "Order new running shoes", day: today),
            TodoTask(title: "Plan the trip", day: today), TodoTask(title: "Book the dentist", day: today),
            TodoTask(title: "Reply to Marta about Sunday", done: true, day: today), TodoTask(title: "Send the invoice", done: true, day: today)])
        FeatureGallery.workspace("calendar-merged-crowded", width: 988, height: inView) { CalendarWorkspaceView(store: crowded) }
        FeatureGallery.workspace("calendar-merged-crowded-narrow", width: 628, height: inView) { CalendarWorkspaceView(store: crowded) }
    }
}
