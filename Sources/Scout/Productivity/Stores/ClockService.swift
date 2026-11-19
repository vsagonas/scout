import AppKit
import SwiftUI
import UserNotifications

// B3 — one clock for the whole app: several timers, a stopwatch with laps, a Pomodoro cycle and alarms.
// The ring's Clock tool, the Timer / Pomodoro widgets and the live activities all read this service.

struct ClockTimer: Identifiable, Codable, Equatable {
    var id = UUID()
    var label: String
    var duration: TimeInterval
    /// Set while running.
    var endDate: Date?
    /// Set while paused.
    var pausedRemaining: TimeInterval?
    /// A to-do this timer is a focus session for (its minutes are added to the task when it ends).
    var taskID: UUID?

    var isRunning: Bool { endDate != nil }
    var isPaused: Bool { endDate == nil }

    func remaining(at now: Date = Date()) -> TimeInterval {
        if let endDate { return max(0, endDate.timeIntervalSince(now)) }
        return pausedRemaining ?? duration
    }
}

struct Stopwatch: Equatable, Codable {
    var startDate: Date?
    var accumulated: TimeInterval = 0
    var laps: [TimeInterval] = []

    var isRunning: Bool { startDate != nil }

    func elapsed(at now: Date = Date()) -> TimeInterval {
        accumulated + (startDate.map { now.timeIntervalSince($0) } ?? 0)
    }
}

enum PomodoroPhase: String, Codable {
    case work, shortBreak, longBreak

    var title: String {
        switch self {
        case .work: String(localized: "Focus")
        case .shortBreak: String(localized: "Short break")
        case .longBreak: String(localized: "Long break")
        }
    }

    var isBreak: Bool { self != .work }
}

struct PomodoroState: Equatable, Codable {
    var phase: PomodoroPhase = .work
    var endDate: Date?
    var pausedRemaining: TimeInterval?
    /// Focus sessions finished in this cycle.
    var sessions = 0

    var isRunning: Bool { endDate != nil }
    var isActive: Bool { endDate != nil || pausedRemaining != nil }
}

struct ClockAlarm: Identifiable, Codable, Equatable {
    var id = UUID()
    var hour: Int
    var minute: Int
    var label = ""
    var enabled = true
    var repeatsDaily = false
    var lastFired: Date?

    var timeText: String {
        var parts = DateComponents()
        parts.hour = hour
        parts.minute = minute
        let date = Calendar.current.date(from: parts) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

enum ClockTab: String, CaseIterable, Identifiable {
    case timer, stopwatch, pomodoro, alarms
    var id: String { rawValue }
    var title: String {
        switch self {
        case .timer: String(localized: "Timer")
        case .stopwatch: String(localized: "Stopwatch")
        case .pomodoro: String(localized: "Pomodoro")
        case .alarms: String(localized: "Alarms")
        }
    }
    var symbol: String {
        switch self {
        case .timer: "timer"
        case .stopwatch: "stopwatch"
        case .pomodoro: "leaf"
        case .alarms: "alarm"
        }
    }
}

/// Something that is ringing right now (a finished timer, an alarm, a Pomodoro phase).
struct ClockRinging: Identifiable, Equatable {
    enum Source: Equatable { case timer(UUID), alarm(UUID), pomodoro }
    var id: String
    var title: String
    var subtitle: String
    var symbol: String
    var source: Source
}

/// What survives a quit, an update or a restart: running and paused timers, the stopwatch and the Pomodoro (end dates,
/// paused remaining time, labels, phase, finished sessions).
struct ClockSaved: Codable {
    var timers: [ClockTimer]
    var stopwatch: Stopwatch
    var pomodoro: PomodoroState
    var savedAt: Date
}

/// A timer or Pomodoro phase that ran out while Scout was closed. Marked finished at launch (no sound); the live timer panel
/// shows it for a minute (`shownUntil`).
struct ClockEnded: Identifiable, Equatable {
    var id: String
    var title: String
    var symbol: String
    var duration: TimeInterval
    var endedAt: Date
    var shownUntil: Date
}

@MainActor
final class ClockService: ObservableObject {
    static let shared = ClockService()

    // Every change to these three is saved (see `saveState`) and restored at the next launch.
    @Published private(set) var timers: [ClockTimer] = [] { didSet { saveState() } }
    @Published private(set) var stopwatch = Stopwatch() { didSet { saveState() } }
    @Published private(set) var pomodoro = PomodoroState() { didSet { saveState() } }
    /// Timers and Pomodoro phases that ended while Scout was closed, for the minute after launch.
    @Published private(set) var ended: [ClockEnded] = []
    @Published var alarms: [ClockAlarm] = [] { didSet { saveAlarms() } }
    @Published private(set) var ringing: [ClockRinging] = []
    /// The Clock panel switches to this tab when set (the ring's push-past options set it).
    @Published var requestedTab: ClockTab?

    private let alarmFile = JSONFile<[ClockAlarm]>("alarms.json")
    private var ticker: Timer?
    private var soundTimer: Timer?
    private var ringingSince: Date?
    private let isDemo: Bool
    private let stateFile: JSONFile<ClockSaved>?
    private var restoring = false
    private var savePending = false

    // Settings (Timers & Pomodoro page)
    var workMinutes: Int { max(1, UserDefaults.standard.int("clock.pomo.work", default: 25)) }
    var shortMinutes: Int { max(1, UserDefaults.standard.int("clock.pomo.short", default: 5)) }
    var longMinutes: Int { max(1, UserDefaults.standard.int("clock.pomo.long", default: 15)) }
    var sessionsBeforeLong: Int { max(2, UserDefaults.standard.int("clock.pomo.every", default: 4)) }
    var autoStartNext: Bool { UserDefaults.standard.bool("clock.pomo.autoStart", default: false) }
    var soundName: String { UserDefaults.standard.string("clock.sound", default: "Glass") }
    var soundsOn: Bool { UserDefaults.standard.bool("clock.soundOn", default: true) }

    convenience init() {
        self.init(demo: ScoutRuntime.isGallery, stateFile: ScoutRuntime.isScripted ? nil : JSONFile<ClockSaved>("clock-state.json"))
    }

    /// `demo` instances (the gallery) never post activities, play sounds or save alarms. Only an instance given a `stateFile`
    /// saves and restores its timers, stopwatch and Pomodoro (the shared one, outside scripted runs; self-tests with their own
    /// file). `restoreAt` is "now" for judging what ended while Scout was closed.
    init(demo: Bool, stateFile: JSONFile<ClockSaved>? = nil, restoreAt: Date = Date()) {
        isDemo = demo
        self.stateFile = stateFile
        if demo {
            alarms = [ClockAlarm(hour: 7, minute: 30, label: "Wake up", repeatsDaily: true),
                      ClockAlarm(hour: 13, minute: 0, label: "Lunch with Marta", enabled: false)]
        } else if !ScoutRuntime.isScripted {
            alarms = alarmFile.load() ?? []
        }
        if let saved = stateFile?.load() { restore(saved, now: restoreAt) }
    }

    func start() {
        guard ticker == nil, !isDemo else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        refreshActivities()   // timers restored at launch show in the wings again
    }

    // MARK: Save and restore

    /// Writes the state once per run-loop turn however many fields changed together.
    private func saveState() {
        guard stateFile != nil, !restoring, !savePending else { return }
        savePending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.savePending = false
                self.stateFile?.save(ClockSaved(timers: self.timers, stopwatch: self.stopwatch, pomodoro: self.pomodoro, savedAt: Date()))
            }
        }
    }

    /// Puts the saved state back. What is still running continues (end dates are absolute); what ran out while Scout was
    /// closed is marked finished, quietly, and listed in `ended` for a minute. The stopwatch keeps counting.
    private func restore(_ saved: ClockSaved, now: Date) {
        restoring = true
        defer { restoring = false; saveState() }
        let shownUntil = now.addingTimeInterval(60)
        var keep: [ClockTimer] = []
        for t in saved.timers {
            if let end = t.endDate, end <= now {
                ended.append(ClockEnded(id: "timer-\(t.id)", title: t.label.isEmpty ? "Timer" : t.label, symbol: "timer",
                                        duration: t.duration, endedAt: end, shownUntil: shownUntil))
                if let task = t.taskID, !isDemo { TodoStore.shared.addFocus(task, minutes: max(1, Int((t.duration / 60).rounded()))) }
            } else {
                keep.append(t)
            }
        }
        timers = keep
        stopwatch = saved.stopwatch
        pomodoro = saved.pomodoro
        if let end = pomodoro.endDate, end <= now {
            let phase = pomodoro.phase
            advancePomodoro(finished: true, autoStart: false)
            ended.append(ClockEnded(id: "pomodoro-\(Int(end.timeIntervalSince1970))", title: phase == .work ? String(localized: "Focus session") : String(localized: "Break"),
                                    symbol: "leaf", duration: duration(of: phase), endedAt: end, shownUntil: shownUntil))
        }
    }

    /// The user closed the "finished" line of a timer that ended while Scout was closed.
    func dismissEnded(_ id: String) { ended.removeAll { $0.id == id } }

    // MARK: Timers

    @discardableResult
    func addTimer(seconds: TimeInterval, label: String = "", start: Bool = true, taskID: UUID? = nil) -> ClockTimer {
        var timer = ClockTimer(label: label, duration: max(1, seconds), taskID: taskID)
        timer.pausedRemaining = timer.duration
        timers.append(timer)
        if start { resumeTimer(timer.id) }
        askForNotificationsOnce()
        refreshActivities()
        return timer
    }

    func resumeTimer(_ id: UUID) {
        guard let i = timers.firstIndex(where: { $0.id == id }), timers[i].isPaused else { return }
        timers[i].endDate = Date().addingTimeInterval(timers[i].pausedRemaining ?? timers[i].duration)
        timers[i].pausedRemaining = nil
        refreshActivities()
    }

    func pauseTimer(_ id: UUID) {
        guard let i = timers.firstIndex(where: { $0.id == id }), timers[i].isRunning else { return }
        timers[i].pausedRemaining = timers[i].remaining()
        timers[i].endDate = nil
        refreshActivities()
    }

    func resetTimer(_ id: UUID) {
        guard let i = timers.firstIndex(where: { $0.id == id }) else { return }
        timers[i].endDate = nil
        timers[i].pausedRemaining = timers[i].duration
        refreshActivities()
    }

    func cancelTimer(_ id: UUID) {
        if let t = timers.first(where: { $0.id == id }), let task = t.taskID, !isDemo {
            // A focus session cut short still counts the full minutes spent.
            let minutes = Int((t.duration - t.remaining()) / 60)
            if minutes >= 1 { TodoStore.shared.addFocus(task, minutes: minutes) }
        }
        timers.removeAll { $0.id == id }
        refreshActivities()
    }

    // MARK: Stopwatch

    func toggleStopwatch() {
        if let start = stopwatch.startDate {
            stopwatch.accumulated += Date().timeIntervalSince(start)
            stopwatch.startDate = nil
        } else {
            stopwatch.startDate = Date()
        }
    }

    func lapStopwatch() {
        guard stopwatch.isRunning else { return }
        stopwatch.laps.append(stopwatch.elapsed())
    }

    func resetStopwatch() { stopwatch = Stopwatch() }

    // MARK: Pomodoro

    func duration(of phase: PomodoroPhase) -> TimeInterval {
        switch phase {
        case .work: TimeInterval(workMinutes * 60)
        case .shortBreak: TimeInterval(shortMinutes * 60)
        case .longBreak: TimeInterval(longMinutes * 60)
        }
    }

    func pomodoroRemaining(at now: Date = Date()) -> TimeInterval {
        if let end = pomodoro.endDate { return max(0, end.timeIntervalSince(now)) }
        return pomodoro.pausedRemaining ?? duration(of: pomodoro.phase)
    }

    func startPomodoro() {
        if pomodoro.isRunning { return }
        let remaining = pomodoro.pausedRemaining ?? duration(of: pomodoro.phase)
        pomodoro.endDate = Date().addingTimeInterval(remaining)
        pomodoro.pausedRemaining = nil
        askForNotificationsOnce()
        refreshActivities()
    }

    func pausePomodoro() {
        guard pomodoro.isRunning else { return }
        pomodoro.pausedRemaining = pomodoroRemaining()
        pomodoro.endDate = nil
        refreshActivities()
    }

    func togglePomodoro() { pomodoro.isRunning ? pausePomodoro() : startPomodoro() }

    /// Jumps to the next phase without counting a finished session.
    func skipPomodoro() {
        advancePomodoro(finished: false)
    }

    func resetPomodoro() {
        pomodoro = PomodoroState()
        refreshActivities()
    }

    private func advancePomodoro(finished: Bool, autoStart: Bool = true) {
        let wasWork = pomodoro.phase == .work
        if wasWork, finished { pomodoro.sessions += 1 }
        let next: PomodoroPhase
        if wasWork {
            next = pomodoro.sessions > 0 && pomodoro.sessions % sessionsBeforeLong == 0 && finished ? .longBreak : .shortBreak
        } else {
            next = .work
        }
        if pomodoro.phase == .longBreak { pomodoro.sessions = 0 }
        pomodoro.phase = next
        pomodoro.endDate = nil
        pomodoro.pausedRemaining = nil
        if autoStartNext, autoStart { startPomodoro() }
        refreshActivities()
    }

    // MARK: Alarms

    func addAlarm(hour: Int, minute: Int, label: String = "", repeatsDaily: Bool = false) {
        alarms.append(ClockAlarm(hour: hour, minute: minute, label: label, repeatsDaily: repeatsDaily))
        alarms.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        askForNotificationsOnce()
    }

    func removeAlarm(_ id: UUID) { alarms.removeAll { $0.id == id } }

    private func saveAlarms() {
        guard !isDemo, !ScoutRuntime.isScripted else { return }
        alarmFile.save(alarms)
    }

    // MARK: Ticking

    private func tick() {
        let now = Date()
        if ended.contains(where: { $0.shownUntil <= now }) { ended.removeAll { $0.shownUntil <= now } }
        var finishedTimers: [ClockTimer] = []
        for t in timers where (t.endDate ?? .distantFuture) <= now { finishedTimers.append(t) }
        for t in finishedTimers { finish(timer: t) }

        if let end = pomodoro.endDate, end <= now { finishPomodoroPhase() }

        let cal = Calendar.current
        let parts = cal.dateComponents([.hour, .minute], from: now)
        for i in alarms.indices where alarms[i].enabled {
            guard alarms[i].hour == parts.hour, alarms[i].minute == parts.minute else { continue }
            if let last = alarms[i].lastFired, now.timeIntervalSince(last) < 90 { continue }
            alarms[i].lastFired = now
            if !alarms[i].repeatsDaily { alarms[i].enabled = false }
            ring(ClockRinging(id: "alarm-\(alarms[i].id)", title: alarms[i].label.isEmpty ? String(localized: "Alarm") : alarms[i].label,
                              subtitle: alarms[i].timeText, symbol: "alarm.fill", source: .alarm(alarms[i].id)))
        }
    }

    private func finish(timer: ClockTimer) {
        timers.removeAll { $0.id == timer.id }
        if let task = timer.taskID { TodoStore.shared.addFocus(task, minutes: max(1, Int((timer.duration / 60).rounded()))) }
        refreshActivities()
        ring(ClockRinging(id: "timer-\(timer.id)", title: timer.label.isEmpty ? String(localized: "Timer done") : timer.label,
                          subtitle: String(localized: "\(ProdFormat.clock(timer.duration)) timer finished"), symbol: "timer", source: .timer(timer.id)))
    }

    private func finishPomodoroPhase() {
        let finishedPhase = pomodoro.phase
        let sessions = pomodoro.sessions + (finishedPhase == .work ? 1 : 0)
        advancePomodoro(finished: true)
        let title = finishedPhase == .work ? String(localized: "Focus session done") : String(localized: "Break over")
        let subtitle: String
        if finishedPhase != .work { subtitle = String(localized: "Ready for the next focus session") }
        else if pomodoro.phase == .longBreak { subtitle = String(localized: "Sessions so far: \(sessions). Time for a long break.") }
        else { subtitle = String(localized: "Sessions so far: \(sessions). Time for a short break.") }
        ring(ClockRinging(id: "pomodoro-\(Date().timeIntervalSince1970)", title: title, subtitle: subtitle, symbol: "leaf.fill", source: .pomodoro))
    }

    // MARK: Ringing

    private func ring(_ event: ClockRinging) {
        ringing.removeAll { $0.id == event.id }
        ringing.append(event)
        ringingSince = Date()
        notify(event)
        if !isDemo {
            LiveActivityCenter.shared.present(NotchCard(id: "clock.ring.\(event.id)", kind: .timer, duration: 90) {
                ClockRingingBanner(event: event)
            })
        }
        startSound()
    }

    func stopRinging(_ id: String) {
        ringing.removeAll { $0.id == id }
        LiveActivityCenter.shared.dismissCard(id: "clock.ring.\(id)")
        if ringing.isEmpty { stopSound() }
    }

    func stopAllRinging() { ringing.map(\.id).forEach(stopRinging) }

    /// Timers and alarms snooze for five minutes (as a new timer); a Pomodoro phase just stops.
    /// The running or paused focus timer of a to-do, if any.
    func focusTimer(for task: UUID) -> ClockTimer? { timers.first { $0.taskID == task } }

    func snooze(_ id: String, minutes: Int = 5) {
        guard let event = ringing.first(where: { $0.id == id }) else { return }
        stopRinging(id)
        if event.source != .pomodoro {
            addTimer(seconds: TimeInterval(minutes * 60), label: String(localized: "Snoozed — \(event.title)"))
        }
    }

    private func startSound() {
        guard soundsOn, !isDemo, soundTimer == nil else { return }
        ProdSound.play(soundName)
        let t = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let since = self.ringingSince, Date().timeIntervalSince(since) > 60 { self.stopAllRinging(); return }
                ProdSound.play(self.soundName)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        soundTimer = t
    }

    private func stopSound() {
        soundTimer?.invalidate()
        soundTimer = nil
        NSSound(named: NSSound.Name(soundName))?.stop()
    }

    // MARK: Notifications

    private var canUseNotifications: Bool { !ScoutRuntime.isScripted && !isDemo && Bundle.main.bundleURL.pathExtension == "app" }

    private func askForNotificationsOnce() {
        guard canUseNotifications, !UserDefaults.standard.bool(forKey: "clock.askedNotifications") else { return }
        UserDefaults.standard.set(true, forKey: "clock.askedNotifications")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ event: ClockRinging) {
        guard canUseNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.subtitle
        let request = UNNotificationRequest(identifier: event.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Live activities

    private func refreshActivities() {
        guard !isDemo else { return }
        let center = LiveActivityCenter.shared
        let now = Date()
        // Timer: the soonest running (or the first paused) timer.
        let running = timers.filter(\.isRunning).min { ($0.endDate ?? .distantFuture) < ($1.endDate ?? .distantFuture) }
        if let timer = running ?? timers.first {
            let end = timer.endDate
            let activity = LiveActivity(id: "clock.timer", kind: .timer, onTap: { NotchNavigator.shared.open(.nook) }) {
                Image(systemName: "timer").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
            } trailing: {
                Group {
                    if let end, end > now {
                        Text(timerInterval: now...end, pauseTime: nil, countsDown: true, showsHours: false)
                    } else {
                        Text(ProdFormat.clock(timer.remaining())).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
                .frame(maxWidth: 52, alignment: .trailing)
            }
            center.show(activity)
        } else {
            center.dismiss(id: "clock.timer")
        }
        // Pomodoro
        if pomodoro.isActive {
            let end = pomodoro.endDate
            let remaining = pomodoroRemaining()
            let phase = pomodoro.phase
            let activity = LiveActivity(id: "clock.pomodoro", kind: .pomodoro, onTap: { NotchNavigator.shared.open(.nook) }) {
                Image(systemName: "leaf.fill").font(.system(size: 12)).foregroundStyle(phase.isBreak ? Color.green : Theme.accent)
            } trailing: {
                Group {
                    if let end, end > now {
                        Text(timerInterval: now...end, pauseTime: nil, countsDown: true, showsHours: false)
                    } else {
                        Text(ProdFormat.clock(remaining)).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
                .frame(maxWidth: 52, alignment: .trailing)
            }
            center.show(activity)
        } else {
            center.dismiss(id: "clock.pomodoro")
        }
    }

    // MARK: Demo states for the gallery

    static func demo(running: Bool) -> ClockService {
        let s = ClockService(demo: true)
        let now = Date()
        if running {
            s.timers = [ClockTimer(label: "Tea", duration: 300, endDate: now.addingTimeInterval(187)),
                        ClockTimer(label: "Laundry", duration: 2400, endDate: nil, pausedRemaining: 1500)]
            s.stopwatch = Stopwatch(startDate: now.addingTimeInterval(-74.3), accumulated: 12.5, laps: [21.4, 48.9, 70.2])
            s.pomodoro = PomodoroState(phase: .work, endDate: now.addingTimeInterval(14 * 60 + 12), pausedRemaining: nil, sessions: 2)
        }
        return s
    }
}

/// The card that drops under the notch when something rings.
struct ClockRingingBanner: View {
    let event: ClockRinging

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: event.symbol).font(.system(size: 18)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(event.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if event.source != .pomodoro {
                Button("Snooze") { ClockService.shared.snooze(event.id) }.buttonStyle(.bordered).controlSize(.small)
            }
            Button("Stop") { ClockService.shared.stopRinging(event.id) }.buttonStyle(.borderedProminent).controlSize(.small).tint(Theme.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 300)
    }
}
