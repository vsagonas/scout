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

    /// The app's one manager uses the shared navigator and activity centre; a self-test makes its own (with controllers that show no panel) and runs
    /// the closed flow headless (`install(controllers:)`, `bindNavigator()`, `evaluate(at:)`).
    init(navigator: NotchNavigator? = nil, center: LiveActivityCenter? = nil) {
        self.navigator = navigator ?? .shared
        self.center = center ?? .shared
    }

    private let navigator: NotchNavigator
    private let center: LiveActivityCenter

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
    /// What the pending hover will do (nil: the pointer was on the notch when it closed, so nothing restarts until the pointer has left).
    private var hoverPendingAction: HoverAction?
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

    // Headless tests: where the pointer is (instead of the real one), and what a click on a shape does.
    var pointerOverride: CGPoint?
    var pressedButtonsOverride: Int?
    /// A click on a named shape: `IslandHit.perform` with this manager's own navigator and centre. A test counts the calls.
    lazy var onShapeClick: (String, NotchGeometry) -> Bool = { [unowned self] name, geometry in
        IslandHit.perform(name, geometry: geometry, navigator: self.navigator, center: self.center)
    }
    /// The timestamps of the last click the panel got and of the last one the fallback ran, so one click never runs twice.
    private var lastPanelClickStamp: TimeInterval = -1
    private var lastFallbackStamp: TimeInterval = -1

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

    /// The screens that get a notch: the mode says which displays are candidates (the main one, all of them), the kind of each says whether Scout
    /// draws there (`NotchScreenPolicy.keeps`).
    private func desiredScreens() -> [NSScreen] {
        let all = NSScreen.screens
        guard let main = all.first else { return [] }
        let mode = NotchPrefs.screens
        let candidates = mode == .main ? [main] : all
        let shape = NotchPrefs.noneShape
        return candidates.filter { NotchScreenPolicy.keeps(kind: NotchGeometry.make(for: $0).kind, shape: shape, mode: mode) }
    }

    private func signature() -> String { NotchScreenPolicy.currentSignature() }

    func rebuild() {
        // A hover that was about to act belongs to a controller that is torn down now: it must not open "its" notch afterwards.
        hoverWork?.cancel(); hoverWork = nil
        hoverPending = nil
        hoverPendingAction = nil
        controllers.forEach { $0.teardown() }
        controllers = desiredScreens().map { NotchController(screen: $0) }
        active = nil
        if navigator.isOpen {
            // The dashboard comes back on the first display where it opens; none (only pills left) closes it, as the central refusal would.
            if let i = Self.dashboardIndex(among: controllers.map(\.model.geometry)) {
                let first = controllers[i]
                active = first
                first.model.isOpen = true
                first.panel.allowsKey = true
                first.panel.ignoresMouseEvents = false
            } else if !controllers.isEmpty {
                navigator.forceClose()
            }
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

        bindNavigator()
        center.$activities.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateFullscreen() }
        }.store(in: &cancellables)
    }

    /// The manager follows the navigator: it opens and closes its controllers when `isOpen` flips. Split out so a test can bind a manager of its own
    /// to its own navigator without any system observer or monitor.
    func bindNavigator() {
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
    }

    /// For tests: the controllers the manager works with, none of them on the screen.
    func install(controllers list: [NotchController]) {
        controllers = list
        active = nil
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
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.globalMouseDown(stamp: event.timestamp) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.localMouseDown(stamp: event.timestamp) }
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

    /// What the closed notch of `c` draws now (the same rule the root view asks): the classic shape, separate shapes beside the housing, or nothing.
    func closedDrawing(of c: NotchController) -> ClosedDrawing {
        IslandMode.closed(geometry: c.model.geometry, primary: center.primary?.kind, cardsUp: !center.cards.isEmpty, detailUp: c.model.detailVisible)
    }

    private func isInside(_ c: NotchController, _ p: CGPoint, includingCards: Bool = true) -> Bool {
        // Closed with separate shapes: only a shape (or a claimed housing) counts, never the rect around the whole island.
        if !navigator.isOpen, !c.model.isOpen, closedDrawing(of: c) == .rows {
            if c.hitTarget(at: p) != .none { return true }
            return includingCards && c.cardScreenRects.contains { $0.contains(p) }
        }
        // Just opened from a bubble or a capsule: until the open island has reported its frame, the pointer that opened it still counts as
        // on it (the housing's rect alone would say "outside" for a moment and the fresh dashboard would let a click fall through).
        if c.model.isOpen, c.model.geometry.hasRows, c.model.islandRect.width <= 0, c.hitTarget(at: p) != .none { return true }
        if c.islandScreenRect.contains(p) { return true }
        return includingCards && c.cardScreenRects.contains { $0.contains(p) }
    }

    /// The pointer is over one of the separate shapes (or the claimed housing) a closed notch draws beside its housing.
    private func restsOnShape(_ c: NotchController, at p: CGPoint) -> Bool {
        closedDrawing(of: c) == .rows && c.hitTarget(at: p) != .none
    }

    /// How far the pointer is from the island (0 inside it).
    private func islandDistance(_ c: NotchController, _ p: CGPoint) -> CGFloat {
        let r = c.islandScreenRect
        guard !r.isNull else { return .greatestFiniteMagnitude }
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

    private var pointerLocation: CGPoint { pointerOverride ?? NSEvent.mouseLocation }
    private var pressedButtons: Int { pressedButtonsOverride ?? Int(NSEvent.pressedMouseButtons) }

    /// Looks at the pointer and the notch state and flips mouse capture, hover timers and close timers. `pointer` is passed in by tests.
    func evaluate(at pointer: CGPoint? = nil) {
        let p = pointer ?? pointerLocation
        if navigator.isOpen {
            guard let a = active else { return }
            hoverPending = nil
            hoverWork?.cancel()
            let inside = isInside(a, p)
            // The panel only catches the mouse over the island and cards, so clicks anywhere else reach the app
            // underneath (and our global monitors see them). A held button keeps whatever it started with.
            if navigator.isDropTargeting || pressedButtons != 0 {
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
        // Closed. A notch that draws the classic shape takes the pointer over its island rect, exactly as before; one that draws separate shapes
        // takes it only over a shape (and its housing where it claims it); one that draws nothing takes none.
        var hit: NotchController?
        var rowsTarget: IslandTarget?
        for c in controllers where !c.model.hiddenForFullscreen {
            switch closedDrawing(of: c) {
            case .classic:
                if c.islandScreenRect.contains(p) { hit = c }
            case .rows:
                let target = c.hitTarget(at: p)
                if target != .none { hit = c; rowsTarget = target }
            case .nothing:
                break
            }
            if hit != nil { break }
        }
        for c in controllers {
            let overCard = c.cardScreenRects.contains { $0.contains(p) }
            c.panel.ignoresMouseEvents = !(c === hit || overCard) || c.model.hiddenForFullscreen
            if c !== hit, c.model.hoveredHit != nil { c.model.hoveredHit = nil }
        }
        guard let hit else {
            hoverPending = nil
            hoverPendingAction = nil
            hoverWork?.cancel()
            controllers.forEach { if $0.model.detailVisible { $0.model.detailVisible = false } }
            return
        }
        // The shape under the pointer lights up as the pointer moves from one to the next, whatever the setting says.
        let lit = rowsTarget.flatMap { IslandHitAreas.highlightName(for: $0) }
        if hit.model.hoveredHit != lit { hit.model.hoveredHit = lit }
        let action: HoverAction
        if let rowsTarget, let kind = IslandHitAreas.hoverTarget(for: rowsTarget, geometry: hit.model.geometry) {
            action = IslandHitAreas.hoverAction(setting: NotchPrefs.hover, target: kind, geometry: hit.model.geometry)
        } else {
            switch NotchPrefs.hover {
            case .open: action = .open
            case .details: action = .showDetail
            case .off: action = .nothing
            }
        }
        // One hover per visit: moving from one shape to the next does not start another, unless what hover does there is something else (from a bubble that
        // only lights up to the notch itself that shows its detail).
        guard hoverPending !== hit || (rowsTarget != nil && hoverPendingAction != nil && hoverPendingAction != action) else { return }
        hoverPending = hit
        hoverPendingAction = action
        hoverWork?.cancel()
        switch action {
        case .open:
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hoverPending === hit, !self.navigator.isOpen else { return }
                self.active = hit
                self.navigator.open()
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NotchPrefs.hoverDelay, execute: work)
        case .showDetail:
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hoverPending === hit, !self.navigator.isOpen else { return }
                hit.model.detailVisible = true
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + IslandHitAreas.detailDelay, execute: work)
        case .highlight, .nothing:
            break
        }
    }

    private func scheduleClose() {
        guard closeWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.closeWork = nil
            guard self.navigator.isOpen, self.navigator.holdOpenReasons.isEmpty, !self.navigator.isDropTargeting else { return }
            if let a = self.active, !self.isInside(a, self.pointerLocation),
               !self.switchGrace.keepsOpen(distance: self.islandDistance(a, self.pointerLocation)) {
                // A text field with the cursor in it keeps the notch open until focus leaves.
                if a.panel.isKeyWindow, a.panel.firstResponder is NSText { self.scheduleClose(); return }
                self.navigator.close()
            }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// The panel got a click: it is the panel's to handle (a shape's own tap runs `IslandHit.perform`), never the fallback's.
    func localMouseDown(stamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        dragBaseline = NSPasteboard(name: .drag).changeCount
        dragStartedInNotch = true
        lastPanelClickStamp = stamp
    }

    /// A click only the global monitor saw: it went to another app's window. Open, it ends the visit when it lands outside the notch. Closed, a
    /// click that landed on one of Scout's shapes the panel did not get (the system's own island may swallow clicks near the camera: unknown) runs
    /// the same action the shape's tap would.
    func globalMouseDown(at p: CGPoint? = nil, stamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let p = p ?? pointerLocation
        dragBaseline = NSPasteboard(name: .drag).changeCount
        dragStartedInNotch = false
        if !navigator.isOpen { fallbackClick(at: p, stamp: stamp); return }
        guard let a = active, !navigator.isDropTargeting else { return }
        // A click in another app or on the desktop ends the visit (unless something holds the notch open). The Ask AI tab's holds end with
        // that click: they mean "until you click away".
        if !isInside(a, p) {
            AskAITabHold.ended(navigator: navigator)
            navigator.close()
        }
    }

    /// Runs the click on the shape under `p` when the panel did not get it. A click runs once: the panel's own click (same timestamp) and an
    /// earlier run of the fallback for the same click both stop it. Returns whether an action ran.
    @discardableResult
    func fallbackClick(at p: CGPoint, stamp: TimeInterval) -> Bool {
        guard NotchPrefs.clickToOpen, stamp != lastPanelClickStamp, stamp != lastFallbackStamp else { return false }
        for c in controllers where !c.model.hiddenForFullscreen && closedDrawing(of: c) == .rows {
            switch c.hitTarget(at: p) {
            case .shape(let name):
                lastFallbackStamp = stamp
                if IslandMode.opens(geometry: c.model.geometry) { active = c }   // a refused click (a pill) must not leave that screen as the one to open on
                return onShapeClick(name, c.model.geometry)
            case .housing:
                // The housing a display claims (a classic notch between its bubbles): a click opens the notch, as it always did.
                guard IslandMode.opens(geometry: c.model.geometry) else { continue }
                lastFallbackStamp = stamp
                active = c
                navigator.open()
                return true
            case .none:
                continue
            }
        }
        return false
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

    /// The index of the first display where the dashboard opens (a pill, in this build, is not one); nil when there is none.
    static func dashboardIndex(among geometries: [NotchGeometry]) -> Int? { geometries.firstIndex { IslandMode.opens(geometry: $0) } }

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
                let p = pointerLocation
                active = controllers.first { $0.screenFrame.contains(p) } ?? controllers.first
            }
            // The dashboard never opens on a display where it does not (a pill, in this build), whatever asked: the hover, a click, the menu, a
            // hotkey, a drop, a command. One log line, nothing else.
            if let a = active, !IslandMode.opens(geometry: a.model.geometry) {
                NSLog("Scout: the dashboard does not open on this display yet (the camera pill)")
                active = nil
                navigator.forceClose()
                return
            }
            for c in controllers {
                c.model.isOpen = (c === active)
                c.model.detailVisible = false
                if c.model.hoveredHit != nil { c.model.hoveredHit = nil }   // nothing stays lit under an open dashboard
            }
            active?.panel.allowsKey = true
            active?.panel.ignoresMouseEvents = false
            pointerVisited = active.map { isInside($0, pointerLocation) } ?? false
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
                // Closed with the pointer still on the notch (Esc, a click on the gear): no instant re-open. Where separate shapes are drawn, a
                // pointer resting on one of them counts as well (the housing's rect and 6 pt around it do not reach a bubble or a capsule).
                let p = self.pointerLocation
                self.hoverPending = self.controllers.first { $0.housingScreenRect.insetBy(dx: -6, dy: -6).contains(p) || self.restsOnShape($0, at: p) }
                self.hoverPendingAction = nil
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

    /// The notch a dragged file at `p` is nearest to and how far it is from its anchor (the housing). A display where the dashboard does not open (a
    /// pill, in this build) takes no drop. While this notch is the open one its whole island counts.
    func dropCandidate(at p: CGPoint) -> (controller: NotchController, distance: CGFloat)? {
        var best: (NotchController, CGFloat)?
        for c in controllers where !c.model.hiddenForFullscreen && IslandHitAreas.dropOpens(geometry: c.model.geometry) {
            let r = navigator.isOpen && active === c ? c.islandScreenRect : c.housingScreenRect
            let d = IslandHitAreas.distance(from: p, to: r)
            if best == nil || d < best!.1 { best = (c, d) }
        }
        return best.map { (controller: $0.0, distance: $0.1) }
    }

    private func updateDrop(_ p: CGPoint) {
        guard let (c, distance) = dropCandidate(at: p) else { return }
        let limit = IslandHitAreas.dropReach(targeting: navigator.isDropTargeting)
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
        if navigator.isOpen, let a = active, !isInside(a, pointerLocation) { navigator.close() }
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
        let allowed = center.primary.map { Pref.bool("activity.\($0.kind.rawValue).fullscreen", false) } ?? false
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
        let p = pointerLocation
        guard let c = controllers.first(where: { isInside($0, p, includingCards: false) }) else { return }
        // While the notch is open only its top strip counts: scrolling the content below must never close it.
        if navigator.isOpen {
            guard p.y >= IslandHitAreas.swipeStripTop(geometry: c.model.geometry, screenFrame: c.screenFrame) else { return }
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
                guard IslandMode.opens(geometry: c.model.geometry) else { return }   // a pill opens nothing here
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
