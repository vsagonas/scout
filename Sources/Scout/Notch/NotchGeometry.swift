import AppKit
import SwiftUI

/// The housing at the top of one screen and what Scout draws around it: the camera notch, the camera pill, or (no cutout) Scout's own shape.
struct NotchGeometry: Equatable {
    /// The housing's size: the notch, the pill, or the shape Scout draws on a display without a cutout.
    var size: CGSize
    /// True when the housing is in the glass (a notch or a pill).
    var isHardware: Bool
    var kind: CutoutKind
    /// How far the housing's top edge is below the top of the screen (a notch and the drawn tab: 0).
    var topInset: CGFloat
    /// No cutout only: what Scout draws at rest.
    var noneShape: NoneShape
    /// A classic notch only: how the agents show beside it.
    var agentStyle: AgentWingStyle
    /// The height of the strip the housing sits in (that display's menu bar).
    var stripHeight: CGFloat
    /// A display that takes touches: shapes get a bigger margin for a finger.
    var isTouch: Bool

    /// What every picture, test and call site of the classic notch uses: a notch when it is hardware, else the drawn tab.
    init(size: CGSize, isHardware: Bool) {
        self.init(kind: isHardware ? .notch : .none, size: size, noneShape: .tab)
    }

    init(kind: CutoutKind, size: CGSize, topInset: CGFloat = 0, noneShape: NoneShape = .tab, agentStyle: AgentWingStyle = .faces,
         stripHeight: CGFloat? = nil, isTouch: Bool = false) {
        self.kind = kind
        self.size = size
        self.isHardware = kind != .none
        self.topInset = topInset
        self.noneShape = noneShape
        self.agentStyle = agentStyle
        self.stripHeight = stripHeight ?? max(topInset + size.height, 24)
        self.isTouch = isTouch
    }

    /// The housing's bottom edge, measured from the top of the screen.
    var floor: CGFloat { topInset + size.height }

    /// The housing in a panel's own space (top-left origin; the panel is centred on the screen and flush with its top).
    func housingRect(panelWidth: CGFloat) -> CGRect {
        CGRect(x: (panelWidth - size.width) / 2, y: topInset, width: size.width, height: size.height)
    }

    /// True when this display can draw separate round shapes beside the housing (bubbles, capsules): a pill, the drawn island, and a classic
    /// notch set to round bubbles. What is drawn at a given moment is `IslandMode.closed`.
    var hasRows: Bool {
        switch kind {
        case .pill: true
        case .none: noneShape == .island
        case .notch: agentStyle == .bubbles
        }
    }

    /// False for a pill: the system's own island lives on that housing, so it is never a hover, click or drop target of Scout's.
    var claimsHousing: Bool { kind != .pill }

    /// The housing the CLASSIC drawing uses (one black shape flush with the top edge): the drawn island falls back to the tab's size.
    var classicSize: CGSize { kind == .none && noneShape == .island ? Self.virtualSize : size }

    /// The MacBook Pro 16" notch, used by the gallery.
    static let sample16 = NotchGeometry(size: CGSize(width: 185, height: 32), isHardware: true)
    static let virtualSize = CGSize(width: 190, height: 32)
    /// The camera pill of the 16" MacBook Pro as one outside source measured it (58 by 31 pt, 8.5 pt below the edge, in a strip of about 48 pt).
    static let samplePill16 = NotchGeometry(kind: .pill, size: CGSize(width: 58, height: 31), topInset: 8.5, stripHeight: 48, isTouch: true)
    /// A deliberately tall pill (another report's 59 by 40): the stress case for pictures and tests.
    static let samplePillTall = NotchGeometry(kind: .pill, size: CGSize(width: 59, height: 40), topInset: 8.5, stripHeight: 56, isTouch: true)
    /// A display without a cutout showing Scout's drawn island in a 24 pt menu bar.
    static let sampleNone = NotchGeometry(kind: .none, size: CGSize(width: 68, height: 20), topInset: 2, noneShape: .island, stripHeight: 24)
    /// A display without a cutout showing the drawn tab (the old virtual notch).
    static let sampleNoneTab = NotchGeometry(size: virtualSize, isHardware: false)
    /// The 16" classic notch with the agents as round bubbles beside it.
    static let sampleNotchBubbles = NotchGeometry(kind: .notch, size: CGSize(width: 185, height: 32), agentStyle: .bubbles)

    /// The geometry of one real display, from what the system reports now and the stored choices. It only gathers the facts
    /// (`DisplayFacts.gather`, which never prompts and treats every failed call as unknown); the decision is the pure
    /// `make(facts:override:noneShape:agentStyle:)`.
    @MainActor
    static func make(for screen: NSScreen) -> NotchGeometry { decision(for: screen).geometry }

    /// The same with the notes the display report prints.
    @MainActor
    static func decision(for screen: NSScreen) -> DisplayDecision {
        make(facts: DisplayFacts.gather(screen), override: NotchPrefs.cutoutOverride, noneShape: NotchPrefs.noneShape, agentStyle: NotchPrefs.agentStyle)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// True when the display has a housing in the glass (a notch or a pill), by the geometry: a pill with an inset of zero counts.
    @MainActor
    var hasHardwareNotch: Bool { NotchGeometry.make(for: self).isHardware }
}

/// The notch outline: flush with the top edge, small outward "shoulders" at the top corners (radius
/// `topRadius`, the body walls start that far inside the frame) and rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let t = max(0, min(topRadius, rect.height / 2, rect.width / 4))
        let b = max(0, min(bottomRadius, (rect.height - t) / 1.2, (rect.width - 2 * t) / 2))
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        if t > 0.25 {
            p.addArc(tangent1End: CGPoint(x: rect.minX + t, y: rect.minY),
                     tangent2End: CGPoint(x: rect.minX + t, y: rect.minY + t), radius: t)
        } else {
            p.addLine(to: CGPoint(x: rect.minX + t, y: rect.minY))
        }
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        if b > 0.25 {
            p.addArc(tangent1End: CGPoint(x: rect.minX + t, y: rect.maxY),
                     tangent2End: CGPoint(x: rect.minX + t + b, y: rect.maxY), radius: b)
            p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
            p.addArc(tangent1End: CGPoint(x: rect.maxX - t, y: rect.maxY),
                     tangent2End: CGPoint(x: rect.maxX - t, y: rect.maxY - b), radius: b)
        } else {
            p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.maxY))
        }
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        if t > 0.25 {
            p.addArc(tangent1End: CGPoint(x: rect.maxX - t, y: rect.minY),
                     tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: t)
        } else {
            p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY))
        }
        p.closeSubpath()
        return p
    }
}
