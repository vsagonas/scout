import AppKit
import Combine
import SwiftUI

/// `scout://auto.selftest?out=<file>` (headless runs): the notch opening by itself for the agents, with synthetic agents only. It runs
/// as its own build, offscreen:
///   build/Scout.app/Contents/MacOS/Scout --automation --headless --run "scout://auto.selftest?out=<file>" & PID=$!
/// then wait for the file and `kill $PID`. A fake clock and a pretend pointer drive the presenter; the notch is the real one (real
/// navigator, real `NotchRootView`, real Agents view) in an offscreen panel, and hooks arrive through the store's real `receive`.
/// Nothing reaches the screen, the pointer never moves and nothing is written to the owner's settings.
@MainActor
enum AgentsAutoOpenSelfTest {
    static func register() {
        DebugCommands.register("auto.selftest") { params in
            guard ScoutRuntime.isAutomation else { return }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("auto-selftest.txt")
            Task { @MainActor in await run(out: out) }
        }
    }

    // MARK: Synthetic data

    private static func request(_ id: String) -> AgentPending {
        AgentPending(sessionID: id, kind: .permission, tool: "Bash", summary: "terraform apply", detail: "terraform apply", questions: [], rawToolInput: nil, agent: .claude)
    }

    // MARK: The offscreen notch

    @MainActor private final class Rig {
        let size = CGSize(width: 1120, height: 700)
        let model: NotchScreenModel
        let navigator = NotchNavigator()
        let nook: NookStore
        let panel: NotchPanel
        private var bag = Set<AnyCancellable>()

        init(open: Bool) {
            model = NotchScreenModel(geometry: .sample16, panelSize: size)
            model.isOpen = open
            navigator.isOpen = open
            navigator.$isOpen.sink { [model] isOpen in model.isOpen = isOpen }.store(in: &bag)
            nook = NookStore(persist: false, layout: [.agents])
            nook.liveOverride = NookLive(playing: false, agents: 3)
            nook.tabIDs = { [] }
            panel = NotchPanel(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.navigatorOverride = navigator
            panel.isReleasedWhenClosed = false
            let root = NotchRootView(model: model, center: LiveActivityCenter(), navigator: navigator, nook: nook, styleOverride: .classic)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = CGRect(origin: .zero, size: size)
            panel.contentView = hosting
            panel.orderFrontRegardless()
        }

        func close() {
            panel.contentView = nil
            panel.orderOut(nil)
        }
    }

    private static func settle(_ seconds: Double = 0.45) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// The fake clock and the pretend pointer of the automatic opening.
    private final class World {
        var now = Date()
        var inside = false
        var typing = false
        var enabled = true
        var hidden = false

        func env(scripted: Bool = false) -> AgentsAutoOpen.Env {
            AgentsAutoOpen.Env(now: { [unowned self] in now }, enabled: { [unowned self] in enabled }, isScripted: scripted,
                               hidden: { [unowned self] in hidden }, pointerInside: { [unowned self] in inside }, typing: { [unowned self] in typing })
        }
    }

    // MARK: Run

    @MainActor private final class Checker {
        var lines: [String] = []
        var failed = 0

        func callAsFunction(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failed += 1 }
            lines.append("auto selftest \(ok ? "ok  " : "FAIL") \(name)\(ok || detail.isEmpty ? "" : "  (\(detail))")")
        }
    }

    static func run(out: URL) async {
        let check = Checker()
        let savedTap = NookHaptics.perform
        NookHaptics.perform = {}
        defer { NookHaptics.perform = savedTap }
        LivePanelLookup.override = []
        defer { LivePanelLookup.override = nil }

        settingsChecks(check)
        await ruleChecks(check)
        await cardChecks(check)

        check.lines.append("auto selftest done: \(check.failed == 0 ? "all passed" : "\(check.failed) FAILED")")
        for line in check.lines { print(line) }
        fflush(stdout)
        try? check.lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
    }

    // MARK: 1. The settings switch and what the banner says

    private static func settingsChecks(_ check: Checker) {
        func suite(_ name: String) -> UserDefaults {
            let d = UserDefaults(suiteName: "com.vsag.Scout.autotest.\(name)") ?? .standard
            d.removePersistentDomain(forName: "com.vsag.Scout.autotest.\(name)")
            return d
        }
        let untouched = suite("a")
        AgentsAutoOpen.migrateOldSetting(untouched)
        check("the old switch was never touched: the new one stays unset, so it is ON", untouched.object(forKey: AgentsAutoOpen.enabledKey) == nil && untouched.bool(forKey: AgentsAutoOpen.migratedKey))
        let off = suite("b")
        off.set(false, forKey: AgentsStore.Key.preferWorkspace)
        AgentsAutoOpen.migrateOldSetting(off)
        check("  turned off by the person (a saved false): the new one is OFF", off.object(forKey: AgentsAutoOpen.enabledKey) as? Bool == false)
        let on = suite("c")
        on.set(true, forKey: AgentsStore.Key.preferWorkspace)
        AgentsAutoOpen.migrateOldSetting(on)
        check("  turned on: the new one is ON", on.object(forKey: AgentsAutoOpen.enabledKey) == nil)
        off.set(true, forKey: AgentsAutoOpen.enabledKey)
        AgentsAutoOpen.migrateOldSetting(off)
        check("  and it happens once: a later choice is not undone", off.object(forKey: AgentsAutoOpen.enabledKey) as? Bool == true)
        for name in ["a", "b", "c"] { UserDefaults(suiteName: "com.vsag.Scout.autotest.\(name)")?.removePersistentDomain(forName: "com.vsag.Scout.autotest.\(name)") }
        let kinds: [AgentAnnouncement.Kind] = [.needsYou, .finished(minutes: 12), .error]
        let heads = kinds.map { AgentBanner.headline(AgentAnnouncement(sessionID: "x", kind: $0, at: Date()), project: ["infra", "docs", "scout"][kinds.firstIndex(of: $0) ?? 0]) }
        check("the banner says who and what happened", heads == ["infra needs you", "docs finished after 12 min", "scout stopped with an error"], "\(heads)")
    }

    // MARK: 2. The rules, with the real notch and the real Agents view

    private static func ruleChecks(_ check: Checker) async {
        let world = World()
        let lastWorkspaceBefore = UserDefaults.standard.object(forKey: "notch.lastWorkspace") as? String
        let store = AgentsStore.shared
        let rig = Rig(open: false)
        defer { rig.close(); store.loadSessions([]); store.announcement = nil; store.clearFlashes() }
        let nav = rig.navigator
        let presenter = AgentsAutoOpen(agents: store, navigator: nav, env: world.env())
        store.loadSessions([])
        await settle(0.5)

        var list: [AgentSession] = []
        var heldFor: [String] = []
        func working(_ id: String, minutesIn: Double) -> AgentSession {
            var s = AgentSession(id: id, agent: .claude, cwd: "/Users/you/Dev/\(id)")
            s.title = "Synthetic task \(id)"
            s.state = .working
            s.turnStartedAt = world.now.addingTimeInterval(-minutesIn * 60)
            s.startedAt = s.turnStartedAt
            s.lastEventAt = world.now
            s.lastMessage = "Working on the \(id) task."
            return s
        }
        func put(_ s: AgentSession) {
            if let i = list.firstIndex(where: { $0.id == s.id }) { list[i] = s } else { list.append(s) }
        }
        func apply() {
            store.loadSessions(list, pending: heldFor.map(request))
            presenter.process()
        }
        func finish(_ id: String, after minutes: Double, failedStep: Bool = false) {
            guard var s = list.first(where: { $0.id == id }) else { return }
            s.state = .waiting
            s.note = "Finished: waiting for your next message"
            s.finishedAt = s.turnStartedAt.addingTimeInterval(minutes * 60)
            if failedStep { s.steps = [AgentStep(id: "x", tool: "Bash", summary: "swift build", at: world.now, done: true, failed: true)] }
            put(s)
            apply()
        }
        /// Time passes (and, while the notch is open, the real view gets a moment to show what it was asked for).
        func later(_ seconds: TimeInterval) async {
            if nav.isOpen { await settle(0.2) }
            world.now = world.now.addingTimeInterval(seconds)
            presenter.tick()
        }
        func reopenNothing() async {
            nav.forceClose()
            await settle(0.25)
        }

        // Baseline: three agents working. Nothing opens for what is already there.
        put(working("alpha", minutesIn: 5)); put(working("bravo", minutesIn: 1)); put(working("charlie", minutesIn: 12))
        apply()
        check("nothing opens for agents that are simply working", presenter.opened.isEmpty && !nav.isOpen)

        // The real view asks the SHARED navigator for its height, and that one only listens to the view on show: show Agents there too.
        let sharedWorkspaceBefore = NotchNavigator.shared.workspace
        NotchNavigator.shared.workspace = .agents
        defer { NotchNavigator.shared.workspace = sharedWorkspaceBefore }

        // (a) needs you: from closed, on the Agents view with that agent in detail, the details in the banner.
        heldFor = ["alpha"]
        apply()
        let first = presenter.opened.last
        check("an agent starts needing you: the closed notch opens on the Agents view",
              first?.kind == .needsYou && first?.sessionID == "alpha" && nav.isOpen && nav.expanded == .agents,
              "opened \(presenter.opened.count), expanded \(String(describing: nav.expanded))")
        await settle(0.5)
        check("  the Agents view shows THAT agent in detail (the real view took the request)", store.shownDetailID == "alpha" && store.focusID == nil && store.selectedID == "alpha",
              "shown \(String(describing: store.shownDetailID)), focus \(String(describing: store.focusID))")
        check("  it says what happened (a banner for that agent), and never sets a preferred workspace or touches the saved one",
              store.announcement?.kind == .needsYou && store.announcement?.sessionID == "alpha" && nav.preferredWorkspace == nil
              && UserDefaults.standard.object(forKey: "notch.lastWorkspace") as? String == lastWorkspaceBefore)
        check("  the view asked the island for room for the banner and the answer controls", (NotchNavigator.shared.workspaceHeight ?? 0) >= 320, "\(String(describing: NotchNavigator.shared.workspaceHeight))")
        await later(19)
        check("  it stays open for about 20 s", nav.isOpen && presenter.isShowing)
        await later(2)
        await settle(0.3)
        check("  and closes by itself after that (nobody was on it), the banner goes with it", !nav.isOpen && !presenter.isShowing && store.announcement == nil && store.shownDetailID == nil,
              "open \(nav.isOpen), banner \(String(describing: store.announcement)), shown \(String(describing: store.shownDetailID))")
        nav.open()
        check("  the next open is the dashboard as usual", nav.expanded == nil && nav.isOpen)
        await reopenNothing()
        let countAfterFirst = presenter.opened.count
        presenter.process()
        presenter.process()
        check("once per event: the same request, seen again, opens nothing", presenter.opened.count == countAfterFirst)

        // It was answered: no longer asking. Asking again later is a new event.
        heldFor = []
        apply()
        await later(1)
        // (b) A finish never opens the notch, however long the task was: the small done card says it
        let beforeFinish = presenter.opened.count
        finish("charlie", after: 12)
        await settle(0.3)
        check("an agent that worked 12 min finishes: the notch stays closed (no opening, no banner)",
              presenter.opened.count == beforeFinish && !nav.isOpen && store.announcement == nil, "opened \(presenter.opened.suffix(1)), open \(nav.isOpen)")
        await later(30)
        finish("bravo", after: 1)
        check("  a 1 min task that finishes: nothing opens either", presenter.opened.count == beforeFinish && !nav.isOpen)

        // The cooldown: one opening every 20 s. A finish inside it is not announced, a needs-you waits for its turn.
        await later(30)
        put(working("delta", minutesIn: 1)); put(working("echo", minutesIn: 14)); put(working("foxtrot", minutesIn: 1))
        apply()
        let t0 = world.now
        heldFor = ["delta"]
        apply()
        let n0 = presenter.opened.count
        await later(5)
        finish("echo", after: 14)
        heldFor = ["delta", "foxtrot"]
        apply()
        await settle(0.3)
        check("a long finish within 20 s of an opening is not announced, and a second needs-you waits",
              presenter.opened.count == n0 && store.shownDetailID == "delta", "opened \(presenter.opened.count - n0) more, shown \(String(describing: store.shownDetailID))")
        await later(14)
        check("  (19 s after the opening: still waiting)", presenter.opened.count == n0)
        await later(1.5)
        await settle(0.4)
        // The owner, 2026-11-16: an open notch is never switched or closed for an agent; the one that waited shows its card under it.
        check("  at 20 s, with the notch still open on the first agent, nothing switches to the one that waited, and the finish never opens",
              presenter.opened.count == n0 && !presenter.opened.contains { $0.sessionID == "echo" } && world.now.timeIntervalSince(t0) >= 20,
              "\(presenter.opened.suffix(2)), shown \(String(describing: store.shownDetailID))")
        await later(25)
        await reopenNothing()
        heldFor = []
        apply()

        // A needs-you wins over a finish in the same moment.
        await later(25)
        put(working("golf", minutesIn: 1)); put(working("hotel", minutesIn: 13))
        apply()
        let n1 = presenter.opened.count
        heldFor = ["golf"]
        if var h = list.first(where: { $0.id == "hotel" }) {
            h.state = .waiting; h.note = "Finished: waiting for your next message"; h.finishedAt = h.turnStartedAt.addingTimeInterval(13 * 60); put(h)
        }
        apply()
        check("a needs-you and a long finish at the same moment: only the needs-you opens, and the finish is not announced later",
              presenter.opened.count == n1 + 1 && presenter.opened.last?.sessionID == "golf")
        await later(25)
        check("  the needs-you closed itself and the finish did not come back", !nav.isOpen && presenter.opened.count == n1 + 1)
        heldFor = []
        apply()
        await later(1)
        heldFor = ["golf"]
        apply()
        check("  asking again after it was answered is a new event", presenter.opened.count == n1 + 2 && presenter.opened.last?.sessionID == "golf", "\(presenter.opened.count - n1)")
        await later(25)
        heldFor = []
        apply()
        await reopenNothing()

        // (c) an error.
        await later(25)
        put(working("india", minutesIn: 2))
        apply()
        let n2 = presenter.opened.count
        finish("india", after: 2, failedStep: true)
        await settle(0.3)
        check("an agent that stopped with an error: the notch stays closed too (the done card says it)",
              presenter.opened.count == n2 && !nav.isOpen && store.announcement == nil, "\(String(describing: presenter.opened.last))")
        await reopenNothing()

        // An open notch that is in use is never switched: the agent's row on the dashboard lights up instead.
        await later(25)
        put(working("juliet", minutesIn: 1)); put(working("kilo", minutesIn: 1))
        apply()
        nav.open()
        world.inside = true
        let n3 = presenter.opened.count
        heldFor = ["juliet"]
        apply()
        check("the notch is open and the pointer is on it: nothing switches, the agent's row is lit",
              presenter.opened.count == n3 && nav.expanded == nil && store.flashed.contains("juliet") && store.announcement == nil,
              "expanded \(String(describing: nav.expanded)), flashed \(store.flashed)")
        world.inside = false
        world.typing = true
        heldFor = ["juliet", "kilo"]
        apply()
        check("  a text field with the cursor counts as in use too", presenter.opened.count == n3 && nav.expanded == nil && store.flashed.contains("kilo"))
        world.typing = false
        store.clearFlashes()
        check("  the highlight can be taken away again", store.flashed.isEmpty)
        await reopenNothing()
        heldFor = []
        apply()

        // Hovered at the end of its time: it stays open and is handed over to the pointer.
        await later(25)
        put(working("lima", minutesIn: 1))
        apply()
        let n4 = presenter.opened.count
        heldFor = ["lima"]
        apply()
        await later(18)
        world.inside = true
        await later(1)
        await later(3)
        check("the pointer is on the island when the time is up: it stays open and is left to the pointer", presenter.opened.count == n4 + 1 && nav.isOpen && !presenter.isShowing)
        world.inside = false
        await reopenNothing()
        heldFor = []
        apply()

        // The person chose something else (another agent, from the dashboard's rows): hands off, the banner goes.
        await later(25)
        put(working("mike", minutesIn: 1)); put(working("nina", minutesIn: 1))
        apply()
        heldFor = ["mike"]
        apply()
        await settle(0.4)
        store.focusID = "nina"
        await settle(0.4)
        await later(2)
        check("the person picks another agent while it is open: the opening lets go, the notch stays, the banner is gone",
              nav.isOpen && !presenter.isShowing && store.announcement == nil && store.shownDetailID == "nina",
              "open \(nav.isOpen), showing \(presenter.isShowing), banner \(String(describing: store.announcement)), shown \(String(describing: store.shownDetailID))")
        await later(30)
        check("  and it is not closed under them later", nav.isOpen)
        await reopenNothing()
        heldFor = []
        apply()

        // The switch off, a hidden notch, the minutes setting, scripted runs.
        await later(25)
        put(working("oscar", minutesIn: 1)); put(working("papa", minutesIn: 20))
        apply()
        let n5 = presenter.opened.count
        world.enabled = false
        heldFor = ["oscar"]
        apply()
        finish("papa", after: 20)
        check("the switch off: nothing happens (no opening, no highlight)", presenter.opened.count == n5 && !nav.isOpen && store.flashed.isEmpty)
        world.enabled = true
        heldFor = []
        apply()
        await later(25)
        put(working("quebec", minutesIn: 1))
        apply()
        world.hidden = true
        heldFor = ["quebec"]
        apply()
        check("the notch hidden behind a full-screen app: nothing opens", presenter.opened.count == n5 && !nav.isOpen)
        world.hidden = false
        heldFor = []
        apply()
        await later(25)
        put(working("romeo", minutesIn: 4)); put(working("sierra", minutesIn: 6))
        apply()
        finish("romeo", after: 4)
        finish("sierra", after: 6)
        check("two more finishes (4 and 6 min): neither opens", !presenter.opened.contains { $0.sessionID == "romeo" || $0.sessionID == "sierra" } && !nav.isOpen)
        await reopenNothing()
        let scripted = AgentsAutoOpen(agents: store, navigator: nav, env: world.env(scripted: true))
        scripted.process()
        put(working("tango", minutesIn: 1))
        apply()
        scripted.process()
        heldFor = ["tango"]
        store.loadSessions(list, pending: heldFor.map(request))
        scripted.process()
        scripted.start()
        check("in scripted runs the presenter never opens anything", scripted.opened.isEmpty && !scripted.isShowing && !nav.isOpen && !store.defersCards)
        await reopenNothing()

        check("through all of it: no preferred workspace was set and the saved last workspace was never written",
              nav.preferredWorkspace == nil && UserDefaults.standard.object(forKey: "notch.lastWorkspace") as? String == lastWorkspaceBefore)
        nav.open()
        check("the next plain open is the dashboard", nav.expanded == nil)
        nav.forceClose()
    }

    // MARK: 3. The card under the notch

    /// A hook as the bridge would hand it to the store; nothing is sent anywhere.
    private static func permission(_ store: AgentsStore, session: String, command: String) {
        let json = "{\"session_id\":\"\(session)\",\"cwd\":\"/Users/you/Dev/\(session)\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"\(command)\"}}"
        guard let event = AgentEvent.parse(agent: .claude, data: Data(json.utf8)) else { return }
        store.receive(event, mode: "permission", responder: HookResponder { _ in })
    }

    private static func cardChecks(_ check: Checker) async {
        let world = World()
        let store = AgentsStore.shared
        let rig = Rig(open: false)
        let savedCenter = store.cardCenter
        let center = LiveActivityCenter()
        store.cardCenter = center
        let nav = rig.navigator
        let presenter = AgentsAutoOpen(agents: store, navigator: nav, env: world.env())
        defer {
            presenter.stop()
            rig.close()
            store.cardCenter = savedCenter
            store.loadSessions([])
            store.announcement = nil
            store.clearFlashes()
        }
        var seen = Set<String>()
        var bag = Set<AnyCancellable>()
        center.$cards.sink { cards in for card in cards { seen.insert(card.id) } }.store(in: &bag)
        func cardIDs() -> Set<String> { Set(center.cards.map(\.id)) }

        var carl = AgentSession(id: "carl", agent: .claude, cwd: "/Users/you/Dev/carl")
        carl.state = .working
        carl.turnStartedAt = world.now.addingTimeInterval(-120)
        carl.lastEventAt = world.now
        store.loadSessions([carl])
        presenter.start()   // the baseline, and from now on a new request's card waits one turn of the main queue
        check("the presenter is watching: a new request's card waits for it", store.defersCards)

        // The automatic opening shows the request: its card never appears.
        permission(store, session: "carl", command: "terraform apply")
        let held = store.pending.first?.id
        await settle(0.6)
        check("a request arrives (a hook): the notch opens on that agent and shows the answer controls",
              presenter.opened.last?.sessionID == "carl" && presenter.opened.last?.kind == .needsYou && nav.isOpen && nav.expanded == .agents && store.shownDetailID == "carl",
              "opened \(presenter.opened.count), shown \(String(describing: store.shownDetailID))")
        check("  and the card under the notch was never shown for it (the view has the controls)", held != nil && seen.isEmpty && center.cards.isEmpty, "seen \(seen)")
        permission(store, session: "carl", command: "swift build")
        await settle(0.4)
        check("  while the opening is on, a second request of that agent gets no card either", seen.isEmpty && center.cards.isEmpty && store.pending.count == 2, "seen \(seen), pending \(store.pending.count)")

        // The time is up and the notch closes: the requests still wait, so their cards come back.
        world.now = world.now.addingTimeInterval(21)
        presenter.tick()
        await settle(0.4)
        presenter.tick()
        let back = Set(store.pending.map { "agent.pending.\($0.id)" })
        check("the notch closed by itself and the requests still wait: both cards come back under it", !nav.isOpen && cardIDs() == back && back.count == 2, "cards \(cardIDs()), pending \(back)")

        // Answering takes the card away.
        if let id = store.pending.first?.id { store.decide(id, .allow) }
        check("  answering one removes its card", cardIDs().count == 1)
        if let id = store.pending.first?.id { store.decide(id, .deny) }
        check("  and the other", cardIDs().isEmpty && store.pending.isEmpty)

        // The person looks at that agent themselves (the auto-opening switched off): the cards step aside while the view shows it.
        world.enabled = false
        seen.removeAll()
        permission(store, session: "carl", command: "make")
        await settle(0.3)
        check("with the switch off a request just gets its card, as before", presenter.opened.count == 1 && cardIDs().count == 1 && !nav.isOpen, "cards \(cardIDs())")
        store.focusID = "carl"
        nav.open(.agents)
        await settle(0.5)
        presenter.tick()
        check("the person opens that agent's detail: its card steps aside (the same controls are in the view)", store.shownDetailID == "carl" && cardIDs().isEmpty, "shown \(String(describing: store.shownDetailID)), cards \(cardIDs())")
        nav.forceClose()
        await settle(0.4)
        presenter.tick()
        check("  and returns when the notch closes", cardIDs().count == 1, "cards \(cardIDs())")
        if let id = store.pending.first?.id { store.decide(id, .allow) }
        check("  answered: gone", cardIDs().isEmpty)
        _ = bag
    }
}
