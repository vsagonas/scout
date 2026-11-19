import AppKit
import SwiftUI

// B4 (P2) Clipboard bottom shelf: a full-width panel that slides up from the bottom of the screen on its own
// shortcut (`clip.shelfHotkey`, default ⇧⌘V). Same cards as the notch, larger. Esc or a click outside closes it.

final class ShelfPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class ClipboardShelfController {
    static let shared = ClipboardShelfController()

    static let height: CGFloat = 262

    private var panel: ShelfPanel?
    private var hotKey: HotKey?
    private var registered: String?
    private var outsideMonitor: Any?
    private var observer: NSObjectProtocol?
    private(set) var isShown = false
    private var token = UUID()

    func start() {
        guard !ScoutRuntime.isGallery else { return }
        registerHotKey()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerHotKey() }
        }
        DebugCommands.register("clipboard.shelf") { [weak self] p in
            if p["close"] == "1" { self?.hide() } else { self?.show() }
        }
        DebugCommands.register("clipboard.pause") { p in ClipboardStore.shared.isPaused = p["on"] != "0" }
    }

    private func registerHotKey() {
        let raw = UserDefaults.standard.string(forKey: "clip.shelfHotkey") ?? KeyCombo.shiftCommandV.stringValue
        guard raw != registered else { return }
        registered = raw
        hotKey = nil
        guard !raw.isEmpty, let combo = KeyCombo(string: raw) else { return }
        hotKey = HotKey(combo, onPress: { [weak self] in MainActor.assumeIsolated { self?.toggle() } })
    }

    func toggle() { isShown ? hide() : show() }

    func show() {
        guard !isShown else { return }
        isShown = true
        token = UUID()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        let target = NSRect(x: area.minX, y: area.minY, width: area.width, height: Self.height)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let hosting = NSHostingView(rootView: ClipboardShelfView(store: .shared, onClose: { [weak self] in self?.hide() }))
        hosting.sizingOptions = []
        panel.contentView = hosting
        if ScoutRuntime.reduceMotion {
            panel.setFrame(target, display: true)
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.15; panel.animator().alphaValue = 1 }
        } else {
            panel.alphaValue = 1
            panel.setFrame(target.offsetBy(dx: 0, dy: -Self.height), display: true)
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    func hide() {
        guard isShown, let panel else { return }
        isShown = false
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
        let t = UUID()
        token = t
        let done: () -> Void = { [weak self] in
            guard let self, self.token == t else { return }
            panel.orderOut(nil)
            panel.contentView = nil
        }
        if ScoutRuntime.reduceMotion {
            NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.12; panel.animator().alphaValue = 0 }, completionHandler: { MainActor.assumeIsolated { done() } })
        } else {
            let down = panel.frame.offsetBy(dx: 0, dy: -Self.height)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(down, display: true)
            }, completionHandler: { MainActor.assumeIsolated { done() } })
        }
    }

    private func makePanel() -> ShelfPanel {
        let p = ShelfPanel(contentRect: CGRect(x: 0, y: 0, width: 1000, height: Self.height), styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.onCancel = { [weak self] in self?.hide() }
        return p
    }
}

struct ClipboardShelfView: View {
    @ObservedObject var store: ClipboardStore
    var onClose: (() -> Void)?
    @State private var query = ""
    @State private var filter: ClipboardItem.Kind?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.clipboard").foregroundStyle(Theme.accent)
                Text("Clipboard").font(.system(size: 14, weight: .semibold))
                ProdSearchField(prompt: "Search clipboard", text: $query, focus: $searchFocused).frame(width: 240)
                ClipboardFilterChips(filter: $filter, large: true)
                Spacer()
                if store.isPaused { Label("Paused", systemImage: "pause.circle").font(.system(size: 11.5)).foregroundStyle(.orange) }
                Text("Esc to close").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            ClipboardCardStrip(store: store, query: query, filter: filter, cardWidth: 190, cardHeight: 168, large: true) { item in
                onClose?()
                // Let the shelf slide away so the app you were in is in front before the paste.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { store.pick(item) }
            }
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GlassBackground(UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 22, style: .continuous)))
        .onAppear { searchFocused = true }
    }
}
