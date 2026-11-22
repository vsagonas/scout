import CoreGraphics
import Foundation

/// The numbers of the island's closed look (the round agent bubbles and the capsules beside the housing), in ONE place. Every value is Scout's
/// own START VALUE unless its remark says otherwise: the first build renders a sheet of variants (`island-variants` in the gallery) and the
/// values are picked from those pictures. Marks: MEASURED (read from Scout's own code or the owner's Mac), STATED (an outside source gave it), INFERRED (our
/// own arithmetic), START VALUE (our own first choice).
enum IslandTuning {
    // MARK: Around the housing

    /// Clearance each side of the housing (and above and below it): nothing of Scout's is ever inside it. MEASURED (the old camera gap and wing gap).
    static let clearance: CGFloat = 6
    /// Extra room right of a pill for the system's privacy dot: air, not black. START VALUE.
    static let dotReserve: CGFloat = 16
    /// The gap between two shapes of one side (bubbles, capsules). START VALUE.
    static let gap: CGFloat = 4
    /// A row beside a pill or the drawn island is never taller than its strip minus this. START VALUE.
    static let stripMargin: CGFloat = 4
    /// A row centred on the housing never reaches above the screen's top edge: its height is at most twice the distance from that edge to the
    /// housing's middle. Beside a classic notch that is the notch's own height (32 pt), at every size. START VALUE.
    /// The size factors of Settings › Appearance (the wings' factors). MEASURED.
    static let sizeFactors: [CGFloat] = [1.0, 1.15, 1.3]

    // MARK: Bubbles

    /// The state ring of a bubble, inside its outer diameter. START VALUE.
    static let ringWidth: CGFloat = 1.5
    /// The ring of an agent at work or asleep: white at this opacity (a hairline). START VALUE.
    static let neutralRingOpacity = 0.16
    /// The face cell: 1.5 pt (an 18 pt face) when the disc inside the ring is at least `faceCellThreshold`, else 1.0 pt (a 12 pt face). MEASURED (1.5) and START VALUE (1.0).
    static let faceCellLarge: CGFloat = 1.5
    static let faceCellSmall: CGFloat = 1.0
    static let faceCellThreshold: CGFloat = 27
    /// The agents shown as bubbles, then "+N". MEASURED.
    static let maxBubbles = 4
    /// The "+N" bubble shows at most 99. START VALUE (the size, 10 pt bold rounded, is MEASURED).
    static let moreCap = 99
    static let moreFont: CGFloat = 10
    /// A bubble that needs you: its ring breathes with this period (seconds), between these opacities; steady under Reduce Motion. MEASURED (the old dot's beat).
    static let askBreath: Double = 1.4
    static let askBreathLow = 0.45
    /// Under the pointer: the ring brightens in this time and the bubble grows a little when motion is allowed. START VALUE.
    static let hoverFade: Double = 0.15
    static let hoverScale: CGFloat = 1.08
    /// A bubble or capsule grows in from this scale (Reduce Motion: only a fade). START VALUE.
    static let growStart: CGFloat = 0.6
    /// The rows' own canvas reaches this far below the strip, so a hovered bubble that is as tall as the strip (beside a classic notch) is not
    /// cut flat at the bottom while it grows. START VALUE.
    static let rowsOverflow: CGFloat = 6

    // MARK: Capsules

    /// Space between a capsule's end and its content. MEASURED (the old wing's outer padding).
    static let capsulePadding: CGFloat = 8
    /// A capsule lower than this shows the news on one line, else on two. START VALUE.
    static let oneLineBelow: CGFloat = 28
    /// The capsule's own hairline. START VALUE.
    static let capsuleHairline: CGFloat = 1
    /// The hairline of the drawn island under the pointer. START VALUE.
    static let hoverHairlineOpacity = 0.5

    // MARK: The numbers as data

    struct Row: Equatable {
        var name: String
        var value: String
        var mark: String
    }

    /// Every row of the plan's table C15 that this build draws, with the value as the code holds it. Not built in this build: the plan's state
    /// badge on a bubble and the plan's "face margin of at least 2.5 pt" (the face is instead proved whole inside its disc, corners included).
    static let table: [Row] = [
        Row(name: "Clearance each side of the housing", value: "\(Int(clearance)) pt", mark: "MEASURED"),
        Row(name: "Dot reserve, right of a pill", value: "\(Int(dotReserve)) pt", mark: "START VALUE"),
        Row(name: "Gap between shapes of a side", value: "\(Int(gap)) pt", mark: "START VALUE"),
        Row(name: "Row height", value: "housing height x size factor, 0.5 pt steps; beside a pill or the drawn island at most strip minus \(Int(stripMargin)) pt", mark: "START VALUE"),
        Row(name: "Row height, top edge", value: "at most twice the distance from the screen's top edge to the housing's middle (beside a classic notch: the notch's own height, 32 pt, at every size)", mark: "START VALUE"),
        Row(name: "Shapes on whole pixels", value: "row top on the nearest device pixel (0.25 pt at most on 2x), each side's start line moved away from the housing", mark: "START VALUE"),
        Row(name: "Size factors", value: "1.0, 1.15, 1.3", mark: "MEASURED"),
        Row(name: "Bubble ring", value: "\(ringWidth) pt inside the outer diameter", mark: "START VALUE"),
        Row(name: "Ring at work or asleep", value: "white \(Int(neutralRingOpacity * 100)) %", mark: "START VALUE"),
        Row(name: "Face cell", value: "\(faceCellLarge) pt (disc \(Int(faceCellThreshold)) pt or more), else \(faceCellSmall) pt", mark: "MEASURED and START VALUE"),
        Row(name: "Face fits the disc", value: "whole inside it, corners included: a smaller cell in whole device pixels when 1.0 pt does not fit, no face when one pixel does not", mark: "START VALUE"),
        Row(name: "Bubbles shown", value: "\(maxBubbles), then +N (\(moreCap)+ at most)", mark: "MEASURED and START VALUE"),
        Row(name: "+N bubble", value: "\(Int(moreFont)) pt bold rounded, \(moreCap)+ at most", mark: "MEASURED and START VALUE"),
        Row(name: "Ask ring breath", value: "\(askBreath) s, steady when calm", mark: "MEASURED"),
        Row(name: "Hover", value: "ring \(hoverFade) s; scale \(hoverScale) when motion is on, grown from the bubble's top right corner (away from the housing)", mark: "START VALUE"),
        Row(name: "Grow in", value: "from scale \(growStart) with a fade; calm: a fade, the news capsule grows in width and never travels, older bubbles step one place outward when the row widens", mark: "START VALUE"),
        Row(name: "Clicks", value: "every shape of the rows ignores a click while Settings › Notch › Clicking the notch opens it is off; the pointer still highlights it", mark: "START VALUE"),
        Row(name: "Capsule side padding", value: "\(Int(capsulePadding)) pt", mark: "MEASURED"),
        Row(name: "News lines", value: "2 lines, 1 under \(Int(oneLineBelow)) pt", mark: "MEASURED and START VALUE"),
    ]
}
