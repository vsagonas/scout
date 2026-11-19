import SwiftUI

/// Dashboard panel "Today": the day's remaining meetings and the open to-dos in one panel, and with nothing on, the date, the
/// time and the year. A click
/// on the panel opens the full Calendar; Join and the to-do checkboxes do their own thing. While it is pinned, the live Meeting
/// and To-dos panels stay away (`NookStore.liveItems`), since it shows both.
/// No title: the day screen sits on top and the day's meetings and to-dos are written under it
/// It follows the dashboard's grid (`DashGrid`), the same rows as CPU & Memory: row 1 the time (digits as tall as the CPU and memory ones),
/// row 2 the date,
/// then one grid row per meeting and to-do, or a quiet line when nothing is left.
/// The 90s look (R3): a pocket organiser: the time in amber LCD segments, Join as a plastic key, to-dos in square LCD boxes.
struct TodayWidgetView: View {
    @ObservedObject private var calendar = CalendarService.shared
    @ObservedObject private var todos = TodoStore.shared
    /// Gallery and self-tests: fixed meetings, to-dos, moment and battery instead of the real ones.
    var events: [CalEvent]?
    var tasks: [TodoTask]?
    var now: Date?
    var fixedBattery: BatteryState?
    /// Self-tests: what Join and a to-do box do (the real ones join the call and tick the to-do).
    var onJoin: ((CalEvent) -> Void)?
    var onToggle: ((UUID) -> Void)?

    /// Store screenshots only: the moment their scenes are set at (9:41, the time their menu bar shows). Nil everywhere else.
    nonisolated(unsafe) static var sceneMoment: Date?

    /// The quiet line when nothing is left today.
    static let emptyTitle = String(localized: "Nothing left today")

    var body: some View {
        TimelineView(.everyMinute) { context in
            let moment = now ?? Self.sceneMoment ?? context.date
            let plan = TodayPlan.make(events: eventsToday, tasks: tasks ?? todos.tasks, now: moment)
            VStack(alignment: .leading, spacing: 0) {
                timeReadout(moment)
                Color.clear.frame(height: DashGrid.readoutGap)
                dateLine(moment)
                Color.clear.frame(height: DashGrid.bodyGap)
                Group {
                    if plan.isEmpty {
                        DashEmpty(symbol: "calendar", title: .verbatim(Self.emptyTitle))
                    } else {
                        agenda(plan, now: moment)
                    }
                }
                .reportDashRow("body")
                Spacer(minLength: 0)
            }
            .padding(DashGrid.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .notchContent()
        .onAppear {
            if events == nil { calendar.start(); calendar.refresh() }
        }
    }

    /// Today's meetings, when Calendar is on and allowed (never asks for access).
    private var eventsToday: [CalEvent] {
        if let events { return events }
        switch calendar.access {
        case .granted, .sample: return calendar.eventsToday
        case .off, .needsAccess, .denied: return []
        }
    }

    /// Row 1: the time in LCD segments at the grid's digit height, AM or PM on their baseline (like the "%" beside the CPU digits). The day
    /// screen sits straight on the panel, one with the window: no LCD frame, no grey glass
    private func timeReadout(_ now: Date) -> some View {
        let parts = Dash90Time.parts(now)
        // The 8-bit LCD keeps its blank first cell (a faint 8, like a real clock); the minimal look starts the time at the panel's edge.
        let digits = Retro.is8bit ? parts.digits : parts.digits.trimmingCharacters(in: .whitespaces)
        return DashReadout {
            DashDigits(text: digits, color: Dash90.surfaceAmber)
            if let m = parts.meridiem { DashLabel(m, color: Dash90.surfaceAmber.opacity(0.85)) }
            Spacer(minLength: 0)
        }
    }

    /// Row 2: the weekday and the date with the year, in the info font ("Monday 16 November 2026"; shorter when the panel is narrow).
    private func dateLine(_ now: Date) -> some View {
        ViewThatFits(in: .horizontal) {
            dateText(now, month: .wide)
            dateText(now, month: .abbreviated)
            dateText(now, month: nil)
        }
    }

    private func dateText(_ now: Date, month: Date.FormatStyle.Symbol.Month?) -> some View {
        DashInfoLine {
            Text(now.formatted(.dateTime.weekday(month == nil ? .abbreviated : .wide))).font(DashGrid.infoFont(.semibold))
                .foregroundStyle(NotchInk.primary).fixedSize()
            Text(now.formatted(.dateTime.day().month(month ?? .abbreviated).year())).fixedSize()
            Spacer(minLength: 0)
        }
    }

    /// The meetings and to-dos, one grid row each, and at the bottom how many more and how many are overdue.
    private func agenda(_ plan: TodayPlan, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(plan.events) { event in
                Dash90EventRow(event: event, now: now, joinable: true, join: joinEvent)
            }
            ForEach(plan.tasks) { task in todoRow(task, now: now, inTimeColumn: !plan.events.isEmpty) }
            if plan.more > 0 || plan.overdue > 0 {
                HStack(spacing: 6) {
                    if plan.more > 0 { DashMore(count: plan.more) }
                    Spacer(minLength: 0)
                    if plan.overdue > 0 { Dash90Lamp(text: "\(plan.overdue) overdue") }
                }
                .frame(height: DashGrid.moreHeight)
            }
        }
    }

    /// A to-do. Under meetings its box stands in the time column, so its title starts where a meeting's title does; with no meeting in the
    /// list the box stands at the panel's left edge, where every panel's first letters start.
    private func todoRow(_ task: TodoTask, now: Date, inTimeColumn: Bool) -> some View {
        let overdue = TodayPlan.rank(task, now: now) == 0
        return HStack(spacing: Dash90EventRow.gap) {
            if inTimeColumn { Color.clear.frame(width: Dash90EventRow.tickWidth, height: 1) }
            Button { toggle(task) } label: {
                Dash90Box(checked: false, tint: overdue ? Retro.Ink.ledRed : Dash90.green, size: 14)
                    .padding(.vertical, 4).padding(.leading, inTimeColumn ? 12 : 0).padding(.trailing, inTimeColumn ? 0 : 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .nookControl()
            .help("Mark as done")
            .frame(width: inTimeColumn ? Dash90EventRow.timeWidth : nil, alignment: .trailing)
            Text(task.title).font(DashGrid.rowTitle).lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: DashGrid.rowHeight)
    }

    private func joinEvent(_ event: CalEvent) {
        if let onJoin { onJoin(event) } else { CalendarService.shared.join(event) }
    }

    private func toggle(_ task: TodoTask) {
        if let onToggle { onToggle(task.id) } else if tasks == nil { todos.toggle(task.id) }
    }
}

/// One line of a dashboard list in the 90s look, one grid row (`DashGrid.rowHeight`): a colour tick, the time in small LCD segments, the
/// title in the row font with "Now" or the place beside it, and, when the meeting is about to start, Join as a plastic key. (The Calendar's
/// own view keeps `EventRow`.)
struct Dash90EventRow: View {
    let event: CalEvent
    let now: Date
    var joinable = false
    var join: (CalEvent) -> Void = { CalendarService.shared.join($0) }

    /// The columns every agenda row shares (a to-do's box stands in the time column).
    static let tickWidth: CGFloat = 3
    static let timeWidth: CGFloat = 42
    static let gap: CGFloat = 6

    private var inProgress: Bool { !event.isAllDay && event.start <= now && event.end > now }
    private var soon: Bool { !event.isAllDay && event.start > now && event.start.timeIntervalSince(now) < 15 * 60 }

    var body: some View {
        HStack(spacing: Self.gap) {
            RoundedRectangle(cornerRadius: 1, style: .circular).fill(event.color).frame(width: Self.tickWidth, height: 14)
            Group {
                if event.isAllDay {
                    Dash90Text(pixelLabel("ALL DAY"), pixel: 1, color: Dash90.surfaceAmber)
                } else {
                    SevenSegmentText(Dash90Time.parts(event.start).trimmed, height: 10, color: Dash90.surfaceAmber, ghost: false)
                }
            }
            .frame(width: Self.timeWidth, alignment: .trailing)
            Text(event.title).font(DashGrid.rowTitle).lineLimit(1).layoutPriority(1)
            if inProgress {
                Text("Now").font(DashGrid.infoFont(.semibold)).foregroundStyle(Dash90.surfaceGreen).fixedSize()
            } else if let place = event.location, !place.isEmpty, event.link == nil {
                Text(place).font(DashGrid.infoFont()).foregroundStyle(NotchInk.tertiary).lineLimit(1)
            }
            Spacer(minLength: 2)
            if joinable, event.link != nil, inProgress || soon {
                Button("Join") { join(event) }.buttonStyle(.retro(tint: Retro.Ink.teal, compact: true)).fixedSize().nookControl()   // the title gives way, never the key
            } else if event.link != nil {
                Image(systemName: "video.fill").font(.system(size: 9)).foregroundStyle(NotchInk.tertiary)
            }
        }
        .frame(height: DashGrid.rowHeight)
    }
}

/// What Today shows: the remaining timed meetings first, then the open to-dos (overdue, today, undated; later ones wait for
/// their day), at most `capacity` lines and "+N more".
struct TodayPlan {
    var events: [CalEvent]
    var tasks: [TodoTask]
    var more: Int
    var overdue: Int
    var isEmpty: Bool { events.isEmpty && tasks.isEmpty }

    /// The words after the battery percentage (nil while macOS is still estimating).
    static func batteryDetail(_ b: BatteryState) -> String? {
        if b.isCharged || (b.isPluggedIn && !b.isCharging && b.level >= 99) { return String(localized: "charged") }
        if b.isPluggedIn && !b.isCharging { return String(localized: "plugged in") }
        guard let minutes = b.minutesRemaining, minutes > 0 else { return nil }
        let span = Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return b.isCharging ? String(localized: "full in \(span)") : String(localized: "\(span) left")
    }

    /// 0 overdue, 1 today, 2 no day, 3 a later day.
    static func rank(_ task: TodoTask, now: Date) -> Int {
        guard let day = task.day else { return 2 }
        let cal = Calendar.current
        let d = cal.startOfDay(for: day), today = cal.startOfDay(for: now)
        return d < today ? 0 : (d == today ? 1 : 3)
    }

    static func make(events: [CalEvent], tasks: [TodoTask], now: Date, capacity: Int = 3) -> TodayPlan {
        let timed = events.filter { !$0.isAllDay && $0.end > now }.sorted { $0.start < $1.start }
        let open = tasks.filter { !$0.done && rank($0, now: now) < 3 }
            .sorted { (rank($0, now: now), $0.created) < (rank($1, now: now), $1.created) }
        let eventRows = Array(timed.prefix(open.isEmpty ? capacity : max(1, capacity - 1)))
        let taskRows = Array(open.prefix(max(0, capacity - eventRows.count)))
        let more = (timed.count - eventRows.count) + (open.count - taskRows.count)
        return TodayPlan(events: eventRows, tasks: taskRows, more: more, overdue: open.filter { rank($0, now: now) == 0 }.count)
    }
}
