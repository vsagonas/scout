import AppKit
import EventKit
import SwiftUI

/// Calendar data for the widget, the workspace and the "next meeting" live activity.
/// Nothing touches EventKit until the user turns Calendar on (`cal.enabled`); scripted runs use sample events.
@MainActor
final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    // Settings keys (prefix `cal.`)
    enum Key {
        static let enabled = "cal.enabled"
        static let hidden = "cal.hiddenCalendars"
        static let allDay = "cal.showAllDay"
        static let multiDay = "cal.showMultiDay"
        static let minutesBefore = "cal.minutesBefore"
        static let onlyVideo = "cal.onlyVideo"
        static let elapsed = "cal.showElapsed"
        static let joinCard = "cal.joinCard"
    }

    @Published private(set) var access: CalendarAccess = .off
    @Published private(set) var calendars: [CalSource] = []
    @Published private(set) var eventsToday: [CalEvent] = []
    @Published private(set) var eventsTomorrow: [CalEvent] = []
    @Published var monthEvents: [CalEvent] = []
    @Published private(set) var lastError: String?

    private let store = EKEventStore()
    private var timer: Timer?
    private var started = false
    private var announced: Set<String> = []
    private var joinShown: Set<String> = []
    /// Scripted runs shift the sample events (the `calendar.demo` command brings the next meeting close).
    private var sampleShift: TimeInterval = 0

    var now: Date { Date() }

    private func sampleEvents() -> [CalEvent] {
        CalendarSamples.events(around: now).map { e in
            var e = e
            e.start = e.start.addingTimeInterval(sampleShift)
            e.end = e.end.addingTimeInterval(sampleShift)
            return e
        }
    }

    var hiddenCalendars: Set<String> {
        get { Set((UserDefaults.standard.string(forKey: Key.hidden) ?? "").split(separator: "\n").map(String.init)) }
        set { UserDefaults.standard.set(newValue.sorted().joined(separator: "\n"), forKey: Key.hidden); refresh() }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        refresh()
    }

    private var lastEnabled: Bool?
    private func settingsChanged() {
        let enabled = Pref.bool(Key.enabled, false)
        if lastEnabled != enabled { lastEnabled = enabled; refresh() }
    }

    // MARK: Access

    private func currentAccess() -> CalendarAccess {
        if ScoutRuntime.isScripted { return .sample }
        guard Pref.bool(Key.enabled, false) else { return .off }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .denied, .restricted, .writeOnly: return .denied
        default: return .needsAccess
        }
    }

    /// Called when the user turns Calendar on (or presses "Allow access"): the only place macOS is asked.
    func requestAccess() {
        guard !ScoutRuntime.isScripted else { return }
        Pref.set(true, Key.enabled)
        store.requestFullAccessToEvents { [weak self] granted, error in
            Task { @MainActor in
                self?.lastError = granted ? nil : error?.localizedDescription
                self?.refresh()
            }
        }
    }

    func turnOff() {
        Pref.set(false, Key.enabled)
        LiveActivityCenter.shared.dismiss(id: "calendar.countdown")
        refresh()
    }

    // MARK: Data

    func refresh() {
        access = currentAccess()
        switch access {
        case .off, .needsAccess, .denied:
            calendars = []
            eventsToday = []
            eventsTomorrow = []
            monthEvents = []
        case .sample:
            calendars = CalendarSamples.calendars
            eventsToday = events(on: now)
            eventsTomorrow = events(on: tomorrow)
        case .granted:
            calendars = store.calendars(for: .event).map {
                CalSource(id: $0.calendarIdentifier, title: $0.title,
                          colorHex: CalEvent.hex(of: $0.cgColor), sourceTitle: $0.source?.title ?? "", allowsEditing: $0.allowsContentModifications)
            }.sorted { ($0.sourceTitle, $0.title) < ($1.sourceTitle, $1.title) }
            eventsToday = events(on: now)
            eventsTomorrow = events(on: tomorrow)
        }
        tick()
    }

    private var tomorrow: Date { Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now }

    static func order(_ a: CalEvent, _ b: CalEvent) -> Bool {
        if a.isAllDay != b.isAllDay { return a.isAllDay }
        return (a.start, a.title) < (b.start, b.title)
    }

    private func filtered(_ events: [CalEvent]) -> [CalEvent] {
        let hidden = hiddenCalendars
        let showAllDay = Pref.bool(Key.allDay, true)
        let showMulti = Pref.bool(Key.multiDay, true)
        let onlyVideo = Pref.bool(Key.onlyVideo, false)
        return events.filter { e in
            if hidden.contains(e.calendarID) { return false }
            if e.isAllDay && !showAllDay { return false }
            if e.isMultiDay && !showMulti { return false }
            if onlyVideo && e.link == nil { return false }
            return true
        }
    }

    /// Events on one day, filtered by the settings.
    func events(on day: Date) -> [CalEvent] {
        switch access {
        case .sample:
            return filtered(sampleEvents()).filter { $0.isOn(day) }.sorted(by: Self.order)
        case .granted:
            let cal = Calendar.current
            let start = cal.startOfDay(for: day)
            guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
            return filtered(fetch(from: start, to: end)).sorted(by: Self.order)
        default:
            return []
        }
    }

    /// All events in a range (month grid dots), filtered by the settings.
    func events(from start: Date, to end: Date) -> [CalEvent] {
        switch access {
        case .sample: return filtered(sampleEvents()).filter { $0.start < end && $0.end > start }
        case .granted: return filtered(fetch(from: start, to: end))
        default: return []
        }
    }

    private func fetch(from start: Date, to end: Date) -> [CalEvent] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map(CalEvent.init)
    }

    /// The next event that has not ended yet (timed events first; all-day events never count as "next").
    var nextEvent: CalEvent? {
        eventsToday.filter { !$0.isAllDay && $0.end > now }.min { $0.start < $1.start }
    }

    // MARK: Saving (the composer)

    struct Draft {
        var title = ""
        var day = Date()
        var start = Date()
        var end = Date().addingTimeInterval(3600)
        var isAllDay = false
        var location = ""
        var calendarID = ""
    }

    /// Saves a new event with EventKit. Scripted runs never write anything (there is no access anyway).
    @discardableResult
    func save(_ draft: Draft) -> Bool {
        guard !ScoutRuntime.isScripted else { return false }
        guard access == .granted else { return false }
        guard let target = store.calendars(for: .event).first(where: { $0.calendarIdentifier == draft.calendarID && $0.allowsContentModifications })
                ?? store.defaultCalendarForNewEvents else { return false }
        let cal = Calendar.current
        let event = EKEvent(eventStore: store)
        event.calendar = target
        event.title = draft.title.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "New event") : draft.title
        event.isAllDay = draft.isAllDay
        if draft.isAllDay {
            event.startDate = cal.startOfDay(for: draft.day)
            event.endDate = cal.startOfDay(for: draft.day)
        } else {
            func merge(_ time: Date) -> Date {
                let t = cal.dateComponents([.hour, .minute], from: time)
                return cal.date(bySettingHour: t.hour ?? 9, minute: t.minute ?? 0, second: 0, of: draft.day) ?? draft.day
            }
            event.startDate = merge(draft.start)
            var end = merge(draft.end)
            if end <= event.startDate { end = event.startDate.addingTimeInterval(3600) }
            event.endDate = end
        }
        let place = draft.location.trimmingCharacters(in: .whitespaces)
        if !place.isEmpty {
            if let url = URL(string: place), url.scheme?.hasPrefix("http") == true { event.url = url; event.location = place } else { event.location = place }
        }
        do {
            try store.save(event, span: .thisEvent)
            refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: Live activity: countdown, join card, elapsed

    private func tick() {
        guard access == .granted || access == .sample else {
            LiveActivityCenter.shared.dismiss(id: "calendar.countdown")
            return
        }
        // After midnight "today" changes: keep eventsToday fresh.
        if let first = eventsToday.first(where: { !$0.isAllDay }), !Calendar.current.isDate(first.start, inSameDayAs: now) { eventsToday = events(on: now) }
        let center = LiveActivityCenter.shared
        let minutes = Pref.int(Key.minutesBefore, 10)
        let timed = eventsToday.filter { !$0.isAllDay }
        if let upcoming = timed.filter({ $0.start > now }).min(by: { $0.start < $1.start }),
           minutes > 0, upcoming.start.timeIntervalSince(now) <= Double(minutes) * 60 {
            center.show(Self.countdownActivity(upcoming, now: now))
            return
        }
        if let running = timed.first(where: { $0.start <= now && $0.end > now }) {
            if Pref.bool(Key.joinCard, true), !joinShown.contains(running.id), now.timeIntervalSince(running.start) < 120 {
                joinShown.insert(running.id)
                center.present(Self.startCard(running))
            }
            if Pref.bool(Key.elapsed, false) { center.show(Self.elapsedActivity(running)); return }
        }
        center.dismiss(id: "calendar.countdown")
    }

    static func countdownActivity(_ e: CalEvent, now: Date) -> LiveActivity {
        let link = e.link
        return LiveActivity(id: "calendar.countdown", kind: .calendar, expiresAfter: max(1, e.start.timeIntervalSince(now) + 2), onTap: {
            NotchNavigator.shared.open(.calendar)
        }, leading: {
            HStack(spacing: 5) {
                Circle().fill(e.color).frame(width: 7, height: 7)
                Image(systemName: link != nil ? "video.fill" : "calendar").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            }
        }, trailing: {
            CountdownText(start: e.start)
        }).withDetail {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(e.timeText()).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
            }.foregroundStyle(.white)
        }
    }

    static func elapsedActivity(_ e: CalEvent) -> LiveActivity {
        LiveActivity(id: "calendar.countdown", kind: .calendar, expiresAfter: max(1, e.end.timeIntervalSinceNow), onTap: {
            NotchNavigator.shared.open(.calendar)
        }, leading: {
            Circle().fill(e.color).frame(width: 8, height: 8)
        }, trailing: {
            Text(e.start, style: .timer).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
        }).withDetail {
            Text(e.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
        }
    }

    static func startCard(_ e: CalEvent) -> NotchCard {
        let link = e.link
        return NotchCard(id: "calendar.join", kind: .calendar, duration: 12, onTap: {
            if let link { NSWorkspace.shared.open(link.url) } else { NotchNavigator.shared.open(.calendar) }
        }) {
            JoinCardView(event: e, link: link)
        }
    }

    // MARK: Actions

    func join(_ e: CalEvent) {
        guard let link = e.link, !ScoutRuntime.isScripted else { return }
        NSWorkspace.shared.open(link.url)
    }

    /// Fake "now" ten minutes before the next sample event, to see the countdown and the join card.
    func demo(minutesBefore: Double = 3) {
        sampleShift = 0
        guard let next = CalendarSamples.events().filter({ !$0.isAllDay }).min(by: { $0.start < $1.start }) else { return }
        sampleShift = Date().addingTimeInterval(minutesBefore * 60).timeIntervalSince(next.start)
        joinShown = []
        refresh()
    }
}

extension CalEvent {
    static func hex(of cgColor: CGColor?) -> String {
        guard let cgColor, let ns = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) else { return "#3B82F6" }
        return String(format: "#%02X%02X%02X", Int(round(ns.redComponent * 255)), Int(round(ns.greenComponent * 255)), Int(round(ns.blueComponent * 255)))
    }
}

/// "in 5 min" while minutes remain, m:ss in the last minute, "now" at the start.
struct CountdownText: View {
    let start: Date

    static func text(remaining: TimeInterval) -> String {
        if remaining <= 0 { return String(localized: "now") }
        if remaining < 60 { return String(format: "0:%02d", Int(remaining.rounded(.up))) }
        return String(localized: "in \(Int((remaining / 60).rounded(.up))) min")
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.text(remaining: start.timeIntervalSince(context.date)))
                .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
        }
    }
}

struct JoinCardView: View {
    let event: CalEvent
    let link: MeetingLink.Link?

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(event.color).frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(link != nil ? "Starting now · \(link!.service)" : "Starting now")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if link != nil {
                Text("Join").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.black.opacity(0.85))
                    .padding(.horizontal, 12).padding(.vertical, 5).background(Capsule().fill(Theme.accent))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(width: 320)
    }
}
