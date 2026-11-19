import AppKit
import SwiftUI

/// Watches drags (global mouse monitor, no permission needed), opens a Pocket when a drag of files is shaken,
/// and owns the Pocket panels and the little switcher for minimized ones.
@MainActor
final class PocketsController {
    static let shared = PocketsController()

    private var monitor: Any?
    private var upMonitor: Any?
    private var detector = ShakeDetector()
    private var dragChange = -1
    private var dragHasFiles = false
    private var fired = false
    private var lastEnabled: Bool?
    private let store = PocketStore.shared

    static let switcherID = "pocket.switcher"

    // MARK: Lifecycle

    func start() {
        store.load()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        settingsChanged()
        if Pref.bool(PocketStore.Key.restore, true), !ScoutRuntime.isScripted {
            for p in store.pockets {
                if p.minimized { continue }
                show(p.id, near: nil)
            }
            updateSwitcher()
        }
    }

    private func settingsChanged() {
        let enabled = Pref.bool(PocketStore.Key.enabled, true) && !ScoutRuntime.isScripted
        detector.sensitivity = ShakeDetector.Sensitivity(rawValue: Pref.string(PocketStore.Key.sensitivity, "gentle")) ?? .gentle
        guard lastEnabled != enabled else { return }
        lastEnabled = enabled
        if enabled { install() } else { uninstall() }
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            let location = NSEvent.mouseLocation
            let time = event.timestamp
            MainActor.assumeIsolated { self?.dragged(to: location, at: time) }
        }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.dragEnded() }
        }
    }

    private func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let upMonitor { NSEvent.removeMonitor(upMonitor) }
        monitor = nil
        upMonitor = nil
    }

    // MARK: Detecting

    private func dragged(to point: CGPoint, at time: TimeInterval) {
        let board = NSPasteboard(name: .drag)
        if board.changeCount != dragChange {
            // A new drag started: does it carry files?
            dragChange = board.changeCount
            dragHasFiles = board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            detector.reset()
            fired = false
        }
        guard dragHasFiles, !fired else { return }
        if detector.feed(x: point.x, at: time) {
            fired = true
            Haptics.tick()
            let id = store.create()
            show(id, near: point)
            updateSwitcher()
        }
    }

    private func dragEnded() { dragHasFiles = false; fired = false; detector.reset() }

    // MARK: Panels

    static func panelID(_ id: UUID) -> String { "pocket.\(id.uuidString)" }

    func show(_ id: UUID, near point: CGPoint?) {
        let panelID = Self.panelID(id)
        if Panels.isShown(panelID) { Panels.panel(panelID)?.makeKeyAndOrderFront(nil); return }
        store.setMinimized(false, id)
        let size = CGSize(width: 196, height: 212)
        let position: Panels.Position
        if let point {
            position = .at(CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
        } else {
            position = .remembered
        }
        let panel = Panels.show(id: panelID, options: Panels.Options(size: size, resizable: false, position: position)) {
            PocketView(pocketID: id)
        }
        // Keep it on screen and above other windows, without taking focus from the app being dragged from.
        panel.level = .floating
        panel.dropTitleBar(size: size)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelClosed(id) }
        }
    }

    private var closingByMinimize: Set<UUID> = []

    private func panelClosed(_ id: UUID) {
        if closingByMinimize.remove(id) != nil { updateSwitcher(); return }
        // Closing an empty Pocket discards it; a Pocket with files stays in the switcher.
        if store.urls(of: id).isEmpty { store.discard(id) } else { store.setMinimized(true, id) }
        updateSwitcher()
    }

    func minimize(_ id: UUID) {
        store.setMinimized(true, id)
        closingByMinimize.insert(id)
        Panels.close(Self.panelID(id))
        updateSwitcher()
    }

    func close(_ id: UUID) {
        store.discard(id)
        closingByMinimize.insert(id)
        Panels.close(Self.panelID(id))
        updateSwitcher()
    }

    // MARK: Switcher (minimized pockets)

    func updateSwitcher() {
        let minimized = store.pockets.filter(\.minimized)
        if minimized.isEmpty { Panels.close(Self.switcherID); return }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = CGSize(width: 40 + CGFloat(minimized.count) * 74, height: 44)
        let origin = CGPoint(x: screen.visibleFrame.maxX - size.width - 14, y: screen.visibleFrame.maxY - size.height - 10)
        let panel = Panels.show(id: Self.switcherID, options: Panels.Options(size: size, resizable: false, position: .at(origin))) {
            PocketSwitcherView()
        }
        panel.dropTitleBar(size: size)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}
