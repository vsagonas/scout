import AppKit
import SwiftUI

/// How the notch tells you an agent needs an answer.
enum AgentAttention: String, CaseIterable, Identifiable {
    case peek, open, quiet
    var id: String { rawValue }
    var title: String {
        switch self {
        case .peek: String(localized: "Show a card under the notch")
        case .open: String(localized: "Open the notch on Agents")
        case .quiet: String(localized: "Only the dot beside the notch")
        }
    }
}

/// The state of every Claude Code / Codex session that talks to Scout's hooks, and the requests they wait on.
@MainActor
final class AgentsStore: ObservableObject {
    static let shared = AgentsStore(directory: AppPaths.folder("agents"), isShared: true,
                                    port: ScoutRuntime.isAutomation ? AgentHooks.automationPort : AgentHooks.defaultPort,
                                    fixedToken: ScoutRuntime.isAutomation ? ScoutRuntime.arguments.firstIndex(of: "--agents-token").flatMap { $0 + 1 < ScoutRuntime.arguments.count ? ScoutRuntime.arguments[$0 + 1] : nil } : nil)

    enum Key {
        static let enabled = "agents.enabled"                  // run the local bridge (see enabledByDefault)
        /// The full edition listens from the start. The App Store edition opens its loopback port only once the user
        /// copies the hooks (or turns it on), so a fresh install never listens for nothing.
        static var enabledByDefault: Bool { !Edition.isAppStore }
        static let preferWorkspace = "agents.preferWorkspace"  // RETIRED: the old "open the notch on Agents" switch; `AgentsAutoOpen` migrates it once and replaces it
        static let permissionCards = "agents.permissionCards"  // answer permissions and questions from the notch (default on)
        static let scan = "agents.scan"                        // find sessions by reading the agents' transcript files (default on)
        static let attention = "agents.attention"              // peek / open / quiet when an agent needs an answer (default peek)
    }

    /// What the Settings page shows about the bridge.
    struct BridgeInfo: Equatable {
        var running = false
        var port: UInt16 = 0
        var fallback = false
        var failure: String?
    }

    /// One hook call as the bridge saw it (the newest 60 are kept, for the status file and tests).
    struct EventRecord: Equatable {
        var time: Date
        var agent: AgentKind
        var name: String
        var session: String
        var mode: String
        var tool: String?
    }

    @Published private(set) var sessions: [AgentSession] = [] {
        didSet {   // an agent that is gone gives up its place in the row
            if isShared { AgentFoundOrder.forget(Set(oldValue.map(\.id)).subtracting(sessions.map(\.id))) }
        }
    }
    @Published private(set) var pending: [AgentPending] = []
    @Published private(set) var bridgeInfo = BridgeInfo()
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
    /// The center that shows this store's cards under the notch: the shared one for the shared store, none for the others.
    var cardCenter: LiveActivityCenter?
    /// True while `AgentsAutoOpen` is watching: a new request's card waits one turn of the main queue so the presenter can first decide
    /// whether the notch shows that request itself (then the card never appears).
    var defersCards = false
    /// Requests whose card is held back because the notch shows them itself (see `holdCards`).
    private(set) var cardsHeld: Set<UUID> = []
    private(set) var recent: [EventRecord] = []

    let bridge: AgentBridge
    let scanner = AgentScanner()
    @Published private(set) var scanStatus = AgentScanner.Status()
    /// The folders being read (the allowed ones when the App Store edition had to ask).
    private(set) var scanRoots: [AgentKind: URL] = [:]
    private var lastScan: Bool?
    private var endedAt: [String: Date] = [:]
    /// Sessions that finished a turn today (the Nook dashboard's "done today"); starts over at midnight.
    private var finishedIDs: Set<String> = []
    private var finishedDay = Calendar.current.startOfDay(for: Date())
    @Published private(set) var doneToday = 0
    private let isShared: Bool
    private var responders: [UUID: HookResponder] = [:]
    private var sweep: Timer?
    private var lastEnabled: Bool?
    private var started = false

    init(directory: URL, isShared: Bool = false, port: UInt16 = AgentHooks.defaultPort, fixedToken: String? = nil) {
        bridge = AgentBridge(directory: directory, defaultPort: port, fixedToken: fixedToken)
        self.isShared = isShared
        cardCenter = isShared ? LiveActivityCenter.shared : nil
        bridge.handler = { [weak self] agent, name, mode, body, responder in
            guard let event = AgentEvent.parse(agent: agent, data: body, fallbackName: name) else { responder.respond(""); return }
            // The main dispatch queue (not a Swift Task) so a test can drive it with a nested run loop.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { responder.respond(""); return }
                    self.receive(event, mode: mode, responder: responder)
                }
            }
        }
        bridge.onChange = { [weak self] in MainActor.assumeIsolated { self?.syncBridge() } }
        scanner.onChange = { [weak self] sessions, status in MainActor.assumeIsolated { self?.applyScan(sessions, status: status) } }
        if ScoutRuntime.isAutomation {
            bridge.debugStatus = { [weak self] in DispatchQueue.main.sync { MainActor.assumeIsolated { self?.statusJSON() ?? "{}" } } }
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        if isShared {
            NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.settingsChanged() }
            }
            settingsChanged()
        } else if Edition.answersAgents {
            bridge.start()
        }
        sweep = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruneStale() }
        }
    }

    private func settingsChanged() {
        // Gallery renders never listen or read; real and automation runs do (automation on its own port and folders).
        // A scripted run given a test key (`--agents-token`) always listens: a sandboxed build can't be told otherwise from outside.
        let forced = ScoutRuntime.isAutomation && ScoutRuntime.arguments.contains("--agents-token")
        let enabled = Edition.answersAgents && (Pref.bool(Key.enabled, Key.enabledByDefault) || forced) && !ScoutRuntime.isGallery   // the App Store edition never listens
        if lastEnabled != enabled {
            lastEnabled = enabled
            if enabled { bridge.start() } else { bridge.stop() }
        }
        let scanning = Pref.bool(Key.scan, true) && !ScoutRuntime.isGallery
        if lastScan != scanning {
            lastScan = scanning
            if scanning {
                refreshScanSources()
                scanner.start()
            } else {
                scanner.stop()
                sessions.removeAll { $0.scanned && $0.lastHookAt == nil }
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

    func stop() { bridge.stop() }

    var bridgeRunning: Bool { bridgeInfo.running }

    private func syncBridge() {
        let info = BridgeInfo(running: bridge.isRunning, port: bridge.port, fallback: bridge.usingFallbackPort, failure: bridge.failure)
        let nowListening = info.running && (!bridgeInfo.running || info.port != bridgeInfo.port)
        if info != bridgeInfo { bridgeInfo = info }
        // Listening (again, or on another port): hooks in a folder the person connected are brought up to date by themselves.
        if nowListening, isShared, !ScoutRuntime.isScripted { AgentFolderAccess.updateIfOutdated(port: bridge.advertisedPort, token: bridge.token) }
    }

    /// The hooks block for an agent, for the port Scout listens on (or will try first).
    func snippet(_ agent: AgentKind) -> String { AgentHooks.snippet(agent, port: bridge.advertisedPort, token: bridge.token) }

    // MARK: Receiving hooks

    func receive(_ event: AgentEvent, mode: String, responder: HookResponder) {
        recent.append(EventRecord(time: Date(), agent: event.agent, name: event.name, session: event.sessionID, mode: mode, tool: event.toolName))
        if recent.count > 60 { recent.removeFirst(recent.count - 60) }
        let now = Date()
        var session = sessions.first { $0.id == event.sessionID } ?? AgentSession(id: event.sessionID, agent: event.agent, cwd: event.cwd)
        if !event.cwd.isEmpty { session.cwd = event.cwd }
        session.lastEventAt = now
        session.lastHookAt = now
        var hold = false
        let asks = Pref.bool(Key.permissionCards, true)
        let hasPending = pending.contains { $0.sessionID == session.id }

        switch event.name {
        case "SessionStart":
            if !sessions.contains(where: { $0.id == session.id }) { session.state = .idle }
        case "SessionEnd":
            endedAt[session.id] = now
            sessions.removeAll { $0.id == session.id }
            dropPending(forSession: session.id, answerEmpty: true)
            responder.respond("")
            refreshActivity()
            return
        case "UserPromptSubmit":
            if hasPending { dropPending(forSession: session.id, answerEmpty: true) }   // a new prompt: anything still held is stale
            session.state = .working
            session.turnStartedAt = now
            session.finishedAt = nil
            if let prompt = event.prompt, !prompt.isEmpty { session.title = Self.shorten(prompt, 90) }
            if !session.todos.isEmpty, session.todos.allSatisfy({ $0.status == .completed }) { session.todos = [] }
            session.steps.append(AgentStep(id: UUID().uuidString, tool: "Prompt", summary: Self.shorten(event.prompt ?? "", 90), at: now, done: true))
        case "PreToolUse":
            if mode == "question" {
                guard asks, !event.questions.isEmpty else { break }
                addPending(AgentPending(sessionID: session.id, kind: .question, tool: "AskUserQuestion", summary: event.questions[0].question, detail: "",
                                        questions: event.questions, rawToolInput: event.rawToolInput, agent: event.agent), responder: responder)
                session.state = .waiting
                hold = true
            } else if event.toolName != "AskUserQuestion" {
                let id = event.toolUseID ?? UUID().uuidString
                if !session.steps.contains(where: { $0.id == id }) {
                    session.steps.append(AgentStep(id: id, tool: event.toolName ?? "Tool", summary: Self.shorten(event.toolSummary ?? "", 120), at: now, done: false))
                }
                if let todos = event.todos { session.todos = todos }
                if session.state == .done { session.turnStartedAt = now; session.finishedAt = nil }
                if !hasPending { session.state = .working }
            }
        case "PostToolUse", "PostToolUseFailure":
            // The tool already ran: a permission request for it that is still on the notch was answered in the terminal.
            dropStalePermissions(sessionID: session.id, tool: event.toolName, input: event.rawToolInput)
            if let id = event.toolUseID, let i = session.steps.firstIndex(where: { $0.id == id }) {
                session.steps[i].done = true
                session.steps[i].failed = event.name == "PostToolUseFailure"
            }
            if session.state == .waiting, !pending.contains(where: { $0.sessionID == session.id }) { session.state = .working }
        case "Notification":
            // Idle and "finished" notices are not a request: a done session stays done.
            if ["permission_prompt", "agent_needs_input", "elicitation_dialog"].contains(event.notificationType ?? ""), session.state != .done { session.state = .waiting }
        case "Stop":
            // The turn ended: it is your move (waiting), and after a while done.
            session.state = .waiting
            session.note = AgentNote.finished
            session.finishedAt = now
            markFinished(session.id, at: now)
            session.lastMessage = AgentText.firstSentence(event.lastMessage ?? "")
            for i in session.steps.indices { session.steps[i].done = true }
            dropPending(forSession: session.id, answerEmpty: true)
            // No card drops for a finish: the two-line message beside the notch says it.
        case "SubagentStart":
            session.subagents += 1
        case "SubagentStop":
            session.subagents = max(0, session.subagents - 1)
        case "PermissionRequest":
            let passThrough = ["AskUserQuestion", "ExitPlanMode"].contains(event.toolName ?? "") || !asks
            if !passThrough {
                addPending(AgentPending(sessionID: session.id, kind: .permission, tool: event.toolName ?? "", summary: Self.shorten(event.toolSummary ?? "", 200),
                                        detail: event.toolDetail ?? "", questions: [], rawToolInput: event.rawToolInput, agent: event.agent,
                                        permissionSuggestions: event.permissionSuggestions), responder: responder)
                session.state = .waiting
                hold = true
            }
        default:
            break
        }
        if session.steps.count > 60 { session.steps.removeFirst(session.steps.count - 60) }
        if session.state != .waiting { session.note = ""; session.finishedAt = event.name == "Stop" ? session.finishedAt : nil }
        upsert(session)
        if !hold { responder.respond("") }
        if hold { selectedID = session.id } else if selectedID == nil { selectedID = session.id }
        refreshActivity()
    }

    private func upsert(_ session: AgentSession) {
        if let i = sessions.firstIndex(where: { $0.id == session.id }) { sessions[i] = session } else { sessions.insert(session, at: 0) }
        sessions.sort { ($0.state == .waiting ? 0 : 1, -$0.lastEventAt.timeIntervalSince1970) < ($1.state == .waiting ? 0 : 1, -$1.lastEventAt.timeIntervalSince1970) }
    }

    nonisolated static func shorten(_ s: String, _ n: Int) -> String { AgentText.shorten(s, n) }

    private func markFinished(_ id: String, at date: Date) {
        let today = Calendar.current.startOfDay(for: Date())
        if today != finishedDay { finishedDay = today; finishedIDs = []; doneToday = 0 }
        guard date >= today, finishedIDs.insert(id).inserted else { return }
        doneToday = finishedIDs.count
    }

    // MARK: Pending requests

    private var attention: AgentAttention { AgentAttention(rawValue: Pref.string(Key.attention, AgentAttention.peek.rawValue)) ?? .peek }

    private func addPending(_ request: AgentPending, responder: HookResponder) {
        pending.append(request)
        responders[request.id] = responder
        let id = request.id
        responder.onClose = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.dropPending(id) } }   // answered in the terminal instead
        }
        switch attention {
        case .peek:
            guard cardCenter != nil else { break }
            if defersCards {
                // One turn later: `AgentsAutoOpen` looks at the request first and may open the notch on it, which shows the answer
                // controls itself, so no card is wanted. The presenter's own turn was queued before this one.
                DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in
                    guard let self, self.pending.contains(where: { $0.id == id }) else { return }
                    self.presentCard(for: request)
                } }
            } else {
                presentCard(for: request)
            }
        case .open:
            guard isShared else { break }
            selectedID = request.sessionID
            NotchNavigator.shared.open(.agents)
        case .quiet: break
        }
    }

    private func presentCard(for request: AgentPending) {
        guard let center = cardCenter, !cardsHeld.contains(request.id) else { return }
        let id = request.id
        center.present(NotchCard(id: "agent.pending.\(id)", kind: .agent, duration: 600, onTap: {
            NotchNavigator.shared.open(.agents)
        }) {
            PendingView(request: request, store: self, compact: true)
        })
    }

    /// The requests whose card is held back right now: the notch shows them in the Agents view (an automatic opening, or the detail
    /// of that agent), so a card under the island would show the same answer controls twice. Exactly these are held: a card that
    /// was up is taken away, and one that was held and still waits for an answer comes back.
    func holdCards(_ ids: Set<UUID>) {
        guard ids != cardsHeld else { return }
        let released = cardsHeld.subtracting(ids)
        cardsHeld = ids
        for id in ids { cardCenter?.dismissCard(id: "agent.pending.\(id)") }
        guard attention == .peek else { return }
        for request in pending where released.contains(request.id) { presentCard(for: request) }
    }

    private func dropPending(_ id: UUID) {
        guard let request = pending.first(where: { $0.id == id }) else { return }
        pending.removeAll { $0.id == id }
        responders[id] = nil
        cardsHeld.remove(id)
        cardCenter?.dismissCard(id: "agent.pending.\(id)")
        resumeWorking(request.sessionID)
        refreshActivity()
    }

    private func dropPending(forSession sessionID: String, answerEmpty: Bool) {
        for request in pending where request.sessionID == sessionID {
            if answerEmpty { responders[request.id]?.respond("") }
            responders[request.id] = nil
            cardsHeld.remove(request.id)
            cardCenter?.dismissCard(id: "agent.pending.\(request.id)")
        }
        pending.removeAll { $0.sessionID == sessionID }
    }

    /// True when two tool inputs (JSON) hold the same values.
    nonisolated static func sameInput(_ a: Data?, _ b: Data?) -> Bool {
        guard let a, let b,
              let x = try? JSONSerialization.jsonObject(with: a) as? NSDictionary, let y = try? JSONSerialization.jsonObject(with: b) as? NSDictionary else { return a == nil && b == nil }
        return x.isEqual(y)
    }

    private func dropStalePermissions(sessionID: String, tool: String?, input: Data?) {
        guard let tool else { return }
        for request in pending where request.sessionID == sessionID && request.kind == .permission && request.tool == tool && Self.sameInput(request.rawToolInput, input) {
            responders[request.id]?.respond("")
            responders[request.id] = nil
            LiveActivityCenter.shared.dismissCard(id: "agent.pending.\(request.id)")
        }
        pending.removeAll { $0.sessionID == sessionID && $0.kind == .permission && $0.tool == tool && Self.sameInput($0.rawToolInput, input) }
    }

    private func resumeWorking(_ sessionID: String) {
        if let i = sessions.firstIndex(where: { $0.id == sessionID }), sessions[i].state == .waiting,
           !pending.contains(where: { $0.sessionID == sessionID }) { sessions[i].state = .working }
    }

    // MARK: Answers

    enum Decision { case allow, alwaysAllow, deny, ask, answers([String: String]) }

    func decide(_ id: UUID, _ decision: Decision) {
        guard let request = pending.first(where: { $0.id == id }) else { return }
        let body: String
        switch decision {
        case .allow: body = Self.permissionBody(allow: true)
        case .alwaysAllow: body = Self.permissionBody(allow: true, updates: request.alwaysAllow?.updates)
        case .deny: body = Self.permissionBody(allow: false, message: "Denied from the Scout notch")
        case .ask: body = ""
        case .answers(let answers): body = Self.questionBody(rawToolInput: request.rawToolInput, answers: answers)
        }
        responders[id]?.respond(request.kind == .permission || !body.isEmpty ? body : "")
        dropPending(id)
    }

    /// What a PermissionRequest hook prints to allow or deny. `updates` are the agent's own suggested permission
    /// updates, echoed back as `updatedPermissions` for "Always allow".
    nonisolated static func permissionBody(allow: Bool, message: String? = nil, updates: [[String: Any]]? = nil) -> String {
        var decision: [String: Any] = ["behavior": allow ? "allow" : "deny"]
        if allow, let updates, !updates.isEmpty { decision["updatedPermissions"] = updates }
        if !allow { decision["message"] = message ?? "Denied"; decision["interrupt"] = false }
        return json(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]])
    }

    /// What a PreToolUse hook prints to answer an AskUserQuestion: the same input plus `answers`
    /// (question text → the chosen label; several labels joined with ", "; free text as typed).
    nonisolated static func questionBody(rawToolInput: Data?, answers: [String: String]) -> String {
        var input = (rawToolInput.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        input["answers"] = answers
        return json(["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": input]])
    }

    nonisolated private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Notch: the live activity and the "done" card

    var workingCount: Int { sessions.filter { $0.state == .working }.count }
    var waitingCount: Int { pending.count + sessions.filter { s in s.state == .waiting && !pending.contains(where: { $0.sessionID == s.id }) }.count }

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
        // The notch keeps opening on the dashboard (it lists the agents). An agent that needs you, comes back after a long task or
        // fails opens it for a moment through `AgentsAutoOpen`, which never sets `preferredWorkspace`: taking over by a saved
        // preference once hid the dashboard for good, since the user's own sessions are almost always working.
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

    private func pruneStale() {
        let now = Date()
        // Sessions the scanner follows are timed by the scanner; these are the ones only the hooks know.
        for i in sessions.indices where !sessions[i].scanned {
            if sessions[i].state == .working, now.timeIntervalSince(sessions[i].lastEventAt) > 600 { sessions[i].state = .idle }
            // A finished turn waits for you a couple of minutes, then it is done.
            if sessions[i].state == .waiting, let end = sessions[i].finishedAt, now.timeIntervalSince(end) > 120,
               !pending.contains(where: { $0.sessionID == sessions[i].id }) { sessions[i].state = .done; sessions[i].note = "" }
        }
        sessions.removeAll { s in !s.scanned && now.timeIntervalSince(s.lastEventAt) > 6 * 3600 && !pending.contains(where: { $0.sessionID == s.id }) }
        endedAt = endedAt.filter { now.timeIntervalSince($0.value) < 3600 }
        refreshActivity()
    }

    // MARK: Sessions found by reading the transcripts

    /// The scanner's view of every active session. A session the hooks also know (same id) is one session: the
    /// transcript owns what it says (title, steps, to-dos, helpers, times); a request held for an answer, and the state
    /// right after a hook event, stay as the hooks left them.
    func applyScan(_ found: [AgentSession], status: AgentScanner.Status) {
        if status != scanStatus { scanStatus = status }
        let now = Date()
        let ids = Set(found.map(\.id))
        sessions.removeAll { gone in gone.scanned && !ids.contains(gone.id) && !pending.contains(where: { $0.sessionID == gone.id }) }
        for var s in found {
            if let end = s.finishedAt { markFinished(s.id, at: end) }
            // A session whose hook said "ended" stays gone until its file changes again.
            if let ended = endedAt[s.id], s.lastEventAt <= ended.addingTimeInterval(2) { continue }
            if let i = sessions.firstIndex(where: { $0.id == s.id }) {
                let old = sessions[i]
                let held = pending.contains { $0.sessionID == s.id }
                let hookFresh = old.lastHookAt.map { now.timeIntervalSince($0) < 20 } ?? false
                s.lastHookAt = old.lastHookAt
                if held {
                    s.state = .waiting; s.note = old.note; s.finishedAt = nil
                } else if hookFresh {
                    s.state = old.state; s.note = old.note; s.finishedAt = old.finishedAt; s.turnStartedAt = old.turnStartedAt
                    s.subagents = max(s.subagents, old.subagents)
                }
                sessions[i] = s
            } else {
                sessions.append(s)
            }
        }
        sessions.sort { ($0.state == .waiting ? 0 : 1, -$0.lastEventAt.timeIntervalSince1970) < ($1.state == .waiting ? 0 : 1, -$1.lastEventAt.timeIntervalSince1970) }
        if selectedID == nil || !sessions.contains(where: { $0.id == selectedID }) { selectedID = sessions.first?.id }
        refreshActivity()
    }

    // MARK: Status (scripted runs: `scout://agents.status`)

    /// Everything a test needs to see, as plain JSON values.
    func statusObject() -> [String: Any] {
        let f = ISO8601DateFormatter()
        return [
            "edition": Edition.name,
            "running": bridge.isRunning, "port": Int(bridge.port), "defaultPort": Int(bridge.defaultPort), "fallback": bridge.usingFallbackPort,
            "failure": bridge.failure ?? "",
            "directory": bridge.directory.path,
            "scan": ["enabled": lastScan ?? false, "tracked": scanStatus.tracked, "sessions": scanStatus.sessions, "watching": scanStatus.watching,
                     "claude": Self.name(scanStatus.access[.claude]), "codex": Self.name(scanStatus.access[.codex]),
                     "claudeRoot": scanRoots[.claude]?.path ?? "", "codexRoot": scanRoots[.codex]?.path ?? ""],
            "sessions": sessions.map { s -> [String: Any] in
                ["id": s.id, "agent": s.agent.rawValue, "project": s.project, "state": s.state.title, "title": s.title, "scanned": s.scanned, "note": s.note,
                 "steps": s.steps.count, "current": s.currentStep.map { "\($0.tool): \($0.summary)" } ?? "", "todos": "\(s.todosDone)/\(s.todos.count)", "subagents": s.subagents]
            },
            "pending": pending.map { p -> [String: Any] in
                ["id": p.id.uuidString, "session": p.sessionID, "kind": p.kind == .permission ? "permission" : "question", "tool": p.tool,
                 "summary": p.summary, "alwaysAllow": p.alwaysAllow?.label ?? ""]
            },
            "events": recent.map { ["time": f.string(from: $0.time), "agent": $0.agent.rawValue, "event": $0.name, "session": $0.session, "mode": $0.mode, "tool": $0.tool ?? ""] },
        ]
    }

    func statusJSON() -> String {
        (try? JSONSerialization.data(withJSONObject: statusObject(), options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private static func name(_ a: AgentScanner.Access?) -> String {
        switch a ?? .unknown {
        case .unknown: "unknown"
        case .ok: "ok"
        case .missing: "missing"
        case .denied: "denied"
        }
    }

    /// Answers the pending request at `index` (scripted runs only).
    @discardableResult
    func debugDecide(index: Int, decision: String, text: String?) -> Bool {
        guard pending.indices.contains(index) else { return false }
        let request = pending[index]
        switch decision {
        case "allow": self.decide(request.id, .allow)
        case "always": self.decide(request.id, .alwaysAllow)
        case "deny": self.decide(request.id, .deny)
        case "ask": self.decide(request.id, .ask)
        case "answer":
            guard let q = request.questions.first else { return false }
            self.decide(request.id, .answers([q.question: text ?? q.options.first?.label ?? ""]))
        default: return false
        }
        return true
    }

    // MARK: Sample data (scripted runs and the gallery)

    func loadSamples(pending custom: [AgentPending]? = nil, selecting: String? = nil) {
        sessions = AgentSession.samples()
        selectedID = selecting ?? sessions.first?.id
        pending = custom ?? [AgentPending(sessionID: "demo-2", kind: .permission, tool: "Bash", summary: "npm run lint && npm run build",
                                          detail: "npm run lint && npm run build", questions: [], rawToolInput: nil, agent: .codex)]
        for request in pending { if let i = sessions.firstIndex(where: { $0.id == request.sessionID }) { sessions[i].state = .waiting } }
    }

    /// The gallery: exactly these sessions and held requests.
    func loadSessions(_ list: [AgentSession], pending requests: [AgentPending] = [], selecting: String? = nil) {
        sessions = list
        pending = requests
        selectedID = selecting ?? list.first?.id
        for request in requests { if let i = sessions.firstIndex(where: { $0.id == request.sessionID }) { sessions[i].state = .waiting } }
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

    /// The gallery shows the Settings page as it looks with a running bridge.
    func previewBridge(_ info: BridgeInfo) { bridgeInfo = info }
    func previewScan(_ status: AgentScanner.Status) { scanStatus = status }
    func previewDoneToday(_ n: Int) { doneToday = n }

    func clearSamples() { sessions = []; pending = [] }
}
