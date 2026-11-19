import AppKit
import Combine
import SwiftUI

/// Why the notch opened by itself: shown at the top of that agent's detail in the Agents view ("infra needs you").
struct AgentAnnouncement: Equatable {
    enum Kind: Equatable {
        case needsYou
        case finished(minutes: Int)
        case error
    }

    var sessionID: String
    var kind: Kind
    var at: Date
}

/// The notch opens by itself when an agent starts NEEDING you (a question, a plan waiting for approval), and says the details.
/// An agent that FINISHES, or stops with an error, never opens it and drops no card: the two-line message in the right wing beside the
/// camera says it.
/// For a needs-you it opens the Agents view from the closed notch with THAT agent in detail and a banner on top: who, "needs you",
/// and the first sentence of its latest message. The person answers the agent in the agent's own window. It closes by itself after about 20 s
/// unless the pointer is on the island, a text field has the cursor, or the person chose something else. A notch that is already open and in use is never switched:
/// that agent's row on the dashboard lights up for a moment instead.
///
/// Calm, by rule: once per agent per question (again only after it was answered), at most one opening every 20 s (a needs-you waits for
/// its turn while the agent still asks), nothing in scripted runs, nothing while the notch is hidden in a full-screen app.
///
/// The pieces a layout of the Agents panel and view reuses (all on `AgentsStore`, so any new layout gets them by reading it):
///   - `store.announcement` + `AgentBanner(announcement:session:)` : the banner for the agent in detail (the view clears it when it goes away);
///   - `store.flashed` + `.agentLit(_:)` : the lit row on the dashboard;
///   - `store.focusID` : the view takes it and shows that agent; `store.shownDetailID` : the view reports which agent it shows
///     (nil for the grid), the presenter reads it to see whether the person chose something else.
/// A height the banner needs goes through `NotchNavigator.requestHeight(_:resizeMax:by: .agents)` (see `AgentsWorkspaceView`); this file
/// never writes `workspaceHeight` or `resizeMax`.
///
/// It is TRANSIENT: it never writes the saved last workspace and never sets `NotchNavigator.preferredWorkspace` (that is what once
/// made the dashboard disappear). When it closes the notch, the next open is the dashboard.
@MainActor
final class AgentsAutoOpen {
    static let shared = AgentsAutoOpen()

    // MARK: Settings (Settings › Agents)

    static let enabledKey = "agents.autoOpen"
    static let migratedKey = "agents.autoOpen.migrated"
    static var settingOn: Bool { Pref.bool(enabledKey, true) }

    /// Once: the old "Open the notch on Agents when one needs an answer" switch (default OFF) is replaced by the new one (default ON).
    /// A switch that was never touched has no saved value, so only a person who turned it off themselves keeps it off.
    static func migrateOldSetting(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)
        if defaults.object(forKey: AgentsStore.Key.preferWorkspace) as? Bool == false, defaults.object(forKey: enabledKey) == nil {
            defaults.set(false, forKey: enabledKey)
        }
    }

    // MARK: Timing

    static let cooldown: TimeInterval = 20
    static let showForNeedsYou: TimeInterval = 20
    /// How long the view has to show the agent after the opening before "it is not showing it" means the person chose something else.
    static let grace: TimeInterval = 1.5

    /// Everything the presenter asks of the outside world, so a self-test can run it with a fake clock and a pretend pointer.
    struct Env {
        var now: @MainActor () -> Date = { Date() }
        var enabled: @MainActor () -> Bool = { AgentsAutoOpen.settingOn }
        var isScripted = ScoutRuntime.isScripted
        /// Every notch is hidden behind a full-screen app (or there is none to show).
        var hidden: @MainActor () -> Bool = {
            let all = NotchManager.shared.controllers
            return all.isEmpty || all.allSatisfy { $0.model.hiddenForFullscreen }
        }
        /// The pointer is on the open island (or one of its cards).
        var pointerInside: @MainActor () -> Bool = {
            guard let active = NotchManager.shared.active else { return false }
            return active.islandScreenRect.contains(NSEvent.mouseLocation)
        }
        /// A text field in the notch has the cursor.
        var typing: @MainActor () -> Bool = {
            guard let panel = NotchManager.shared.active?.panel else { return false }
            return panel.isKeyWindow && panel.firstResponder is NSText
        }
    }

    struct Event: Equatable {
        var sessionID: String
        var kind: AgentAnnouncement.Kind
        var at: Date
    }

    private struct Showing {
        var sessionID: String
        var openedAt: Date
        var until: Date
        var engaged = false
    }

    let agents: AgentsStore
    let navigator: NotchNavigator
    var env: Env
    /// When the notch last opened by itself, and what it opened for (tests read these).
    private(set) var lastOpen: Date?
    private(set) var opened: [Event] = []
    private var showing: Showing?
    private var wasWorking: [String: Bool] = [:]
    private var announcedAsking: Set<String> = []
    private var waiting: [Event] = []
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var started = false

    init(agents: AgentsStore? = nil, navigator: NotchNavigator? = nil, env: Env = Env()) {
        self.agents = agents ?? AgentsStore.shared
        self.navigator = navigator ?? NotchNavigator.shared
        self.env = env
    }

    /// True while an automatic opening is on screen and nobody has taken it over.
    var isShowing: Bool { showing != nil }

    // MARK: Starting

    /// Watches the store (not in scripted runs, and never the gallery's).
    func start() {
        guard !started, !env.isScripted else { return }
        started = true
        Self.migrateOldSetting()
        agents.objectWillChange.sink { [weak self] _ in
            // `objectWillChange` fires BEFORE the change: look at the settled store on the next turn of the main queue.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.process() } }
        }.store(in: &cancellables)
        process()   // what is there now is the baseline: nothing opens for it
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Stops watching (a self-test's own presenter; the app's one runs for as long as it lives).
    func stop() {
        timer?.invalidate()
        timer = nil
        cancellables.removeAll()
        started = false
        showing = nil
    }

    // MARK: Noticing

    /// Compares the store with the last look, and shows what is new (see the type's comment for the rules).
    func process() {
        let now = env.now()
        let sessions = agents.sessions
        var events: [Event] = []
        var alive = Set<String>()
        for s in sessions {
            alive.insert(s.id)
            let asks = AgentWingSummary.asks(s)
            let known = wasWorking[s.id] != nil
            if asks {
                if announcedAsking.insert(s.id).inserted, known {
                    // A session first seen already asking (a scan at launch) is the baseline.
                    events.append(Event(sessionID: s.id, kind: .needsYou, at: now))
                }
            } else {
                announcedAsking.remove(s.id)
            }
            // A finish or an error opens nothing: the two-line message in the right wing says it (see the type's comment).
            wasWorking[s.id] = s.state == .working
        }
        wasWorking = wasWorking.filter { alive.contains($0.key) }
        announcedAsking.formIntersection(alive)
        present(events, now: now)
    }

    // MARK: Showing

    private func present(_ events: [Event], now: Date) {
        guard !env.isScripted, env.enabled(), !env.hidden() else { waiting.removeAll(); return }
        // An open notch is never switched or closed for an agent: the agent's row lights up for a moment instead (`flash`), and the notch
        // stays open as it is.
        if navigator.isOpen {
            for event in waiting + events { agents.flash(event.sessionID) }
            waiting.removeAll()
            return
        }
        waiting += events.filter { $0.kind == .needsYou }
        let asking = Set(agents.sessions.filter { AgentWingSummary.asks($0) }.map(\.id))
        waiting.removeAll { !asking.contains($0.sessionID) }   // answered meanwhile
        if let last = lastOpen, now.timeIntervalSince(last) < Self.cooldown { return }
        if !waiting.isEmpty { open(waiting.removeFirst(), now: now) }
    }

    private func open(_ event: Event, now: Date) {
        guard agents.sessions.contains(where: { $0.id == event.sessionID }) else { return }
        lastOpen = now
        opened.append(event)
        if opened.count > 50 { opened.removeFirst(opened.count - 50) }
        agents.announcement = AgentAnnouncement(sessionID: event.sessionID, kind: event.kind, at: now)
        agents.selectedID = event.sessionID
        agents.focusID = event.sessionID   // the Agents view takes it and shows that agent in detail
        showing = Showing(sessionID: event.sessionID, openedAt: now, until: now.addingTimeInterval(Self.showForNeedsYou))
        navigator.open(.agents)   // from closed or open; never `preferredWorkspace`
    }

    /// Once a second: notices what changed, retries a needs-you that waited for its turn, and closes what it opened when its time is up.
    func tick() {
        process()
        defer { dropStaleAnnouncement() }
        guard var current = showing else { return }
        let now = env.now()
        // Someone chose something else, or closed it: hands off (the view had a moment to show the agent first).
        let settled = now.timeIntervalSince(current.openedAt) >= Self.grace
        guard navigator.isOpen, navigator.workspace == .agents, agents.shownDetailID == current.sessionID || !settled else {
            showing = nil
            return
        }
        let used = env.pointerInside() || env.typing()
        if used { current.engaged = true; showing = current }
        guard now >= current.until else { return }
        showing = nil
        if current.engaged || used { return }   // the pointer logic closes it when they leave
        navigator.close()   // honours anything that holds the notch open
    }

    /// The banner belongs to the opening: it goes when the opening is over, unless the person took it over and is still on that agent
    /// (then it goes when they leave or the notch closes).
    private func dropStaleAnnouncement() {
        guard let note = agents.announcement, showing?.sessionID != note.sessionID else { return }
        if navigator.isOpen, navigator.workspace == .agents, agents.shownDetailID == note.sessionID { return }
        agents.announcement = nil
    }
}

/// The highlight of an agent's row for a moment: the notch was in use when that agent needed attention, so it did not switch to it.
/// Any layout of an agent's row can wear it: `.agentLit(store.flashed.contains(session.id))` (the store lights and unlights it).
struct AgentLitModifier: ViewModifier {
    let lit: Bool
    var radius: CGFloat = 6

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.accent.opacity(lit ? 0.34 : 0)))   // behind the text, so it stays readable
            .animation(Theme.quick, value: lit)
    }
}

extension View {
    func agentLit(_ lit: Bool, radius: CGFloat = 6) -> some View { modifier(AgentLitModifier(lit: lit, radius: radius)) }
}

/// What the notch says when it opens by itself for an agent, as a 90s pager: a little plastic body with an LCD that says who and what
/// happened in pixel capitals ("INFRA NEEDS YOU", "SITE FINISHED AFTER 12 MIN", "API STOPPED WITH AN ERROR"), the failed step for an
/// error, and the first words of the agent's latest message in the system font so they read easily.
struct AgentBanner: View {
    let announcement: AgentAnnouncement
    let session: AgentSession

    static func headline(_ announcement: AgentAnnouncement, project: String) -> String {
        switch announcement.kind {
        case .needsYou: String(localized: "\(project) needs you")
        case .finished(let minutes): String(localized: "\(project) finished after \(minutes) min")
        case .error: String(localized: "\(project) stopped with an error")
        }
    }

    /// The colour of the LCD: amber asks, green is done, red stopped.
    static func lcd(_ kind: AgentAnnouncement.Kind) -> Color {
        switch kind {
        case .needsYou: Retro.Ink.phosphorAmber
        case .finished: Retro.Ink.phosphorGreen
        case .error: Color(red: 1.0, green: 0.38, blue: 0.32)
        }
    }

    private var glyph: String {
        switch announcement.kind {
        case .needsYou: "?"
        case .finished: "✓"
        case .error: "!"
        }
    }

    /// The failed step, for an error (what it was doing when it stopped).
    private var failedStep: String? {
        guard announcement.kind == .error, let step = session.steps.last(where: { $0.failed }) else { return nil }
        return String(localized: "\(step.tool) \(step.summary) failed")
    }

    var body: some View {
        if Retro.is8bit { pager } else { AgentMiniBanner(announcement: announcement, session: session) }   // the minimal look: a flat card
    }

    /// The 8-bit look: the pager.
    @ViewBuilder private var pager: some View {
        let ink = Self.lcd(announcement.kind)
        let text = Self.headline(announcement, project: session.project).uppercased()
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    RetroPixelText(glyph, pixel: 2, color: ink)
                    if Dash90.pixelSafe(text) {
                        ViewThatFits(in: .horizontal) {
                            RetroPixelText(text, pixel: 2, color: ink)
                            RetroPixelText(text, pixel: 1.5, color: ink)
                            RetroPixelText(text, pixel: 1, color: ink)
                            Text(verbatim: Self.headline(announcement, project: session.project)).font(.system(size: 12, weight: .bold)).foregroundStyle(ink).lineLimit(1)
                        }
                    } else {   // a headline the pixel font cannot draw (another script, or a project name in one): the system font
                        Text(verbatim: Self.headline(announcement, project: session.project)).font(.system(size: 12, weight: .bold)).foregroundStyle(ink).lineLimit(1)
                    }
                }
                if let failedStep {
                    Text(failedStep).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(ink.opacity(0.85)).lineLimit(1)
                }
                if !session.lastMessage.isEmpty {
                    Text(session.lastMessage).font(.system(size: 11)).foregroundStyle(Retro.Ink.osdWhite.opacity(0.92)).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.clear.retroBevel(.sunken, cornerRadius: AgentDenWindow.screenRadius - 6, depth: 1.5, face: Retro.shade(ink, -0.88)))   // inside the pager's curve
            // The pager's two keys and its beep lamp.
            VStack(spacing: 5) {
                Circle().fill(ink).frame(width: 6, height: 6).shadow(color: ink.opacity(0.8), radius: 2)
                Color.clear.frame(width: 12, height: 7).retroBevel(.raised, cornerRadius: 2, depth: 1, face: Retro.Ink.plasticMid)
                Color.clear.frame(width: 12, height: 7).retroBevel(.raised, cornerRadius: 2, depth: 1, face: Retro.Ink.plasticMid)
            }
            .padding(.top, 2)
        }
        .padding(6)
        .background(Color.clear.retroBevel(.raised, cornerRadius: AgentDenWindow.screenRadius, depth: 1.5, face: Retro.Ink.plasticDark))   // the notch's curve, like every screen
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.headline(announcement, project: session.project))
    }
}
