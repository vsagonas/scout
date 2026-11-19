import AppKit
import SwiftUI

/// A small floating window that takes typing WITHOUT activating Scout, so the app you were in stays
/// frontmost (needed to paste back into it). Esc closes it.
final class FloatingPanel: NSPanel {
    var onClose: (() -> Void)?
    /// The id it was shown with (`Panels.show(id:)`): Windows (resume) tells panels apart by it.
    var panelID: String?
    /// Self-tests build panels far off screen (x -20000); AppKit would pull a titled window back onto a screen, so they ask it not to.
    var allowsOffscreen = false
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsOffscreen ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { close() }
    override func close() {
        super.close()
        onClose?()
    }
}

private struct PanelIDKey: EnvironmentKey { static let defaultValue: String? = nil }

extension EnvironmentValues {
    /// The id of the floating panel a view lives in (nil outside panels). Use `Panels.close(id)`.
    var panelID: String? {
        get { self[PanelIDKey.self] }
        set { self[PanelIDKey.self] = newValue }
    }
}

@MainActor
enum Panels {
    enum Position {
        /// Remembers where the user left it; first time near the pointer.
        case remembered
        case nearPointer
        case center
        case at(CGPoint)
    }

    struct Options {
        var size = CGSize(width: 360, height: 420)
        var minSize: CGSize?
        var resizable = true
        var position: Position = .remembered
        /// Close when the panel loses focus (pickers). Notes and chats stay.
        var closesWhenInactive = false
        var level: NSWindow.Level = .floating
        /// Prompter-style: hidden from screen sharing and recordings.
        var hiddenFromScreenSharing = false

        init(size: CGSize = CGSize(width: 360, height: 420), minSize: CGSize? = nil, resizable: Bool = true,
             position: Position = .remembered, closesWhenInactive: Bool = false,
             level: NSWindow.Level = .floating, hiddenFromScreenSharing: Bool = false) {
            self.size = size
            self.minSize = minSize
            self.resizable = resizable
            self.position = position
            self.closesWhenInactive = closesWhenInactive
            self.level = level
            self.hiddenFromScreenSharing = hiddenFromScreenSharing
        }
    }

    private static var panels: [String: FloatingPanel] = [:]
    private static var observers: [String: NSObjectProtocol] = [:]

    /// Shows (or brings forward) the panel `id`. The view draws its own background (e.g. `GlassBackground`).
    @discardableResult
    static func show<Content: View>(id: String, options: Options = Options(), @ViewBuilder content: () -> Content) -> FloatingPanel {
        if let existing = panels[id] {
            existing.makeKeyAndOrderFront(nil)
            return existing
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView, .nonactivatingPanel]
        if options.resizable { style.insert(.resizable) }
        let panel = FloatingPanel(contentRect: CGRect(origin: .zero, size: options.size), styleMask: style,
                                  backing: .buffered, defer: false)
        panel.panelID = id
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = options.level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        if let min = options.minSize { panel.contentMinSize = min }
        if options.hiddenFromScreenSharing { panel.sharingType = .none }

        let root = content().environment(\.panelID, id).retroStyleRoot()
        panel.contentView = NSHostingView(rootView: root)

        switch options.position {
        case .remembered:
            let name = "Scout.Panel.\(id)"
            if !panel.setFrameUsingName(name) { place(panel, nearPointerWith: options.size) }
            panel.setFrameAutosaveName(name)
        case .nearPointer:
            place(panel, nearPointerWith: options.size)
        case .center:
            panel.center()
        case .at(let point):
            panel.setFrameOrigin(point)
        }

        panel.onClose = {
            Panels.panels[id] = nil
            if let token = Panels.observers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(token) }
        }
        if options.closesWhenInactive {
            observers[id] = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { _ in
                MainActor.assumeIsolated { Panels.close(id) }
            }
        }
        panels[id] = panel
        panel.makeKeyAndOrderFront(nil)
        return panel
    }

    static func close(_ id: String) { panels[id]?.close() }

    static func isShown(_ id: String) -> Bool { panels[id]?.isVisible ?? false }

    static func panel(_ id: String) -> FloatingPanel? { panels[id] }

    static func toggle<Content: View>(id: String, options: Options = Options(), @ViewBuilder content: () -> Content) {
        if isShown(id) { close(id) } else { show(id: id, options: options, content: content) }
    }

    private static func place(_ panel: NSPanel, nearPointerWith size: CGSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { panel.center(); return }
        var origin = CGPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }
}

/// Standard header for floating panels: symbol, title, optional accessory, close button.
struct PanelHeader<Accessory: View>: View {
    let title: Text
    var symbol: String?
    var onClose: (() -> Void)?
    @ViewBuilder var accessory: () -> Accessory
    @Environment(\.panelID) private var panelID

    /// `PanelHeader("Calculator")` localizes a literal; `PanelHeader(verbatim: name)` shows a string as it is.
    init(_ title: LocalizedStringKey, symbol: String? = nil, onClose: (() -> Void)? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = Text(title)
        self.symbol = symbol
        self.onClose = onClose
        self.accessory = accessory
    }

    init(verbatim title: String, symbol: String? = nil, onClose: (() -> Void)? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = Text(verbatim: title)
        self.symbol = symbol
        self.onClose = onClose
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 8) {
            // The title side moves the window. Only there: an AppKit view under a SwiftUI button would take its clicks.
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).foregroundStyle(Theme.accent).allowsHitTesting(false) }
                title.font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize().allowsHitTesting(false)   // the title never gives way: the controls beside it shrink first
                Spacer(minLength: 4)
            }
            .background(WindowDragArea().padding(.top, -40).padding(.bottom, -8))   // up over the hidden title bar too
            accessory()
            Button {
                if let onClose { onClose() } else if let panelID { Panels.close(panelID) }
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.quaternary))
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

/// Behind a header: a press-and-drag there moves the window (the buttons on top keep their clicks).
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
