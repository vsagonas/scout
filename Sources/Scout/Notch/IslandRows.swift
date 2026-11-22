import CoreGraphics

/// Where the closed island's shapes stand beside the housing, as a pure function of plain numbers (plan C2 to C4; decisions A4, A5).
///
/// Everything in a row has ONE height `d`: the housing's height times the size factor, in half points, never more than the strip's height
/// minus 4 pt (a pill and the drawn island float in their strip), and never so tall that a row centred on the housing would reach above the
/// top edge of the screen. Beside a classic notch the row is as tall as the notch at every size: the notch touches the top edge, so the
/// top limit is its own height and the strip does not count. The left row ends 6 pt left of the housing and grows left; the right row starts 6 pt right of it (plus the 16 pt dot
/// reserve on a pill only) and grows right. Both are centred on the housing's vertical middle, the gap between two shapes is 4 pt, a side
/// with nothing has no shape and no gap, and nothing ever enters the housing plus its clearance. The camera is never moved: the two sides do
/// not depend on each other. Every shape stands on whole device pixels (the pixel face needs it): the row's top moves to the nearest device
/// pixel (at most half a pixel, 0.25 pt on a 2x display) and each side's start line moves away from the housing, never toward it.
@MainActor
enum IslandRows {
    /// One thing a side holds, by name, in its own width (a bubble is `diameter` wide; a width of 0 means there is nothing to show).
    struct Piece: Equatable {
        var name: String
        var width: CGFloat
    }

    struct Placed: Equatable {
        var name: String
        var rect: CGRect
    }

    struct Layout: Equatable {
        /// The common height of every shape.
        var diameter: CGFloat
        /// The housing in the panel's own space (top-left origin).
        var housing: CGRect
        /// The housing plus its clearance (and, on a pill, the dot reserve at its right): nothing of Scout's enters it.
        var keepOut: CGRect
        /// The left side's shapes from the outermost to the one nearest the housing; the right side's from the nearest outward.
        var left: [Placed]
        var right: [Placed]
        /// What each side spans (zero when it holds nothing).
        var leftRow: CGRect
        var rightRow: CGRect
        /// The vertical middle every shape is centred on (the housing's).
        var midY: CGFloat
        /// The top of every shape: the housing's middle minus half the height, moved to the nearest device pixel.
        var rowY: CGFloat
        /// Where the left side ends (6 pt left of the housing, moved left onto a device pixel) and where the right side starts (6 pt right of it,
        /// plus the dot reserve on a pill, moved right onto a device pixel). They hold whether or not the side shows anything.
        var leftEdge: CGFloat
        var rightStart: CGFloat
        /// A shape that did not fit between the housing and the panel's edge was cut or left out.
        var clipped: Bool
    }

    // MARK: The row's height

    /// The diameter of every bubble and the height of every capsule on this display.
    static func diameter(geometry: NotchGeometry, sizeFactor: CGFloat) -> CGFloat {
        let wanted = halfPoints(geometry.size.height * sizeFactor)
        // A classic notch touches the top edge and fills its strip: the row beside it is as tall as the notch itself (the top limit below).
        let stripLimit = geometry.kind == .notch ? CGFloat.greatestFiniteMagnitude : geometry.stripHeight - IslandTuning.stripMargin
        let topLimit = 2 * (geometry.topInset + geometry.size.height / 2)   // centred on the housing, a row may not reach above the screen's top edge
        let limit = floorToHalf(min(stripLimit, topLimit))
        return max(0, min(wanted, limit))
    }

    /// How much bigger than at the normal size the row is drawn (content inside a capsule scales by it).
    static func contentScale(geometry: NotchGeometry, sizeFactor: CGFloat) -> CGFloat {
        let base = diameter(geometry: geometry, sizeFactor: 1)
        guard base > 0 else { return 1 }
        return diameter(geometry: geometry, sizeFactor: sizeFactor) / base
    }

    /// A capsule's width: its content (at the row's scale) plus the padding at both ends; nothing to show gives no capsule.
    static func capsuleWidth(content: CGFloat, scale: CGFloat) -> CGFloat {
        content > 0.5 ? content * scale + 2 * IslandTuning.capsulePadding : 0
    }

    // MARK: The layout

    /// The housing plus its clearance on every side, and the dot reserve right of a pill.
    static func keepOut(geometry: NotchGeometry, panelWidth: CGFloat) -> CGRect {
        let housing = geometry.housingRect(panelWidth: panelWidth)
        let reserve = geometry.kind == .pill ? IslandTuning.dotReserve : 0
        return CGRect(x: housing.minX - IslandTuning.clearance, y: housing.minY - IslandTuning.clearance,
                      width: housing.width + 2 * IslandTuning.clearance + reserve, height: housing.height + 2 * IslandTuning.clearance)
    }

    /// The pieces of an agents' bubble row: one bubble per agent (found order, the first started outermost), then "+N" at the housing's end.
    static func bubblePieces(ids: [String], more: Bool, diameter: CGFloat) -> [Piece] {
        ids.map { Piece(name: IslandHit.bubblePrefix + $0, width: diameter) } + (more ? [Piece(name: IslandHit.more, width: diameter)] : [])
    }

    /// Places a side's pieces. `left` is in reading order (the last one is nearest the housing); `right` starts at the housing. `gap` is the
    /// space between shapes of one side and `diameter` the common height; the sheet of variants tries other values, the app uses the rules.
    /// `displayScale` is the display's backing scale: every shape's top and each side's start line land on a whole device pixel.
    static func layout(geometry: NotchGeometry, panelWidth: CGFloat, sizeFactor: CGFloat, left: [Piece], right: [Piece],
                       gap: CGFloat = IslandTuning.gap, diameter override: CGFloat? = nil, displayScale: CGFloat = 2) -> Layout {
        let d = override ?? diameter(geometry: geometry, sizeFactor: sizeFactor)
        let housing = geometry.housingRect(panelWidth: panelWidth)
        let reserve = geometry.kind == .pill ? IslandTuning.dotReserve : 0
        let unit = 1 / max(1, displayScale)
        let y = ((housing.midY - d / 2) / unit).rounded() * unit   // the nearest device pixel (a half point at 2x)
        let leftEdge = ((housing.minX - IslandTuning.clearance) / unit + 1e-6).rounded(.down) * unit   // away from the housing
        let rightStart = ((housing.maxX + IslandTuning.clearance + reserve) / unit - 1e-6).rounded(.up) * unit   // away from the housing
        var clipped = false

        // The left side: the nearest piece first, outward.
        var leftPlaced: [Placed] = []
        var edge = leftEdge
        for piece in left.reversed() where piece.width > 0.5 {
            let room = edge   // the panel's left edge is x = 0
            if room < 1 { clipped = true; continue }
            let width = min(piece.width, room)
            if width < piece.width { clipped = true }
            leftPlaced.append(Placed(name: piece.name, rect: CGRect(x: edge - width, y: y, width: width, height: d)))
            edge -= width + gap
        }
        leftPlaced.reverse()

        // The right side: from the housing outward.
        var rightPlaced: [Placed] = []
        var start = rightStart
        for piece in right where piece.width > 0.5 {
            let room = panelWidth - start
            if room < 1 { clipped = true; continue }
            let width = min(piece.width, room)
            if width < piece.width { clipped = true }
            rightPlaced.append(Placed(name: piece.name, rect: CGRect(x: start, y: y, width: width, height: d)))
            start += width + gap
        }

        return Layout(diameter: d, housing: housing, keepOut: keepOut(geometry: geometry, panelWidth: panelWidth),
                      left: leftPlaced, right: rightPlaced, leftRow: union(leftPlaced), rightRow: union(rightPlaced), midY: housing.midY,
                      rowY: y, leftEdge: leftEdge, rightStart: rightStart, clipped: clipped)
    }

    /// True when two rects share area (touching edges do not count).
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }

    // MARK: Small helpers

    private static func union(_ placed: [Placed]) -> CGRect {
        let all = placed.map(\.rect).reduce(CGRect.null) { $0.union($1) }
        return all.isNull ? .zero : all
    }

    private static func halfPoints(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
    private static func floorToHalf(_ value: CGFloat) -> CGFloat { (value * 2).rounded(.down) / 2 }
}
