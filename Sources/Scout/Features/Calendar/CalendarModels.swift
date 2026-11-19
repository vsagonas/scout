import EventKit
import SwiftUI

/// A calendar event as the notch shows it (a plain value, so sample data and EventKit look the same).
struct CalEvent: Identifiable, Hashable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    var notes: String?
    var url: URL?
    var calendarID: String
    var calendarTitle: String
    var colorHex: String

    var color: Color { Color(hex: colorHex) ?? Theme.accent }

    var link: MeetingLink.Link? {
        MeetingLink.find(in: [url?.absoluteString, location, notes])
    }

    /// Spans more than one calendar day (an all-day event of several days counts too).
    var isMultiDay: Bool {
        let cal = Calendar.current
        let lastMoment = isAllDay ? end.addingTimeInterval(-1) : max(start, end.addingTimeInterval(-1))
        return !cal.isDate(start, inSameDayAs: lastMoment)
    }

    func isOn(_ day: Date) -> Bool {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return false }
        return start < dayEnd && max(end, start.addingTimeInterval(1)) > dayStart
    }

    /// "9:30 – 10:00 AM", "All day", "Day 2 of 3"…
    func timeText(on day: Date = Date()) -> String {
        let cal = Calendar.current
        if isAllDay {
            if isMultiDay {
                let first = cal.startOfDay(for: start)
                let total = max(1, (cal.dateComponents([.day], from: first, to: cal.startOfDay(for: end)).day ?? 1))
                let index = (cal.dateComponents([.day], from: first, to: cal.startOfDay(for: day)).day ?? 0) + 1
                return String(localized: "Day \(min(index, total)) of \(total)")
            }
            return String(localized: "All day")
        }
        let s = start.formatted(date: .omitted, time: .shortened)
        let e = end.formatted(date: .omitted, time: .shortened)
        return start == end ? s : "\(s) – \(e)"
    }
}

struct CalSource: Identifiable, Hashable {
    var id: String
    var title: String
    var colorHex: String
    var sourceTitle: String
    var allowsEditing: Bool
    var color: Color { Color(hex: colorHex) ?? Theme.accent }
}

enum CalendarAccess: Equatable {
    case off            // the user has not turned Calendar on
    case needsAccess    // on, but macOS has not been asked / allowed yet
    case denied
    case granted
    case sample         // scripted runs
}

extension CalEvent {
    init(_ e: EKEvent) {
        let hex = CalEvent.hex(of: e.calendar.cgColor)
        self.init(id: (e.eventIdentifier ?? UUID().uuidString) + "@\(Int(e.startDate.timeIntervalSince1970))",
                  title: (e.title?.isEmpty == false ? e.title : nil) ?? String(localized: "Untitled"),
                  start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
                  location: e.location, notes: e.notes, url: e.url,
                  calendarID: e.calendar.calendarIdentifier, calendarTitle: e.calendar.title, colorHex: hex)
    }
}

/// Sample events for scripted runs and the gallery: a believable day, relative to today.
enum CalendarSamples {
    static func events(around day: Date = Date()) -> [CalEvent] {
        let cal = Calendar.current
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let base = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: day)) ?? day
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
        }
        func make(_ id: String, _ title: String, _ s: Date, _ e: Date, allDay: Bool = false, location: String? = nil,
                  notes: String? = nil, calendar: String, color: String) -> CalEvent {
            CalEvent(id: id, title: title, start: s, end: e, isAllDay: allDay, location: location, notes: notes, url: nil,
                     calendarID: calendar, calendarTitle: calendar, colorHex: color)
        }
        return [
            make("s1", "Team offsite", at(0, 0), at(3, 0), allDay: true, location: "Lisbon", calendar: "Work", color: "#3B82F6"),
            make("s2", "Standup", at(0, 9, 30), at(0, 9, 45), notes: "Join: https://zoom.us/j/9988776655", calendar: "Work", color: "#3B82F6"),
            make("s3", "Design review", at(0, 11), at(0, 12), location: "https://meet.google.com/abc-defg-hij", calendar: "Work", color: "#3B82F6"),
            make("s4", "Lunch with Maya", at(0, 13), at(0, 14), location: "Café Lino", calendar: "Personal", color: "#F97316"),
            make("s5", "Roadmap sync", at(0, 14, 30), at(0, 15, 15), location: "Room 4B", notes: "https://teams.microsoft.com/l/meetup-join/19%3ameeting", calendar: "Work", color: "#3B82F6"),
            make("s6", "Gym", at(0, 18), at(0, 19), calendar: "Personal", color: "#22C55E"),
            make("s7", "Dentist", at(1, 10), at(1, 10, 45), location: "Dr. Alvarez", calendar: "Personal", color: "#F97316"),
            make("s8", "Product demo", at(2, 16), at(2, 17), location: "https://us02web.zoom.us/j/123456789", calendar: "Work", color: "#3B82F6"),
            make("s9", "Dinner", at(4, 20), at(4, 22), location: "Taverna Nikos", calendar: "Personal", color: "#F97316"),
        ]
    }

    static let calendars: [CalSource] = [
        CalSource(id: "Work", title: "Work", colorHex: "#3B82F6", sourceTitle: "iCloud", allowsEditing: true),
        CalSource(id: "Personal", title: "Personal", colorHex: "#F97316", sourceTitle: "iCloud", allowsEditing: true),
        CalSource(id: "Birthdays", title: "Birthdays", colorHex: "#A855F7", sourceTitle: "Other", allowsEditing: false),
    ]
}
