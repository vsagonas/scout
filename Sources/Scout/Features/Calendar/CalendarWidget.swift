import SwiftUI

/// Nook widget: today's remaining events (or tomorrow's first ones), with color bars and times. Clicking the panel opens the full Calendar.
struct CalendarWidgetView: View {
    @ObservedObject private var service = CalendarService.shared
    @State private var tick = Date()

    var body: some View {
        content
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .notchContent()
            .onAppear { service.start(); service.refresh() }
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { tick = $0 }
    }

    @ViewBuilder private var content: some View {
        switch service.access {
        case .off:
            NotchEmptyState(symbol: "calendar", message: "See your day here", detail: "Show upcoming events and meeting links.",
                            actionTitle: "Turn on Calendar") { service.requestAccess() }
        case .needsAccess:
            NotchEmptyState(symbol: "calendar.badge.exclamationmark", message: "Allow calendar access",
                            actionTitle: "Allow access") { service.requestAccess() }
        case .denied:
            NotchEmptyState(symbol: "calendar.badge.exclamationmark", message: "Calendar access is off",
                            actionTitle: "Open Settings") { Permissions.openSettings(.calendars) }
        case .granted, .sample:
            agenda
        }
    }

    private var agenda: some View {
        let now = service.now
        let remaining = service.eventsToday.filter { $0.isAllDay || $0.end > now }
        let allDay = remaining.filter(\.isAllDay)
        let timed = remaining.filter { !$0.isAllDay }
        let showTomorrow = timed.isEmpty
        let rows = Array(timed.prefix(allDay.isEmpty ? 3 : 2))
        let tomorrowRows = Array(service.eventsTomorrow.filter { !$0.isAllDay }.prefix(2))
        return VStack(alignment: .leading, spacing: 5) {
            Dash90Title(showTomorrow && !service.eventsToday.isEmpty ? "Done today" : "Today", symbol: "calendar", tint: Retro.Ink.magenta) {
                Dash90Text(now.formatted(.dateTime.weekday(.abbreviated).day()), pixel: 1, color: Look.osd)
            }
            Dash90LCD(padding: 4, fill: true) {
                VStack(alignment: .leading, spacing: 1) {
                    if let banner = allDay.first {
                        HStack(spacing: 5) {
                            Image(systemName: "sun.max").font(.system(size: 9)).foregroundStyle(banner.color)
                            Text(banner.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Text(banner.timeText(on: now)).font(.system(size: 10)).foregroundStyle(NotchInk.tertiary).lineLimit(1)
                        }
                        .padding(.horizontal, 6).frame(height: 20).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 3, style: .circular).fill(banner.color.opacity(0.22)))
                    }
                    if timed.isEmpty && service.eventsToday.isEmpty {
                        Text("Nothing for today").font(.system(size: 12, weight: .medium)).foregroundStyle(NotchInk.secondary).padding(.horizontal, 4).padding(.vertical, 3)
                    }
                    ForEach(rows) { event in Dash90EventRow(event: event, now: now, joinable: true) }
                    if timed.count > rows.count {
                        Dash90Text(String(localized: "+\(timed.count - rows.count) more"), pixel: 1, color: Dash90.amber.opacity(0.8)).padding(.leading, 3).padding(.top, 2)
                    }
                    if showTomorrow && !tomorrowRows.isEmpty {
                        Dash90Text(String(localized: "Tomorrow"), pixel: 1, color: Dash90.amber.opacity(0.8)).padding(.leading, 3).padding(.top, 1)
                        ForEach(tomorrowRows) { event in Dash90EventRow(event: event, now: now, joinable: false).opacity(0.85) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// One line: color bar, time, title and (when it's about to start) a Join button.
struct EventRow: View {
    let event: CalEvent
    let now: Date
    var joinable = false
    var showDay = false

    private var inProgress: Bool { !event.isAllDay && event.start <= now && event.end > now }
    private var soon: Bool { !event.isAllDay && event.start > now && event.start.timeIntervalSince(now) < 15 * 60 }

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5).fill(event.color).frame(width: 3, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(event.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    if inProgress { Text("Now").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent) }
                    Text(event.isAllDay ? event.timeText(on: now) : FeatureFormat.time(event.start))
                        .font(.system(size: 10)).foregroundStyle(NotchInk.secondary).monospacedDigit()
                    if let place = event.location, !place.isEmpty, event.link == nil {
                        Text("·  " + place).font(.system(size: 10)).foregroundStyle(NotchInk.tertiary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 2)
            if joinable, event.link != nil, inProgress || soon {
                Button("Join") { CalendarService.shared.join(event) }.buttonStyle(.notchPillCompact).nookControl()
            } else if event.link != nil {
                Image(systemName: "video.fill").font(.system(size: 10)).foregroundStyle(NotchInk.tertiary)
            }
        }
        .frame(height: 26)
    }
}
