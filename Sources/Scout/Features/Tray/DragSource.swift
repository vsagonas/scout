import AppKit
import SwiftUI

/// Sits on top of a Tray cell and handles what SwiftUI can't do well: multi-file drags, modifier clicks
/// (⌘ and ⇧), double click and a right-click menu. Dragging is always a COPY: originals never move.
struct CellInteraction: NSViewRepresentable {
    var dragURLs: () -> [URL]
    var onMouseDown: (NSEvent.ModifierFlags) -> Void
    var onClickWithoutDrag: (NSEvent.ModifierFlags) -> Void
    var onDoubleClick: () -> Void
    var makeMenu: () -> NSMenu?

    func makeNSView(context: Context) -> InteractionView {
        let v = InteractionView()
        v.config = self
        return v
    }

    func updateNSView(_ view: InteractionView, context: Context) { view.config = self }

    final class InteractionView: NSView, NSDraggingSource {
        var config: CellInteraction?
        private var downEvent: NSEvent?
        private var dragged = false

        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            downEvent = event
            dragged = false
            if event.clickCount >= 2 { config?.onDoubleClick(); return }
            config?.onMouseDown(event.modifierFlags)
        }

        override func mouseUp(with event: NSEvent) {
            defer { downEvent = nil }
            guard !dragged, event.clickCount < 2 else { return }
            config?.onClickWithoutDrag(event.modifierFlags)
        }

        override func mouseDragged(with event: NSEvent) {
            guard !dragged, let down = downEvent, let urls = config?.dragURLs(), !urls.isEmpty else { return }
            let dx = event.locationInWindow.x - down.locationInWindow.x
            let dy = event.locationInWindow.y - down.locationInWindow.y
            guard hypot(dx, dy) > 4 else { return }
            dragged = true
            let items: [NSDraggingItem] = urls.enumerated().map { index, url in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 48, height: 48)
                let offset = CGFloat(min(index, 3)) * 4
                let origin = convert(down.locationInWindow, from: nil)
                item.setDraggingFrame(NSRect(x: origin.x - 24 + offset, y: origin.y - 24 - offset, width: 48, height: 48), contents: icon)
                return item
            }
            beginDraggingSession(with: items, event: down, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

        override func menu(for event: NSEvent) -> NSMenu? { config?.makeMenu() }
        override func rightMouseDown(with event: NSEvent) {
            if let menu = config?.makeMenu() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
        }
    }
}

/// An NSMenuItem that runs a closure.
final class BlockMenuItem: NSMenuItem {
    private let block: () -> Void

    init(_ title: String, symbol: String? = nil, _ block: @escaping () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { block() }
}
