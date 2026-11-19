import AppKit
import SwiftUI

/// Self-check of the dashboard with real mouse events in an OFFSCREEN panel (nothing shows, the pointer never moves, no real
/// notch is involved). It runs headless, as its own build:
///   build/Scout.app/Contents/MacOS/Scout --automation --headless --run "scout://notch.selftest.dash?out=/tmp/dash.txt" & PID=$!
/// then wait for the file and `kill $PID`. It clicks panels, the header tabs and a button inside a panel, and calls Esc and Edit
/// Nook. The trackpad tap is counted, never played.
@MainActor
enum NotchDashSelfTest {
    /// Called from `HeadlessChecks.registerAll()`.
    static func register() {
        DebugCommands.register("notch.selftest.dash") { params in
            guard ScoutRuntime.isAutomation else { return }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("notch-dash-selftest.txt")
            Task { @MainActor in await SelfTestGate.shared.exclusive { await run(out: out) } }   // alone: never interleaved with another test (radio.selftest flips the look and uses the shared Radio store)
        }
    }

    /// A stand-in Calendar panel: a title, a Join button (marked as a control) and empty room below.
    private struct StubCalendarPanel: View {
        let onJoin: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("Today").font(.system(size: 12, weight: .semibold))
                Button("Join") { onJoin() }.buttonStyle(.notchPillCompact).nookControl()
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .notchContent()
        }
    }

    @MainActor private final class Rig {
        let size = CGSize(width: 1120, height: 700)
        let model: NotchScreenModel
        let navigator = NotchNavigator()
        let nook = NookStore(persist: false, layout: [.agents, .askAI, .calendar])
        let panel: NotchPanel
        var joins = 0
        var taps = 0

        init() {
            model = NotchScreenModel(geometry: .sample16, panelSize: size)
            model.isOpen = true
            navigator.isOpen = true
            nook.liveOverride = NookLive(playing: false, agents: 0)
            nook.tabIDs = { [] }
            panel = NotchPanel(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.navigatorOverride = navigator
            panel.isReleasedWhenClosed = false
            nook.viewOverride = { [unowned self] item in
                item == .panel(.calendar) ? AnyView(StubCalendarPanel(onJoin: { self.joins += 1 })) : nil
            }
            let root = NotchRootView(model: model, center: LiveActivityCenter(), navigator: navigator, nook: nook, styleOverride: .classic)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = CGRect(origin: .zero, size: size)
            panel.contentView = hosting
            panel.orderFrontRegardless()
        }

        func rect(_ name: String) -> CGRect? { model.panelRects[name] }

        func post(_ type: NSEvent.EventType, _ p: CGPoint) {
            let location = CGPoint(x: p.x, y: size.height - p.y)
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else { return }
            panel.sendEvent(event)
        }

        func click(_ p: CGPoint) {
            post(.leftMouseDown, p)
            post(.leftMouseUp, p)
        }

        func firstTextField() -> NSTextField? {
            func find(_ view: NSView) -> NSTextField? {
                if let field = view as? NSTextField { return field }
                for sub in view.subviews { if let found = find(sub) { return found } }
                return nil
            }
            return panel.contentView.flatMap(find)
        }

        func close() {
            panel.contentView = nil
            panel.orderOut(nil)
        }
    }

    private static func settle(_ seconds: Double = 0.45) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func run(out: URL) async {
        var lines: [String] = []
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failed += 1 }
            lines.append("dash selftest \(ok ? "ok  " : "FAIL") \(name)\(ok || detail.isEmpty ? "" : "  (\(detail))")")
        }

        // The header's tabs and the lock key come from the settings domain: this test needs the app's own (every tab, no lock), and puts back what was there.
        let borrowed = SelfTestSettings(clearing: ["notch.workspaces", "notch.tabsEdited", NotchPrefs.lockedTabKey])
        defer { borrowed.restore() }
        let savedPerform = NookHaptics.perform
        defer { NookHaptics.perform = savedPerform }
        LivePanelLookup.override = []
        defer { LivePanelLookup.override = nil }

        let rig = Rig()
        NookHaptics.perform = { rig.taps += 1 }
        await settle(0.9)
        defer { rig.close() }

        guard let calendar = rig.rect("panel.calendar"), rig.rect("panel.askAI") != nil, rig.rect("panel.agents") != nil else {
            check("the dashboard draws its panels", false, "panel rects: \(rig.model.panelRects.keys.sorted())")
            finish(lines, failed, out: out)
            return
        }
        check("the dashboard draws its panels (Agents, Ask AI, a pinned Calendar) and the header tabs", rig.rect("tab.nook") != nil && rig.rect("tab.calendar") != nil && rig.navigator.expanded == nil)
        let emptySpot = CGPoint(x: calendar.midX, y: calendar.maxY - 14)

        // 1. A click on a panel's background expands it into its full view.
        rig.taps = 0
        rig.click(emptySpot)
        await settle()
        check("click on the Calendar panel's background: the Calendar expands", rig.navigator.expanded == .calendar, "expanded = \(String(describing: rig.navigator.expanded))")
        check("  the island grew for the Calendar (240+ pt) and the dashboard tab is still there", rig.model.islandRect.height >= 240 && rig.rect("tab.nook") != nil,
              "island \(rig.model.islandRect), tab \(String(describing: rig.rect("tab.nook")))")
        check("  one trackpad tap for the expand", rig.taps == 1, "taps = \(rig.taps)")

        // 2. The dashboard tab goes back to the dashboard (the "‹ back" control is gone, owner 2026-11-15).
        if let back = rig.rect("tab.nook") { rig.click(CGPoint(x: back.midX, y: back.midY)) }
        await settle()
        check("click on the dashboard tab: the dashboard again, and a tap for it", rig.navigator.expanded == nil && rig.taps == 2, "expanded = \(String(describing: rig.navigator.expanded)), taps = \(rig.taps)")

        // 3. A button inside a panel does its own action, not an expand.
        let join = rig.nook.controlRects.first { calendar.contains(CGPoint(x: $0.midX, y: $0.midY)) }
        if let join { rig.click(CGPoint(x: join.midX, y: join.midY)) }
        await settle()
        check("click on a button inside a panel (Join): its action runs and nothing expands", join != nil && rig.joins == 1 && rig.navigator.expanded == nil,
              "join rect \(String(describing: join)), joins \(rig.joins), expanded \(String(describing: rig.navigator.expanded))")

        // 4. Esc: back to the dashboard first, then close the notch.
        rig.click(emptySpot)
        await settle()
        let expandedBeforeEsc = rig.navigator.expanded == .calendar
        let tapsBeforeEsc = rig.taps
        rig.panel.cancelOperation(nil)
        await settle(0.2)
        let afterFirst = (rig.navigator.expanded, rig.navigator.isOpen)
        rig.panel.cancelOperation(nil)
        await settle(0.2)
        check("Esc: first back to the dashboard (the notch stays open), the second Esc closes it",
              expandedBeforeEsc && afterFirst.0 == nil && afterFirst.1 && !rig.navigator.isOpen, "after first \(afterFirst), open \(rig.navigator.isOpen)")
        check("  the collapse by Esc taps too", rig.taps == tapsBeforeEsc + 1, "taps \(rig.taps) vs \(tapsBeforeEsc)")

        // 5. The notch opens on the dashboard, except a programmatic open that names a detail (the ring's Ask AI, a hotkey).
        rig.navigator.open(.askAI)
        let askExpanded = rig.navigator.expanded == .askAI
        rig.navigator.forceClose()
        rig.navigator.open()
        let reopened = rig.navigator.expanded == nil && rig.navigator.isOpen
        rig.navigator.forceClose()
        rig.navigator.preferredWorkspace = .agents
        rig.navigator.open()
        let preferred = rig.navigator.expanded == .agents
        rig.navigator.preferredWorkspace = nil
        rig.navigator.forceClose()
        rig.navigator.open(.calendar)
        rig.navigator.forceClose()
        rig.navigator.open()
        check("open(.askAI) opens expanded; a plain open() goes to the dashboard even after a detail was open; a preferred detail (Agents when asked) expands",
              askExpanded && reopened && preferred && rig.navigator.expanded == nil, "ask \(askExpanded), reopened \(reopened), preferred \(preferred), now \(String(describing: rig.navigator.expanded))")
        rig.navigator.isOpen = true
        await settle(0.3)

        // 6. Edit Nook: a click on a panel edits it, it does not expand.
        rig.nook.beginEditing(navigator: rig.navigator)
        await settle(0.5)
        rig.click(emptySpot)
        await settle(0.3)
        check("Edit Nook: clicking a panel does not expand it", rig.navigator.expanded == nil, "expanded = \(String(describing: rig.navigator.expanded))")
        rig.nook.endEditing(navigator: rig.navigator)
        rig.navigator.release("nook-edit")
        await settle(0.5)

        // 7. The header tabs (back at the owner's word, 2026-11-15): a click on a tab opens its full view, the dashboard tab
        // goes back. 
        rig.navigator.collapse()
        if !rig.navigator.isOpen { rig.navigator.open() }
        await settle()
        if let tab = rig.rect("tab.calendar") { rig.click(CGPoint(x: tab.midX, y: tab.midY)) }
        await settle()
        let openedByTab = rig.navigator.expanded == .calendar
        if let tab = rig.rect("tab.nook") { rig.click(CGPoint(x: tab.midX, y: tab.midY)) }
        await settle()
        check("a click on the Calendar tab opens the Calendar, and the dashboard tab goes back", openedByTab && rig.navigator.expanded == nil,
              "calendar tab \(String(describing: rig.rect("tab.calendar"))), opened \(openedByTab), expanded \(String(describing: rig.navigator.expanded))")

        // 7b. A tap on the Radio key opens the Radio tab on Favourites if any station is saved, else Latest if it has entries, else Search (the
        // owner, 2026-11-16). The shared store is in memory in a scripted run; it is emptied for this check and put back exactly as it was.
        do {
            let store = RadioStore.shared, model = RadioModel.shared
            let jazz = RadioFixtures.jazz, aurora = RadioFixtures.aurora
            let before = store.saved
            defer { store.restore(before) }
            var cleared = before
            cleared.latest = []
            cleared.favourites = []
            store.restore(cleared)

            // A key's rect once it has stopped moving: a rect read while the island is still resizing is where the key WAS, and a click there lands
            // on its neighbour (what a busy main thread did to this check).
            func steadyRect(_ name: String) async -> CGRect? {
                var last = rig.rect(name)
                for _ in 0..<30 {
                    await settle(0.1)
                    let now = rig.rect(name)
                    if let a = last, let b = now, abs(a.minX - b.minX) < 0.5, abs(a.minY - b.minY) < 0.5, abs(a.width - b.width) < 0.5 { return b }
                    last = now
                }
                return last
            }
            func waitFor(_ condition: () -> Bool) async -> Bool {
                for _ in 0..<60 {
                    if condition() { return true }
                    await settle(0.05)
                }
                return condition()
            }
            /// What the tab opened on, or why it did not open.
            func tapRadio() async -> (page: RadioModel.Page?, why: String) {
                if rig.navigator.expanded != nil, let home = await steadyRect("tab.nook") {   // the dashboard first (its key), so the Radio view opens afresh
                    rig.click(CGPoint(x: home.midX, y: home.midY))
                    _ = await waitFor { rig.navigator.expanded == nil }
                }
                await settle(0.5)   // the Radio view of the visit before has gone
                guard let radio = await steadyRect("tab.radio") else { return (nil, "no Radio key") }
                let leftOver = RadioModel.Page.list(UUID())
                model.page = leftOver   // left on something else by an earlier visit: only the opening of the tab can move it
                rig.click(CGPoint(x: radio.midX, y: radio.midY))
                guard await waitFor({ rig.navigator.expanded == .radio }) else { return (nil, "the key did not open Radio, the island shows \(String(describing: rig.navigator.expanded))") }
                _ = await waitFor { model.page != leftOver }
                await settle(0.15)
                return model.page == leftOver ? (nil, "Radio opened but chose no section") : (model.page, "")
            }
            let empty = await tapRadio()
            rig.navigator.collapse()
            store.recordPlayed(jazz)
            let recent = await tapRadio()
            rig.navigator.collapse()
            store.toggleFavourite(aurora)
            let saved = await tapRadio()
            rig.navigator.collapse()
            check("a tap on the Radio key opens Radio on Search when nothing is saved or played, on Latest when something was played, on Favourites when a station is saved",
                  empty.page == .search && recent.page == .latest && saved.page == .favourites,
                  "nothing \(String(describing: empty.page)) \(empty.why), played \(String(describing: recent.page)) \(recent.why), saved \(String(describing: saved.page)) \(saved.why), radio key \(String(describing: rig.rect("tab.radio")))")
        }

        // 8. After a switch the island may shrink away from a pointer that did not move: the notch stays open until the pointer
        // moves clearly farther away (the owner: picking the dashboard tab from a wider view closed the notch).
        var grace = NotchSwitchGrace()
        let t0 = Date()
        check("no switch: a pointer outside the island lets the notch close", !grace.keepsOpen(distance: 50, now: t0))
        grace.begin(now: t0)
        check("right after a switch the notch stays open while the island settles", grace.keepsOpen(distance: 150, now: t0.addingTimeInterval(0.2)))
        check("  once settled, a pointer that has not moved keeps it open", grace.keepsOpen(distance: 150, now: t0.addingTimeInterval(1)))
        check("  moving back toward the island keeps it open", grace.keepsOpen(distance: 60, now: t0.addingTimeInterval(1.5)))
        check("  moving clearly farther away (40 pt past where the switch left it) closes it", !grace.keepsOpen(distance: 200, now: t0.addingTimeInterval(2)))
        check("  and then the grace is over", !grace.keepsOpen(distance: 100, now: t0.addingTimeInterval(2.1)))
        grace.begin(now: t0)
        grace.end()
        check("  back inside the island ends the grace at once", !grace.keepsOpen(distance: 30, now: t0.addingTimeInterval(0.1)))

        // 9. A view that is leaving cannot wipe the next view's height request. Its onDisappear comes AFTER the next view's
        // onAppear: going from Agents to Ask AI the island grew and then suddenly shrank (the owner, 2026-11-15).
        let nav = NotchNavigator()
        nav.open(.agents)
        nav.requestHeight(300, resizeMax: 600, by: .agents)
        nav.workspace = .askAI
        nav.requestHeight(400, resizeMax: .greatestFiniteMagnitude, by: .askAI)
        nav.releaseHeight(by: .agents)
        check("Agents then Ask AI: Ask AI keeps its height after the Agents view has gone", nav.neededHeight(shown: .askAI) == 400 && nav.resizeMax(shown: .askAI) != nil,
              "needed \(nav.neededHeight(shown: .askAI))")
        nav.workspace = .nook
        nav.releaseHeight(by: .askAI)
        check("  back on the dashboard nothing asks for a height", nav.neededHeight(shown: .nook) == 0 && nav.resizeMax(shown: .nook) == nil)
        nav.workspace = .agents
        nav.requestHeight(400, resizeMax: nil, by: .askAI)
        check("  a request left by another view never sizes the one that shows", nav.neededHeight(shown: .agents) == 0)
        // The other way: Ask AI then Agents. Ask AI fired one more request on its way out, AFTER the Agents view had asked, then gave the height
        // up, and the den opened at the small default height.
        // A request from a view that is not on show is ignored.
        let back = NotchNavigator()
        back.open(.askAI)
        back.requestHeight(400, resizeMax: .greatestFiniteMagnitude, by: .askAI)
        back.workspace = .agents
        back.requestHeight(419, resizeMax: nil, by: .agents)
        back.requestHeight(380, resizeMax: .greatestFiniteMagnitude, by: .askAI)   // the late request on the way out
        back.releaseHeight(by: .askAI)
        check("Ask AI then Agents: the den keeps its full height (the leaving Ask AI's late request is ignored)",
              back.neededHeight(shown: .agents) == 419 && back.resizeMax(shown: .agents) == nil, "needed \(back.neededHeight(shown: .agents))")

        // The CPU & Memory panel lights up under the pointer like the panels that open a full view (a click opens Activity Monitor).
        // Full screen: only another app's window IN FRONT on that screen hides the notch, not a full-screen game left behind other windows.
        typealias FW = NotchManager.FullscreenWindow
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1080)
        let game = FW(layer: 0, pid: 500, rect: screen)
        let editor = FW(layer: 0, pid: 600, rect: CGRect(x: 100, y: 60, width: 1200, height: 800))
        let helper = FW(layer: 0, pid: 700, rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        let menuBar = FW(layer: 24, pid: 800, rect: CGRect(x: 0, y: 0, width: 1728, height: 24))
        check("full screen: a game in front hides the notch; the same game behind another app's window does not; Scout's own, helpers and bars are skipped",
              NotchManager.coversScreen([menuBar, helper, game, editor], bounds: screen, mine: 1)
                && !NotchManager.coversScreen([editor, game], bounds: screen, mine: 1)
                && !NotchManager.coversScreen([FW(layer: 0, pid: 1, rect: CGRect(x: 0, y: 0, width: 300, height: 300)), editor, game], bounds: screen, mine: 1)
                && NotchManager.coversScreen([FW(layer: 0, pid: 1, rect: CGRect(x: 0, y: 0, width: 300, height: 300)), game], bounds: screen, mine: 1)
                && !NotchManager.coversScreen([FW(layer: 0, pid: 500, rect: CGRect(x: 1728, y: 0, width: 1920, height: 1080))], bounds: screen, mine: 1)
                && !NotchManager.coversScreen([], bounds: screen, mine: 1))
        check("every panel lights up under the pointer (CPU & Memory, Pomodoro, Timer, Volume too)", WidgetKind.allCases.allSatisfy { NookItem.panel($0).highlightsOnHover }
              && NookItem.nowPlaying.highlightsOnHover && NookItem.panel(.pomodoro).highlightsOnHover)

        // 10. The Ask AI tab keeps ONE height whichever chat is open (the owner, 2026-11-16: clicking between chats made the island shorter for
        // some of them), and a height the person dragged on the grip is theirs, saved for this tab, also when it is shorter than the usual one.
        check("with a key Ask AI asks for the conversation height for every chat (empty ones too); without one it asks for nothing",
              AskAINotchContent.requestedHeight(hasKey: true) == AskAINotchContent.conversationHeight && AskAINotchContent.requestedHeight(hasKey: false) == nil)
        let tab = NotchNavigator()
        tab.workspace = .askAI
        tab.requestHeight(AskAINotchContent.requestedHeight(hasKey: true), resizeMax: .greatestFiniteMagnitude, by: .askAI)
        let before = tab.neededHeight(shown: .askAI)
        tab.requestHeight(AskAINotchContent.requestedHeight(hasKey: true), resizeMax: .greatestFiniteMagnitude, by: .askAI)   // clicking on another (empty or short) chat asks again
        check("  clicking between chats leaves the height as it was, and the tab stays resizable",
              before == AskAINotchContent.conversationHeight && tab.neededHeight(shown: .askAI) == before && tab.resizeMax(shown: .askAI) != nil)
        check("  the grip may make Ask AI shorter than its usual height (down to 240 pt), the other tabs only taller",
              tab.resizeFloor(shown: .askAI, automatic: 400) == NotchNavigator.chatFloor && tab.resizeFloor(shown: .askAI, automatic: 200) == 200
                && tab.resizeFloor(shown: .agents, automatic: 300) == 300 && tab.resizeFloor(shown: .calendar, automatic: 240) == 240)
        let savedBefore = UserDefaults.standard.object(forKey: "notch.draggedHeights")
        defer { UserDefaults.standard.set(savedBefore, forKey: "notch.draggedHeights") }
        tab.setDraggedHeight(520, for: .askAI, save: true)
        check("  a height dragged in the Ask AI tab is saved for it and comes back (a new notch reads it)", NotchNavigator().draggedHeight(for: .askAI) == 520 && NotchNavigator().draggedHeight(for: .agents) == nil)
        tab.setDraggedHeight(nil, for: .askAI, save: true)
        check("  a double-click on the grip gives the usual height back", NotchNavigator().draggedHeight(for: .askAI) == nil)

        finish(lines, failed, out: out)
    }

    private static func finish(_ lines: [String], _ failed: Int, out file: URL) {
        var out = lines
        out.append("dash selftest done: \(failed == 0 ? "all passed" : "\(failed) FAILED")")
        for line in out { print(line) }
        fflush(stdout)
        try? out.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}
