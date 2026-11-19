import SwiftUI

// The scout's own little world in pixels: the five poses as pictures (the scout plus what it touches), the beanbag, the walls of a room.
// The den's furniture is in AgentDenArt. Same pixel grid for all of it.

/// One moment of a big figure's face: the step on the wing's beat (`AgentFaceArt.tick`) and whether it lies in the couple of seconds after
/// something happened (`AgentFaceArt.burstSeconds`).
struct AgentFaceStep: Equatable {
    var tick: Int
    var burst: Bool
}

enum AgentPixelWorld {
    // MARK: The beanbag

    /// A purple beanbag: round, a light patch on top, a dark underside. 26 x 9.
    static let beanbag: PixelSprite = {
        let widths = [12, 18, 22, 24, 26, 26, 26, 24, 20]
        var rows: [String] = []
        for (i, w) in widths.enumerated() {
            let pad = (26 - w) / 2
            var row = [Character](repeating: ".", count: 26)
            for x in pad..<(pad + w) {
                var ch: Character = "P"
                if x == pad || x == pad + w - 1 || i == 0 || i == widths.count - 1 { ch = "o" }
                else if i >= widths.count - 3 { ch = "p" }
                else if i <= 2 && x < 13 && x > pad + 1 { ch = "Q" }
                row[x] = ch
            }
            rows.append(String(row))
        }
        return PixelSprite(rows)
    }()

    static var sprites: [(name: String, sprite: PixelSprite)] { [("beanbag", beanbag), ("machine", AgentDenArt.machine), ("tv", AgentDenArt.tv(screen: (12, 9)).sprite)] + AgentDenSprites.all }

    // MARK: The five poses

    /// A scout of `look` wearing `variant`'s face: the wing's frame of `face`'s step (it moves), or the face at rest when there is no step
    /// (`blink` shuts the resting eyes of a working or an asking one).
    private static func scout(_ look: AgentNookLook, blink: Bool = false, face: AgentFaceStep?, variant: Int) -> PixelSprite {
        AgentPixelSprites.figure(look, tick: face?.tick, burst: face?.burst ?? false, eyesShut: blink, variant: variant)
    }

    /// Where the scout's figure stands in the picture of a look (`picture(look:...)`, furniture or not): the figure's left column and top row,
    /// and its height in cells (a seated or sleeping one has no feet: 14 rows, the others 16). Its head, and so its middle, is column
    /// `AgentPixelSprites.figureWidth / 2` of the figure. A still picture's place: the finished one hops a row up in its second frame.
    /// The helpers stand right under this (`AgentDenLayout.helperSpot`, `AgentNookHelperPlace`).
    static func figureBox(_ look: AgentNookLook) -> (x: Int, y: Int, h: Int) {
        switch look {
        case .working: (0, 1, 14)
        case .needsYou: (2, 8, 16)
        case .finished: (4, 8, 16)
        case .stopped: (6, 6, 16)
        case .idle: (7, 1, 14)
        }
    }

    /// The picture's own size in cells (the furniture drawn).
    static func pictureSize(_ look: AgentNookLook) -> (w: Int, h: Int) {
        switch look {
        case .working: (30, 22)
        case .needsYou, .finished: (28, 24)
        case .stopped: (28, 22)
        case .idle: (30, 21)
        }
    }

    /// The scout and what it touches, for a look. `frame` is 0 or 1 (a second frame only while Reduce Motion is off), `blink` shuts the eyes.
    /// With `furniture` false only the scout (and its bubble) is drawn.
    /// `variant` is the agent's face from `AgentFaceArt.variants`: the figure's head is that face (the same headwear in the same colour).
    /// `face` is the step of that face: with one the head moves like the
    /// wing's face of that agent (glances, blinks, calls, laughs), without one (a still picture) it is at rest and `blink` applies.
    /// `running`: the step of the running text on a working agent's screen (nil: the step's prop, still). The den passes it
    static func picture(look: AgentNookLook, prop: AgentNookProp?, frame: Int, blink: Bool, furniture: Bool = true, running: Int? = nil, variant: Int = 0,
                        face: AgentFaceStep? = nil) -> PixelPicture {
        switch look {
        case .working: return working(prop: prop, frame: frame, blink: blink, furniture: furniture, running: running, variant: variant, face: face)
        case .needsYou: return needsYou(frame: frame, blink: blink, variant: variant, face: face)
        case .finished: return finished(frame: frame, stars: furniture, variant: variant, face: face)
        case .stopped: return stopped(frame: frame, variant: variant, face: face)
        case .idle: return asleep(frame: frame, furniture: furniture, variant: variant, face: face)
        }
    }

    /// At a chunky computer: the step's prop on its screen, two hands on the keyboard (the hands swap in the second frame).
    private static func working(prop: AgentNookProp?, frame: Int, blink: Bool, furniture: Bool, running: Int? = nil, variant: Int = 0, face: AgentFaceStep? = nil) -> PixelPicture {
        let deskW = 30
        var parts: [PixelPlacement] = []
        let creature = scout(.working, blink: blink, face: face, variant: variant)
        parts.append(PixelPlacement(sprite: creature, x: 0, y: 1))
        if furniture {
            parts.append(PixelPlacement(sprite: AgentPixelSprites.desk(width: deskW), x: 0, y: 16))
            parts.append(PixelPlacement(sprite: AgentPixelSprites.computer, x: 16, y: 0))
            let screen = running.map { AgentPixelSprites.runningText(step: $0) } ?? (prop.map { AgentPixelSprites.prop($0) } ?? AgentPixelSprites.textLines)
            parts.append(PixelPlacement(sprite: screen, x: 16 + AgentPixelSprites.computerScreen.x, y: AgentPixelSprites.computerScreen.y))
            parts.append(PixelPlacement(sprite: AgentPixelSprites.keyboard, x: 1, y: 14))
            let hand = PixelSprite(["oo", "bb"])
            let left = frame == 0 ? (5, 12) : (5, 13), right = frame == 0 ? (11, 13) : (11, 12)
            parts.append(PixelPlacement(sprite: hand, x: left.0, y: left.1))
            parts.append(PixelPlacement(sprite: hand, x: right.0, y: right.1))
        }
        return PixelPicture(w: deskW, h: furniture ? 22 : 14, placements: parts)
    }

    /// Standing, one hand up (it waves a little in the second frame) and a "?" bubble.
    /// The head (columns 2 to 13 of the figure, so 4 to 15 of the picture) has its hand up on the left (the shoulder is the neckerchief; the
    /// hand only bobs, so it never covers a cup or a lock of the headwear) and its bubble up on the right, beside the headwear (the bow, the
    /// cap's peak: nothing of the face's wear reaches past column 15 of the picture).
    private static func needsYou(frame: Int, blink: Bool, variant: Int = 0, face: AgentFaceStep? = nil) -> PixelPicture {
        let body = scout(.needsYou, blink: blink, face: face, variant: variant)
        let parts = [
            PixelPlacement(sprite: body, x: 2, y: 8),
            PixelPlacement(sprite: AgentPixelSprites.armUp, x: 0, y: 9 + (frame == 0 ? 0 : 1)),
            PixelPlacement(sprite: AgentPixelSprites.askBubble, x: 16, y: 0),
        ]
        return PixelPicture(w: 28, h: 24, placements: parts)
    }

    /// Happy eyes, a wide smile, one arm up holding the pixel check mark; sparkles.
    private static func finished(frame: Int, stars: Bool, variant: Int = 0, face: AgentFaceStep? = nil) -> PixelPicture {
        let up = frame == 0 ? 0 : 1
        let parts = [
            PixelPlacement(sprite: AgentPixelSprites.sparkle, x: 1, y: 6 - up),
            PixelPlacement(sprite: AgentPixelSprites.star, x: 2, y: 15),
            PixelPlacement(sprite: scout(.finished, face: face, variant: variant), x: 4, y: 8 - up),
            PixelPlacement(sprite: AgentPixelSprites.armUp.flipped(), x: 18, y: 9 - up),
            PixelPlacement(sprite: AgentPixelSprites.checkBadge, x: 17, y: 0 - up),
        ] + (stars ? [PixelPlacement(sprite: AgentPixelSprites.star, x: 25, y: 14)] : [])
        return PixelPicture(w: 28, h: 24, placements: parts)
    }

    /// Dizzy eyes (a cross and a plus swap in the second frame), stars going round its head (two spots in the second frame).
    private static func stopped(frame: Int, variant: Int = 0, face: AgentFaceStep? = nil) -> PixelPicture {
        let a: [(Int, Int)] = [(3, 2), (12, 0), (21, 3)], b: [(Int, Int)] = [(21, 3), (3, 2), (12, 0)]
        let spots = frame == 0 ? a : b
        var parts = [PixelPlacement(sprite: scout(.stopped, face: face, variant: variant), x: 6, y: 6)]
        for s in spots { parts.append(PixelPlacement(sprite: AgentPixelSprites.star, x: s.0, y: s.1)) }
        return PixelPicture(w: 28, h: 22, placements: parts)
    }

    /// Asleep on a beanbag, with Z's rising.
    private static func asleep(frame: Int, furniture: Bool, variant: Int = 0, face: AgentFaceStep? = nil) -> PixelPicture {
        var parts = [PixelPlacement(sprite: scout(.idle, face: face, variant: variant), x: 7, y: 1, dim: 0.14)]
        if furniture { parts.append(PixelPlacement(sprite: beanbag, x: 2, y: 12)) }
        parts.append(PixelPlacement(sprite: AgentPixelSprites.zSmall, x: 25, y: 8 - frame))
        parts.append(PixelPlacement(sprite: AgentPixelSprites.zMedium, x: 25, y: 2 - frame))
        return PixelPicture(w: 30, h: furniture ? 21 : 14, placements: parts)
    }
}
