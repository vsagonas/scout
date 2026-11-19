import AppKit
import Carbon.HIToolbox
import SwiftUI

/// `scout://calendar.selftest.merged?out=<file>` (headless, its own build: `--automation --headless --run …`, then `kill $PID`).
/// The Calendar tab and the To-dos tab are one tab now: no To-dos
/// key in the header, every way that named the To-dos (a panel, a hotkey, a saved lock, a saved tab list) lands on the Calendar view, the island
/// is tall enough, the month, the agenda and the to-dos sit inside it without overlapping (wide and narrow, both looks, both colour presets, two
/// sizes), and real clicks tick a to-do and switch to "All open". Synthetic data only (the scripted run's sample to-dos and events).
@MainActor
enum CalendarMergedSelfTest {
    static func register() {
        DebugCommands.register("calendar.selftest.merged") { params in
            guard ScoutRuntime.isAutomation else { return }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("calendar-merged-selftest.txt")
            Task { @MainActor in await run(out: out) }
        }
    }

    private static func settle(_ seconds: Double = 0.6) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static let touched = [Retro.styleKey, Look.scaleKey, Look.presetKey, "notch.workspaces", "notch.tabsEdited", "notch.tabOrder2",
                                  NotchPrefs.lockedTabKey, ShortcutEntry.workspace(.todo).id]

    static func run(out: URL) async {
        var lines: [String] = []
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failed += 1 }
            lines.append("calendar selftest \(ok ? "ok  " : "FAIL") \(name)\(ok || detail.isEmpty ? "" : "  (\(detail))")")
        }
        let defaults = UserDefaults.standard
        var kept: [String: Any] = [:]
        for key in touched { if let v = defaults.object(forKey: key) { kept[key] = v } }
        defer { for key in touched { if let v = kept[key] { defaults.set(v, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        for key in touched { defaults.removeObject(forKey: key) }

        // 1. No To-dos tab in the header, however the tab list was saved.
        check("with nothing saved the header's tabs are the default ones, with the Calendar and without the To-dos",
              NotchPrefs.tabs.contains(.calendar) && !NotchPrefs.tabs.contains(.todo) && !NotchPrefs.allTabsInOrder.contains(.todo) && !NotchPrefs.defaultTabOrder.contains(.todo),
              "\(NotchPrefs.tabs.map(\.rawValue))")
        check("  the To-dos are among the kinds that never get a tab", NotchPrefs.notTabs.contains(.todo))
        let older = NotchPrefs.parseTabs("nook,agents,calendar,todo,notes", edited: false)
        check("a tab list saved with the To-dos loses them (an older list also gets the newer tabs, not the To-dos)",
              !older.contains(.todo) && older.contains(.calendar) && older.contains(.notes) && older.contains(.mirror), "\(older.map(\.rawValue))")
        let edited = NotchPrefs.parseTabs("nook,todo,notes", edited: true)
        check("  a list that kept the To-dos but not the Calendar gets the Calendar in the To-dos' place",
              edited == [.nook, .calendar, .notes], "\(edited.map(\.rawValue))")
        let onlyTodos = NotchPrefs.parseTabs("todo", edited: true)
        check("  a list of only the To-dos becomes the Calendar alone", onlyTodos == [.calendar], "\(onlyTodos.map(\.rawValue))")

        // 2. Everything that names the To-dos opens the Calendar view.
        check("the island shows the Calendar for the To-dos (resolve)", NotchPrefs.resolve(.todo) == .calendar && NotchPrefs.merged(.todo) == .calendar && NotchPrefs.merged(.notes) == .notes)
        let nav = NotchNavigator()
        nav.open(.todo)
        check("open(.todo) (a hotkey, the ring, a panel) opens the Calendar", nav.isOpen && nav.expanded == .calendar && nav.workspace == .calendar, "\(nav.workspace)")
        nav.forceClose()
        nav.expand(.todo)
        check("  expand(.todo) too", nav.expanded == .calendar)
        nav.workspace = .nook
        nav.workspace = .todo
        check("  setting the workspace to .todo directly lands on the Calendar", nav.workspace == .calendar)
        nav.forceClose()
        nav.toggle(.todo)
        let opened = nav.isOpen && nav.expanded == .calendar
        nav.toggle(.todo)
        check("  the To-dos hotkey toggles the Calendar: first press opens it, the second closes it", opened && !nav.isOpen, "opened \(opened), open now \(nav.isOpen)")
        let preferring = NotchNavigator()
        preferring.preferredWorkspace = .todo
        preferring.open()
        check("  a preferred To-dos view opens the Calendar", preferring.expanded == .calendar)
        check("the To-dos panel (dashboard) opens the Calendar: WidgetKind.todo.detail, a click on the panel, and the live To-dos panel",
              WidgetKind.todo.detail == .calendar && WidgetKind.calendar.detail == .calendar && WidgetKind.today.detail == .calendar
                && LiveTodosPanel.live().expandTo == .calendar)
        let clicker = NotchNavigator()
        clicker.isOpen = true
        NookStore(persist: false, layout: [.todo]).expand(.panel(.todo), navigator: clicker)
        check("  expanding the To-dos panel shows the Calendar", clicker.expanded == .calendar, "\(String(describing: clicker.expanded))")

        // 3. A lock saved on the To-dos keeps the Calendar; the To-dos cannot be locked as a tab of their own.
        defaults.set("todo", forKey: NotchPrefs.lockedTabKey)
        check("a lock saved on the To-dos keeps the Calendar as the opening tab", NotchPrefs.lockedTab == .calendar && NotchPrefs.openingWorkspace == .calendar)
        let locked = NotchNavigator()
        locked.open()
        check("  a plain opening of the notch shows the Calendar", locked.expanded == .calendar, "\(String(describing: locked.expanded))")
        check("  the lock key cannot keep the To-dos (they are not a tab), the Calendar yes", !NotchPrefs.canLock(.todo) && NotchPrefs.canLock(.calendar))
        NotchPrefs.toggleLock(on: .todo)
        check("  the lock key on the merged tab lets go of the saved To-dos lock", NotchPrefs.lockedTab == nil, "\(String(describing: NotchPrefs.lockedTab))")
        defaults.removeObject(forKey: NotchPrefs.lockedTabKey)

        // 4. The Settings shortcut for the To-dos: not listed until one is saved, then it still works and opens the Calendar.
        check("the Settings › Keyboard Shortcuts list has no To-dos row of its own when none was saved, and has the Calendar's",
              !ShortcutEntry.workspaceEntries.contains { $0.id == ShortcutEntry.workspace(.todo).id } && ShortcutEntry.workspaceEntries.contains { $0.id == ShortcutEntry.workspace(.calendar).id })
        defaults.set(KeyCombo(keyCode: UInt32(kVK_ANSI_T), modifiers: [.control, .option]).stringValue, forKey: ShortcutEntry.workspace(.todo).id)
        check("  a shortcut saved for the To-dos stays listed and registered (it opens the Calendar)",
              ShortcutEntry.workspaceEntries.contains { $0.id == ShortcutEntry.workspace(.todo).id } && ShortcutEntry.workspace(.todo).title.contains("Calendar"))
        defaults.removeObject(forKey: ShortcutEntry.workspace(.todo).id)

        // 5. Heights: the Calendar and the To-dos ask for the same, and it is enough for the to-do list and the stacked layout.
        check("the merged view's minimum open height is the same for the Calendar and the To-dos: the month with the header",
              NotchPrefs.minimumOpenHeight(for: .todo) == NotchPrefs.minimumOpenHeight(for: .calendar)
              && NotchPrefs.minimumOpenHeight(for: .calendar) == CalendarWorkspaceView.monthHeight + CalendarWorkspaceView.islandChrome,
              "\(NotchPrefs.minimumOpenHeight(for: .calendar))")
        // As tall as what the day shows, no taller than the old 400 pt.
        let quiet = CalendarWorkspaceView.islandHeight(wide: true, calendarReady: true, events: 1, tasks: 1)
        let busy = CalendarWorkspaceView.islandHeight(wide: true, calendarReady: true, events: 2, tasks: 4)
        let crowded = CalendarWorkspaceView.islandHeight(wide: true, calendarReady: true, events: 9, tasks: 12)
        let narrow = CalendarWorkspaceView.islandHeight(wide: false, calendarReady: true, events: 0, tasks: 0)
        check("the view asks for what it shows: the month for a quiet day, more for a busy one, the old 400 at most and when narrow",
              quiet == NotchPrefs.calendarHeight && busy > quiet && busy < NotchPrefs.calendarTallHeight && crowded == NotchPrefs.calendarTallHeight
              && narrow == NotchPrefs.calendarTallHeight, "quiet \(quiet) busy \(busy) crowded \(crowded) narrow \(narrow)")

        // 6. The list: the picked day's to-dos (open first), or every open one.
        let today = Calendar.current.startOfDay(for: Date())
        let later = Calendar.current.date(byAdding: .day, value: 3, to: today) ?? today
        let store = TodoStore(preview: [TodoTask(title: "Done today", done: true, day: today), TodoTask(title: "Open today", day: today),
                                        TodoTask(title: "Open later", day: later), TodoTask(title: "Open undated"), TodoTask(title: "Done undated", done: true)])
        var allOpen = false
        let column = CalendarTodosColumn(store: store, clock: ClockService.shared, day: today, showAllOpen: Binding(get: { allOpen }, set: { allOpen = $0 }))
        check("a day shows its own to-dos, the open one first", column.shown.map(\.title) == ["Open today", "Done today"], "\(column.shown.map(\.title))")
        allOpen = true
        let everyOpen = CalendarTodosColumn(store: store, clock: ClockService.shared, day: today, showAllOpen: Binding(get: { allOpen }, set: { allOpen = $0 }))
        check("  \"All open\" shows every open one, whatever its day, and none that is done",
              Set(everyOpen.shown.map(\.title)) == ["Open today", "Open later", "Open undated"], "\(everyOpen.shown.map(\.title))")
        store.add("New for the picked day", day: later)
        check("  a task added for a day lands on that day", store.tasks(on: later).map(\.title).contains("New for the picked day") && store.tasks(on: today).count == 2)

        // 7. The island: the real header and view, offscreen, at both widths, both looks, both colour presets and two sizes.
        let savedLook = [Retro.styleKey: defaults.object(forKey: Retro.styleKey), Look.scaleKey: defaults.object(forKey: Look.scaleKey), Look.presetKey: defaults.object(forKey: Look.presetKey)]
        defer { for (key, v) in savedLook { if let v { defaults.set(v, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        for eightBit in [true, false] {
            for preset in [Look.Preset.dark, .light] {
                for size in [Look.Size.normal, .xlarge] {
                    defaults.set(eightBit, forKey: Retro.styleKey)
                    defaults.set(preset.rawValue, forKey: Look.presetKey)
                    defaults.set(size.rawValue, forKey: Look.scaleKey)
                    for narrow in [false, true] {
                        let label = "\(eightBit ? "8-bit" : "minimal"), \(preset.title.lowercased()), \(size.title.lowercased()), \(narrow ? "narrow (680)" : "wide")"
                        let rig = LookSelfTest.Rig(widthCap: narrow ? 680 : nil)
                        rig.navigator.open(.todo)
                        await settle(0.8)
                        let island = rig.island
                        let r = { (name: String) in rig.rect(name) ?? .zero }
                        let month = r("cal.month"), agenda = r("cal.agenda"), todos = r("cal.todos"), add = r("cal.todos.add"), chip = r("cal.todos.all")
                        let row = r("cal.todos.row.0"), list = r("cal.todos.list")
                        let inside = { (rect: CGRect) in rect.width > 0 && rect.minX >= island.minX - 0.5 && rect.maxX <= island.maxX + 0.5 && rect.minY >= island.minY - 0.5 && rect.maxY <= island.maxY + 0.5 }
                        let found = [month, agenda, todos, add, chip, row, list].allSatisfy { $0.width > 0 }
                        let arranged = narrow ? (todos.minY >= month.maxY - 0.5 && todos.minY >= agenda.maxY - 0.5 && agenda.minX >= month.maxX - 0.5)
                                              : (agenda.minX >= month.maxX - 0.5 && todos.minX >= agenda.maxX - 0.5 && abs(todos.minY - agenda.minY) < 3)
                        check("\(label): the Calendar view opened by the To-dos draws the month, the agenda and the to-dos \(narrow ? "(the to-dos under the month)" : "side by side"), none cut off or overlapping",
                              rig.navigator.expanded == .calendar && found && [month, agenda, todos, add, chip, row, list].allSatisfy(inside) && arranged && inside(add.union(chip)) && todos.insetBy(dx: -1.5, dy: -1.5).contains(add) && todos.insetBy(dx: -1.5, dy: -1.5).contains(chip),
                              "island \(island), month \(month), agenda \(agenda), todos \(todos), add \(add), row \(row)")
                        check("  the island is as tall as the merged view needs (\(Int(NotchPrefs.calendarHeight)) pt times the size) and the first to-do sits inside the list",
                              island.height >= NotchPrefs.calendarHeight * size.factor - 1 && list.insetBy(dx: -1.5, dy: -1.5).contains(row), "island height \(island.height), list \(list), row \(row)")
                        check("  no To-dos key in the header, the Calendar key there and lit", rig.rect("tab.todo") == nil && rig.rect("tab.calendar") != nil)
                        rig.close()
                    }
                }
            }
        }

        // 8. Real clicks in the wide island: tick a to-do, switch to "All open" and back.
        defaults.set(true, forKey: Retro.styleKey)
        defaults.set(Look.Preset.dark.rawValue, forKey: Look.presetKey)
        defaults.set(Look.Size.normal.rawValue, forKey: Look.scaleKey)
        let rig = LookSelfTest.Rig()
        rig.navigator.open(.todo)
        await settle(0.9)
        let shared = TodoStore.shared
        let firstOpen = shared.tasks(on: today).first { !$0.done }
        if let tick = rig.rect("cal.todos.tick.0"), let firstOpen {
            rig.click(CGPoint(x: tick.midX, y: tick.midY))
            await settle(0.4)
            check("a real click on a to-do's box in the merged view ticks it off", shared.tasks.first { $0.id == firstOpen.id }?.done == true,
                  "\(firstOpen.title): done \(String(describing: shared.tasks.first { $0.id == firstOpen.id }?.done))")
            shared.toggle(firstOpen.id)
            await settle(0.3)
            check("  and it ticks back (the box is a toggle)", shared.tasks.first { $0.id == firstOpen.id }?.done == false)
        } else {
            check("a real click on a to-do's box in the merged view ticks it off", false, "tick \(String(describing: rig.rect("cal.todos.tick.0"))), first open \(String(describing: firstOpen?.title)); rects \(rig.model.panelRects.keys.sorted())")
        }
        func rows() -> Int { rig.model.panelRects.keys.filter { $0.hasPrefix("cal.todos.row.") }.count }
        let dayRows = rows()
        if let chip = rig.rect("cal.todos.all") {
            rig.click(CGPoint(x: chip.midX, y: chip.midY))
            await settle(0.5)
            let allRows = rows()
            rig.click(CGPoint(x: chip.midX, y: chip.midY))
            await settle(0.5)
            check("a real click on \"All open\" lists every open to-do (\(shared.openTasks.count)), and a second click goes back to the day's (\(shared.tasks(on: today).count))",
                  dayRows == shared.tasks(on: today).count && allRows == shared.openTasks.count && rows() == dayRows, "day \(dayRows), all \(allRows), back \(rows())")
        } else {
            check("a real click on \"All open\" lists every open to-do", false, "no chip rect")
        }
        rig.close()

        var out2 = lines
        out2.append("calendar selftest done: \(failed == 0 ? "all passed" : "\(failed) FAILED")")
        for line in out2 { print(line) }
        fflush(stdout)
        try? out2.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
    }
}
