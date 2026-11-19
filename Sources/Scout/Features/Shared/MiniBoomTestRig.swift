import AppKit
import SwiftUI

// An offscreen panel that hosts one view, finds the controls it marks with `nookControl()` / `liveControl()`, clicks them with real mouse events and
// draws the view to a bitmap. The self-tests of the live panels and of the Ask AI line use it to check both looks (8-bit and minimal).

@MainActor
final class MiniBoomRig {
    final class Rects { var all: [CGRect] = [] }

    let size: CGSize
    let panel: NotchPanel
    let hosting: NSHostingView<AnyView>
    private let rects = Rects()

    /// `face`: draw the view on a dashboard panel's face (the live panels and the Ask AI line sit on one in the real dashboard).
    init(_ view: AnyView, size: CGSize, face: Bool = true) {
        self.size = size
        panel = NotchPanel(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.navigatorOverride = NotchNavigator()
        panel.isReleasedWhenClosed = false
        let box = rects
        let framed = view.environment(\.colorScheme, .dark).frame(width: size.width, height: size.height)
        let root = (face ? AnyView(framed.nookPanelFace()) : AnyView(framed))
            .coordinateSpace(name: "notchPanel")
            .onPreferenceChange(NookControlKey.self) { box.all = $0 }
        hosting = NSHostingView(rootView: AnyView(root))
        hosting.frame = CGRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.orderFrontRegardless()
    }

    var controls: [CGRect] { rects.all }

    private func post(_ type: NSEvent.EventType, _ p: CGPoint) {
        let location = CGPoint(x: p.x, y: size.height - p.y)
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                             pressure: type == .leftMouseUp ? 0 : 1) else { return }
        panel.sendEvent(event)
    }

    func click(_ rect: CGRect) async {
        let p = CGPoint(x: rect.midX, y: rect.midY)
        post(.leftMouseDown, p)
        post(.leftMouseUp, p)
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    /// The panel's picture, as bytes, and how many bytes differ from its first pixel (a blank picture has none).
    func picture() -> (bytes: Data, busy: Int)? {
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.bitmapData else { return nil }
        let count = rep.bytesPerRow * rep.pixelsHigh
        let first = (data[0], data[1], data[2])
        var busy = 0
        var i = 0
        while i + 3 < count {
            if data[i] != first.0 || data[i + 1] != first.1 || data[i + 2] != first.2 { busy += 1 }
            i += 4
        }
        return (Data(bytes: data, count: count), busy)
    }

    /// The first text field the view drew (the real field a person types into).
    func firstTextField() -> NSTextField? {
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return panel.contentView.flatMap(find)
    }

    func close() {
        panel.contentView = nil
        panel.orderOut(nil)
    }
}
