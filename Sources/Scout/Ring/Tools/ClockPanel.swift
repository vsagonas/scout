import AppKit
import SwiftUI

@MainActor
enum ClockPanel {
    static func show(tab: ClockTab? = nil) {
        if let tab { ClockService.shared.requestedTab = tab }
        ToolPanels.show("clock", size: CGSize(width: 380, height: 440), minSize: CGSize(width: 340, height: 380), resizable: true) {
            ClockPanelView()
        }
    }
}

@MainActor
struct ClockPanelView: View {
    @ObservedObject var clock: ClockService
    @State private var tab: ClockTab

    init(clock: ClockService? = nil, tab: ClockTab? = nil) {
        let clock = clock ?? ClockService.shared
        self.clock = clock
        _tab = State(initialValue: tab ?? clock.requestedTab ?? ClockTab(rawValue: ToolMemory.string(ToolMemory.clockTab) ?? "") ?? .timer)
    }

    var body: some View {
        ToolPanelFrame("Clock", symbol: "timer") {
            VStack(spacing: 12) {
                Picker("", selection: $tab) {
                    ForEach(ClockTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 14)
                Group {
                    switch tab {
                    case .timer: TimerTabView(clock: clock)
                    case .stopwatch: StopwatchTabView(clock: clock)
                    case .pomodoro: PomodoroTabView(clock: clock)
                    case .alarms: AlarmsTabView(clock: clock)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.bottom, 12)
        }
        .onChange(of: clock.requestedTab) { _, new in if let new { tab = new; clock.requestedTab = nil } }
        .onChange(of: tab) { _, new in ToolMemory.set(new.rawValue, ToolMemory.clockTab) }
        .onAppear { clock.requestedTab = nil }
    }
}

// MARK: Timer

struct TimerTabView: View {
    @ObservedObject var clock: ClockService
    @State private var minutes = 10
    @State private var seconds = 0

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                NumberStepper(value: $minutes, range: 0...600, label: "min")
                Text(verbatim: ":").font(.system(size: 34, weight: .light, design: .rounded)).foregroundStyle(.secondary).padding(.horizontal, 4)
                NumberStepper(value: $seconds, range: 0...59, label: "sec")
            }
            HStack(spacing: 6) {
                ForEach([1, 5, 10, 25], id: \.self) { m in
                    Button("\(m) min") { minutes = m; seconds = 0 }.buttonStyle(.bordered).controlSize(.small)
                }
            }
            Button {
                clock.addTimer(seconds: TimeInterval(minutes * 60 + seconds))
            } label: { Label("Start timer", systemImage: "play.fill").frame(minWidth: 130) }
            .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
            .disabled(minutes * 60 + seconds == 0)

            if clock.timers.isEmpty {
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(clock.timers) { TimerRow(timer: $0, clock: clock) }
                    }
                    .padding(.horizontal, 14)
                }
            }
        }
    }
}

struct TimerRow: View {
    let timer: ClockTimer
    @ObservedObject var clock: ClockService

    var body: some View {
        HStack(spacing: 10) {
            ProgressRing(progress: progressValue(Date()), lineWidth: 3).frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    Text(ProdFormat.clock(timer.remaining(at: ctx.date)))
                        .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                Text(verbatim: timer.label.isEmpty ? String(localized: "\(ProdFormat.clock(timer.duration)) timer") : timer.label)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button {
                timer.isRunning ? clock.pauseTimer(timer.id) : clock.resumeTimer(timer.id)
            } label: { Image(systemName: timer.isRunning ? "pause.fill" : "play.fill") }
            .buttonStyle(.bordered).controlSize(.small)
            Button { clock.cancelTimer(timer.id) } label: { Image(systemName: "xmark") }.buttonStyle(.bordered).controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func progressValue(_ now: Date) -> Double {
        guard timer.duration > 0 else { return 0 }
        return 1 - timer.remaining(at: now) / timer.duration
    }
}

/// A big number you can scroll or step (Haptics.step on each change).
struct NumberStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var label: LocalizedStringKey

    var body: some View {
        VStack(spacing: 2) {
            Button { bump(1) } label: { Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold)) }.buttonStyle(.plain).foregroundStyle(.secondary)
            Text(verbatim: String(format: "%02d", value))
                .font(.system(size: 46, weight: .semibold, design: .rounded)).monospacedDigit()
                .frame(minWidth: 72)
                .background(ScrollCatcher { delta in bump(delta > 0 ? 1 : -1) })
            Button { bump(-1) } label: { Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)) }.buttonStyle(.plain).foregroundStyle(.secondary)
            Text(label).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func bump(_ d: Int) {
        let n = min(range.upperBound, max(range.lowerBound, value + d))
        if n != value { value = n; Haptics.step() }
    }
}

/// Reports vertical scroll-wheel movement over its area (SwiftUI has no scroll event of its own).
struct ScrollCatcher: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) { nsView.onScroll = onScroll }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        private var accumulated: CGFloat = 0

        override func scrollWheel(with event: NSEvent) {
            accumulated += event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.25 : 1)
            if abs(accumulated) >= 1 {
                onScroll?(accumulated)
                accumulated = 0
            }
        }
    }
}

struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 6
    var tint: Color = Theme.accent

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)).rotationEffect(.degrees(-90))
        }
    }
}

// MARK: Stopwatch

struct StopwatchTabView: View {
    @ObservedObject var clock: ClockService

    var body: some View {
        VStack(spacing: 14) {
            TimelineView(.animation(minimumInterval: 1 / 20, paused: !clock.stopwatch.isRunning)) { ctx in
                Text(ProdFormat.stopwatch(clock.stopwatch.elapsed(at: ctx.date)))
                    .font(.system(size: 46, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            HStack(spacing: 8) {
                Button(clock.stopwatch.isRunning ? "Lap" : "Reset") {
                    clock.stopwatch.isRunning ? clock.lapStopwatch() : clock.resetStopwatch()
                }
                .buttonStyle(.bordered).controlSize(.large)
                .disabled(!clock.stopwatch.isRunning && clock.stopwatch.elapsed() == 0)
                Button {
                    clock.toggleStopwatch()
                } label: { Label(clock.stopwatch.isRunning ? "Stop" : "Start", systemImage: clock.stopwatch.isRunning ? "pause.fill" : "play.fill").frame(minWidth: 80) }
                .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
            }
            if clock.stopwatch.laps.isEmpty {
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(clock.stopwatch.laps.enumerated().reversed()), id: \.offset) { i, total in
                            let lap = total - (i > 0 ? clock.stopwatch.laps[i - 1] : 0)
                            HStack {
                                Text("Lap \(i + 1)").foregroundStyle(.secondary)
                                Spacer()
                                Text(ProdFormat.stopwatch(lap)).monospacedDigit()
                                Text(ProdFormat.stopwatch(total)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                            }
                            .font(.system(size: 12.5, design: .rounded)).padding(.vertical, 5)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 18)
                }
            }
        }
    }
}

// MARK: Pomodoro

struct PomodoroTabView: View {
    @ObservedObject var clock: ClockService

    var body: some View {
        VStack(spacing: 16) {
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let remaining = clock.pomodoroRemaining(at: ctx.date)
                let total = clock.duration(of: clock.pomodoro.phase)
                ZStack {
                    ProgressRing(progress: total > 0 ? 1 - remaining / total : 0, lineWidth: 9,
                                 tint: clock.pomodoro.phase.isBreak ? .green : Theme.accent)
                    VStack(spacing: 2) {
                        Text(ProdFormat.clock(remaining)).font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(clock.pomodoro.phase.title).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 190, height: 190)
            SessionDots(done: clock.pomodoro.sessions % clock.sessionsBeforeLong, total: clock.sessionsBeforeLong)
            HStack(spacing: 8) {
                Button { clock.resetPomodoro() } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.bordered).controlSize(.large)
                Button { clock.togglePomodoro() } label: {
                    Label(clock.pomodoro.isRunning ? "Pause" : (clock.pomodoro.isActive ? "Resume" : "Start"),
                          systemImage: clock.pomodoro.isRunning ? "pause.fill" : "play.fill").frame(minWidth: 90)
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
                Button { clock.skipPomodoro() } label: { Image(systemName: "forward.end.fill") }.buttonStyle(.bordered).controlSize(.large).help("Skip to the next phase")
            }
            Spacer(minLength: 0)
        }
    }
}

struct SessionDots: View {
    var done: Int
    var total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { i in
                Circle().fill(i < done ? Theme.accent : Color.primary.opacity(0.15)).frame(width: 8, height: 8)
            }
        }
    }
}

// MARK: Alarms

struct AlarmsTabView: View {
    @ObservedObject var clock: ClockService
    @State private var time = Calendar.current.date(bySettingHour: 7, minute: 30, second: 0, of: Date()) ?? Date()
    @State private var label = ""
    @State private var daily = true

    /// The alarm's name (or "Alarm") and, for a daily one, that it repeats.
    private static func alarmLine(_ alarm: ClockAlarm) -> String {
        let name = alarm.label.isEmpty ? String(localized: "Alarm") : alarm.label
        return alarm.repeatsDaily ? String(localized: "\(name) · every day") : name
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                DatePicker("", selection: $time, displayedComponents: .hourAndMinute).labelsHidden()
                TextField("Label", text: $label).textFieldStyle(.roundedBorder)
                Toggle("Daily", isOn: $daily).toggleStyle(.checkbox).controlSize(.small)
                Button {
                    let c = Calendar.current.dateComponents([.hour, .minute], from: time)
                    clock.addAlarm(hour: c.hour ?? 7, minute: c.minute ?? 0, label: label, repeatsDaily: daily)
                    label = ""
                } label: { Image(systemName: "plus") }.buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
            }
            .padding(.horizontal, 14)
            if clock.alarms.isEmpty {
                ToolEmptyState(symbol: "alarm", message: String(localized: "No alarms yet."))
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach($clock.alarms) { $alarm in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(alarm.timeText).font(.system(size: 22, weight: .light, design: .rounded)).monospacedDigit()
                                    Text(verbatim: Self.alarmLine(alarm))
                                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .opacity(alarm.enabled ? 1 : 0.5)
                                Spacer()
                                Toggle("", isOn: $alarm.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                                Button { clock.removeAlarm(alarm.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.06)))
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }
        }
    }
}
