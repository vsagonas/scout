import AppKit
import Combine
import SwiftUI

/// Owns every notch window and decides, from the pointer, when a notch opens and closes (A1).
///
/// The panels ignore the mouse except over the live island and cards. Global + local `.mouseMoved`
/// monitors (no permission needed) plus a slow timer tell us where the pointer is.
@MainActor
final class NotchManager {
    static let shared = NotchManager()

    private(set) var controllers: [NotchController] = []
    private(set) var active: NotchController?

    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    /// The pointer has been inside the open notch at least once; only then does leaving close it
    /// (an "Open Notch" from the menu bar or a scout:// command must not close before the pointer arrives).
    private var pointerVisited = false
    private var hoverPending: NotchController?
    private var hoverWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    /// A tab or panel switch can shrink the island away from a pointer that did not move (see `NotchSwitchGrace`).
    private var switchGrace = NotchSwitchGrace()
    private var rebuildWork: DispatchWorkItem?
    private var configSignature = ""
    private var keyFromApp: NSRunningApplication?
    private var started = false

    // Drag-and-drop mode
    private var dragBaseline = 0
    /// The mouse went down on the notch itself (dragging a Tray file out, say): that is not a drop coming in.
    private var dragStartedInNotch = false
    private var dragActive = false
    private var dropEndWork: DispatchWorkItem?

    // Two-finger gestures
    private var swipe = CGSize.zero
    private var swipeHandled = false

    private var navigator: NotchNavigator { .shared }

    // MARK: Start

    func start() {
        guard !started else { return }
        started = true
        // The notch always opens on the dashboard: no detail is remembered between visits (older versions saved one in
        // "notch.lastWorkspace"; the key is left alone, the first-run check in AppDelegate still reads it).
        configSignature = signature()
        rebuild()
        installMonitors()
        installObservers()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: Screens

    private func desiredScreens() -> [NSScreen] {
        let all = NSScreen.screens
        guard let main = all.first else { return [] }
        let mode = NotchPrefs.screens
        let candidates: [NSScreen]
        switch mode {
        case .main: candidates = [main]
        case .all: candidates = all
        case .notched: candidates = all.filter(\.hasHardwareNotch)
        }
        return candidates.filter { $0.hasHardwareNotch || (mode != .notched && NotchPrefs.virtualNotch) }
    }

    private func signature() -> String {
        let screens = NSScreen.screens.map { "\($0.displayID):\(NSStringFromRect($0.frame)):\($0.safeAreaInsets.top)" }.joined(separator: ",")
        return "\(NotchPrefs.screens.rawValue)|\(NotchPrefs.virtualNotch)|\(screens)"
    }

    func rebuild() {
        controllers.forEach { $0.teardown() }
        controllers = desiredScreens().map { NotchController(screen: $0) }
        active = nil
        if navigator.isOpen, let first = controllers.first {
            active = first
            first.model.isOpen = true
            first.panel.allowsKey = true
            first.panel.ignoresMouseEvents = false
        }
        updateFullscreen()
    }

    private func scheduleRebuild() {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let sig = self.signature()
            if sig != self.configSignature {
                self.configSignature = sig
                self.rebuild()
            }
        }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    // MARK: Observers and monitors

    private func installObservers() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRebuild() }
        })
        observers.append(nc.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRebuild() }
        })
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.updateFullscreen() }
                }
            })
        }
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object is NotchPanel else { return }
                if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() { self.keyFromApp = front }
            }
        })
        observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object is NotchPanel else { return }
                self.evaluate()
            }
        })

        navigator.$isOpen.removeDuplicates().sink { [weak self] open in
            DispatchQueue.main.async { self?.openChanged(open) }
        }.store(in: &cancellables)
        navigator.$workspace.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.noteSwitch() }
        }.store(in: &cancellables)
        #if !APPSTORE
        navigator.$activeTab.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.noteSwitch() }
        }.store(in: &cancellables)
        #endif
        navigator.$holdOpenReasons.removeDuplicates().sink { [weak self] reasons in
            guard reasons.isEmpty else { return }
            DispatchQueue.main.async { self?.evaluate() }
        }.store(in: &cancellables)
        navigator.$isDropTargeting.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.evaluate() }
        }.store(in: &cancellables)
        LiveActivityCenter.shared.$activities.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateFullscreen() }
        }.store(in: &cancellables)
    }

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerChanged() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerChanged() }
            return event
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.globalMouseDown() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.localMouseDown() }
            return event
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseUp() }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.scrolled(event) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.scrolled(event) }
            return event
        }) { monitors.append(m) }
    }

    // MARK: Pointer logic

    private func isInside(_ c: NotchController, _ p: CGPoint, includingCards: Bool = true) -> Bool {
        if c.islandScreenRect.contains(p) { return true }
        return includingCards && c.cardScreenRects.contains { $0.contains(p) }
    }

    /// How far the pointer is from the island (0 inside it).
    private func islandDistance(_ c: NotchController, _ p: CGPoint) -> CGFloat {
        let r = c.islandScreenRect
        return hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
    }

    /// The open notch switched what it shows (a tab, a panel, back to the dashboard): its size may change under the pointer.
    private func noteSwitch() {
        guard navigator.isOpen else { return }
        switchGrace.begin()
    }

    private func pointerChanged() {
        if dragActive { return }
        evaluate()
    }

    /// Looks at the pointer and the notch state and flips mouse capture, hover timers and close timers.
    func evaluate() {
        let p = NSEvent.mouseLocation
        if navigator.isOpen {
            guard let a = active else { return }
            hoverPending = nil
            hoverWork?.cancel()
            let inside = isInside(a, p)
            // The panel only catches the mouse over the island and cards, so clicks anywhere else reach the app
            // underneath (and our global monitors see them). A held button keeps whatever it started with.
            if navigator.isDropTargeting || NSEvent.pressedMouseButtons != 0 {
                a.panel.ignoresMouseEvents = false
            } else {
                a.panel.ignoresMouseEvents = !inside
            }
            if navigator.isDropTargeting { return }
            if inside {
                pointerVisited = true
                switchGrace.end()
                closeWork?.cancel(); closeWork = nil
            } else if switchGrace.keepsOpen(distance: islandDistance(a, p)) {
                closeWork?.cancel(); closeWork = nil
            } else if pointerVisited {
                scheduleClose()
            }
            return
        }
        let hit = controllers.first { !$0.model.hiddenForFullscreen && $0.islandScreenRect.contains(p) }
        for c in controllers {
            let overCard = c.cardScreenRects.contains { $0.contains(p) }
            c.panel.ignoresMouseEvents = !(c === hit || overCard) || c.model.hiddenForFullscreen
        }
        guard let hit else {
            hoverPending = nil
            hoverWork?.cancel()
            controllers.forEach { if $0.model.detailVisible { $0.model.detailVisible = false } }
            return
        }
        guard hoverPending !== hit else { return }
        hoverPending = hit
        hoverWork?.cancel()
        switch NotchPrefs.hover {
        case .open:
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hoverPending === hit, !self.navigator.isOpen else { return }
                self.active = hit
                self.navigator.open()
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NotchPrefs.hoverDelay, execute: work)
        case .details:
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hoverPending === hit, !self.navigator.isOpen else { return }
                hit.model.detailVisible = true
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        case .off:
            break
        }
    }

    private func scheduleClose() {
        guard closeWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.closeWork = nil
            guard self.navigator.isOpen, self.navigator.holdOpenReasons.isEmpty, !self.navigator.isDropTargeting else { return }
            if let a = self.active, !self.isInside(a, NSEvent.mouseLocation),
               !self.switchGrace.keepsOpen(distance: self.islandDistance(a, NSEvent.mouseLocation)) {
                // A text field with the cursor in it keeps the notch open until focus leaves.
                if a.panel.isKeyWindow, a.panel.firstResponder is NSText { self.scheduleClose(); return }
                self.navigator.close()
            }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func localMouseDown() {
        dragBaseline = NSPasteboard(name: .drag).changeCount
        dragStartedInNotch = true
    }

    private func globalMouseDown() {
        dragBaseline = NSPasteboard(name: .drag).changeCount
        dragStartedInNotch = false
        guard navigator.isOpen, let a = active, !navigator.isDropTargeting else { return }
        // A click in another app or on the desktop ends the visit (unless something holds the notch open). The Ask AI tab's holds end with
        // that click: they mean "until you click away".
        if !isInside(a, NSEvent.mouseLocation) {
            AskAITabHold.ended(navigator: navigator)
            navigator.close()
        }
    }

    private func mouseUp() {
        if dragActive {
            dragActive = false
            scheduleDropEnd()
        }
    }

    // MARK: Open / close

    /// The index of the notch to open for a window on the screen `displayID`: that screen's notch, else the first one (the main notched
    /// screen); nil when there is no notch at all.
    nonisolated static func controllerIndex(for displayID: CGDirectDisplayID?, among displayIDs: [CGDirectDisplayID]) -> Int? {
        if let displayID, let i = displayIDs.firstIndex(of: displayID) { return i }
        return displayIDs.isEmpty ? nil : 0
    }

    /// Opens the notch for the Settings window (it stays open behind it, see `SettingsNotchHold`): on the screen the window is on, else the main
    /// notched screen. A notch that is already open stays where it is.
    func openBehind(_ window: NSWindow?) {
        if !navigator.isOpen,
           let i = Self.controllerIndex(for: window?.screen?.displayID, among: controllers.map(\.displayID)) {
            active = controllers[i]
        }
        navigator.open()
    }

    private func openChanged(_ open: Bool) {
        hoverWork?.cancel()
        closeWork?.cancel(); closeWork = nil
        switchGrace.end()
        if open {
            if active == nil {
                let p = NSEvent.mouseLocation
                active = controllers.first { $0.screenFrame.contains(p) } ?? controllers.first
            }
            for c in controllers {
                c.model.isOpen = (c === active)
                c.model.detailVisible = false
            }
            active?.panel.allowsKey = true
            active?.panel.ignoresMouseEvents = false
            pointerVisited = active.map { isInside($0, NSEvent.mouseLocation) } ?? false
            if NotchPrefs.haptics { Haptics.tick() }
        } else {
            for c in controllers { c.model.isOpen = false }
            if NookStore.shared.isEditing { NookStore.shared.endEditing() }
            if navigator.isDropTargeting { navigator.isDropTargeting = false }
            // No tick when it closes: only opening taps the trackpad
            let closing = active
            active = nil
            hoverPending = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.navigator.isOpen else { return }
                self.returnKeyToUser(closing)
                closing?.panel.allowsKey = false
                // Closed with the pointer still on the notch (Esc, a click on the gear): no instant re-open.
                let p = NSEvent.mouseLocation
                self.hoverPending = self.controllers.first { $0.fallbackNotchRect.insetBy(dx: -6, dy: -6).contains(p) }
                self.evaluate()
            }
        }
    }

    /// The notch took keyboard focus (a text field): give typing back to the app the user was in.
    private func returnKeyToUser(_ c: NotchController?) {
        guard let panel = c?.panel, panel.isKeyWindow else { return }
        panel.resignKey()
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        if let app = keyFromApp, !app.isTerminated { app.activate(options: []) }
        keyFromApp = nil
    }

    // MARK: Timer: drag detection, fullscreen, safety net

    private var tickCount = 0

    private func tick() {
        tickCount += 1
        // Drag of files or links toward the notch.
        let leftDown = NSEvent.pressedMouseButtons & 1 != 0
        if leftDown {
            let pb = NSPasteboard(name: .drag)
            if pb.changeCount != dragBaseline, !dragStartedInNotch, carriesDroppable(pb) {
                if !dragActive { dragActive = true; dropEndWork?.cancel() }
                updateDrop(NSEvent.mouseLocation)
            }
        } else if dragActive {
            dragActive = false
            scheduleDropEnd()
        }
        if !dragActive, !navigator.isDropTargeting, tickCount % 5 == 0 { evaluate() }
        if tickCount % 45 == 0 { updateFullscreen() }
    }

    private func carriesDroppable(_ pb: NSPasteboard) -> Bool {
        guard !NookStore.shared.isEditing else { return false }
        let types = pb.types ?? []
        return types.contains(.fileURL) || types.contains(.URL) || types.contains(.string)
    }

    private func updateDrop(_ p: CGPoint) {
        var best: (NotchController, CGFloat)?
        for c in controllers where !c.model.hiddenForFullscreen {
            let r = navigator.isOpen && active === c ? c.islandScreenRect : c.fallbackNotchRect
            let dx = max(r.minX - p.x, 0, p.x - r.maxX)
            let dy = max(r.minY - p.y, 0, p.y - r.maxY)
            let d = hypot(dx, dy)
            if best == nil || d < best!.1 { best = (c, d) }
        }
        guard let (c, distance) = best else { return }
        let limit: CGFloat = navigator.isDropTargeting ? 240 : 120
        if distance <= limit {
            dropEndWork?.cancel()
            guard !navigator.isDropTargeting || active !== c else { return }
            active = c
            c.panel.ignoresMouseEvents = false
            navigator.isDropTargeting = true
            navigator.open()
        } else if navigator.isDropTargeting {
            endDrop()
        }
    }

    private func scheduleDropEnd() {
        guard navigator.isDropTargeting else { return }
        dropEndWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endDrop() }
        dropEndWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func endDrop() {
        dropEndWork?.cancel()
        guard navigator.isDropTargeting else { return }
        navigator.isDropTargeting = false
        if navigator.isOpen, let a = active, !isInside(a, NSEvent.mouseLocation) { navigator.close() }
    }

    // MARK: Fullscreen

    func updateFullscreen() {
        guard NotchPrefs.hideInFullscreen else {
            controllers.forEach { $0.model.hiddenForFullscreen = false }
            return
        }
        // On-screen windows, front to back (the order CGWindowList gives).
        let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let windows: [FullscreenWindow] = info.compactMap { w in
            guard let dict = w[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: dict) else { return nil }
            return FullscreenWindow(layer: w[kCGWindowLayer as String] as? Int ?? -1, pid: w[kCGWindowOwnerPID as String] as? Int32 ?? 0,
                                    rect: rect, alpha: w[kCGWindowAlpha as String] as? Double ?? 1)
        }
        let mine = getpid()
        let allowed = LiveActivityCenter.shared.primary.map { Pref.bool("activity.\($0.kind.rawValue).fullscreen", false) } ?? false
        for c in controllers {
            let covered = Self.coversScreen(windows, bounds: CGDisplayBounds(c.displayID), mine: mine)
            let hidden = covered && !allowed
            if c.model.hiddenForFullscreen != hidden {
                c.model.hiddenForFullscreen = hidden
                if hidden { c.panel.ignoresMouseEvents = true }
            }
        }
    }

    struct FullscreenWindow {
        let layer: Int
        let pid: Int32
        let rect: CGRect
        var alpha: Double = 1
    }

    /// Whether another app's full-screen window is IN FRONT on the screen `bounds`: the front ordinary window on that screen (layer 0, not
    /// Scout's, visible, bigger than a helper) fills the screen exactly. A full-screen game left running behind other windows does not count:
    /// it hid Scout on every screen while the owner worked in other apps.
    nonisolated static func coversScreen(_ windows: [FullscreenWindow], bounds: CGRect, mine: Int32) -> Bool {
        for w in windows where w.layer == 0 && w.pid != mine && w.alpha > 0.01 && w.rect.width >= 80 && w.rect.height >= 80 {
            guard w.rect.intersects(bounds) else { continue }
            return abs(w.rect.minX - bounds.minX) < 1 && abs(w.rect.minY - bounds.minY) < 1
                && abs(w.rect.width - bounds.width) < 1 && abs(w.rect.height - bounds.height) < 1
        }
        return false
    }

    // MARK: Two-finger gestures (P2)

    private func scrolled(_ event: NSEvent) {
        guard NotchPrefs.gestures, event.hasPreciseScrollingDeltas else { return }
        let p = NSEvent.mouseLocation
        guard let c = controllers.first(where: { isInside($0, p, includingCards: false) }) else { return }
        // While the notch is open only its top strip counts: scrolling the content below must never close it.
        if navigator.isOpen {
            let strip = c.screenFrame.maxY - c.model.geometry.size.height - 6
            guard p.y >= strip else { return }
        }
        if event.phase == .began { swipe = .zero; swipeHandled = false }
        guard !swipeHandled else { return }
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        swipe.width += event.scrollingDeltaX * sign
        swipe.height += event.scrollingDeltaY * sign
        let vertical = abs(swipe.height) > abs(swipe.width)
        if vertical, abs(swipe.height) > 36 {
            swipeHandled = true
            if swipe.height > 0, !navigator.isOpen {
                active = c
                navigator.open()
            } else if swipe.height < 0, navigator.isOpen {
                navigator.close()
            }
        } else if !vertical, abs(swipe.width) > 60, !navigator.isOpen {
            swipeHandled = true
            let right = (swipe.width > 0) != NotchPrefs.gestureInvert
            if NowPlayingService.shared.track != nil {
                if right { NowPlayingService.shared.next() } else { NowPlayingService.shared.previous() }
                if NotchPrefs.haptics { Haptics.step() }
            }
        }
    }
}

/// After the open notch switches what it shows, the island may shrink away from a pointer that has not moved: picking the
/// dashboard tab from a wider view closed the notch.
/// For `settle` seconds nothing closes while the island changes size; after
/// that the notch closes only once the pointer is `slack` farther from the island than the switch left it. Back inside, the
/// ordinary rule returns (`end()`).
struct NotchSwitchGrace {
    static let settle: TimeInterval = 0.6
    static let slack: CGFloat = 40
    private(set) var since: Date?
    private(set) var allowed: CGFloat = 0

    mutating func begin(now: Date = Date()) {
        since = now
        allowed = 0
    }

    mutating func end() {
        since = nil
        allowed = 0
    }

    /// True: leave the notch open although the pointer is outside, `distance` points from the island.
    mutating func keepsOpen(distance: CGFloat, now: Date = Date()) -> Bool {
        guard let since else { return false }
        if now.timeIntervalSince(since) < Self.settle {
            allowed = max(allowed, distance + Self.slack)
            return true
        }
        if distance <= allowed { return true }
        end()
        return false
    }
}
