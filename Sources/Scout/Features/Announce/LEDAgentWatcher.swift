import Combine
import SwiftUI

/// Watches the agents (from `AgentsStore`, which it only reads) and posts the first announcements:
///   - a NEW agent is detected: "WELCOME <PROJECT> ♥" in that agent kind's tint;
///   - an agent goes away while at work: "BYE <PROJECT>", after `byeHold`; never when it was a restart (the same project back as a new
///     session), and never for one whose turn was over (Scout puts a finished agent away after five minutes; its window may be open);
///   - an agent finishes while the notch is in use (the automatic opening lights its row instead of opening): "<PROJECT> DONE ✓".
/// Agents found by the first scan after launch are the baseline and never announced; neither is anything in the first 10 s after
/// that scan. A session that left and comes back is the same agent: it is not welcomed twice (a finished one is taken as closed after
/// a few minutes, and a helper's notification or a new prompt wakes it again).
/// A newcomer is welcomed after `welcomeHold` seconds, not at once, and only if it is still there and did not just come and go with a
/// quick answer. One that shows up already finished is never welcomed.
/// Nothing runs in scripted runs, and nothing here ticks: it only reacts to the store's own changes.
@MainActor
final class LEDAgentWatcher {
    static let shared = LEDAgentWatcher()

    /// After the store's first load, how long what appears still counts as "was already there".
    static let warmUp: TimeInterval = 10
    /// How long a newcomer waits before its welcome: a session that is over within a few seconds never gets one.
    static let welcomeHold: TimeInterval = 5
    /// How long an agent's absence counts as a break of the same agent (no second welcome): a closed session wakes up again when a helper
    /// reports back or the owner writes to it.
    static let comeBack: TimeInterval = 6 * 3600
    /// How long a goodbye waits: a restarted agent (the same project back as a new session) gets only its WELCOME, never BYE then WELCOME
    static let byeHold: TimeInterval = 30
    /// If the first load never shows (no transcript scan), the baseline ends this long after starting.
    static let fallback: TimeInterval = 15
    static let nameLimit = 14

    struct Env {
        var now: () -> Date = { Date() }
        var isScripted = ScoutRuntime.isScripted
        /// True once the store has done its first load (the scanner's first pass, or no scan at all).
        var loaded: @MainActor (AgentsStore) -> Bool = { store in
            store.scanStatus.lastSweep != nil || !Pref.bool(AgentsStore.Key.scan, true)
        }
        /// Runs `work` after `seconds`; returns a closure that cancels it (a test's clock replaces it).
        var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void = { seconds, work in
            let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
            return { item.cancel() }
        }
    }

    private struct Known {
        var project: String
        var kind: AgentKind
        /// Its turn was over when last seen: if it then leaves the list, it is resting (Scout puts a finished agent away after five
        /// minutes, its window may still be open), not gone, and gets no goodbye.
        var resting = false
    }

    let announcements: LEDAnnouncements
    var env: Env
    private(set) var isRunning = false
    private var startedAt: Date?
    private var loadedAt: Date?
    private var present: [String: Known] = [:]
    /// Newcomers waiting for their welcome (when they came), and the ones that will never get one (finished on arrival, or gone too soon).
    private var waiting: [String: Date] = [:]
    private var silent: Set<String> = []
    private var lastSessions: [AgentSession] = []
    private var lastLoaded = false
    private var cancelFlush: (() -> Void)?
    private var leftAt: [String: Date] = [:]
    /// Goodbyes waiting out `byeHold`, by session id.
    private var leaving: [String: (known: Known, at: Date)] = [:]
    private var flashedBefore: Set<String> = []
    private var cancellables = Set<AnyCancellable>()

    init(announcements: LEDAnnouncements? = nil, env: Env = Env()) {
        self.announcements = announcements ?? LEDAnnouncements.shared
        self.env = env
    }

    // MARK: Names

    /// "scout_app" → "SCOUT-APP", cut to 14 characters.
    static func label(_ project: String) -> String {
        let up = project.uppercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
        return String(up.prefix(nameLimit)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: Starting

    /// Starts watching the store (not in scripted runs: a gallery or a self-test never gets a message by itself).
    func start(store: AgentsStore? = nil) {
        guard !isRunning, !env.isScripted else { return }
        let store = store ?? AgentsStore.shared
        isRunning = true
        startedAt = env.now()
        flashedBefore = store.flashed
        store.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak store] sessions in
                guard let self, let store else { return }
                MainActor.assumeIsolated { self.process(sessions: sessions, loaded: self.env.loaded(store)) }
            }
            .store(in: &cancellables)
        store.$scanStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak store] _ in
                guard let self, let store else { return }
                MainActor.assumeIsolated { self.process(sessions: store.sessions, loaded: self.env.loaded(store)) }
            }
            .store(in: &cancellables)
        store.$flashed
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak store] flashed in
                guard let self, let store else { return }
                MainActor.assumeIsolated {
                    self.processFlashes(flashed, sessions: store.sessions, loaded: self.env.loaded(store))
                }
            }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        cancelFlush?(); cancelFlush = nil
        isRunning = false
    }

    // MARK: Noticing

    /// True once the baseline period is over: the first load happened and `warmUp` seconds have passed (or the fallback ran out).
    func isReady(loaded: Bool, now: Date) -> Bool {
        if loadedAt == nil, loaded { loadedAt = now }
        if let loadedAt { return now.timeIntervalSince(loadedAt) >= Self.warmUp }
        if let startedAt { return now.timeIntervalSince(startedAt) >= Self.fallback }
        return false
    }

    /// Compares the sessions with the last look and announces what is new or gone.
    func process(sessions: [AgentSession], loaded: Bool, now: Date? = nil) {
        let now = now ?? env.now()
        if startedAt == nil { startedAt = now }
        lastSessions = sessions
        lastLoaded = loaded
        let ready = isReady(loaded: loaded, now: now)
        var seen: [String: Known] = [:]
        for s in sessions { seen[s.id] = Known(project: Self.label(s.project), kind: s.agent, resting: s.finishedAt != nil && s.state != .working) }
        // A goodbye is off when its agent is back, or when its project is back as a new session (a restart).
        leaving = leaving.filter { id, l in seen[id] == nil && !seen.values.contains { $0.project == l.known.project && $0.kind == l.known.kind } }
        // Newcomers.
        for s in sessions where present[s.id] == nil {
            guard ready else { continue }   // part of the baseline: it was there all along
            if let left = leftAt[s.id], now.timeIntervalSince(left) < Self.comeBack { continue }   // the same agent coming back, not a new one
            if s.finishedAt != nil, s.state != .working { silent.insert(s.id); continue }   // over already: nothing to welcome
            waiting[s.id] = now
        }
        // Welcomes that waited long enough (a session that is gone, or finished a quick turn meanwhile, gets none).
        for (id, since) in waiting.sorted(by: { $0.value < $1.value }) {
            guard let s = sessions.first(where: { $0.id == id }) else { waiting[id] = nil; silent.insert(id); continue }
            guard now.timeIntervalSince(since) >= Self.welcomeHold else { continue }
            waiting[id] = nil
            if s.finishedAt != nil, s.state != .working, s.wasQuickTurn { silent.insert(id); continue }
            let name = Self.label(s.project)
            announcements.post(LEDAnnouncements.boardText(String(localized: "WELCOME \(name) ♥"), english: "WELCOME \(name) ♥"), tint: s.agent.tint, symbol: s.agent.symbol)
        }
        // Leavers: no goodbye while another session of the same project is here; otherwise it waits `byeHold` for a restart. One whose turn
        // was over when last seen is only resting (put away after five minutes): no goodbye either. The board said "BYE SCOUT" every time
        // the agent of a chat that was still open waited a while for its person
        for (id, known) in present where seen[id] == nil {
            leftAt[id] = now
            if ready, !silent.contains(id), !known.resting, !seen.values.contains(where: { $0.project == known.project && $0.kind == known.kind }) {
                leaving[id] = (known, now)
            }
            silent.remove(id)
        }
        for (id, l) in leaving.sorted(by: { $0.value.at < $1.value.at }) where now.timeIntervalSince(l.at) >= Self.byeHold {
            leaving[id] = nil
            let name = l.known.project
            announcements.post(LEDAnnouncements.boardText(String(localized: "BYE \(name)"), english: "BYE \(name)"), tint: l.known.kind.tint, symbol: l.known.kind.symbol)
        }
        cancelFlush?()
        cancelFlush = nil
        let dues = waiting.values.map { Self.welcomeHold - now.timeIntervalSince($0) } + leaving.values.map { Self.byeHold - now.timeIntervalSince($0.at) }
        if let next = dues.min() {
            cancelFlush = env.schedule(max(0.05, next + 0.05)) { [weak self] in self?.flush() }
        }
        leftAt = leftAt.filter { now.timeIntervalSince($0.value) < Self.comeBack * 2 }
        present = seen
    }

    /// The hold of a waiting newcomer ran out: look again at the last sessions.
    private func flush() {
        cancelFlush = nil
        process(sessions: lastSessions, loaded: lastLoaded)
    }

    /// The automatic opening lit a row because the notch was in use. A finished agent is announced on the board; one that needs
    /// you is not (the lit row says it, and the board says only the good news).
    func processFlashes(_ flashed: Set<String>, sessions: [AgentSession], loaded: Bool, now: Date? = nil) {
        let fresh = flashed.subtracting(flashedBefore)
        flashedBefore = flashed
        let now = now ?? env.now()
        guard isReady(loaded: loaded, now: now) else { return }
        for id in fresh.sorted() {
            guard let s = sessions.first(where: { $0.id == id }) else { continue }
            if s.state == .working || AgentWingSummary.asks(s) { continue }
            let name = Self.label(s.project)
            announcements.post(LEDAnnouncements.boardText(String(localized: "\(name) DONE ✓"), english: "\(name) DONE ✓"), tint: s.agent.tint, symbol: s.agent.symbol)
        }
    }

    /// Forgets everything (a self-test starts from nothing).
    func reset() {
        present = [:]; leftAt = [:]; flashedBefore = []; loadedAt = nil; startedAt = nil
        waiting = [:]; silent = []; lastSessions = []; leaving = [:]; cancelFlush?(); cancelFlush = nil
    }
}
