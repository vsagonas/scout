import AppKit
import SwiftUI

/// `scout://island.selftest.bubbles?out=<file>` (headless): the round agent bubbles and the news capsule, in pixels and clicks. Everything runs on
/// offscreen panels with faked geometry (`LookSelfTest.Rig`); nothing shows and the owner's Scout is never touched. The little characters are
/// called AGENTS in every line. The three settings it changes (look, size, colours) are put back when the run ends.
@MainActor
enum AgentBubbleSelfTest {
    static func register() {
        DebugCommands.register("island.selftest.bubbles") { params in
            guard ScoutRuntime.isAutomation else { return }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("island-bubbles-selftest.txt")
            Task { @MainActor in
                let check = SuiteCheck("island bubbles")
                await run(check)
                check.finish(out: out)
            }
        }
    }

    typealias Pixels = LookSelfTest.Pixels

    private static let panel = CGSize(width: 700, height: 120)

    private static func settle(_ seconds: Double = 0.9) async { await LookSelfTest.settle(seconds) }

    private static let clickKey = "notch.clickToOpen"
    private static let keys = [Retro.styleKey, Look.scaleKey, Look.presetKey, clickKey]

    static func run(_ check: SuiteCheck) async {
        var kept: [String: Any] = [:]
        for key in keys { if let v = UserDefaults.standard.object(forKey: key) { kept[key] = v } }
        let keptMotion = ScoutRuntime.reduceMotionOverride
        defer {
            for key in keys { if let v = kept[key] { UserDefaults.standard.set(v, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
            ScoutRuntime.reduceMotionOverride = keptMotion
            AgentWingRight.lastRevealed = ""
        }
        Pref.set(Look.Size.normal.rawValue, Look.scaleKey)
        Pref.set(Look.Preset.dark.rawValue, Look.presetKey)
        Pref.set(true, Retro.styleKey)
        Pref.set(true, clickKey)
        ScoutRuntime.reduceMotionOverride = true   // steady rings and no travel while pixels are read; the motion checks set both
        AgentWingRight.lastRevealed = ""

        rules(check)
        await atRest(check)
        await rows(check)
        await bubbleShapes(check)
        await capsules(check)
        await hover(check)
        await clicks(check)
        await motion(check)
    }

    // MARK: Helpers

    private static func rgb(_ c: NSColor?) -> (r: Double, g: Double, b: Double) {
        guard let c = c?.usingColorSpace(.sRGB) else { return (0, 0, 0) }
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    private static func distance(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)) -> Double {
        ((a.r - b.r) * (a.r - b.r) + (a.g - b.g) * (a.g - b.g) + (a.b - b.b) * (a.b - b.b)).squareRoot()
    }

    /// A SwiftUI view drawn offscreen at `scale` pixels per point (1 for a 1x display), its pixels read back.
    private static func render<V: View>(_ view: V, size: CGSize, scale: CGFloat = 2, wait: Double = 0.12) async -> Pixels? {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        OffscreenWindows.mark(window)
        window.orderFrontRegardless()
        defer { window.contentView = nil; window.orderOut(nil) }
        await settle(wait)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return Pixels(rep: rep, points: size)
    }

    private static func union(_ rects: [CGRect]) -> CGRect { rects.reduce(CGRect.null) { $0.union($1) } }

    // MARK: 1. The rules, as numbers

    private static func rules(_ check: SuiteCheck) {
        typealias Row = (inner: CGFloat, scale: CGFloat, cell: CGFloat)
        // The last rows are the faces that do not fit: a disc under 16.97 pt takes a smaller cell in whole device pixels, or none (0).
        let table: [Row] = [(28, 2, 1.5), (27, 2, 1.5), (26.9, 2, 1.0), (25, 2, 1.0), (17, 2, 1.0), (28, 1, 1.0), (40, 1, 1.0), (17, 1, 1.0), (28, 3, 4.0 / 3),
                            (16.9, 2, 0.5), (15, 2, 0.5), (13, 2, 0.5), (8.4, 2, 0), (16.9, 1, 0), (15, 1, 0), (15, 3, 1.0 / 3 * 2)]
        let wrong = table.filter { abs(AgentBubbleMetrics.faceCell(inner: $0.inner, scale: $0.scale) - $0.cell) > 1e-9 }
        check("the face cell: 1.5 pt when the disc inside the ring is 27 pt or more, else 1.0 pt; a whole point on a 1x display (\(table.count) rows)",
              wrong.isEmpty, wrong.map { "\($0)" }.joined(separator: "; "))
        var notWhole: [String] = []
        for scale in [CGFloat(1), 2, 3] {
            for inner in stride(from: CGFloat(10), through: 50, by: 0.5) {
                let px = AgentBubbleMetrics.faceCell(inner: inner, scale: scale) * scale
                if abs(px - px.rounded()) > 1e-6 { notWhole.append("inner \(inner) scale \(scale): \(px) px") }
                let origin = AgentBubbleMetrics.faceOrigin(outer: inner + 3, cell: AgentBubbleMetrics.faceCell(inner: inner, scale: scale), scale: scale) * scale
                if abs(origin - origin.rounded()) > 1e-6 { notWhole.append("origin at inner \(inner) scale \(scale): \(origin) px") }
            }
        }
        check("a face cell and the face's place are whole device pixels at 1x, 2x and 3x", notWhole.isEmpty, notWhole.prefix(3).joined(separator: "; "))
        // The face fits whole inside the disc, corners too, for every display and size of the first build.
        var outside: [String] = []
        let geometries: [NotchGeometry] = [.samplePill16, .samplePillTall, .sampleNone, .sampleNotchBubbles, IslandSamples.notch37, IslandSamples.none37, IslandSamples.none22]
        for g in geometries {
            for factor in IslandTuning.sizeFactors {
                for scale in [CGFloat(1), 2] {
                    let d = IslandRows.diameter(geometry: g, sizeFactor: factor)
                    let inner = AgentBubbleMetrics.innerDiameter(outer: d)
                    let cell = AgentBubbleMetrics.faceCell(inner: inner, scale: scale)
                    if !AgentBubbleMetrics.faceFits(cell: cell, inner: inner) {
                        outside.append("\(g.kind) d \(d) scale \(scale): corner at \(AgentBubbleMetrics.cornerReach(cell: cell)) of \(inner / 2)")
                    }
                }
            }
        }
        check("the face's corners lie inside the disc (the corner distance, not only the sides) on every sample display, size and scale, the 18 pt drawn island included", outside.isEmpty, outside.prefix(3).joined(separator: "; "))
        // The smallest island there is: a 22 pt bar, an 18 pt bubble, a 15 pt disc. A 12 pt face (1.0 pt cells) reaches 8.49 pt from its middle in the
        // corner of its square (the bow sits in that corner), the disc only 7.5: so the cell steps down to 0.5 pt on a 2x display (6 pt face,
        // corner reach 4.24) and the face is left out on a 1x display, where one pixel is a whole point.
        let small = IslandRows.diameter(geometry: IslandSamples.none22, sizeFactor: 1.3)
        let smallInner = AgentBubbleMetrics.innerDiameter(outer: small)
        check("the 18 pt bubble (22 pt bar): a 15 pt disc; 1.0 pt cells would not fit (corner reach 8.49 against 7.5), so 2x draws 0.5 pt cells (reach 4.24) and 1x draws no face",
              small == 18 && smallInner == 15 && !AgentBubbleMetrics.faceFits(cell: 1.0, inner: smallInner)
                && AgentBubbleMetrics.faceCell(inner: smallInner, scale: 2) == 0.5 && abs(AgentBubbleMetrics.cornerReach(cell: 0.5) - 4.2426) < 0.001
                && AgentBubbleMetrics.faceCell(inner: smallInner, scale: 1) == 0, "d \(small) inner \(smallInner)")
        // Where a face is drawn its absolute place is on whole device pixels: the bubble's own origin (row top, side line) plus the face's origin in it.
        var offGrid: [String] = []
        for g in geometries {
            for factor in IslandTuning.sizeFactors {
                for scale in [CGFloat(1), 2] {
                    let d = IslandRows.diameter(geometry: g, sizeFactor: factor)
                    if scale == 1, d != d.rounded() { continue }   // a half point is not a whole pixel on a 1x display (only the pill's sizes; a pill is never 1x)
                    let inner = AgentBubbleMetrics.innerDiameter(outer: d)
                    let cell = AgentBubbleMetrics.faceCell(inner: inner, scale: scale)
                    guard cell > 0 else { continue }
                    let origin = AgentBubbleMetrics.faceOrigin(outer: d, cell: cell, scale: scale)
                    let layout = IslandRows.layout(geometry: g, panelWidth: 1400, sizeFactor: factor, left: IslandRows.bubblePieces(ids: ["a", "b", "c", "d"], more: true, diameter: d), right: [],
                                                   displayScale: scale)
                    for placed in layout.left {
                        for (axis, value) in [("x", placed.rect.minX + origin), ("y", placed.rect.minY + origin)] where abs(value * scale - (value * scale).rounded()) > 1e-6 {
                            offGrid.append("\(g.kind) d \(d) @\(scale)x \(placed.name) \(axis) \(value)")
                        }
                    }
                }
            }
        }
        check("the face's absolute place (bubble origin plus face origin) is a whole device pixel on every sample display, size and scale (7 displays, 3 sizes, 1x and 2x)", offGrid.isEmpty, offGrid.prefix(3).joined(separator: "; "))
        check("every bubble of a display has one outer diameter: the ring is inside it (a 31 pt bubble has a 28 pt disc)",
              AgentBubbleMetrics.innerDiameter(outer: 31) == 28 && AgentBubbleMetrics.innerDiameter(outer: 20) == 17)
        check("\"+N\" shows at most 99+", AgentMoreBubble.text(1) == "+1" && AgentMoreBubble.text(99) == "+99" && AgentMoreBubble.text(100) == "99+" && AgentMoreBubble.text(400) == "99+")
        check("the ring by what the agent does: asking amber, finished green, stopped red, at work and asleep neutral",
              AgentBubbleRing(.asking) == .needs && AgentBubbleRing(.finished) == .finished && AgentBubbleRing(.stopped) == .stopped
                && AgentBubbleRing(.working) == .neutral && AgentBubbleRing(.idle) == .neutral)
        let breaths = stride(from: 0.0, to: 1.4, by: 0.02).map { BubbleRing.breath(at: $0) }
        check("the ask ring breathes between 0.45 and 1 once every 1.4 s",
              abs((breaths.min() ?? 0) - 0.45) < 0.01 && abs((breaths.max() ?? 0) - 1) < 0.01 && abs(BubbleRing.breath(at: 0) - BubbleRing.breath(at: 1.4)) < 1e-9)
        // The numbers below are written out here, so a constant changed in IslandTuning without the table (or the table's words) fails this line.
        let rows = Dictionary(IslandTuning.table.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        check("the tuning table's rows carry these literal values: clearance 6 pt, dot reserve 16 pt, gap 4 pt, side padding 8 pt, +N 10 pt bold rounded 99+, 4 bubbles then +N, ring 1.5 pt, ask breath 1.4 s, hover scale 1.08; every row has a name, a value and a mark",
              rows["Clearance each side of the housing"] == "6 pt" && rows["Dot reserve, right of a pill"] == "16 pt" && rows["Gap between shapes of a side"] == "4 pt" && rows["Capsule side padding"] == "8 pt"
                && rows["+N bubble"] == "10 pt bold rounded, 99+ at most" && rows["Bubbles shown"] == "4, then +N (99+ at most)" && rows["Bubble ring"] == "1.5 pt inside the outer diameter"
                && rows["Ask ring breath"] == "1.4 s, steady when calm" && rows["Hover"] == "ring 0.15 s; scale 1.08 when motion is on, grown from the bubble's top right corner (away from the housing)" && rows["Size factors"] == "1.0, 1.15, 1.3"
                && IslandTuning.clearance == 6 && IslandTuning.dotReserve == 16 && IslandTuning.gap == 4 && IslandTuning.capsulePadding == 8 && IslandTuning.moreFont == 10 && IslandTuning.moreCap == 99
                && IslandTuning.maxBubbles == 4 && IslandTuning.ringWidth == 1.5 && IslandTuning.askBreath == 1.4 && IslandTuning.hoverScale == 1.08 && IslandTuning.sizeFactors == [1.0, 1.15, 1.3]
                && IslandTuning.table.count >= 18 && IslandTuning.table.allSatisfy { !$0.name.isEmpty && !$0.value.isEmpty && !$0.mark.isEmpty }, "\(rows)")
        check("the top-edge limit of the row height is in the table: the classic notch in a 37 pt strip is 32 pt at every size, the strip limit alone would give 33",
              (rows["Row height, top edge"] ?? "").contains("32 pt") && IslandTuning.stripMargin == 4
                && IslandRows.diameter(geometry: IslandSamples.notch37, sizeFactor: 1.3) == 32 && IslandSamples.notch37.stripHeight - IslandTuning.stripMargin == 33)
        // The news capsule's one-line rule and its widths.
        check("the news is two lines in a capsule of 28 pt or more and one line under it; a short readout is a short capsule",
              IslandTuning.oneLineBelow == 28 && AgentWingRight.oneLineWidth("Done.") < 40 && AgentWingRight.oneLineWidth(String(repeating: "word ", count: 200)) == AgentWingRight.maxTextWidth)
    }

    // MARK: 2. At rest: nothing of Scout's

    private static func atRest(_ check: SuiteCheck) async {
        // A pill with nothing to show: not one opaque pixel of Scout's in the whole strip (and none in the panel).
        let pill = LookSelfTest.Rig(size: panel, open: false, geometry: .samplePill16)
        await settle()
        if let pixels = pill.snapshot(scale: 2) {
            let strip = pixels.opaqueCount(in: CGRect(x: 0, y: 0, width: panel.width, height: NotchGeometry.samplePill16.stripHeight))
            let whole = pixels.opaqueCount(in: CGRect(origin: .zero, size: panel))
            check("at rest on a pill: zero opaque pixels of Scout's in the whole strip (and in the whole panel)", strip == 0 && whole == 0, "strip \(strip), panel \(whole), scale \(pixels.rep.pixelsWide / Int(panel.width))x")
        } else {
            check("at rest on a pill: the panel draws", false)
        }
        pill.close()
        // The same pill with an activity that is not the agents (it waits for its own capsule and filter): still nothing.
        let other = LiveActivityCenter()
        other.show(LiveActivity(id: "test.timer", kind: .timer, leading: { Text(verbatim: "T") }, trailing: { Text(verbatim: "04:32") }))
        let pillOther = LookSelfTest.Rig(size: panel, open: false, geometry: .samplePill16, center: other)
        await settle()
        if let pixels = pillOther.snapshot(scale: 2) {
            check("a pill with another activity (not the agents) still draws nothing of Scout's", pixels.opaqueCount(in: CGRect(origin: .zero, size: panel)) == 0)
        }
        pillOther.close()
        // The classic notch at rest is still the black notch (the drawing of every version before).
        let classic = LookSelfTest.Rig(size: panel, open: false)
        await settle()
        if let pixels = classic.snapshot(scale: 2) {
            let hw = NotchGeometry.sample16.size
            check("the classic notch at rest is still black at its centre and draws nothing 6 pt beside it",
                  pixels.alpha(CGPoint(x: panel.width / 2, y: hw.height / 2)) > 0.99 && pixels.luminance(CGPoint(x: panel.width / 2, y: hw.height / 2)) < 0.06
                    && pixels.alpha(CGPoint(x: (panel.width - hw.width) / 2 - 6, y: hw.height / 2)) == 0 && pixels.alpha(CGPoint(x: (panel.width + hw.width) / 2 + 6, y: hw.height / 2)) == 0)
        }
        classic.close()
        // The drawn island at rest is its own small black capsule and nothing else.
        let drawn = LookSelfTest.Rig(size: panel, open: false, geometry: .sampleNone)
        await settle()
        if let pixels = drawn.snapshot(scale: 2) {
            let g = NotchGeometry.sampleNone
            let housing = g.housingRect(panelWidth: panel.width)
            let all = pixels.opaqueCount(in: CGRect(origin: .zero, size: panel))
            let inside = pixels.opaqueCount(in: housing)
            let middle = pixels.color(CGPoint(x: housing.midX, y: housing.midY))
            check("the drawn island at rest is a black capsule of 68 by 20 at 2 pt and nothing else", all > 0 && all == inside && (middle?.alphaComponent ?? 0) > 0.99 && pixels.luminance(CGPoint(x: housing.midX, y: housing.midY)) < 0.06,
                  "all \(all) inside \(inside)")
            check("  its hit rect is named \"drawn\" and is the housing", abs((drawn.model.hitRects["drawn"] ?? .zero).minX - housing.minX) < 0.6 && abs((drawn.model.hitRects["drawn"] ?? .zero).width - housing.width) < 0.6,
                  "\(String(describing: drawn.model.hitRects["drawn"]))")
        } else {
            check("the drawn island draws", false)
        }
        drawn.close()
    }

    // MARK: 3. Rows with agents and news

    private static func rows(_ check: SuiteCheck) async {
        typealias Case = (name: String, geometry: NotchGeometry)
        let cases: [Case] = [("pill", .samplePill16), ("tall pill", .samplePillTall), ("drawn island", .sampleNone), ("notch with bubbles", .sampleNotchBubbles), ("notch with bubbles in a 37 pt strip", IslandSamples.notch37)]
        for eightBit in [true, false] {
            Pref.set(eightBit, Retro.styleKey)
            for c in cases {
                let g = c.geometry
                AgentWingRight.lastRevealed = ""
                let store = IslandSamples.store([.working, .working, .finished, .needsYou, .working, .idle])
                let rig = LookSelfTest.Rig(size: panel, open: false, geometry: g, store: store)
                await settle()
                let look = "\(c.name), \(eightBit ? "8-bit" : "minimal")"
                let rects = rig.model.hitRects
                let summary = AgentWingSummary.make(sessions: store.sessions)
                let d = IslandRows.diameter(geometry: g, sizeFactor: 1)
                let layoutSpec = IslandRows.layout(geometry: g, panelWidth: panel.width, sizeFactor: 1, left: [], right: [])
                guard let pixels = rig.snapshot(scale: 2) else { check("\(look): the panel draws", false); rig.close(); continue }

                // The names and the places: where the view stands equals where the pure layout puts it.
                let newsRect = rects["capsule.news"]
                // The minimal look: the count at work is "bubble.more" (it opens the Agents room), the amber one carries the name of the agent that asks (a click focuses it).
                let leftNames = eightBit ? summary.faces.map { IslandHit.bubblePrefix + $0.id } + [IslandHit.more] : [IslandHit.more, IslandHit.bubblePrefix + (summary.firstAsking ?? "none")]
                let leftRects = leftNames.compactMap { rects[$0] }
                check("\(look): every shape reports its own named rect (\(leftNames.count) left, the news right)", leftRects.count == leftNames.count && newsRect != nil && rects.keys.allSatisfy { IslandHit.isHitName($0) },
                      "names \(rects.keys.sorted())")
                if leftRects.count == leftNames.count, let newsRect {
                    let layout = IslandRows.layout(geometry: g, panelWidth: panel.width, sizeFactor: 1,
                                                   left: leftNames.map { IslandRows.Piece(name: $0, width: d) },
                                                   right: [IslandRows.Piece(name: "capsule.news", width: newsRect.width)])
                    var off: [String] = []
                    for (placed, name) in zip(layout.left, leftNames) {
                        let got = rects[name] ?? .zero
                        if abs(got.minX - placed.rect.minX) > 0.6 || abs(got.minY - placed.rect.minY) > 0.6 || abs(got.width - placed.rect.width) > 0.6 || abs(got.height - placed.rect.height) > 0.6 {
                            off.append("\(name) is \(got), layout says \(placed.rect)")
                        }
                    }
                    if let placed = layout.right.first, abs(newsRect.minX - placed.rect.minX) > 0.6 || abs(newsRect.minY - placed.rect.minY) > 0.6 || abs(newsRect.height - placed.rect.height) > 0.6 {
                        off.append("news is \(newsRect), layout says \(placed.rect)")
                    }
                    check("\(look): the bubbles and the news stand where IslandRows puts them (one height \(d), 4 pt gaps, 6 pt clearance)", off.isEmpty, off.prefix(2).joined(separator: "; "))
                    // The news capsule is exactly as wide as its content plus the padding.
                    let text = "Which region?"
                    let contentWidth = 7 + 4 + (d < IslandTuning.oneLineBelow ? AgentWingRight.oneLineWidth(text) : AgentWingRight.textWidth(text))
                    let expected = IslandRows.capsuleWidth(content: contentWidth, scale: IslandRows.contentScale(geometry: g, sizeFactor: 1))
                    check("\(look): the news capsule is its content (dot, gap, \(d < 28 ? "one line" : "two lines")) plus 8 pt at each end: \(expected) pt", abs(newsRect.width - expected) < 0.75, "\(newsRect.width)")
                    // The gap between two bubbles is transparent.
                    var gapsOpaque: [String] = []
                    for (a, b) in zip(layout.left, layout.left.dropFirst()) {
                        let x = (a.rect.maxX + b.rect.minX) / 2
                        if pixels.alpha(CGPoint(x: x, y: layout.midY)) != 0 { gapsOpaque.append("\(a.name)/\(b.name) at x \(x)") }
                    }
                    check("\(look): the pixel between two bubbles is transparent (\(max(0, layout.left.count - 1)) gaps)", gapsOpaque.isEmpty, gapsOpaque.joined(separator: "; "))
                }
                // Nothing of Scout's in the housing, its clearance and (pill) the dot reserve; on a drawn island the housing is the black capsule itself.
                let keepOut = layoutSpec.keepOut
                let inKeepOut = pixels.opaqueCount(in: keepOut)
                let housing = layoutSpec.housing
                if g.kind == .none {
                    check("\(look): the clearance around the drawn capsule is transparent (everything in the keep-out is the capsule)", inKeepOut == pixels.opaqueCount(in: housing), "keep-out \(inKeepOut), capsule \(pixels.opaqueCount(in: housing))")
                } else {
                    check("\(look): alpha 0 in the housing, its 6 pt clearance\(g.kind == .pill ? " and the 16 pt dot reserve" : "")", inKeepOut == 0, "\(inKeepOut) opaque pixels in \(keepOut)")
                }
                rig.close()
            }
        }
        Pref.set(true, Retro.styleKey)

        // Sizes and colours: the row follows the size setting (31, 35.5, 40.5 on the pill) and the keep-out stays empty in the light colours.
        for (index, size) in Look.Size.allCases.enumerated() {
            for preset in Look.Preset.allCases {
                Pref.set(size.rawValue, Look.scaleKey)
                Pref.set(preset.rawValue, Look.presetKey)
                AgentWingRight.lastRevealed = ""
                let store = IslandSamples.store([.working, .needsYou, .finished, .working])
                let rig = LookSelfTest.Rig(size: panel, open: false, geometry: .samplePill16, store: store)
                await settle()
                let expectedD: [CGFloat] = [31, 35.5, 40.5]
                let rect = rig.model.hitRects.first { $0.key.hasPrefix("bubble.ag") }?.value ?? .zero
                let keepOut = IslandRows.keepOut(geometry: .samplePill16, panelWidth: panel.width)
                if let pixels = rig.snapshot(scale: 2) {
                    let enter = pixels.opaqueCount(in: keepOut)
                    check("pill, size \(size.title), \(preset.title) colours: every bubble is \(expectedD[index]) pt (one diameter) and the keep-out stays empty",
                          abs(rect.width - expectedD[index]) < 0.6 && abs(rect.height - expectedD[index]) < 0.6 && enter == 0, "bubble \(rect.size), keep-out pixels \(enter)")
                    // The drawn bubble stands on whole pixels: its top (the row moves to the nearest device pixel: 6.25 becomes 6.5 and 3.75 becomes 4 on a 2x display)
                    // and every bubble's left side, so the pixel face inside it does too. Read from the real view's reported rects, at this panel's own scale.
                    let scale = max(1, rig.panel.backingScaleFactor)
                    let places = rig.model.hitRects.filter { $0.key.hasPrefix("bubble.ag") }.values
                    let expectedY = ((24 - expectedD[index] / 2) * scale).rounded() / scale
                    let off = places.filter { abs($0.minY * scale - ($0.minY * scale).rounded()) > 0.02 || (scale >= 2 && abs($0.minX * scale - ($0.minX * scale).rounded()) > 0.02) }
                    check("  its top is \(expectedY) (the housing's middle 24 minus half of it, moved to the nearest device pixel at \(Int(scale))x) and every bubble stands on whole pixels",
                          !places.isEmpty && off.isEmpty && places.allSatisfy { abs($0.minY - expectedY) < 0.02 }, "tops \(places.map(\.minY)) off \(off.map(\.origin))")
                } else {
                    check("pill, size \(size.title): the panel draws", false)
                }
                rig.close()
            }
        }
        Pref.set(Look.Size.normal.rawValue, Look.scaleKey)
        Pref.set(Look.Preset.dark.rawValue, Look.presetKey)

        // Nine agents: four bubbles and "+5", the readout absent when nobody waits and nobody has a to-do list: no shape and no gap on the right.
        AgentWingRight.lastRevealed = ""
        let nine = IslandSamples.store([AgentNookLook](repeating: .working, count: 9))
        let rig = LookSelfTest.Rig(size: panel, open: false, geometry: .samplePill16, store: nine)
        await settle()
        let names = rig.model.hitRects.keys.sorted()
        check("nine agents at work on a pill: four bubbles and \"+5\", nothing on the right (no shape, no gap)",
              names.filter { $0.hasPrefix("bubble.ag") }.count == 4 && names.contains(IslandHit.more) && !names.contains("capsule.news") && AgentWingSummary.make(sessions: nine.sessions).moreFaces == 5, "\(names)")
        if let pixels = rig.snapshot(scale: 2) {
            let g = NotchGeometry.samplePill16
            let housing = g.housingRect(panelWidth: panel.width)
            check("  the right side of the strip is empty: no opaque pixel right of the housing", pixels.opaqueCount(in: CGRect(x: housing.maxX, y: 0, width: panel.width - housing.maxX, height: g.stripHeight)) == 0)
        }
        rig.close()
    }

    // MARK: 4. One bubble: face inside its disc, ring colours, hover, breath

    private static func bubbleShapes(_ check: SuiteCheck) async {
        func face(_ style: Int, _ mood: AgentFaceMood) -> AgentWingSummary.Face {
            AgentWingSummary.Face(id: "t\(style)", agent: style % 2 == 0 ? .claude : .codex, mood: mood, variant: AgentFaceArt.variant(style: style, colour: style + 1, skin: style))
        }
        // (18, 2) and (18, 1) are the smallest island there is (a 22 pt bar): 0.5 pt cells at 2x, no face at 1x.
        let outers: [(CGFloat, CGFloat)] = [(31, 2), (35.5, 2), (40.5, 2), (20, 2), (28, 2), (32, 2), (31, 1), (20, 1), (18, 2), (18, 1)]
        var outside: [String] = [], stray: [String] = [], noFace: [String] = [], renders = 0
        for (outer, scale) in outers {
            let size = CGSize(width: outer + 8, height: outer + 8)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let inner = AgentBubbleMetrics.innerDiameter(outer: outer)
            // Without a face: the disc and its ring only (steady colours: Reduce Motion is pinned on).
            guard let bare = await render(AgentBubble(face: face(1, .asking), label: "", diameter: outer, displayScale: scale, showsFace: false), size: size, scale: scale) else { continue }
            for style in 0...5 {
                guard let withFace = await render(AgentBubble(face: face(style, .asking), label: "", diameter: outer, displayScale: scale, frozenAt: 0.6), size: size, scale: scale) else { continue }
                renders += 1
                var facePixels = 0
                let px = withFace.rep.pixelsWide, py = withFace.rep.pixelsHigh
                for y in 0..<py {
                    for x in 0..<px {
                        let a = withFace.rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), b = bare.rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                        let point = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(px) * size.width, y: (CGFloat(y) + 0.5) / CGFloat(py) * size.height)
                        let r = hypot(point.x - center.x, point.y - center.y)
                        let alpha = Double(a?.alphaComponent ?? 0)
                        if alpha > 0.02, r > outer / 2 + 0.75 { stray.append("outer \(outer) @\(scale)x style \(style): a pixel at radius \(r)"); }
                        guard let a, let b else { continue }
                        let changed = abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) + abs(a.alphaComponent - b.alphaComponent) > 0.06
                        if changed {
                            facePixels += 1
                            if r > inner / 2 + 0.1 { outside.append("outer \(outer) @\(scale)x style \(style): a face pixel at radius \(r) beyond the disc's \(inner / 2)") }
                        }
                    }
                }
                if AgentBubbleMetrics.faceCell(inner: inner, scale: scale) == 0 {
                    if facePixels != 0 { noFace.append("outer \(outer) @\(scale)x style \(style): \(facePixels) face pixels where no face fits") }
                } else if facePixels < 20 {
                    noFace.append("outer \(outer) @\(scale)x style \(style): only \(facePixels) face pixels")
                }
            }
        }
        check("no face pixel lies outside its disc (0.1 pt tolerance): \(renders) bubbles (10 sizes and scales, the 18 pt island included; the 6 heads: bare, hair, cap, beanie, headphones, bow), corners included; where no face fits none is drawn",
              outside.isEmpty && noFace.isEmpty, (outside + noFace).prefix(3).joined(separator: "; "))
        check("  and no pixel of a bubble lies outside its outer circle (the ring is inside the one diameter)", stray.isEmpty, stray.prefix(3).joined(separator: "; "))

        // The ring colours of the states differ: amber, green, red, and the neutral hairline.
        let size = CGSize(width: 39, height: 39)
        var ring: [String: (r: Double, g: Double, b: Double)] = [:]
        for (name, mood) in [("needs", AgentFaceMood.asking), ("finished", .finished), ("stopped", .stopped), ("working", .working), ("asleep", .idle)] {
            if let pixels = await render(AgentBubble(face: face(1, mood), label: "", diameter: 31, showsFace: false), size: size) {
                ring[name] = rgb(pixels.color(CGPoint(x: size.width / 2 + 15.5 - 0.75, y: size.height / 2)))
            }
        }
        let names = ["needs", "finished", "stopped", "working"]
        var close: [String] = []
        for (i, a) in names.enumerated() { for b in names.dropFirst(i + 1) where distance(ring[a] ?? (0, 0, 0), ring[b] ?? (0, 0, 0)) < 0.25 { close.append("\(a)/\(b)") } }
        let neutral = ring["working"] ?? (1, 1, 1)
        check("the ring colours of the four states differ (amber, green, red, neutral), by at least 0.25 in colour", close.isEmpty && ring.count == 5, "too close \(close); \(ring)")
        check("  at work and asleep the ring is the same neutral hairline: dark grey, no hue", distance(neutral, ring["asleep"] ?? (0, 0, 0)) < 0.02 && neutral.r < 0.35 && abs(neutral.r - neutral.g) < 0.02 && abs(neutral.g - neutral.b) < 0.02, "\(neutral)")
        let needs = ring["needs"] ?? (0, 0, 0), finished = ring["finished"] ?? (0, 0, 0), stopped = ring["stopped"] ?? (0, 0, 0)
        check("  amber is orange (red high, blue low), finished is green, stopped is red", needs.r > 0.8 && needs.b < 0.3 && needs.g > 0.3 && finished.g > 0.6 && finished.r < 0.4 && stopped.r > 0.8 && stopped.g < 0.4, "\(needs) \(finished) \(stopped)")

        // Under the pointer the ring brightens.
        if let calm = await render(AgentBubble(face: face(1, .working), label: "", diameter: 31, hovered: false, showsFace: false), size: size),
           let hot = await render(AgentBubble(face: face(1, .working), label: "", diameter: 31, hovered: true, showsFace: false), size: size, wait: 0.4) {
            let p = CGPoint(x: size.width / 2 + 15.5 - 0.75, y: size.height / 2)
            check("a bubble under the pointer: the ring brightens (and with Reduce Motion on it does not grow)", calm.luminance(p) + 0.1 < hot.luminance(p), "\(calm.luminance(p)) -> \(hot.luminance(p))")
        }

        // "+N" carries the amber ring when a hidden agent needs you (only when more than four ask), and the neutral one otherwise.
        let askers = AgentWingSummary.make(sessions: IslandSamples.sessions([AgentNookLook](repeating: .needsYou, count: 6)))
        let workers = AgentWingSummary.make(sessions: IslandSamples.sessions([AgentNookLook](repeating: .working, count: 6)))
        check("a hidden agent that needs you makes the \"+N\" bubble amber: 6 asking agents (2 hidden) do, 6 at work do not",
              askers.moreFaces == 2 && askers.moreNeeds && workers.moreFaces == 2 && !workers.moreNeeds && askers.faces.count == 4, "\(askers.moreNeeds) \(workers.moreNeeds)")
        if let amber = await render(AgentMoreBubble(count: 2, needs: true, diameter: 31), size: size), let quiet = await render(AgentMoreBubble(count: 2, needs: false, diameter: 31), size: size) {
            let at = CGPoint(x: size.width / 2 + 15.5 - 0.75, y: size.height / 2)
            let a = rgb(amber.color(at)), q = rgb(quiet.color(at))
            check("  and its ring is orange, the quiet one's the neutral hairline", a.r > 0.8 && a.b < 0.3 && q.r < 0.35 && abs(q.r - q.b) < 0.02, "\(a) \(q)")
        }

        // The ask ring: steady under Reduce Motion, breathing otherwise (two looks half a breath apart).
        let p = CGPoint(x: size.width / 2 + 15.5 - 0.75, y: size.height / 2)
        ScoutRuntime.reduceMotionOverride = true
        var calmLevels: [Double] = []
        for _ in 0..<4 {
            if let r = await render(BubbleRing(kind: .needs, width: 1.5).frame(width: 31, height: 31), size: size, wait: 0.35) { calmLevels.append(Double(r.alpha(p))) }
        }
        ScoutRuntime.reduceMotionOverride = false
        var movingLevels: [Double] = []
        for _ in 0..<8 {
            if let r = await render(BubbleRing(kind: .needs, width: 1.5).frame(width: 31, height: 31), size: size, wait: 0.17) { movingLevels.append(Double(r.alpha(p))) }
        }
        ScoutRuntime.reduceMotionOverride = true
        check("the ask ring is steady under Reduce Motion", (calmLevels.max() ?? 0) - (calmLevels.min() ?? 1) < 0.02 && (calmLevels.min() ?? 0) > 0.9, "\(calmLevels)")
        check("  and breathes otherwise (its opacity moves by more than 0.2 across a second)", (movingLevels.max() ?? 0) - (movingLevels.min() ?? 1) > 0.2, "\(movingLevels)")
    }

    // MARK: 5. Capsules: the radio beside the agents, another activity on the drawn island

    private static func capsules(_ check: SuiteCheck) async {
        // The radio keeps its place after the news as a second capsule, 4 pt away, one height, on the same middle.
        AgentWingRight.lastRevealed = ""
        let store = IslandSamples.store([.working, .needsYou])
        let center = LiveActivityCenter()
        center.show(RadioNotchPresenter.sample())
        let pill = LookSelfTest.Rig(size: panel, open: false, geometry: .samplePill16, center: center, store: store)
        await settle()
        let rects = pill.model.hitRects
        if let news = rects["capsule.news"], let radio = rects["capsule.companion"], let pixels = pill.snapshot(scale: 2) {
            check("the radio beside the agents is a second capsule 4 pt after the news, one height (31), on the same middle",
                  abs(radio.minX - (news.maxX + 4)) < 0.6 && abs(radio.height - 31) < 0.6 && abs(news.height - 31) < 0.6 && abs(radio.midY - news.midY) < 0.3 && radio.width > 40,
                  "news \(news) radio \(radio)")
            check("  the keep-out stays empty with the radio there", pixels.opaqueCount(in: IslandRows.keepOut(geometry: .samplePill16, panelWidth: panel.width)) == 0)
        } else {
            check("the radio's capsule reports its rect", false, "\(rects.keys.sorted())")
        }
        pill.close()

        // Another activity on the drawn island: a capsule on each side, plain, one height; content taller than the capsule is scaled to fit.
        let other = LiveActivityCenter()
        other.show(LiveActivity(id: "test.timer", kind: .timer, leading: { Rectangle().fill(Color.white).frame(width: 14, height: 14) },
                                trailing: { Rectangle().fill(Color.white).frame(width: 30, height: 40) }))
        let drawn = LookSelfTest.Rig(size: panel, open: false, geometry: .sampleNone, center: other)
        await settle()
        let g = NotchGeometry.sampleNone
        let housing = g.housingRect(panelWidth: panel.width)
        if let lead = drawn.model.hitRects["capsule.lead"], let trail = drawn.model.hitRects["capsule.trail"], let pixels = drawn.snapshot(scale: 2) {
            check("drawn island, another activity: a capsule left (14 pt content, 30 wide) and one right (a 30 by 40 content scaled to fit 20 pt: 28 wide), 6 pt from the housing, 20 pt high",
                  abs(lead.width - 30) < 0.6 && abs(lead.maxX - (housing.minX - 6)) < 0.6 && abs(trail.minX - (housing.maxX + 6)) < 0.6 && abs(trail.width - 28) < 0.6
                    && abs(lead.height - 20) < 0.6 && abs(trail.height - 20) < 0.6 && abs(lead.midY - housing.midY) < 0.3, "lead \(lead) trail \(trail)")
            check("  nothing but the drawn capsule is in the clearance around it", pixels.opaqueCount(in: IslandRows.keepOut(geometry: g, panelWidth: panel.width)) == pixels.opaqueCount(in: housing))
        } else {
            check("drawn island, another activity: the capsules report their rects", false, "\(drawn.model.hitRects.keys.sorted())")
        }
        drawn.close()

        // A classic notch set to round bubbles keeps the classic drawing for another activity; a drawn island with a card up falls back to the tab.
        let notch = LookSelfTest.Rig(size: panel, open: false, geometry: .sampleNotchBubbles, center: other)
        await settle()
        check("a notch with round bubbles draws another activity the classic way (no rows, no named shapes)", notch.model.hitRects.isEmpty && notch.island.width > 185, "\(notch.model.hitRects.keys.sorted()) island \(notch.island)")
        notch.close()
        let carded = LiveActivityCenter()
        carded.present(NotchCard(id: "test.card", duration: 600) { Text(verbatim: "A card") })
        let tab = LookSelfTest.Rig(size: panel, open: false, geometry: .sampleNone, center: carded)
        await settle()
        check("a drawn island with a card up falls back to the tab's classic drawing (190 pt wide, no named shapes)", tab.model.hitRects.isEmpty && tab.island.width >= 190, "island \(tab.island)")
        tab.close()
    }

    // MARK: 5b. Hover: the pointer's name reaches the shape that carries it

    /// The point of a named shape where its ring or rim shows: a bubble's ring on its right side, a capsule's hairline at its top.
    private static func probe(_ name: String, _ rect: CGRect) -> CGPoint {
        name.hasPrefix(IslandHit.capsulePrefix) || name == IslandHit.drawn ? CGPoint(x: rect.midX, y: rect.minY + 0.5) : CGPoint(x: rect.maxX - 0.75, y: rect.midY)
    }

    /// The widest the opaque shape near `rect` gets across its rows, in points (read at 2x: a pixel centre every half point).
    private static func width(_ pixels: Pixels, near rect: CGRect) -> CGFloat {
        var best: CGFloat = 0
        for y in stride(from: rect.minY - 1.75, through: rect.maxY + 3.25, by: 0.5) {
            var count = 0
            for x in stride(from: rect.minX - 3.25, through: rect.maxX + 0.75, by: 0.5) where pixels.alpha(CGPoint(x: x, y: y)) > 0.5 { count += 1 }
            best = max(best, CGFloat(count) * 0.5)
        }
        return best
    }

    /// Through the real root view: `model.hoveredHit` becomes the context's `hovered`, and the shape with exactly that name draws its ring or rim
    /// lighter while every other shape stays as it was. Each name in `names` is hovered in turn and compared with the picture of nobody hovered.
    private static func wired(_ check: SuiteCheck, _ title: String, geometry: NotchGeometry, eightBit: Bool, store: AgentsStore?, center: LiveActivityCenter? = nil,
                              names: (AgentWingSummary) -> [String]) async {
        Pref.set(eightBit, Retro.styleKey)
        AgentWingRight.lastRevealed = ""
        let rig = LookSelfTest.Rig(size: panel, open: false, geometry: geometry, center: center, store: store)
        await settle()
        let wanted = names(AgentWingSummary.make(sessions: store?.sessions ?? []))
        let rects = rig.model.hitRects
        guard !wanted.isEmpty, wanted.allSatisfy({ rects[$0] != nil }), let base = rig.snapshot(scale: 2) else {
            check("\(title): every named shape reports its rect and the panel draws", false, "wanted \(wanted), got \(rects.keys.sorted())")
            rig.close()
            return
        }
        var wrong: [String] = []
        for name in wanted {
            rig.model.hoveredHit = name
            await settle(0.5)
            guard let hot = rig.snapshot(scale: 2) else { wrong.append("\(name): no picture"); continue }
            for other in wanted {
                let change = hot.luminance(probe(other, rects[other] ?? .zero)) - base.luminance(probe(other, rects[other] ?? .zero))
                if other == name, change < 0.08 { wrong.append("\(name) hovered: its own ring or rim changed by \(change)") }
                if other != name, abs(change) > 0.02 { wrong.append("\(name) hovered: \(other) changed by \(change)") }
            }
        }
        rig.model.hoveredHit = nil
        check("\(title): hovering each of \(wanted.count) names (\(wanted.map { $0.replacingOccurrences(of: "bubble.", with: "b.") }.joined(separator: ", "))) lights that shape's ring or rim and no other", wrong.isEmpty, wrong.prefix(3).joined(separator: "; "))
        rig.close()
    }

    private static func hover(_ check: SuiteCheck) async {
        let six: [AgentNookLook] = [.working, .working, .finished, .needsYou, .working, .idle]
        let radio = LiveActivityCenter()
        radio.show(RadioNotchPresenter.sample())
        let store = IslandSamples.store(six)
        let faces = AgentWingSummary.make(sessions: store.sessions).faces
        await wired(check, "pill, 8-bit, six agents with the radio", geometry: .samplePill16, eightBit: true, store: store, center: radio) { _ in
            [IslandHit.bubblePrefix + faces[0].id, IslandHit.bubblePrefix + faces[faces.count - 1].id, IslandHit.more, "capsule.news", "capsule.companion"]
        }
        await wired(check, "pill, minimal look", geometry: .samplePill16, eightBit: false, store: IslandSamples.store(six)) { summary in
            [IslandHit.more, IslandHit.bubblePrefix + (summary.firstAsking ?? "none"), "capsule.news"]
        }
        let other = LiveActivityCenter()
        other.show(LiveActivity(id: "test.timer", kind: .timer, leading: { Rectangle().fill(Color.white).frame(width: 14, height: 14) },
                                trailing: { Rectangle().fill(Color.white).frame(width: 30, height: 40) }))
        await wired(check, "drawn island, another activity", geometry: .sampleNone, eightBit: true, store: nil, center: other) { _ in ["capsule.lead", "capsule.trail", IslandHit.drawn] }
        Pref.set(true, Retro.styleKey)

        // The small scale: a hovered bubble grows by 1.08 when motion is allowed and keeps its size under Reduce Motion. The bubble next to the housing is the
        // test: its growth must not enter the clearance (nothing of it is cut flat there) and its round edge must stay round.
        for calm in [true, false] {
            ScoutRuntime.reduceMotionOverride = calm
            let still = IslandSamples.store([.working, .working, .working])
            let rig = LookSelfTest.Rig(size: panel, open: false, geometry: .samplePill16, store: still)
            await settle()
            let nearestName = rig.model.hitRects.filter { $0.key.hasPrefix("bubble.ag") }.max { $0.value.maxX < $1.value.maxX }?.key ?? "none"
            guard let rect = rig.model.hitRects[nearestName], let rest = rig.snapshot(scale: 2) else { check("hover scale: the nearest bubble reports its rect", false); rig.close(); continue }
            let restWidth = width(rest, near: rect)
            rig.model.hoveredHit = nearestName
            await settle(0.7)
            if let hot = rig.snapshot(scale: 2) {
                let hotWidth = width(hot, near: rect)
                let expected = calm ? rect.width : rect.width * IslandTuning.hoverScale
                let keepOut = IslandRows.keepOut(geometry: .samplePill16, panelWidth: panel.width)
                let edgeBand = hot.opaqueCount(in: CGRect(x: rect.maxX - 0.5, y: 0, width: 0.5, height: NotchGeometry.samplePill16.stripHeight))
                check("hovering the bubble next to the pill with Reduce Motion \(calm ? "on" : "off"): it \(calm ? "keeps its size" : "grows by 1.08") (\(String(format: "%.1f", restWidth)) to \(String(format: "%.1f", hotWidth)) pt, wanted \(String(format: "%.1f", expected))), the keep-out stays empty and its edge toward the pill stays round (a round edge touches the last half point with about 16 pixels, a cut one with 30)",
                      abs(restWidth - rect.width) < 0.6 && abs(hotWidth - expected) < 0.6 && hot.opaqueCount(in: keepOut) == 0 && edgeBand <= 20, "rest \(restWidth) hot \(hotWidth) keep-out \(hot.opaqueCount(in: keepOut)) edge band \(edgeBand)")
            } else {
                check("hover scale: the panel draws", false)
            }
            rig.close()
        }
        ScoutRuntime.reduceMotionOverride = true
    }

    // MARK: 6. Real clicks

    private static func clicks(_ check: SuiteCheck) async {
        for (name, geometry) in [("drawn island", NotchGeometry.sampleNone), ("notch with bubbles", .sampleNotchBubbles)] {
            AgentWingRight.lastRevealed = ""
            let store = IslandSamples.store([.working, .working, .finished, .working])
            let rig = LookSelfTest.Rig(size: panel, open: false, geometry: geometry, store: store)
            await settle()
            let faces = AgentWingSummary.make(sessions: store.sessions).faces
            let second = "bubble.\(faces[1].id)"
            if let rect = rig.model.hitRects[second] {
                rig.click(CGPoint(x: rect.midX, y: rect.midY))
                await settle(0.3)
                check("\(name): a real click on the second bubble focuses that agent and opens the Agents room", store.focusID == faces[1].id && rig.navigator.isOpen && rig.navigator.workspace == .agents,
                      "focus \(store.focusID ?? "nil") open \(rig.navigator.isOpen) workspace \(rig.navigator.workspace)")
                // Between two bubbles nothing is hit.
                store.focusID = nil
                rig.navigator.forceClose()
                if let first = rig.model.hitRects["bubble.\(faces[0].id)"] {
                    rig.click(CGPoint(x: (first.maxX + rect.minX) / 2, y: first.midY))
                    await settle(0.3)
                    check("  a click between two bubbles opens nothing and focuses nobody", !rig.navigator.isOpen && store.focusID == nil, "open \(rig.navigator.isOpen) focus \(store.focusID ?? "nil")")
                }
            } else {
                check("\(name): the second bubble reports its rect", false, "\(rig.model.hitRects.keys.sorted())")
            }
            if geometry.kind == .none {
                if let drawn = rig.model.hitRects["drawn"] {
                    rig.navigator.forceClose()
                    rig.click(CGPoint(x: drawn.midX, y: drawn.midY))
                    await settle(0.3)
                    check("  a click on the drawn capsule opens the dashboard", rig.navigator.isOpen, "open \(rig.navigator.isOpen)")
                }
            } else {
                // The physical notch of a classic notch is still a target (a click opens it, as it always did; the rows draw an invisible
                // one over it). The housing of a camera pill never is (this loop has no pill: its rule is in island.selftest.hit).
                rig.navigator.forceClose()
                rig.click(CGPoint(x: panel.width / 2, y: geometry.size.height / 2))
                await settle(0.3)
                check("  a click in the classic notch itself opens the dashboard from the rows", rig.navigator.isOpen, "open \(rig.navigator.isOpen)")
            }
            rig.close()
        }
        // The minimal look: the amber bubble stands for the agent that asks (a click focuses it and opens the Agents room), the count at work opens the room alone.
        Pref.set(false, Retro.styleKey)
        for (name, geometry) in [("drawn island", NotchGeometry.sampleNone), ("notch with bubbles", .sampleNotchBubbles)] {
            AgentWingRight.lastRevealed = ""
            let minimal = IslandSamples.store([.working, .working, .needsYou])
            let rig = LookSelfTest.Rig(size: panel, open: false, geometry: geometry, store: minimal)
            await settle()
            let summary = AgentWingSummary.make(sessions: minimal.sessions)
            let amber = IslandHit.bubblePrefix + (summary.firstAsking ?? "none")
            if let rect = rig.model.hitRects[amber], let count = rig.model.hitRects[IslandHit.more] {
                rig.click(CGPoint(x: rect.midX, y: rect.midY))
                await settle(0.3)
                check("minimal look, \(name): a real click on the amber bubble focuses the agent that asks (\(summary.firstAsking ?? "none")) and opens the Agents room",
                      summary.firstAsking == "ag-2" && minimal.focusID == "ag-2" && rig.navigator.isOpen && rig.navigator.workspace == .agents, "focus \(minimal.focusID ?? "nil") open \(rig.navigator.isOpen) \(rig.navigator.workspace)")
                minimal.focusID = nil
                rig.navigator.forceClose()
                rig.click(CGPoint(x: count.midX, y: count.midY))
                await settle(0.3)
                check("  and a click on the count at work opens the Agents room with nobody focused", minimal.focusID == nil && rig.navigator.isOpen && rig.navigator.workspace == .agents,
                      "focus \(minimal.focusID ?? "nil") open \(rig.navigator.isOpen) \(rig.navigator.workspace)")
            } else {
                check("minimal look, \(name): the amber bubble reports its rect under the asking agent's own name", false, "\(rig.model.hitRects.keys.sorted())")
            }
            rig.close()
        }
        Pref.set(true, Retro.styleKey)

        // One rule for every shape of the rows: with Settings > Notch > Clicking the notch opens it OFF, a bubble, the news capsule, another activity's two
        // capsules and the drawn capsule take no click; with it ON the same clicks open the room (so the clicks did reach the shapes). The news capsule's own
        // ON click is not made: the agents' activity opens the app's shared navigator, which a test must not touch.
        AgentWingRight.lastRevealed = ""
        let asks = IslandSamples.store([.working, .needsYou])
        let timer = LiveActivityCenter()
        timer.show(LiveActivity(id: "test.timer", kind: .timer, leading: { Rectangle().fill(Color.white).frame(width: 14, height: 14) }, trailing: { Rectangle().fill(Color.white).frame(width: 30, height: 14) }))
        let agentsRig = LookSelfTest.Rig(size: panel, open: false, geometry: .sampleNone, store: asks)
        let timerRig = LookSelfTest.Rig(size: panel, open: false, geometry: .sampleNone, center: timer)
        await settle()
        var ignored: [String] = [], opened: [String] = [], tried = 0
        for on in [false, true] {
            Pref.set(on, clickKey)
            for (rig, shape) in [(agentsRig, "bubble.ag-0"), (agentsRig, "capsule.news"), (agentsRig, "drawn"), (timerRig, "capsule.lead"), (timerRig, "capsule.trail"), (timerRig, "drawn")] {
                if on, shape == "capsule.news" { continue }
                guard let rect = rig.model.hitRects[shape] else { ignored.append("\(shape) has no rect"); continue }
                tried += 1
                asks.focusID = nil
                rig.navigator.forceClose()
                rig.click(CGPoint(x: rect.midX, y: rect.midY))
                await settle(0.25)
                if on, !rig.navigator.isOpen { opened.append(shape) }
                if !on, rig.navigator.isOpen || asks.focusID != nil { ignored.append(shape) }
            }
        }
        Pref.set(true, clickKey)
        check("clicking the notch opens it OFF: a bubble, the news capsule, another activity's capsules and the drawn capsule ignore a real click; ON: the same clicks open the room (\(tried) clicks)",
              ignored.isEmpty && opened.isEmpty && tried == 11, "opened while off: \(ignored); not opened while on: \(opened); tried \(tried)")
        agentsRig.close()
        timerRig.close()

        // A pill: the rows are there, a click on a bubble does nothing (the dashboard does not open on a pill in this build).
        AgentWingRight.lastRevealed = ""
        let store = IslandSamples.store([.working, .working, .needsYou])
        let rig = LookSelfTest.Rig(size: panel, open: false, geometry: .samplePill16, store: store)
        await settle()
        let faces = AgentWingSummary.make(sessions: store.sessions).faces
        let name = "bubble.\(faces[1].id)"
        if let rect = rig.model.hitRects[name] {
            rig.click(CGPoint(x: rect.midX, y: rect.midY))
            await settle(0.3)
            check("pill: a real click on a bubble opens nothing and focuses nobody", !rig.navigator.isOpen && store.focusID == nil, "open \(rig.navigator.isOpen) focus \(store.focusID ?? "nil")")
        } else {
            check("pill: the bubble reports its rect", false)
        }
        let nav = NotchNavigator()
        let asked = IslandHit.perform(name, geometry: .samplePill16, navigator: nav, agents: store)
        let housing = NotchGeometry.samplePill16.housingRect(panelWidth: panel.width)
        rig.click(CGPoint(x: housing.midX, y: housing.midY))
        await settle(0.3)
        check("pill: IslandHit.perform returns false and opens nothing; a click in the housing hits nothing", !asked && !nav.isOpen && !rig.navigator.isOpen, "perform \(asked)")
        rig.close()
    }

    // MARK: 7. Motion: both versions

    private static func motion(_ check: SuiteCheck) async {
        let g = NotchGeometry.samplePill16
        for calm in [true, false] {
            ScoutRuntime.reduceMotionOverride = calm
            AgentWingRight.lastRevealed = ""
            let store = AgentsStore()
            store.loadSessions([IslandSamples.session(0, .working)])
            let rig = LookSelfTest.Rig(size: panel, open: false, geometry: g, store: store)
            await settle(1.2)
            func leftRow() -> CGRect { union(rig.model.hitRects.filter { $0.key.hasPrefix("bubble.") }.map(\.value)) }
            let before = leftRow().width
            // A second agent comes: the row grows by one bubble and a gap (31 + 4).
            store.loadSessions([IslandSamples.session(0, .working), IslandSamples.session(1, .working)])
            var samples: [(t: Double, w: Double)] = []
            var frames = 0, intruded = 0
            let keepOutRect = IslandRows.keepOut(geometry: g, panelWidth: panel.width)
            /// One picture per sample: no pixel of Scout's in the housing, its clearance and the dot reserve, in this frame of the animation.
            func watch() { if let pixels = rig.snapshot(scale: 2) { frames += 1; intruded += pixels.opaqueCount(in: keepOutRect) } }
            let start = Date()
            for _ in 0..<40 {
                await settle(0.04)
                samples.append((Date().timeIntervalSince(start), Double(leftRow().width)))
                watch()
            }
            let target = 2 * 31 + 4
            let late = samples.filter { $0.t >= (calm ? 0.45 : 1.6) }
            let monotonic = zip(samples, samples.dropFirst()).allSatisfy { $1.w >= $0.w - 0.05 }
            let keepOut = IslandRows.keepOut(geometry: g, panelWidth: panel.width)
            let nearest = rig.model.hitRects.filter { $0.key.hasPrefix("bubble.") }.map(\.value.maxX).max() ?? 0
            check("\(calm ? "calm" : "moving"): a second agent widens the row from \(Int(before)) to \(target) pt\(calm ? ", never narrower on the way, and within 0.5 pt of it by 0.4 s" : " (it may overshoot) and within 0.5 pt of it by 1.5 s")",
                  abs(before - 31) < 0.6 && !late.isEmpty && late.allSatisfy { abs($0.w - Double(target)) <= 0.5 } && (calm ? monotonic : true) && nearest <= keepOut.minX + 0.6,
                  "before \(before), samples \(samples.map { String(format: "%.1f", $0.w) }.joined(separator: " "))")
            // The news: a question arrives, the capsule grows in (width and fade when calm, scale and fade otherwise) and ends at its content's width.
            store.loadSessions([IslandSamples.session(0, .working), IslandSamples.session(1, .needsYou)])
            var news: [Double] = [], starts: [Double] = []
            for _ in 0..<40 {
                await settle(0.04)
                let rect = rig.model.hitRects["capsule.news"]
                news.append(Double(rect?.width ?? 0))
                if let rect, rect.width > 0.5 { starts.append(Double(rect.minX)) }
                watch()
            }
            let rightStart = Double(g.housingRect(panelWidth: panel.width).maxX + 6 + 16)
            check("\(calm ? "calm" : "moving"): the capsule never travels while it grows in: it starts 22 pt right of the pill in every frame (\(starts.count) samples)",
                  !starts.isEmpty && starts.allSatisfy { abs($0 - rightStart) <= 0.6 }, "starts \(starts.map { String(format: "%.1f", $0) }.joined(separator: " "))")
            let finalWidth = IslandRows.capsuleWidth(content: 7 + 4 + AgentWingRight.textWidth("Which region?"), scale: 1)
            let newsMonotonic = zip(news, news.dropFirst()).allSatisfy { $1 >= $0 - 0.05 }
            check("\(calm ? "calm" : "moving"): the news capsule ends at \(Int(finalWidth)) pt\(calm ? " and only ever grows (width and fade, no travel)" : "")",
                  abs((news.last ?? 0) - Double(finalWidth)) <= 0.75 && (calm ? newsMonotonic : true), "\(news.map { String(format: "%.0f", $0) }.joined(separator: " "))")
            // The bubble next to the pill is under the pointer while a third agent comes: it grows by 1.08 (moving) and steps outward with the row.
            let hoverTarget = rig.model.hitRects.filter { $0.key.hasPrefix("bubble.ag") }.max { $0.value.maxX < $1.value.maxX }?.key
            rig.model.hoveredHit = hoverTarget
            for _ in 0..<8 { await settle(0.05); watch() }
            store.loadSessions([IslandSamples.session(0, .working), IslandSamples.session(1, .needsYou), IslandSamples.session(2, .working)])
            for _ in 0..<30 { await settle(0.04); watch() }
            check("\(calm ? "calm" : "moving"): in every one of \(frames) pictures taken while the row widens, the news grows in and a hovered bubble steps outward, not one pixel of Scout's is in the housing, its clearance or the dot reserve",
                  frames >= 100 && intruded == 0, "\(intruded) opaque pixels in \(frames) frames")
            rig.close()
        }
        ScoutRuntime.reduceMotionOverride = true
    }
}
