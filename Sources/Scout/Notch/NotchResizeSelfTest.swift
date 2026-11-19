import AppKit
import SwiftUI

/// `scout://notch.selftest.resize?out=<file>` (automation runs): drags the open island's bottom grip with real
/// mouse events in an OFFSCREEN window (nothing shows, the pointer never moves) and reports the heights.
@MainActor
enum NotchResizeSelfTest {
    private static var window: NSWindow?

    static func run(out: URL) {
        let size = CGSize(width: 1120, height: 900)
        let model = NotchScreenModel(geometry: .sample16, panelSize: size)
        model.isOpen = true
        let navigator = NotchNavigator()
        navigator.workspace = .calendar
        navigator.setDraggedHeight(nil, for: .calendar, save: false)
        navigator.resizeMax = 600   // case 1: the workspace has more to show, up to 600
        let root = NotchRootView(model: model, center: LiveActivityCenter(), navigator: navigator, nook: NookStore(persist: false, layout: nil))
        let w = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: root)
        w.orderFrontRegardless()
        window = w
        var lines: [String] = []
        func height() -> CGFloat { model.islandRect.height }
        func drag(_ dy: CGFloat, then: @escaping () -> Void) {
            let x = size.width / 2, y = size.height - (height() - 9)
            post(w, .leftMouseDown, CGPoint(x: x, y: y))
            for step in 1...10 { post(w, .leftMouseDragged, CGPoint(x: x, y: y - dy * CGFloat(step) / 10)) }
            post(w, .leftMouseUp, CGPoint(x: x, y: y - dy))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                then()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            lines.append("more to show (limit 600): island before \(height())")
            drag(150) {
                lines.append("  dragged down 150: island \(height())")
                drag(500) {
                    lines.append("  dragged down 500 more: island \(height()) (stops at the content)")
                    let x = size.width / 2, y = size.height - (height() - 9)
                    post(w, .leftMouseDown, CGPoint(x: x, y: y), clicks: 1); post(w, .leftMouseUp, CGPoint(x: x, y: y), clicks: 1)
                    post(w, .leftMouseDown, CGPoint(x: x, y: y), clicks: 2); post(w, .leftMouseUp, CGPoint(x: x, y: y), clicks: 2)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        lines.append("  double-click: island \(height())")
                        navigator.resizeMax = nil   // case 2: everything fits, so there is no grip
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            lines.append("nothing more to show: island before \(height())")
                            drag(150) {
                                lines.append("  dragged down 150: island \(height()) (unchanged: no grip)")
                                try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
                                w.orderOut(nil)
                                window = nil
                            }
                        }
                    }
                }
            }
        }
    }

    static func post(_ w: NSWindow, _ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1) {
        guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                                         pressure: type == .leftMouseUp ? 0 : 1) else { return }
        NSApp.postEvent(e, atStart: false)
    }
}

/// `scout://panel.selftest.drag?out=<file>` (automation runs): an OFFSCREEN panel with the standard header; reports which
/// view a click on the header's empty middle reaches (it must be the drag area) and which a click on the close button reaches.
@MainActor
enum PanelDragSelfTest {
    private static var window: NSWindow?

    static func run(out: URL) {
        let size = CGSize(width: 440, height: 300)
        let w = FloatingPanel(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.contentView = NSHostingView(rootView: ToolPanelFrame("Ask AI", symbol: "sparkles") { Color.clear.frame(height: 240) })
        w.orderFrontRegardless()
        window = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let frameView = w.contentView?.superview
            func name(_ p: CGPoint) -> String { frameView?.hitTest(p).map { String(describing: type(of: $0)) } ?? "nil" }
            func allViews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allViews) }
            let dragFrame = (frameView.map(allViews)?.first { $0 is WindowDragArea.DragView }).map { $0.convert($0.bounds, to: nil) } ?? .zero
            let headerY = dragFrame.minY + 14
            func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
            let drags = frameView.map(all)?.filter { $0 is WindowDragArea.DragView } ?? []
            let where_ = drags.map { NSStringFromRect($0.convert($0.bounds, to: nil)) }.joined(separator: " ")
            let row = stride(from: 20.0, through: Double(size.width) - 20, by: 40).map { x in "\(Int(x)):\(name(CGPoint(x: x, y: headerY)).prefix(8))" }.joined(separator: " ")
            let lines = ["drag views: \(drags.count) at \(where_)", "header row: \(row)",
                         "header middle: \(name(CGPoint(x: size.width / 2, y: headerY)))",
                         "top strip: \(name(CGPoint(x: size.width / 2, y: size.height - 8)))",
                         "close button: \(name(CGPoint(x: size.width - 24, y: headerY)))",
                         "content: \(name(CGPoint(x: size.width / 2, y: 100)))",
                         "movable \(w.isMovable)"]
            try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
            w.orderOut(nil)
            window = nil
        }
    }
}
