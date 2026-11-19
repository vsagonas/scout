import AppKit
import SwiftUI

// The menu-bar item (binoculars).

@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    static let shared = StatusMenu()
    private var item: NSStatusItem?
    private var notchItem: NSMenuItem?
    private var clipboardItem: NSMenuItem?
    private var menu: NSMenu?
    private var observer: NSObjectProtocol?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // The minimal agent face, not the binoculars.
        // A template image: the menu bar tints it.
        let face = AppIconInUse.menuBarImage   // the agent face's outline and two eyes (a template the menu bar tints)
        face.accessibilityDescription = "Scout"
        item.button?.image = face
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        notchItem = add(menu, String(localized: "Open Notch"), #selector(toggleNotch), symbol: "rectangle.topthird.inset.filled")
        menu.addItem(.separator())
        clipboardItem = add(menu, String(localized: "Pause Clipboard History"), #selector(toggleClipboard), symbol: "pause.circle")
        menu.addItem(.separator())
        add(menu, String(localized: "Settings…"), #selector(openSettings), key: ",", symbol: "gearshape")
        menu.addItem(.separator())
        add(menu, String(localized: "Quit Scout"), #selector(quit), key: "q")
        // Scout opens the menu itself (see openMenu) instead of `item.menu`, which macOS 27 placed a line too low.
        self.menu = menu
        item.button?.target = self
        item.button?.action = #selector(buttonPressed)
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        self.item = item
        applyVisibility()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyVisibility() }
        }
        DebugCommands.register("statusmenu.measure") { [weak self] params in
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("statusmenu-measure.txt")
            self?.measure(out: out)
        }
    }

    @objc private func buttonPressed() { openMenu() }

    /// Opens the menu right under the menu bar. macOS 27 reports the icon's window a whole bar-height too low
    /// (65 pt tall, the icon at its bottom), so the automatic `statusItem.menu` opened one line below the bar.
    /// The bar's own height places it right.
    private func openMenu() {
        guard let menu, let button = item?.button, let window = button.window else { return }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
        let bar = max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        // A menu draws 8 pt to the right of the point it is given: −13 puts its edge 5 pt left of the icon, as macOS does.
        let point = NSPoint(x: icon.minX - 13, y: screen.frame.maxY - bar - 5)
        button.highlight(true)
        menu.popUp(positioning: nil, at: point, in: nil)
        button.highlight(false)
    }

    /// `scout://statusmenu.measure`: opens the menu for a moment and writes where the icon and the menu sit.
    private func measure(out: URL) {
        guard let button = item?.button, menu != nil else { return }
        var lines: [String] = []
        let screen = button.window?.screen ?? NSScreen.main
        lines.append("screen \(NSStringFromRect(screen?.frame ?? .zero)) visibleTop \(screen?.visibleFrame.maxY ?? 0) safeTop \(screen?.safeAreaInsets.top ?? 0) thickness \(NSStatusBar.system.thickness)")
        lines.append("icon window \(NSStringFromRect(button.window?.frame ?? .zero)) button \(NSStringFromRect(button.frame)) image \(NSStringFromSize(button.image?.size ?? .zero)) alignmentRect \(NSStringFromRect(button.image?.alignmentRect ?? .zero))")
        let before = Set(NSApp.windows.map(\.windowNumber))
        let screenTop = screen?.frame.maxY ?? 0
        let header = lines
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                var report = header
                for w in NSApp.windows where w.isVisible && !before.contains(w.windowNumber) {
                    report.append("menu window \(type(of: w)) \(NSStringFromRect(w.frame)) top \(screenTop - w.frame.maxY) pt below the screen top")
                }
                self?.menu?.cancelTracking()
                try? report.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .default)
        button.performClick(nil)
    }

    /// Shows or hides the icon when the setting changes. Showing or hiding a status item makes macOS save that into Scout's defaults, which
    /// posts "defaults changed" at once, before the item reports its new state; answering that echo set the item again and again until the
    /// stack ran out. The latch applies a value
    /// once and ignores what comes back while it is being applied.
    private let visibility = ReentryLatch()

    private func applyVisibility() {
        let show = Pref.bool("app.showMenuBarIcon", true)
        visibility.apply(show) { [weak self] value in self?.item?.isVisible = value }
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        if let symbol { entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(entry)
        return entry
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        notchItem?.title = NotchNavigator.shared.isOpen ? String(localized: "Close Notch") : String(localized: "Open Notch")
        let paused = ClipboardStore.shared.isPaused
        clipboardItem?.title = paused ? String(localized: "Resume Clipboard History") : String(localized: "Pause Clipboard History")
        clipboardItem?.image = NSImage(systemSymbolName: paused ? "play.circle" : "pause.circle", accessibilityDescription: nil)
    }

    @objc private func toggleNotch() {
        let nav = NotchNavigator.shared
        if nav.isOpen { nav.forceClose() } else { nav.open() }
    }

    @objc private func toggleClipboard() { ClipboardStore.shared.isPaused.toggle() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Applies a wanted value once, and only when it changed; a call that comes back while the value is being applied (a notification the
/// setter itself posts) is ignored. A class on purpose: the setter re-enters it while `apply` is still running.
@MainActor
final class ReentryLatch {
    private var applying = false
    private(set) var applied: Bool?
    /// How many times the setter really ran (self-tests).
    private(set) var runs = 0

    func apply(_ want: Bool, _ set: (Bool) -> Void) {
        guard !applying, applied != want else { return }
        applying = true
        applied = want
        runs += 1
        set(want)
        applying = false
    }
}
