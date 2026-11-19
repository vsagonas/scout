import SwiftUI

// The den's drawing: the room, what hangs and stands in it, the glow of its lamps, the five stations and the empty den.
// Everything is cells (`px` points each, a multiple of half a point) of the kit's pixel font and the sprites of AgentPixelArt.

/// Cell positions of the den's fixtures for a room of `cols` x `rows` cells (so the room, the decor and the tests agree).
struct AgentDenPlan {
    var cols: Int
    var rows: Int
    var wallRows: Int
    var rail: Int
    var window: Int
    var posterA: Int
    var sign: Int
    var posterB: Int
    var shelf: Int

    init(size: CGSize, cell: CGFloat = AgentDenArt.roomCell) {
        let c = Int((size.width / cell).rounded(.up))
        let wall = Int(AgentDenLayout.wallHeight / cell)
        cols = c
        rows = Int((size.height / cell).rounded(.up))
        wallRows = wall
        rail = Int(Double(wall) * 0.60)
        func at(_ fraction: Double) -> Int { Int((Double(c) * fraction).rounded()) }
        window = at(0.11); posterA = at(0.265); sign = at(0.47); posterB = at(0.64); shelf = at(0.81)
    }
}

extension AgentDenArt {
    // MARK: The room

    /// The wallpaper, the wooden panelling and the carpet with its rug. Static: it only changes with the size and the hour.
    static func drawRoom(_ ctx: inout GraphicsContext, size: CGSize, night: Bool) {
        let plan = AgentDenPlan(size: size)
        let px = roomCell
        let o = CGPoint.zero
        let pal = PixelPalette.world(.claude).dimmed(night ? 0.45 : 0)
        func c(_ ch: Character) -> Color { pal.color(ch) ?? .black }
        func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ ch: Character) { AgentPixel.fill(&ctx, x: x, y: y, w: w, h: h, origin: o, px: px, c(ch)) }
        let cols = plan.cols, wall = plan.wallRows, rail = plan.rail
        // The wallpaper: dark teal with a lattice of light dots.
        fill(0, 0, cols, wall, "W")
        var dots = Path()
        var y = 5
        while y < rail - 1 {
            var x = (y / 5) % 2 == 0 ? 3 : 6
            while x < cols { dots.addRect(CGRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: px, height: px)); x += 6 }
            y += 5
        }
        ctx.fill(dots, with: .color(c("V")))
        // The crown moulding and the chair rail.
        fill(0, 0, cols, 2, "m"); fill(0, 2, cols, 1, "n"); fill(0, 3, cols, 1, "o")
        fill(0, rail, cols, 1, "l"); fill(0, rail + 1, cols, 1, "n"); fill(0, rail + 2, cols, 1, "o")
        // The panelling: planks with a light left edge and a dark right edge.
        let panelTop = rail + 3, panelBottom = wall - 3
        fill(0, panelTop, cols, panelBottom - panelTop, "n")
        var x = 0
        while x < cols {
            fill(x, panelTop, 1, panelBottom - panelTop, "o")
            fill(x + 1, panelTop, 1, panelBottom - panelTop, "l")
            fill(x + 9, panelTop, 1, panelBottom - panelTop, "m")
            x += 10
        }
        // The baseboard.
        fill(0, panelBottom, cols, 1, "o"); fill(0, panelBottom + 1, cols, 2, "m")
        // The carpet: deep red with a woven texture.
        fill(0, wall, cols, plan.rows - wall, "C")
        fill(0, wall, cols, 1, "o")
        var weave = Path()
        for r in stride(from: wall + 1, to: max(wall + 1, plan.rows), by: 1) {
            var xx = r % 2 == 0 ? 0 : 2
            while xx < cols { weave.addRect(CGRect(x: CGFloat(xx) * px, y: CGFloat(r) * px, width: px, height: px)); xx += 4 }
        }
        ctx.fill(weave, with: .color(Retro.shade(c("C"), 0.10)))
        // The rug: a border of teal and gold round a purple field with a lattice of diamonds.
        let rugX = AgentDenLayout.rugEdgeCells, rugW = cols - 2 * rugX
        let rugY = wall + 5, rugH = plan.rows - rugY - 2
        if rugW > 30, rugH > 12 {
            fill(rugX, rugY, rugW, rugH, "o")
            fill(rugX + 1, rugY + 1, rugW - 2, rugH - 2, "T")
            fill(rugX + 3, rugY + 3, rugW - 6, rugH - 6, "Y")
            fill(rugX + 4, rugY + 4, rugW - 8, rugH - 8, "p")
            var diamonds = Path()
            var ry = rugY + 6
            while ry < rugY + rugH - 5 {
                var rx = rugX + 8 + ((ry - rugY) / 6 % 2 == 0 ? 0 : 4)
                while rx < rugX + rugW - 7 {
                    for (dx, dy) in [(0, -1), (-1, 0), (0, 0), (1, 0), (0, 1)] {
                        diamonds.addRect(CGRect(x: CGFloat(rx + dx) * px, y: CGFloat(ry + dy) * px, width: px, height: px))
                    }
                    rx += 8
                }
                ry += 6
            }
            ctx.fill(diamonds, with: .color(c("P")))
            // The fringe at both ends.
            for r in stride(from: rugY + 2, to: rugY + rugH - 1, by: 2) {
                fill(rugX - 2, r, 2, 1, "Y"); fill(rugX + rugW, r, 2, 1, "Y")
            }
        }
    }

    // MARK: What hangs and stands in it

    /// The window (day or night by the hour), the wall clock, the shelf with books, a plant and a lava lamp. No posters and no "AGENT TV" sign
    /// any more.
    static func drawDecor(_ ctx: inout GraphicsContext, size: CGSize, date: Date, night: Bool) {
        let plan = AgentDenPlan(size: size)
        let px = roomCell
        let o = CGPoint.zero
        let bright = PixelPalette.world(.claude)
        let pal = bright.dimmed(night ? 0.38 : 0)
        func draw(_ s: PixelSprite, _ x: Int, _ y: Int, bright b: Bool = false) { AgentPixel.draw(s, in: &ctx, at: CGPoint(x: CGFloat(x) * px, y: CGFloat(y) * px), px: px, palette: b ? bright : pal) }
        window(&ctx, x: plan.window - 15, y: 8, day: !night, date: date, px: px)
        clock(&ctx, cx: plan.sign, cy: 27, date: date, px: px, pal: pal)
        // The shelf: a board on two brackets, books, a plant, a lava lamp.
        let sx = plan.shelf - 23, sy = 38
        func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ ch: Character) { AgentPixel.fill(&ctx, x: x, y: y, w: w, h: h, origin: o, px: px, pal.color(ch) ?? .black) }
        fill(sx, sy, 46, 1, "o"); fill(sx, sy + 1, 46, 1, "l"); fill(sx, sy + 2, 46, 1, "n"); fill(sx, sy + 3, 46, 1, "o")
        for bx in [sx + 4, sx + 38] { fill(bx, sy + 4, 2, 4, "o"); fill(bx + 2, sy + 4, 1, 3, "m") }
        let heights = [9, 11, 8, 10, 9], colors: [Character] = ["R", "B", "G", "Y", "P"]
        for (i, h) in heights.enumerated() { draw(AgentDenSprites.book(height: h, colors[i]), sx + 2 + i * 5, sy - h - 2) }
        draw(AgentDenSprites.plant, sx + 28, sy - 14)
        draw(AgentDenSprites.lavaLamp, sx + 39, sy - 17, bright: true)
    }

    /// The window: a sash with four panes, curtains and a sill. Day: sky, a sun, clouds, green hills. Night: stars, a crescent, a city.
    static func window(_ ctx: inout GraphicsContext, x: Int, y: Int, day: Bool, date: Date, px: CGFloat) {
        let o = CGPoint.zero
        let pal = PixelPalette.world(.claude)
        func fill(_ fx: Int, _ fy: Int, _ w: Int, _ h: Int, _ ch: Character) { AgentPixel.fill(&ctx, x: fx, y: fy, w: w, h: h, origin: o, px: px, pal.color(ch) ?? .black) }
        // The frame.
        fill(x, y, 30, 28, "o"); fill(x + 1, y + 1, 28, 26, "n"); fill(x + 2, y + 2, 26, 24, "o")
        let gx = x + 3, gy = y + 3, gw = 24, gh = 22
        fill(gx, gy, gw, gh, day ? "S" : "N")
        if day {
            // clouds, a sun, hills
            for (cx, cy, w) in [(gx + 2, gy + 3, 7), (gx + 14, gy + 7, 8)] { fill(cx, cy, w, 2, "w"); fill(cx + 1, cy - 1, w - 3, 1, "w") }
            disc(&ctx, cx: gx + 18, cy: gy + 5, r: 3, origin: o, px: px, pal.color("Y") ?? .yellow)
            fill(gx, gy + 16, gw, 6, "G"); fill(gx + 3, gy + 15, 9, 1, "G"); fill(gx + 14, gy + 14, 8, 2, "G")
            fill(gx, gy + 20, gw, 2, "T")
        } else {
            for (sx, sy) in [(2, 2), (9, 5), (15, 1), (21, 8), (5, 11), (12, 9)] { fill(gx + sx, gy + sy, 1, 1, "w") }
            AgentPixel.draw(AgentPixelSprites.moon, in: &ctx, at: CGPoint(x: CGFloat(gx + 15) * px, y: CGFloat(gy + 3) * px), px: px, palette: pal)
            // a city: blocks with lit windows
            let blocks: [(Int, Int)] = [(0, 8), (5, 12), (10, 7), (14, 10), (19, 6)]
            for (bx, bh) in blocks { fill(gx + bx, gy + gh - bh, 5, bh, "d") }
            for (bx, bh) in blocks { for wy in stride(from: gy + gh - bh + 1, to: gy + gh - 1, by: 3) { fill(gx + bx + 1, wy, 1, 1, "Y"); fill(gx + bx + 3, wy + 1, 1, 1, "Y") } }
        }
        // The cross bars.
        fill(gx + gw / 2 - 1, gy, 2, gh, "n"); fill(gx, gy + gh / 2 - 1, gw, 2, "n")
        // The sill and the curtains: magenta with darker folds, tied back.
        fill(x - 2, y + 28, 34, 2, "l"); fill(x - 2, y + 30, 34, 1, "o")
        fill(x - 2, y - 2, 34, 2, "n"); fill(x - 2, y - 2, 34, 1, "l")
        for side in [0, 1] {
            let cx = side == 0 ? x - 4 : x + 28
            fill(cx, y - 1, 6, 29, "M")
            for fx in [cx + 1, cx + 4] { fill(fx, y, 1, 26, "R") }
            fill(cx, y + 15, 6, 2, "Y")
            fill(cx, y - 1, 6, 1, "o"); fill(cx, y + 28, 6, 1, "o")
        }
    }

    /// An invented poster: a neon sunset over a grid, "NEON" over it.
    static func posterNeon(_ ctx: inout GraphicsContext, x: Int, y: Int, px: CGFloat, pal: PixelPalette) {
        let o = CGPoint.zero
        func c(_ ch: Character) -> Color { pal.color(ch) ?? .black }
        func fill(_ fx: Int, _ fy: Int, _ w: Int, _ h: Int, _ ch: Character) { AgentPixel.fill(&ctx, x: fx, y: fy, w: w, h: h, origin: o, px: px, c(ch)) }
        fill(x, y, 28, 30, "c"); fill(x + 1, y + 1, 26, 28, "N")
        AgentPixel.text(&ctx, "NEON", x: x + 2, y: y + 3, origin: o, px: px, c("Y"))
        // the sun, cut by dark slits
        disc(&ctx, cx: x + 14, cy: y + 16, r: 6, origin: o, px: px, c("M"))
        fill(x + 9, y + 16, 11, 5, "O")
        for sy in [y + 17, y + 19, y + 21] { fill(x + 7, sy, 15, 1, "N") }
        fill(x + 1, y + 22, 26, 7, "P")
        // the grid in perspective
        for gy in [y + 23, y + 25, y + 28] { fill(x + 1, gy, 26, 1, "T") }
        for k in -4...4 { line(&ctx, from: (x + 14 + k, y + 22), to: (x + 14 + k * 3, y + 28), origin: o, px: px, c("T")) }
    }

    /// An invented poster: teal with confetti and "RAD".
    static func posterRad(_ ctx: inout GraphicsContext, x: Int, y: Int, px: CGFloat, pal: PixelPalette) {
        let o = CGPoint.zero
        func c(_ ch: Character) -> Color { pal.color(ch) ?? .black }
        func fill(_ fx: Int, _ fy: Int, _ w: Int, _ h: Int, _ ch: Character) { AgentPixel.fill(&ctx, x: fx, y: fy, w: w, h: h, origin: o, px: px, c(ch)) }
        fill(x, y, 20, 26, "c"); fill(x + 1, y + 1, 18, 24, "T")
        // a triangle, a ring, a zigzag and stripes
        for i in 0..<5 { fill(x + 3, y + 3 + i, i + 1, 1, "Y") }
        disc(&ctx, cx: x + 14, cy: y + 6, r: 3, origin: o, px: px, c("M"))
        disc(&ctx, cx: x + 14, cy: y + 6, r: 1, origin: o, px: px, c("T"))
        for i in 0..<8 { fill(x + 3 + i, y + 12 + (i % 2), 1, 1, "P") }
        for sy in [y + 15, y + 17] { fill(x + 11, sy, 6, 1, "O") }
        AgentPixel.text(&ctx, "RAD", x: x + 2, y: y + 18, origin: o, px: px, c("N"))
        AgentPixel.text(&ctx, "RAD", x: x + 1, y: y + 17, origin: o, px: px, c("w"))
    }

    /// The wall clock: a pixel face with the real time.
    static func clock(_ ctx: inout GraphicsContext, cx: Int, cy: Int, date: Date, px: CGFloat, pal: PixelPalette) {
        let o = CGPoint.zero
        func c(_ ch: Character) -> Color { pal.color(ch) ?? .black }
        disc(&ctx, cx: cx, cy: cy, r: 8, origin: o, px: px, c("o"))
        disc(&ctx, cx: cx, cy: cy, r: 7, origin: o, px: px, c("n"))
        disc(&ctx, cx: cx, cy: cy, r: 6, origin: o, px: px, c("c"))
        for (tx, ty) in [(0, -5), (5, 0), (0, 5), (-5, 0)] { AgentPixel.fill(&ctx, x: cx + tx, y: cy + ty, w: 1, h: 1, origin: o, px: px, c("k")) }
        let a = AgentDenSky.clockAngles(date)
        func end(_ degrees: Double, _ len: Double) -> (Int, Int) {
            let r = degrees * .pi / 180
            return (cx + Int((sin(r) * len).rounded()), cy - Int((cos(r) * len).rounded()))
        }
        line(&ctx, from: (cx, cy), to: end(a.hour, 3), origin: o, px: px, c("k"))
        line(&ctx, from: (cx, cy), to: end(a.minute, 5), origin: o, px: px, c("R"))
        AgentPixel.fill(&ctx, x: cx, y: cy, w: 1, h: 1, origin: o, px: px, c("k"))
    }

    // MARK: The glow of the lamps

    /// What fades: the lava lamp (wax and glow) and, at night, the warm light of the lamp on the shelf.
    static func drawGlow(_ ctx: inout GraphicsContext, size: CGSize, clock: AgentNookClock, night: Bool) {
        let plan = AgentDenPlan(size: size)
        let px = roomCell
        let o = CGPoint.zero
        let pal = PixelPalette.world(.claude)
        func c(_ ch: Character) -> Color { pal.color(ch) ?? .black }
        let breathe = clock.t == nil ? 1.0 : 0.55 + 0.45 * clock.pulse(period: 4.2)
        // The lava lamp: wax blobs rising (a second frame while it moves), and its glow.
        let lx = plan.shelf - 23 + 39, ly = 38 - 17
        let f = clock.frame(period: 2.5)
        let blobs: [(Int, Int)] = f == 0 ? [(2, 5), (3, 8), (2, 11)] : [(3, 4), (2, 7), (3, 10)]
        for (bx, by) in blobs { AgentPixel.fill(&ctx, x: lx + bx, y: ly + by, w: 2, h: 2, origin: o, px: px, c("O")) }
        var glow = ctx
        glow.opacity = (night ? 0.5 : 0.22) * breathe
        for r in 0..<14 {
            let half = max(2, 9 - abs(r - 6))
            AgentPixel.dither(&glow, x: lx + 3 - half, y: ly + r - 2, w: 2 * half, h: 1, origin: o, px: px, c("M"), phase: r)
        }
    }

    // MARK: A station

    /// The cells of one station: 44 wide, 36 tall (the furniture stands on row 27, the helpers sit on the floor rows under it).
    static let station = (w: 44, h: 36)
    /// The floor row of a station: the furniture stands on row 27; the floor is under it.
    static let stationFloor = 28

    /// Where the picture of each state is placed in a station (cells from its top left). One table for the drawing and for the helpers'
    /// row, so the helpers always find the agent (`AgentDenLayout.helperSpot`).
    static func pictureOrigin(_ look: AgentNookLook) -> (x: Int, y: Int) {
        switch look {
        case .working: (7, 6)
        case .needsYou: (0, 4)
        case .finished: (8, 4)
        case .stopped: (0, 6)
        case .idle: (3, 7)
        }
    }

    /// Draws the station of one agent at `origin` with cells of `px` points.
    static func drawStation(_ ctx: inout GraphicsContext, _ st: AgentDenStation, kind: AgentKind, prop: AgentNookProp?, clock: AgentNookClock,
                            origin: CGPoint, px: CGFloat, selected: Bool, hover: Bool, glow: Bool, variant: Int = 0, burst: Bool = false) {
        let look = st.room.look
        let pal = PixelPalette.face(kind, variant: variant)   // each agent its own skin, like its face in the wing
        let world = PixelPalette.world(.claude)
        let frame = clock.frame(), blink = clock.blinking()
        func at(_ x: Int, _ y: Int) -> CGPoint { CGPoint(x: origin.x + CGFloat(x) * px, y: origin.y + CGFloat(y) * px) }
        func sprite(_ s: PixelSprite, _ x: Int, _ y: Int, opacity: Double = 1, palette: PixelPalette? = nil) {
            AgentPixel.draw(s, in: &ctx, at: at(x, y), px: px, palette: palette ?? world, opacity: opacity)
        }
        func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ ch: Character) { AgentPixel.fill(&ctx, x: x, y: y, w: w, h: h, origin: origin, px: px, world.color(ch) ?? .black) }
        func picture(_ look: AgentNookLook, _ x: Int, _ y: Int, furniture: Bool = true) {
            // The screen runs text while the agent works: a new line every 0.35 s (a still clock, in pictures and tests, stays on one step).
            let pic = AgentPixelWorld.picture(look: look, prop: prop, frame: frame, blink: blink, furniture: furniture,
                                              running: look == .working ? Int((clock.t ?? 0) / 0.35) : nil, variant: variant,
                                              face: clock.faceStep(burst: burst))
            pic.draw(&ctx, origin: at(x, y), px: px, palette: pal)
        }
        // The soft shadow on the carpet, under the furniture.
        AgentPixel.dither(&ctx, x: 1, y: 26, w: station.w - 2, h: 2, origin: origin, px: px, Color.black.opacity(0.35))
        let place = pictureOrigin(look)
        switch look {
        case .working:
            picture(.working, place.x, place.y)
        case .needsYou:
            // The ring: arcs either side of the phone. They fade in turn under Reduce Motion, and spread when it moves. They are drawn first: the
            // agent's bubble (now beside its square head, 16 to 26) lies over the far arc on the left.
            let far = clock.t == nil ? 0.6 : 0.2 + 0.8 * clock.pulse(period: 1.1)
            let near = clock.t == nil ? 1.0 : 0.5 + 0.5 * clock.pulse(period: 1.1, phase: 0.5)
            let spread = clock.frame(period: 0.35)
            sprite(AgentDenSprites.ring, 27 - spread, 6, opacity: near)
            sprite(AgentDenSprites.ring.flipped(), 42 + spread, 6, opacity: near)
            sprite(AgentDenSprites.ring, 24 - spread, 5, opacity: far)
            sprite(AgentDenSprites.ring.flipped(), 45 + spread - 1, 5, opacity: far)
            picture(.needsYou, place.x, place.y, furniture: true)
            sprite(AgentDenSprites.table, 29, 18)
            let shake = clock.frame(period: 0.25)
            sprite(AgentDenSprites.phone, 30 + shake, 10)
        case .finished:
            // Only the agent, happy, in the middle of its spot: no TV with the minutes and no "MIN" sign
            picture(.finished, place.x, place.y, furniture: false)
        case .stopped:
            picture(.stopped, place.x, place.y)
            sprite(AgentDenArt.machine, 27, 10)
            // Smoke rises: three puffs that thin out; they drift a cell in the second frame.
            let drift = frame
            let thin = clock.t == nil ? 1.0 : 0.6 + 0.4 * clock.pulse(period: 2.2)
            sprite(AgentDenSprites.puff, 28 + drift, 4, opacity: 0.9)
            sprite(AgentDenSprites.puff, 32 - drift, 0, opacity: 0.65 * thin)
            let spark = clock.t == nil ? 1.0 : clock.pulse(period: 0.9)
            sprite(AgentDenSprites.spark, 25, 11, opacity: spark)
            sprite(AgentDenSprites.spark, 42, 16, opacity: 1 - spark * 0.6)
        case .idle:
            picture(.idle, place.x, place.y)
            var light = ctx
            light.opacity = clock.t == nil ? 0.5 : 0.25 + 0.4 * clock.pulse(period: 5)
            for r in 0..<11 {
                let half = max(1, 6 - abs(r - 5))
                AgentPixel.dither(&light, x: 39 - half, y: 15 + r, w: 2 * half, h: 1, origin: origin, px: px, world.color("L") ?? .white, phase: r)
            }
            sprite(AgentDenSprites.nightlight, 36, 19)
        }
        // The helpers stand right under their agent, centred on its figure, as 8 x 8 scouts (asleep when their agent is). Four are drawn;
        // the rest are a "+N" in pixel digits at the row's right end, white with a dark outline, so it reads at every size.
        let row = AgentDenLayout.helperRow(count: st.room.helpers)
        if row.drawn > 0 {
            let spot = AgentDenLayout.helperSpot(look: look, drawn: row.drawn, more: row.more)
            let helper = AgentPixelSprites.familyMini(awake: st.room.helpersAwake, variant: variant)   // its agent's skin and hair colour
            let helperPalette = st.room.helpersAwake ? pal : pal.dimmed(0.30)
            for i in 0..<row.drawn {
                let hop = st.room.helpersAwake && clock.frame(period: 0.4, phase: Double(i) * 0.5) == 1 ? 1 : 0
                AgentPixel.draw(helper, in: &ctx, at: at(spot.left + i * (8 + spot.gap), spot.top - hop), px: px, palette: helperPalette)
            }
            if row.more > 0 {
                let label = "+\(row.more)", x0 = spot.label, y0 = spot.top + 1
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
                    AgentPixel.text(&ctx, label, x: x0 + dx, y: y0 + dy, origin: origin, px: px, Color.black)
                }
                AgentPixel.text(&ctx, label, x: x0, y: y0, origin: origin, px: px, Color.white)
            }
        }
        // The cursor: four corner brackets when the agent is chosen, paler under the pointer, white when it glows.
        if selected || hover || glow {
            let color = glow ? Color.white : (selected ? Color(red: 1.0, green: 0.84, blue: 0.20) : Color.white.opacity(0.55))
            let w = station.w, h = station.h, n = 4
            for (x, y, dx, dy) in [(0, 0, 1, 1), (w - 1, 0, -1, 1), (0, h - 1, 1, -1), (w - 1, h - 1, -1, -1)] {
                AgentPixel.fill(&ctx, x: dx > 0 ? x : x - n + 1, y: y, w: n, h: 1, origin: origin, px: px, color)
                AgentPixel.fill(&ctx, x: x, y: dy > 0 ? y : y - n + 1, w: 1, h: n, origin: origin, px: px, color)
            }
        }
    }

    /// The TV of a station that finished: the minutes it took on the screen, "MIN" on the cabinet, and a green check beside it.
    private static func tvStation(_ ctx: inout GraphicsContext, _ st: AgentDenStation, origin: CGPoint, px: CGFloat) {
        let world = PixelPalette.world(.claude)
        let t = tv(screen: (12, 11))
        func place(_ s: PixelSprite, _ x: Int, _ y: Int) { AgentPixel.draw(s, in: &ctx, at: CGPoint(x: origin.x + CGFloat(x) * px, y: origin.y + CGFloat(y) * px), px: px, palette: world) }
        func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ ch: Character) { AgentPixel.fill(&ctx, x: x, y: y, w: w, h: h, origin: origin, px: px, world.color(ch) ?? .black) }
        let tx = 23, ty = 0
        place(t.sprite, tx, ty)
        let sx = tx + t.screenAt.x, sy = ty + t.screenAt.y
        let digits: String, unit: String
        if let took = st.tookSeconds { let r = AgentDenStation.took(took); digits = r.digits; unit = r.unit } else { digits = "✓"; unit = "DONE" }
        AgentPixel.dither(&ctx, x: sx, y: sy, w: 12, h: 11, origin: origin, px: px, (world.color("G") ?? .green).opacity(0.14))
        let tw = AgentPixel.textWidth(digits)
        AgentPixel.text(&ctx, digits, x: sx + max(0, (12 - tw) / 2), y: sy + 2, origin: origin, px: px, world.color("G") ?? .green)
        // the cabinet with the unit on its front
        let cx = tx - 1, cy = 17, cw = 22
        fill(cx, cy, cw, 11, "o"); fill(cx + 1, cy + 1, cw - 2, 1, "l"); fill(cx + 1, cy + 2, cw - 2, 1, "n"); fill(cx + 1, cy + 3, cw - 2, 7, "m")
        let uw = AgentPixel.textWidth(unit)
        AgentPixel.text(&ctx, unit, x: cx + max(1, (cw - uw) / 2), y: cy + 3, origin: origin, px: px, world.color("Y") ?? .yellow)
    }

    // MARK: The empty den

    /// The empty den's TV with its cabinet, in points (the room draws it here and the view puts the calm line under it).
    static func emptyFrame(size: CGSize, px: CGFloat) -> CGRect {
        let cols = Int(size.width / px)
        let plan = AgentDenPlan(size: size)
        let t = tv(screen: (42, 24))
        let w = t.sprite.width, h = t.sprite.height
        let tvX = max(2, cols / 2 - w / 2 - 14), tvY = plan.wallRows - h - 9 + 12
        return CGRect(x: CGFloat(tvX) * px, y: CGFloat(tvY) * px, width: CGFloat(w) * px, height: CGFloat(h + 9) * px)
    }

    /// Nobody home: the room stays empty, a simple NO AGENTS on the floor and the empty beanbag with its nightlight beside it.
    /// `emptyFrame` is still where the TV used to stand: the beanbag sits there and the note (if any) goes under it.
    /// Returns that rectangle.
    @discardableResult
    static func drawEmptyDen(_ ctx: inout GraphicsContext, size: CGSize, clock: AgentNookClock, px: CGFloat, note: Bool = false) -> CGRect {
        let rows = Int(size.height / px)
        let world = PixelPalette.world(.claude)
        let t = tv(screen: (42, 24))
        let w = t.sprite.width, h = t.sprite.height
        let cabH = 9
        let frame = emptyFrame(size: size, px: px)
        let tvX = Int(frame.minX / px), tvY = Int(frame.minY / px)
        let o = CGPoint.zero
        let box = CGRect(x: CGFloat(tvX) * px, y: CGFloat(tvY) * px, width: CGFloat(w) * px, height: CGFloat(h + cabH) * px)
        // The note and its key stand where the beanbag would: then the room has nothing on the rug.
        guard !note else { return box }
        // Pixel capitals in the middle of the floor,
        // white with a dark outline like the old screen words.
        let cols = Int(size.width / px)
        let wallRows = AgentDenPlan(size: size, cell: px).wallRows
        let words = pixelLabel("NO AGENTS"), tw = AgentPixel.textWidth(words)
        let tx = max(2, cols / 2 - tw / 2), ty = wallRows + max(2, (rows - wallRows) / 2 - 4)
        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
            AgentPixel.text(&ctx, words, x: tx + dx, y: ty + dy, origin: o, px: px, Color.black.opacity(0.85))
        }
        AgentPixel.text(&ctx, words, x: tx, y: ty, origin: o, px: px, world.color("w") ?? .white)
        // the beanbag, empty, and a nightlight, beside the words (clear of the shelf at the right in a narrow den)
        let bagX = min(cols - 36, tx + tw + 12), bagY = rows - 9 - 4
        AgentPixel.draw(AgentPixelWorld.beanbag, in: &ctx, at: CGPoint(x: CGFloat(bagX) * px, y: CGFloat(bagY) * px), px: px, palette: world.dimmed(0.18))
        var halo = ctx
        halo.opacity = clock.t == nil ? 0.5 : 0.25 + 0.4 * clock.pulse(period: 5)
        for r in 0..<11 {
            let half = max(1, 6 - abs(r - 5))
            AgentPixel.dither(&halo, x: bagX + 30 - half, y: bagY - 3 + r, w: 2 * half, h: 1, origin: o, px: px, world.color("L") ?? .white, phase: r)
        }
        AgentPixel.draw(AgentDenSprites.nightlight, in: &ctx, at: CGPoint(x: CGFloat(bagX + 27) * px, y: CGFloat(bagY - 1) * px), px: px, palette: world)
        return box
    }
}
