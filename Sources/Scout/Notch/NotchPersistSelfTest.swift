import Foundation

/// `scout://notch.selftest.persist?out=<file>` (headless runs): everything the user does to the dashboard is saved and comes
/// back after a restart, and a layout saved by an earlier build moves to the live dashboard once, without losing anything. Uses
/// the scripted run's own settings (never the owner's); every "relaunch" is a new store or navigator reading them back.
@MainActor
enum NotchPersistSelfTest {
    static func register() {
        DebugCommands.register("notch.selftest.persist") { params in
            guard ScoutRuntime.isAutomation else { return }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("notch-persist-selftest.txt")
            let lines = run()
            try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        }
    }

    static func run() -> [String] {
        var lines: [String] = []
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failed += 1 }
            lines.append("persist selftest \(ok ? "ok  " : "FAIL") \(name)\(ok || detail.isEmpty ? "" : "  (\(detail))")")
        }
        let defaults = UserDefaults.standard
        let keys = [NookStore.layoutKey, NookStore.migratedKey, NookStore.backupKey, NookStore.pulseTodayKey, "notch.draggedHeights", "notch.haptics",
                    "notch.workspaces", "notch.tabOrder2", "notch.tabsEdited", NotchPrefs.lockedTabKey]
        func reset() { keys.forEach { defaults.removeObject(forKey: $0) } }
        func saved() -> [String]? { defaults.stringArray(forKey: NookStore.layoutKey) }
        defer { reset() }

        // 1. A layout saved by an earlier build moves to the live dashboard once; the old list is kept.
        reset()
        let old = ["agents", "media", "pulse", "timer", "todo"]
        defaults.set(old, forKey: NookStore.layoutKey)
        let first = NookStore()
        check("an earlier build's saved layout moves to the live dashboard (Agents + Ask AI) once", first.layout == WidgetKind.defaultLayout, "\(first.layout)")
        check("  the old list is kept aside, the move is written down and the new layout is saved",
              defaults.stringArray(forKey: NookStore.backupKey) == old && defaults.bool(forKey: NookStore.migratedKey) && saved() == WidgetKind.defaultLayout.map(\.rawValue))

        // 2. What the user does afterwards is saved and comes back as it was (panel order, panels added with "+", panels taken off).
        first.add(.calendar)
        first.add(.weather)
        first.add(.timer)
        first.place(.weather, at: 0)
        first.remove(.askAI)
        let expected = first.layout
        let relaunched = NookStore()
        check("pinned panels, their order and the ones taken off survive a relaunch (no second migration)", relaunched.layout == expected && expected.first == .weather && !expected.contains(.askAI),
              "expected \(expected), got \(relaunched.layout)")
        relaunched.restoreDefaults()
        check("Edit Nook's \"restore\" is saved too", NookStore().layout == WidgetKind.defaultLayout)

        // 3. A dashboard the user emptied stays empty; a list that names nothing this build knows is not an empty dashboard.
        let emptied = NookStore()
        for kind in emptied.layout { emptied.remove(kind) }
        check("a dashboard emptied by hand stays empty after a relaunch", NookStore().layout.isEmpty)
        defaults.set(["bogus", "gone"], forKey: NookStore.layoutKey)
        check("a damaged saved list falls back to the default instead of an empty dashboard", NookStore().layout == WidgetKind.defaultLayout)
        defaults.set(["calendar", "bogus", "calendar", "agents"], forKey: NookStore.layoutKey)
        check("unknown and repeated entries are skipped, the rest keeps its order", NookStore().layout == [.calendar, .agents])

        // 4. A fresh install: nothing saved, the default shows; the first change is saved and is never migrated away.
        reset()
        let fresh = NookStore()
        fresh.add(.timer)
        check("a fresh install starts on the default, and its first change comes back", fresh.layout == WidgetKind.defaultLayout + [.timer] && NookStore().layout == WidgetKind.defaultLayout + [.timer])

        // 5. Dragged heights (the resize grip) and the haptics setting are kept.
        let nav = NotchNavigator()
        nav.setDraggedHeight(333, for: .agents, save: true)
        check("a height dragged on the grip comes back after a relaunch", NotchNavigator().draggedHeight(for: .agents) == 333)
        nav.setDraggedHeight(nil, for: .agents, save: true)
        check("  and double-clicking the grip (back to the usual height) is kept too", NotchNavigator().draggedHeight(for: .agents) == nil)
        Pref.set(false, "notch.haptics")
        check("the haptics switch is read back", !NotchPrefs.haptics)

        // 6. The notch always opens on the dashboard: no detail is remembered (and nothing is saved for it).
        let visit = NotchNavigator()
        visit.open(.calendar)
        visit.forceClose()
        visit.open()
        check("the notch reopens on the dashboard, not on the detail that was open", visit.expanded == nil && visit.isOpen)

        // 7. Once: the CPU and memory graph and Today join a saved dashboard; a saved tab list takes the owner's order.
        defaults.set(["agents", "askAI"], forKey: NookStore.layoutKey)
        defaults.set(true, forKey: NookStore.migratedKey)
        defaults.removeObject(forKey: NookStore.pulseTodayKey)
        let joined = NookStore()
        check("the CPU and memory graph and Today join a saved dashboard once", joined.layout == [.agents, .askAI, .pulse, .today], "\(joined.layout)")
        joined.remove(.today)
        check("  taking Today off afterwards is kept after a relaunch", NookStore().layout == [.agents, .askAI, .pulse], "\(NookStore().layout)")
        defaults.set("nook,askAI,tray,calendar,clipboard,agents,prompter,music", forKey: "notch.workspaces")
        defaults.removeObject(forKey: "notch.tabOrder2")
        defaults.removeObject(forKey: "notch.tabsEdited")
        NotchPrefs.applyDefaultTabOrderOnce()
        let frontTabs: [WorkspaceKind] = [.nook, .agents, .askAI, .calendar, .clipboard]
        check("a saved tab list takes the default order once: dashboard, agents, Ask AI, calendar, clipboard, then the rest",
              Array(NotchPrefs.tabs.prefix(5)) == frontTabs && NotchPrefs.tabs.contains(.music), "\(NotchPrefs.tabs)")
        defaults.removeObject(forKey: "notch.workspaces")
        check("  with nothing saved the tabs start in that order too", Array(NotchPrefs.tabs.prefix(5)) == frontTabs, "\(NotchPrefs.tabs)")

        // 8. The lock key (the owner, 2026-11-16): the notch opens on the locked tab instead of the dashboard, however it is opened.
        check("with no lock the notch opens on the dashboard", NotchPrefs.lockedTab == nil && NotchPrefs.openingWorkspace == .nook)
        NotchPrefs.toggleLock(on: .calendar)
        check("the lock keeps the Calendar as the opening tab and it is saved", NotchPrefs.lockedTab == .calendar && defaults.string(forKey: NotchPrefs.lockedTabKey) == "calendar")
        let held = NotchNavigator()
        held.open()
        check("a plain opening (the pointer, a click, a swipe, the menu) shows the locked tab, not the dashboard", held.isOpen && held.expanded == .calendar, "\(String(describing: held.expanded))")
        held.open(.agents)
        check("  an opening that names a tab (a hotkey, a panel, the menu's Open) still shows that tab", held.expanded == .agents)
        held.forceClose()
        held.open()
        check("  closed and opened again after another tab was on show: back on the locked tab", held.expanded == .calendar)
        held.workspace = .clipboard
        held.open()
        check("  an already open notch keeps what it shows when it is asked to open again", held.expanded == .clipboard)
        check("  a relaunch (a new navigator) opens on the locked tab too", { let n = NotchNavigator(); n.open(); return n.expanded == .calendar }())
        held.collapse()
        check("  the dashboard tab and Esc still go to the dashboard", held.expanded == nil && held.isOpen)
        NotchPrefs.toggleLock(on: .clipboard)
        check("a second lock moves the first (one tab is kept at a time)", NotchPrefs.lockedTab == .clipboard)
        NotchPrefs.toggleLock(on: .clipboard)
        let freed = NotchNavigator()
        freed.open()
        check("the lock key on the locked tab lets go: the notch opens on the dashboard again", NotchPrefs.lockedTab == nil && freed.expanded == nil && defaults.string(forKey: NotchPrefs.lockedTabKey) == nil)
        NotchPrefs.toggleLock(on: .mirror)
        check("the Mirror cannot be kept (it starts the camera), nothing is saved", NotchPrefs.lockedTab == nil && !NotchPrefs.canLock(.mirror) && NotchPrefs.canLock(.calendar))
        defaults.set("mirror", forKey: NotchPrefs.lockedTabKey)
        check("  a saved lock naming the Mirror is ignored", NotchPrefs.openingWorkspace == .nook)
        defaults.set("not-a-tab", forKey: NotchPrefs.lockedTabKey)
        check("  so is one naming nothing this build knows", NotchPrefs.openingWorkspace == .nook)
        NotchPrefs.toggleLock(on: .nook)
        let dash = NotchNavigator()
        dash.open()
        check("the dashboard can be the locked one too (it opens there, and a second press lets go)",
              NotchPrefs.lockedTab == .nook && dash.expanded == nil && { NotchPrefs.toggleLock(on: .nook); return NotchPrefs.lockedTab == nil }())
        for kind in WorkspaceKind.available where NotchPrefs.canLock(kind) {
            NotchPrefs.toggleLock(on: kind)
            let n = NotchNavigator()
            n.open()
            let ok = n.workspace == kind
            NotchPrefs.toggleLock(on: kind)
            if !ok { check("every tab the lock can keep opens as the opening one (\(kind.rawValue))", false, "\(n.workspace)") }
        }
        check("every tab the lock can keep opens as the opening one (\(WorkspaceKind.available.filter(NotchPrefs.canLock).count) tabs)", NotchPrefs.lockedTab == nil)

        lines.append("persist selftest done: \(failed == 0 ? "all passed" : "\(failed) FAILED")")
        return lines
    }
}
