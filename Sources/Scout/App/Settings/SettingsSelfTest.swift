import AppKit

/// `scout://settings.selftest?row=6&front=1&out=<file>`: opens Settings and checks that the sidebar takes
/// clicks, without moving the pointer. For every sidebar row it writes where a real click would land (the
/// window server's answer, which counts windows that ignore the mouse correctly) and which view inside the
/// window would get it; then it posts a click on `row` and reports whether the page changed.
@MainActor
enum SettingsSelfTest {
    static func run(out: URL, row: Int, bringToFront: Bool, forceActivate: Bool = false, regular: Bool = false) {
        if regular { NSApp.setActivationPolicy(.regular) }
        if bringToFront || SettingsWindowController.shared.currentWindow == nil { SettingsWindowController.shared.show(.general) }
        if forceActivate {
            if let window = SettingsWindowController.shared.currentWindow { WindowFront.show(window) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { inspect(out: out, row: row) }
    }

    private static func name(_ object: AnyObject?) -> String {
        object.map { String(describing: type(of: $0)) } ?? "nil"
    }

    private static func inspect(out: URL, row wanted: Int) {
        var lines: [String] = []
        func write() { try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8) }
        guard let window = SettingsWindowController.shared.currentWindow, let frameView = window.contentView?.superview else {
            lines.append("no settings window"); write(); return
        }
        lines.append("settings window \(window.windowNumber) frame \(NSStringFromRect(window.frame)) key \(window.isKeyWindow) appActive \(NSApp.isActive)")
        for w in NSApp.windows where w.isVisible && w !== window {
            lines.append("other window \(w.windowNumber) \(name(w)) level \(w.level.rawValue) frame \(NSStringFromRect(w.frame)) ignoresMouse \(w.ignoresMouseEvents)")
        }
        let views = allViews(frameView)
        let tables = views.compactMap { $0 as? NSTableView }
        lines.append("tables: " + tables.map { "\(name($0)) rows \($0.numberOfRows) in window \(NSStringFromRect($0.convert($0.bounds, to: nil)))" }.joined(separator: " | "))
        let interesting = Set(views.map { name($0) }).filter { $0.contains("Table") || $0.contains("Outline") || $0.contains("List") || $0.contains("Split") || $0.contains("Hosting") }
        lines.append("views: " + interesting.sorted().joined(separator: ", "))

        var points: [(Int, CGPoint)] = []
        if let table = tables.max(by: { $0.numberOfRows < $1.numberOfRows }), table.numberOfRows > 0 {
            for row in 0..<table.numberOfRows {
                let r = table.rect(ofRow: row)
                points.append((row, table.convert(CGPoint(x: r.midX, y: r.midY), to: nil)))
            }
        } else {
            // No table view: probe a column of points where the sidebar sits.
            let h = window.contentLayoutRect.height
            for i in 0..<10 { points.append((i, CGPoint(x: 110, y: h - 90 - CGFloat(i) * 32))) }
        }
        var target: CGPoint?
        for (row, inWindow) in points {
            let onScreen = window.convertPoint(toScreen: inWindow)
            let hit = frameView.hitTest(inWindow)
            let server = NSWindow.windowNumber(at: onScreen, belowWindowWithWindowNumber: 0)
            let owner = server == window.windowNumber ? "Settings" : (NSApp.window(withWindowNumber: server).map { "\(name($0)) level \($0.level.rawValue)" } ?? "another app")
            lines.append("row \(row) at \(NSStringFromPoint(onScreen)): view \(name(hit)), a real click goes to window \(server) (\(owner))")
            if row == wanted { target = inWindow }
        }
        guard let target else { write(); return }
        let before = SettingsSelection.shared.pane
        let t = ProcessInfo.processInfo.systemUptime
        if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: target, modifierFlags: [], timestamp: t, windowNumber: window.windowNumber,
                                         context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
           let up = NSEvent.mouseEvent(with: .leftMouseUp, location: target, modifierFlags: [], timestamp: t + 0.06, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
            NSApp.postEvent(down, atStart: false)
            NSApp.postEvent(up, atStart: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            lines.append("posted click on row \(wanted): page \(before?.rawValue ?? "nil") -> \(SettingsSelection.shared.pane?.rawValue ?? "nil"); key \(window.isKeyWindow) appActive \(NSApp.isActive) policy \(NSApp.activationPolicy().rawValue)")
            write()
        }
    }

    private static func allViews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(allViews) }
}
