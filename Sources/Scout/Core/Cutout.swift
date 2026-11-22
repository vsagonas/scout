import SwiftUI

// What is in the glass at the top of a display, and what Scout draws beside it. Shared by the notch and by the views drawn beside the
// camera (the agents' faces, the news): they read `CutoutContext` from the environment.

/// What is in the glass at the top of a display.
enum CutoutKind: String, Equatable, CaseIterable {
    /// The classic camera notch, flush with the top edge.
    case notch
    /// The camera pill of the new MacBook Pro: a small capsule a little below the top edge. The system's own island lives around it, so
    /// Scout never draws on it and never takes the pointer there.
    case pill
    /// No cutout: an external display, an iMac, an older MacBook.
    case none
}

/// What Scout draws at rest on a display without a cutout (`notch.shape`).
enum NoneShape: String, Equatable, CaseIterable {
    /// A small capsule of Scout's own inside the menu bar.
    case island
    /// The drawn notch, flush with the top edge (what every version before 1.0.20 drew).
    case tab = "notch"
    case nothing
}

/// How the agents show beside a classic notch (`notch.agentStyle`).
enum AgentWingStyle: String, Equatable, CaseIterable {
    /// Square pixel faces inside the notch's black shape: the default, nothing changes on a classic notch.
    case faces
    /// Round bubbles beside the notch.
    case bubbles
}

/// What a view drawn beside the camera needs to know about its place. The notch's root view sets it; pictures and tests set their own.
struct CutoutContext: Equatable {
    var kind: CutoutKind = .notch
    /// True while the closed notch draws separate round shapes beside the housing (bubbles, capsules) instead of one black shape with
    /// the wings inside it.
    var rows = false
    /// The height of one bubble or capsule as drawn, its ring included, in points (0 outside rows).
    var rowHeight: CGFloat = 0
    /// The display's backing scale (1 on a non-Retina display): pixel art picks whole pixels by it.
    var displayScale: CGFloat = 2
    /// The name of the shape under the pointer (`IslandHit` names: "bubble.<agent id>", "bubble.more", "capsule.news"…), nil when none.
    var hovered: String?
    /// The display's geometry while rows are drawn: a view that takes a click hands it to `IslandHit.perform` (nil outside rows).
    var geometry: NotchGeometry?
}

private struct CutoutContextKey: EnvironmentKey {
    static let defaultValue = CutoutContext()
}

extension EnvironmentValues {
    var cutout: CutoutContext {
        get { self[CutoutContextKey.self] }
        set { self[CutoutContextKey.self] = newValue }
    }
}
