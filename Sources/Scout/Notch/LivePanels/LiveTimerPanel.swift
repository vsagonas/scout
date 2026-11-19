import Combine
import SwiftUI

// live.timer: while a timer entry exists (running or paused) or the Pomodoro is active. The soonest timer, else the
// Pomodoro phase, with pause / resume through the Clock service. The dashboard has no fixed Timer widget any more.
// Also: for a minute after launch, a timer or Pomodoro phase that ran out while Scout was closed shows as finished.

struct LiveTimerSnapshot: Equatable {
    var timers: [ClockTimer] = []
    var pomodoro = PomodoroState()
    var pomodoroTotal: TimeInterval = 25 * 60   // the length of the current Pomodoro phase
    var ended: [ClockEnded] = []                // ran out while Scout was closed
}

/// What the panel shows: one timer or the Pomodoro, or a finished one, and how many more are running.
struct LiveTimerShown: Equatable {
    var symbol: String
    var label: String
    var endDate: Date?             // nil = paused
    var pausedRemaining: TimeInterval
    var total: TimeInterval
    var isBreak = false
    var timerID: UUID?             // nil = the Pomodoro
    var more: Int
    var finished: ClockEnded?      // set = a timer that ended while Scout was closed
}

/// What a button does; the real one drives `ClockService`.
struct LiveTimerActions {
    var toggleTimer: (UUID) -> Void
    var togglePomodoro: () -> Void
    var dismissEnded: (String) -> Void
}

@MainActor
final class LiveTimerPanel: LiveDriven {
    let id = "live.timer"
    let title = String(localized: "Timer")
    let symbol = "timer"
    let priority = 60
    let span = 4
    let expandTo: WorkspaceKind? = nil

    let feed: LiveFeed<LiveTimerSnapshot>
    private let clock: () -> Date
    private let actions: LiveTimerActions

    var changes: AnyPublisher<Void, Never> { feed.changes }
    var isLive: Bool { Self.shown(feed.value, now: clock()) != nil }

    init(feed: LiveFeed<LiveTimerSnapshot>, clock: @escaping () -> Date = Date.init, actions: LiveTimerActions) {
        self.feed = feed
        self.clock = clock
        self.actions = actions
    }

    static func live() -> LiveTimerPanel {
        let service = ClockService.shared
        let feed = LiveFeed<LiveTimerSnapshot>(read: {
            LiveTimerSnapshot(timers: service.timers, pomodoro: service.pomodoro, pomodoroTotal: service.duration(of: service.pomodoro.phase),
                              ended: service.ended)
        }, triggers: [service.liveTrigger])
        let actions = LiveTimerActions(toggleTimer: { id in
            guard let timer = service.timers.first(where: { $0.id == id }) else { return }
            if timer.isRunning { service.pauseTimer(id) } else { service.resumeTimer(id) }
        }, togglePomodoro: { service.togglePomodoro() }, dismissEnded: { service.dismissEnded($0) })
        return LiveTimerPanel(feed: feed, actions: actions)
    }

    /// What is running (and how many other things run): the soonest running timer, else the first paused one, else the
    /// Pomodoro. A timer that ended while Scout was closed goes first, for its minute.
    static func shown(_ s: LiveTimerSnapshot, now: Date) -> LiveTimerShown? {
        let pomodoroActive = s.pomodoro.isActive
        let running = s.timers.count + (pomodoroActive ? 1 : 0)
        if let end = s.ended.filter({ $0.shownUntil > now }).min(by: { $0.endedAt < $1.endedAt }) {
            return LiveTimerShown(symbol: end.symbol, label: end.title, endDate: nil, pausedRemaining: 0, total: end.duration,
                                  timerID: nil, more: running, finished: end)
        }
        if let timer = s.timers.filter(\.isRunning).min(by: { ($0.endDate ?? .distantFuture) < ($1.endDate ?? .distantFuture) }) ?? s.timers.first {
            return LiveTimerShown(symbol: "timer", label: timer.label, endDate: timer.endDate,
                                  pausedRemaining: timer.pausedRemaining ?? timer.duration, total: timer.duration, timerID: timer.id,
                                  more: running - 1)
        }
        guard pomodoroActive else { return nil }
        return LiveTimerShown(symbol: "leaf", label: s.pomodoro.phase.title, endDate: s.pomodoro.endDate,
                              pausedRemaining: s.pomodoro.pausedRemaining ?? s.pomodoroTotal, total: s.pomodoroTotal,
                              isBreak: s.pomodoro.phase.isBreak, timerID: nil, more: 0)
    }

    func nextWake(after now: Date) -> Date? {
        feed.value.ended.map(\.shownUntil).filter { $0 > now }.min()
    }

    func makeView() -> AnyView { AnyView(LiveTimerView(feed: feed, clock: clock, actions: actions)) }
}

// MARK: - View

struct LiveTimerView: View {
    @ObservedObject var feed: LiveFeed<LiveTimerSnapshot>
    var clock: () -> Date = Date.init
    var actions: LiveTimerActions

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            if let shown = LiveTimerPanel.shown(feed.value, now: clock()) {
                if Retro.is8bit {
                    if let ended = shown.finished { finished(ended, more: shown.more) } else { panel(shown) }
                } else {
                    if let ended = shown.finished { minimalFinished(ended, more: shown.more) } else { minimalPanel(shown) }
                }
            } else {
                Color.clear
            }
        }
    }

    /// The minimal look: the time left in big system digits, a plain pause/resume button, the label and a slim bar.
    private func minimalPanel(_ t: LiveTimerShown) -> some View {
        let running = t.endDate != nil
        let remaining = t.endDate.map { max(0, $0.timeIntervalSince(clock())) } ?? t.pausedRemaining
        return LiveRetroFrame(symbol: t.symbol, title: t.timerID == nil ? "Pomodoro" : "Timer", short: t.timerID == nil ? "Pomo" : nil, tint: Retro.Ink.orange, trailing: {
            if !running { LiveRetroFact(text: String(localized: "Paused")) } else if t.more > 0 { LiveRetroFact(text: String(localized: "+\(t.more) more")) }
        }) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    MiniDigits(text: ProdFormat.clock(remaining), size: 34, color: running ? NotchInk.primary : NotchInk.secondary)
                    Spacer(minLength: 4)
                    Button { if let id = t.timerID { actions.toggleTimer(id) } else { actions.togglePomodoro() } } label: {
                        Image(systemName: running ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(MiniIconButtonStyle(size: 32, lit: !running, radius: 16)).liveControl()
                    .help(running ? "Pause" : "Resume")
                }
                if !t.label.isEmpty { Text(t.label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(NotchInk.secondary).lineLimit(1) }
                MiniBar(fraction: t.total > 0 ? 1 - remaining / t.total : 0, tint: Theme.accent)
            }
            Spacer(minLength: 0)
        }
    }

    /// The minimal look of a timer that ended while Scout was closed: what it was, when, and a plain check to dismiss it.
    private func minimalFinished(_ e: ClockEnded, more: Int) -> some View {
        LiveRetroFrame(symbol: "checkmark.circle.fill", title: "Finished", tint: Retro.Ink.lime, trailing: {
            if more > 0 { LiveRetroFact(text: String(localized: "+\(more) running")) }
        }) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Text(e.title).font(.system(size: 18, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    Button { actions.dismissEnded(e.id) } label: { Image(systemName: "checkmark") }
                        .buttonStyle(MiniIconButtonStyle(size: 28, radius: 14)).liveControl().help("Dismiss")
                }
                Text("Ended at \(FeatureFormat.time(e.endedAt)) while Scout was closed")
                    .font(.system(size: 10.5)).foregroundStyle(NotchInk.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    private func panel(_ t: LiveTimerShown) -> some View {
        let running = t.endDate != nil
        let tint: Color = t.isBreak ? Retro.Ink.lime : (t.timerID == nil ? Retro.Ink.red : Retro.Ink.orange)
        let remaining = t.endDate.map { max(0, $0.timeIntervalSince(clock())) } ?? t.pausedRemaining
        return LiveRetroFrame(symbol: t.symbol, title: t.timerID == nil ? "Pomodoro" : "Timer", short: t.timerID == nil ? "Pomo" : nil, tint: tint, trailing: {
            if !running { LiveRetroFact(text: String(localized: "Paused")) } else if t.more > 0 { LiveRetroFact(text: String(localized: "+\(t.more) more")) }
        }) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Dash90LCD(padding: 5) {
                        Dash90Digits(text: ProdFormat.clock(remaining), big: 28, color: running ? Dash90.amber : Dash90.amber.opacity(0.55))
                            .frame(maxWidth: .infinity)
                    }
                    Button { if let id = t.timerID { actions.toggleTimer(id) } else { actions.togglePomodoro() } } label: {
                        Image(systemName: running ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.dash90Key(tint: running ? Retro.Ink.plasticMid : Retro.shade(tint, -0.1), width: 32, height: 38, lit: !running)).liveControl()
                    .help(running ? "Pause" : "Resume")
                }
                if !t.label.isEmpty { Text(t.label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1) }
                LiveRetroBar(fraction: t.total > 0 ? 1 - remaining / t.total : 0, tint: tint, segments: 22, height: 11)
            }
            Spacer(minLength: 0)
        }
    }

    /// "Finished", what it was, when it ended, and a button to dismiss it.
    private func finished(_ e: ClockEnded, more: Int) -> some View {
        LiveRetroFrame(symbol: "checkmark.circle.fill", title: "Finished", tint: Retro.Ink.lime, trailing: {
            if more > 0 { LiveRetroFact(text: String(localized: "+\(more) running")) }
        }) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Text(e.title).font(.system(size: 18, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    Button { actions.dismissEnded(e.id) } label: { Image(systemName: "checkmark") }
                        .buttonStyle(.dash90Key(tint: Retro.Ink.lime, width: 32, height: 28)).liveControl().help("Dismiss")
                }
                Text("Ended at \(FeatureFormat.time(e.endedAt)) while Scout was closed")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                LiveRetroBar(fraction: 1, tint: Retro.Ink.ledGreen, segments: 22, height: 11)
            }
            Spacer(minLength: 0)
        }
    }
}
