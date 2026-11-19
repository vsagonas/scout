import SwiftUI

/// Where an agent's helpers stand in a room of the dashboard's Agent TV (the den has its own, `AgentDenLayout.helperSpot`, in cells): right
/// under the agent, the row centred on the agent's figure (the middle of its head, in the picture of its state) and starting at the first row
/// under its body. A standing agent has its feet at the picture's bottom, so the row hangs right under the picture; the one at its desk and
/// the one on its beanbag have no feet, so the row stands in front of the furniture, under the body (the helpers win the place). All in
/// points, from the picture's top left. Pure arithmetic, so the self-test can check it.
enum AgentNookHelperPlace {
    /// The picture of `look` is `pictureSize(look)` cells of `px` points; the figure stands in it at `figureBox(look)`.
    static func pictureWidth(_ look: AgentNookLook, px: CGFloat) -> CGFloat { CGFloat(AgentPixelWorld.pictureSize(look).w) * px }
    static func pictureHeight(_ look: AgentNookLook, px: CGFloat) -> CGFloat { CGFloat(AgentPixelWorld.pictureSize(look).h) * px }

    /// The middle of the figure's head from the picture's left edge.
    static func figureMiddle(_ look: AgentNookLook, px: CGFloat) -> CGFloat {
        CGFloat(AgentPixelWorld.figureBox(look).x + AgentPixelSprites.figureWidth / 2) * px
    }

    /// The row's top from the picture's top: the figure's bottom edge. Awake helpers hop up a step (`hop` points), so they rest that much
    /// lower (never less than a cell of the picture): a hop never lands on the agent.
    static func rowTop(_ look: AgentNookLook, px: CGFloat, awake: Bool, hop: CGFloat) -> CGFloat {
        let box = AgentPixelWorld.figureBox(look)
        return CGFloat(box.y + box.h) * px + (awake ? max(px, hop) : 0)
    }

    /// How far the row reaches up into the picture (over the desk or the beanbag); 0 for a standing agent, whose row hangs under it.
    static func overlap(_ look: AgentNookLook, px: CGFloat, awake: Bool, hop: CGFloat) -> CGFloat {
        max(0, pictureHeight(look, px: px) - rowTop(look, px: px, awake: awake, hop: hop))
    }

    /// The left edge of a bunk (padding, `helpersWidth` of helpers, then the "+N") in a room `inner` wide whose picture is centred in it:
    /// the helpers (not the "+N") are centred on the figure. A bunk that would leave the room is shifted to stay inside, with its "+N".
    /// A multiple of half a point, like everything on the glass.
    static func bunkLeft(_ look: AgentNookLook, px: CGFloat, inner: CGFloat, padding: CGFloat, helpersWidth: CGFloat, bunkWidth: CGFloat) -> CGFloat {
        let pictureLeft = ((inner - pictureWidth(look, px: px)) / 2 * 2).rounded(.down) / 2
        let wanted = pictureLeft + figureMiddle(look, px: px) - padding - helpersWidth / 2
        let clamped = max(0, min(wanted, inner - bunkWidth))
        return (clamped * 2).rounded() / 2
    }

    /// The picture's left edge in a room `inner` wide (centred, on a half point).
    static func pictureLeft(_ look: AgentNookLook, px: CGFloat, inner: CGFloat) -> CGFloat {
        ((inner - pictureWidth(look, px: px)) / 2 * 2).rounded(.down) / 2
    }
}
