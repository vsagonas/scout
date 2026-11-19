import SwiftUI

// 8-bit pixel art for the AgentNook.
// Every picture is a table of rows of palette letters, drawn as crisp square pixels: no gradients, no smoothing, no anti-aliased curves.
// One sprite pixel is `px` points everywhere in a picture, a multiple of 0.5 pt, so it lands on whole device pixels at 2x.
// Our own drawings. No image files.

/// A bitmap: rows of palette letters. "." is transparent.
struct PixelSprite: Equatable {
    private(set) var grid: [[Character]]

    init(_ rows: [String]) { grid = rows.map { Array($0) } }
    init(grid: [[Character]]) { self.grid = grid }

    var rows: [String] { grid.map { String($0) } }
    var height: Int { grid.count }
    var width: Int { grid.map(\.count).max() ?? 0 }
    var size: (w: Int, h: Int) { (width, height) }
    /// Every row is as wide as the widest.
    var isRectangular: Bool { grid.allSatisfy { $0.count == width } }
    /// The letters it uses besides ".".
    var letters: Set<Character> { Set(grid.joined()).subtracting(["."]) }

    static func blank(_ w: Int, _ h: Int) -> PixelSprite { PixelSprite(grid: Array(repeating: Array(repeating: ".", count: w), count: h)) }

    subscript(x: Int, y: Int) -> Character {
        get { y >= 0 && y < grid.count && x >= 0 && x < grid[y].count ? grid[y][x] : "." }
        set { if y >= 0 && y < grid.count && x >= 0 && x < grid[y].count { grid[y][x] = newValue } }
    }

    /// Sets single pixels, `(x, y, letter)`.
    func patched(_ pixels: [(Int, Int, Character)]) -> PixelSprite {
        var copy = self
        for (x, y, c) in pixels { copy[x, y] = c }
        return copy
    }

    func overlay(_ other: PixelSprite, _ x: Int, _ y: Int) -> PixelSprite {
        var copy = self
        for (r, row) in other.grid.enumerated() {
            for (c, ch) in row.enumerated() where ch != "." { copy[x + c, y + r] = ch }
        }
        return copy
    }

    func flipped() -> PixelSprite { PixelSprite(grid: grid.map { Array($0.reversed()) }) }

    /// Turns letters into other letters (the right half of a mirrored sprite loses its highlight, a sleeping one dims).
    func mapped(_ map: [Character: Character]) -> PixelSprite { PixelSprite(grid: grid.map { $0.map { map[$0] ?? $0 } }) }

    func replacingRows(_ range: ClosedRange<Int>, with rows: [String]) -> PixelSprite {
        var g = grid
        g.replaceSubrange(range, with: rows.map { Array($0) })
        return PixelSprite(grid: g)
    }

    func droppingRows(_ range: ClosedRange<Int>) -> PixelSprite {
        var g = grid
        g.removeSubrange(range)
        return PixelSprite(grid: g)
    }

    /// Repeats column `column` `count` more times (a sleeping scout is a wide one).
    func widened(atColumn column: Int, by count: Int) -> PixelSprite {
        PixelSprite(grid: grid.map { row in
            var r = row
            r.insert(contentsOf: Array(repeating: row[min(column, row.count - 1)], count: count), at: min(column, row.count))
            return r
        })
    }

    /// The left half is written, the right half is its mirror (`rightMap` changes letters on the right).
    static func mirrored(_ half: [String], rightMap: [Character: Character] = [:]) -> [String] {
        half.map { row in
            let right = row.reversed().map { rightMap[$0] ?? $0 }
            return row + String(right)
        }
    }
}

/// The letters of a picture and their colours. One small palette: a dark outline, the kind's body colour with one shade and one highlight,
/// cream, white and black for the eyes, then the world's few colours (wood, beige plastic, lamp yellow, screen green…).
struct PixelPalette {
    var colors: [Character: Color]

    func color(_ letter: Character) -> Color? { colors[letter] }
    var letters: Set<Character> { Set(colors.keys) }

    static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }

    /// The palette for a kind of agent (its tint: Claude Code sand-orange, Codex green).
    static func world(_ kind: AgentKind = .claude) -> PixelPalette {
        let tint = kind.tint
        var c: [Character: Color] = [
            // the scout
            "o": Retro.shade(tint, -0.78),
            "b": tint,
            "s": Retro.shade(tint, -0.26),
            "h": Retro.shade(tint, 0.30),
            "c": rgb(0.98, 0.93, 0.80),
            "w": rgb(1, 1, 1),
            "k": rgb(0.10, 0.08, 0.12),
            "r": rgb(1.0, 0.56, 0.58),
            // wood
            "n": rgb(0.55, 0.36, 0.22), "m": rgb(0.34, 0.21, 0.14), "l": rgb(0.74, 0.52, 0.31),
            // beige plastic, greys, screens
            "e": rgb(0.82, 0.78, 0.66), "f": rgb(0.60, 0.56, 0.46), "g": rgb(0.52, 0.52, 0.55), "d": rgb(0.18, 0.18, 0.22), "x": rgb(0.04, 0.07, 0.08),
            "u": rgb(0.30, 0.31, 0.36),
            // bright colours
            "R": rgb(0.92, 0.22, 0.20), "Y": rgb(1.0, 0.84, 0.20), "A": rgb(1.0, 0.69, 0.13), "G": rgb(0.30, 0.86, 0.42), "T": rgb(0.10, 0.76, 0.76),
            "P": rgb(0.56, 0.36, 0.92), "M": rgb(0.96, 0.28, 0.62), "O": rgb(1.0, 0.56, 0.16), "B": rgb(0.32, 0.52, 0.96), "L": rgb(0.78, 0.82, 1.0),
            // darker world colours (night sky, carpet, wall)
            "N": rgb(0.08, 0.10, 0.26), "C": rgb(0.30, 0.12, 0.20), "W": rgb(0.14, 0.25, 0.33), "V": rgb(0.19, 0.31, 0.40),
            "z": rgb(0.62, 0.64, 0.70), "q": rgb(0.45, 0.50, 0.62),
            "Q": rgb(0.72, 0.62, 1.0), "p": rgb(0.34, 0.22, 0.60), "H": rgb(1.0, 0.95, 0.70), "S": rgb(0.62, 0.84, 1.0),
        ]
        c["."] = nil
        return PixelPalette(colors: c)
    }

    /// Every colour darkened (a sleeping scout in a dark room).
    func dimmed(_ amount: Double) -> PixelPalette {
        PixelPalette(colors: colors.mapValues { Retro.shade($0, -amount) })
    }
}

/// How big one pixel is, and how a sprite is drawn.
enum AgentPixel {
    /// The pixel size that fits a picture of `grid` cells into `area`: a multiple of 0.5 pt (so it lands on whole device pixels at 2x),
    /// between `lowest` and `highest`.
    static func size(grid: (w: Int, h: Int), in area: CGSize, lowest: CGFloat = 1, highest: CGFloat = 4) -> CGFloat {
        guard grid.w > 0, grid.h > 0 else { return lowest }
        let fit = min(area.width / CGFloat(grid.w), area.height / CGFloat(grid.h))
        return min(highest, max(lowest, (fit * 2).rounded(.down) / 2))
    }

    /// True when a pixel of this size lands on whole device pixels at 2x (and on whole points or half points).
    static func isCrisp(_ px: CGFloat) -> Bool { px >= 0.5 && (px * 2).rounded() == px * 2 }

    /// Draws a sprite with its top-left corner at `origin` (in points, itself a multiple of half a point).
    static func draw(_ sprite: PixelSprite, in ctx: inout GraphicsContext, at origin: CGPoint, px: CGFloat, palette: PixelPalette, opacity: Double = 1) {
        var paths: [Character: Path] = [:]
        for (r, row) in sprite.grid.enumerated() {
            var c = 0
            while c < row.count {
                let ch = row[c]
                if ch == "." { c += 1; continue }
                var end = c + 1
                while end < row.count, row[end] == ch { end += 1 }   // a run of one colour is one rectangle
                paths[ch, default: Path()].addRect(CGRect(x: origin.x + CGFloat(c) * px, y: origin.y + CGFloat(r) * px, width: CGFloat(end - c) * px, height: px))
                c = end
            }
        }
        for (ch, path) in paths {
            guard let color = palette.color(ch) else { continue }
            ctx.fill(path, with: .color(opacity < 1 ? color.opacity(opacity) : color))
        }
    }

    /// A filled block in grid cells.
    static func fill(_ ctx: inout GraphicsContext, x: Int, y: Int, w: Int, h: Int, origin: CGPoint, px: CGFloat, _ color: Color) {
        guard w > 0, h > 0 else { return }
        ctx.fill(Path(CGRect(x: origin.x + CGFloat(x) * px, y: origin.y + CGFloat(y) * px, width: CGFloat(w) * px, height: CGFloat(h) * px)), with: .color(color))
    }

    /// Dither: every other cell of a block (a checkerboard), for light and shade the 8-bit way.
    static func dither(_ ctx: inout GraphicsContext, x: Int, y: Int, w: Int, h: Int, origin: CGPoint, px: CGFloat, _ color: Color, phase: Int = 0) {
        guard w > 0, h > 0 else { return }
        var path = Path()
        for r in 0..<h {
            var c = (r + phase) % 2
            while c < w {
                path.addRect(CGRect(x: origin.x + CGFloat(x + c) * px, y: origin.y + CGFloat(y + r) * px, width: px, height: px))
                c += 2
            }
        }
        ctx.fill(path, with: .color(color))
    }

    /// Pixel capitals (the kit's own 5x7 font) as crisp squares at a grid position; unknown characters are blanks.
    static func text(_ ctx: inout GraphicsContext, _ text: String, x: Int, y: Int, origin: CGPoint, px: CGFloat, _ color: Color) {
        var path = Path()
        for (c, r) in RetroPixelLayout.litPixels(RetroPixelLayout.columns(text)) {
            path.addRect(CGRect(x: origin.x + CGFloat(x + c) * px, y: origin.y + CGFloat(y + r) * px, width: px, height: px))
        }
        ctx.fill(path, with: .color(color))
    }

    /// The width of pixel text in grid cells.
    static func textWidth(_ text: String) -> Int { LEDFont.width(text) }
}

/// A placed sprite in a picture: grid position, and an optional palette (a dimmed one for a sleeping scout).
struct PixelPlacement {
    var sprite: PixelSprite
    var x: Int
    var y: Int
    var dim: Double = 0
}

/// A picture made of placed sprites on a grid of `w` x `h` cells.
struct PixelPicture {
    var w: Int
    var h: Int
    var placements: [PixelPlacement]

    func draw(_ ctx: inout GraphicsContext, origin: CGPoint, px: CGFloat, palette: PixelPalette) {
        for p in placements {
            AgentPixel.draw(p.sprite, in: &ctx, at: CGPoint(x: origin.x + CGFloat(p.x) * px, y: origin.y + CGFloat(p.y) * px), px: px,
                            palette: p.dim > 0 ? palette.dimmed(p.dim) : palette)
        }
    }
}

// MARK: - The sprites

/// Every sprite table of the scouts and their things (the self-test checks that each is rectangular and uses only the palette).
enum AgentPixelSprites {
    // MARK: The scout

    /// The scout is a square head on a small body:
    /// the head is the wing's own 12 x 12 face (`AgentFaceArt.figureHead`: the same outline with its cut corners, the
    /// highlight, the cheeks, the eyes and mouth of the look, and the headwear of the agent's face), at columns 2 to 13 of a 16 x 16 figure; under
    /// it a cream neckerchief with a knot (the chin is its upper edge) and its lower edge, then two feet. Nothing stands above the head's top row.
    static let figureWidth = 16
    /// The head's place in the figure: the figure's left margin, and the top row.
    static let headColumn = 2

    /// Rows 12 to 15 of the standing figure: the neckerchief (shoulders as wide as the head), its lower edge, the feet.
    private static let bodyRows = [
        "..occccsscccco..",   // 12 neckerchief with the knot
        "...oooooooooo...",   // 13 lower edge
        "...osso..osso...",   // 14 feet
        "...oooo..oooo...",   // 15
    ]

    /// The figure of `look` (a scout in its pose) wearing `variant`'s headwear: the working one sits at its desk (no feet), the sleeping one
    /// has none either, the others stand. The head is `AgentFaceArt.figureHead`: with a `tick` and `burst` the wing's own frame of that step
    /// (the face moves), without one the face at rest (`eyesShut` is its blink).
    static func figure(_ look: AgentNookLook, tick: Int? = nil, burst: Bool = false, eyesShut: Bool = false, variant: Int = 0) -> PixelSprite {
        var sprite = PixelSprite.blank(figureWidth, 16).overlay(AgentFaceArt.figureHead(look, tick: tick, burst: burst, eyesShut: eyesShut, variant: variant), headColumn, 0)
        sprite = sprite.replacingRows(12...15, with: bodyRows)
        return look == .working || look == .idle ? sprite.droppingRows(14...15) : sprite
    }

    /// The scout standing, asking (a hand goes up beside it), eyes open and shut.
    static let scout: PixelSprite = figure(.needsYou)
    static let scoutBlink: PixelSprite = figure(.needsYou, eyesShut: true)

    /// Happy arches and a wide smile.
    static let scoutHappy: PixelSprite = figure(.finished)

    /// Dizzy crosses and a wobbly mouth.
    static let scoutDizzy: PixelSprite = figure(.stopped)

    /// The scout at a desk: no feet (the desk is in front of them), looking at its computer.
    static let scoutSeated: PixelSprite = figure(.working)

    static let scoutSeatedBlink: PixelSprite = figure(.working, eyesShut: true)

    /// The scout asleep: eyes shut, a tiny mouth, no feet (the beanbag is under it).
    static let scoutAsleep: PixelSprite = figure(.idle)

    /// A raised arm (cheering, asking): 4 wide, 12 tall; the shoulder is the bottom.
    static let armUp = PixelSprite([
        ".oo.",
        "ohho",
        "ohho",
        "obbo",
        "obbo",
        "obbo",
        "obbo",
        "obso",
        "obso",
        "obso",
        ".oso",
        "..oo",
    ])

    // MARK: Helpers (8 x 8)

    /// A helper has the scout's square head too, no tuft on top.
    private static let miniRows = [
        "..oooo..",
        ".ohhbbo.",
        "ohhbbbbo",
        "obkbbkbo",
        "obkbbkbo",
        "occcccco",
        ".osssso.",
        ".oo..oo.",
    ]

    static let miniAwake = PixelSprite(miniRows)

    /// A helper asleep: eyes as little lines.
    static let miniAsleep = PixelSprite(miniRows).patched([(2, 3, "b"), (5, 3, "b"), (2, 4, "k"), (5, 4, "k"), (1, 4, "o"), (6, 4, "o")])

    /// A helper of the agent that wears face `variant`: drawn with that face's palette (the same skin), and when the agent wears something
    /// on its head (hair, a cap, a beanie, headphones, a bow), a small fringe of the same colour on top, so an agent and its helpers read as
    /// one family
    static func familyMini(awake: Bool, variant: Int) -> PixelSprite {
        let sprite = awake ? miniAwake : miniAsleep
        guard AgentFaceArt.style(variant) != 0 else { return sprite }
        let c = AgentFaceArt.colours[AgentFaceArt.colour(variant)]
        return sprite.patched([(2, 0, c), (3, 0, c), (4, 0, c), (5, 0, c), (1, 1, c), (2, 1, c), (3, 1, c), (4, 1, c), (5, 1, c), (6, 1, c), (1, 2, c), (6, 2, c)])
    }

    // MARK: Bubbles and badges

    private static let bubbleRows = [
        "..ooooooo..",
        ".oAAAAAAAo.",
        "oAAAAAAAAAo",
        "oAAAAAAAAAo",
        "oAAAAAAAAAo",
        "oAAAAAAAAAo",
        "oAAAAAAAAAo",
        "oAAAAAAAAAo",
        "oAAAAAAAAAo",
        ".oAAAAAAAo.",
        "..oAAooooo.",
        "...oAo.....",
        "....oo.....",
    ]

    /// The "?" bubble of an agent that needs you. 11 x 13.
    static let askBubble = PixelSprite(bubbleRows).patched([
        (4, 2, "k"), (5, 2, "k"), (6, 2, "k"), (3, 3, "k"), (7, 3, "k"), (7, 4, "k"), (6, 5, "k"), (5, 6, "k"), (5, 8, "k"),
    ])

    /// The pixel check mark in a green badge. 11 x 11.
    static let checkBadge = PixelSprite([
        "...ooooo...",
        "..oGGGGGo..",
        ".oGGGGGGGo.",
        "oGGGGGGGGGo",
        "oGGGGGGGGGo",
        "oGGGGGGGGGo",
        "oGGGGGGGGGo",
        "oGGGGGGGGGo",
        ".oGGGGGGGo.",
        "..oGGGGGo..",
        "...ooooo...",
    ]).patched([(2, 5, "w"), (3, 6, "w"), (4, 7, "w"), (5, 6, "w"), (6, 5, "w"), (7, 4, "w"), (8, 3, "w"),
                (2, 4, "w"), (3, 5, "w"), (4, 6, "w"), (6, 4, "w"), (7, 3, "w"), (5, 5, "w")])

    /// A small gold star. 3 x 3.
    static let star = PixelSprite([".Y.", "YYY", ".Y."])
    static let sparkle = PixelSprite([".c.", "ccc", ".c."])

    /// The Z's of sleep: three sizes.
    static let zSmall = PixelSprite(["wwww", "..w.", ".w..", "wwww"]).mapped(["w": "L"])
    static let zMedium = PixelSprite(["wwwww", "...w.", "..w..", ".w...", "wwwww"]).mapped(["w": "L"])
    static let zLarge = PixelSprite(["wwwwww", "....w.", "...w..", "..w...", ".w....", "wwwwww"]).mapped(["w": "L"])

    // MARK: Props (8 x 8, white on a dark screen)

    static let wrench = PixelSprite([
        ".ww..ww.",
        ".ww..ww.",
        ".wwwwww.",
        "...ww...",
        "...ww...",
        "..wwww..",
        ".ww..ww.",
        "..wwww..",
    ])

    static let pencil = PixelSprite([
        "......MM",
        ".....wwM",
        "....www.",
        "...www..",
        "..www...",
        ".wYw....",
        ".YY.....",
        "k.......",
    ])

    static let magnifier = PixelSprite([
        ".wwww...",
        "w....w..",
        "w....w..",
        "w....w..",
        ".wwww...",
        ".....w..",
        "......w.",
        ".......w",
    ])

    static let globe = PixelSprite([
        "..wwww..",
        ".w.ww.w.",
        "w..ww..w",
        "wwwwwwww",
        "w..ww..w",
        ".w.ww.w.",
        "..wwww..",
        "........",
    ])

    /// The screen of a scout that is only thinking: lines of text.
    static let textLines = PixelSprite([
        "GGGGGG..",
        "........",
        "GGGG.GG.",
        "........",
        "GGGGGGG.",
        "........",
        "GGG.....",
        "........",
    ])

    /// Lines of code scrolling up a screen, one line a step, with a cursor that blinks at the end of the newest line. 8 x 8.
    static func runningText(step: Int) -> PixelSprite {
        let lengths = [6, 4, 7, 3, 5, 7, 2, 6, 4, 5, 3, 7, 5, 2, 6]
        let s = max(0, step)
        var rows: [String] = []
        for r in 0..<8 {
            if r % 2 == 1 { rows.append("........"); continue }
            let n = lengths[(r / 2 + s) % lengths.count]
            var row = String(repeating: "G", count: n) + String(repeating: ".", count: 8 - n)
            if r == 6, s % 2 == 0, n < 8 { row = String(row.prefix(n)) + "Y" + String(row.dropFirst(n + 1)) }
            rows.append(row)
        }
        return PixelSprite(rows)
    }

    static func prop(_ p: AgentNookProp) -> PixelSprite {
        switch p {
        case .wrench: wrench
        case .pencil: pencil
        case .magnifier: magnifier
        case .globe: globe
        }
    }

    // MARK: Furniture of the scout's room

    /// A chunky beige computer: a monitor with an 8 x 8 screen (the prop shows there), a power light, a neck and a foot. 14 x 17.
    static let computer = PixelSprite([
        ".oooooooooooo.",
        "oeeeeeeeeeeeeo",
        "oeffffffffffeo",
        "oefxxxxxxxxfeo",
        "oefxxxxxxxxfeo",
        "oefxxxxxxxxfeo",
        "oefxxxxxxxxfeo",
        "oefxxxxxxxxfeo",
        "oefxxxxxxxxfeo",
        "oefxxxxxxxxfeo",
        "oefxxxxxxxxfeo",
        "oeffffffffffeo",
        "oeeeeeeeeeeGeo",
        ".oooooooooooo.",
        ".....oeeo.....",
        "...oeeeeeeo...",
        "...oooooooo...",
    ])

    /// Where the 8 x 8 prop goes on the computer's screen.
    static let computerScreen = (x: 3, y: 3)

    /// The keyboard, flat on the desk. 14 x 3.
    static let keyboard = PixelSprite([
        ".oooooooooooo.",
        "oefefefefefefo",
        ".oooooooooooo.",
    ])

    /// A desk `w` cells wide: a light top and a dark front with two drawers. Height 6.
    static func desk(width w: Int) -> PixelSprite {
        let inner = max(0, w - 2)
        var s = PixelSprite([
            String(repeating: "o", count: w),
            "o" + String(repeating: "l", count: inner) + "o",
            "o" + String(repeating: "n", count: inner) + "o",
            "o" + String(repeating: "m", count: inner) + "o",
            "o" + String(repeating: "m", count: inner) + "o",
            String(repeating: "o", count: w),
        ])
        let drawer = max(8, (w - 8) / 2)
        for d in 0..<2 {
            let x0 = 3 + d * (drawer + 2)
            guard x0 + drawer < w - 2 else { continue }
            for x in x0..<(x0 + drawer) { s[x, 3] = "n"; s[x, 4] = "n" }
            s[x0 + drawer / 2 - 1, 3] = "Y"; s[x0 + drawer / 2, 3] = "Y"
        }
        return s
    }

    /// A pixel lamp that hangs from the ceiling: cord, shade, bulb. 7 x 6.
    static let hangingLamp = PixelSprite([
        "...o...",
        "..oYo..",
        ".oYYYo.",
        "oYYYYYo",
        "ooooooo",
        "..AAA..",
    ])

    static let moon = PixelSprite([
        "..LLL..",
        ".LLL...",
        "LLL....",
        "LLL....",
        "LLL....",
        ".LLL...",
        "..LLL..",
    ])

    // MARK: The registry (for the self-test and the sprite sheet)

    static var all: [(name: String, sprite: PixelSprite)] {
        [("scout", scout), ("scoutBlink", scoutBlink), ("scoutHappy", scoutHappy), ("scoutDizzy", scoutDizzy), ("scoutSeated", scoutSeated),
         ("scoutSeatedBlink", scoutSeatedBlink), ("scoutAsleep", scoutAsleep), ("armUp", armUp), ("miniAwake", miniAwake), ("miniAsleep", miniAsleep),
         ("askBubble", askBubble), ("checkBadge", checkBadge), ("star", star), ("sparkle", sparkle),
         ("zSmall", zSmall), ("zMedium", zMedium), ("zLarge", zLarge), ("wrench", wrench), ("pencil", pencil), ("magnifier", magnifier),
         ("globe", globe), ("textLines", textLines), ("computer", computer), ("keyboard", keyboard), ("desk", desk(width: 40)),
         ("hangingLamp", hangingLamp), ("moon", moon)] + AgentPixelWorld.sprites
    }
}
