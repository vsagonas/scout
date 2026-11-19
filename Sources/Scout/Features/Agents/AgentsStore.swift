import AppKit
import SwiftUI

/// The state of every Claude Code / Codex session Scout finds by reading the agents' own progress files (read only).
@MainActor
final class AgentsStore: ObservableObject {
    static let shared = AgentsStore(isShared: true)

    enum Key {
        static let preferWorkspace = "agents.preferWorkspace"  // RETIRED: the old "open the notch on Agents" switch; `AgentsAutoOpen` migrates it once and replaces it
        static let scan = "agents.scan"                        // find sessions by reading the agents' transcript files (default on)
    }

    @Published private(set) var sessions: [AgentSession] = [] {
        didSet {   // an agent that is gone gives up its place in the row
            if isShared { AgentFoundOrder.forget(Set(oldValue.map(\.id)).subtracting(sessions.map(\.id))) }
        }
    }
    @Published var selectedID: String?
    /// A widget asks the workspace to open this session's detail (the workspace takes it and clears it).
    @Published var focusID: String?
    /// Why the notch opened by itself (`AgentsAutoOpen`): shown as a banner at the top of that agent's detail in the Agents view.
    @Published var announcement: AgentAnnouncement?
    /// Agents whose row on the dashboard is lit for a moment (the notch was in use when they needed attention, so it did not switch).
    @Published private(set) var flashed: Set<String> = []
    private var flashWork: [String: DispatchWorkItem] = [:]
    /// The session whose detail the Agents view shows right now (nil: the grid, or the view is not on screen). The view keeps it.
    var shownDetailID: String?

    let scanner = AgentScanner()
    @Published private(set) var scanStatus = AgentScanner.Status()
    /// The folders being read (the allowed ones when the App Store edition had to ask).
    private(set) var scanRoots: [AgentKind: URL] = [:]
    private var lastScan: Bool?
    /// Sessions that finished a turn today (the Nook dashboard's "done today"); starts over at midnight.
    private var finishedIDs: Set<String> = []
    private var finishedDay = Calendar.current.startOfDay(for: Date())
    @Published private(set) var doneToday = 0
    private let isShared: Bool
    private var started = false

    init(isShared: Bool = false) {
        self.isShared = isShared
        scanner.onChange = { [weak self] sessions, status in MainActor.assumeIsolated { self?.applyScan(sessions, status: status) } }
    }

    // MARK: Lifecycle

    func start() {
        guard !started, isShared else { return }
        started = true
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        settingsChanged()
    }

    private func settingsChanged() {
        // Gallery renders never read; real and automation runs do (automation on its own folders).
        let scanning = Pref.bool(Key.scan, true) && !ScoutRuntime.isGallery
        if lastScan != scanning {
            lastScan = scanning
            if scanning {
                refreshScanSources()
                scanner.start()
            } else {
                scanner.stop()
                sessions.removeAll()
                scanStatus = AgentScanner.Status()
                refreshActivity()
            }
        }
    }

    /// Where the scanner reads: the real folders (the allowed ones when a sandboxed Scout had to ask), or a test folder in scripted runs.
    func refreshScanSources() {
        var sources: [AgentScanner.Source] = []
        for agent in AgentKind.allCases {
            var root = ScoutRuntime.isScripted ? AgentAccess.automationRoot(for: agent) : AgentAccess.defaultRoot(for: agent)
            if Edition.isAppStore, !ScoutRuntime.isScripted, AgentAccess.probe(root) == .denied, let allowed = AgentAccess.allowedRoot(for: agent) { root = allowed }
            scanRoots[agent] = root
            sources.append(.init(agent: agent, root: root))
        }
        scanner.setSources(sources)
    }

    // MARK: Notch: the live activity

    var workingCount: Int { sessions.filter { $0.state == .working }.count }
    var waitingCount: Int { sessions.filter { $0.state == .waiting }.count }

    private var activityShown = false
    private var lastActivityUpdate = Date.distantPast
    private var activityWork: DispatchWorkItem?

    /// Keeps the closed notch's wings in step with the sessions: shown while an agent works or waits, a short "done" afterwards.
    /// Calm: at most a few updates a second (the wings' own numbers animate by themselves, they watch the store).
    func refreshActivity() {
        guard isShared else { return }
        let wait = 0.35 - Date().timeIntervalSince(lastActivityUpdate)
        if wait > 0 {
            guard activityWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.activityWork = nil; self?.applyActivity() } }
            activityWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
            return
        }
        applyActivity()
    }

    private func applyActivity() {
        lastActivityUpdate = Date()
        let center = LiveActivityCenter.shared
        let working = workingCount, waiting = waitingCount
        // The closed notch shows the same agents as the TV and the den, for as long as they are there:
        // not only while one works or waits. They leave when their chat closes.
        let active = working > 0 || waiting > 0 || !sessions.isEmpty
        if !active {
            if activityShown, !sessions.isEmpty {
                // Everything finished: the wings say so for a moment, then step aside.
                activityShown = false
                center.show(Self.wings(store: self, expiresAfter: 6))
            } else {
                center.dismiss(id: "agents.main")
            }
            return
        }
        activityShown = true
        // The notch keeps opening on the dashboard (it lists the agents). An agent that needs you opens it for a moment through
        // `AgentsAutoOpen`, which never sets `preferredWorkspace`: taking over by a saved preference once hid the dashboard for good,
        // since the user's own sessions are almost always working.
        center.show(Self.wings(store: self, expiresAfter: nil))
    }

    /// The `.agent` activity: left the glyph and counts, right the most important session; hovering lists every agent;
    /// a click opens the Agents grid. It wins the wings over now playing (media stays the small bubble).
    static func wings(store: AgentsStore, expiresAfter: TimeInterval?) -> LiveActivity {
        LiveActivity(id: "agents.main", kind: .agent, expiresAfter: expiresAfter, onTap: { NotchNavigator.shared.open(.agents) }, leading: {
            AgentWingLeft(store: store)
        }, trailing: {
            AgentWingRight(store: store)
        }).withDetail {
            AgentWingDetail(store: store)
        }
    }

    private func markFinished(_ id: String, at date: Date) {
        let today = Calendar.current.startOfDay(for: Date())
        if today != finishedDay { finishedDay = today; finishedIDs = []; doneToday = 0 }
        guard date >= today, finishedIDs.insert(id).inserted else { return }
        doneToday = finishedIDs.count
    }

    // MARK: Sessions found by reading the transcripts

    /// The scanner's view of every active session: the transcript owns what it says (title, steps, to-dos, helpers, times, whether it waits).
    func applyScan(_ found: [AgentSession], status: AgentScanner.Status) {
        if status != scanStatus { scanStatus = status }
        let ids = Set(found.map(\.id))
        sessions.removeAll { !ids.contains($0.id) }
        for s in found {
            if let end = s.finishedAt { markFinished(s.id, at: end) }
            if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.append(s) }
        }
        sessions.sort { ($0.state == .waiting ? 0 : 1, -$0.lastEventAt.timeIntervalSince1970) < ($1.state == .waiting ? 0 : 1, -$1.lastEventAt.timeIntervalSince1970) }
        if selectedID == nil || !sessions.contains(where: { $0.id == selectedID }) { selectedID = sessions.first?.id }
        refreshActivity()
    }

    // MARK: Status (scripted runs: `scout://agents.status`)

    /// Everything a test needs to see, as plain JSON values.
    func statusObject() -> [String: Any] {
        [
            "edition": Edition.name,
            "scan": ["enabled": lastScan ?? false, "tracked": scanStatus.tracked, "sessions": scanStatus.sessions, "watching": scanStatus.watching,
                     "claude": Self.name(scanStatus.access[.claude]), "codex": Self.name(scanStatus.access[.codex]),
                     "claudeRoot": scanRoots[.claude]?.path ?? "", "codexRoot": scanRoots[.codex]?.path ?? ""],
            "sessions": sessions.map { s -> [String: Any] in
                ["id": s.id, "agent": s.agent.rawValue, "project": s.project, "state": s.state.title, "title": s.title, "note": s.note,
                 "steps": s.steps.count, "current": s.currentStep.map { "\($0.tool): \($0.summary)" } ?? "", "todos": "\(s.todosDone)/\(s.todos.count)", "subagents": s.subagents]
            },
        ]
    }

    private static func name(_ a: AgentScanner.Access?) -> String {
        switch a ?? .unknown {
        case .unknown: "unknown"
        case .ok: "ok"
        case .missing: "missing"
        case .denied: "denied"
        }
    }

    // MARK: Sample data (scripted runs and the gallery)

    func loadSamples(selecting: String? = nil) {
        sessions = AgentSession.samples()
        selectedID = selecting ?? sessions.first?.id
    }

    /// The gallery: exactly these sessions.
    func loadSessions(_ list: [AgentSession], selecting: String? = nil) {
        sessions = list
        selectedID = selecting ?? list.first?.id
    }

    // MARK: The lit row

    /// Lights an agent's row on the dashboard for a few seconds.
    func flash(_ sessionID: String, seconds: TimeInterval = 4) {
        flashed.insert(sessionID)
        flashWork[sessionID]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.flashed.remove(sessionID)
                self?.flashWork[sessionID] = nil
            }
        }
        flashWork[sessionID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func clearFlashes() {
        flashWork.values.forEach { $0.cancel() }
        flashWork = [:]
        if !flashed.isEmpty { flashed = [] }
    }

    /// The gallery lights these rows (no timer).
    func previewFlashed(_ ids: Set<String>) { flashed = ids }

    func previewScan(_ status: AgentScanner.Status) { scanStatus = status }
    func previewDoneToday(_ n: Int) { doneToday = n }

    func clearSamples() { sessions = [] }
}
