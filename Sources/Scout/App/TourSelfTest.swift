import AppKit
import SwiftUI

/// The tour's part of `look.selftest` (Notch/LookSelfTest.swift): the welcome tour in an offscreen window (nothing shows), real clicks on
/// its cards and keys, the pick written to its setting, the chosen card marked, the arrow keys, the window growing with the size, and the
/// pictures that ship with the app.
@MainActor
enum TourSelfTest {
    @MainActor private final class Rig {
        let window: NSWindow
        let model: OnboardingModel
        var finished = false

        /// The tour's real window (an `OnboardingWindow` shown offscreen).
        init(window: NSWindow, model: OnboardingModel) {
            self.window = window
            self.model = model
        }

        init(page: Int) {
            model = OnboardingModel(page: page)
            let size = OnboardingView.windowSize(for: Look.size, screen: nil)
            window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            let view = OnboardingView(model: model, onFinish: {}, onResize: { [weak window] size in
                if let window { window.setContentSize(OnboardingWindow.contentSize(for: window, layout: size)) }
            })
            window.contentView = NSHostingView(rootView: view)
            window.orderFrontRegardless()
        }

        var content: NSView { window.contentView ?? NSView() }
        /// The transparent title bar the tour's layout sits under.
        var topInset: CGFloat { content.safeAreaInsets.top }

        /// The window point (bottom-left origin) of the middle of a named card or key (the tour's points times the window's scaling).
        func point(_ name: String) -> CGPoint? {
            guard let r = model.rects[name] else { return nil }
            return CGPoint(x: r.midX * model.scale, y: content.bounds.height - (r.midY * model.scale + topInset))
        }

        func click(_ name: String) -> Bool {
            guard let p = point(name) else { return false }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                     pressure: type == .leftMouseUp ? 0 : 1) else { return false }
                window.sendEvent(event)
            }
            return true
        }

        /// The colour of the picture at a point just inside a card's left edge (where the pick's border is drawn).
        func edgeColour(_ name: String) -> (r: Double, g: Double, b: Double)? {
            guard let r = model.rects[name], let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
            content.cacheDisplay(in: content.bounds, to: rep)
            let sx = CGFloat(rep.pixelsWide) / content.bounds.width, sy = CGFloat(rep.pixelsHigh) / content.bounds.height
            let x = Int((r.minX + 2) * model.scale * sx), y = Int((r.midY * model.scale + topInset) * sy)
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
            return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }

        func close() {
            window.contentView = nil
            window.orderOut(nil)
        }
    }

    /// True when the colour is the tour's amber (a strong red and green, little blue); the unpicked border is a soft grey.
    private static func isAmber(_ c: (r: Double, g: Double, b: Double)?) -> Bool {
        guard let c else { return false }
        return c.r - c.b > 0.4
    }

    static func run(report: (String, Bool, String) -> Void, settle: (Double) async -> Void) async {
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { report(name, ok, detail) }
        UserDefaults.standard.removeObject(forKey: Look.scaleKey)
        UserDefaults.standard.removeObject(forKey: Look.presetKey)
        Pref.set(true, Retro.styleKey)

        // The pictures ship with the app, small.
        var missing: [String] = [], big: [String] = [], wrongShape: [String] = []
        for eightBit in [true, false] {
            for preset in Look.Preset.allCases {
                let name = TourPictures.name(eightBit: eightBit, preset: preset)
                guard let url = Bundle.main.url(forResource: name, withExtension: "png"), TourPictures.image(name) != nil else { missing.append(name); continue }
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if bytes > 400_000 { big.append("\(name) \(bytes / 1000) KB") }
                // The island exactly, at 2x: the width the tour cuts to, and the height the app opens the dashboard at (180 pt).
                if let rep = TourPictures.image(name)?.representations.first,
                   rep.pixelsWide != Int(LookGallery.pictureWidth * 2) || rep.pixelsHigh != Int(NotchPrefs.openHeight * 2) {
                    wrongShape.append("\(name) \(rep.pixelsWide) x \(rep.pixelsHigh) px")
                }
            }
        }
        check("the tour's four pictures (8-bit and minimal, dark and light) are in the app", missing.isEmpty, "missing \(missing)")
        check("  and each is a few hundred KB at most", big.isEmpty, big.joined(separator: ", "))
        check("  and each is the open island exactly: \(Int(LookGallery.pictureWidth)) x \(Int(NotchPrefs.openHeight)) pt (the height the app opens the dashboard at)",
              wrongShape.isEmpty && LookGallery.pictureHeight == CGFloat(NotchPrefs.openHeight), wrongShape.joined(separator: ", "))
        check("the tour has seven pages: welcome, look, size, colours, notch, permissions, done (the ring's page went with the ring)", OnboardingView.pageCount == 7
              && OnboardingView.lookPage == 1 && OnboardingView.sizePage == 2 && OnboardingView.colourPage == 3)

        // Page 2: the look.
        let look = Rig(page: OnboardingView.lookPage)
        await settle(0.8)
        check("the look page shows two cards, 8-bit and Minimal", look.model.rects["look.8bit"] != nil && look.model.rects["look.minimal"] != nil,
              "rects \(look.model.rects.keys.sorted())")
        check("  the 8-bit card is marked first (it is the default), the Minimal card is not", isAmber(look.edgeColour("look.8bit")) && !isAmber(look.edgeColour("look.minimal")),
              "8-bit \(String(describing: look.edgeColour("look.8bit"))), minimal \(String(describing: look.edgeColour("look.minimal")))")
        _ = look.click("look.minimal")
        await settle(0.5)
        check("a real click on the Minimal card writes the look (8-bit off)", !Pref.bool(Retro.styleKey, true), "8-bit \(Pref.bool(Retro.styleKey, true))")
        check("  and the mark moves to the Minimal card", isAmber(look.edgeColour("look.minimal")) && !isAmber(look.edgeColour("look.8bit")))
        _ = look.click("look.8bit")
        await settle(0.5)
        check("a real click on the 8-bit card writes it back (8-bit on)", Pref.bool(Retro.styleKey, false))
        check("an arrow key moves the pick: right is Minimal, left is 8-bit again", {
            look.model.arrow(1)
            let minimal = !Pref.bool(Retro.styleKey, true)
            look.model.arrow(-1)
            return minimal && Pref.bool(Retro.styleKey, false)
        }())
        // Continue goes to the size page.
        _ = look.click("next")
        await settle(0.5)
        check("Continue goes on to the size page", look.model.page == OnboardingView.sizePage, "page \(look.model.page)")

        // Page 3: the size, and the window growing with it.
        await settle(0.5)
        check("the size page shows Normal, Large and Extra large", ["size.normal", "size.large", "size.xlarge"].allSatisfy { look.model.rects[$0] != nil },
              "rects \(look.model.rects.keys.sorted())")
        let normalPreview = look.model.rects["size.preview"]?.width ?? 0
        for size in [Look.Size.large, .xlarge, .normal] {
            _ = look.click("size.\(size.rawValue)")
            await settle(0.6)
            let want = OnboardingView.windowSize(for: size, screen: nil)
            let have = CGSize(width: look.content.frame.width, height: look.content.frame.height - look.topInset)
            check("a real click on \(size.title) writes the size, and the tour window and its preview grow to match",
                  Look.size == size && abs(have.width - want.width) < 1 && abs(have.height - want.height) < 1
                    && abs((look.model.rects["size.preview"]?.width ?? 0) - normalPreview * size.factor) < 2,
                  "size \(Look.size), window \(have) want \(want), preview \(look.model.rects["size.preview"]?.width ?? 0) vs \(normalPreview) x \(size.factor)")
        }
        look.model.arrow(1)
        let afterArrow = Look.size
        look.model.arrow(-1)
        check("on the size page the arrow keys step Normal, Large and back", afterArrow == .large && Look.size == .normal, "after \(afterArrow), now \(Look.size)")

        // Page 4: the colours.
        look.model.page = OnboardingView.colourPage
        await settle(0.8)
        check("the colours page shows Dark and Light colourful", look.model.rects["colour.dark"] != nil && look.model.rects["colour.light"] != nil)
        check("  the Dark card is marked first", isAmber(look.edgeColour("colour.dark")) && !isAmber(look.edgeColour("colour.light")))
        _ = look.click("colour.light")
        await settle(0.5)
        check("a real click on Light colourful writes the colours, and the mark follows", Look.preset == .light && isAmber(look.edgeColour("colour.light")) && !isAmber(look.edgeColour("colour.dark")),
              "preset \(Look.preset)")
        _ = look.click("colour.dark")
        await settle(0.5)
        check("a real click on Dark writes it back", Look.preset == .dark)
        look.model.arrow(1)
        check("on the colours page the right arrow picks Light colourful", Look.preset == .light)
        look.model.arrow(-1)
        look.model.page = 0
        check("the arrow keys do nothing on the other pages (the key goes on to the system)", look.model.arrow(1) == false && look.model.arrow(-1) == false)
        look.close()

        await runWindow(check: check, settle: settle)
    }

    /// The tour's real window (`OnboardingWindow`), shown offscreen in rooms of our own: it opens in the middle of its screen's visible frame, stays
    /// in the middle as the size pick makes it grow and shrink, and is never partly outside the visible frame (a small screen shrinks it).
    private static func runWindow(check: (String, Bool, String) -> Void, settle: (Double) async -> Void) async {
        let keptOnboarded = UserDefaults.standard.object(forKey: "app.onboarded")   // finish() marks the tour as seen
        defer { UserDefaults.standard.set(keptOnboarded, forKey: "app.onboarded") }
        UserDefaults.standard.removeObject(forKey: Look.scaleKey)
        let rooms: [(String, CGRect)] = [
            ("a 1440 x 875 screen", CGRect(x: -20000, y: -20000, width: 1440, height: 875)),
            ("a second screen with its own origin (1920 x 1055)", CGRect(x: -23000, y: -19800, width: 1920, height: 1055)),
            ("a small screen (1280 x 650)", CGRect(x: -21000, y: -20400, width: 1280, height: 650)),
        ]
        func offset(_ f: CGRect, _ room: CGRect) -> CGFloat { max(abs(f.midX - room.midX), abs(f.midY - room.midY)) }   // a window origin rounds to whole points: under 1 pt is the middle
        func inside(_ f: CGRect, _ room: CGRect) -> Bool {
            f.minX >= room.minX - 0.5 && f.maxX <= room.maxX + 0.5 && f.minY >= room.minY - 0.5 && f.maxY <= room.maxY + 0.5
        }
        func describe(_ f: CGRect) -> String { NSStringFromRect(f) }

        for (name, room) in rooms {
            let tour = OnboardingWindow(room: { _ in room }, front: { $0.orderFrontRegardless() }, offscreen: true)
            tour.show(page: OnboardingView.sizePage)
            await settle(0.8)
            guard let window = tour.currentWindow, let model = tour.currentModel else {
                check("the tour opens (\(name))", false, "no window")
                continue
            }
            let rig = Rig(window: window, model: model)
            let opened = window.frame
            check("the tour opens in the middle of \(name), whole inside it", offset(opened, room) < 1 && inside(opened, room),
                  "frame \(describe(opened)) room \(describe(room))")
            for size in [Look.Size.large, .xlarge, .normal, .xlarge] {
                _ = rig.click("size.\(size.rawValue)")
                await settle(0.7)
                let f = window.frame
                let layout = OnboardingView.windowSize(for: size, room: room.size)
                let grown = abs(f.width - layout.width) < 1.5
                let ok = Look.size == size && offset(f, room) < 1 && inside(f, room) && grown
                check("  \(size.title): the window grows or shrinks to \(Int(layout.width)) wide and stays in the middle of \(name), whole inside it", ok,
                      "frame \(describe(f)) room \(describe(room)) want width \(layout.width) size \(Look.size)")
            }
            // A window the person moved to a corner keeps its place when it changes size, and still never leaves the visible frame.
            window.setFrameOrigin(CGPoint(x: room.maxX - window.frame.width + 300, y: room.minY - 200))
            _ = rig.click("size.large")
            await settle(0.7)
            let moved = window.frame
            check("  a window dragged half off the screen is brought fully inside when the size changes", inside(moved, room), "frame \(describe(moved)) room \(describe(room))")
            tour.finish()
            UserDefaults.standard.removeObject(forKey: Look.scaleKey)
        }

        // It opens at the size picked before (a saved Extra large), already in the middle.
        Pref.set(Look.Size.xlarge.rawValue, Look.scaleKey)
        let room = rooms[0].1
        let again = OnboardingWindow(room: { _ in room }, front: { $0.orderFrontRegardless() }, offscreen: true)
        again.show()
        await settle(0.5)
        if let f = again.currentWindow?.frame {
            check("the tour opens in the middle at a saved Extra large size too", offset(f, room) < 1 && inside(f, room), "frame \(describe(f)) room \(describe(room))")
        }
        again.finish()
        UserDefaults.standard.removeObject(forKey: Look.scaleKey)

        let big = OnboardingWindow.placed(size: CGSize(width: 900, height: 700), middle: CGPoint(x: 0, y: 0), in: CGRect(x: 100, y: 100, width: 800, height: 600))
        let corner = OnboardingWindow.placed(size: CGSize(width: 400, height: 300), middle: CGPoint(x: 1000, y: 1000), in: CGRect(x: 0, y: 0, width: 800, height: 600))
        let centre = OnboardingWindow.placed(size: CGSize(width: 400, height: 300), middle: CGPoint(x: 400, y: 300), in: CGRect(x: 0, y: 0, width: 800, height: 600))
        check("the placement keeps a frame around its middle, moves it inside the room, and keeps the top of one that is too big", centre == CGRect(x: 200, y: 150, width: 400, height: 300)
              && corner == CGRect(x: 400, y: 300, width: 400, height: 300) && big.maxY == 700 && big.minX == 100, "centre \(centre) corner \(corner) big \(big)")
    }
}
