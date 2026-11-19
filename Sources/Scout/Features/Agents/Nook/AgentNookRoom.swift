import AppKit
import SwiftUI

/// Which rows a room has space for (pure arithmetic, so the self-test can check it). The scout comes first and every scout on a screen has
/// the SAME pixel size, the biggest that fits (with one small row kept free under it when any room of the screen has helpers or a
/// counter). The helpers' bunk and the to-do counter are made to fit under it: normal size, then small, then both on one row; the
/// counter drops its blocks and keeps its number before it goes (a counter is never clipped). The one-line sentence comes last.
enum AgentNookRoomRows {
    struct Plan: Equatable {
        var bunk = false
        var shelf = false
        var sentence = false
        /// The bunk and the shelf share one row.
        var combined = false
        /// A very wide room puts the scout on the left, big, and the bunk, the shelf and the sentence in a column on the right.
        var side = false
        /// The rows are small (a helper 8 pixels, the counter 7) to leave the scout its size.
        var tight = false
        /// One pixel of the scout, in points: a multiple of half a point, the same for every room of a screen.
        var px: CGFloat = 1
    }

    struct Metrics {
        var pad: CGFloat, plate: CGFloat, bunk: CGFloat, shelf: CGFloat, sentence: CGFloat, gap: CGFloat, bunkTight: CGFloat, shelfTight: CGFloat
    }

    static func metrics(_ style: AgentNookLayout.Style) -> Metrics {
        switch style {
        case .roomy: Metrics(pad: 4, plate: 14, bunk: 16, shelf: 12, sentence: 12, gap: 2, bunkTight: 11, shelfTight: 8)
        case .compact: Metrics(pad: 3, plate: 11, bunk: 11, shelf: 10, sentence: 0, gap: 2, bunkTight: 11, shelfTight: 8)
        }
    }

    /// The biggest scene (the widest and tallest of the five pictures) in pixels.
    static let scene = (w: 30, h: 24)

    /// A wide room puts the bunk and the shelf side by side.
    static let combinedFrom: CGFloat = 150
    /// A very wide room (one agent in a wide panel) gets the column on the right.
    static let sideFrom: CGFloat = 236
    static let sideColumn: CGFloat = 108

    /// The pixel size of the scouts of a screen whose rooms are `size`: the biggest that fits the plate and the scene, keeping one small
    /// row under it when `needsRow` (some room has helpers or a counter).
    /// `helpers`: some room of the screen has helpers. In a very wide room the helpers stand under the scout too (not in the column at the
    /// right), so that room keeps the row free under the scout then.
    static func scoutPixel(style: AgentNookLayout.Style, size: CGSize, needsRow: Bool, helpers: Bool = false) -> CGFloat {
        let m = metrics(style)
        let side = style == .roomy && size.width >= sideFrom
        let reserve: CGFloat = (side ? helpers : needsRow) ? m.bunkTight + m.gap : 0
        let width = side ? size.width - sideColumn - 8 - 2 * m.pad : size.width - 2 * m.pad
        let height = size.height - 2 * m.pad - m.plate - m.gap - reserve
        return AgentPixel.size(grid: scene, in: CGSize(width: width, height: height), lowest: 1, highest: side ? 3 : 2.5)
    }

    static func plan(helpers: Int, todos: Int, style: AgentNookLayout.Style, size: CGSize, needsRow: Bool? = nil, screenHelpers: Bool? = nil) -> Plan {
        let m = metrics(style)
        var plan = Plan()
        plan.px = scoutPixel(style: style, size: size, needsRow: needsRow ?? (helpers > 0 || todos > 0), helpers: screenHelpers ?? (helpers > 0))
        if style == .roomy, size.width >= sideFrom {
            plan.side = true; plan.bunk = helpers > 0; plan.shelf = todos > 0; plan.sentence = true
            // The helpers' row stands under the scout: the full-size one when the room is tall enough, else the small one (the row kept free).
            plan.tight = size.height - 2 * m.pad - m.plate - m.gap - CGFloat(scene.h) * plan.px < m.bunk + m.gap
            return plan
        }
        var left = size.height - 2 * m.pad - m.plate - m.gap - CGFloat(scene.h) * plan.px
        let wide = style == .roomy && size.width >= combinedFrom
        func take(_ height: CGFloat) -> Bool {
            guard left >= height + m.gap else { return false }
            left -= height + m.gap
            return true
        }
        if helpers > 0, todos > 0 {
            if take(m.bunk + m.shelf + m.gap) { plan.bunk = true; plan.shelf = true }
            else if wide, take(max(m.bunk, m.shelf)) { plan.bunk = true; plan.shelf = true; plan.combined = true }
            else if take(m.bunkTight + m.shelfTight + m.gap) { plan.bunk = true; plan.shelf = true; plan.tight = true }
            else if take(m.bunkTight) { plan.bunk = true; plan.shelf = true; plan.combined = true; plan.tight = true }
        } else if helpers > 0 {
            if take(m.bunk) { plan.bunk = true } else if take(m.bunkTight) { plan.bunk = true; plan.tight = true }
        } else if todos > 0 {
            if take(m.shelf) { plan.shelf = true } else if take(m.shelfTight) { plan.shelf = true; plan.tight = true }
        }
        if style == .roomy, take(m.sentence) { plan.sentence = true }
        return plan
    }
}

/// The room's walls in pixels: flat colours and dithered light in whole cells of 2 pt. The light tells the state (a warm lamp, amber,
/// daylight, dim, dark with a moon), then the floor, a pixel lamp and the pennant of the flag. Behind everything else in the room.
struct AgentNookWall: View {
    var look: AgentNookLook
    var style: AgentNookLayout.Style
    var clock: AgentNookClock = .still
    /// The hanging lamp is drawn. A long name plate takes its place (the lamp's light stays), so the two never overlap.
    var showLamp = true
    /// The moon's row: lower when the name plate reaches it.
    var moonRow = 3
    /// The dark floor strip along the bottom. The Agent TV's glass has none: it read as black space above the border
    var floor = true
    /// The dashboard's Agent TV: a soft, warm, cozy wall instead of the brown one
    var cozy = false

    /// One cell of the wall.
    static let cell: CGFloat = 2

    /// Where the hanging lamp starts in a roomy room this wide, in points from the left.
    static func lampLeft(width: CGFloat) -> CGFloat {
        let cols = Int((width / cell).rounded(.up))
        return CGFloat(Int(Double(cols) * 0.6) - 3) * cell
    }

    /// Where the moon (with the star beside it) starts in a dark room this wide, in points from the left.
    static func moonLeft(width: CGFloat) -> CGFloat {
        let cols = Int((width / cell).rounded(.up))
        return CGFloat(cols - 18) * cell
    }

    private struct Palette {
        var wall: Color, lower: Color, glow: Color?, floor: Color
    }

    private var palette: Palette {
        func c(_ r: Double, _ g: Double, _ b: Double) -> Color { PixelPalette.rgb(r, g, b) }
        // Dusty rose with a peach lamp glow: warm and soft, and the agents' peach faces still stand out on it.
        if cozy { return Palette(wall: c(0.47, 0.30, 0.34), lower: c(0.39, 0.24, 0.29), glow: c(0.80, 0.56, 0.48), floor: c(0.25, 0.15, 0.18)) }
        switch look.light {
        case .lampOn: return Palette(wall: c(0.31, 0.20, 0.10), lower: c(0.25, 0.16, 0.08), glow: c(0.50, 0.35, 0.17), floor: c(0.15, 0.10, 0.06))
        case .amber: return Palette(wall: c(0.36, 0.23, 0.06), lower: c(0.28, 0.18, 0.05), glow: c(0.62, 0.42, 0.10), floor: c(0.17, 0.10, 0.04))
        case .daylight: return Palette(wall: c(0.28, 0.40, 0.46), lower: c(0.22, 0.33, 0.39), glow: c(0.50, 0.64, 0.70), floor: c(0.14, 0.21, 0.26))
        case .dim: return Palette(wall: c(0.15, 0.15, 0.18), lower: c(0.12, 0.12, 0.15), glow: nil, floor: c(0.08, 0.08, 0.10))
        case .dark: return Palette(wall: c(0.07, 0.08, 0.17), lower: c(0.06, 0.06, 0.13), glow: nil, floor: c(0.04, 0.04, 0.09))
        }
    }

    var body: some View {
        Canvas { context, size in
            var ctx = context
            let p = palette
            let px = Self.cell
            let cols = Int((size.width / px).rounded(.up)), rows = Int((size.height / px).rounded(.up))
            let o = CGPoint.zero
            let world = PixelPalette.world(.claude)
            AgentPixel.fill(&ctx, x: 0, y: 0, w: cols, h: rows, origin: o, px: px, p.wall)
            let floorRows = floor ? (style == .roomy ? 3 : 2) : 0
            let railRow = Int(Double(rows - floorRows) * 0.62)
            AgentPixel.fill(&ctx, x: 0, y: railRow, w: cols, h: rows - floorRows - railRow, origin: o, px: px, p.lower)
            AgentPixel.dither(&ctx, x: 0, y: railRow, w: cols, h: 1, origin: o, px: px, p.wall)
            // The lamp's light: a lighter cone of dither under it, fading in and out under Reduce Motion.
            let lampCol = style == .roomy ? Int(Double(cols) * 0.6) : cols / 2
            let breathe = clock.t == nil ? 1 : 0.55 + 0.45 * clock.pulse(period: 4)
            if let glow = p.glow {
                var layer = ctx
                layer.opacity = breathe
                if look.light == .daylight {
                    for r in 0..<max(0, min(rows - floorRows, rows / 2)) { AgentPixel.dither(&layer, x: 0, y: r, w: cols, h: 1, origin: o, px: px, glow.opacity(0.55), phase: r) }
                } else {
                    for r in stride(from: 5, to: max(5, rows - floorRows), by: 1) {
                        let half = 2 + Int(Double(r - 5) * 0.7)
                        let x0 = max(0, lampCol - half), x1 = min(cols, lampCol + half + 1)
                        AgentPixel.dither(&layer, x: x0, y: r, w: x1 - x0, h: 1, origin: o, px: px, glow.opacity(0.5), phase: r)
                        let inner = max(0, half - 3)
                        if inner > 0 { AgentPixel.fill(&layer, x: max(0, lampCol - inner), y: r, w: min(cols, lampCol + inner + 1) - max(0, lampCol - inner), h: 1, origin: o, px: px, glow.opacity(0.28)) }
                    }
                }
            }
            // The floor, with a light edge.
            if floorRows > 0 {
                AgentPixel.fill(&ctx, x: 0, y: rows - floorRows, w: cols, h: floorRows, origin: o, px: px, p.floor)
                AgentPixel.fill(&ctx, x: 0, y: rows - floorRows, w: cols, h: 1, origin: o, px: px, Color.white.opacity(0.10))
            }
            if style == .roomy, showLamp { lamp(&ctx, col: lampCol, palette: world) }
            if look.hasMoon { moon(&ctx, cols: cols, palette: world) }
            if let flag = look.flag { self.flag(&ctx, flag, cols: cols) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The hanging lamp: lit in a lit room, dark when nobody is awake, red and low in a dim one.
    private func lamp(_ ctx: inout GraphicsContext, col: Int, palette: PixelPalette) {
        let lit = look.light == .lampOn || look.light == .amber
        var p = palette
        if !lit {
            let off = look.light == .daylight ? 0.30 : 0.62
            p = palette.dimmed(off)
            if look.light == .dim { p.colors["Y"] = PixelPalette.rgb(0.50, 0.14, 0.12); p.colors["A"] = PixelPalette.rgb(0.50, 0.14, 0.12) }
        }
        AgentPixel.draw(AgentPixelSprites.hangingLamp, in: &ctx, at: CGPoint(x: CGFloat(col - 3) * Self.cell, y: 0), px: Self.cell, palette: p)
    }

    private func moon(_ ctx: inout GraphicsContext, cols: Int, palette: PixelPalette) {
        AgentPixel.draw(AgentPixelSprites.moon, in: &ctx, at: CGPoint(x: CGFloat(cols - 11) * Self.cell, y: CGFloat(moonRow) * Self.cell), px: Self.cell, palette: palette)
        AgentPixel.draw(AgentPixelSprites.sparkle, in: &ctx, at: CGPoint(x: CGFloat(cols - 18) * Self.cell, y: CGFloat(moonRow + 4) * Self.cell), px: Self.cell, palette: palette, opacity: 0.8)
    }

    private func flag(_ ctx: inout GraphicsContext, _ flag: AgentNookLook.Flag, cols: Int) {
        let color: Color = flag == .amber ? PixelPalette.rgb(1.0, 0.69, 0.13) : (flag == .green ? PixelPalette.rgb(0.30, 0.86, 0.42) : PixelPalette.rgb(0.92, 0.22, 0.20))
        let px = Self.cell, o = CGPoint.zero
        let pole = cols - 4
        AgentPixel.fill(&ctx, x: pole, y: 1, w: 1, h: 9, origin: o, px: px, Color(white: 0.78))
        let flutter = clock.frame(period: 0.6)
        for (i, w) in [5, 4, 3, 2].enumerated() { AgentPixel.fill(&ctx, x: pole - w - (i == 0 ? flutter : 0), y: 1 + i, w: w + (i == 0 ? flutter : 0), h: 1, origin: o, px: px, color) }
    }
}

/// The helpers' bunk: smaller siblings in a row on a plank, awake (bright, eyes open, a little hop) while their agent works and
/// asleep otherwise. Four are drawn, then "+N". Pixels again: an 8 x 8 helper is `mini` points wide.
struct AgentNookBunk: View {
    var tint: Color
    var drawn: Int
    var more: Int
    var awake: Bool
    var mini: CGFloat = 12
    var spacing: CGFloat = 3
    var padding: CGFloat = 4
    var clock: AgentNookClock = .still
    var kind: AgentKind = .claude
    /// Its agent's face (the helpers are its family).
    var variant = 0

    var body: some View {
        let px = mini / 8
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(0..<drawn, id: \.self) { i in
                AgentNookMini(kind: kind, awake: awake, hop: awake && clock.frame(period: 0.4, phase: Double(i) * 0.5) == 1, variant: variant)
                    .frame(width: mini, height: mini)
            }
            if more > 0 {
                RetroPixelText("+\(more)", pixel: max(1, px), color: Retro.Ink.osdWhite.opacity(0.85)).padding(.leading, 1)
            }
        }
        .padding(.horizontal, padding)
        .padding(.bottom, px * 2)
        .background(alignment: .bottom) {
            // The plank (two cells thick) and its two legs.
            VStack(spacing: 0) {
                Rectangle().fill(PixelPalette.rgb(0.55, 0.36, 0.22)).frame(height: px * 2)
                HStack {
                    Rectangle().fill(PixelPalette.rgb(0.34, 0.21, 0.14)).frame(width: px * 2, height: px)
                    Spacer(minLength: 0)
                    Rectangle().fill(PixelPalette.rgb(0.34, 0.21, 0.14)).frame(width: px * 2, height: px)
                }
                .padding(.horizontal, px * 2)
            }
        }
        .padding(.bottom, px)
    }
}

extension AgentNookBunk {
    /// The width of a bunk with `drawn` helpers and a "+N" for `more`.
    static func width(drawn: Int, more: Int, mini: CGFloat, spacing: CGFloat, padding: CGFloat) -> CGFloat {
        let label = more > 0 ? spacing + RetroPixelLayout.width("+\(more)", pixel: max(1, mini / 8)) + 1 : 0
        return CGFloat(drawn) * mini + CGFloat(max(0, drawn - 1)) * spacing + label + 2 * padding
    }
}

/// One helper: an 8 x 8 scout, eyes open while awake and shut while asleep.
struct AgentNookMini: View {
    var kind: AgentKind = .claude
    var awake: Bool
    var hop = false
    /// Its agent's face: the helper wears the same skin and a fringe of the same hair colour.
    var variant = 0

    var body: some View {
        Canvas { context, size in
            var ctx = context
            let px = max(1, (size.width / 8 * 2).rounded(.down) / 2)
            let sprite = AgentPixelSprites.familyMini(awake: awake, variant: variant)
            let face = PixelPalette.face(kind, variant: variant)
            let palette = awake ? face : face.dimmed(0.30)
            AgentPixel.draw(sprite, in: &ctx, at: CGPoint(x: 0, y: size.height - 8 * px - (hop ? px : 0)), px: px, palette: palette)
        }
        .accessibilityHidden(true)
    }
}

/// The agent's to-do list as little blocks on a shelf, filled when done, with "2/5" in pixel digits. A counter is never clipped: with
/// little room it drops blocks, then all of them and keeps the number, then (only if even the number does not fit) both.
struct AgentNookShelf: View {
    var model: AgentNookRoomModel
    var cap: Int
    var block: CGFloat = 6
    var pixel: CGFloat = 1.5
    var clock: AgentNookClock = .still
    /// The width this may use (nil: all it wants).
    var available: CGFloat?

    /// How many blocks fit beside the number in `available` points (0: the number alone), or nil when not even the number fits.
    static func blocksThatFit(total: Int, text: String, cap: Int, block: CGFloat, pixel: CGFloat, available: CGFloat?) -> Int? {
        let number = RetroPixelLayout.width(text, pixel: pixel)
        guard let available else { return min(total, cap) }
        guard number <= available + 0.01 else { return nil }
        let n = min(total, cap)
        let room = Int(((available - number - 5 + 2) / (block + 2)).rounded(.down))
        return room >= 2 ? min(n, room) : 0
    }

    var body: some View {
        let text = model.progressText ?? ""
        let fit = Self.blocksThatFit(total: model.todoTotal, text: text, cap: cap, block: block, pixel: pixel, available: available)
        let tint = model.kind.tint
        let white = Color.white
        if let fit {
            HStack(alignment: .bottom, spacing: 5) {
                if fit > 0 {
                    let blocks = model.blocks(cap: fit)
                    VStack(spacing: 0) {
                        HStack(spacing: 2) {
                            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                                Rectangle().fill(color(b, tint))
                                    .overlay(Rectangle().strokeBorder(border(b, tint), lineWidth: max(1, block / 6)))
                                    .overlay(alignment: .topLeading) { if b == .done { Rectangle().fill(white.opacity(0.55)).frame(width: block / 3, height: block / 3).padding(block / 6) } }
                                    .frame(width: block, height: block)
                            }
                        }
                        Rectangle().fill(PixelPalette.rgb(0.55, 0.36, 0.22)).frame(height: 2).padding(.top, 0.5)
                    }
                    .fixedSize()
                }
                if !text.isEmpty {
                    RetroPixelText(text, pixel: pixel, color: Retro.Ink.osdWhite.opacity(0.88)).padding(.bottom, -0.5)
                }
            }
            .fixedSize()
        }
    }

    private func color(_ b: AgentNookBlock, _ tint: Color) -> Color {
        switch b {
        case .done: tint
        case .current: tint.opacity(0.30 + 0.25 * clock.pulse(period: 2, still: 1))
        case .todo: .white.opacity(0.14)
        }
    }

    private func border(_ b: AgentNookBlock, _ tint: Color) -> Color {
        switch b {
        case .done: Retro.shade(tint, -0.6)
        case .current: tint
        case .todo: .white.opacity(0.35)
        }
    }
}

/// One room: the light, the name plate (pixel capitals), the scout in its pose, the helpers' bunk, the to-do counter and (where there is
/// room) the first sentence of the latest message in the system font. Hovering may only brighten its edge; clicking is the panel's business.
/// `reserveRow` says some room of the screen has helpers or a counter, so every scout of the screen gets the same pixel size.
struct AgentNookRoom: View {
    var model: AgentNookRoomModel
    var style: AgentNookLayout.Style = .roomy
    var clock: AgentNookClock = .still
    /// The room glows for a moment: something happened to this agent.
    var glow = false
    var hover = false
    var reserveRow: Bool?
    /// Some room of the screen has helpers (a very wide room keeps the row for them under its scout then).
    var reserveHelpers: Bool?
    /// Its agent's own skin (`AgentFaceArt.variants`).
    var variant = 0
    /// On the TV the rooms share ONE wall drawn behind them all, up to the TV's border, and have no frame of their own
    var shared = false

    private var look: AgentNookLook { model.look }
    private var tint: Color { look == .needsYou ? AgentNookInk.amber : NotchInk.secondary }

    var body: some View {
        GeometryReader { geo in
            let m = AgentNookRoomRows.metrics(style)
            let rows = AgentNookRoomRows.plan(helpers: model.helpers, todos: model.todoTotal, style: style, size: geo.size, needsRow: reserveRow, screenHelpers: reserveHelpers)
            let inner = geo.size.width - 2 * m.pad
            // Where the name plate ends: the hanging lamp gives way to a long name, and the moon moves under it.
            let label = plateLabel(width: geo.size.width)
            let plateEnd = m.pad + RetroPixelLayout.width(label.name, pixel: label.pixel) + 6 * label.pixel + 2
            let moonRow = plateEnd <= AgentNookWall.moonLeft(width: geo.size.width) ? 3 : Int(((m.pad + m.plate) / AgentNookWall.cell).rounded(.up)) + 2
            ZStack(alignment: .topLeading) {
                if !shared {
                    AgentNookWall(look: look, style: style, clock: clock, showLamp: plateEnd <= AgentNookWall.lampLeft(width: geo.size.width), moonRow: moonRow)
                }
                VStack(alignment: .leading, spacing: m.gap) {
                    // On the TV the name plate stands UNDER the agent's desk.
                    if !shared {
                        plate(width: geo.size.width)
                            .frame(height: m.plate, alignment: .leading)
                    }
                    if rows.side {
                        // The helpers stand under the scout (in its own column); the column at the right keeps the sentence and the counter.
                        HStack(alignment: .bottom, spacing: 8) {
                            figure(rows, width: inner - AgentNookRoomRows.sideColumn - 8)
                            VStack(alignment: .leading, spacing: 5) {
                                Spacer(minLength: 0)
                                sentence(lines: 3)
                                if rows.shelf { shelf(available: AgentNookRoomRows.sideColumn, tight: false) }
                            }
                            .frame(width: AgentNookRoomRows.sideColumn, alignment: .leading)
                        }
                        if shared {
                            plate(width: geo.size.width).frame(height: m.plate).frame(maxWidth: .infinity, alignment: .center)
                        }
                    } else {
                        figure(rows, width: inner)
                        if shared {
                            plate(width: geo.size.width).frame(height: m.plate).frame(maxWidth: .infinity, alignment: .center)
                        }
                        if rows.shelf, !rows.combined { shelf(available: inner, tight: rows.tight).frame(maxWidth: .infinity, alignment: .leading) }
                        if rows.sentence { sentence(lines: 1).frame(height: m.sentence, alignment: .leading) }
                    }
                }
                .padding(m.pad)
            }
            .overlay { if !shared { AgentNookFrame(color: edge, thick: 1, glow: glow).allowsHitTesting(false) } }
        }
        .clipShape(Rectangle())
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityText)
    }

    private var edge: Color {
        let base: Color
        switch look {
        case .working: base = Color(white: 0.30)
        case .needsYou: base = AgentNookInk.amber
        case .finished: base = PixelPalette.rgb(0.30, 0.86, 0.42).opacity(0.75)
        case .stopped: base = PixelPalette.rgb(0.92, 0.22, 0.20).opacity(0.8)
        case .idle: base = Color(white: 0.22)
        }
        return hover ? Retro.shade(base, 0.45) : base
    }

    private func critter(_ px: CGFloat) -> some View {
        AgentNookCritter(kind: model.kind, variant: variant, pose: look.pose, prop: model.prop, clock: clock, crop: style == .compact, pixel: px)
    }

    /// The scout and its helpers: the picture at its exact size, centred in a room `width` wide, and the helpers' row right under it,
    /// centred on the figure (`AgentNookHelperPlace`). The block stands in the middle of the space the room gives it, as the scout alone did.
    private func figure(_ rows: AgentNookRoomRows.Plan, width: CGFloat) -> some View {
        let px = rows.px
        return VStack(spacing: 0) {
            critter(px)
                .frame(width: AgentNookHelperPlace.pictureWidth(look, px: px), height: AgentNookHelperPlace.pictureHeight(look, px: px))
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(x: AgentNookHelperPlace.pictureLeft(look, px: px, inner: width))
            if rows.bunk { helperRow(rows, width: width, px: px) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The helpers' bunk under the scout (and, in a room that shares the row, the counter beside it, on the side with more room).
    private func helperRow(_ rows: AgentNookRoomRows.Plan, width: CGFloat, px: CGFloat) -> AnyView {
        let z = bunkSizes(tight: rows.tight)
        let limit = rows.combined ? width * 0.62 : width
        let slots = bunkSlots(width: limit, tight: rows.tight)
        let bunkWide = bunkWidth(slots, tight: rows.tight)
        let helpersWide = CGFloat(slots.drawn) * z.mini + CGFloat(max(0, slots.drawn - 1)) * z.spacing
        let left = AgentNookHelperPlace.bunkLeft(look, px: px, inner: width, padding: z.padding, helpersWidth: helpersWide, bunkWidth: bunkWide)
        let up = AgentNookHelperPlace.overlap(look, px: px, awake: model.helpersAwake, hop: z.mini / 8)
        let room = (left: left - 6, right: width - left - bunkWide - 6)
        let counterLeft = !counterFits(available: room.right, tight: rows.tight) && room.left > room.right   // the right, unless not even the number fits there
        let bunkView = bunk(width: limit, tight: rows.tight).padding(.leading, left)
        if rows.combined {
            // The counter stays in the row under the picture; only the helpers reach up over the furniture.
            return AnyView(ZStack(alignment: .bottomLeading) {
                bunkView.offset(y: -up)
                shelf(available: max(0, counterLeft ? room.left : room.right), tight: rows.tight)
                    .frame(maxWidth: .infinity, alignment: counterLeft ? .leading : .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .leading))
        }
        return AnyView(bunkView.frame(maxWidth: .infinity, alignment: .leading).padding(.top, -up))
    }

    private func sentence(lines: Int) -> some View {
        Text(model.sentence).font(.system(size: 9.2)).foregroundStyle(tint)
            .lineLimit(lines).truncationMode(.tail).fixedSize(horizontal: false, vertical: lines > 1)
    }

    /// The name plate: the project in pixel capitals on a dark plate with a one-pixel edge in the kind's colour.
    private func plate(width: CGFloat) -> some View {
        let label = plateLabel(width: width)
        let pixel = label.pixel
        return RetroPixelText(label.name, pixel: pixel, color: Retro.Ink.osdWhite.opacity(look == .idle ? 0.75 : 1))
            .padding(.horizontal, 3 * pixel).padding(.vertical, 2 * pixel)
            .background(Rectangle().fill(Color.black.opacity(0.55)))
            .overlay(Rectangle().strokeBorder(model.kind.tint.opacity(look == .idle ? 0.55 : 0.95), lineWidth: max(1, pixel * 0.7)))
            .fixedSize()
    }

    /// The name on the plate, cut to fit a room this wide, and its pixel size.
    private func plateLabel(width: CGFloat) -> (name: String, pixel: CGFloat) {
        let roomy = style == .roomy
        let pixel: CGFloat = roomy ? 1.5 : 1
        let limit = max(24, (roomy ? width * 0.74 : width - 12) - 8 * pixel)
        return (AgentNookRoom.fit(model.project, pixel: pixel, width: limit), pixel)
    }

    /// The project name cut to fit `width` points of pixel text; a cut name ends in a dot.
    static func fit(_ name: String, pixel: CGFloat, width: CGFloat) -> String {
        var text = name.uppercased()
        guard RetroPixelLayout.width(text, pixel: pixel) > width else { return text }
        while text.count > 1 {
            text.removeLast()
            let cut = text + "."
            if RetroPixelLayout.width(cut, pixel: pixel) <= width { return cut }
        }
        return text
    }

    // MARK: Helpers and counter

    private struct BunkSizes { var mini: CGFloat, spacing: CGFloat, padding: CGFloat, label: CGFloat }

    private func bunkSizes(tight: Bool) -> BunkSizes {
        let big = style == .roomy && !tight
        return BunkSizes(mini: big ? 12 : 8, spacing: big ? 3 : 2.5, padding: big ? 4 : 2, label: big ? 14 : 11)
    }

    private func bunkSlots(width: CGFloat, tight: Bool) -> (drawn: Int, more: Int) {
        let z = bunkSizes(tight: tight)
        return model.helperSlots(available: width - 2 * z.padding, mini: z.mini, spacing: z.spacing, label: z.label)
    }

    private func bunkWidth(_ slots: (drawn: Int, more: Int), tight: Bool) -> CGFloat {
        let z = bunkSizes(tight: tight)
        return AgentNookBunk.width(drawn: slots.drawn, more: slots.more, mini: z.mini, spacing: z.spacing, padding: z.padding)
    }

    /// Four helpers when they fit; fewer in a narrow room, so the "+N" is never cut off.
    private func bunk(width: CGFloat, tight: Bool) -> some View {
        let z = bunkSizes(tight: tight)
        let slots = bunkSlots(width: width, tight: tight)
        return AgentNookBunk(tint: model.kind.tint, drawn: slots.drawn, more: slots.more, awake: model.helpersAwake, mini: z.mini, spacing: z.spacing,
                             padding: z.padding, clock: clock, kind: model.kind, variant: variant)
    }

    /// True when the counter (at least its number) fits in `available` points.
    private func counterFits(available: CGFloat, tight: Bool) -> Bool {
        let roomy = style == .roomy && !tight
        return AgentNookShelf.blocksThatFit(total: model.todoTotal, text: model.progressText ?? "", cap: roomy ? 8 : 5, block: roomy ? 6 : 5, pixel: roomy ? 1.5 : 1, available: max(0, available)) != nil
    }

    private func shelf(available: CGFloat, tight: Bool) -> some View {
        let roomy = style == .roomy && !tight
        return AgentNookShelf(model: model, cap: roomy ? 8 : 5, block: roomy ? 6 : 5, pixel: roomy ? 1.5 : 1, clock: clock, available: available)
    }
}

/// The edge of a room: a frame of whole cells in `color` with the four corner cells cut away (the stepped corner of a pixel box);
/// a glowing room gets a white double frame.
struct AgentNookFrame: View {
    var color: Color
    var thick: Int = 1
    var glow = false

    var body: some View {
        Canvas { context, size in
            var ctx = context
            let c = AgentNookWall.cell
            let cols = Int((size.width / c).rounded(.up)), rows = Int((size.height / c).rounded(.up))
            guard cols > 4, rows > 4 else { return }
            let o = CGPoint.zero
            func frame(_ t: Int, inset: Int, _ color: Color) {
                AgentPixel.fill(&ctx, x: inset, y: inset, w: cols - 2 * inset, h: t, origin: o, px: c, color)
                AgentPixel.fill(&ctx, x: inset, y: rows - inset - t, w: cols - 2 * inset, h: t, origin: o, px: c, color)
                AgentPixel.fill(&ctx, x: inset, y: inset, w: t, h: rows - 2 * inset, origin: o, px: c, color)
                AgentPixel.fill(&ctx, x: cols - inset - t, y: inset, w: t, h: rows - 2 * inset, origin: o, px: c, color)
            }
            frame(thick, inset: 0, color)
            if glow {
                frame(2, inset: 0, Color.white.opacity(0.95))
                frame(1, inset: 2, Color.white.opacity(0.55))
            }
            // The corner cells are cut away: the glass behind the rooms is black.
            for (x, y) in [(0, 0), (cols - 1, 0), (0, rows - 1), (cols - 1, rows - 1)] {
                AgentPixel.fill(&ctx, x: x, y: y, w: 1, h: 1, origin: o, px: c, Color.black)
            }
        }
    }
}
