import AppKit
import SwiftUI

/// The borderless, non-activating panel that holds one notch. It keeps ONE fixed frame (big enough for the
/// open state and the cards); the SwiftUI content animates inside it.
final class NotchPanel: NSPanel {
    /// The window level every notch panel floats at (above other apps' windows, level with the menu bar's items). The Settings window sits one
    /// step above it while the notch is held open behind it (`SettingsNotchHold`).
    static let notchLevel: NSWindow.Level = .statusBar

    /// True only while the notch is open: then a click inside makes the panel key (so text fields can type)
    /// without activating Scout, and the app the user was in stays frontmost.
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// The default would push a window that touches the menu bar down by its height.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Self-tests give their offscreen panel its own navigator; the real panels use the shared one.
    var navigatorOverride: NotchNavigator?

    /// Esc: back to the dashboard first, then close the notch.
    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { (navigatorOverride ?? NotchNavigator.shared).escape() }
    }
}

/// One notch on one screen: its panel, its model, its SwiftUI view.
@MainActor
final class NotchController {
    let displayID: CGDirectDisplayID
    let model: NotchScreenModel
    let panel: NotchPanel
    private(set) var screenFrame: CGRect

    /// The panel is as tall as most of the screen (at most 1000 pt), so the island can be dragged down to read a long
    /// chat; outside the island and cards it ignores the mouse.
    static func panelHeight(for screen: NSScreen) -> CGFloat { min(max(720, screen.frame.height - 60), 1000) }
    static let panelWidth: CGFloat = 1400

    init(screen: NSScreen) {
        displayID = screen.displayID
        screenFrame = screen.frame
        let width = min(Self.panelWidth, screen.frame.width)
        let height = Self.panelHeight(for: screen)
        let size = CGSize(width: width, height: height)
        model = NotchScreenModel(geometry: NotchGeometry.make(for: screen), panelSize: size)
        let frame = CGRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height,
                           width: width, height: height)
        panel = NotchPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.level = NotchPanel.notchLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        let root = NotchRootView(model: model, center: .shared, navigator: .shared, nook: .shared)
        let hosting = NSHostingView(rootView: root.retroStyleRoot().modifier(NotchLeftToRight()))   // drawn around the physical camera notch: never mirrored (Arabic text inside still reads right to left)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        if #available(macOS 13.0, *) { hosting.sizingOptions = [] }
        panel.contentView = hosting
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
    }

    /// The panel-local rects as screen rects (bottom-left origin).
    func screenRect(of local: CGRect) -> CGRect {
        guard local.width > 0 else { return .zero }
        let f = panel.frame
        return CGRect(x: f.minX + local.minX, y: f.maxY - local.maxY, width: local.width, height: local.height)
    }

    /// The closed or open island in screen coordinates, a little generous (and reaching above the screen edge).
    var islandScreenRect: CGRect {
        var r = screenRect(of: model.islandRect)
        if r == .zero { r = fallbackNotchRect }
        return r.insetBy(dx: -4, dy: -3).union(CGRect(x: r.minX - 4, y: r.minY, width: r.width + 8, height: r.height + 8))
    }

    var cardScreenRects: [CGRect] { model.cardRects.map { screenRect(of: $0).insetBy(dx: -4, dy: -4) } }

    /// Where the hardware notch is, used before the view has reported its first layout.
    var fallbackNotchRect: CGRect {
        let size = model.geometry.size
        return CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width, height: size.height)
    }

    func teardown() {
        panel.ignoresMouseEvents = true
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
    }
}
