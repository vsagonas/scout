import Combine
import SwiftUI

// live.meeting: the next timed event that starts within the hour, or the one in progress. Reads the calendar service;
// never asks for access (calendar off or not allowed = never live).

struct LiveMeetingSnapshot: Equatable {
    var enabled = false           // Calendar is on and macOS lets Scout read it
    var events: [CalEvent] = []   // today's and tomorrow's, so a meeting just after midnight shows too
}

@MainActor
final class LiveMeetingPanel: LiveDriven {
    /// How far ahead an upcoming meeting shows.
    static let window: TimeInterval = 60 * 60
    /// An event this long is a block of the day (working hours, a trip), not a meeting.
    static let longest: TimeInterval = 8 * 3600

    let id = "live.meeting"
    let title = String(localized: "Meeting")
    let symbol = "video.fill"
    let span = 4
    let expandTo: WorkspaceKind? = .calendar

    let feed: LiveFeed<LiveMeetingSnapshot>
    private let clock: () -> Date
    private let join: (CalEvent) -> Void

    var changes: AnyPublisher<Void, Never> { feed.changes }

    init(feed: LiveFeed<LiveMeetingSnapshot>, clock: @escaping () -> Date = Date.init, join: @escaping (CalEvent) -> Void) {
        self.feed = feed
        self.clock = clock
        self.join = join
    }

    static func live() -> LiveMeetingPanel {
        let service = CalendarService.shared
        let feed = LiveFeed<LiveMeetingSnapshot>(read: {
            let enabled = service.access == .granted || service.access == .sample
            guard enabled else { return LiveMeetingSnapshot() }
            var seen = Set<String>()
            let events = (service.eventsToday + service.eventsTomorrow).filter { !$0.isAllDay && seen.insert($0.id).inserted }
            return LiveMeetingSnapshot(enabled: true, events: events.sorted { $0.start < $1.start })
        }, triggers: [service.liveTrigger])
        return LiveMeetingPanel(feed: feed) { CalendarService.shared.join($0) }
    }

    // MARK: Choosing

    struct Pick: Equatable {
        var event: CalEvent
        var inProgress: Bool
    }

    /// The meeting in progress (with a call link first, then the one that started last), else the next one within the hour.
    static func pick(_ snapshot: LiveMeetingSnapshot, now: Date) -> Pick? {
        guard snapshot.enabled else { return nil }
        let timed = snapshot.events.filter { !$0.isAllDay && $0.end.timeIntervalSince($0.start) < longest }
        let running = timed.filter { $0.start <= now && $0.end > now }
        if let current = running.max(by: { a, b in
            let la = a.link != nil, lb = b.link != nil
            return la == lb ? a.start < b.start : (!la && lb)
        }) {
            return Pick(event: current, inProgress: true)
        }
        let upcoming = timed.filter { $0.start > now && $0.start.timeIntervalSince(now) <= window }
        if let next = upcoming.min(by: { $0.start < $1.start }) { return Pick(event: next, inProgress: false) }
        return nil
    }

    private var pick: Pick? { Self.pick(feed.value, now: clock()) }

    var isLive: Bool { pick != nil }
    var priority: Int { pick?.inProgress == true ? 90 : 70 }

    func nextWake(after now: Date) -> Date? {
        guard feed.value.enabled else { return nil }
        let times = feed.value.events.flatMap { [$0.start.addingTimeInterval(-Self.window), $0.start, $0.end] }
        return times.filter { $0 > now }.min()
    }

    func makeView() -> AnyView { AnyView(LiveMeetingView(feed: feed, clock: clock, join: join)) }
}

// MARK: - View

struct LiveMeetingView: View {
    @ObservedObject var feed: LiveFeed<LiveMeetingSnapshot>
    var clock: () -> Date = Date.init
    var join: (CalEvent) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let now = clock()
            if let pick = LiveMeetingPanel.pick(feed.value, now: now) {
                if Retro.is8bit { panel(pick, now: now) } else { minimalPanel(pick, now: now) }
            } else {
                Color.clear
            }
        }
    }

    /// The minimal look: the meeting's title, one quiet line (when it starts or how long is left), the times, and Join as a plain button.
    private func minimalPanel(_ pick: LiveMeetingPanel.Pick, now: Date) -> some View {
        let event = pick.event
        let link = event.link
        return LiveRetroFrame(symbol: link != nil ? "video.fill" : "calendar", title: pick.inProgress ? "Meeting now" : "Next meeting",
                              short: "Meeting", tint: Retro.Ink.teal) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .circular).fill(event.color).frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title).font(.system(size: 13, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if pick.inProgress {
                        HStack(spacing: 5) {
                            Circle().fill(Color(red: 0.30, green: 0.80, blue: 0.45)).frame(width: 5, height: 5)
                            Text(verbatim: String(localized: "Now") + " · " + Self.left(pick.event.end.timeIntervalSince(now))).font(.system(size: 11.5)).foregroundStyle(NotchInk.secondary).lineLimit(1)
                        }
                    } else {
                        Text(Self.countdown(pick.event.start.timeIntervalSince(now)).prefix(1).uppercased() + Self.countdown(pick.event.start.timeIntervalSince(now)).dropFirst())
                            .font(.system(size: 11.5)).foregroundStyle(NotchInk.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            HStack(alignment: .center, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    Text(FeatureFormat.time(event.start) + " – " + FeatureFormat.time(event.end))
                    Text(FeatureFormat.time(event.start))
                }
                .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(NotchInk.secondary).lineLimit(1).fixedSize()
                Spacer(minLength: 4)
                if link != nil {
                    Button("Join") { join(event) }
                        .buttonStyle(.notchPillCompact).liveControl()
                }
            }
        }
    }

    /// A pager: the meeting on an LCD window, the countdown in pixel letters, the times in segments, Join as a plastic key.
    private func panel(_ pick: LiveMeetingPanel.Pick, now: Date) -> some View {
        let event = pick.event
        let link = event.link
        return LiveRetroFrame(symbol: link != nil ? "video.fill" : "calendar", title: pick.inProgress ? "Meeting now" : "Next meeting",
                              short: "Meeting", tint: Retro.Ink.teal) {
            Dash90LCD(padding: 6) {
                HStack(alignment: .top, spacing: 7) {
                    RoundedRectangle(cornerRadius: 1, style: .circular).fill(event.color).frame(width: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title).font(.system(size: 13, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .lastTextBaseline, spacing: 6) {
                                fact(pick, now: now, pixel: 1.5)
                                Spacer(minLength: 2)
                                if let link { Text(link.service).font(.system(size: 10)).foregroundStyle(NotchInk.tertiary).lineLimit(1) }
                            }
                            fact(pick, now: now, pixel: 1.5)
                            fact(pick, now: now, pixel: 1)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            HStack(alignment: .center, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        SevenSegmentText(Dash90Time.parts(event.start).trimmed, height: 12, color: Dash90.surfaceAmber, ghost: false)
                        Text(verbatim: "-").font(.system(size: 10, weight: .bold)).foregroundStyle(Dash90.surfaceAmber.opacity(0.8))
                        SevenSegmentText(Dash90Time.parts(event.end).trimmed, height: 12, color: Dash90.surfaceAmber, ghost: false)
                    }
                    SevenSegmentText(Dash90Time.parts(event.start).trimmed, height: 12, color: Dash90.surfaceAmber, ghost: false)
                }
                Spacer(minLength: 4)
                if link != nil {
                    Button("Join") { join(event) }
                        .buttonStyle(.retro(tint: Retro.Ink.teal)).liveControl()
                }
            }
        }
    }

    @ViewBuilder private func fact(_ pick: LiveMeetingPanel.Pick, now: Date, pixel: CGFloat) -> some View {
        if pick.inProgress {
            HStack(spacing: 6) {
                Dash90Lamp(text: "now", color: Retro.Ink.ledGreen)
                Dash90Text(Self.left(pick.event.end.timeIntervalSince(now)), pixel: pixel, color: Dash90.surfaceAmber)
            }
        } else {
            Dash90Text(Self.countdown(pick.event.start.timeIntervalSince(now)), pixel: pixel, color: Dash90.surfaceAmber)
        }
    }

    /// "in 12 min", and in the last minute "in 0:45".
    static func countdown(_ remaining: TimeInterval) -> String {
        if remaining < 60 { return String(localized: "in \(String(format: "0:%02d", min(59, max(0, Int(remaining.rounded(.up))))))") }
        return String(localized: "in \(LiveFormat.span(remaining))")
    }

    /// "20 min left", "< 1 min left".
    static func left(_ remaining: TimeInterval) -> String {
        remaining < 60 ? String(localized: "< 1 min left") : String(localized: "\(LiveFormat.span(remaining)) left")
    }
}
