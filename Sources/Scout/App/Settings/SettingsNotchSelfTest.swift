import AppKit

/// `settings.selftest.notch?out=<file>`: the notch behind the Settings window, offscreen and headless (nothing shows, no real notch exists). The
/// real `SettingsWindowController` and `SettingsNotchHold` run on their own `NotchNavigator`, a stand-in panel at the notch's window level, and a
/// window the test keeps at x -20000. Run your own build:
///   build/Scout.app/Contents/MacOS/Scout --automation --headless --run "scout://settings.selftest.notch?out=/path/notch.txt" & PID=$!
@MainActor
enum SettingsNotchSelfTest {
    static func register() {
        DebugCommands.register("settings.selftest.notch") { params in
            guard ScoutRuntime.isAutomation else { return }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("settings-notch-selftest.txt")
            Task { @MainActor in await run(out: out) }
        }
    }

    /// Settings' stand-in content: counts the clicks that reach it.
    private final class ProbeView: NSView {
        var downs = 0
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { downs += 1 }
    }

    private static func settle(_ seconds: Double = 0.15) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func click(_ window: NSWindow, at p: CGPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else { return }
            window.sendEvent(event)
        }
    }

    static func run(out: URL) async {
        var lines: [String] = []
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failed += 1 }
            lines.append("settings notch selftest \(ok ? "ok  " : "FAIL") \(name)\(ok || detail.isEmpty ? "" : "  (\(detail))")")
        }

        let nav = NotchNavigator()
        let opening = OpenLog()
        let hold = SettingsNotchHold(navigator: nav, openNotch: { window in
            opening.windows.append(window)
            nav.open()
        })
        // The notch panel as the real ones are made: borderless, at the notch's level (offscreen).
        let panel = NotchPanel(contentRect: CGRect(x: -20000, y: -20000, width: 600, height: 300), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NotchPanel.notchLevel
        panel.navigatorOverride = nav
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        let probe = ProbeView(frame: CGRect(x: 0, y: 0, width: 900, height: 640))
        let controller = SettingsWindowController(notchHold: hold, front: { w in
            w.setFrameOrigin(CGPoint(x: -20000, y: -20000))
            w.orderFrontRegardless()
        }, content: { probe }, offscreen: true)
        let reason = SettingsNotchHold.reason

        check("before Settings shows: the notch is closed and nothing holds it", !nav.isOpen && nav.holdOpenReasons.isEmpty && controller.currentWindow == nil)

        // 1. Settings opens: the notch opens behind it and is held; Settings floats one step above the notch panels.
        controller.show()
        guard let window = controller.currentWindow else {
            check("the Settings window is made", false)
            finish(lines, failed, out: out)
            return
        }
        check("Settings shows: the notch opens (once) and is held open", nav.isOpen && nav.holdOpenReasons.contains(reason) && opening.windows.count == 1 && opening.windows.first === window,
              "open \(nav.isOpen), holds \(nav.holdOpenReasons), opened \(opening.windows.count)")
        check("  the Settings window is above the notch panel (level \(window.level.rawValue) over \(panel.level.rawValue))",
              window.level.rawValue > panel.level.rawValue && window.level == SettingsNotchHold.aboveNotch, "settings \(window.level.rawValue), panel \(panel.level.rawValue)")
        check("  its title is Settings and it is a real titled window", window.title == "Scout Settings" && window.styleMask.contains(.titled))
        check("  the shared colour panel (a colour well opens it) rises with it, so it shows above Settings", NSColorPanel.shared.level.rawValue > window.level.rawValue,
              "colour panel \(NSColorPanel.shared.level.rawValue), settings \(window.level.rawValue)")

        // 2. Whatever tries to close the notch (the pointer leaving it, a click in another app, a click in Settings) finds it held.
        click(window, at: CGPoint(x: 450, y: 320))
        await settle()
        nav.close()   // what the mouse-out timer and the click-away monitor call
        check("a click inside Settings reaches Settings and does not close the notch", probe.downs == 1 && nav.isOpen && nav.holdOpenReasons.contains(reason), "clicks \(probe.downs), open \(nav.isOpen)")
        nav.hold("radio.search")
        nav.release("radio.search")
        nav.close()
        check("  a click away or the pointer leaving (close()) leaves it open while Settings shows, also after another hold came and went", nav.isOpen)

        // 3. A notch panel taking the keyboard (typing in the notch) changes nothing.
        hold.becameKey(panel)
        check("typing in the notch (its panel takes the keyboard): still held, Settings still above", nav.isOpen && nav.holdOpenReasons.contains(reason) && window.level == SettingsNotchHold.aboveNotch)

        // 4. A file chooser (a modal panel at a lower level) keeps the hold but Settings steps down so the chooser is seen; another window lets go.
        let chooser = NSOpenPanel()
        let tour = shown()
        defer { tour.orderOut(nil) }
        check("the keyboard kinds: Settings, a notch panel and nothing mean Settings; an open panel is a chooser; another window is other",
              SettingsNotchHold.keyboard(window, settings: window) == .settings && SettingsNotchHold.keyboard(panel, settings: window) == .settings
                && SettingsNotchHold.keyboard(nil, settings: window) == .settings && SettingsNotchHold.keyboard(chooser, settings: window) == .chooser
                && SettingsNotchHold.keyboard(tour, settings: window) == .other && SettingsNotchHold.keyboard(NSColorPanel.shared, settings: window) == .chooser)
        hold.becameKey(chooser)
        check("a file chooser takes the keyboard: the notch stays held, Settings steps down to its ordinary level so the chooser shows",
              nav.isOpen && nav.holdOpenReasons.contains(reason) && window.level == .normal, "level \(window.level.rawValue)")
        check("  and the colour panel goes back to its own level", NSColorPanel.shared.level == .floating, "colour panel \(NSColorPanel.shared.level.rawValue)")
        hold.becameKey(window)
        check("  Settings takes the keyboard again: above the notch again", window.level == SettingsNotchHold.aboveNotch && nav.isOpen)
        // The board's Test (Settings › Live Activities): the notch closes for the message and opens again behind Settings when it is over
        var boardPlaying = false
        hold.stepAside { boardPlaying }
        await settle(0.3)
        let closedForBoard = !nav.isOpen && !nav.holdOpenReasons.contains(reason)
        boardPlaying = true
        await settle(0.7)
        let stillClosed = !nav.isOpen
        boardPlaying = false
        await settle(0.7)
        check("the board's Test: the notch closes while the message plays and opens again behind Settings when it is over",
              closedForBoard && stillClosed && nav.isOpen && nav.holdOpenReasons.contains(reason), "closed \(closedForBoard), during \(stillClosed), after \(nav.isOpen)")
        hold.becameKey(tour)
        check("another Scout window (the tour) takes the keyboard: the hold goes, Settings steps down, the notch Settings opened closes",
              !nav.isOpen && nav.holdOpenReasons.isEmpty && window.level == .normal && !hold.isHolding, "open \(nav.isOpen), holds \(nav.holdOpenReasons)")
        hold.becameKey(window)
        check("  back in Settings: the notch opens again behind it and is held", nav.isOpen && nav.holdOpenReasons.contains(reason) && window.level == SettingsNotchHold.aboveNotch && opening.windows.count == 3)   // the board's Test opened it once more

        // 5. The person closes the notch themselves (Esc, the shortcut): theirs to do. Opening it again while Settings shows holds it again.
        nav.forceClose()
        check("Esc or the shortcut closes the notch even while Settings shows", !nav.isOpen && nav.holdOpenReasons.isEmpty)
        nav.open()
        nav.close()
        check("  a notch opened again while Settings shows is held again", nav.isOpen && nav.holdOpenReasons.contains(reason))

        // 6. The app stops being the one in use (the person went to another app): the notch is released and Settings steps down; coming back restores.
        hold.appActivityChanged(false)
        check("another app comes forward: the hold goes and Settings goes back to its ordinary level", !hold.isHolding && window.level == .normal && nav.holdOpenReasons.isEmpty)
        nav.forceClose()
        hold.appActivityChanged(true)
        check("  Scout is in use again with Settings on show: the notch opens behind it again", nav.isOpen && nav.holdOpenReasons.contains(reason) && window.level == SettingsNotchHold.aboveNotch)

        // 7. Settings closes: the hold is released, the level is back, the notch Settings opened closes.
        window.close()
        await settle()
        check("closing Settings releases the hold, restores the level and closes the notch it opened",
              !nav.isOpen && nav.holdOpenReasons.isEmpty && window.level == .normal && !hold.isHolding && NSColorPanel.shared.level == .floating,
              "open \(nav.isOpen), holds \(nav.holdOpenReasons), level \(window.level.rawValue), colour panel \(NSColorPanel.shared.level.rawValue)")
        nav.open()
        nav.close()
        check("  and the notch is an ordinary one again (it closes on close())", !nav.isOpen)

        // 8. Settings opens on a notch that is already open: it is held, and after Settings closes it stays open and ordinary.
        // Opening it again starts on the first page, whatever was open last;
        // a page asked for by name opens on that page.
        let savedPane = SettingsSelection.shared.pane
        SettingsSelection.shared.pane = .clipboard
        let openBefore = opening.windows.count
        nav.open()
        controller.show()
        check("Settings opened again starts on the first page (General)", SettingsSelection.shared.pane == .general, "\(String(describing: SettingsSelection.shared.pane))")
        check("Settings shows over a notch that is already open: held, not opened again", nav.isOpen && nav.holdOpenReasons.contains(reason) && opening.windows.count == openBefore && window.level == SettingsNotchHold.aboveNotch)
        window.close()
        await settle()
        check("  Settings closes: the hold is gone and the notch stays open (it was not Settings' to close)", nav.isOpen && nav.holdOpenReasons.isEmpty && window.level == .normal)
        nav.close()
        check("  and it closes as usual", !nav.isOpen)

        // 9. Another hold stays when Settings lets go (a menu, a text field in the notch). Opened for a page, it opens there.
        controller.show(.clipboard)
        check("  opened for a page by name, it opens on that page", SettingsSelection.shared.pane == .clipboard)
        SettingsSelection.shared.pane = savedPane
        nav.hold("radio.menu")
        window.close()
        await settle()
        check("Settings closes while something else holds the notch: the notch stays until that lets go", nav.isOpen && nav.holdOpenReasons == ["radio.menu"])
        nav.release("radio.menu")
        nav.forceClose()

        // 10. Which notch opens: the screen the window is on, else the first one.
        check("the notch for the Settings window: its own screen's, else the first one, none when there is none",
              NotchManager.controllerIndex(for: 2, among: [1, 2]) == 1 && NotchManager.controllerIndex(for: nil, among: [1, 2]) == 0
                && NotchManager.controllerIndex(for: 9, among: [1, 2]) == 0 && NotchManager.controllerIndex(for: 1, among: []) == nil)

        // 10b. The menu-bar icon setting (on/off) crashed Scout: the status item saves its visibility into the defaults, whose change
        // notification set it again before it settled. The latch applies once and ignores the echo (here the setter echoes ten levels deep).
        let latch = ReentryLatch()
        var depth = 0
        func setter(_ value: Bool) {
            depth += 1
            if depth < 10 { latch.apply(value) { setter($0) } }
        }
        latch.apply(false) { setter($0) }
        let firstRuns = latch.runs
        latch.apply(false) { setter($0) }
        depth = 0
        latch.apply(true) { setter($0) }
        check("the menu-bar icon's on/off setting: applied once per change, its own echo ignored, no repeat for the same value",
              firstRuns == 1 && latch.runs == 2 && latch.applied == true && depth == 1, "runs \(latch.runs), depth \(depth)")

        // 11. The real Settings content:
        // the search field sits under the window's buttons, no title is drawn, there is no split view (no hide key, no drag-to-collapse),
        // the sidebar keeps its width when the window is at its narrowest, and typing filters the pages. A picture goes next to the report.
        let savedPage = SettingsSelection.shared.pane
        let realNav = NotchNavigator()
        let real = SettingsWindowController(notchHold: SettingsNotchHold(navigator: realNav, openNotch: { _ in realNav.open() }), front: { w in
            w.setFrameOrigin(CGPoint(x: -20000, y: -20000))
            w.orderFrontRegardless()
        }, offscreen: true)
        real.show(.appearance)
        await settle(0.6)
        if let w = real.currentWindow, let content = w.contentView {
            let views = descendants(of: content.superview ?? content)
            let field = views.compactMap { $0 as? NSSearchField }.first
            let close = w.standardWindowButton(.closeButton)
            let fieldRect = field.map { $0.convert($0.bounds, to: nil) } ?? .zero
            let closeRect = close.map { $0.convert($0.bounds, to: nil) } ?? .zero
            check("Settings: the sidebar's search field is under the window's buttons, inside the sidebar",
                  field != nil && close != nil && fieldRect.maxY <= closeRect.minY - 2 && fieldRect.minX >= 0 && fieldRect.maxX <= SettingsRootView.sidebarWidth,
                  "field \(fieldRect), buttons \(closeRect)")
            check("  no window title is drawn over it (the page header names the page)", w.titleVisibility == .hidden && w.title == "Scout Settings")
            let toggle = w.toolbar?.items.contains { $0.itemIdentifier == .toggleSidebar || $0.itemIdentifier.rawValue.lowercased().contains("sidebar") } ?? false
            check("  the sidebar cannot be hidden: no split view to collapse and no hide key", !views.contains { $0 is NSSplitView } && !toggle,
                  "split views \(views.filter { $0 is NSSplitView }.count), toggle \(toggle)")
            let wide = fieldRect.width
            w.setContentSize(w.contentMinSize)
            await settle(0.3)
            let narrow = field.map { $0.convert($0.bounds, to: nil) } ?? .zero
            check("  the narrowest window keeps the sidebar as wide", abs(narrow.width - wide) < 0.5 && narrow.maxX <= SettingsRootView.sidebarWidth, "\(wide) → \(narrow.width)")
            let table = views.compactMap { $0 as? NSTableView }.first
            let rowsBefore = table?.numberOfRows ?? 0
            if let field {
                field.stringValue = "appear"
                field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            }
            await settle(0.4)
            let rowsAfter = descendants(of: content).compactMap { $0 as? NSTableView }.first?.numberOfRows ?? 0
            check("  typing in the search field filters the pages", rowsBefore > 6 && rowsAfter > 0 && rowsAfter < rowsBefore, "rows \(rowsBefore) → \(rowsAfter)")
            if let field {
                field.stringValue = ""
                field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            }
            w.setContentSize(CGSize(width: 900, height: 640))
            await settle(0.4)
            if let frameView = content.superview, let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out.deletingPathExtension().appendingPathExtension("png"))
            }
            w.close()
            await settle()
        } else {
            check("Settings: the real window is made", false)
        }
        SettingsSelection.shared.pane = savedPage

        finish(lines, failed, out: out)
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    /// A plain Scout window, visible at x -20000 (stands in for the tour).
    private static func shown() -> NSWindow {
        let w = ScoutWindow(contentRect: CGRect(x: -20000, y: -20000, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.allowsOffscreen = true
        w.isReleasedWhenClosed = false
        w.orderFrontRegardless()
        return w
    }

    private final class OpenLog {
        var windows: [NSWindow] = []
    }

    private static func finish(_ lines: [String], _ failed: Int, out file: URL) {
        var out = lines
        out.append("settings notch selftest done: \(failed == 0 ? "all passed" : "\(failed) FAILED")")
        for line in out { print(line) }
        fflush(stdout)
        try? out.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}
