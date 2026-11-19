import SwiftUI

// The to-do list inside the Calendar view. The to-dos used to have a tab of their own (a second month, the day's tasks beside it).
// The Calendar's month is the one calendar now: a day picked there shows
// that day's events AND that day's to-dos, and a day with open to-dos carries a small square under its number.
// What the old To-dos view did stays: add a task for the day (or for no day), tick one off, delete it, the focus timer per task, and
// "All open" for every open task whatever its day.

struct CalendarTodosColumn: View {
    @ObservedObject var store: TodoStore
    @ObservedObject var clock: ClockService
    /// The day the month has picked.
    let day: Date
    /// True: every open task, whatever its day (the old view's "All open").
    @Binding var showAllOpen: Bool
    /// A wide, short strip (the narrow island, under the month and the agenda): the heading, the add field and "All open" on one line, the
    /// tasks in two columns.
    var compact = false
    @Environment(\.notchNavigator) private var navigator
    @State private var newTitle = ""
    @FocusState private var addFocused: Bool

    private var cal: Calendar { .current }

    /// The tasks on show: the open ones of every day, or the picked day's (open first, then the done ones).
    var shown: [TodoTask] {
        showAllOpen ? store.openTasks : store.tasks(on: day).sorted { !$0.done && $1.done }
    }

    private var subtitle: String {
        if showAllOpen { return String(localized: "Every open task, any day") }
        let open = store.openCount
        if cal.isDateInToday(day) { return String(localized: "Today · \(open) open in total") }
        let date = day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return String(localized: "\(date) · \(open) open in total")
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("To-dos").font(.system(size: 13, weight: .semibold))
            Text(subtitle).font(.system(size: 10)).foregroundStyle(NotchInk.secondary).lineLimit(1)
        }
    }

    private var allOpenChip: some View {
        NotchChip(title: "All open", symbol: showAllOpen ? "checkmark" : nil, selected: showAllOpen) { showAllOpen.toggle() }
            .help(showAllOpen ? "Show the picked day's to-dos" : "Show every open to-do, whatever its day")
            .reportRect("cal.todos.all")
    }

    private var addField: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.accent)
            TextField(showAllOpen ? "Add a task (no day)" : "Add a task for this day", text: $newTitle)
                .textFieldStyle(.plain).font(.system(size: 12)).focused($addFocused).onSubmit(add)
        }
        .padding(.horizontal, 9).frame(height: 28)
        .notchTile(radius: 8)
        .reportRect("cal.todos.add")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if compact {
                HStack(spacing: 12) {
                    heading.fixedSize()
                    addField
                    allOpenChip
                }
            } else {
                HStack(alignment: .top) {
                    heading
                    Spacer(minLength: 4)
                    allOpenChip
                }
                addField
            }
            list
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: addFocused) { _, typing in
            // The notch stays open while a task is being typed (the pointer may rest elsewhere).
            if typing { navigator.hold("calendar.todo") } else { navigator.release("calendar.todo") }
        }
        .onDisappear { navigator.release("calendar.todo") }
    }

    @ViewBuilder private var list: some View {
        let tasks = shown
        if tasks.isEmpty {
            VStack(spacing: 4) {
                Image(systemName: "checkmark.circle").font(.system(size: 18)).foregroundStyle(NotchInk.tertiary)
                Text(showAllOpen ? "Nothing open" : "Nothing planned").font(.system(size: 12, weight: .medium)).foregroundStyle(NotchInk.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .top), count: compact ? 2 : 1), spacing: 3) {
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                        CalendarTodoRow(task: task, store: store, clock: clock, showDay: showAllOpen, compact: compact, tickName: "cal.todos.tick.\(index)").reportRect("cal.todos.row.\(index)")
                    }
                }
            }
            .reportRect("cal.todos.list")
        }
    }

    private func add() {
        store.add(newTitle, day: showAllOpen ? nil : day)
        newTitle = ""
    }
}

/// One to-do: a box to tick (an LCD box in the 8-bit look, a square in the minimal one), the title, the day it is planned for when the list
/// spans days, the minutes focused, the focus timer, and a delete mark under the pointer (the right-click menu deletes too).
struct CalendarTodoRow: View {
    let task: TodoTask
    @ObservedObject var store: TodoStore
    @ObservedObject var clock: ClockService
    var showDay: Bool
    /// In the narrow island's two columns the Focus key is just its leaf, so a title keeps its line.
    var compact = false
    /// The name the tick box reports its rect under (self-tests click it).
    var tickName = "cal.todos.tick"
    @State private var hovering = false

    private var overdue: Bool {
        guard !task.done, let day = task.day else { return false }
        return day < Calendar.current.startOfDay(for: Date())
    }

    var body: some View {
        let focus = clock.focusTimer(for: task.id)
        HStack(spacing: 8) {
            Button { store.toggle(task.id) } label: {
                Dash90Box(checked: task.done, tint: overdue ? Retro.Ink.ledRed : Dash90.green, size: 16)
                    .padding(2).contentShape(Rectangle())
                    .reportRect(tickName)
            }
            .buttonStyle(.plain)
            .help(task.done ? "Mark as not done" : "Mark as done")
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title).font(.system(size: 12, weight: .medium)).strikethrough(task.done)
                    .foregroundStyle(task.done ? NotchInk.secondary : NotchInk.primary).lineLimit(2)
                if let line = detail {
                    Text(line).font(.system(size: 10)).foregroundStyle(overdue ? Look.accent(Retro.Ink.ledRed) : NotchInk.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let focus {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(ProdFormat.clock(focus.remaining(at: ctx.date))).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Theme.accent)
                }
                Button { clock.cancelTimer(focus.id) } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(NotchIconButtonStyle(size: 20)).help("Stop focusing")
            } else if !task.done {
                Button { clock.addTimer(seconds: TimeInterval(clock.workMinutes * 60), label: String(localized: "Focus — \(task.title)"), taskID: task.id) } label: {
                    Label("Focus", systemImage: "leaf").labelStyle(CalendarFocusLabel(iconOnly: compact))
                }
                .buttonStyle(.notchPillCompact).help("Start a \(clock.workMinutes)-minute focus timer for this task")
            }
            if hovering {
                Button { store.delete(task.id) } label: { Image(systemName: "trash").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(NotchInk.secondary).help("Delete")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(minHeight: 34)
        .notchTile(radius: 8, fill: hovering ? NotchInk.tileStrong : NotchInk.tile)
        .onHover { hovering = $0 }
        .contextMenu { Button("Delete", role: .destructive) { store.delete(task.id) } }
    }

    /// "Overdue · 14 Nov", "16 Nov", "25 min focused": the second line, when there is something to say.
    private var detail: String? {
        var parts: [String] = []
        if overdue { parts.append(String(localized: "Overdue")) }
        if showDay || overdue, let day = task.day { parts.append(day.formatted(.dateTime.day().month(.abbreviated))) }
        if task.focusMinutes > 0 { parts.append(String(localized: "\(task.focusMinutes) min focused")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The Focus key's label: the leaf and the word, or the leaf alone.
private struct CalendarFocusLabel: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        if iconOnly { configuration.icon } else { Label(configuration) }
    }
}
