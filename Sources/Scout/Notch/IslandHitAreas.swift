import AppKit

// The pointer on the closed island: which shape is under it, what hover does there, where a dragged file is anchored. Every function here is pure
// (plain rects in, rects or words out; coordinates are the screen's, x to the right, and nothing in here depends on which way y runs, because
// every margin is the same above and below), so `island.selftest.hit` proves each with a table of numbers. The manager (`NotchManager`) only
// gathers the rects and calls them.

/// What is under the pointer on a closed island that draws separate shapes.
enum IslandTarget: Equatable {
    /// One of the named shapes (`IslandHit`: "bubble.<id>", "capsule.news", "drawn"…).
    case shape(String)
    /// The housing itself: only on a display that claims it (a classic notch, the drawn island). Never a pill.
    case housing
    case none
}

/// The five kinds of thing a pointer can rest on, for the hover table.
enum IslandHoverTarget: CaseIterable {
    case bubble, capsule, drawn
    /// The housing of a display that claims it.
    case housing
    /// The camera pill: the system's own island lives there. Whatever the setting says, nothing happens.
    case pillHousing
}

/// What resting the pointer on a target does.
enum HoverAction: Equatable {
    /// The dashboard opens after the setting's delay.
    case open
    /// The hover detail shows after 0.45 s (the classic closed notch's own behaviour).
    case showDetail
    /// Only the shape under the pointer is highlighted.
    case highlight
    case nothing
}

@MainActor
enum IslandHitAreas {
    // The numbers. START VALUES unless marked: they sit beside the same numbers of the layout (the clearance and the dot reserve are the layout's
    // too).
    /// MEASURED (the old island rect): a hit rect grows this far on its outer sides.
    static let slop: CGFloat = 4
    /// START VALUE: the margin on a touch display, for a finger.
    static let touchSlop: CGFloat = 8
    /// MEASURED (the old camera gap and wing gap): nothing of Scout's sits closer to the housing than this.
    static let clearance: CGFloat = 6
    /// START VALUE: the room kept free right of a pill for the system's privacy dot.
    static let dotReserve: CGFloat = 16
    /// MEASURED: the drop zone around the housing, and the wider one once a drag is targeting the notch.
    static let dropZone: CGFloat = 120
    static let dropZoneTargeting: CGFloat = 240
    /// MEASURED: the delay of the hover detail.
    static let detailDelay: TimeInterval = 0.45

    static func margin(for geometry: NotchGeometry) -> CGFloat { geometry.isTouch ? touchSlop : slop }

    // MARK: Rects

    /// The housing in screen coordinates: centred on the screen's top edge, `topInset` below it. Also the anchor for a dragged file and for the hold
    /// after a close. For a classic notch (inset 0) this is exactly the rect used before the island work.
    static func housingRect(geometry: NotchGeometry, screenFrame: CGRect) -> CGRect {
        CGRect(x: screenFrame.midX - geometry.size.width / 2, y: screenFrame.maxY - geometry.topInset - geometry.size.height,
               width: geometry.size.width, height: geometry.size.height)
    }

    /// A pill only: where Scout never takes the pointer: the housing and its clearance on every side, and right of it the room kept for the
    /// system's privacy dot.
    static func keepOut(housing: CGRect, geometry: NotchGeometry) -> CGRect? {
        guard geometry.kind == .pill else { return nil }
        return CGRect(x: housing.minX - clearance, y: housing.minY - clearance, width: housing.width + 2 * clearance + dotReserve,
                      height: housing.height + 2 * clearance)
    }

    /// The housing as a target on a display that claims it: today's island margin (4 pt sideways, 3 pt above and below, and 8 pt more toward the
    /// edge above).
    static func claimedHousingRect(_ housing: CGRect) -> CGRect {
        housing.insetBy(dx: -4, dy: -3).union(CGRect(x: housing.minX - 4, y: housing.minY, width: housing.width + 8, height: housing.height + 8))
    }

    /// The rects that take the pointer: each shape grown by the margin (4 pt, 8 on a touch display) above, below and on its OUTER sides only. Toward a
    /// neighbour (another shape, or the housing where it is claimed, however far) it grows nothing, so a click between two bubbles hits nothing.
    /// On a pill every rect is then cut back so it never enters the keep-out; a shape that is itself inside it is no target at all.
    static func hitRects(shapes: [String: CGRect], housing: CGRect, geometry: NotchGeometry) -> [String: CGRect] {
        let margin = margin(for: geometry)
        let keepOut = keepOut(housing: housing, geometry: geometry)
        var neighbours = shapes.map { (name: $0.key, rect: $0.value) }
        if geometry.claimsHousing { neighbours.append((name: "\u{1}housing", rect: housing)) }
        let eps: CGFloat = 0.001
        var result: [String: CGRect] = [:]
        for (name, r) in shapes where r.width > 0 && r.height > 0 {
            var left = margin, right = margin
            for other in neighbours where other.name != name {
                let o = other.rect
                guard o.minY < r.maxY, r.minY < o.maxY else { continue }
                if o.maxX <= r.minX + eps { left = 0 }
                if o.minX >= r.maxX - eps { right = 0 }
            }
            var grown = CGRect(x: r.minX - left, y: r.minY - margin, width: r.width + left + right, height: r.height + 2 * margin)
            if let keepOut, grown.intersects(keepOut) {
                if r.maxX <= keepOut.minX + eps {
                    grown = CGRect(x: grown.minX, y: grown.minY, width: min(grown.maxX, keepOut.minX) - grown.minX, height: grown.height)
                } else if r.minX >= keepOut.maxX - eps {
                    let x = max(grown.minX, keepOut.maxX)
                    grown = CGRect(x: x, y: grown.minY, width: grown.maxX - x, height: grown.height)
                } else {
                    continue
                }
            }
            if grown.width > 0 { result[name] = grown }
        }
        return result
    }

    /// What is under the point `p`: a shape's name, the housing (only where the display claims it), or nothing. The camera pill is never a
    /// target, and nothing inside the keep-out of a pill is either.
    static func target(at p: CGPoint, shapes: [String: CGRect], housing: CGRect, geometry: NotchGeometry) -> IslandTarget {
        if let keepOut = keepOut(housing: housing, geometry: geometry), keepOut.contains(p) { return .none }
        let rects = hitRects(shapes: shapes, housing: housing, geometry: geometry)
        for name in rects.keys.sorted(by: { (rects[$0]!.minX, $0) < (rects[$1]!.minX, $1) }) where rects[name]!.contains(p) { return .shape(name) }
        if geometry.claimsHousing, claimedHousingRect(housing).contains(p) { return .housing }
        return .none
    }

    // MARK: Hover and click

    /// What hover on `target` does under the setting (`NotchHover`):
    /// - Open: the dashboard opens (the manager adds the delay), only where `IslandMode.opens`; where it does not, a shape only lights up.
    /// - Show what's happening: in this build a shape only lights up; the housing of a display that claims it shows the detail as before.
    /// - Nothing: a shape only lights up.
    /// The camera pill's housing: always nothing.
    static func hoverAction(setting: NotchHover, target: IslandHoverTarget, geometry: NotchGeometry) -> HoverAction {
        if target == .pillHousing { return .nothing }
        let isShape = target != .housing
        switch setting {
        case .open: return IslandMode.opens(geometry: geometry) ? .open : (isShape ? .highlight : .nothing)
        case .details: return isShape ? .highlight : .showDetail
        case .off: return isShape ? .highlight : .nothing
        }
    }

    /// The hover kind of a target (the housing of a pill is the fifth kind, which `target(at:…)` never returns).
    static func hoverTarget(for target: IslandTarget, geometry: NotchGeometry) -> IslandHoverTarget? {
        switch target {
        case .none: return nil
        case .housing: return geometry.claimsHousing ? .housing : .pillHousing
        case .shape(let name):
            if name == IslandHit.drawn { return .drawn }
            return name.hasPrefix(IslandHit.capsulePrefix) ? .capsule : .bubble
        }
    }

    /// The name of the shape to light up for a target (nil for the housing and for nothing).
    static func highlightName(for target: IslandTarget) -> String? {
        if case .shape(let name) = target { return name }
        return nil
    }

    // MARK: Drag, hold and swipe

    /// How far `p` is from the anchor (0 inside it): the drop zone is measured from here, not from the screen's top edge.
    static func distance(from p: CGPoint, to anchor: CGRect) -> CGFloat {
        hypot(max(anchor.minX - p.x, 0, p.x - anchor.maxX), max(anchor.minY - p.y, 0, p.y - anchor.maxY))
    }

    /// The reach of the drop zone: 120 pt, 240 once a drag is targeting the notch (MEASURED numbers; the anchor is the housing now).
    static func dropReach(targeting: Bool) -> CGFloat { targeting ? dropZoneTargeting : dropZone }

    /// A file dragged to the top centre opens the dashboard only where the dashboard opens: on a pill a drop opens nothing in this build.
    static func dropOpens(geometry: NotchGeometry) -> Bool { IslandMode.opens(geometry: geometry) }

    /// The top of the open notch's swipe strip, in screen coordinates: 6 pt below the housing's bottom edge. While the notch is open only this
    /// strip and above it counts for the two-finger swipe, so scrolling the content below never closes it.
    static func swipeStripTop(geometry: NotchGeometry, screenFrame: CGRect) -> CGFloat { screenFrame.maxY - geometry.floor - 6 }
}

// MARK: - The controller's side

extension NotchController {
    /// The housing in screen coordinates: the anchor for a drag and for the hold after a close.
    var housingScreenRect: CGRect { IslandHitAreas.housingRect(geometry: model.geometry, screenFrame: screenFrame) }

    /// The closed island's named shapes as the view reported them, in screen coordinates.
    var shapeScreenRects: [String: CGRect] {
        var rects: [String: CGRect] = [:]
        for (name, local) in model.hitRects where local.width > 0 {
            let r = screenRect(of: local)
            if r.width > 0 { rects[name] = r }
        }
        return rects
    }

    /// What is under `p` while separate shapes are drawn beside the housing.
    func hitTarget(at p: CGPoint) -> IslandTarget {
        IslandHitAreas.target(at: p, shapes: shapeScreenRects, housing: housingScreenRect, geometry: model.geometry)
    }
}
