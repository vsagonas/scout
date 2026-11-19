import AppKit
import SwiftUI

// B4 widgets for the Nook grid: Timer, Pomodoro, To-dos, Notes, Quick Apps. Sized for NookMetrics
// (span × 50 pt wide, 140 pt tall) and flexible: they fill whatever width the grid gives them.

private struct WidgetTitle: View {
    var symbol: String
    var title: String.LocalizationValue
    var short: String.LocalizationValue?
    var tint: Color
    var trailing: String?

    var body: some View {
        Dash90Title(title, short: short, symbol: symbol, tint: tint) {
            if let trailing { Dash90Text(trailing, pixel: 1, color: Look.osd) }
        }
    }
}

// MARK: - Timer

struct TimerWidgetView: View {
    @ObservedObject var clock: ClockService
    @State private var minutes = 5

    init(clock: ClockService? = nil) { self.clock = clock ?? ClockService.shared }

    private var shown: ClockTimer? { clock.timers.first(where: \.isRunning) ?? clock.timers.first }

    var body: some View {
        VStack(spacing: 5) {
            WidgetTitle(symbol: "timer", title: "Timer", tint: Retro.Ink.orange, trailing: clock.timers.count > 1 ? "+\(clock.timers.count - 1)" : nil)
            if let timer = shown { running(timer) } else { setup }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var setup: some View {
        VStack(spacing: 5) {
            Dash90LCD(padding: 4) {
                SevenSegmentText(String(format: "%02d:00", minutes), height: 30, color: Dash90.amber)
                    .frame(maxWidth: .infinity)
                    .background(ScrollCatcher { d in bump(d > 0 ? 1 : -1) })
                    .help("Scroll to change the minutes")
            }
            HStack(spacing: 4) {
                ForEach([1, 5, 10, 25], id: \.self) { m in
                    Button { minutes = m } label: {
                        Text(verbatim: "\(m)").font(.system(size: 10.5, weight: .heavy, design: .rounded)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.retro(tint: minutes == m ? (Retro.is8bit ? Retro.Ink.phosphorAmber : Theme.accent) : Retro.Ink.plasticMid, compact: true))
                }
            }
            Button { clock.addTimer(seconds: TimeInterval(minutes * 60)) } label: {
                Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.retro(tint: Retro.Ink.orange))
        }
        .frame(maxHeight: .infinity)
    }

    private func running(_ timer: ClockTimer) -> some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let remaining = timer.remaining(at: ctx.date)
                VStack(spacing: 6) {
                    Dash90LCD(padding: 5) {
                        SevenSegmentText(ProdFormat.clock(remaining), height: 30, color: timer.isRunning ? Dash90.amber : Dash90.amber.opacity(0.55))
                            .frame(maxWidth: .infinity)
                    }
                    LiveRetroBar(fraction: timer.duration > 0 ? 1 - remaining / timer.duration : 0, tint: Retro.Ink.orange, segments: 22, height: 11)
                }
            }
            HStack(spacing: 8) {
                Button { timer.isRunning ? clock.pauseTimer(timer.id) : clock.resumeTimer(timer.id) } label: {
                    Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.dash90Key(tint: timer.isRunning ? Retro.Ink.plasticMid : Retro.Ink.orange, width: 40, height: 22, lit: !timer.isRunning))
                Button { clock.cancelTimer(timer.id) } label: { Image(systemName: "xmark").font(.system(size: 9.5, weight: .black)) }
                    .buttonStyle(.dash90Key(width: 40, height: 22))
            }
            Spacer(minLength: 0)
        }
    }

    private func bump(_ d: Int) {
        let n = min(180, max(1, minutes + d))
        if n != minutes { minutes = n; Haptics.step() }
    }
}

// MARK: - Pomodoro

struct PomodoroWidgetView: View {
    @ObservedObject var clock: ClockService

    init(clock: ClockService? = nil) { self.clock = clock ?? ClockService.shared }

    var body: some View {
        let breaking = clock.pomodoro.phase.isBreak
        let tint: Color = breaking ? Retro.Ink.lime : Retro.Ink.red
        VStack(spacing: 5) {
            WidgetTitle(symbol: "leaf", title: "Pomodoro", short: "Pomo", tint: tint, trailing: clock.pomodoro.phase.title)
            Spacer(minLength: 0)
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let remaining = clock.pomodoroRemaining(at: ctx.date)
                let total = clock.duration(of: clock.pomodoro.phase)
                VStack(spacing: 5) {
                    Dash90LCD(padding: 4) {
                        SevenSegmentText(ProdFormat.clock(remaining), height: 26, color: breaking ? Dash90.green : Dash90.amber).frame(maxWidth: .infinity)
                    }
                    LiveRetroBar(fraction: total > 0 ? 1 - remaining / total : 0, tint: tint, segments: 22, height: 10)
                }
            }
            HStack(spacing: 5) {
                ForEach(0..<clock.sessionsBeforeLong, id: \.self) { i in
                    let done = i < clock.pomodoro.sessions % clock.sessionsBeforeLong
                    if Retro.is8bit {
                        Rectangle().fill(done ? Retro.Ink.ledGreen : Retro.Ink.ledGreen.opacity(0.18)).frame(width: 8, height: 5)
                    } else {
                        Circle().fill(done ? Look.ink(0.85) : Look.ink(0.18)).frame(width: 5, height: 5)
                    }
                }
            }
            HStack(spacing: 8) {
                Button { clock.togglePomodoro() } label: { Image(systemName: clock.pomodoro.isRunning ? "pause.fill" : "play.fill") }
                    .buttonStyle(.dash90Key(tint: clock.pomodoro.isRunning ? Retro.Ink.plasticMid : tint, width: 40, height: 22, lit: !clock.pomodoro.isRunning))
                Button { clock.skipPomodoro() } label: { Image(systemName: "forward.end.fill").font(.system(size: 9.5)) }
                    .buttonStyle(.dash90Key(width: 40, height: 22))
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - To-dos

struct TodoWidgetView: View {
    @ObservedObject var store: TodoStore
    @AppStorage("todo.showCompleted") private var showCompleted = true
    @State private var newTitle = ""

    init(store: TodoStore? = nil) { self.store = store ?? TodoStore.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Dash90Title("To-dos", short: "To-dos", symbol: "checklist", tint: Retro.Ink.purple) {
                HStack(spacing: 4) {
                    Dash90Text(String(localized: "\(store.openCount) open"), pixel: 1, color: Look.osd)
                    Button { showCompleted.toggle() } label: { Image(systemName: showCompleted ? "eye" : "eye.slash").font(.system(size: 8, weight: .bold)) }
                        .buttonStyle(.retro(compact: true)).help(showCompleted ? "Hide completed" : "Show completed").nookControl()
                }
            }
            HStack(spacing: 5) {
                Text(verbatim: "+").font(.system(size: 12, weight: .heavy, design: .monospaced)).foregroundStyle(Dash90.green)
                TextField("", text: $newTitle, prompt: Text("Add a task").foregroundStyle(Dash90.green.opacity(0.45)))
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Dash90.green)
                    .onSubmit { store.add(newTitle); newTitle = "" }
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .dash90Field()
            let open = store.openTasks
            let done = showCompleted ? store.doneTasks : []
            if open.isEmpty, done.isEmpty {
                Text("Nothing to do. Enjoy it.").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(open) { DashTodoRow(task: $0, store: store) }
                        ForEach(done) { DashTodoRow(task: $0, store: store) }
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// One to-do on the dashboard: an LCD box (a lit tick when done), the title, and a delete mark under the pointer.
private struct DashTodoRow: View {
    let task: TodoTask
    @ObservedObject var store: TodoStore
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button { store.toggle(task.id) } label: {
                Dash90Box(checked: task.done, tint: Dash90.green, size: 14).padding(3).contentShape(Rectangle())
            }
            .buttonStyle(.plain).nookControl()
            Text(task.title).font(.system(size: 12)).lineLimit(1).strikethrough(task.done).foregroundStyle(task.done ? Color.secondary : Color.primary)
            Spacer(minLength: 2)
            if hovering {
                Button { store.delete(task.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).nookControl()
            }
        }
        .frame(height: 21)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Notes

/// The Notes panel: the newest notes, one line each. A click on a note, or on +, opens the full Notes view (the list and the
/// editor) with that note chosen; a click on the rest of the panel opens it too.
struct NotesWidgetView: View {
    @ObservedObject var store: NotesStore
    @Environment(\.notchNavigator) private var navigator

    init(store: NotesStore? = nil) { self.store = store ?? NotesStore.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Dash90Title("Notes", symbol: "note.text", tint: Retro.Ink.yellow) {
                Button { store.add(); navigator.open(.notes) } label: { Image(systemName: "plus").font(.system(size: 8, weight: .black)) }
                    .buttonStyle(.retro(compact: true)).help("New note").nookControl()
            }
            let recent = store.recent(4)
            if recent.isEmpty {
                Text("No notes yet. Click + to write one.").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Dash90LCD(padding: 3) {
                    VStack(spacing: 0) {
                        ForEach(recent) { note in
                            HStack(spacing: 6) {
                                Text(note.title).font(.system(size: 11.5)).lineLimit(1)
                                Spacer(minLength: 2)
                                Dash90Text(ProdFormat.age(note.modified), pixel: 1, color: Dash90.amber.opacity(0.8))
                            }
                            .padding(.horizontal, 4)
                            .frame(height: 20)
                            .contentShape(Rectangle())
                            .onTapGesture { store.selectedID = note.id; navigator.open(.notes) }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Quick Apps

struct QuickAppsWidgetView: View {
    @ObservedObject var store: PinnedAppsStore

    init(store: PinnedAppsStore? = nil) { self.store = store ?? PinnedAppsStore.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetTitle(symbol: "square.grid.3x3", title: "Quick Apps", short: "Apps", tint: Retro.Ink.teal)
            if store.apps.isEmpty {
                VStack(spacing: 6) {
                    Text("No pinned apps yet.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Pin apps") { SettingsWindowController.shared.show(.nook) }.buttonStyle(.retro(compact: true))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Dash90LCD(padding: 6) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(store.apps) { app in
                            Button {
                                NotchNavigator.shared.forceClose()
                                store.open(app)
                            } label: {
                                Image(nsImage: AppIcons.icon(forPath: app.path)).resizable().frame(width: 26, height: 26)
                            }
                            .buttonStyle(.plain).help(app.name)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
