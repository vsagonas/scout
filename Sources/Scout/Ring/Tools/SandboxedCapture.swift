import AppKit
import ScreenCaptureKit
import SwiftUI

// The App Store edition's screenshot engine (the full edition keeps using /usr/sbin/screencapture).
// ScreenCaptureKit takes the picture; Scout draws the small full-screen overlays for Region and Window itself.
// Nothing here runs in scripted runs, and nothing asks for Screen Recording until the user takes a screenshot.

#if APPSTORE

/// What the user chose in an overlay.
enum CapturePick {
    /// A region of one screen: `rect` is in that screen's own points, origin top-left (what ScreenCaptureKit's `sourceRect` wants).
    case region(screen: NSScreen, rect: CGRect)
    case window(CGWindowID)
}

@MainActor
enum SandboxedCapture {
    private static var overlay: CaptureOverlay?

    /// Takes a screenshot of the given kind and hands the picture to `done` (on the main actor). Cancelling gives no call.
    static func capture(_ mode: ScreenshotTool.Mode, done: @escaping (CGImage, CGFloat) -> Void) {
        guard ensureAccess() else { return }
        switch mode {
        case .screen:
            let screen = screenUnderPointer()
            run(done) { try await shoot(screen: screen, rect: nil) }
        case .region, .window:
            let overlay = CaptureOverlay(mode: mode == .region ? .region : .window) { pick in
                Self.overlay = nil
                guard let pick else { return }
                // A moment for the overlay to leave the screen before the picture is taken.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    switch pick {
                    case .region(let screen, let rect):
                        run(done) { try await shoot(screen: screen, rect: rect) }
                    case .window(let id):
                        run(done) { try await shoot(windowID: id) }
                    }
                }
            }
            Self.overlay = overlay
            overlay.show()
        }
    }

    // MARK: Permission

    /// Screen Recording is asked here, on the user's click, once. Without it the user is told what to do.
    private static func ensureAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        _ = CGRequestScreenCaptureAccess()
        Toast.show("Allow Scout under Screen Recording in System Settings, then try again", symbol: "lock.shield", style: .warning, duration: 4)
        return false
    }

    // MARK: Taking the picture

    private static func run(_ done: @escaping (CGImage, CGFloat) -> Void, _ work: @escaping () async throws -> (CGImage, CGFloat)) {
        Task { @MainActor in
            do {
                let (image, scale) = try await work()
                done(image, scale)
            } catch {
                Toast.show("Couldn't take the screenshot. Check Screen Recording in System Settings.", symbol: "exclamationmark.triangle.fill", style: .error, duration: 3.5)
            }
        }
    }

    private static func screenUnderPointer() -> NSScreen {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private static func ownWindows(in content: SCShareableContent) -> [SCWindow] {
        content.windows.filter { $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier }
    }

    private static func shoot(screen: NSScreen, rect: CGRect?) async throws -> (CGImage, CGFloat) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let id = displayID(of: screen), let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.noDisplay }
        let scale = screen.backingScaleFactor
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows(in: content))
        let config = SCStreamConfiguration()
        let size = rect?.size ?? CGSize(width: display.width, height: display.height)
        config.width = max(1, Int((size.width * scale).rounded()))
        config.height = max(1, Int((size.height * scale).rounded()))
        if let rect { config.sourceRect = rect }
        config.showsCursor = false
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }

    private static func shoot(windowID: CGWindowID) async throws -> (CGImage, CGFloat) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw CaptureError.noWindow }
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let primaryHeight = NSScreen.screens[0].frame.height
        let cocoaCenter = CGPoint(x: center.x, y: primaryHeight - center.y)
        let scale = (NSScreen.screens.first { NSMouseInRect(cocoaCenter, $0.frame, false) } ?? NSScreen.main)?.backingScaleFactor ?? 2
        let config = SCStreamConfiguration()
        config.width = max(1, Int((window.frame.width * scale).rounded()))
        config.height = max(1, Int((window.frame.height * scale).rounded()))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        return (image, scale)
    }

    private enum CaptureError: Error { case noDisplay, noWindow }
}

// MARK: - The selection overlay

/// A dimmed full-screen layer on every display. Region: drag a rectangle. Window: point at a window and click.
/// Esc or a click without dragging cancels.
@MainActor
final class CaptureOverlay {
    enum Mode { case region, window }

    private let mode: Mode
    private let finish: (CapturePick?) -> Void
    private var panels: [CapturePanel] = []
    private var views: [CaptureOverlayView] = []
    private var keyMonitor: Any?
    private var finished = false
    /// The window under the pointer (Window mode), in global Cocoa coordinates (origin bottom-left).
    private var highlight: CGRect?
    private var highlightID: CGWindowID?

    init(mode: Mode, finish: @escaping (CapturePick?) -> Void) {
        self.mode = mode
        self.finish = finish
    }

    func show() {
        for screen in NSScreen.screens {
            let panel = CapturePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.acceptsMouseMovedEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = CaptureOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size), mode: mode, screen: screen, owner: self)
            panel.contentView = view
            panel.setFrame(screen.frame, display: false)
            panel.orderFrontRegardless()
            panels.append(panel)
            views.append(view)
        }
        panels.first { $0.frame.contains(NSEvent.mouseLocation) }?.makeKey()
        NSCursor.crosshair.push()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Esc
            MainActor.assumeIsolated { self?.end(nil) }
            return nil
        }
        if mode == .window { updateHighlight(at: NSEvent.mouseLocation) }
    }

    // MARK: Called by the views

    func end(_ pick: CapturePick?) {
        guard !finished else { return }
        finished = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        NSCursor.pop()
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
        finish(pick)
    }

    func updateHighlight(at point: CGPoint) {
        let hit = CaptureOverlay.windowUnder(point)
        highlight = hit?.frame
        highlightID = hit?.id
        views.forEach { $0.needsDisplay = true }
    }

    func chooseHighlightedWindow() {
        if let id = highlightID { end(.window(id)) } else { end(nil) }
    }

    var highlightRect: CGRect? { highlight }

    // MARK: Which window is under the pointer

    /// The frontmost normal window under `point` (global Cocoa coordinates), skipping Scout's own. Names are not needed,
    /// so no Screen Recording permission is involved in this lookup.
    private static func windowUnder(_ point: CGPoint) -> (id: CGWindowID, frame: CGRect)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let primaryHeight = NSScreen.screens[0].frame.height
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  (info[kCGWindowOwnerPID as String] as? Int32) != getpid(),
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 40, bounds.height >= 40 else { continue }
            let cocoa = CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            if cocoa.contains(point) { return (id, cocoa) }
        }
        return nil
    }
}

private final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class CaptureOverlayView: NSView {
    private let mode: CaptureOverlay.Mode
    private let screen: NSScreen
    private unowned let owner: CaptureOverlay
    private var start: CGPoint?
    private var current: CGPoint?
    private var tracking: NSTrackingArea?
    /// Gallery only: draw this hole instead of a live selection.
    var previewHole: CGRect?

    init(frame: CGRect, mode: CaptureOverlay.Mode, screen: NSScreen, owner: CaptureOverlay) {
        self.mode = mode
        self.screen = screen
        self.owner = owner
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        if mode == .window { owner.updateHighlight(at: NSEvent.mouseLocation) }
    }

    override func mouseDown(with event: NSEvent) {
        if mode == .window { owner.chooseHighlightedWindow(); return }
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .region else { return }
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .region, let rect = selection else { return }
        start = nil
        current = nil
        guard rect.width >= 4, rect.height >= 4 else { owner.end(nil); return }
        // View coordinates have their origin bottom-left; ScreenCaptureKit wants the screen's own points from the top-left.
        let local = CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
        owner.end(.region(screen: screen, rect: local))
    }

    private var selection: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(start.x - current.x), height: abs(start.y - current.y))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let hole: CGRect?
        if let previewHole {
            hole = previewHole
        } else {
            switch mode {
            case .region:
                hole = selection
            case .window:
                hole = owner.highlightRect.map { global in
                    // Global Cocoa coordinates → this view (the screen's frame origin is the view's origin).
                    CGRect(x: global.minX - screen.frame.minX, y: global.minY - screen.frame.minY, width: global.width, height: global.height)
                }
        }
        }
        let dim = NSBezierPath(rect: bounds)
        if let hole { dim.append(NSBezierPath(rect: hole)) }
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.28).setFill()
        dim.fill()
        guard let hole, hole.intersects(bounds) else { return }
        if mode == .window {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(rect: hole).fill()
        }
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: hole.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
        if mode == .region { drawSize(of: hole) }
    }

    private func drawSize(of rect: CGRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attributes)
        let pill = CGRect(x: rect.maxX - size.width - 14, y: max(rect.minY - size.height - 10, 4), width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        text.draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 3), withAttributes: attributes)
    }
}


/// Gallery only: the overlay drawn with a fixed selection (Region) or highlighted window (Window).
struct CaptureOverlayPreview: NSViewRepresentable {
    let window: Bool
    let hole: CGRect

    /// Keeps the overlay alive: the view only holds an unowned reference to it.
    final class Holder { var overlay: CaptureOverlay? }

    func makeCoordinator() -> Holder { Holder() }

    func makeNSView(context: Context) -> NSView {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let overlay = CaptureOverlay(mode: window ? .window : .region) { _ in }
        context.coordinator.overlay = overlay
        let view = CaptureOverlayView(frame: CGRect(x: 0, y: 0, width: 520, height: 320), mode: window ? .window : .region, screen: screen, owner: overlay)
        view.previewHole = hole
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

#endif
