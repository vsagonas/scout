import AppKit

// How Scout finds out what is at the top of a display: a notch, a pill or nothing. One pure function (`NotchGeometry.make(facts:…)`) from plain
// numbers, so a table test can prove every case without the hardware; `DisplayFacts.gather` (DisplayReport.swift) is the only code that asks the
// system. Every number below carries its origin: MEASURED (read on the owner's Mac or from Scout's own code), STATED (given by an outside source
// that did not show how it knew), INFERRED (our own arithmetic from other numbers), START VALUE (our own first choice, to be judged on pictures).

/// The hardware numbers and the start values of the detection, in one place.
enum CutoutNumbers {
    /// STATED (one outside source, from a real screenshot of a 16 inch): the camera pill is 58 by 31 pt, its top 8.5 pt below the screen edge.
    static let pillSize = CGSize(width: 58, height: 31)
    static let pillTopInset: CGFloat = 8.5
    /// STATED (the same source): the menu bar's slot for the pill is 59 pt wide on a screen 1,736 pt wide. The 14 inch is INFERRED to be the same.
    static let pillSlotWidth: CGFloat = 59
    /// START VALUE: the scale k = measured housing / 59 is believed only between 0.75 and 1.35 times 59 pt.
    static let scaleRange: ClosedRange<CGFloat> = (0.75 * pillSlotWidth)...(1.35 * pillSlotWidth)
    /// START VALUE: a housing under this share of the screen's width is a pill, from it up a notch (INFERRED shares: pill 59 / 1736 = 0.034,
    /// classic notch 185 / 1728 = 0.107 and 185 / 1512 = 0.122).
    static let pillShareLimit: CGFloat = 0.07
    /// MEASURED (the owner's 16 inch): the classic notch is 185 by 32 pt.
    static let notchDefaultSize = CGSize(width: 185, height: 32)
    /// MEASURED (the rule that was there before): a measured housing wider than this is not believed.
    static let notchWidthLimit: CGFloat = 420
    /// INFERRED (arithmetic from Apple's pixel sizes): the menu strip of the new MacBook Pro is about 48 pt tall.
    static let pillStripFallback: CGFloat = 48
    /// MEASURED (this Mac): the status bar's thickness on a Mac without a notch, used when the system gives no bar at all.
    static let barFallback: CGFloat = 24
    /// START VALUES: the drawn island on a display without a cutout is the bar's height minus 4 pt (at least 18, at most 32), 3.4 times as wide as
    /// tall, centred in the bar's height.
    static let islandBarMargin: CGFloat = 4
    static let islandHeightRange: ClosedRange<CGFloat> = 18...32
    static let islandWidthRatio: CGFloat = 3.4
    /// STATED (Apple's identifier page as read in the research; not verified on a real Mac): the 14 inch (Mac17,11 and Mac17,13) and the 16 inch
    /// (Mac17,10 and Mac17,12) with the camera pill.
    static let pillModels: Set<String> = ["Mac17,10", "Mac17,11", "Mac17,12", "Mac17,13"]
}

/// The choice in Settings › Notch › Camera cutout (`notch.cutout`): Scout reads the display, or is told what it has.
enum CutoutOverride: String, CaseIterable, Identifiable {
    case automatic, pill, notch, none
    var id: String { rawValue }

    /// The kind this choice forces; nil for Automatic.
    var kind: CutoutKind? {
        switch self {
        case .automatic: nil
        case .pill: .pill
        case .notch: .notch
        case .none: CutoutKind.none
        }
    }
}

/// A plain width of the four sides of a display's safe area (what the system hides under a camera housing).
struct DisplayInsets: Equatable {
    var top: CGFloat = 0
    var left: CGFloat = 0
    var bottom: CGFloat = 0
    var right: CGFloat = 0
}

/// Everything the system says about one display that the detection and the report use, as plain numbers. Nothing personal is in it: no name,
/// serial number, vendor or product id.
struct DisplayFacts: Equatable {
    /// The system's number for this display this session (only to tell displays apart while Scout runs; the report does not print it).
    var displayID: UInt32 = 0
    var frame: CGRect
    var visibleFrame: CGRect = .zero
    var safeInsets = DisplayInsets()
    /// The two areas left and right of the housing at the top, empty (zero) when the display has none.
    var auxLeft: CGRect = .zero
    var auxRight: CGRect = .zero
    /// The height of the menu bar as the screen's own frames show it (frame top minus visible top); 0 when the bar is hidden or unknown.
    var menuBar: CGFloat = 0
    /// What `NSStatusBar.system.thickness` says; 0 when unknown.
    var barThickness: CGFloat = 0
    var backingScale: CGFloat = 2
    /// The pixels of the display's current mode; nil when the system would not say.
    var pixelSize: CGSize?
    var isBuiltIn = true
    /// `hw.model`; nil when unreadable (that counts as "not on the list").
    var modelID: String?
    var isTouch = false

    var safeTop: CGFloat { safeInsets.top }
    /// Both areas beside the housing are there and the housing between them has a width.
    var hasAux: Bool { auxLeft.width > 0 && auxRight.width > 0 && housingWidth > 0 }
    var housingWidth: CGFloat { frame.width - auxLeft.width - auxRight.width }
    /// The housing's share of the screen's width (nil without both areas).
    var housingShare: CGFloat? { hasAux && frame.width > 0 ? housingWidth / frame.width : nil }
    var isListedPill: Bool { isBuiltIn && modelID.map(CutoutNumbers.pillModels.contains) == true }

    /// The menu bar height a drawn island fits into: the bar the frames show, never under the status bar's thickness; the fallback
    /// when the system says nothing.
    var noneBar: CGFloat {
        let bar = max(menuBar, barThickness)
        return bar > 0 ? bar : CutoutNumbers.barFallback
    }
}

/// What the detection decided for one display, with the lines the display report prints about it.
struct DisplayDecision: Equatable {
    var geometry: NotchGeometry
    var notes: [String]
}

extension NotchGeometry {
    /// The island Scout draws on a display without a cutout, for a menu bar `bar` points tall: the bar minus 4 pt (at least 18, at most 32) high,
    /// 3.4 times as wide, centred in the bar's height (never above the screen's top edge). A 24 pt bar gives 68 by 20 at 2 pt.
    static func drawnIsland(bar: CGFloat) -> NotchGeometry {
        let n = CutoutNumbers.self
        let height = min(max(bar - n.islandBarMargin, n.islandHeightRange.lowerBound), n.islandHeightRange.upperBound)
        return NotchGeometry(kind: .none, size: CGSize(width: n.islandWidthRatio * height, height: height), topInset: max(0, (bar - height) / 2),
                             noneShape: .island, stripHeight: bar)
    }

    /// Finds the kind of a display's top and the numbers Scout draws with, from plain facts. The rules, in this order:
    /// 1. The override (built-in displays only; an external display is never a pill and ignores it). It takes the measured housing only when that
    ///    is plausible for the chosen kind (pill: under 0.07 of the width, notch: 0.07 or more), else that kind's defaults.
    /// 2. A built-in display on the model list is a pill before any inset rule; a built-in touch display is a pill too.
    /// 3. Both areas beside the housing: under 0.07 of the width a pill, else a notch with the measured width (over 420 pt becomes 185).
    ///    An external display with both areas is a notch.
    /// 4. No areas and an inset above zero: a notch 185 wide and as tall as the inset. Else no cutout.
    /// The notes are for the report and never change the result.
    static func make(facts f: DisplayFacts, override: CutoutOverride = .automatic, noneShape: NoneShape = .tab,
                     agentStyle: AgentWingStyle = .faces) -> DisplayDecision {
        let n = CutoutNumbers.self
        var notes: [String] = []
        let share = f.housingShare
        let limit = n.pillShareLimit
        var kind = CutoutKind.none
        /// Whether the measured housing is what the chosen kind's numbers should come from.
        var measured = false

        if override != .automatic, !f.isBuiltIn {
            notes.append("the override \(override.rawValue) is ignored: this display is not built in")
        }
        if override != .automatic, f.isBuiltIn, let forced = override.kind {
            kind = forced
            switch forced {
            case .pill:
                measured = share.map { $0 < limit } ?? false
                notes.append("override pill: " + (measured ? "the measured housing fits a pill" : "the display's housing does not read like a pill (or is not reported), so the default pill is used"))
            case .notch:
                measured = share.map { $0 >= limit } ?? false
                notes.append("override notch: " + (measured ? "the measured housing fits a notch" : "the display's housing does not read like a notch (or is not reported), so the default notch is used"))
            case .none:
                notes.append("override none: Scout draws no housing here")
            }
        } else if f.isListedPill {
            kind = .pill
            notes.append("pill: the model \(f.modelID ?? "") is on the list of Macs with a camera pill")
            if let share, share >= limit {
                notes.append("CONTRADICTION: the model is on the list but the display reports a housing of \(fmt(f.housingWidth)) pt (share \(fmt(share, 3))), which reads like a classic notch; the list or the share rule needs a look")
            } else {
                measured = share != nil
            }
        } else if f.isBuiltIn, f.isTouch, !(share.map { $0 >= limit } ?? false) {
            // Touch alone says "pill" only while the display does not report a housing that reads like a classic notch: what the display
            // measures wins over a flag nobody has read on a real Mac yet (a wrong pill would keep the dashboard from ever opening).
            kind = .pill
            notes.append("pill: the built-in display takes touches (only the Macs with a camera pill do) and the model is not on the list")
            measured = share != nil
        } else if f.hasAux, let share {
            if f.isBuiltIn, share < limit {
                kind = .pill
                measured = true
                notes.append("pill: the housing is \(fmt(f.housingWidth)) pt, \(fmt(share, 3)) of the width (under \(fmt(limit, 2)))")
            } else {
                kind = .notch
                measured = true
                notes.append("notch: the housing is \(fmt(f.housingWidth)) pt, \(fmt(share, 3)) of the width" + (f.isBuiltIn ? "" : " (an external display with a housing is read as a notch)"))
                if f.isBuiltIn, f.isTouch {
                    notes.append("CONTRADICTION: the display takes touches but reports a housing of \(fmt(f.housingWidth)) pt (share \(fmt(share, 3))), which reads like a classic notch: read as a notch")
                }
            }
        } else if f.safeTop > 0 {
            kind = .notch
            notes.append("notch: the display hides \(fmt(f.safeTop)) pt at the top and reports no areas beside it, so the notch is 185 pt wide")
        } else {
            kind = .none
            notes.append("none: no housing, no hidden top, no areas beside it" + (f.isBuiltIn ? "" : " (external display)"))
        }

        let bar = f.menuBar
        let geometry: NotchGeometry
        switch kind {
        case .pill:
            var k: CGFloat = 1
            if measured, n.scaleRange.contains(f.housingWidth) {
                k = f.housingWidth / n.pillSlotWidth
                notes.append("pill size scaled by k = \(fmt(k, 3)) from the measured housing of \(fmt(f.housingWidth)) pt")
            } else if measured {
                notes.append("the measured housing of \(fmt(f.housingWidth)) pt is outside \(fmt(n.scaleRange.lowerBound))...\(fmt(n.scaleRange.upperBound)) pt, so k = 1")
            }
            let size = CGSize(width: n.pillSize.width * k, height: n.pillSize.height * k)
            let inset = n.pillTopInset * k
            // The strip is the menu bar, never lower than the housing's own floor (a bar under the pill would put the pill below its strip); hidden: 48.
            let strip = bar > 0 ? max(bar, inset + size.height) : n.pillStripFallback
            geometry = NotchGeometry(kind: .pill, size: size, topInset: inset, stripHeight: strip, isTouch: f.isTouch)
        case .notch:
            var size = n.notchDefaultSize
            if measured, f.housingWidth <= n.notchWidthLimit {
                size.width = f.housingWidth
                size.height = f.safeTop > 0 ? f.safeTop : n.notchDefaultSize.height
            } else if measured {
                notes.append("the measured housing of \(fmt(f.housingWidth)) pt is over \(fmt(n.notchWidthLimit)) pt, so the notch is 185 pt wide")
                size.height = f.safeTop > 0 ? f.safeTop : n.notchDefaultSize.height
            } else if override == .automatic || !f.isBuiltIn {
                size.height = f.safeTop > 0 ? f.safeTop : n.notchDefaultSize.height   // no areas, an inset: as tall as the inset
            }
            // The strip of a notch is left to the geometry's own rule (the housing's floor, 32 for the classic notch), whatever the menu bar says, so the
            // geometry detected on a real Mac equals sample16 and sampleNotchBubbles and the pictures made on them match the owner's screen.
            geometry = NotchGeometry(kind: .notch, size: size, agentStyle: agentStyle, isTouch: f.isTouch)
        case .none:
            var g: NotchGeometry
            switch noneShape {
            case .island: g = drawnIsland(bar: f.noneBar)
            case .tab: g = NotchGeometry(size: virtualSize, isHardware: false)
            case .nothing: g = NotchGeometry(kind: .none, size: virtualSize, noneShape: .nothing)
            }
            g.isTouch = f.isTouch
            geometry = g
        }
        return DisplayDecision(geometry: geometry, notes: notes)
    }

    private static func fmt(_ value: CGFloat, _ digits: Int = 1) -> String {
        let text = String(format: "%.\(digits)f", Double(value))
        guard text.contains(".") else { return text }
        var trimmed = text
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
    }
}
