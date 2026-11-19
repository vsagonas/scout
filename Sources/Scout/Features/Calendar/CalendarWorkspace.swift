import SwiftUI

/// Calendar workspace: the month grid with event dots on the left, the chosen day's agenda (or the new-event composer) beside it, and
/// the to-do list beside that. One day is picked in the
/// month: the agenda shows its events and the to-do list its tasks. In a narrow island the to-dos go under the month and the agenda, in
/// two columns; the to-dos work with Calendar access off too.
struct CalendarWorkspaceView: View {
    @ObservedObject private var service = CalendarService.shared
    @ObservedObject private var todos: TodoStore
    @ObservedObject private var clock: ClockService
    @State private var month = Calendar.current.startOfDay(for: Date())
    @State private var selected = Calendar.current.startOfDay(for: Date())
    @State private var composing = false
    @State private var showAllOpen = false
    @State private var monthEvents: [CalEvent] = []
    /// The notch this view stands in (it asks it for its height).
    @Environment(\.notchNavigator) private var navigator
    /// The three columns stand side by side (else the to-dos go under the month).
    @State private var wide = true
    private let previewAccess: CalendarAccess?

    /// Gallery only: start in the composer, on "All open" or on another day, as if the calendar were off; a to-do store and clock of
    /// its own (never the shared ones).
    init(previewComposing: Bool = false, previewAllOpen: Bool = false, previewDay: Date? = nil, previewAccess: CalendarAccess? = nil,
         store: TodoStore? = nil, clock: ClockService? = nil) {
        _composing = State(initialValue: previewComposing)
        _showAllOpen = State(initialValue: previewAllOpen)
        if let previewDay {
            _month = State(initialValue: Calendar.current.startOfDay(for: previewDay))
            _selected = State(initialValue: Calendar.current.startOfDay(for: previewDay))
        }
        self.previewAccess = previewAccess
        _todos = ObservedObject(wrappedValue: store ?? TodoStore.shared)
        _clock = ObservedObject(wrappedValue: clock ?? ClockService.shared)
    }

    private let cal = Calendar.current

    /// The view's inner width (its own 16 pt padding left and right taken off) from which the month, the agenda and the to-dos stand in
    /// three columns: the month 252, the agenda at least 270, the to-dos at least 270, and the gaps and rules between.
    static let threeColumnsFrom: CGFloat = 840
    /// The month column's height: its heading 22, the weekday letters 12, six rows of 21, and 3 between the three.
    static let monthHeight: CGFloat = 166

    /// What the island adds around the view: the header 32, 6 above and 16 below it, the view's own 10 + 10.
    static let islandChrome: CGFloat = 74

    /// The island height (header included) the view needs for what it shows: wide, the month, or the picked day's events or to-dos when
    /// they need more (up to the old fixed height); narrow, the old fixed height (the to-dos under the month).
    /// a fixed 400 pt left half of it empty under a day with one event and one to-do.
    static func islandHeight(wide: Bool, calendarReady: Bool, events: Int, tasks: Int) -> CGFloat {
        guard wide else { return NotchPrefs.calendarTallHeight }
        let agenda = calendarReady ? 42 + CGFloat(max(1, events)) * 44 : 200   // its heading, then a 40 pt row and a gap each
        let todos = 37 + 41 + CGFloat(max(1, tasks)) * 46                       // the heading, the add field, then a 40 pt row and a gap each
        return min(NotchPrefs.calendarTallHeight - islandChrome, max(monthHeight, agenda, todos)) + islandChrome
    }

    private var neededHeight: CGFloat {
        let events = monthEvents.filter { $0.isOn(selected) }.count
        let tasks = showAllOpen ? todos.openTasks.count : todos.tasks(on: selected).count
        return Self.islandHeight(wide: wide, calendarReady: calendarReady, events: composing ? 6 : events, tasks: tasks)
    }

    /// Asks the notch it stands in (the app's, or a test's own) for the height of what it shows.
    private func syncHeight() {
        navigator.requestHeight(neededHeight, resizeMax: nil, by: .calendar)
    }

    private var access: CalendarAccess { previewAccess ?? service.access }
    private var calendarReady: Bool { access == .granted || access == .sample }

    var body: some View {
        GeometryReader { geo in
            let inner = geo.size.width - 32
            Group {
                if !calendarReady { withoutCalendar(inner) }
                else if inner >= Self.threeColumnsFrom { threeColumns(inner) }
                else { stacked }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .onAppear { wide = inner >= Self.threeColumnsFrom }
            .onChange(of: inner >= Self.threeColumnsFrom) { _, isWide in wide = isWide }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .notchContent()
        .onAppear { service.start(); service.refresh(); reload(); syncHeight() }
        .onChange(of: neededHeight) { syncHeight() }
        // Coming back to the tab quickly keeps the view alive, so it asks again whenever the notch switches to it (as the Agents view does).
        .onReceive(navigator.$workspace) { kind in
            if NotchPrefs.resolve(kind) == .calendar { DispatchQueue.main.async { syncHeight() } }
        }
        .onDisappear { navigator.releaseHeight(by: .calendar) }
        .onChange(of: month) { reload() }
        .onReceive(service.$eventsToday) { _ in reload() }
        .onReceive(service.$access) { _ in reload() }
    }

    private var rule: some View { Rectangle().fill(NotchInk.hairline).frame(width: 1) }

    private var todosColumn: some View {
        CalendarTodosColumn(store: todos, clock: clock, day: selected, showAllOpen: $showAllOpen).reportRect("cal.todos")
    }

    /// The width of the to-do column in the wide layout: half of what the month leaves, between 270 and 380.
    private func todoWidth(_ inner: CGFloat) -> CGFloat { min(380, max(270, (inner - 252 - 4 * 16 - 2) / 2)) }

    /// Wide: the month, the agenda (or the composer) and the to-dos side by side.
    private func threeColumns(_ inner: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 16) {
            monthColumn.frame(width: 252).reportRect("cal.month")
            rule
            if composing {
                composer
            } else {
                agendaColumn.reportRect("cal.agenda")
            }
            rule
            todosColumn.frame(width: todoWidth(inner))
        }
    }

    /// Narrow: the month and the agenda (or the composer) in a strip as high as the month, the to-dos under them across the whole width.
    private var stacked: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                monthColumn.frame(width: 252).reportRect("cal.month")
                rule
                if composing { composer } else { agendaColumn.reportRect("cal.agenda") }
            }
            .frame(height: Self.monthHeight)
            Rectangle().fill(NotchInk.hairline).frame(height: 1)
            CalendarTodosColumn(store: todos, clock: clock, day: selected, showAllOpen: $showAllOpen, compact: true).reportRect("cal.todos")
        }
    }

    /// Calendar off, waiting for access or refused: what to do about it on the left, the to-dos (they need no access) on the right.
    private func withoutCalendar(_ inner: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Group {
                switch access {
                case .off:
                    NotchEmptyState(symbol: "calendar", message: "Your calendar, in the notch",
                                    detail: "See the month, your agenda and a Join button for video calls.",
                                    actionTitle: "Turn on Calendar") { service.requestAccess() }
                case .needsAccess:
                    NotchEmptyState(symbol: "calendar.badge.exclamationmark", message: "Allow calendar access",
                                    detail: "macOS will ask once. Events stay on this Mac.", actionTitle: "Allow access") { service.requestAccess() }
                default:
                    NotchEmptyState(symbol: "calendar.badge.exclamationmark", message: "Calendar access is off",
                                    detail: "Turn it on for Scout in System Settings › Privacy & Security › Calendars.",
                                    actionTitle: "Open System Settings") { Permissions.openSettings(.calendars) }
                }
            }
            .reportRect("cal.empty")
            rule
            todosColumn.frame(width: todoWidth(inner))
        }
    }

    private var composer: some View {
        EventComposer(day: $selected, calendars: service.calendars.filter(\.allowsEditing)) { composing = false }
    }

    // MARK: Month

    private var gridDays: [Date] {
        guard let first = cal.dateInterval(of: .month, for: month)?.start else { return [] }
        let weekday = cal.component(.weekday, from: first)
        let lead = (weekday - cal.firstWeekday + 7) % 7
        guard let start = cal.date(byAdding: .day, value: -lead, to: first) else { return [] }
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    private func reload() {
        let days = gridDays
        guard let first = days.first, let last = days.last, let end = cal.date(byAdding: .day, value: 1, to: last) else { return }
        monthEvents = service.events(from: first, to: end)
    }

    private var monthColumn: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Text(month.formatted(.dateTime.month(.wide).year())).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7).layoutPriority(1)   // a longer month name or "Today" shrinks, never cuts
                Spacer(minLength: 2)
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(NotchIconButtonStyle(size: 20))
                Button("Today") { month = cal.startOfDay(for: service.now); selected = month; showAllOpen = false }.buttonStyle(.notchPillCompact).lineLimit(1).minimumScaleFactor(0.6)
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(NotchIconButtonStyle(size: 20))
            }
            .frame(height: 22)
            let symbols = weekdaySymbols
            HStack(spacing: 0) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, s in
                    Text(s).font(.system(size: 9, weight: .semibold)).foregroundStyle(NotchInk.tertiary).frame(maxWidth: .infinity)
                }
            }
            .frame(height: 12)
            let days = gridDays
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { col in
                            if row * 7 + col < days.count { dayCell(days[row * 7 + col]) }
                        }
                    }
                }
            }
        }
    }

    private var weekdaySymbols: [String] {
        let s = cal.veryShortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(s[first...] + s[..<first])
    }

    private func shiftMonth(_ delta: Int) {
        if let m = cal.date(byAdding: .month, value: delta, to: month) { month = m }
    }

    private func dayCell(_ day: Date) -> some View {
        let inMonth = cal.isDate(day, equalTo: month, toGranularity: .month)
        let isToday = cal.isDate(day, inSameDayAs: service.now)
        let isSelected = cal.isDate(day, inSameDayAs: selected)
        let colors = Array(NSOrderedSet(array: monthEvents.filter { $0.isOn(day) }.map(\.colorHex)).array as? [String] ?? []).prefix(3)
        let tasks = todos.tasks(on: day)
        let hasOpenTask = tasks.contains { !$0.done }
        return Button { selected = cal.startOfDay(for: day); showAllOpen = false } label: {
            VStack(spacing: 1) {
                Text(verbatim: "\(cal.component(.day, from: day))")
                    .font(.system(size: 11, weight: isToday ? .bold : .regular)).monospacedDigit()
                    .foregroundStyle(isSelected && isToday ? Color.black.opacity(0.85) : (isToday ? Theme.accent : (inMonth ? NotchInk.primary : NotchInk.tertiary)))
                HStack(spacing: 2) {
                    ForEach(Array(colors.enumerated()), id: \.offset) { _, hex in
                        Circle().fill(Color(hex: hex) ?? Theme.accent).frame(width: 3.5, height: 3.5)
                    }
                    // A to-do on this day: a small square (the events' dots are round); lit while one is open, dim when all are done.
                    if !tasks.isEmpty {
                        RoundedRectangle(cornerRadius: 0.8, style: .continuous)
                            .fill(hasOpenTask ? (isSelected && isToday ? Color.black.opacity(0.7) : Theme.accent) : NotchInk.tertiary)
                            .frame(width: 3.5, height: 3.5)
                    }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity).frame(height: 21)
            .background {
                if isSelected { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isToday ? Theme.accent.opacity(0.9) : NotchInk.tileStrong) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Agenda

    private var agendaColumn: some View {
        let events = monthEvents.filter { $0.isOn(selected) }.sorted(by: CalendarService.order)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    (cal.isDateInToday(selected) ? Text("Today") : Text(verbatim: selected.formatted(.dateTime.weekday(.wide))))
                        .font(.system(size: 13, weight: .semibold))
                    Text(selected.formatted(.dateTime.month(.wide).day().year())).font(.system(size: 10)).foregroundStyle(NotchInk.secondary)
                }
                Spacer()
                if service.access == .granted {
                    Button { composing = true } label: { Label("New event", systemImage: "plus") }.buttonStyle(.notchPillCompact)
                }
            }
            if events.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle").font(.system(size: 18)).foregroundStyle(NotchInk.tertiary)
                    Text("Nothing planned").font(.system(size: 12, weight: .medium)).foregroundStyle(NotchInk.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(events) { e in AgendaRow(event: e, day: selected, now: service.now) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct AgendaRow: View {
    let event: CalEvent
    let day: Date
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(event.color).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    Text(event.timeText(on: day)).monospacedDigit()
                    if let place = event.location, !place.isEmpty, event.link == nil {
                        Text("·  " + place).lineLimit(1)
                    } else if let link = event.link {
                        Text("·  " + link.service).lineLimit(1)
                    }
                }
                .font(.system(size: 10)).foregroundStyle(NotchInk.secondary)
            }
            Spacer(minLength: 4)
            if event.link != nil { Button("Join") { CalendarService.shared.join(event) }.buttonStyle(.notchPillCompact) }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(height: 34)
        .notchTile(radius: 8)
    }
}

// MARK: - New event

struct EventComposer: View {
    let calendars: [CalSource]
    var onDone: () -> Void
    /// The day shared with the month grid beside the composer: clicking a day there changes it.
    @Binding var day: Date
    @State private var draft = CalendarService.Draft()
    @FocusState private var titleFocused: Bool

    init(day: Binding<Date>, calendars: [CalSource], onDone: @escaping () -> Void) {
        self.calendars = calendars
        self.onDone = onDone
        _day = day
        var d = CalendarService.Draft()
        let cal = Calendar.current
        d.day = day.wrappedValue
        let nextHour = cal.date(bySetting: .minute, value: 0, of: Date().addingTimeInterval(3600)) ?? Date()
        d.start = nextHour
        d.end = nextHour.addingTimeInterval(3600)
        d.calendarID = calendars.first?.id ?? ""
        _draft = State(initialValue: d)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("New event").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Cancel") { onDone() }.buttonStyle(.notchPillCompact)
                Button("Add") {
                    var final = draft
                    final.day = day
                    if CalendarService.shared.save(final) { Toast.show("Event added", symbol: "calendar.badge.plus"); onDone() }
                }
                    .buttonStyle(NotchPillButtonStyle(prominent: true, compact: true))
            }
            TextField("Title", text: $draft.title)
                .textFieldStyle(.roundedBorder).focused($titleFocused)
            HStack(spacing: 8) {
                DatePicker("", selection: $day, displayedComponents: .date).labelsHidden().datePickerStyle(.compact)
                Toggle("All day", isOn: $draft.isAllDay).toggleStyle(.checkbox).font(.system(size: 11))
                if !draft.isAllDay {
                    DatePicker("", selection: $draft.start, displayedComponents: .hourAndMinute).labelsHidden().datePickerStyle(.compact)
                    Text(verbatim: "–").foregroundStyle(NotchInk.secondary)
                    DatePicker("", selection: $draft.end, displayedComponents: .hourAndMinute).labelsHidden().datePickerStyle(.compact)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                TextField("Location or meeting link", text: $draft.location).textFieldStyle(.roundedBorder)
                if calendars.count > 1 {
                    Picker("", selection: $draft.calendarID) {
                        ForEach(calendars) { c in Text(c.title).tag(c.id) }
                    }
                    .labelsHidden().frame(width: 110)
                }
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { NotchNavigator.shared.hold("calendar.composer"); titleFocused = true }
        .onDisappear { NotchNavigator.shared.release("calendar.composer") }
    }
}
