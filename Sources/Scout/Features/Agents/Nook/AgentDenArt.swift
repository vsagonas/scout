import SwiftUI

// The den in pixels: one screen of a late-80s console game. The room (wallpaper, panelling, carpet, rug), what hangs and stands in it
// (window, posters, neon sign, wall clock, shelf, lava lamp) and the five stations where the agents live. Our own drawings.
// The room is drawn in cells of `AgentDenArt.roomCell` points; a station in cells of its own size (a multiple of half a point).

/// The furniture sprites of the den and of a station.
enum AgentDenSprites {
    /// A red desk phone: the handset on its prongs, a body with a dial. 12 x 8.
    static let phone = PixelSprite([
        ".oooooooooo.",
        "oRRRRRRRRRRo",
        ".oooooooooo.",
        "..o......o..",
        ".oRRRRRRRRo.",
        "oRRRYYYYRRRo",
        "oRRRYooYRRRo",
        "oooooooooooo",
    ])

    /// A round side table. 14 x 10.
    static let table = PixelSprite([
        "oooooooooooooo",
        "ollllllllllllo",
        "onnnnnnnnnnnno",
        ".oooooooooooo.",
        ".....omno.....",
        ".....omno.....",
        ".....omno.....",
        ".....omno.....",
        "...oonnnnoo...",
        "..oooooooooo..",
    ])

    /// A ring of the phone: an arc, open to the right (flip it for the other side). 3 x 6.
    static let ring = PixelSprite(["..A", ".A.", "A..", "A..", ".A.", "..A"])

    /// A puff of smoke. 7 x 6.
    static let puff = PixelSprite([
        "..zzz..",
        ".zzzzz.",
        "zzzzzzz",
        "zzzzzzz",
        ".zzqzz.",
        "..qqq..",
    ])

    /// A tiny spark. 3 x 3.
    static let spark = PixelSprite(["Y.Y", ".Y.", "Y.Y"])

    /// The little cabinet a TV stands on. 22 x 5.
    static let cabinet = PixelSprite([
        "oooooooooooooooooooooo",
        "olllllllllllllllllllno",
        "onnnnnnnnnnnnnnnnnnnno",
        "ommmmmmmmmmmmmmmmmmmmo",
        "oooooooooooooooooooooo",
    ])

    /// A nightlight: a crescent on a small base. 7 x 9.
    static let nightlight = PixelSprite([
        "..LLL..",
        ".LLL...",
        "LLL....",
        "LLL....",
        ".LLL...",
        "..LLL..",
        ".ooooo.",
        "odddddo",
        "ooooooo",
    ])

    /// A pot plant. 9 x 14.
    static let plant = PixelSprite([
        "...G.G...",
        "..GGGGG..",
        ".GGTGGGG.",
        "GGGGGTGGG",
        ".GGGGGGG.",
        "G.GGTGG.G",
        "...GGG...",
        "...oGo...",
        "..ooooo..",
        ".oOOOOOo.",
        ".oOOOOOo.",
        ".oOOOOOo.",
        "..oOOOo..",
        "..ooooo..",
    ])

    /// A trophy. 7 x 9.
    static let trophy = PixelSprite([
        "oYYYYYo",
        "YoYYYoY",
        "oYYYYYo",
        ".oYYYo.",
        "..oYo..",
        "..oYo..",
        ".ooYoo.",
        ".onnno.",
        ".ooooo.",
    ])

    /// A lava lamp: a glass body of coloured wax, a cap and a base. 6 x 17.
    static let lavaLamp = PixelSprite([
        "..oo..",
        ".oddo.",
        ".oMMo.",
        "oMMMMo",
        "oMMMMo",
        "oMMMMo",
        "oMMMMo",
        "oMMMMo",
        "oMMMMo",
        "oMMMMo",
        "oMMMMo",
        "oMMMMo",
        ".oMMo.",
        "..oo..",
        ".oddo.",
        "oddddo",
        "oooooo",
    ])

    /// A book standing up, `h` tall (colour letter c).
    static func book(height h: Int, _ c: Character) -> PixelSprite {
        var rows = ["oooo"]
        for i in 1..<h { rows.append("o" + String(c) + (i == 2 || i == h - 3 ? "w" : String(c)) + "o") }
        rows.append("oooo")
        return PixelSprite(rows)
    }

    static var all: [(name: String, sprite: PixelSprite)] {
        [("phone", phone), ("table", table), ("ring", ring), ("puff", puff), ("spark", spark), ("cabinet", cabinet), ("nightlight", nightlight),
         ("plant", plant), ("trophy", trophy), ("lavaLamp", lavaLamp), ("book", book(height: 9, "R"))]
    }
}

// MARK: - Plastic: the TV and the smoking machine

enum AgentDenArt {
    /// One cell of the room, in points (the wall, the floor and everything on them).
    static let roomCell: CGFloat = 3

    // MARK: Helpers in cells

    /// A filled disc (a sun, a clock face) of radius `r` cells around the cell (cx, cy).
    static func disc(_ ctx: inout GraphicsContext, cx: Int, cy: Int, r: Int, origin: CGPoint, px: CGFloat, _ color: Color) {
        for dy in -r...r {
            let half = Int((Double(r * r - dy * dy)).squareRoot().rounded())
            AgentPixel.fill(&ctx, x: cx - half, y: cy + dy, w: 2 * half + 1, h: 1, origin: origin, px: px, color)
        }
    }

    /// A line of single cells.
    static func line(_ ctx: inout GraphicsContext, from a: (Int, Int), to b: (Int, Int), origin: CGPoint, px: CGFloat, _ color: Color, thick: Int = 1) {
        var x = a.0, y = a.1
        let dx = abs(b.0 - a.0), dy = -abs(b.1 - a.1)
        let sx = a.0 < b.0 ? 1 : -1, sy = a.1 < b.1 ? 1 : -1
        var err = dx + dy
        while true {
            AgentPixel.fill(&ctx, x: x, y: y, w: thick, h: thick, origin: origin, px: px, color)
            if x == b.0 && y == b.1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
        }
    }

    // MARK: TV

    /// A CRT television in cells: a dark plastic body, a screen of `screen` cells, a control column and two feet.
    /// Returns the sprite and where the screen starts.
    static func tv(screen: (w: Int, h: Int)) -> (sprite: PixelSprite, screenAt: (x: Int, y: Int)) {
        let bezel = 2, side = 5
        let w = screen.w + 2 * bezel + side, h = screen.h + 2 * bezel + 2
        var s = PixelSprite.blank(w, h)
        let bodyH = h - 2
        for y in 0..<bodyH {
            for x in 0..<w {
                var c: Character = "d"
                if x == 0 || x == w - 1 || y == 0 || y == bodyH - 1 { c = "o" }
                else if y == 1 || x == 1 { c = "u" }
                s[x, y] = c
            }
        }
        for x in [0, w - 1] { for y in [0, bodyH - 1] { s[x, y] = "." } }   // stepped corners
        // the screen: a dark well with the glass inside
        for y in (bezel - 1)..<(bezel + screen.h + 1) { for x in (bezel - 1)..<(bezel + screen.w + 1) { s[x, y] = "o" } }
        for y in bezel..<(bezel + screen.h) { for x in bezel..<(bezel + screen.w) { s[x, y] = "x" } }
        // the control column: two knobs and a grille
        let cx = bezel + screen.w + 2
        for ky in [2, 6] where ky + 2 < bodyH - 2 {
            s[cx, ky] = "g"; s[cx + 1, ky] = "g"; s[cx, ky + 1] = "z"; s[cx + 1, ky + 1] = "g"
        }
        var gy = 10
        while gy < bodyH - 4 { for x in cx..<(cx + 2) { s[x, gy] = "o" }; gy += 2 }
        s[cx, bodyH - 3] = "R"
        // two feet
        for y in bodyH..<h { for x in [2, 3, w - 4, w - 3] { s[x, y] = "o" } }
        return (s, (bezel, bezel))
    }

    /// A beige machine that has broken down: vents, a dead screen with a red X, a lamp and a crack. 16 x 18.
    static let machine: PixelSprite = {
        var s = PixelSprite.blank(16, 18)
        for y in 0..<16 { for x in 0..<16 {
            var c: Character = "e"
            if x == 0 || x == 15 || y == 0 || y == 15 { c = "o" } else if y == 1 || x == 1 { c = "w" } else if x == 14 || y == 14 { c = "f" }
            s[x, y] = c
        } }
        for x in [0, 15] { for y in [0, 15] { s[x, y] = "." } }
        for y in [3, 5] { for x in 3..<13 { s[x, y] = "f" } }                          // vents
        for y in 7..<12 { for x in 3..<13 { s[x, y] = (x == 3 || x == 12 || y == 7 || y == 11) ? "o" : "x" } }
        for (x, y) in [(5, 8), (9, 8), (6, 9), (8, 9), (7, 9), (6, 10), (8, 10), (5, 10), (9, 10)] { s[x, y] = "R" }   // a red X
        s[3, 13] = "R"; s[4, 13] = "R"                                                  // the lamp
        for (x, y) in [(10, 12), (11, 13), (10, 14), (11, 15)] { s[x, y] = "o" }        // a crack
        for y in 16..<18 { for x in [2, 3, 12, 13] { s[x, y] = "o" } }                   // feet
        return s
    }()
}
