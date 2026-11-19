import AppKit
import SwiftUI

/// `scout://mirror.selftest?out=<file>` (headless runs only, as its own build):
///   build/Scout.app/Contents/MacOS/Scout --automation --headless --run "scout://mirror.selftest?out=/tmp/mirror.txt" & PID=$!
/// then wait for the file and `kill $PID`. It never opens a camera: the zoom math runs on synthetic sizes, the camera rules run
/// against a stand-in driver that counts its calls, and the mouse checks click an OFFSCREEN Mirror drawing its stand-in face.
@MainActor
enum MirrorSelfTest {
    static func register() {
        DebugCommands.register("mirror.selftest") { params in
            guard ScoutRuntime.isAutomation else { return }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("mirror-selftest.txt")
            Task { @MainActor in
                let lines = await run()
                try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: A camera that only counts

    @MainActor private final class FakeCamera: MirrorCameraDriver {
        var authorization: MirrorAuthorization
        var accessCalls = 0
        var startCalls = 0
        var stopCalls = 0
        var snapshotCalls = 0
        var grantsAccess = true
        var holdAccess = false
        var holdStart = false
        var pendingAccess: (@MainActor (Bool) -> Void)?
        var pendingStart: (@MainActor (MirrorStartResult) -> Void)?

        init(_ authorization: MirrorAuthorization) { self.authorization = authorization }

        func requestAccess(_ done: @escaping @MainActor (Bool) -> Void) {
            accessCalls += 1
            if holdAccess { pendingAccess = done; return }
            if grantsAccess { authorization = .authorized }
            done(grantsAccess)
        }

        func devices() -> [MirrorModel.CameraInfo] { [] }

        func start(deviceID: String, _ done: @escaping @MainActor (MirrorStartResult) -> Void) {
            startCalls += 1
            if holdStart { pendingStart = done; return }
            done(.running(aspect: 16.0 / 9.0))
        }

        func stop() { stopCalls += 1 }

        func snapshot(_ done: @escaping @MainActor (CGImage?) -> Void) {
            snapshotCalls += 1
            let context = CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.setFillColor(CGColor(srgbRed: 0.5, green: 0.4, blue: 0.3, alpha: 1))
            context?.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
            done(context?.makeImage())
        }
    }

    // MARK: An offscreen Mirror to click

    @MainActor private final class Rig {
        let size = CGSize(width: 990, height: 320)
        let camera: FakeCamera
        let model: MirrorModel
        let tools = MirrorTools()
        let panel: NSPanel
        var holds: [Bool] = []

        init() {
            camera = FakeCamera(.authorized)
            model = MirrorModel(driver: camera, scripted: false)
            panel = NSPanel(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: MirrorScene(model: model, tools: tools).frame(width: size.width, height: size.height))
            hosting.frame = CGRect(origin: .zero, size: size)
            panel.contentView = hosting
            panel.orderFrontRegardless()
            tools.holdsOpen = { [unowned self] on in self.holds.append(on) }
        }

        /// Where the picture sits in the view (it fills the view by default; else the biggest 16:9 picture, centred).
        var picture: CGRect {
            let fit = MirrorScene.pictureSize(aspect: model.aspect, in: size, fill: UserDefaults.standard.object(forKey: MirrorScene.fillKey) as? Bool ?? true)
            return CGRect(x: (size.width - fit.width) / 2, y: (size.height - fit.height) / 2, width: fit.width, height: fit.height)
        }

        /// A point of the picture by its unit coordinates, in the view's top-left coordinates.
        func spot(_ u: CGPoint) -> CGPoint {
            let p = picture
            return CGPoint(x: p.minX + u.x * p.width, y: p.minY + u.y * p.height)
        }

        func post(_ type: NSEvent.EventType, _ p: CGPoint, clickCount: Int = 1) {
            let location = CGPoint(x: p.x, y: size.height - p.y)
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else { return }
            panel.sendEvent(event)
        }

        func click(_ p: CGPoint) {
            post(.leftMouseDown, p)
            post(.leftMouseUp, p)
        }

        func doubleClick(_ p: CGPoint) {
            click(p)
            post(.leftMouseDown, p, clickCount: 2)
            post(.leftMouseUp, p, clickCount: 2)
        }

        func drag(from a: CGPoint, to b: CGPoint) {
            post(.leftMouseDown, a)
            for i in 1...6 {
                let t = CGFloat(i) / 6
                post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
            post(.leftMouseUp, b)
        }

        func button(_ name: String) -> CGPoint? {
            guard let r = tools.buttonRects[name] else { return nil }
            return CGPoint(x: r.midX, y: r.midY)
        }

        func close() {
            panel.contentView = nil
            panel.orderOut(nil)
        }
    }

    private static func settle(_ seconds: Double = 0.4) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: The checks

    static func run() async -> [String] {
        var lines: [String] = []
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failed += 1 }
            lines.append("mirror selftest \(ok ? "ok  " : "FAIL") \(name)\(ok || detail.isEmpty ? "" : "  (\(detail))")")
        }
        func near(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 1e-9) -> Bool { abs(a - b) <= eps }
        func near(_ a: CGPoint, _ b: CGPoint, _ eps: CGFloat = 1e-9) -> Bool { near(a.x, b.x, eps) && near(a.y, b.y, eps) }
        func inside(_ z: MirrorZoom) -> Bool {
            let v = z.visible
            return v.minX >= -1e-9 && v.minY >= -1e-9 && v.maxX <= 1 + 1e-9 && v.maxY <= 1 + 1e-9
        }
        func describe(_ z: MirrorZoom) -> String { "scale \(z.scale), origin \(z.origin)" }

        // 0. The tab is registered: last, with its height, and the panel expands into it.
        check("the Mirror is the last tab by default, and the panel's detail is the Mirror",
              NotchPrefs.defaultTabOrder.last == .mirror && NotchPrefs.allTabsInOrder.last == .mirror && WidgetKind.mirror.detail == .mirror,
              "\(NotchPrefs.allTabsInOrder.map(\.rawValue))")
        check("  a saved tab list that was never edited gets the Mirror added at the end; an edited one does not",
              NotchPrefs.parseTabs("nook,agents,askAI", edited: false).last == .mirror && NotchPrefs.parseTabs("nook,agents,askAI", edited: true).last == .askAI)
        check("  the island opens at least 380 pt high for it", NotchPrefs.minimumOpenHeight(for: .mirror) >= 380)

        // 1. The zoom math, on synthetic sizes (a 570 x 320 picture).
        let size = CGSize(width: 570, height: 320)
        let spot = CGPoint(x: 142.5, y: 80)   // left quarter, upper quarter
        let u = MirrorZoom.unit(spot, in: size)
        check("pixels become unit points, and a point outside the view lands on its edge",
              near(u, CGPoint(x: 0.25, y: 0.25)) && near(MirrorZoom.unit(CGPoint(x: 285, y: 160), in: size), CGPoint(x: 0.5, y: 0.5))
                && near(MirrorZoom.unit(CGPoint(x: -30, y: 900), in: size), CGPoint(x: 0, y: 1)) && near(MirrorZoom.unit(.zero, in: .zero), CGPoint(x: 0.5, y: 0.5)))

        var z = MirrorZoom()
        z.click(at: u)
        check("a click zooms in around THAT spot (2×, the spot stays under the pointer)",
              near(z.scale, 2) && near(z.picturePoint(atView: u), u) && near(z.origin, CGPoint(x: -0.25, y: -0.25)), describe(z))
        let other = MirrorZoom.unit(CGPoint(x: 400, y: 200), in: size)
        var z2 = MirrorZoom()
        z2.click(at: other)
        check("  the same for another spot", near(z2.scale, 2) && near(z2.picturePoint(atView: other), other) && inside(z2), describe(z2))

        z.click(at: u)
        check("another click there goes to 3×, still around that spot", near(z.scale, 3) && near(z.picturePoint(atView: u), u) && inside(z), describe(z))
        let at3 = z
        z.click(at: u)
        check("  a further click stays at 3×", z == at3, describe(z))
        z.reset()
        check("double-click (or the 1× button) goes back to the whole picture: 1×, nothing moved", z == MirrorZoom() && near(z.scale, 1) && z.origin == .zero, describe(z))

        // Clamping at the four edges and four corners: the view never shows outside the picture.
        let edges: [(String, CGPoint, CGPoint)] = [
            ("left edge", CGPoint(x: 0, y: 0.5), CGPoint(x: 0, y: -0.5)),
            ("right edge", CGPoint(x: 1, y: 0.5), CGPoint(x: -1, y: -0.5)),
            ("top edge", CGPoint(x: 0.5, y: 0), CGPoint(x: -0.5, y: 0)),
            ("bottom edge", CGPoint(x: 0.5, y: 1), CGPoint(x: -0.5, y: -1)),
            ("top-left corner", CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0)),
            ("top-right corner", CGPoint(x: 1, y: 0), CGPoint(x: -1, y: 0)),
            ("bottom-left corner", CGPoint(x: 0, y: 1), CGPoint(x: 0, y: -1)),
            ("bottom-right corner", CGPoint(x: 1, y: 1), CGPoint(x: -1, y: -1)),
        ]
        for (name, at, expected) in edges {
            var e = MirrorZoom()
            e.click(at: at)
            check("a click on the \(name) zooms to 2× with that edge flush (nothing outside the picture)", near(e.origin, expected) && inside(e), describe(e))
        }
        var far = MirrorZoom()
        far.click(at: MirrorZoom.unit(CGPoint(x: 9000, y: -400), in: size))
        check("a click far outside the view counts as the nearest edge", near(far.origin, CGPoint(x: -1, y: 0)) && inside(far), describe(far))
        var corner3 = MirrorZoom()
        corner3.click(at: CGPoint(x: 1, y: 1))
        corner3.click(at: CGPoint(x: 1, y: 1))
        check("  and at 3× the corner stays flush", near(corner3.scale, 3) && near(corner3.origin, CGPoint(x: -2, y: -2)) && inside(corner3), describe(corner3))

        // Pan limits.
        var p = MirrorZoom.zoomed(2, around: CGPoint(x: 0.5, y: 0.5))
        p.pan(by: CGPoint(x: 5, y: 5))
        let topLeft = p.origin
        p.pan(by: CGPoint(x: -9, y: -9))
        let bottomRight = p.origin
        check("dragging far in any direction stops at the picture's edges (2×)", near(topLeft, .zero) && near(bottomRight, CGPoint(x: -1, y: -1)), "\(topLeft) \(bottomRight)")
        var p3 = MirrorZoom.zoomed(3, around: CGPoint(x: 0.3, y: 0.6))
        p3.pan(by: CGPoint(x: -9, y: 9))
        check("  at 3× the limits are 0 and -2", near(p3.origin, CGPoint(x: -2, y: 0)) && inside(p3), describe(p3))
        var move = MirrorZoom.zoomed(2, around: CGPoint(x: 0.5, y: 0.5))
        let before = move.origin
        move.pan(by: CGPoint(x: -0.1, y: 0.05))
        check("  a small drag moves the picture with the pointer", near(move.origin, CGPoint(x: before.x - 0.1, y: before.y + 0.05)), describe(move))
        var flat = MirrorZoom()
        flat.pan(by: CGPoint(x: 0.3, y: 0.3))
        check("  at 1× there is nothing to drag", flat == MirrorZoom())

        // Scroll / pinch: the spot under the pointer stays under it.
        var s = MirrorZoom()
        var kept = true
        let anchors = [CGPoint(x: 0.3, y: 0.6), CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.05, y: 0.95), CGPoint(x: 0.5, y: 0.5)]
        for anchor in anchors {
            for _ in 0..<4 {
                let under = s.picturePoint(atView: anchor)
                s.zoom(by: MirrorTools.scrollFactor(dy: 12, precise: true), around: anchor)
                if s.scale < MirrorZoom.maxScale - 0.001, !near(s.picturePoint(atView: anchor), under, 1e-9) { kept = false }
                if !inside(s) { kept = false }
            }
        }
        check("scroll zoom keeps the spot under the pointer, at four different spots, and never shows outside the picture", kept, describe(s))
        var pinch = MirrorZoom()
        let under = pinch.picturePoint(atView: CGPoint(x: 0.7, y: 0.4))
        pinch.zoom(by: 1.35, around: CGPoint(x: 0.7, y: 0.4))
        check("  a pinch does the same", near(pinch.picturePoint(atView: CGPoint(x: 0.7, y: 0.4)), under) && near(pinch.scale, 1.35))
        var out = MirrorZoom.zoomed(3, around: CGPoint(x: 0.9, y: 0.8))
        for _ in 0..<40 { out.zoom(by: 0.8, around: CGPoint(x: 0.9, y: 0.8)); if !inside(out) { kept = false } }
        check("  zooming out all the way ends exactly at 1×, never past it", out == MirrorZoom() && kept, describe(out))
        var capped = MirrorZoom()
        for _ in 0..<60 { capped.zoom(by: 1.3, around: CGPoint(x: 0.5, y: 0.5)) }
        check("  and zooming in stops at \(Int(MirrorZoom.maxScale))×", near(capped.scale, MirrorZoom.maxScale))
        check("a trackpad scroll up zooms in, down zooms out, and one wheel notch is a modest step",
              MirrorTools.scrollFactor(dy: 10, precise: true) > 1 && MirrorTools.scrollFactor(dy: -10, precise: true) < 1
                && MirrorTools.scrollFactor(dy: 1, precise: false) < 1.2 && MirrorTools.scrollFactor(dy: 9999, precise: true) <= exp(0.5) + 1e-9)

        // Flip.
        let click = CGPoint(x: 0.25, y: 0.5)
        var plain = MirrorZoom()
        var flipped = MirrorZoom()
        plain.click(at: click)
        flipped.click(at: click)
        check("flip does not change where a click zooms (the picture is already mirrored on screen)", plain == flipped)
        check("  the spot clicked in the mirrored picture is the mirrored spot of the camera's own image",
              near(MirrorZoom.sourcePoint(of: flipped.picturePoint(atView: click), flipped: true), CGPoint(x: 0.75, y: 0.5))
                && near(MirrorZoom.sourcePoint(of: plain.picturePoint(atView: click), flipped: false), CGPoint(x: 0.25, y: 0.5)))
        var scene = MirrorZoom.zoomed(3, around: CGPoint(x: 0.2, y: 0.3))
        let feature = CGPoint(x: 0.3, y: 0.55)   // a spot of the camera's own image
        let shownBefore = scene.origin.x + scene.scale * feature.x   // flip off: it shows at x = feature.x
        let regionBefore = scene.visible
        scene.mirrorHorizontally()   // flip switched on while zoomed
        let shownAfter = scene.origin.x + scene.scale * (1 - feature.x)
        check("switching the flip while zoomed keeps looking at the same part of the scene (the spot swaps sides, nothing outside)",
              near(shownAfter, 1 - shownBefore) && inside(scene) && near(1 - scene.visible.maxX, regionBefore.minX) && near(1 - scene.visible.minX, regionBefore.maxX) && near(scene.visible.minY, regionBefore.minY),
              "before \(shownBefore) after \(shownAfter)")
        var whole = MirrorZoom()
        whole.mirrorHorizontally()
        check("  at 1× the flip changes nothing in the zoom", whole == MirrorZoom())

        // 2. The tools: the ladder, easing off with Reduce Motion, freeze.
        let tools = MirrorTools()
        tools.stepZoom(1)
        let up1 = tools.zoom.scale
        tools.stepZoom(1)
        tools.stepZoom(1)
        let up3 = tools.zoom.scale
        for _ in 0..<9 { tools.stepZoom(1) }
        let top = tools.zoom.scale
        tools.stepZoom(-1)
        let down = tools.zoom.scale
        tools.doubleClick()
        check("+ / − walk 1× → 1.5× → 2× → 3× … 5× and back, around the centre; a double-click resets",
              near(up1, 1.5) && near(up3, 3) && near(top, 5) && near(down, 4) && tools.zoom == MirrorZoom() && tools.zoom.origin == .zero, "\(up1) \(up3) \(top) \(down)")
        tools.click(at: u)
        tools.setScale(4)
        tools.resetZoom()
        check("the slider and the 1× button land exactly on a scale", tools.zoom == MirrorZoom())

        // 3. The camera rules, against a camera that only counts. Scripted runs never start one.
        check("this is a scripted run, and the Mirror knows it", ScoutRuntime.isScripted && MirrorModel.shared.scripted)
        let real = MirrorModel.shared
        real.viewAppeared(autostart: true)
        real.start()
        check("in a scripted run the real model never starts the camera: it stays stopped, with no input on the session",
              real.state == .stopped && real.session?.isRunning == false && real.session?.inputs.isEmpty == true, "\(real.state)")
        real.viewDisappeared()
        let scriptedFake = FakeCamera(.authorized)
        let scriptedModel = MirrorModel(driver: scriptedFake, scripted: true)
        scriptedModel.viewAppeared(autostart: true)
        scriptedModel.start()
        scriptedModel.snapshot { _ in }
        check("  and a camera behind a scripted model is never touched: no start, no stop, no prompt, no frame",
              scriptedFake.startCalls == 0 && scriptedFake.accessCalls == 0 && scriptedFake.snapshotCalls == 0 && scriptedModel.state == .stopped)

        // Authorized: the tab and the panel share one session; it stops with the last of them.
        let cam = FakeCamera(.authorized)
        let model = MirrorModel(driver: cam, scripted: false)
        model.viewAppeared(autostart: true)
        check("allowed camera: the tab starts it when it appears", cam.startCalls == 1 && model.state == .running, "\(cam.startCalls) \(model.state)")
        model.viewAppeared(autostart: false)
        model.viewDisappeared()
        check("  the panel and the tab share ONE session: the second view starts nothing, and it keeps running while one is on screen",
              cam.startCalls == 1 && cam.stopCalls == 0 && model.state == .running && model.viewersOnScreen == 1)
        model.viewDisappeared()
        check("  it stops the moment the last view goes", cam.stopCalls == 1 && model.state == .stopped && model.viewersOnScreen == 0, "\(cam.stopCalls) \(model.state)")

        // Not allowed yet: macOS asks only on the click.
        let ask = FakeCamera(.notDetermined)
        let askModel = MirrorModel(driver: ask, scripted: false)
        askModel.viewAppeared(autostart: true)
        check("camera not decided yet: the tab starts nothing and asks nothing by itself", ask.startCalls == 0 && ask.accessCalls == 0 && askModel.state == .stopped)
        askModel.start()
        check("  the button asks macOS once, and the camera starts after \"Allow\"", ask.accessCalls == 1 && ask.startCalls == 1 && askModel.state == .running, "\(ask.accessCalls) \(ask.startCalls) \(askModel.state)")
        askModel.viewDisappeared()

        let late = FakeCamera(.notDetermined)
        late.holdAccess = true
        let lateModel = MirrorModel(driver: late, scripted: false)
        lateModel.viewAppeared(autostart: true)
        lateModel.start()
        let waiting = lateModel.state == .starting
        lateModel.viewDisappeared()
        late.authorization = .authorized
        late.pendingAccess?(true)
        check("\"Allow\" answered after the view is gone never turns the camera on", waiting && late.startCalls == 0 && lateModel.state == .stopped, "\(late.startCalls) \(lateModel.state)")

        let slow = FakeCamera(.authorized)
        slow.holdStart = true
        let slowModel = MirrorModel(driver: slow, scripted: false)
        slowModel.viewAppeared(autostart: true)
        slowModel.viewDisappeared()
        slow.pendingStart?(.running(aspect: 16.0 / 9.0))
        check("a camera that comes up after the view is gone is stopped again, and the model does not say running", slow.stopCalls >= 1 && slowModel.state == .stopped, "\(slow.stopCalls) \(slowModel.state)")

        // Denied: a line and "Open Settings"; allowed later in System Settings, it starts on the next visit.
        let denied = FakeCamera(.denied)
        let deniedModel = MirrorModel(driver: denied, scripted: false)
        deniedModel.viewAppeared(autostart: true)
        deniedModel.start()
        check("camera access refused: the model says denied and starts nothing", deniedModel.state == .denied && denied.startCalls == 0 && denied.accessCalls == 0)
        deniedModel.viewDisappeared()
        denied.authorization = .authorized
        deniedModel.viewAppeared(autostart: true)
        check("  allowed afterwards in System Settings: the next visit starts it", denied.startCalls == 1 && deniedModel.state == .running, "\(denied.startCalls) \(deniedModel.state)")
        deniedModel.viewDisappeared()

        // Freeze holds a frame in memory only while the camera runs.
        let frozenCam = FakeCamera(.authorized)
        let frozenModel = MirrorModel(driver: frozenCam, scripted: false)
        let frozenTools = MirrorTools()
        frozenTools.toggleFreeze(using: frozenModel)
        check("Freeze with no picture does nothing", frozenCam.snapshotCalls == 0 && frozenTools.frozen == nil && !frozenTools.isFrozen)
        frozenModel.viewAppeared(autostart: true)
        frozenTools.toggleFreeze(using: frozenModel)
        check("Freeze holds the current frame; pressing it again goes live", frozenCam.snapshotCalls == 1 && frozenTools.frozen != nil && frozenTools.isFrozen, "\(frozenCam.snapshotCalls)")
        frozenTools.toggleFreeze(using: frozenModel)
        check("  live again: the held frame is let go", frozenTools.frozen == nil && !frozenTools.isFrozen)
        frozenModel.viewDisappeared()

        // The still the Photo card asks for: the picture as the Mirror shows it (flip and zoom applied); nothing in scripted runs or with the camera off.
        func bands() -> CGImage? {
            guard let c = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            let colours: [CGColor] = [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 1, blue: 0, alpha: 1),
                                      CGColor(red: 0, green: 0, blue: 1, alpha: 1), CGColor(red: 1, green: 1, blue: 0, alpha: 1)]
            c.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
            for (i, colour) in colours.enumerated() {
                c.setFillColor(colour)
                c.fill(CGRect(x: i * 100, y: 100, width: 100, height: 100))   // the TOP half (the bitmap's origin is at the bottom)
            }
            return c.makeImage()
        }
        func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> String {
            var data = [UInt8](repeating: 0, count: 4)
            guard let c = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "?" }
            c.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
            return data[0] > 200 && data[1] < 60 && data[2] < 60 ? "red" : data[0] < 60 && data[1] > 200 && data[2] < 60 ? "green"
                : data[0] < 60 && data[1] < 60 && data[2] > 200 ? "blue" : data[0] > 200 && data[1] > 200 && data[2] < 60 ? "yellow"
                : abs(Int(data[0]) - Int(data[1])) < 6 && abs(Int(data[1]) - Int(data[2])) < 6 && data[0] > 90 && data[0] < 190 ? "grey" : "other \(data[0]),\(data[1]),\(data[2])"
        }
        if let raw = bands(), let plainStill = MirrorStill.render(raw, zoom: MirrorZoom(), flip: false), let flipStill = MirrorStill.render(raw, zoom: MirrorZoom(), flip: true),
           let zoomFlip = MirrorStill.render(raw, zoom: .zoomed(2, around: CGPoint(x: 0, y: 0)), flip: true),
           let zoomCorner = MirrorStill.render(raw, zoom: .zoomed(2, around: CGPoint(x: 1, y: 1)), flip: false) {
            check("a still at 1× is the camera's frame; with the flip on it is mirrored left to right",
                  plainStill.width == 400 && plainStill.height == 200 && pixel(plainStill, 10, 10) == "red" && pixel(plainStill, 390, 10) == "yellow"
                    && flipStill.width == 400 && pixel(flipStill, 10, 10) == "yellow" && pixel(flipStill, 390, 10) == "red",
                  "\(pixel(plainStill, 10, 10)) \(pixel(plainStill, 390, 10)) \(pixel(flipStill, 10, 10)) \(pixel(flipStill, 390, 10))")
            check("  a 2× still is the part the Mirror shows: flipped, the top-left of the screen is the camera's top-right (200 x 100 pixels)",
                  zoomFlip.width == 200 && zoomFlip.height == 100 && pixel(zoomFlip, 10, 10) == "yellow" && pixel(zoomFlip, 190, 10) == "blue" && pixel(zoomFlip, 10, 90) == "yellow",
                  "\(zoomFlip.width)x\(zoomFlip.height) \(pixel(zoomFlip, 10, 10)) \(pixel(zoomFlip, 190, 10)) \(pixel(zoomFlip, 10, 90))")
            check("  and a zoom on the bottom-right corner is the bottom-right of the frame",
                  zoomCorner.width == 200 && zoomCorner.height == 100 && pixel(zoomCorner, 10, 10) == "grey" && pixel(zoomCorner, 190, 90) == "grey",
                  "\(zoomCorner.width)x\(zoomCorner.height) \(pixel(zoomCorner, 10, 10))")
        } else {
            check("a still can be made from a frame", false)
        }
        let stillCam = FakeCamera(.authorized)
        let stillModel = MirrorModel(driver: stillCam, scripted: false)
        let stillTools = MirrorTools()
        let cameraOff = await MirrorCamera.still(model: stillModel, tools: stillTools, flip: true)
        stillModel.viewAppeared(autostart: true)
        let live = await MirrorCamera.still(model: stillModel, tools: stillTools, flip: true)
        stillTools.click(at: CGPoint(x: 0.5, y: 0.5))
        let zoomedLive = await MirrorCamera.still(model: stillModel, tools: stillTools, flip: false)
        stillTools.toggleFreeze(using: stillModel)
        let snapshotsBeforeHeld = stillCam.snapshotCalls
        let held = await MirrorCamera.still(model: stillModel, tools: stillTools, flip: true)
        check("the Mirror's still: nothing with the camera off, the frame when it runs (as zoomed), the held frame while frozen",
              cameraOff == nil && live?.width == 8 && live?.height == 4 && zoomedLive?.width == 4 && zoomedLive?.height == 2 && held != nil && stillCam.snapshotCalls == snapshotsBeforeHeld,
              "off \(cameraOff == nil) live \(String(describing: live?.width)) zoomed \(String(describing: zoomedLive?.width)) held \(held != nil)")
        stillModel.viewDisappeared()
        let scriptedStill = await MirrorCamera.currentStill()
        check("  in a scripted run there is no still at all", scriptedStill == nil)

        // 4. Real clicks on an offscreen Mirror (its stand-in face; the camera is a counting stand-in). Once in the 8-bit look, once in the minimal look
        // (the setting is put back as it was afterwards).
        let savedLook = UserDefaults.standard.object(forKey: Retro.styleKey)
        for eightBit in [true, false] {
        Pref.set(eightBit, Retro.styleKey)
        let look = eightBit ? "" : "[minimal look] "
        let rig = Rig()
        await settle(0.9)
        check(look + "the Mirror drew in the \(eightBit ? "8-bit" : "minimal") look", Retro.is8bit == eightBit)
        check(look + "the Mirror tab draws: the camera started by itself (it was allowed), the toolbar is there",
              rig.camera.startCalls == 1 && rig.model.state == .running && rig.button("snap") != nil && rig.button("zoomReset") != nil,
              "start \(rig.camera.startCalls), state \(rig.model.state), buttons \(rig.tools.buttonRects.keys.sorted())")
        let spot1 = CGPoint(x: 0.25, y: 0.25)
        rig.click(rig.spot(spot1))
        await settle(0.1)
        let zoomClick = rig.tools.zoom
        check(look + "a click on the picture zooms to 2× around the clicked spot", near(zoomClick.scale, 2, 1e-6) && near(zoomClick.picturePoint(atView: spot1), spot1, 2e-3), describe(zoomClick))
        rig.click(rig.spot(spot1))
        await settle(0.1)
        check(look + "  a second click on the same spot: 3×", near(rig.tools.zoom.scale, 3, 1e-6), describe(rig.tools.zoom))
        rig.doubleClick(rig.spot(CGPoint(x: 0.6, y: 0.5)))
        await settle(0.1)
        check(look + "  a double-click: back to 1×", rig.tools.zoom == MirrorZoom(), describe(rig.tools.zoom))
        // The display sits over the picture (LIVE in the top-left corner, the stamp at the bottom-left): it takes no click, the picture under it does.
        rig.click(CGPoint(x: rig.picture.minX + 44, y: rig.picture.minY + 34))
        await settle(0.1)
        let throughLive = rig.tools.zoom.scale
        rig.doubleClick(rig.spot(CGPoint(x: 0.6, y: 0.5)))
        await settle(0.1)
        rig.click(CGPoint(x: rig.picture.minX + 60, y: rig.picture.maxY - 30))
        await settle(0.1)
        let throughStamp = rig.tools.zoom.scale
        rig.doubleClick(rig.spot(CGPoint(x: 0.6, y: 0.5)))
        await settle(0.1)
        check(look + "the on-screen display takes no click: pressing where LIVE or the stamp is zooms the picture under it", near(throughLive, 2, 1e-6) && near(throughStamp, 2, 1e-6) && rig.tools.zoom == MirrorZoom(),
              "live spot \(throughLive), stamp spot \(throughStamp)")

        rig.click(rig.spot(CGPoint(x: 0.5, y: 0.5)))
        await settle(0.1)
        let originBeforeDrag = rig.tools.zoom.origin
        rig.holds = []
        rig.drag(from: rig.spot(CGPoint(x: 0.5, y: 0.4)), to: rig.spot(CGPoint(x: 0.3, y: 0.3)))
        await settle(0.1)
        let dragged = rig.tools.zoom
        check(look + "dragging while zoomed pans (and is not a click), holding the notch open until it lets go",
              near(dragged.scale, 2, 1e-6) && dragged.origin.x < originBeforeDrag.x - 0.05 && dragged.origin.y < originBeforeDrag.y - 0.05 && inside(dragged) && rig.holds == [true, false],
              "\(describe(dragged)), holds \(rig.holds)")
        rig.drag(from: rig.spot(CGPoint(x: 0.9, y: 0.9)), to: rig.spot(CGPoint(x: 0.05, y: 0.05)))
        await settle(0.1)
        check(look + "  dragging on past the edge stops at the edge", near(rig.tools.zoom.origin, CGPoint(x: -1, y: -1), 1e-6) && inside(rig.tools.zoom), describe(rig.tools.zoom))
        rig.doubleClick(rig.spot(CGPoint(x: 0.5, y: 0.5)))
        await settle(0.1)
        rig.holds = []
        rig.drag(from: rig.spot(CGPoint(x: 0.5, y: 0.5)), to: rig.spot(CGPoint(x: 0.3, y: 0.3)))
        check(look + "  at 1× a drag does nothing (no zoom, no pan, no hold)", rig.tools.zoom == MirrorZoom() && rig.holds.isEmpty, "\(describe(rig.tools.zoom)), holds \(rig.holds)")

        // Flip is a setting now (Settings › Mirror), not a key on the picture: switching it flips the live picture and zooms nothing.
        let flipBefore = Pref.bool(MirrorModel.Key.flip, true)
        Pref.set(!flipBefore, MirrorModel.Key.flip)
        await settle(0.2)
        let flipAfter = Pref.bool(MirrorModel.Key.flip, true)
        check(look + "no Flip key on the picture; the setting flips it and does not zoom", rig.button("flip") == nil && flipAfter != flipBefore && rig.tools.zoom == MirrorZoom(),
              "flip key \(rig.button("flip") != nil), flip \(flipBefore) -> \(flipAfter), \(describe(rig.tools.zoom))")
        Pref.set(flipBefore, MirrorModel.Key.flip)
        await settle(0.1)
        check(look + "  no Light key and no Freeze key in the toolbar",
              rig.button("light") == nil && rig.button("lightSlider") == nil && rig.button("freeze") == nil && rig.button("snap") != nil,
              "buttons \(rig.tools.buttonRects.keys.sorted())")
        if let plus = rig.button("zoomIn") { rig.click(plus) }
        await settle(0.1)
        let plusScale = rig.tools.zoom.scale
        if let reset = rig.button("zoomReset") { rig.click(reset) }
        await settle(0.1)
        check(look + "  + zooms in a step, the read-out button goes back to 1×", near(plusScale, 1.5, 1e-6) && rig.tools.zoom == MirrorZoom(), "\(plusScale) \(describe(rig.tools.zoom))")
        // Snap: one still of the picture goes on the clipboard (a private pasteboard here, never the real one) and flies into the Clipboard key.
        let testBoard = NSPasteboard(name: NSPasteboard.Name("com.vsag.Scout.selftest.snap.\(UUID().uuidString)"))
        let realBoard = MirrorSnap.pasteboard
        MirrorSnap.pasteboard = { testBoard }
        let flightsBefore = NotchFly.shared.last?.id
        if let snap = rig.button("snap") { rig.click(snap) }
        await settle(0.5)
        let png = testBoard.data(forType: .png)
        let snapped = png.flatMap { NSBitmapImageRep(data: $0) }
        let flight = NotchFly.shared.last
        check(look + "  Snap takes one still and puts it on the clipboard as a picture (PNG and TIFF), then flies it from the picture into the Clipboard key; no zoom",
              rig.camera.snapshotCalls == 1 && snapped != nil && (snapped?.pixelsWide ?? 0) > 0 && testBoard.data(forType: .tiff) != nil
                && flight != nil && flight?.id != flightsBefore && flight?.from == "mirror.picture" && flight?.to == "tab.clipboard" && rig.tools.zoom == MirrorZoom(),
              "snapshots \(rig.camera.snapshotCalls), png \(png?.count ?? 0), flight \(String(describing: flight?.from)) → \(String(describing: flight?.to))")
        MirrorSnap.pasteboard = realBoard
        testBoard.releaseGlobally()

        // The Share key: nothing is taken before the click; a click takes one still and delivers the polaroid made of it (a stand-in takes the
        // delivery here, so no share sheet ever opens), and it is not a click on the picture under it.
        var delivered: [(image: NSImage, anchored: Bool)] = []
        let realDeliver = MirrorShare.deliver, realAgents = MirrorShare.agentsProvider
        MirrorShare.deliver = { image, anchor in delivered.append((image, anchor?.window != nil)) }
        MirrorShare.agentsProvider = { MirrorPolaroid.sampleAgents(2) }
        let snapshotsBeforeShare = rig.camera.snapshotCalls
        check(look + "the Share key is in the toolbar, and no picture was taken or made before it is clicked",
              rig.button("share") != nil && delivered.isEmpty && snapshotsBeforeShare == 1, "share \(rig.button("share") != nil), delivered \(delivered.count), snapshots \(snapshotsBeforeShare)")
        if let share = rig.button("share") { rig.click(share) }
        await settle(0.7)
        var photoMiddle = (r: -1, g: -1, b: -1), whiteFrame = false
        if let made = delivered.first?.image, let cg = made.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            photoMiddle = MirrorPolaroidChecks.pixel(cg, CGPoint(x: MirrorPolaroid.photoRect.midX, y: MirrorPolaroid.photoRect.midY - 40))
            whiteFrame = MirrorPolaroidChecks.isWhite(MirrorPolaroidChecks.pixel(cg, CGPoint(x: 9, y: 200)))
        }
        check(look + "  a click on Share takes one still of the picture and delivers its polaroid (360 x 450 pt, the camera's colours in the square, a white frame), from the key; the picture is not zoomed",
              delivered.count == 1 && rig.camera.snapshotCalls == snapshotsBeforeShare + 1 && delivered.first?.image.size == MirrorPolaroid.size && delivered.first?.anchored == true
                && abs(photoMiddle.r - 128) < 14 && abs(photoMiddle.g - 102) < 14 && abs(photoMiddle.b - 77) < 14 && whiteFrame && rig.tools.zoom == MirrorZoom(),
              "delivered \(delivered.count), snapshots \(rig.camera.snapshotCalls), middle \(photoMiddle), white \(whiteFrame), \(describe(rig.tools.zoom))")
        MirrorShare.deliver = realDeliver
        MirrorShare.agentsProvider = realAgents

        // The camera stops with the view.
        let stopsBefore = rig.camera.stopCalls
        NotchNavigator.shared.isOpen = true
        await settle(0.1)
        NotchNavigator.shared.isOpen = false
        await settle(0.2)
        check(look + "the camera stops when the notch closes", rig.camera.stopCalls == stopsBefore + 1 && rig.model.state == .stopped, "stops \(rig.camera.stopCalls) vs \(stopsBefore), state \(rig.model.state)")
        rig.close()
        await settle(0.3)
        check(look + "and when the view is gone (the tab left): the count of views on screen is zero", rig.model.viewersOnScreen == 0, "viewers \(rig.model.viewersOnScreen)")
        }
        Pref.set(savedLook, Retro.styleKey)

        // 4b. Share shows the polaroid first, in a small window (offscreen here): the picture, Copy, Save…, Close and Share…, one step above the island.
        let preview = MirrorSharePreview(offscreen: true)
        if let photo = MirrorPolaroid.samplePhoto(), let polaroid = MirrorPolaroid.image(photo: photo, agents: MirrorPolaroid.sampleAgents(3)) {
            preview.show(polaroid)
            await settle(0.5)
            let w = preview.currentWindow
            let content = w?.contentView?.frame.size ?? .zero
            check("Share's preview: a small window of its own shows the polaroid (the picture at 0.8, the keys under it), above the island",
                  w != nil && w?.title == "Polaroid" && w?.level == SettingsNotchHold.aboveNotch
                    && abs(content.width - MirrorSharePreviewView.width) < 1 && content.height > MirrorPolaroid.size.height * 0.8 + 40,
                  "window \(w != nil), size \(content)")
            if let frameView = w?.contentView?.superview, let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: AppPaths.file("mirror-selftest.preview.png"))
            }
            preview.close()
            await settle(0.1)
            check("  Close hides it", preview.currentWindow == nil)
        } else {
            check("Share's preview: the sample polaroid is made", false)
        }

        // 5. The viewfinder: what the on-screen display says (plain data), never REC, the zoom label, the battery only with a battery.
        let utc = { () -> Calendar in var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC") ?? .current; return c }()
        let nov15 = DateComponents(calendar: utc, timeZone: utc.timeZone, year: 2026, month: 11, day: 15, hour: 22, minute: 41).date ?? Date()
        let osdLive = MirrorOSD.make(frozen: false, scale: 1, battery: nil, date: nov15, standIn: false, calendar: utc)
        check("the viewfinder says LIVE while the picture is live, with the date and time stamp, and nothing else (1x, no battery, a real camera)",
              osdLive.words == ["LIVE"] && osdLive.items.contains(.stamp(date: "2026-11-15", time: "22:41")) && osdLive.items.count == 2, "\(osdLive.items)")
        var everyWord: [String] = []
        for frozen in [false, true] {
            for scale in [CGFloat(1), 1.5, 2, 3, 5] {
                for battery in [nil, BatteryState.sample] as [BatteryState?] {
                    for standIn in [false, true] {
                        everyWord += MirrorOSD.make(frozen: frozen, scale: scale, battery: battery, date: nov15, standIn: standIn, calendar: utc).words
                    }
                }
            }
        }
        check("the display never says REC (nothing is recorded): over every state, zoom, battery and picture kind", !everyWord.contains { $0.uppercased().contains("REC") } && everyWord.contains("LIVE"),
              "\(Set(everyWord).sorted())")
        let osdHeld = MirrorOSD.make(frozen: true, scale: 1, battery: nil, date: nov15, standIn: false, calendar: utc)
        check("  while a frame is held it says FROZEN, not LIVE (it is not live then)", osdHeld.words == ["FROZEN"] && !osdHeld.items.contains(.live), "\(osdHeld.items)")
        check("  the zoom level shows only while zoomed: 2X, 3X, 1.5X; nothing at 1x or a hair above",
              MirrorOSD.zoomLabel(1) == nil && MirrorOSD.zoomLabel(1.02) == nil && MirrorOSD.zoomLabel(2) == "2X" && MirrorOSD.zoomLabel(3) == "3X"
                && MirrorOSD.zoomLabel(1.5) == "1.5X" && MirrorOSD.zoomLabel(5) == "5X")
        let zoomed = MirrorOSD.make(frozen: false, scale: 2, battery: nil, date: nov15, standIn: false, calendar: utc)
        check("  at 2x the display carries 2X next to LIVE", zoomed.words == ["LIVE", "2X"], "\(zoomed.words)")
        let withBattery = MirrorOSD.make(frozen: false, scale: 1, battery: BatteryState(level: 78, isCharging: false, isPluggedIn: true, isCharged: false, minutesRemaining: nil), date: nov15, standIn: false, calendar: utc)
        let overfull = MirrorOSD.make(frozen: false, scale: 1, battery: BatteryState(level: 140, isCharging: false, isPluggedIn: false, isCharged: false, minutesRemaining: nil), date: nov15, standIn: false, calendar: utc)
        check("  the battery glyph shows only when the Mac has a battery, with its level and whether it is plugged in",
              !osdLive.items.contains { if case .battery = $0 { true } else { false } } && withBattery.items.contains(.battery(level: 78, charging: true))
                && overfull.items.contains(.battery(level: 100, charging: false)), "\(withBattery.items)")
        check("  the glyph's colour follows the level (green, yellow, red)", MirrorBatteryGlyph.color(level: 80) == Retro.Ink.ledGreen && MirrorBatteryGlyph.color(level: 30) == Retro.Ink.ledYellow
                && MirrorBatteryGlyph.color(level: 10) == Retro.Ink.ledRed)
        let midnight = DateComponents(calendar: utc, timeZone: utc.timeZone, year: 2027, month: 1, day: 2, hour: 0, minute: 5).date ?? Date()
        check("  the stamp is the date and the 24-hour time, two digits each", MirrorOSD.stamp(midnight, calendar: utc) == (date: "2027-01-02", time: "00:05")
                && MirrorOSD.stamp(nov15, calendar: utc) == (date: "2026-11-15", time: "22:41"))
        check("  a drawn stand-in picture says so; a real camera's does not", MirrorOSD.make(frozen: false, scale: 1, battery: nil, date: nov15, standIn: true, calendar: utc).items.contains(.sample)
                && !osdLive.items.contains(.sample))
        check("NO SIGNAL static only where there is no picture to see (camera off, no access, none found); never over a picture, not while starting",
              MirrorSignalRule.showsStatic(for: .stopped) && MirrorSignalRule.showsStatic(for: .denied) && MirrorSignalRule.showsStatic(for: .noCamera)
                && !MirrorSignalRule.showsStatic(for: .running) && !MirrorSignalRule.showsStatic(for: .starting))

        lines.append("mirror selftest done: \(failed == 0 ? "all passed" : "\(failed) FAILED")")
        return lines
    }
}
