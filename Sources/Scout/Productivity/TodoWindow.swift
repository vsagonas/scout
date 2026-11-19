import AppKit
import SwiftUI

// B4 (P2) To-do window: a month calendar with a dot on every day that has tasks, the chosen day's list, and
// a focus timer per task (its minutes are added to the task when the session ends).

@MainActor
final class TodoWindowController {
    static let shared = TodoWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 780, height: 520),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = String(localized: "To-do")
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentMinSize = CGSize(width: 640, height: 420)
            w.contentView = NSHostingView(rootView: TodoWindowView())
            w.center()
            w.setFrameAutosaveName("Scout.TodoWindow")
            window = w
        }
        if let window { WindowFront.show(window) }
    }
}

struct TodoWindowView: View {
    @ObservedObject var store: TodoStore
    @ObservedObject var clock: ClockService
    @State private var month: Date
    @State private var selected: Date
    @State private var showAllOpen = false
    @State private var newTitle = ""
    /// Inside the notch (the To-dos panel's full view): no window background, snugger paddings.
    private let embedded: Bool

    init(store: TodoStore? = nil, clock: ClockService? = nil, day: Date = Date(), embedded: Bool = false) {
        self.embedded = embedded
        self.store = store ?? TodoStore.shared
        self.clock = clock ?? ClockService.shared
        _month = State(initialValue: day)
        _selected = State(initialValue: Calendar.current.startOfDay(for: day))
    }

    private var cal: Calendar { .current }

    var body: some View {
        HStack(spacing: 0) {
            calendarColumn.frame(width: 300).padding(embedded ? 12 : 20)
            Divider()
            tasksColumn.padding(embedded ? 12 : 20)
        }
        .background(embedded ? Color.clear : Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Calendar

    private var calendarColumn: some View {
        VStack(spacing: 12) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year())).font(.system(size: 17, weight: .semibold))
                Spacer()
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                Button { month = Date(); selected = cal.startOfDay(for: Date()) } label: { Text("Today").font(.system(size: 12)) }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                Button { shift(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
            }
            let symbols = orderedWeekdaySymbols()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, s in
                    Text(s).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                }
                ForEach(Array(gridDays().enumerated()), id: \.offset) { _, day in
                    if let day { dayCell(day) } else { Color.clear.frame(height: 38) }
                }
            }
            Spacer(minLength: 0)
            let open = store.openTasks.count
            Text("Open tasks in total: \(open)").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = cal.isDate(day, inSameDayAs: selected)
        let isToday = cal.isDateInToday(day)
        let tasks = store.tasks(on: day)
        let hasOpen = tasks.contains { !$0.done }
        return Button {
            selected = cal.startOfDay(for: day)
            showAllOpen = false
        } label: {
            VStack(spacing: 3) {
                Text(verbatim: "\(cal.component(.day, from: day))").font(.system(size: 13, weight: isToday ? .bold : .regular, design: .rounded)).monospacedDigit()
                Circle().fill(tasks.isEmpty ? Color.clear : (hasOpen ? Theme.accent : Color.secondary.opacity(0.6))).frame(width: 4.5, height: 4.5)
            }
            .frame(maxWidth: .infinity).frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isSelected && !showAllOpen ? Theme.accent.opacity(0.28) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(isToday ? Theme.accent.opacity(0.8) : .clear, lineWidth: 1.2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func shift(_ delta: Int) { month = cal.date(byAdding: .month, value: delta, to: month) ?? month }

    private func orderedWeekdaySymbols() -> [String] {
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Days of the month padded with nils so the first lands on the right weekday.
    private func gridDays() -> [Date?] {
        guard let interval = cal.dateInterval(of: .month, for: month), let range = cal.range(of: .day, in: .month, for: month) else { return [] }
        let weekday = cal.component(.weekday, from: interval.start)
        let lead = (weekday - cal.firstWeekday + 7) % 7
        var days: [Date?] = Array(repeating: nil, count: lead)
        for d in range { days.append(cal.date(byAdding: .day, value: d - 1, to: interval.start)) }
        return days
    }

    // MARK: Tasks

    private var shownTasks: [TodoTask] {
        showAllOpen ? store.openTasks : store.tasks(on: selected).sorted { !$0.done && $1.done }
    }

    private var tasksColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    (showAllOpen ? Text("All open tasks") : Text(verbatim: selected.formatted(.dateTime.weekday(.wide).day().month(.wide)))).font(.system(size: 20, weight: .semibold))
                    (showAllOpen ? Text("Across every day") : (cal.isDateInToday(selected) ? Text("Today") : Text(verbatim: selected.formatted(.relative(presentation: .named))))).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("All open", isOn: $showAllOpen).toggleStyle(.checkbox).controlSize(.small)
            }
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent)
                TextField(showAllOpen ? "Add a task (no day)" : "Add a task for this day", text: $newTitle).textFieldStyle(.plain).font(.system(size: 14)).onSubmit(add)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.07)))
            let tasks = shownTasks
            if tasks.isEmpty {
                ProdEmptyState(symbol: "checkmark.circle", message: showAllOpen ? "Nothing open." : "Nothing planned for this day.")
            } else {
                ScrollView {
                    VStack(spacing: 4) { ForEach(tasks) { TodoWindowRow(task: $0, store: store, clock: clock, showDay: showAllOpen) } }
                }
            }
        }
    }

    private func add() {
        store.add(newTitle, day: showAllOpen ? nil : selected)
        newTitle = ""
    }
}

struct TodoWindowRow: View {
    let task: TodoTask
    @ObservedObject var store: TodoStore
    @ObservedObject var clock: ClockService
    var showDay: Bool
    @State private var hovering = false

    var body: some View {
        let focus = clock.focusTimer(for: task.id)
        HStack(spacing: 10) {
            Button { store.toggle(task.id) } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle").font(.system(size: 18)).foregroundStyle(task.done ? Theme.accent : Color.secondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).font(.system(size: 14)).strikethrough(task.done).foregroundStyle(task.done ? .secondary : .primary).lineLimit(2)
                HStack(spacing: 8) {
                    if showDay, let day = task.day { Text(day.formatted(.dateTime.day().month(.abbreviated))).font(.system(size: 11)).foregroundStyle(.secondary) }
                    if task.focusMinutes > 0 { Label("\(task.focusMinutes) min focused", systemImage: "leaf").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
            }
            Spacer()
            if let focus {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(ProdFormat.clock(focus.remaining(at: ctx.date))).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Theme.accent)
                }
                Button { clock.cancelTimer(focus.id) } label: { Image(systemName: "stop.fill").font(.system(size: 10)) }.buttonStyle(.bordered).controlSize(.small).help("Stop focusing")
            } else if !task.done {
                Button { clock.addTimer(seconds: TimeInterval(clock.workMinutes * 60), label: String(localized: "Focus — \(task.title)"), taskID: task.id) } label: {
                    Label("Focus", systemImage: "leaf").font(.system(size: 11.5))
                }
                .buttonStyle(.bordered).controlSize(.small).help("Start a \(clock.workMinutes)-minute focus timer for this task")
            }
            if hovering { Button { store.delete(task.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hovering ? 0.08 : 0.05)))
        .onHover { hovering = $0 }
    }
}
