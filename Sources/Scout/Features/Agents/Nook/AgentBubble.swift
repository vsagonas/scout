import SwiftUI

// The agents as small ROUND bubbles beside the island.
// A bubble is a black disc with a ring around it; every bubble on a display has ONE outer diameter, ring included, so no
// bubble is smaller than its neighbour. The ring tells the state: amber and breathing when the agent needs you, green when it
// finished, red when it stopped, a neutral hairline while it works or sleeps. The pixel face is the same one the wing has always drawn (its moods,
// its order, its colours); it sits WHOLE inside the disc, corners included. The little characters are called agents.

/// The colour of a bubble's ring by what the agent is doing.
enum AgentBubbleRing: Equatable {
    case needs, finished, stopped, neutral

    init(_ mood: AgentFaceMood) {
        switch mood {
        case .asking: self = .needs
        case .finished: self = .finished
        case .stopped: self = .stopped
        case .working, .idle: self = .neutral
        }
    }

    var color: Color {
        switch self {
        case .needs: Color.orange
        case .finished: Color.green
        case .stopped: Color.red
        case .neutral: Color.white.opacity(IslandTuning.neutralRingOpacity)
        }
    }
}

/// The rules for the face inside the disc, as pure functions (the numbers are in `IslandTuning`).
enum AgentBubbleMetrics {
    /// The black disc inside the ring.
    static func innerDiameter(outer: CGFloat, ring: CGFloat = IslandTuning.ringWidth) -> CGFloat { max(0, outer - 2 * ring) }

    /// The face's cell: 1.5 pt (an 18 pt face) when the disc inside the ring is at least 27 pt, else 1.0 pt (a 12 pt face); always whole device
    /// pixels, so on a 1x display a cell is a whole point. When the face's corners would leave the disc (a disc under 17 pt, the drawn island in a
    /// 22 pt bar: 15 pt inside the ring) the cell steps down by one device pixel at a time until the face fits whole (0.5 pt on a 2x display,
    /// a 6 pt face); where not even one device pixel per cell fits (a 1x display) the result is 0: the bubble draws no face, only its disc and ring.
    static func faceCell(inner: CGFloat, scale: CGFloat) -> CGFloat {
        let wanted = inner >= IslandTuning.faceCellThreshold ? IslandTuning.faceCellLarge : IslandTuning.faceCellSmall
        let unit = 1 / max(1, scale)
        var steps = max(1, Int((wanted / unit + 1e-6).rounded(.down)))
        while steps > 0, !faceFits(cell: CGFloat(steps) * unit, inner: inner) { steps -= 1 }
        return CGFloat(steps) * unit
    }

    /// The side of the whole 12 by 12 face.
    static func faceSide(cell: CGFloat) -> CGFloat { CGFloat(AgentFaceArt.cells) * cell }

    /// The distance from the face's middle to its corner: the disc must reach at least that far.
    static func cornerReach(cell: CGFloat) -> CGFloat { faceSide(cell: cell) / 2 * 2.0.squareRoot() }

    /// True when the face's corners lie inside a disc of this diameter.
    static func faceFits(cell: CGFloat, inner: CGFloat) -> Bool { cornerReach(cell: cell) <= inner / 2 + 1e-6 }

    /// Where the face's top-left corner stands inside the bubble's frame: centred, then moved onto a whole device pixel.
    static func faceOrigin(outer: CGFloat, cell: CGFloat, scale: CGFloat) -> CGFloat {
        let unit = 1 / max(1, scale)
        return ((outer - faceSide(cell: cell)) / 2 / unit).rounded() * unit
    }
}

extension AgentBubbleMetrics {
    /// A hovered bubble grows from its top right corner: toward the left (its neighbour, 4 pt away) and down, never toward the housing (the nearest
    /// bubble would run into the clearance, where the closed view cuts everything off, and show a flat edge) and never above its top (a bubble the
    /// size of the classic notch's strip touches the screen's top edge).
    static let hoverAnchor = UnitPoint(x: 1, y: 0)
}

/// One agent's bubble: its face in a black disc inside a coloured ring.
struct AgentBubble: View {
    var face: AgentWingSummary.Face
    /// The accessibility label (`NotchHeader.faceHelp`), made by the caller from the sessions.
    var label: String
    /// The outer diameter, ring included.
    var diameter: CGFloat
    var ringWidth: CGFloat = IslandTuning.ringWidth
    var displayScale: CGFloat = 2
    var hovered = false
    /// Gallery and tests: draw one still moment of the face (seconds).
    var frozenAt: Double?
    /// The sheet of variants tries other cells; nil follows the rule.
    var cell: CGFloat?
    /// Tests draw the bubble without its face to tell the face's pixels from the rest.
    var showsFace = true

    var body: some View {
        let inner = AgentBubbleMetrics.innerDiameter(outer: diameter, ring: ringWidth)
        let px = cell ?? AgentBubbleMetrics.faceCell(inner: inner, scale: displayScale)
        let origin = AgentBubbleMetrics.faceOrigin(outer: diameter, cell: px, scale: displayScale)
        ZStack(alignment: .topLeading) {
            Circle().fill(Color.black)
            BubbleRing(kind: AgentBubbleRing(face.mood), width: ringWidth, hovered: hovered)
            if showsFace, px > 0 {
                AgentFaceIcon(agent: face.agent, mood: face.mood, phase: AgentFaceArt.phase(for: face.id), frozenAt: frozenAt, variant: face.variant, px: px)
                    .padding(.leading, origin).padding(.top, origin)
            }
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .scaleEffect(hovered && !ScoutRuntime.reduceMotion ? IslandTuning.hoverScale : 1, anchor: AgentBubbleMetrics.hoverAnchor)
        .animation(.easeOut(duration: IslandTuning.hoverFade), value: hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// The ring of a bubble: the state's colour; a bubble that needs you breathes (steady under Reduce Motion); under the pointer it brightens.
struct BubbleRing: View {
    var kind: AgentBubbleRing
    var width: CGFloat
    var hovered = false

    var body: some View {
        Group {
            if kind == .needs && !ScoutRuntime.reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 15)) { ctx in
                    ring(opacity: Self.breath(at: ctx.date.timeIntervalSinceReferenceDate))
                }
            } else {
                ring(opacity: 1)
            }
        }
        .animation(.easeOut(duration: IslandTuning.hoverFade), value: hovered)
    }

    private func ring(opacity: Double) -> some View {
        ZStack {
            Circle().strokeBorder(kind.color, lineWidth: width).opacity(opacity)
            Circle().strokeBorder(Color.white.opacity(hovered ? (kind == .neutral ? 0.34 : 0.32) : 0), lineWidth: width)
        }
    }

    /// The ask ring's opacity at time `t`: one breath every `askBreath` seconds, between the low value and full.
    static func breath(at t: Double) -> Double {
        let low = IslandTuning.askBreathLow
        return low + (1 - low) * (0.5 + 0.5 * sin(2 * .pi * t / IslandTuning.askBreath))
    }
}

/// The round "+N" for the agents that do not fit (99+ at most); its ring is amber when a hidden agent needs you, so urgency is never hidden.
struct AgentMoreBubble: View {
    var count: Int
    var needs: Bool
    var diameter: CGFloat
    var ringWidth: CGFloat = IslandTuning.ringWidth
    var hovered = false

    static func text(_ count: Int) -> String { count > IslandTuning.moreCap ? "\(IslandTuning.moreCap)+" : "+\(count)" }

    var body: some View {
        let inner = AgentBubbleMetrics.innerDiameter(outer: diameter, ring: ringWidth)
        ZStack {
            Circle().fill(Color.black)
            BubbleRing(kind: needs ? .needs : .neutral, width: ringWidth, hovered: hovered)
            Text(verbatim: Self.text(count)).font(.system(size: IslandTuning.moreFont, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.78)).lineLimit(1).minimumScaleFactor(0.6).frame(width: inner * 0.86)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .scaleEffect(hovered && !ScoutRuntime.reduceMotion ? IslandTuning.hoverScale : 1, anchor: AgentBubbleMetrics.hoverAnchor)
        .animation(.easeOut(duration: IslandTuning.hoverFade), value: hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Agents"))
    }
}

/// The minimal look in the round language: one bubble with the number of agents at work (the cpu glyph over it when the bubble is tall
/// enough, alone when nothing works), and a second amber one with the number that need you.
struct AgentCountBubble: View {
    /// The number to show; nil draws the glyph alone.
    var count: Int?
    /// The amber one.
    var needs = false
    var diameter: CGFloat
    var ringWidth: CGFloat = IslandTuning.ringWidth
    var hovered = false

    /// The glyph is dropped below this height.
    static let glyphFrom: CGFloat = 26

    var body: some View {
        let inner = AgentBubbleMetrics.innerDiameter(outer: diameter, ring: ringWidth)
        ZStack {
            Circle().fill(needs ? Color.orange : Color.black)
            if !needs { BubbleRing(kind: .neutral, width: ringWidth, hovered: hovered) }
            if needs {
                Circle().strokeBorder(Color.white.opacity(hovered ? 0.4 : 0), lineWidth: ringWidth)
                number.foregroundStyle(Color.black.opacity(0.85))
            } else if count != nil {
                VStack(spacing: -1) {
                    if diameter >= Self.glyphFrom { Image(systemName: "cpu").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.accent) }
                    number.foregroundStyle(Look.primary)
                }
                .frame(width: inner)
            } else {
                Image(systemName: "cpu").font(.system(size: min(12, inner * 0.6), weight: .semibold)).foregroundStyle(Theme.accent)
            }
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .scaleEffect(hovered && !ScoutRuntime.reduceMotion ? IslandTuning.hoverScale : 1, anchor: AgentBubbleMetrics.hoverAnchor)
        .animation(.easeOut(duration: IslandTuning.hoverFade), value: hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Agents"))
    }

    private var number: some View {
        Text(verbatim: "\(count ?? 0)").font(.system(size: diameter >= Self.glyphFrom ? 12 : 11, weight: .bold, design: .rounded)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.6)
    }
}
