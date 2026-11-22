import AppKit

/// `scout://island.selftest.layout?out=<file>` (headless): where the bubbles and capsules stand beside the housing, in numbers. `IslandRows` is a
/// pure function: every expected number below is worked out here from the rules, not read back from it. The agents are called AGENTS in every line.
@MainActor
enum IslandLayoutSelfTest {
    static func register() {
        SuiteCheck.register("island.selftest.layout", suite: "island layout") { check in
            tables(check)
            named(check)
            edges(check)
        }
    }

    private typealias Sample = (name: String, geometry: NotchGeometry, diameters: [CGFloat])

    /// The four main samples and three more (the classic notch in its real 37 pt strip, the drawn island in a 37 pt bar and in the lowest
    /// bar of 22 pt). The diameter of each at the three size factors, worked out by hand: housing height times the factor in half points, at most
    /// the strip minus 4 pt, and (centred on the housing) never above the top edge: pill 31 gives 31, 35.65 -> 35.5, 40.3 -> 40.5; the tall pill
    /// 40, 46, 52 (cap 52); the drawn island 20 (cap 20); the drawn island in a 22 pt bar 18 (cap 18); beside a classic notch the row is as
    /// tall as the notch, 32, at every size and in every strip (the notch touches the top edge: the strip's margin does not count there).
    private static let samples: [Sample] = [
        ("pill 16 inch", .samplePill16, [31, 35.5, 40.5]),
        ("tall pill", .samplePillTall, [40, 46, 52]),
        ("drawn island, bar 24", .sampleNone, [20, 20, 20]),
        ("notch with bubbles, strip 32", .sampleNotchBubbles, [32, 32, 32]),
        ("notch with bubbles, strip 37", IslandSamples.notch37, [32, 32, 32]),
        ("drawn island, bar 37", IslandSamples.none37, [32, 33, 33]),
        ("drawn island, bar 22", IslandSamples.none22, [18, 18, 18]),
    ]
    private static let factors: [CGFloat] = [1.0, 1.15, 1.3]
    private static let panelWidth: CGFloat = 1400
    private static let newsWidth: CGFloat = 120
    private static let companionWidth: CGFloat = 60

    // MARK: 0 to 9 agents, three size factors, every sample

    private static func tables(_ check: SuiteCheck) {
        var wrongDiameter: [String] = [], wrongWidth: [String] = [], wrongNearest: [String] = [], wrongRight: [String] = [], wrongMiddle: [String] = []
        var wrongEmpty: [String] = [], wrongHeight: [String] = [], wrongKeepOut: [String] = [], wrongGap: [String] = [], wrongPixels: [String] = [], rows = 0
        for sample in samples {
            let g = sample.geometry
            let housing = CGRect(x: (panelWidth - g.size.width) / 2, y: g.topInset, width: g.size.width, height: g.size.height)
            // Each side's start line is 6 pt from the housing (22 pt right of a pill), moved AWAY from it onto a whole device pixel (a half point at 2x):
            // the drawn island of a 37 pt bar is 108.8 wide, so its left line 639.6 becomes 639.5 and its right line 760.4 becomes 760.5.
            let leftLine = ((housing.minX - 6) * 2).rounded(.down) / 2
            let rightStart = ((housing.maxX + 6 + (g.kind == .pill ? 16 : 0)) * 2).rounded(.up) / 2
            for (f, factor) in factors.enumerated() {
                let d = sample.diameters[f]
                for agents in 0...9 {
                    rows += 1
                    let label = "\(sample.name), \(agents) agents, factor \(factor)"
                    let shown = min(agents, 4)
                    let more = agents > 4
                    let ids = (0..<shown).map { "a\($0)" }
                    let pieces = IslandRows.bubblePieces(ids: ids, more: more, diameter: d)
                    let layout = IslandRows.layout(geometry: g, panelWidth: panelWidth, sizeFactor: factor, left: pieces,
                                                   right: [IslandRows.Piece(name: "capsule.news", width: newsWidth), IslandRows.Piece(name: "capsule.companion", width: companionWidth)])
                    if layout.diameter != d { wrongDiameter.append("\(label): \(layout.diameter) not \(d)") }
                    let shapes = shown + (more ? 1 : 0)
                    // The row's width: n bubbles, 4 pt between them; an empty side has no shape and no gap.
                    let expectedWidth = shapes == 0 ? 0 : CGFloat(shapes) * d + CGFloat(shapes - 1) * 4
                    if abs(layout.leftRow.width - expectedWidth) > 0.001 || layout.left.count != shapes { wrongWidth.append("\(label): \(layout.leftRow.width) not \(expectedWidth)") }
                    if shapes == 0 {
                        if layout.leftRow != .zero || !layout.left.isEmpty { wrongEmpty.append(label) }
                    } else {
                        // The nearest bubble ends 6 pt left of the housing; the "+N" is the nearest when there is one; the first agent is outermost.
                        if abs(layout.left.last!.rect.maxX - leftLine) > 0.001 { wrongNearest.append("\(label): ends \(layout.left.last!.rect.maxX) not \(leftLine)") }
                        if more, layout.left.last!.name != IslandHit.more { wrongNearest.append("\(label): +N is not nearest") }
                        if shown > 0, layout.left.first!.name != "bubble.a0" { wrongNearest.append("\(label): the first agent is not outermost") }
                        for (a, b) in zip(layout.left, layout.left.dropFirst()) where abs(b.rect.minX - a.rect.maxX - 4) > 0.001 { wrongGap.append("\(label): gap \(b.rect.minX - a.rect.maxX)") }
                    }
                    // The right capsule starts 6 pt right of the housing (22 on a pill: the dot reserve); the radio follows 4 pt later.
                    if layout.right.count != 2 || abs(layout.right[0].rect.minX - rightStart) > 0.001 || abs(layout.right[0].rect.width - newsWidth) > 0.001
                        || abs(layout.right[1].rect.minX - (rightStart + newsWidth + 4)) > 0.001 {
                        wrongRight.append("\(label): \(layout.right.map { $0.rect.minX }) not from \(rightStart)")
                    }
                    // Every shape is exactly d tall and centred on the housing's vertical middle, within the 0.25 pt the move onto a whole device pixel may cost
                    // (a pill's 35.5 and 40.5 stand at 6.5 and 4 instead of 6.25 and 3.75); its top is a whole pixel at 2x.
                    for placed in layout.left + layout.right {
                        if abs(placed.rect.midY - housing.midY) > 0.25 + 0.001 { wrongMiddle.append("\(label): \(placed.name) middle \(placed.rect.midY) not \(housing.midY)") }
                        if abs(placed.rect.minY * 2 - (placed.rect.minY * 2).rounded()) > 1e-6 || abs(placed.rect.minX * 2 - (placed.rect.minX * 2).rounded()) > 1e-6 { wrongPixels.append("\(label): \(placed.name) at \(placed.rect.origin)") }
                        if abs(placed.rect.height - d) > 0.001 { wrongHeight.append("\(label): \(placed.name) height \(placed.rect.height)") }
                        if placed.rect.minY < -0.001 || placed.rect.maxY > g.stripHeight + 0.001 { wrongHeight.append("\(label): \(placed.name) leaves the strip \(placed.rect.minY) to \(placed.rect.maxY)") }
                        if IslandRows.overlaps(placed.rect, layout.keepOut) { wrongKeepOut.append("\(label): \(placed.name) enters the keep-out") }
                    }
                    if g.kind != .notch, d > g.stripHeight - 4 + 0.001 { wrongHeight.append("\(label): d \(d) over strip \(g.stripHeight) minus 4") }
                    if d.truncatingRemainder(dividingBy: 0.5) != 0 { wrongHeight.append("\(label): d \(d) is not in half points") }
                }
            }
        }
        let total = "\(rows) combinations"
        check("every shape's left side and top are whole device pixels at 2x (\(total))", wrongPixels.isEmpty, wrongPixels.prefix(4).joined(separator: "; "))
        check("the row's height: the housing's height times the factor in half points, at most the strip minus 4 pt (\(total))", wrongDiameter.isEmpty, wrongDiameter.prefix(4).joined(separator: "; "))
        check("the left row is n bubbles and 4 pt gaps wide, \"+N\" included: 0 to 9 agents, 7 samples, 3 factors (\(total))", wrongWidth.isEmpty, wrongWidth.prefix(4).joined(separator: "; "))
        check("the nearest bubble ends 6 pt left of the housing (moved left onto a device pixel); \"+N\" is the nearest; the first agent started is outermost (\(total))", wrongNearest.isEmpty, wrongNearest.prefix(4).joined(separator: "; "))
        check("the gap between two bubbles is 4 pt (\(total))", wrongGap.isEmpty, wrongGap.prefix(4).joined(separator: "; "))
        check("the right capsule starts 6 pt right of the housing (moved right onto a device pixel), 22 pt on a pill (the dot reserve), the radio 4 pt after it (\(total))", wrongRight.isEmpty, wrongRight.prefix(4).joined(separator: "; "))
        check("every shape is centred on the housing's vertical middle, within the 0.25 pt of the move onto a device pixel (\(total))", wrongMiddle.isEmpty, wrongMiddle.prefix(4).joined(separator: "; "))
        check("every shape is one height, in half points; beside a pill or the drawn island inside the strip minus 4 pt, beside a notch as tall as the notch (\(total))", wrongHeight.isEmpty, wrongHeight.prefix(4).joined(separator: "; "))
        check("a side with no agents has no shape and no gap (\(total))", wrongEmpty.isEmpty, wrongEmpty.prefix(4).joined(separator: "; "))
        check("nothing ever enters the housing plus 6 pt (plus the 16 pt reserve right of a pill) (\(total))", wrongKeepOut.isEmpty, wrongKeepOut.prefix(4).joined(separator: "; "))
    }

    // MARK: Rows with the numbers written out

    private static func named(_ check: SuiteCheck) {
        // The pill: housing 58 by 31 at 8.5, centred in 1400: x 671 to 729, middle 24.
        let pill = IslandRows.layout(geometry: .samplePill16, panelWidth: 1400, sizeFactor: 1,
                                     left: IslandRows.bubblePieces(ids: ["a", "b", "c", "d"], more: true, diameter: 31),
                                     right: [IslandRows.Piece(name: "capsule.news", width: 150)])
        check("pill, 4 agents and \"+N\": five bubbles of 31 span 494 to 665, the right capsule 751 to 901, all on the middle 24",
              pill.leftRow == CGRect(x: 494, y: 8.5, width: 171, height: 31) && pill.right[0].rect == CGRect(x: 751, y: 8.5, width: 150, height: 31)
                && pill.midY == 24 && pill.housing == CGRect(x: 671, y: 8.5, width: 58, height: 31) && pill.keepOut == CGRect(x: 665, y: 2.5, width: 86, height: 43),
              "\(pill.leftRow) \(pill.right.map(\.rect)) \(pill.keepOut)")
        // The drawn island: housing 68 by 20 at 2, x 666 to 734; no dot reserve; d 20 at every factor (a 24 pt bar).
        let drawn = IslandRows.layout(geometry: .sampleNone, panelWidth: 1400, sizeFactor: 1.3,
                                      left: IslandRows.bubblePieces(ids: ["a", "b"], more: false, diameter: 20), right: [IslandRows.Piece(name: "capsule.news", width: 90)])
        check("drawn island, 2 agents at the biggest size: bubbles stay 20 (the bar is 24): 616 to 660, capsule 740 to 830, middle 12",
              drawn.leftRow == CGRect(x: 616, y: 2, width: 44, height: 20) && drawn.right[0].rect == CGRect(x: 740, y: 2, width: 90, height: 20) && drawn.midY == 12,
              "\(drawn.leftRow) \(drawn.right.map(\.rect))")
        // The classic notch with bubbles: housing 185 by 32 flush, x 607.5 to 792.5; the row is as tall as the notch, 32.
        let notch = IslandRows.layout(geometry: .sampleNotchBubbles, panelWidth: 1400, sizeFactor: 1,
                                      left: IslandRows.bubblePieces(ids: ["a"], more: false, diameter: 32), right: [IslandRows.Piece(name: "capsule.news", width: 100)])
        check("notch with bubbles: one bubble of 32 ends at 601.5, the capsule starts at 798.5, middle 16, no dot reserve",
              notch.left[0].rect == CGRect(x: 569.5, y: 0, width: 32, height: 32) && notch.right[0].rect == CGRect(x: 798.5, y: 0, width: 100, height: 32) && notch.midY == 16,
              "\(notch.left.map(\.rect)) \(notch.right.map(\.rect))")
        // The tall pill: 59 by 40 at 8.5, middle 28.5; d 52 at the biggest size reaches 2.5 to 54.5 inside the 56 pt strip.
        let tall = IslandRows.layout(geometry: .samplePillTall, panelWidth: 1400, sizeFactor: 1.3,
                                     left: IslandRows.bubblePieces(ids: ["a"], more: false, diameter: 52), right: [])
        check("tall pill at the biggest size: a bubble of 52 stands 2.5 to 54.5, ends at 664.5 (housing 670.5)",
              tall.left[0].rect == CGRect(x: 612.5, y: 2.5, width: 52, height: 52) && tall.housing.minX == 670.5 && tall.rightRow == .zero, "\(tall.left.map(\.rect))")
        // Whole device pixels: the row's top moves to the nearest pixel (a pill's 35.5 pt bubble would stand at 6.25, the 40.5 pt one at 3.75: half pixels at 2x).
        let mid = IslandRows.layout(geometry: .samplePill16, panelWidth: 1400, sizeFactor: 1.15, left: IslandRows.bubblePieces(ids: ["a"], more: false, diameter: 35.5), right: [])
        let big = IslandRows.layout(geometry: .samplePill16, panelWidth: 1400, sizeFactor: 1.3, left: IslandRows.bubblePieces(ids: ["a"], more: false, diameter: 40.5), right: [])
        let oneX = IslandRows.layout(geometry: .samplePill16, panelWidth: 1400, sizeFactor: 1.15, left: IslandRows.bubblePieces(ids: ["a"], more: false, diameter: 35.5), right: [], displayScale: 1)
        let oneXBig = IslandRows.layout(geometry: .samplePill16, panelWidth: 1400, sizeFactor: 1.3, left: IslandRows.bubblePieces(ids: ["a"], more: false, diameter: 40.5), right: [], displayScale: 1)
        check("a pill's 35.5 pt bubble stands at 6.5 (not 6.25) and the 40.5 pt one at 4 (not 3.75) on a 2x display, their middles 0.25 pt from the housing's 24; on a 1x display at 6 and 4",
              mid.left[0].rect.minY == 6.5 && mid.rowY == 6.5 && big.left[0].rect.minY == 4 && big.rowY == 4 && abs(mid.left[0].rect.midY - 24) == 0.25 && abs(big.left[0].rect.midY - 24) == 0.25
                && oneX.left[0].rect.minY == 6 && oneXBig.left[0].rect.minY == 4, "\(mid.left.map(\.rect)) \(big.left.map(\.rect)) \(oneX.left.map(\.rect)) \(oneXBig.left.map(\.rect))")
        // The drawn island of a 37 pt bar is 108.8 wide: its side lines (639.6 and 760.4) move away from it onto half points, never toward it.
        let wide = IslandRows.layout(geometry: IslandSamples.none37, panelWidth: 1400, sizeFactor: 1, left: IslandRows.bubblePieces(ids: ["a", "b"], more: false, diameter: 32),
                                     right: [IslandRows.Piece(name: "capsule.news", width: 100)])
        check("drawn island, bar 37: two bubbles of 32 end at 639.5 and the capsule starts at 760.5 (the keep-out edges are 639.6 and 760.4), nothing enters the keep-out",
              wide.leftEdge == 639.5 && wide.left[1].rect.maxX == 639.5 && wide.left[0].rect.minX == 571.5 && wide.rightStart == 760.5 && wide.right[0].rect.minX == 760.5
                && abs(wide.keepOut.minX - 639.6) < 1e-9 && abs(wide.keepOut.maxX - 760.4) < 1e-9 && wide.rowY == 2.5 && !(wide.left + wide.right).contains { IslandRows.overlaps($0.rect, wide.keepOut) },
              "\(wide.left.map(\.rect)) \(wide.right.map(\.rect)) \(wide.keepOut)")
        // The two sides do not depend on each other: the camera is never moved.
        let leftOnly = IslandRows.layout(geometry: .samplePill16, panelWidth: 1400, sizeFactor: 1, left: IslandRows.bubblePieces(ids: ["a", "b"], more: false, diameter: 31), right: [])
        let both = IslandRows.layout(geometry: .samplePill16, panelWidth: 1400, sizeFactor: 1, left: IslandRows.bubblePieces(ids: ["a", "b"], more: false, diameter: 31),
                                     right: [IslandRows.Piece(name: "capsule.news", width: 300)])
        let rightOnly = IslandRows.layout(geometry: .samplePill16, panelWidth: 1400, sizeFactor: 1, left: [], right: [IslandRows.Piece(name: "capsule.news", width: 300)])
        check("the sides are independent: the left row is where it is whether or not the right side shows, and the housing never moves",
              leftOnly.left == both.left && rightOnly.right == both.right && leftOnly.housing == both.housing && both.housing == rightOnly.housing)
        // A piece of no width in the middle leaves no gap.
        let hole = IslandRows.layout(geometry: .samplePill16, panelWidth: 1400, sizeFactor: 1, left: [],
                                     right: [IslandRows.Piece(name: "capsule.news", width: 0), IslandRows.Piece(name: "capsule.companion", width: 60)])
        check("a capsule with nothing to show takes no room: the radio starts where the news would have", hole.right.count == 1 && hole.right[0].rect.minX == 751, "\(hole.right.map(\.rect))")
        // The content scale and the capsule's width.
        check("the content scale: 1 at the normal size, the diameter's ratio above it (pill 35.5/31, drawn island stays 1)",
              IslandRows.contentScale(geometry: .samplePill16, sizeFactor: 1) == 1 && abs(IslandRows.contentScale(geometry: .samplePill16, sizeFactor: 1.15) - 35.5 / 31) < 1e-9
                && IslandRows.contentScale(geometry: .sampleNone, sizeFactor: 1.3) == 1)
        check("a capsule is its content times the scale plus 8 pt at each end; nothing to show gives none",
              IslandRows.capsuleWidth(content: 80, scale: 1) == 96 && IslandRows.capsuleWidth(content: 80, scale: 1.5) == 136 && IslandRows.capsuleWidth(content: 0, scale: 1) == 0
                && IslandRows.capsuleWidth(content: 0.4, scale: 2) == 0)
        check("the bubble pieces: one per agent in the order given, then \"+N\"",
              IslandRows.bubblePieces(ids: ["x", "y"], more: true, diameter: 20).map(\.name) == ["bubble.x", "bubble.y", "bubble.more"]
                && IslandRows.bubblePieces(ids: [], more: false, diameter: 20).isEmpty)
        // The keep-out: housing plus 6 on every side, plus 16 at the right of a pill only.
        check("the keep-out is the housing plus 6 pt (plus 16 right of a pill)",
              IslandRows.keepOut(geometry: .sampleNotchBubbles, panelWidth: 1400) == CGRect(x: 601.5, y: -6, width: 197, height: 44)
                && IslandRows.keepOut(geometry: .samplePill16, panelWidth: 1400) == CGRect(x: 665, y: 2.5, width: 86, height: 43)
                && IslandRows.keepOut(geometry: .sampleNone, panelWidth: 1400) == CGRect(x: 660, y: -4, width: 80, height: 32))
    }

    // MARK: Edges: a narrow panel, the size limit

    private static func edges(_ check: SuiteCheck) {
        // A panel too narrow for what it holds: shapes are cut at the panel's edge, never beyond it, and the layout says so.
        let narrow = IslandRows.layout(geometry: .samplePill16, panelWidth: 400, sizeFactor: 1,
                                       left: IslandRows.bubblePieces(ids: ["a", "b", "c", "d"], more: true, diameter: 31),
                                       right: [IslandRows.Piece(name: "capsule.news", width: 300)])
        let all = narrow.left + narrow.right
        check("a panel too narrow for the rows: nothing leaves it, nothing enters the keep-out, and the layout says it cut something",
              narrow.clipped && all.allSatisfy { $0.rect.minX >= -0.001 && $0.rect.maxX <= 400.001 && !IslandRows.overlaps($0.rect, narrow.keepOut) },
              "\(all.map(\.rect)) clipped \(narrow.clipped)")
        // The size limit holds for ANY geometry: never above the top edge; beside a pill never more than the strip minus 4 pt; beside a classic
        // notch (flush with the top edge) exactly the notch's own height, whatever the strip and the size factor.
        var wrong: [String] = []
        for strip in stride(from: CGFloat(18), through: 60, by: 1.5) {
            for height in stride(from: CGFloat(16), through: 44, by: 2) {
                for inset in [CGFloat(0), 2, 8.5] {
                    let g = NotchGeometry(kind: inset == 0 ? .notch : .pill, size: CGSize(width: 60, height: height), topInset: inset, stripHeight: strip)
                    for factor in factors {
                        let d = IslandRows.diameter(geometry: g, sizeFactor: factor)
                        let mid = inset + height / 2
                        let overStrip = g.kind == .notch ? d != height : d > strip - 4 + 0.001
                        if overStrip || d > 2 * mid + 0.001 || d < 0 || d.truncatingRemainder(dividingBy: 0.5) != 0 {
                            wrong.append("strip \(strip) height \(height) inset \(inset) factor \(factor): d \(d)")
                        }
                    }
                }
            }
        }
        check("the row's height never reaches above the top edge; beside a pill it stays inside the strip minus 4 pt; beside a notch it is the notch's height, for any strip, housing and factor", wrong.isEmpty, wrong.prefix(4).joined(separator: "; "))
    }
}
