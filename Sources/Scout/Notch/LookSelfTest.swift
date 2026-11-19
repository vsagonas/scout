import AppKit
import SwiftUI

/// `scout://look.selftest?out=<file>` (headless, its own build: `--automation --headless --run …`, then `kill $PID`).
/// The appearance settings (Core/Retro/ScoutLook.swift): the defaults (8-bit on, normal, dark); the open island is bigger by the size
/// factor and stays flush with the screen edge while real clicks (a tab key, a panel, the Ask AI field) still land at every size; the
/// light preset makes the island and its panels light with dark text; the closed notch stays black; and the welcome tour's pages write
/// the settings from real clicks on their cards. Synthetic data only; the three settings are put back when the run ends.
@MainActor
enum LookSelfTest {
    static func register() {
        DebugCommands.register("look.selftest") { params in
            guard ScoutRuntime.isAutomation else { return }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("look-selftest.txt")
            Task { @MainActor in await run(out: out) }
        }
    }

    // MARK: The rig: an offscreen notch (a real panel, real mouse events), nothing shows

    @MainActor final class Rig {
        let size: CGSize
        let model: NotchScreenModel
        let navigator = NotchNavigator()
        let nook: NookStore
        let panel: NotchPanel

        init(size: CGSize = CGSize(width: 1500, height: 900), open: Bool = true, layout: [WidgetKind] = [.agents, .askAI, .pulse, .today],
             view: ((WidgetKind) -> AnyView?)? = nil, widthCap: CGFloat? = nil) {
            self.size = size
            model = NotchScreenModel(geometry: .sample16, panelSize: size)
            model.isOpen = open
            navigator.isOpen = open
            nook = NookStore(persist: false, layout: layout)
            nook.liveOverride = NookLive(playing: false, agents: 0)
            nook.tabIDs = { [] }
            if let view { nook.viewOverride = { item in if case .panel(let kind) = item { return view(kind) } else { return nil } } }
            panel = NotchPanel(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.navigatorOverride = navigator
            panel.isReleasedWhenClosed = false
            let root = NotchRootView(model: model, center: LiveActivityCenter(), navigator: navigator, nook: nook, styleOverride: .classic, widthCapOverride: widthCap)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = CGRect(origin: .zero, size: size)
            panel.contentView = hosting
            panel.orderFrontRegardless()
        }

        var island: CGRect { model.islandRect }
        func rect(_ name: String) -> CGRect? { model.panelRects[name] }

        func post(_ type: NSEvent.EventType, _ p: CGPoint) {
            let location = CGPoint(x: p.x, y: size.height - p.y)
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else { return }
            panel.sendEvent(event)
        }

        func click(_ p: CGPoint) {
            post(.leftMouseDown, p)
            post(.leftMouseUp, p)
        }

        func firstTextField() -> NSTextField? {
            func find(_ view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, field.isEditable { return field }
                for sub in view.subviews { if let found = find(sub) { return found } }
                return nil
            }
            return panel.contentView.flatMap(find)
        }

        /// The picture as the panel draws it (panel-local points, top-left origin).
        func snapshot() -> Pixels? {
            guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.layoutSubtreeIfNeeded()
            view.cacheDisplay(in: view.bounds, to: rep)
            return Pixels(rep: rep, points: view.bounds.size)
        }

        func close() {
            panel.contentView = nil
            panel.orderOut(nil)
        }
    }

    /// A drawn picture to read pixels from, addressed in points (top-left origin).
    struct Pixels {
        let rep: NSBitmapImageRep
        let points: CGSize

        func luminance(_ p: CGPoint) -> Double {
            let x = min(rep.pixelsWide - 1, max(0, Int(p.x / points.width * CGFloat(rep.pixelsWide))))
            let y = min(rep.pixelsHigh - 1, max(0, Int(p.y / points.height * CGFloat(rep.pixelsHigh))))
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 0.5 }
            return 0.299 * Double(c.redComponent) + 0.587 * Double(c.greenComponent) + 0.114 * Double(c.blueComponent)
        }

        /// The darkest and the brightest luminance inside `r` (points).
        func range(in r: CGRect) -> (dark: Double, bright: Double) {
            var dark = 1.0, bright = 0.0
            let step = 0.5
            var y = r.minY
            while y < r.maxY {
                var x = r.minX
                while x < r.maxX {
                    let l = luminance(CGPoint(x: x, y: y))
                    dark = min(dark, l)
                    bright = max(bright, l)
                    x += step
                }
                y += step
            }
            return (dark, bright)
        }
    }

    static func settle(_ seconds: Double = 0.5) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: The settings, put back at the end

    private static let keys = [Retro.styleKey, Look.scaleKey, Look.presetKey, "app.onboarded"]

    private static func saved() -> [String: Any] {
        var kept: [String: Any] = [:]
        for key in keys { if let v = UserDefaults.standard.object(forKey: key) { kept[key] = v } }
        return kept
    }

    private static func restore(_ kept: [String: Any]) {
        for key in keys {
            if let v = kept[key] { UserDefaults.standard.set(v, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    // MARK: Run

    static func run(out: URL) async {
        var lines: [String] = []
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failed += 1 }
            lines.append("look selftest \(ok ? "ok  " : "FAIL") \(name)\(ok || detail.isEmpty ? "" : "  (\(detail))")")
        }
        let kept = saved()
        defer { restore(kept) }
        func set(size: Look.Size? = nil, preset: Look.Preset? = nil, eightBit: Bool? = nil) {
            if let size { Pref.set(size.rawValue, Look.scaleKey) }
            if let preset { Pref.set(preset.rawValue, Look.presetKey) }
            if let eightBit { Pref.set(eightBit, Retro.styleKey) }
        }

        // 1. The defaults and the factors.
        for key in keys where key != "app.onboarded" { UserDefaults.standard.removeObject(forKey: key) }
        let forcedEnv = ProcessInfo.processInfo.environment
        if forcedEnv["SCOUT_8BIT"] == nil && forcedEnv["SCOUT_SCALE"] == nil && forcedEnv["SCOUT_PRESET"] == nil {
            check("the defaults: 8-bit on, size normal, colours dark", Retro.is8bit && Look.size == .normal && Look.preset == .dark && !Look.isLight,
                  "8bit \(Retro.is8bit), size \(Look.size), preset \(Look.preset)")
        }
        check("the size factors are 1.0, 1.2 and 1.45 (the wings 1.0, 1.15 and 1.3)",
              Look.Size.normal.factor == 1 && Look.Size.large.factor == 1.2 && Look.Size.xlarge.factor == 1.45
                && Look.Size.normal.wingFactor == 1 && Look.Size.large.wingFactor == 1.15 && Look.Size.xlarge.wingFactor == 1.3)
        Pref.set("huge", Look.scaleKey)
        Pref.set("pink", Look.presetKey)
        check("an unknown saved size or colour falls back to normal and dark", Look.size == .normal && Look.preset == .dark, "\(Look.size) \(Look.preset)")
        // ONE light/dark setting for windows and notch.
        check("the one Appearance setting gives the notch its colours: Light light, Dark dark, System as macOS is",
              AppAppearance.notchPreset(for: .light, systemDark: true) == .light && AppAppearance.notchPreset(for: .dark, systemDark: false) == .dark
              && AppAppearance.notchPreset(for: .system, systemDark: true) == .dark && AppAppearance.notchPreset(for: .system, systemDark: false) == .light)
        UserDefaults.standard.removeObject(forKey: Look.scaleKey)
        UserDefaults.standard.removeObject(forKey: Look.presetKey)

        // 2. The size: the open island grows by the factor, stays flush with the screen edge, and real clicks still land.
        var normalIsland = CGRect.zero
        var normalTab = CGRect.zero
        for size in Look.Size.allCases {
            set(size: size, preset: .dark, eightBit: true)
            let rig = Rig()
            await settle(0.9)
            let island = rig.island
            if size == .normal && ProcessInfo.processInfo.environment["LOOK_DUMP"] != nil {
                func dump(_ v: NSView, _ depth: Int) {
                    lines.append(String(repeating: "  ", count: depth) + "\(type(of: v)) \(v.frame)")
                    for sub in v.subviews { dump(sub, depth + 1) }
                }
                if let c = rig.panel.contentView { dump(c, 0) }
            }
            let tab = rig.rect("tab.calendar") ?? .zero
            if size == .normal { normalIsland = island; normalTab = tab }
            let f = size.factor
            let clampedW = island.width >= rig.size.width - 40 - 1
            check("size \(size.title): the island is \(f) times as wide and as tall as at normal, its top flush with the screen edge",
                  island.width > 0 && island.minY < 0.5
                    && (abs(island.width / max(1, normalIsland.width) - f) < 0.03 || clampedW)
                    && abs(island.height / max(1, normalIsland.height) - f) < 0.03,
                  "island \(island.size) top \(island.minY), normal \(normalIsland.size)")
            check("  a tab key is \(f) times as big (the reported rects follow the scaling)",
                  abs(tab.height / max(1, normalTab.height) - f) < 0.05 && tab.width > 0, "tab \(tab.size), normal \(normalTab.size)")
            // A real click on a tab key and back, and on a panel's background.
            if let cal = rig.rect("tab.calendar") {
                rig.click(CGPoint(x: cal.midX, y: cal.midY))
                await settle(0.5)
                let opened = rig.navigator.expanded == .calendar
                // The keys move a little when the faces make room beside the camera, so the dashboard key is read again.
                if let back = rig.rect("tab.nook") { rig.click(CGPoint(x: back.midX, y: back.midY)) }
                await settle(0.5)
                let backAtDashboard = rig.navigator.expanded == nil
                check("  real clicks on the Calendar tab key and back on the dashboard key land", opened && backAtDashboard, "opened \(opened), back \(backAtDashboard)")
            } else {
                check("  the tab keys report their rects", false, "rects \(rig.model.panelRects.keys.sorted())")
            }
            if let panel = rig.rect("panel.today") {
                rig.click(CGPoint(x: panel.midX, y: panel.maxY - 6))
                await settle(0.4)
                check("  a real click on the Today panel opens the Calendar", rig.navigator.expanded == .calendar, "expanded \(String(describing: rig.navigator.expanded))")
            } else {
                check("  the Today panel reports its rect", false, "rects \(rig.model.panelRects.keys.sorted())")
            }
            rig.close()

            // The Ask AI line's real text field (an AppKit view) sits where it is drawn, and a click on it focuses it.
            let store = AIChatStore()
            let draft = AskAINotchDraft()
            let ask = Rig(layout: [.askAI]) { kind in kind == .askAI ? AnyView(AskAIWidgetView(store: store, draft: draft)) : nil }
            await settle(0.9)
            if let askRect = ask.rect("panel.askAI"), let field = ask.firstTextField(), let content = ask.panel.contentView {
                let inWindow = field.convert(field.bounds, to: nil)
                let local = CGRect(x: inWindow.minX, y: ask.size.height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
                check("  the Ask AI text field sits inside the Ask AI panel as drawn", askRect.insetBy(dx: -2, dy: -2).contains(CGPoint(x: local.midX, y: local.midY)),
                      "field \(local), panel \(askRect), bounds \(content.bounds.size)")
                ask.click(CGPoint(x: local.midX, y: local.midY))
                await settle(0.3)
                let focused = (ask.panel.firstResponder as? NSText)?.delegate === field
                check("  a real click on the Ask AI field focuses it", focused, "first responder \(String(describing: ask.panel.firstResponder))")
            } else {
                check("  the Ask AI panel and its text field draw", false, "panels \(ask.model.panelRects.keys.sorted())")
            }
            ask.close()
        }

        // 3. The colours: the light preset makes the island and its panels light with dark text; the closed notch stays black.
        for preset in Look.Preset.allCases {
            for eightBit in [true, false] {
                set(size: .normal, preset: preset, eightBit: eightBit)
                let rig = Rig()
                await settle(0.9)
                let island = rig.island
                let look = "\(preset.title), \(eightBit ? "8-bit" : "minimal")"
                let wantName: NSAppearance.Name = preset == .light ? .aqua : .darkAqua
                check("\(look): the window's own appearance follows the colours (so what AppKit draws reads on the surface)",
                      rig.panel.appearance?.name == wantName, "appearance \(String(describing: rig.panel.appearance?.name.rawValue))")
                if let pixels = rig.snapshot(), island.width > 0 {
                    // Under the panels in the middle of the island: the bare surface. (The bottom-left corner was the 8-bit Agent TV's rim since the
                    // set reaches out to the island's corner, and this check failed in the 8-bit look on main already.)
                    let bgPoint = CGPoint(x: island.midX, y: island.maxY - 4)
                    let bg = pixels.luminance(bgPoint)
                    let headerBg = pixels.luminance(CGPoint(x: island.minX + 60, y: island.minY + 6))
                    check("\(look): the island is \(preset == .light ? "light" : "black")",
                          preset == .light ? (bg > 0.85 && headerBg > 0.85) : (bg < 0.06 && headerBg < 0.06), "body \(bg), header \(headerBg)")
                    // Every header key shows its symbol against the surface (a dark symbol on light, a light one on black).
                    var weak: [String] = []
                    for (name, rect) in rig.model.panelRects where name.hasPrefix("tab.") {
                        let r = pixels.range(in: rect.insetBy(dx: 3, dy: 3))
                        let contrast = preset == .light ? bg - r.dark : r.bright - bg
                        if contrast < 0.28 { weak.append("\(name) \(String(format: "%.2f", contrast))") }
                    }
                    check("\(look): every header key's symbol is readable on the surface (\(preset == .light ? "dark on light" : "light on black"))", weak.isEmpty, weak.sorted().joined(separator: ", "))
                    // The Ask AI panel's words are readable.
                    if let ask = rig.rect("panel.askAI") {
                        let r = pixels.range(in: ask.insetBy(dx: 4, dy: 4))
                        let text = preset == .light ? r.dark : r.bright
                        // The panel has no title any more (2026-11-16): its darkest words are the quiet placeholder, still far darker than the paper.
                        check("\(look): the panels' text is dark on light and light on black", preset == .light ? text < 0.7 : text > 0.5, "extreme \(text)")
                    }
                } else {
                    check("\(look): the island draws", false, "island \(island), snapshot \(rig.snapshot() != nil)")
                }
                rig.close()

                // The closed notch is black in both.
                let closed = Rig(open: false)
                await settle(0.7)
                if let pixels = closed.snapshot() {
                    let hw = NotchGeometry.sample16.size
                    let l = pixels.luminance(CGPoint(x: closed.size.width / 2, y: hw.height / 2))
                    check("\(look): the closed notch stays black", l < 0.06, "luminance \(l)")
                } else {
                    check("\(look): the closed notch draws", false)
                }
                closed.close()
            }
        }

        // 4. The welcome tour writes the settings from real clicks on its cards.
        await TourSelfTest.run(report: { check($0, $1, $2) }, settle: { await settle($0) })

        restore(kept)
        finish(lines, failed, out: out)
    }

    private static func finish(_ lines: [String], _ failed: Int, out file: URL) {
        var out = lines
        out.append("look selftest done: \(failed == 0 ? "all passed" : "\(failed) FAILED")")
        for line in out { print(line) }
        fflush(stdout)
        try? out.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}
