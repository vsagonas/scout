import AppKit
import SwiftUI

/// `scout://island.selftest.hit?out=<file>` (headless): which shapes take the pointer and what hover and click do on each kind of display.
/// The pure functions of `IslandHitAreas` are proved with tables of numbers (screen coordinates of faked displays); the closed flow of
/// `NotchManager` then runs headless with controllers that show no panel (`NotchController(geometry:screenFrame:panelFrame:showsPanel:)`), its own
/// navigator and activity centre, and the pointer passed in (`evaluate(at:)`). Nothing is drawn on the screen and nothing reaches the owner's
/// Scout. The settings it changes are put back.
@MainActor
enum IslandHitSelfTest {
    static func register() {
        // Its own registration (not `SuiteCheck.register`): the closed flow waits for the manager's timers and dispatch blocks, so the run is async.
        DebugCommands.register("island.selftest.hit") { params in
            guard ScoutRuntime.isAutomation else { return }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("island.selftest.hit.txt")
            Task { @MainActor in
                let check = SuiteCheck("island hit")
                await run(check)
                check.finish(out: out)
            }
        }
    }

    private static func run(_ check: SuiteCheck) async {
        let kept = saved()
        defer { restore(kept) }
        UserDefaults.standard.set(false, forKey: "notch.haptics")   // no tap on the trackpad from a test
        UserDefaults.standard.set(true, forKey: "notch.clickToOpen")
        hitRectTables(check)
        keepOutAndGaps(check)
        hoverTable(check)
        todaysNumbers(check)
        dashboardPlace(check)
        await pillFlow(check)
        await bubblesFlow(check)
        await drawnFlow(check)
        await classicFlow(check)
        await clickFlow(check)
    }

    // MARK: Settings, put back at the end

    private static let keys = ["notch.hover", "notch.hoverDelay", "notch.haptics", "notch.clickToOpen"]

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

    /// Lets the main queue run for a while: the manager's hover timers and the navigator's observers are dispatch blocks.
    private static func settle(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.001 && abs(a.minY - b.minY) < 0.001 && abs(a.width - b.width) < 0.001 && abs(a.height - b.height) < 0.001
    }

    // MARK: The displays, faked in screen coordinates

    private struct Layout {
        var name: String
        var geometry: NotchGeometry
        var screen: CGRect
        var housing: CGRect
        var shapes: [String: CGRect]
    }

    /// Bubbles to the left (one housing high, 6 pt from the housing, 4 pt apart), the news capsule to the right (6 pt from the housing, 16 pt more on
    /// a pill), the drawn island's own shape where the display draws one.
    private static func layout(_ name: String, _ geometry: NotchGeometry, screen: CGRect, bubbles: [String] = ["bubble.a", "bubble.b", "bubble.c"]) -> Layout {
        let housing = IslandHitAreas.housingRect(geometry: geometry, screenFrame: screen)
        let d = geometry.size.height
        var shapes: [String: CGRect] = [:]
        var x = housing.minX - 6
        for bubble in bubbles {
            shapes[bubble] = CGRect(x: x - d, y: housing.minY, width: d, height: d)
            x -= d + 4
        }
        let reserve: CGFloat = geometry.kind == .pill ? 16 : 0
        shapes["capsule.news"] = CGRect(x: housing.maxX + 6 + reserve, y: housing.minY, width: 90, height: d)
        if geometry.kind == .none { shapes[IslandHit.drawn] = housing }
        return Layout(name: name, geometry: geometry, screen: screen, housing: housing, shapes: shapes)
    }

    private static let pillScreen = CGRect(x: 0, y: 0, width: 1736, height: 1117)
    private static let noneScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private static let notchScreen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    private static var pillFinger: NotchGeometry { .samplePill16 }
    private static var pillMouse: NotchGeometry { var g = NotchGeometry.samplePill16; g.isTouch = false; return g }

    // MARK: The slop rules

    private static func hitRectTables(_ check: SuiteCheck) {
        // Expected hit rects: each shape grown by the margin (4 pt, 8 on a touch display) above, below and at the far end of its row; nothing toward a
        // neighbour; on a pill, cut back to the keep-out (the housing, 6 pt around it, and 16 pt more on its right).
        let pill = layout("pill, a mouse", pillMouse, screen: pillScreen)
        check("the pill's housing rect is centred, 8.5 pt below the top edge", same(pill.housing, CGRect(x: 839, y: 1077.5, width: 58, height: 31)), "\(pill.housing)")
        let pillRows: [(String, Layout, [String: CGRect])] = [
            ("pill, a mouse (4 pt)", pill, [
                "bubble.a": CGRect(x: 802, y: 1073.5, width: 31, height: 39),
                "bubble.b": CGRect(x: 767, y: 1073.5, width: 31, height: 39),
                "bubble.c": CGRect(x: 728, y: 1073.5, width: 35, height: 39),
                "capsule.news": CGRect(x: 919, y: 1073.5, width: 94, height: 39)]),
            ("pill, a finger (8 pt)", layout("pill, a finger", pillFinger, screen: pillScreen), [
                "bubble.a": CGRect(x: 802, y: 1069.5, width: 31, height: 47),
                "bubble.b": CGRect(x: 767, y: 1069.5, width: 31, height: 47),
                "bubble.c": CGRect(x: 724, y: 1069.5, width: 39, height: 47),
                "capsule.news": CGRect(x: 919, y: 1069.5, width: 98, height: 47)]),
            ("tall pill, a mouse", layout("tall pill", { var g = NotchGeometry.samplePillTall; g.isTouch = false; return g }(), screen: pillScreen), [
                "bubble.a": CGRect(x: 792.5, y: 1064.5, width: 40, height: 48),
                "bubble.b": CGRect(x: 748.5, y: 1064.5, width: 40, height: 48),
                "bubble.c": CGRect(x: 700.5, y: 1064.5, width: 44, height: 48),
                "capsule.news": CGRect(x: 919.5, y: 1064.5, width: 94, height: 48)]),
            ("drawn island in a 24 pt bar (the island itself is a shape)", layout("island", .sampleNone, screen: noneScreen), [
                "drawn": CGRect(x: 926, y: 1054, width: 68, height: 28),
                "bubble.a": CGRect(x: 900, y: 1054, width: 20, height: 28),
                "bubble.b": CGRect(x: 876, y: 1054, width: 20, height: 28),
                "bubble.c": CGRect(x: 848, y: 1054, width: 24, height: 28),
                "capsule.news": CGRect(x: 1000, y: 1054, width: 94, height: 28)]),
            ("classic notch with round bubbles", layout("notch bubbles", .sampleNotchBubbles, screen: notchScreen), [
                "bubble.a": CGRect(x: 733.5, y: 1081, width: 32, height: 40),
                "bubble.b": CGRect(x: 697.5, y: 1081, width: 32, height: 40),
                "bubble.c": CGRect(x: 657.5, y: 1081, width: 36, height: 40),
                "capsule.news": CGRect(x: 962.5, y: 1081, width: 94, height: 40)]),
        ]
        for (name, lay, expected) in pillRows {
            let got = IslandHitAreas.hitRects(shapes: lay.shapes, housing: lay.housing, geometry: lay.geometry)
            for (shape, want) in expected.sorted(by: { $0.key < $1.key }) {
                check("hit rect, \(name): \(shape)", got[shape].map { same($0, want) } ?? false, "got \(String(describing: got[shape])) wanted \(want)")
            }
            check("hit rects, \(name): no shape is lost or invented", Set(got.keys) == Set(expected.keys), "\(got.keys.sorted())")
        }
        // The shape that is inside the keep-out of a pill is never a target.
        let inside = IslandHitAreas.hitRects(shapes: ["bubble.x": CGRect(x: 850, y: 1077.5, width: 31, height: 31)], housing: pill.housing, geometry: pillMouse)
        check("a shape that sits inside the keep-out of a pill is no target at all", inside.isEmpty, "\(inside)")
        // Nothing is added toward a neighbour, near or far (the rule is strict, not only "when the margins would meet"): the housing of a claiming display
        // counts as a neighbour too. A shape with no neighbour grows on every side.
        let far = IslandHitAreas.hitRects(shapes: ["bubble.a": CGRect(x: 100, y: 0, width: 20, height: 20), "bubble.b": CGRect(x: 140, y: 0, width: 20, height: 20)],
                                          housing: CGRect(x: 500, y: 0, width: 50, height: 20), geometry: .sampleNotchBubbles)
        check("two shapes 20 pt apart grow nothing toward each other, nor toward the housing 340 pt away; only the outer end of the row grows",
              far["bubble.a"].map { same($0, CGRect(x: 96, y: -4, width: 24, height: 28)) } == true && far["bubble.b"].map { same($0, CGRect(x: 140, y: -4, width: 20, height: 28)) } == true,
              "\(far)")
        let alone = IslandHitAreas.hitRects(shapes: ["bubble.a": CGRect(x: 100, y: 0, width: 20, height: 20)], housing: CGRect(x: 500, y: 200, width: 50, height: 20), geometry: .sampleNotchBubbles)
        check("a shape with no neighbour on its row grows by the margin on every side", alone["bubble.a"].map { same($0, CGRect(x: 96, y: -4, width: 28, height: 28)) } == true, "\(alone)")
        let touching = IslandHitAreas.hitRects(shapes: ["bubble.a": CGRect(x: 100, y: 0, width: 20, height: 20), "bubble.b": CGRect(x: 120, y: 0, width: 20, height: 20)],
                                               housing: CGRect(x: 500, y: 200, width: 50, height: 20), geometry: .sampleNotchBubbles)
        check("two shapes side by side do not grow toward each other", touching["bubble.a"].map { same($0, CGRect(x: 96, y: -4, width: 24, height: 28)) } == true
              && touching["bubble.b"].map { same($0, CGRect(x: 120, y: -4, width: 24, height: 28)) } == true, "\(touching)")
        let rows = IslandHitAreas.hitRects(shapes: ["bubble.a": CGRect(x: 100, y: 0, width: 20, height: 20), "bubble.b": CGRect(x: 140, y: 40, width: 20, height: 20)],
                                           housing: CGRect(x: 500, y: 200, width: 50, height: 20), geometry: .sampleNotchBubbles)
        check("shapes in different rows (no vertical overlap) are not neighbours", rows["bubble.a"].map { same($0, CGRect(x: 96, y: -4, width: 28, height: 28)) } == true
              && rows["bubble.b"].map { same($0, CGRect(x: 136, y: 36, width: 28, height: 28)) } == true, "\(rows)")
        check("the margins are 4 pt, 8 pt for a finger", IslandHitAreas.margin(for: pillMouse) == 4 && IslandHitAreas.margin(for: pillFinger) == 8
              && IslandHitAreas.margin(for: .sample16) == 4)
    }

    // MARK: Between shapes and inside the keep-out

    private static func target(_ lay: Layout, _ p: CGPoint) -> IslandTarget {
        IslandHitAreas.target(at: p, shapes: lay.shapes, housing: lay.housing, geometry: lay.geometry)
    }

    private static func keepOutAndGaps(_ check: SuiteCheck) {
        for lay in [layout("pill, a mouse", pillMouse, screen: pillScreen), layout("pill, a finger", pillFinger, screen: pillScreen),
                    layout("tall pill", .samplePillTall, screen: pillScreen)] {
            let hr = lay.housing
            let keep = IslandHitAreas.keepOut(housing: hr, geometry: lay.geometry)!
            check("the keep-out of the \(lay.name) is the housing plus 6 pt around it and 16 pt more on its right",
                  same(keep, CGRect(x: hr.minX - 6, y: hr.minY - 6, width: hr.width + 12 + 16, height: hr.height + 12)), "\(keep)")
            let rects = IslandHitAreas.hitRects(shapes: lay.shapes, housing: hr, geometry: lay.geometry)
            let clear = rects.allSatisfy { $0.value.maxX <= keep.minX + 0.001 || $0.value.minX >= keep.maxX - 0.001 }
            check("no hit rect of the \(lay.name) touches the keep-out, so none touches the housing", clear, "\(rects)")
            var hits = 0
            var y = keep.minY
            while y < keep.maxY {
                var x = keep.minX
                while x < keep.maxX {
                    if rects.values.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) { hits += 1 }
                    x += 0.5
                }
                y += 0.5
            }
            check("no hit rect of the \(lay.name) holds a point inside the keep-out (a grid at half points)", hits == 0, "\(hits) points")
            check("every point of the keep-out of the \(lay.name) hits nothing: the housing centre and its four clearances", [CGPoint(x: hr.midX, y: hr.midY), CGPoint(x: keep.minX + 1, y: hr.midY),
                  CGPoint(x: keep.maxX - 1, y: hr.midY), CGPoint(x: hr.midX, y: keep.minY + 1), CGPoint(x: hr.midX, y: keep.maxY - 1)].allSatisfy { target(lay, $0) == .none })
            check("the pill's housing centre is no target", target(lay, CGPoint(x: hr.midX, y: hr.midY)) == .none)
            // Between two bubbles.
            let a = lay.shapes["bubble.a"]!, b = lay.shapes["bubble.b"]!
            var gapHits = 0
            var gx = b.maxX
            while gx < a.minX { if target(lay, CGPoint(x: gx + 0.1, y: a.midY)) != .none { gapHits += 1 }; gx += 0.25 }
            check("a click between two bubbles of the \(lay.name) hits nothing (the whole 4 pt gap)", gapHits == 0, "\(gapHits)")
            check("each bubble's own middle hits that bubble", target(lay, CGPoint(x: a.midX, y: a.midY)) == .shape("bubble.a") && target(lay, CGPoint(x: b.midX, y: b.midY)) == .shape("bubble.b"))
            let cap = lay.shapes["capsule.news"]!
            check("the capsule's middle hits the capsule, a point 2 pt beyond its far end still does (the margin)",
                  target(lay, CGPoint(x: cap.midX, y: cap.midY)) == .shape("capsule.news") && target(lay, CGPoint(x: cap.maxX + 2, y: cap.midY)) == .shape("capsule.news")
                  && target(lay, CGPoint(x: cap.maxX + IslandHitAreas.margin(for: lay.geometry) + 1, y: cap.midY)) == .none)
        }
        let island = layout("island", .sampleNone, screen: noneScreen)
        check("on the drawn island the island's own shape is a target", target(island, CGPoint(x: island.housing.midX, y: island.housing.midY)) == .shape(IslandHit.drawn))
        check("on the drawn island a point in the gap beside a bubble reaches the housing's margin, the rest of the gap hits nothing",
              target(island, CGPoint(x: 921, y: island.housing.midY)) == .none && target(island, CGPoint(x: 923, y: island.housing.midY)) == .housing)
        let bubbles = layout("notch bubbles", .sampleNotchBubbles, screen: notchScreen)
        let h = bubbles.housing
        check("on a classic notch with bubbles the notch housing stays a target as before", target(bubbles, CGPoint(x: h.midX, y: h.midY)) == .housing
              && IslandHitAreas.claimedHousingRect(h) == CGRect(x: 767.5, y: 1082, width: 193, height: 43))
        check("on a classic notch with bubbles the gap between a bubble and the housing hits nothing beyond the housing's own margin",
              target(bubbles, CGPoint(x: 766.5, y: h.midY)) == .none && target(bubbles, CGPoint(x: 768, y: h.midY)) == .housing)
        check("a point far from everything hits nothing", target(bubbles, CGPoint(x: 100, y: 100)) == .none && target(island, CGPoint(x: 1500, y: 500)) == .none)
        check("the pointer lights up only a named shape", IslandHitAreas.highlightName(for: .shape("bubble.a")) == "bubble.a" && IslandHitAreas.highlightName(for: .housing) == nil
              && IslandHitAreas.highlightName(for: .none) == nil)
    }

    // MARK: The hover table

    private static func hoverTable(_ check: SuiteCheck) {
        // The setting by the five targets. A shape lights up whatever the setting says; only opens, and only where the dashboard opens;
        // the housing of a display that claims it behaves as before; the camera pill's housing never does anything.
        typealias Row = (NotchHover, IslandHoverTarget, NotchGeometry, HoverAction)
        let notch = NotchGeometry.sampleNotchBubbles, pill = NotchGeometry.samplePill16
        let rows: [Row] = [
            (.open, .bubble, notch, .open), (.open, .capsule, notch, .open), (.open, .drawn, .sampleNone, .open), (.open, .housing, notch, .open), (.open, .pillHousing, pill, .nothing),
            (.details, .bubble, notch, .highlight), (.details, .capsule, notch, .highlight), (.details, .drawn, .sampleNone, .highlight), (.details, .housing, notch, .showDetail),
            (.details, .pillHousing, pill, .nothing),
            (.off, .bubble, notch, .highlight), (.off, .capsule, notch, .highlight), (.off, .drawn, .sampleNone, .highlight), (.off, .housing, notch, .nothing), (.off, .pillHousing, pill, .nothing),
            // On a pill the dashboard does not open: can only light a shape up.
            (.open, .bubble, pill, .highlight), (.open, .capsule, pill, .highlight), (.details, .bubble, pill, .highlight), (.off, .capsule, pill, .highlight),
            (.open, .pillHousing, notch, .nothing),
        ]
        for (setting, target, geometry, expected) in rows {
            let got = IslandHitAreas.hoverAction(setting: setting, target: target, geometry: geometry)
            check("hover: \(setting.rawValue) on \(target) (\(geometry.kind)) is \(expected)", got == expected, "\(got)")
        }
        check("the hover table covers three settings by five targets", NotchHover.allCases.count == 3 && IslandHoverTarget.allCases.count == 5)
        check("the housing of a pill is the fifth kind of target, never a bubble", IslandHitAreas.hoverTarget(for: .housing, geometry: pill) == .pillHousing
              && IslandHitAreas.hoverTarget(for: .housing, geometry: notch) == .housing && IslandHitAreas.hoverTarget(for: .shape("bubble.more"), geometry: notch) == .bubble
              && IslandHitAreas.hoverTarget(for: .shape("capsule.companion"), geometry: notch) == .capsule && IslandHitAreas.hoverTarget(for: .shape("drawn"), geometry: .sampleNone) == .drawn
              && IslandHitAreas.hoverTarget(for: .none, geometry: notch) == nil)
    }

    // MARK: Today's numbers for a classic notch

    private static func todaysNumbers(_ check: SuiteCheck) {
        // Literal numbers, worked out by hand for a 1,728 by 1,117 pt screen and the 1,400 pt panel: the rects of every version before the island work.
        let c = NotchController(geometry: .sample16, screenFrame: notchScreen, panelFrame: CGRect(x: 164, y: 397, width: 1400, height: 720), showsPanel: false)
        c.model.islandRect = CGRect(x: 607.5, y: 0, width: 185, height: 32)
        check("sample16: the island rect is today's (the island, 4 pt around it, 3 pt above and below, 8 pt more toward the edge)",
              same(c.islandScreenRect, CGRect(x: 767.5, y: 1082, width: 193, height: 43)), "\(c.islandScreenRect)")
        check("sample16: the anchor (the housing) is today's", same(c.housingScreenRect, CGRect(x: 771.5, y: 1085, width: 185, height: 32)) && same(c.fallbackNotchRect, c.housingScreenRect), "\(c.housingScreenRect)")
        check("sample16: the drop zone reaches 120 pt from the housing, 240 once a drag targets the notch",
              IslandHitAreas.dropReach(targeting: false) == 120 && IslandHitAreas.dropReach(targeting: true) == 240
              && IslandHitAreas.distance(from: CGPoint(x: 671.5, y: 1100), to: c.housingScreenRect) == 100
              && IslandHitAreas.distance(from: CGPoint(x: 771.5, y: 1085 - 120), to: c.housingScreenRect) == 120
              && abs(IslandHitAreas.distance(from: CGPoint(x: 771.5 - 30, y: 1085 - 40), to: c.housingScreenRect) - 50) < 0.001)
        check("sample16: the swipe strip is 6 pt below the housing, 1,079 pt from the bottom", IslandHitAreas.swipeStripTop(geometry: .sample16, screenFrame: notchScreen) == 1079)
        check("sample16: a drop at the top centre opens; on a pill it opens nothing", IslandHitAreas.dropOpens(geometry: .sample16) && IslandHitAreas.dropOpens(geometry: .sampleNone)
              && !IslandHitAreas.dropOpens(geometry: .samplePill16))
        let pill = NotchController(geometry: .samplePill16, screenFrame: pillScreen, panelFrame: CGRect(x: 168, y: 397, width: 1400, height: 720), showsPanel: false)
        check("a pill's anchor is the housing 8.5 pt below the edge, and its swipe strip is 6 pt under the housing's floor",
              same(pill.housingScreenRect, CGRect(x: 839, y: 1077.5, width: 58, height: 31)) && IslandHitAreas.swipeStripTop(geometry: .samplePill16, screenFrame: pillScreen) == 1117 - 39.5 - 6)
        check("a closed pill has no island rect, so the old fallback can never make the pill a target", pill.islandScreenRect.isNull)
        pill.model.isOpen = true
        check("an open notch keeps its island rect (the rule is for a closed pill)", !pill.islandScreenRect.isNull)
    }

    // MARK: Where an open dashboard comes back to

    private static func dashboardPlace(_ check: SuiteCheck) {
        // After the displays change while the dashboard is open, it returns to the first display where it opens; a pill is never one.
        let place = NotchManager.dashboardIndex(among:)
        check("the dashboard comes back to the first display where it opens: a notch alone, a notch after a pill, a drawn island",
              place([.sample16]) == 0 && place([.samplePill16, .sample16]) == 1 && place([.samplePill16, .samplePillTall, .sampleNone]) == 2 && place([.sample16, .samplePill16]) == 0
              && place([.sampleNotchBubbles, .sampleNone]) == 0 && place([.sampleNoneTab]) == 0)
        check("the dashboard has no display to come back to when only pills are left, or none is", place([.samplePill16]) == nil && place([.samplePill16, .samplePillTall]) == nil && place([]) == nil)
    }

    // MARK: Headless closed flow

    private static func local(_ screen: CGRect, in controller: NotchController) -> CGRect {
        let f = controller.panel.frame
        return CGRect(x: screen.minX - f.minX, y: f.maxY - screen.maxY, width: screen.width, height: screen.height)
    }

    @MainActor
    private final class Rig {
        let layout: Layout
        let navigator = NotchNavigator()
        let center = LiveActivityCenter()
        let manager: NotchManager
        let controller: NotchController
        var clicks: [String] = []

        init(_ layout: Layout, agents: Bool = true) {
            self.layout = layout
            navigator.workspace = .nook
            manager = NotchManager(navigator: navigator, center: center)
            controller = NotchController(geometry: layout.geometry, screenFrame: layout.screen,
                                         panelFrame: CGRect(x: layout.screen.midX - 700, y: layout.screen.maxY - 720, width: 1400, height: 720), showsPanel: false)
            if agents {
                center.show(LiveActivity(id: "agents.main", kind: .agent, leading: { EmptyView() }, trailing: { EmptyView() }))
            }
            for (name, rect) in layout.shapes { controller.model.hitRects[name] = IslandHitSelfTest.local(rect, in: controller) }
            if layout.geometry.kind == .notch, layout.geometry.agentStyle == .faces {
                controller.model.islandRect = IslandHitSelfTest.local(layout.housing, in: controller)
            }
            manager.pointerOverride = CGPoint(x: -9999, y: -9999)
            manager.pressedButtonsOverride = 0
            manager.install(controllers: [controller])
            manager.bindNavigator()
            manager.onShapeClick = { [unowned self] name, _ in clicks.append(name); return true }
        }

        func point(_ shape: String) -> CGPoint { CGPoint(x: layout.shapes[shape]!.midX, y: layout.shapes[shape]!.midY) }
        func evaluate(_ p: CGPoint) { manager.evaluate(at: p) }
        func away() { manager.evaluate(at: CGPoint(x: -9999, y: -9999)) }
    }

    /// A rig, given a moment for the initial observers of its manager to run: a bound navigator reports its state once, which runs the manager's
    /// "closed" step (and its pointer check 0.3 s later); a pointer check that follows would otherwise cancel a hover started by the test.
    private static func makeRig(_ layout: Layout, agents: Bool = true) async -> Rig {
        let rig = Rig(layout, agents: agents)
        await settle(0.4)
        return rig
    }

    private static func setHover(_ hover: NotchHover, delay: Double = 0) {
        UserDefaults.standard.set(hover.rawValue, forKey: "notch.hover")
        UserDefaults.standard.set(delay, forKey: "notch.hoverDelay")
    }

    private static func pillFlow(_ check: SuiteCheck) async {
        setHover(.open)
        let rig = await makeRig(layout("pill", pillMouse, screen: pillScreen))
        let c = rig.controller
        check("pill, agents showing: the closed notch draws separate shapes", rig.manager.closedDrawing(of: c) == .rows)
        rig.evaluate(rig.point("bubble.a"))
        check("pill: the pointer over a bubble lets the panel take the mouse and lights the bubble", !c.panel.ignoresMouseEvents && c.model.hoveredHit == "bubble.a",
              "ignores \(c.panel.ignoresMouseEvents) hovered \(String(describing: c.model.hoveredHit))")
        await settle(0.3)
        check("pill: «Open the notch» opens nothing on a pill (the bubble only lights up)", !rig.navigator.isOpen && !c.model.isOpen)
        rig.evaluate(rig.point("capsule.news"))
        check("pill: moving to the capsule moves the highlight", c.model.hoveredHit == "capsule.news")
        let a = rig.layout.shapes["bubble.a"]!, b = rig.layout.shapes["bubble.b"]!
        rig.evaluate(CGPoint(x: (a.minX + b.maxX) / 2, y: a.midY))
        check("pill: the pointer between two bubbles takes nothing and lights nothing", c.panel.ignoresMouseEvents && c.model.hoveredHit == nil)
        let hr = rig.layout.housing
        rig.evaluate(CGPoint(x: hr.midX, y: hr.midY))
        check("pill: the pointer on the camera pill takes nothing and lights nothing", c.panel.ignoresMouseEvents && c.model.hoveredHit == nil)
        rig.evaluate(CGPoint(x: hr.maxX + 10, y: hr.midY))
        check("pill: the pointer in the room kept for the privacy dot takes nothing", c.panel.ignoresMouseEvents && c.model.hoveredHit == nil)
        rig.evaluate(CGPoint(x: hr.midX, y: hr.minY - 3))
        check("pill: the pointer in the clearance below the pill takes nothing", c.panel.ignoresMouseEvents)
        await settle(0.4)
        check("pill: a second of hover over the pill and its keep-out opens nothing", !rig.navigator.isOpen)
        rig.away()
        check("pill: the pointer far away: the panel ignores the mouse again", c.panel.ignoresMouseEvents && c.model.hoveredHit == nil)

        // Whatever asks for the dashboard (the menu, a hotkey, a command, a drop): one log line, nothing opens.
        rig.navigator.open(.agents)
        await settle(0.4)
        check("pill: a request to open the dashboard (menu, hotkey, command) is refused: nothing opens", !rig.navigator.isOpen && !c.model.isOpen && rig.manager.active == nil)
        rig.navigator.open()
        await settle(0.3)
        check("pill: asking twice changes nothing", !rig.navigator.isOpen && !c.model.isOpen)
        check("pill: a file dragged to the top centre opens nothing: no notch takes the drop", rig.manager.dropCandidate(at: CGPoint(x: hr.midX, y: hr.maxY + 4)) == nil)
        check("pill: IslandHit.perform returns false for every name and nothing opens",
              ["bubble.a", "bubble.more", "capsule.news", "capsule.companion"].allSatisfy { !IslandHit.perform($0, geometry: .samplePill16, navigator: rig.navigator, center: rig.center) } && !rig.navigator.isOpen)
        check("pill: a click on the pill itself is no fallback click", !rig.manager.fallbackClick(at: CGPoint(x: hr.midX, y: hr.midY), stamp: 1) && rig.clicks.isEmpty)
        check("pill: the fallback hands a click on a bubble to the shape's hook once and marks no screen to open on",
              rig.manager.fallbackClick(at: rig.point("bubble.b"), stamp: 2) && rig.clicks == ["bubble.b"] && rig.manager.active == nil)
        // The same click with the real action (the default hook): the pill refuses it, nothing opens and no screen is marked.
        rig.manager.onShapeClick = { [unowned rig] name, geometry in IslandHit.perform(name, geometry: geometry, navigator: rig.navigator, center: rig.center) }
        let ran = rig.manager.fallbackClick(at: rig.point("bubble.a"), stamp: 3)
        await settle(0.3)
        check("pill: with the real action a click on a bubble the panel did not get runs nothing: it is refused, nothing opens, no screen is marked",
              !ran && !rig.navigator.isOpen && !c.model.isOpen && rig.manager.active == nil, "ran \(ran) open \(rig.navigator.isOpen)")
        rig.manager.onShapeClick = { [unowned rig] name, _ in rig.clicks.append(name); return true }

        // Anything but the agents on a pill draws nothing, and takes no pointer.
        rig.center.show(LiveActivity(id: "board", kind: .announcement, leading: { EmptyView() }, trailing: { EmptyView() }))
        check("pill: another activity that outranks the agents (the announcement board) draws nothing yet", rig.manager.closedDrawing(of: c) == .nothing)
        rig.evaluate(rig.point("bubble.a"))
        check("pill: while nothing is drawn the notch takes no pointer", c.panel.ignoresMouseEvents && c.model.hoveredHit == nil)
        rig.away()
    }

    private static func bubblesFlow(_ check: SuiteCheck) async {
        let lay = layout("notch bubbles", .sampleNotchBubbles, screen: notchScreen)
        // Open: the dashboard opens after the delay, where it opens.
        setHover(.open)
        var rig = await makeRig(lay)
        var c = rig.controller
        check("notch with bubbles, agents showing: the closed notch draws separate shapes", rig.manager.closedDrawing(of: c) == .rows)
        rig.evaluate(rig.point("bubble.a"))
        check("notch with bubbles: the pointer over a bubble takes the mouse and lights it", !c.panel.ignoresMouseEvents && c.model.hoveredHit == "bubble.a")
        await settle(0.3)
        check("notch with bubbles: «Open the notch» opens the dashboard on that screen after the delay", rig.navigator.isOpen && c.model.isOpen && rig.manager.active === c,
              "open \(rig.navigator.isOpen) model \(c.model.isOpen)")
        rig.navigator.forceClose()
        await settle(0.5)
        check("notch with bubbles: and it closes again", !rig.navigator.isOpen && !c.model.isOpen)
        // Closed with the pointer still on a bubble (Esc, a click on the gear): no instant re-open, the pointer has to leave and come back first.
        rig = await makeRig(lay); c = rig.controller
        rig.manager.pointerOverride = rig.point("bubble.a")
        rig.evaluate(rig.point("bubble.a"))
        await settle(0.3)
        check("notch with bubbles: «Open the notch» opens on a bubble (the pointer rests on it)", rig.navigator.isOpen && c.model.isOpen)
        rig.navigator.forceClose()
        await settle(1.0)
        check("notch with bubbles: closed with the pointer still on bubble.a (Esc), nothing re-opens (the housing's rect and 6 pt do not reach the bubble)",
              !rig.navigator.isOpen && !c.model.isOpen && c.model.hoveredHit == "bubble.a", "open \(rig.navigator.isOpen) hovered \(String(describing: c.model.hoveredHit))")
        rig.evaluate(rig.point("capsule.news"))
        await settle(0.3)
        check("notch with bubbles: moving to the capsule after that does not open it either (one visit)", !rig.navigator.isOpen)
        rig.away()
        rig.evaluate(rig.point("bubble.b"))
        await settle(0.3)
        check("notch with bubbles: after the pointer has left and come back a hover opens again", rig.navigator.isOpen && c.model.isOpen)
        rig.navigator.forceClose()
        await settle(0.5)
        // Show what's happening: only the highlight, in this build.
        setHover(.details)
        rig = await makeRig(lay); c = rig.controller
        rig.evaluate(rig.point("bubble.b"))
        await settle(0.7)
        check("notch with bubbles: «Show what's happening» lights the bubble and opens nothing, shows no detail", c.model.hoveredHit == "bubble.b" && !rig.navigator.isOpen && !c.model.detailVisible,
              "hovered \(String(describing: c.model.hoveredHit)) open \(rig.navigator.isOpen) detail \(c.model.detailVisible)")
        rig.evaluate(CGPoint(x: lay.housing.midX, y: lay.housing.midY))
        await settle(0.7)
        check("notch with bubbles: «Show what's happening» on the notch itself still shows the detail after 0.45 s, as before", c.model.detailVisible && c.model.hoveredHit == nil)
        // Nothing.
        setHover(.off)
        rig = await makeRig(lay); c = rig.controller
        rig.evaluate(rig.point("capsule.news"))
        await settle(0.4)
        check("notch with bubbles: «Nothing» lights the capsule and opens nothing", c.model.hoveredHit == "capsule.news" && !rig.navigator.isOpen && !c.model.detailVisible,
              "hovered \(String(describing: c.model.hoveredHit)) open \(rig.navigator.isOpen) detail \(c.model.detailVisible)")
        rig.evaluate(CGPoint(x: lay.housing.midX, y: lay.housing.midY))
        await settle(0.4)
        check("notch with bubbles: «Nothing» on the notch itself does nothing", !rig.navigator.isOpen && !c.model.detailVisible)
        // The housing opens as before.
        setHover(.open)
        rig = await makeRig(lay); c = rig.controller
        rig.evaluate(CGPoint(x: lay.housing.midX, y: lay.housing.midY))
        await settle(0.3)
        check("notch with bubbles: the notch itself opens the dashboard on hover, as before", rig.navigator.isOpen && c.model.isOpen)
        rig.navigator.forceClose()
        await settle(0.5)
        // A display that draws no rows now (nothing from the agents): the classic path again.
        rig = await makeRig(lay, agents: false)
        check("notch with bubbles but no agents: the classic drawing (today's rects)", rig.manager.closedDrawing(of: rig.controller) == .classic)
    }

    private static func drawnFlow(_ check: SuiteCheck) async {
        let lay = layout("island", .sampleNone, screen: noneScreen)
        setHover(.open)
        let rig = await makeRig(lay)
        let c = rig.controller
        let empty = await makeRig(lay, agents: false)
        check("drawn island, agents showing: separate shapes, and with nothing to show too", rig.manager.closedDrawing(of: c) == .rows
              && empty.manager.closedDrawing(of: empty.controller) == .rows)
        rig.evaluate(rig.point(IslandHit.drawn))
        check("drawn island: the pointer on the island lets the panel take the mouse and lights it", !c.panel.ignoresMouseEvents && c.model.hoveredHit == IslandHit.drawn)
        await settle(0.3)
        check("drawn island: «Open the notch» opens the dashboard on hover", rig.navigator.isOpen && c.model.isOpen)
        rig.navigator.forceClose()
        await settle(0.5)
        check("drawn island: a file dragged to the top centre is anchored at the island: the drop zone reaches it",
              rig.manager.dropCandidate(at: CGPoint(x: lay.housing.midX, y: lay.housing.minY - 100))?.distance == 100)
        rig.away()
    }

    private static func classicFlow(_ check: SuiteCheck) async {
        let lay = layout("classic", .sample16, screen: notchScreen, bubbles: [])
        setHover(.open)
        let rig = await makeRig(lay)
        let c = rig.controller
        check("classic notch: the closed notch draws the classic shape, agents or not", rig.manager.closedDrawing(of: c) == .classic)
        let hr = lay.housing
        rig.evaluate(CGPoint(x: hr.minX - 3.9, y: hr.midY))
        check("classic notch: the island rect takes the pointer 3.9 pt outside the notch (today's margin), and no shape is lit", !c.panel.ignoresMouseEvents && c.model.hoveredHit == nil)
        rig.away()
        rig.evaluate(CGPoint(x: hr.minX - 4.5, y: hr.midY))
        check("classic notch: 4.5 pt outside the notch takes nothing (today's margin)", c.panel.ignoresMouseEvents)
        rig.away()
        rig.evaluate(CGPoint(x: hr.midX, y: hr.minY - 2.9))
        check("classic notch: 2.9 pt below the notch is inside today's rect", !c.panel.ignoresMouseEvents)
        rig.away()
        rig.evaluate(CGPoint(x: hr.midX, y: hr.minY - 3.5))
        check("classic notch: 3.5 pt below the notch is outside today's rect", c.panel.ignoresMouseEvents)
        rig.away()
        rig.evaluate(CGPoint(x: hr.midX, y: hr.maxY + 7))
        check("classic notch: 7 pt above the edge is still inside today's rect (8 pt more toward the edge)", !c.panel.ignoresMouseEvents)
        await settle(0.3)
        check("classic notch: «Open the notch» opens on hover, as before", rig.navigator.isOpen && c.model.isOpen)
        rig.navigator.forceClose()
        await settle(0.5)
        // One hover per visit on the classic path: the setting changed while the pointer rests on the notch restarts nothing (only separate shapes do).
        setHover(.details)
        let resting = await makeRig(lay)
        let middle = CGPoint(x: hr.midX, y: hr.midY)
        resting.evaluate(middle)
        setHover(.open)
        resting.evaluate(middle)
        await settle(0.7)
        check("classic notch: changing «Pointing at the notch» while the pointer rests on it restarts nothing: the detail still shows, nothing opens",
              resting.controller.model.detailVisible && !resting.navigator.isOpen, "detail \(resting.controller.model.detailVisible) open \(resting.navigator.isOpen)")
        resting.away()
        // The classic drawing with a card up on a drawn island (D1): the island falls back to the tab's drawing.
        let tab = await makeRig(layout("tab", .sampleNoneTab, screen: noneScreen, bubbles: []))
        check("drawn tab: always the classic drawing", tab.manager.closedDrawing(of: tab.controller) == .classic)
    }

    private static func clickFlow(_ check: SuiteCheck) async {
        let lay = layout("notch bubbles", .sampleNotchBubbles, screen: notchScreen)
        var rig = await makeRig(lay)
        let b = rig.point("bubble.b")
        check("fallback click: a click on a bubble the panel did not get runs once", rig.manager.fallbackClick(at: b, stamp: 10) && rig.clicks == ["bubble.b"])
        check("fallback click: the same click again does not run twice", !rig.manager.fallbackClick(at: b, stamp: 10) && rig.clicks == ["bubble.b"])
        check("fallback click: the next click runs", rig.manager.fallbackClick(at: rig.point("bubble.a"), stamp: 11) && rig.clicks == ["bubble.b", "bubble.a"])
        rig.manager.localMouseDown(stamp: 12)
        check("fallback click: a click the panel got (same stamp) is never run again by the fallback", !rig.manager.fallbackClick(at: rig.point("bubble.a"), stamp: 12) && rig.clicks.count == 2)
        let a = lay.shapes["bubble.a"]!, bb = lay.shapes["bubble.b"]!
        check("fallback click: a click between two bubbles runs nothing", !rig.manager.fallbackClick(at: CGPoint(x: (a.minX + bb.maxX) / 2, y: a.midY), stamp: 13) && rig.clicks.count == 2)
        check("fallback click: a click on the capsule runs it", rig.manager.fallbackClick(at: rig.point("capsule.news"), stamp: 14) && rig.clicks.last == "capsule.news")
        rig.manager.globalMouseDown(at: rig.point("bubble.a"), stamp: 15)
        check("fallback click: the global monitor's click reaches the shape too", rig.clicks.last == "bubble.a" && rig.clicks.count == 4)
        UserDefaults.standard.set(false, forKey: "notch.clickToOpen")
        check("fallback click: with «Clicking the notch opens it» off the shapes ignore clicks", !rig.manager.fallbackClick(at: rig.point("bubble.a"), stamp: 16) && rig.clicks.count == 4)
        check("a shape's own click (IslandHit.perform) does nothing either, then", !IslandHit.perform("bubble.a", geometry: .sampleNotchBubbles, navigator: rig.navigator, center: rig.center) && !rig.navigator.isOpen)
        UserDefaults.standard.set(true, forKey: "notch.clickToOpen")
        // A real click through the default action opens the dashboard on the Agents room (a notch with bubbles).
        rig = await makeRig(lay)
        rig.manager.onShapeClick = { [unowned rig] name, geometry in IslandHit.perform(name, geometry: geometry, navigator: rig.navigator, center: rig.center, agents: AgentsStore()) }
        rig.controller.model.hitRects["bubble.more"] = local(CGRect(x: 600, y: 1085, width: 32, height: 32), in: rig.controller)
        let ran = rig.manager.fallbackClick(at: CGPoint(x: 616, y: 1101), stamp: 20)
        await settle(0.3)
        check("fallback click: with the real action a click on the \"+N\" bubble opens the Agents room", ran && rig.navigator.isOpen && rig.navigator.workspace == .agents,
              "open \(rig.navigator.isOpen) workspace \(rig.navigator.workspace)")
        rig.navigator.forceClose()
        await settle(0.5)
    }
}
