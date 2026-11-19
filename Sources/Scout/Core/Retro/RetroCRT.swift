import SwiftUI

// CRT glass and the TV set. The glass has bulged edges, faint scanlines, a soft vignette and a corner reflection. Nothing moves.

/// The outline of CRT glass: a rounded rectangle whose straight edges bow outward a little, so the corners sit slightly in.
struct CRTGlassShape: Shape {
    var cornerRadius: CGFloat = 12

    /// How far the corners sit in from the frame, in points (the edges' middles touch the frame).
    static func bulge(for size: CGSize) -> CGFloat { min(2.6, max(0.6, min(size.width, size.height) * 0.011)) }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        guard w > 8, h > 8 else { return Path(rect) }
        let b = Self.bulge(for: rect.size)
        let r = min(max(cornerRadius, b + 2), min(w, h) / 2)
        let x0 = rect.minX, y0 = rect.minY, x1 = rect.maxX, y1 = rect.maxY
        var p = Path()
        p.move(to: CGPoint(x: x0 + r, y: y0 + b))
        p.addQuadCurve(to: CGPoint(x: x1 - r, y: y0 + b), control: CGPoint(x: x0 + w / 2, y: y0 - b))
        p.addQuadCurve(to: CGPoint(x: x1 - b, y: y0 + r), control: CGPoint(x: x1 - b, y: y0 + b))
        p.addQuadCurve(to: CGPoint(x: x1 - b, y: y1 - r), control: CGPoint(x: x1 + b, y: y0 + h / 2))
        p.addQuadCurve(to: CGPoint(x: x1 - r, y: y1 - b), control: CGPoint(x: x1 - b, y: y1 - b))
        p.addQuadCurve(to: CGPoint(x: x0 + r, y: y1 - b), control: CGPoint(x: x0 + w / 2, y: y1 + b))
        p.addQuadCurve(to: CGPoint(x: x0 + b, y: y1 - r), control: CGPoint(x: x0 + b, y: y1 - b))
        p.addQuadCurve(to: CGPoint(x: x0 + b, y: y0 + r), control: CGPoint(x: x0 - b, y: y0 + h / 2))
        p.addQuadCurve(to: CGPoint(x: x0 + r, y: y0 + b), control: CGPoint(x: x0 + b, y: y0 + b))
        p.closeSubpath()
        return p
    }
}

extension View {
    /// CRT glass over this view: it draws on a black screen, clipped to a gently bulged rounded rectangle, with faint scanlines
    /// (`scanlines`, 0 to about 0.3, over the content but light enough to keep small text crisp), a soft vignette (`vignette`, 0 to 1)
    /// and a corner reflection. A `tint` makes it a one-colour phosphor screen (green, amber…). Nothing moves.
    func crtScreen(cornerRadius: CGFloat = 12, scanlines: Double = 0.10, tint: Color? = nil, vignette: Double = 0.35) -> some View {
        modifier(CRTScreenModifier(cornerRadius: cornerRadius, scanlines: scanlines, tint: tint, vignette: vignette, lit: true))
    }
}

struct CRTScreenModifier: ViewModifier {
    let cornerRadius: CGFloat
    let scanlines: Double
    let tint: Color?
    let vignette: Double
    /// False draws a switched-off tube: dark glass and its reflection, no picture.
    let lit: Bool
    /// True: the light preset's glass, a pale tube with a soft rim and vignette instead of black (only the Agent TV asks for it; every other
    /// screen stays a dark glass whatever the preset).
    var paper = false

    func body(content: Content) -> some View {
        if Retro.is8bit { glass(content.lookScreen()) } else { plain(content.lookScreen()) }   // glass is dark inside the light preset too
    }

    /// The minimal look: a plain dark rounded rectangle with a hairline (no scanlines, no bulge, no reflection, no phosphor).
    private func plain<V: View>(_ content: V) -> some View {
        content
            .background(paper ? CRTDrawing.paperGlass : Color(white: lit ? 0.055 : 0.03))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Retro.hairline, lineWidth: 0.5).allowsHitTesting(false))
    }

    private func glass<V: View>(_ content: V) -> some View {
        Group {
            if let tint { content.colorMultiply(tint) } else { content }
        }
        .background(Canvas { ctx, size in
            CRTDrawing.drawTube(&ctx, size: size, tint: tint, lit: lit, paper: paper)
        })
        .overlay(Canvas { ctx, size in
            CRTDrawing.drawGlass(&ctx, size: size, cornerRadius: cornerRadius, scanlines: scanlines, vignette: vignette, lit: lit, paper: paper)
        }.allowsHitTesting(false))
        .clipShape(CRTGlassShape(cornerRadius: cornerRadius))
    }
}

enum CRTDrawing {
    /// The light preset's tube: a pale warm-grey glass (the Agent TV; `paper: true`).
    static let paperGlass = Color(red: 0.868, green: 0.876, blue: 0.852)
    /// The ink of words and lines drawn on that pale glass and on the pale set (a warm near-black).
    static let paperInk = Color(red: 0.16, green: 0.155, blue: 0.14)
    /// The mask around the glass on the light preset: a shade deeper than the other wells, so its edge reads on all four sides (a sunken
    /// bevel's lit bottom-right edge vanishes on the paper otherwise, and the set's border would look uneven).
    static var paperMask: Color { Retro.shade(Look.wellPaper, -0.10) }

    /// Under the picture: a black screen with a faint glow in the middle (the tube is lit even where the picture is black); with `paper`, a pale
    /// glass with a soft white glow.
    static func drawTube(_ ctx: inout GraphicsContext, size: CGSize, tint: Color?, lit: Bool, paper: Bool = false) {
        guard size.width > 0, size.height > 0 else { return }
        let rect = CGRect(origin: .zero, size: size)
        ctx.fill(Path(rect), with: .color(paper ? paperGlass : Retro.Ink.screenBlack))
        let glow = paper ? Color.white.opacity(0.45)
            : lit ? (tint ?? Color(red: 0.55, green: 0.65, blue: 0.62)).opacity(tint == nil ? 0.07 : 0.14) : Color(red: 0.55, green: 0.62, blue: 0.62).opacity(0.05)
        var c = ctx
        c.translateBy(x: size.width / 2, y: size.height / 2)
        c.scaleBy(x: size.width / 2, y: size.height / 2)
        c.fill(Path(CGRect(x: -1.5, y: -1.5, width: 3, height: 3)),
               with: .radialGradient(Gradient(colors: [glow, glow.opacity(0)]), center: .zero, startRadius: 0, endRadius: 1.1))
    }

    /// Over the picture: scanlines, vignette, a dark rim where the glass dips into the frame, and the reflection.
    static func drawGlass(_ ctx: inout GraphicsContext, size: CGSize, cornerRadius: CGFloat, scanlines: Double, vignette: Double, lit: Bool, paper: Bool = false) {
        guard size.width > 8, size.height > 8 else { return }
        let rect = CGRect(origin: .zero, size: size)
        let shape = CRTGlassShape(cornerRadius: cornerRadius).path(in: rect)

        // Scanlines: thin dark rows, one device-pixel aligned row pair every 2 points (3 on big screens).
        if lit, scanlines > 0.001 {
            let pitch: CGFloat = size.height > 260 ? 3 : 2
            var rows = Path()
            var y: CGFloat = 0
            while y < size.height {
                let top = ctx.snapped(y)
                rows.addRect(CGRect(x: 0, y: top, width: size.width, height: max(1 / max(1, ctx.environment.displayScale), ctx.snapped(y + pitch / 2) - top)))
                y += pitch
            }
            ctx.fill(rows, with: .color(Color.black.opacity(min(0.6, scanlines))))
        }

        // Vignette: an ellipse that is clear in the middle and dark in the corners.
        if vignette > 0.001 {
            var c = ctx
            c.translateBy(x: size.width / 2, y: size.height / 2)
            c.scaleBy(x: size.width / 2, y: size.height / 2)
            let dark = paper ? Color(red: 0.62, green: 0.57, blue: 0.48).opacity(min(0.95, vignette * 0.8)) : Color.black.opacity(min(0.95, vignette))   // paper: a soft warm shade, not black
            c.fill(Path(CGRect(x: -1.6, y: -1.6, width: 3.2, height: 3.2)),
                   with: .radialGradient(Gradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.52),
                                                          .init(color: dark.opacity(0.45), location: 0.80), .init(color: dark, location: 1)]),
                                         center: .zero, startRadius: 0, endRadius: 1.42))
        }

        // The rim: the glass curves away at its edge, so the last few points are darker.
        var rim = ctx
        rim.clip(to: shape)
        let rimShade = paper ? Color(red: 0.30, green: 0.26, blue: 0.20) : Color.black
        rim.stroke(shape, with: .color(rimShade.opacity(paper ? 0.10 : 0.28)), lineWidth: 9)
        rim.stroke(shape, with: .color(rimShade.opacity(paper ? 0.16 : 0.35)), lineWidth: 3)

        // The reflection: a soft sheen in the top-left.
        let u = min(size.width, size.height)
        var glare = ctx
        glare.clip(to: shape)
        var sheen = glare
        sheen.translateBy(x: u * 0.30, y: u * 0.10)
        sheen.scaleBy(x: size.width * 0.50, y: u * 0.42)
        sheen.fill(Path(CGRect(x: -1, y: -1, width: 2, height: 2)), with: .radialGradient(
            Gradient(colors: [Color.white.opacity(lit ? 0.09 : 0.16), Color.white.opacity(0)]), center: .zero, startRadius: 0, endRadius: 1))
    }
}

// MARK: - Static

/// "No signal" static: a STILL texture (it never flickers, never moves; a caller may fade it in). `seed` picks the picture,
/// `strength` (0 to 1) how bright the snow is. Fills its frame; put it in a `crtScreen` for the glass.
struct CRTNoise: View {
    let seed: Int
    let strength: Double

    init(seed: Int = 1, strength: Double = 0.5) {
        self.seed = seed
        self.strength = strength
    }

    var body: some View {
        Canvas { ctx, size in
            guard size.width > 1, size.height > 1 else { return }
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.03, green: 0.035, blue: 0.04)))
            var dice = Retro.Dice(seed: seed)
            // Grains are a little wider than tall, like analogue snow; big screens get bigger grains so the cost stays flat.
            var cw: CGFloat = 2.2, ch: CGFloat = 1.8
            let cells = (size.width / cw) * (size.height / ch)
            if cells > 26000 { let k = sqrt(cells / 26000); cw *= k; ch *= k }
            let cols = Int((size.width / cw).rounded(.up)), rows = Int((size.height / ch).rounded(.up))
            let levels = 6
            var paths = [Path](repeating: Path(), count: levels)
            let gain = 0.35 + 0.65 * min(1, max(0, strength))
            for r in 0..<rows {
                for c in 0..<cols {
                    let v = pow(dice.next(), 1.7) * gain
                    let level = Int(v * Double(levels))
                    if level >= 1 { paths[min(levels - 1, level)].addRect(CGRect(x: CGFloat(c) * cw, y: CGFloat(r) * ch, width: cw, height: ch)) }
                }
            }
            for level in 1..<levels {
                let g = 0.10 + 0.82 * Double(level) / Double(levels - 1)
                ctx.fill(paths[level], with: .color(Color(red: g * 0.94, green: g * 0.98, blue: g)))
            }
            // A few soft interference bands across the picture.
            for _ in 0..<3 {
                let y = dice.range(0, Double(size.height)), hgt = dice.range(4, 14) * (size.height > 200 ? 1.8 : 1)
                let light = dice.next() > 0.45
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: hgt)),
                         with: .color((light ? Color.white : Color.black).opacity(light ? 0.05 + 0.06 * strength : 0.16)))
            }
        }
    }
}

/// A switched-off tube with words faintly on its glass, soft and fading across it, like the room reflected in the glass.
/// The glass's own shine is drawn over it.
struct CRTReflection: View {
    let text: String?
    /// True: the words are dark on the pale glass of the light preset instead of white on black.
    var paper = false
    static let strength = 0.2

    var body: some View {
        GeometryReader { geo in
            if let text, !text.isEmpty {
                let columns = CGFloat(max(1, RetroPixelLayout.columns(text).count))
                let pixel = max(1.5, min(3.5, (geo.size.width * 0.6) / columns))
                RetroPixelText(text, pixel: pixel, color: paper ? CRTDrawing.paperInk : .white)
                    .blur(radius: pixel * 0.3)
                    .opacity(paper ? Self.strength * 1.5 : Self.strength)
                    .mask(LinearGradient(colors: [Color.white, Color.white.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: geo.size.width, height: geo.size.height)
                    .accessibilityLabel(text)
            }
        }
    }
}

// MARK: - The TV set

/// The geometry of a TV set in a frame, as plain numbers.
struct CRTSetLayout: Equatable {
    /// The glass's corner: big and round like the open notch's own corners, so the set sits in the island's bottom corner as if made for it
    static func glassRadius(compact: Bool) -> CGFloat { compact ? 14 : 20 }

    enum Strip { case side, bottom }
    var strip: Strip
    var bezel: CGFloat
    /// The black mask around the glass.
    var well: CGRect
    /// The glass itself.
    var screen: CGRect
    /// The strip with the knobs, the speaker grille and the lights.
    var stripRect: CGRect
    /// 1 for a dashboard-size set; big sets scale their knobs, badge and lamp up (in half steps, at most 2.5).
    var scale: CGFloat

    static let maskThickness: CGFloat = 3

    /// `extendLeft`: the glass (its black rim and the screen) reaches this much further left than the set's frame; the strip with the knobs
    /// stays where it is
    init(size: CGSize, compact: Bool, extendLeft: CGFloat = 0) {
        let w = size.width, h = size.height
        bezel = compact ? 4 : 6
        scale = max(1, min(2.5, (h / 150 * 2).rounded() / 2))
        let mask = Self.maskThickness
        if w / max(1, h) >= 0.9 {   // the knobs stay at the side on every dashboard size
            strip = .side
            let length = compact ? min(34, max(22, w * 0.13)) : min(84, max(34, w * 0.20))
            well = CGRect(x: bezel - extendLeft, y: bezel, width: w - 2 * bezel - length - 3 + extendLeft, height: h - 2 * bezel)
            stripRect = CGRect(x: w - bezel - length, y: bezel, width: length, height: h - 2 * bezel)
        } else {
            strip = .bottom
            let length: CGFloat = compact ? 15 : 22
            well = CGRect(x: bezel - extendLeft, y: bezel, width: w - 2 * bezel + extendLeft, height: h - 2 * bezel - length - 3)
            stripRect = CGRect(x: bezel, y: h - bezel - length, width: w - 2 * bezel, height: length)
        }
        screen = well.insetBy(dx: mask, dy: mask)
    }
}

/// A TV's plastic body around a CRT screen: a strip with knobs and a speaker grille, a red power light, a small pixel badge, and with
/// `onAir` an ON AIR lamp. `compact` is the small version (thin bezel, fewer parts); `powerOn: false` is a dark tube and a dim light.
/// It fills the frame it is given (150 x 140 works; at least about as wide as tall puts the strip at the side, otherwise
/// at the bottom). Extras: `plastic` is the body colour, `tint` makes the screen a one-colour phosphor.
struct CRTSet<Screen: View>: View {
    let badge: String
    let compact: Bool
    let powerOn: Bool
    let onAir: Bool
    let plastic: Color
    let tint: Color?
    /// Words faintly on the glass while the set is off, like the room reflected in it.
    let reflection: String?
    let screen: Screen

    init(badge: String = "", compact: Bool = false, powerOn: Bool = true, onAir: Bool = false,
         plastic: Color = Retro.Ink.plasticDark, tint: Color? = nil, reflection: String? = nil, @ViewBuilder screen: () -> Screen) {
        self.reflection = reflection
        self.badge = badge
        self.compact = compact
        self.powerOn = powerOn
        self.onAir = onAir
        self.plastic = plastic
        self.tint = tint
        self.screen = screen()
    }

    /// How much further left the glass reaches than the frame (the Agent TV toward the island's corner).
    @Environment(\.crtGlassExtendLeft) private var extendLeft

    var body: some View {
        if Retro.is8bit { setBody } else { plainBody }
    }

    /// The minimal look: no plastic body, knobs or lights; just the screen's content on a plain dark rounded rectangle.
    private var plainBody: some View {
        Group {
            if powerOn { screen.clipped() } else { CRTReflection(text: reflection, paper: Look.isLight) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(CRTScreenModifier(cornerRadius: CRTSetLayout.glassRadius(compact: compact), scanlines: 0, tint: nil, vignette: 0, lit: powerOn, paper: Look.isLight))
    }

    private var setBody: some View {
        GeometryReader { geo in
            let layout = CRTSetLayout(size: geo.size, compact: compact, extendLeft: extendLeft)
            let glassRadius = CRTSetLayout.glassRadius(compact: compact)
            ZStack(alignment: .topLeading) {
                // No plastic body around the set: the screen and its knobs stand on the dashboard's one surface
                Color.clear
                    .frame(width: layout.well.width, height: layout.well.height)
                    .retroBevel(.sunken, cornerRadius: glassRadius + CRTSetLayout.maskThickness, depth: 1.5, face: Look.isLight ? CRTDrawing.paperMask : Color(red: 0.03, green: 0.03, blue: 0.035))   // the mask: black in the dark preset, a light well in the light one
                    .offset(x: layout.well.minX, y: layout.well.minY)
                Group {
                    if powerOn {
                        screen
                            .frame(width: layout.screen.width, height: layout.screen.height)
                            .clipped()
                            .modifier(CRTScreenModifier(cornerRadius: glassRadius, scanlines: 0.10, tint: tint, vignette: 0.35, lit: true, paper: Look.isLight))
                    } else {
                        CRTReflection(text: reflection, paper: Look.isLight)
                            .frame(width: layout.screen.width, height: layout.screen.height)
                            .modifier(CRTScreenModifier(cornerRadius: glassRadius, scanlines: 0, tint: nil, vignette: 0.45, lit: false, paper: Look.isLight))
                    }
                }
                .offset(x: layout.screen.minX, y: layout.screen.minY)
                CRTStrip(layout: layout, badge: badge, compact: compact, powerOn: powerOn, onAir: onAir, plastic: plastic)
                    .frame(width: layout.stripRect.width, height: layout.stripRect.height)
                    .offset(x: layout.stripRect.minX, y: layout.stripRect.minY)
            }
        }
    }
}

/// The strip of a set. Parts drop out, least important first, when the strip is small (`ViewThatFits`).
private struct CRTStrip: View {
    let layout: CRTSetLayout
    let badge: String
    let compact: Bool
    let powerOn: Bool
    let onAir: Bool
    let plastic: Color

    private var knobFace: Color { Retro.isLight(plastic) ? Color(red: 0.24, green: 0.24, blue: 0.26) : Color(red: 0.62, green: 0.62, blue: 0.60) }
    private var inkColor: Color { Retro.isLight(plastic) || Look.isLight ? CRTDrawing.paperInk : Color(red: 0.74, green: 0.74, blue: 0.70) }   // dark lettering on the light preset's paper

    var body: some View {
        if layout.strip == .side {
            let w = layout.stripRect.width
            let knob = min((compact ? 15 : 20) * layout.scale, w * 0.52)
            if compact {
                ViewThatFits(in: .vertical) {
                    column(width: w, knob: knob, knobs: 1, badge: false, slits: 3, dimLamp: false)
                    column(width: w, knob: knob * 0.8, knobs: 1, badge: false, slits: 0, dimLamp: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ViewThatFits(in: .vertical) {
                    column(width: w, knob: knob, knobs: 2, badge: true, slits: 5, dimLamp: true)
                    column(width: w, knob: knob, knobs: 2, badge: true, slits: 4, dimLamp: false)
                    column(width: w, knob: knob, knobs: 1, badge: false, slits: 3, dimLamp: false)
                    column(width: w, knob: knob * 0.8, knobs: 1, badge: false, slits: 0, dimLamp: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            let h = layout.stripRect.height
            let knob = min((compact ? 11 : 15) * layout.scale, h - 4)
            if compact {
                ViewThatFits(in: .horizontal) {
                    row(height: h, knob: knob, knobs: 1, badge: false, slits: 3)
                    row(height: h, knob: knob, knobs: 0, badge: false, slits: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ViewThatFits(in: .horizontal) {
                    row(height: h, knob: knob, knobs: 2, badge: true, slits: 5)
                    row(height: h, knob: knob, knobs: 2, badge: false, slits: 4)
                    row(height: h, knob: knob, knobs: 1, badge: false, slits: 3)
                    row(height: h, knob: knob, knobs: 0, badge: false, slits: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func column(width: CGFloat, knob: CGFloat, knobs: Int, badge showBadge: Bool, slits: Int, dimLamp: Bool) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 3)
            ForEach(0..<knobs, id: \.self) { i in
                CRTKnob(diameter: knob, angle: i == 0 ? -35 : 50, face: knobFace).padding(.bottom, i == knobs - 1 ? 0 : 4)
            }
            Spacer(minLength: 3)
            if slits > 0 { CRTGrille(slits: slits, plastic: plastic).frame(width: max(8, width - 10)) }
            Spacer(minLength: 3)
            // No ON AIR lamp: the set's name stands where it was.
            if showBadge, !badge.isEmpty { badgeView(maxWidth: width - 4, pixel: layout.scale.rounded(.down)) }
            Spacer(minLength: 3)
            CRTPowerLight(on: powerOn)
        }
        .frame(width: width)
        .padding(.vertical, 2)
    }

    private func row(height: CGFloat, knob: CGFloat, knobs: Int, badge showBadge: Bool, slits: Int) -> some View {
        HStack(spacing: 5) {
            CRTPowerLight(on: powerOn)
            if showBadge, !badge.isEmpty { badgeView(maxWidth: 80 * layout.scale, pixel: layout.scale.rounded(.down)) }
            Spacer(minLength: 2)
            ForEach(0..<knobs, id: \.self) { i in CRTKnob(diameter: knob, angle: i == 0 ? -35 : 50, face: knobFace) }
            if slits > 0 { CRTGrille(slits: slits, plastic: plastic).frame(width: compact ? 18 : 24, height: max(6, height - 7)) }
        }
        .padding(.horizontal, 4)
        .frame(height: height)
        .fixedSize(horizontal: true, vertical: false)
    }

    /// The badge in pixel capitals; a name of several words that is too wide for one line breaks at its first space.
    @ViewBuilder private func badgeView(maxWidth: CGFloat, pixel: CGFloat) -> some View {
        let one = RetroPixelLayout.width(badge, pixel: pixel)
        if one <= maxWidth {
            RetroPixelText(badge, pixel: pixel, color: inkColor)
        } else if let space = badge.firstIndex(of: " ") {
            let a = String(badge[..<space]), b = String(badge[badge.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            VStack(spacing: 2 * pixel) {
                RetroPixelText(a, pixel: pixel, color: inkColor)
                RetroPixelText(b, pixel: pixel, color: inkColor)
            }
        }
    }
}

/// A knob: a plastic dial with a ridged edge and a pointer, set at a fixed angle (it never turns by itself).
struct CRTKnob: View {
    let diameter: CGFloat
    let angle: Double
    let face: Color

    var body: some View {
        Canvas { ctx, size in
            let d = diameter
            let center = CGPoint(x: size.width / 2, y: size.height / 2 - 0.5)
            let body = CGRect(x: center.x - d / 2 + 0.5, y: center.y - d / 2 + 0.5, width: d - 1, height: d - 1)
            // The socket shadow under the knob.
            ctx.fill(Path(ellipseIn: body.insetBy(dx: -1, dy: -1).offsetBy(dx: 0.5, dy: 1)), with: .color(Color.black.opacity(0.55)))
            ctx.fill(Path(ellipseIn: body), with: .radialGradient(
                Gradient(colors: [Retro.shade(face, 0.40), face, Retro.shade(face, -0.50)]),
                center: CGPoint(x: body.minX + d * 0.34, y: body.minY + d * 0.30), startRadius: 0, endRadius: d * 0.8))
            // Ridges around the edge.
            if d >= 13 {
                var ticks = Path()
                let n = 16
                for i in 0..<n {
                    let a = Double(i) / Double(n) * 2 * .pi
                    ticks.move(to: CGPoint(x: center.x + cos(a) * d * 0.40, y: center.y + sin(a) * d * 0.40))
                    ticks.addLine(to: CGPoint(x: center.x + cos(a) * d * 0.5, y: center.y + sin(a) * d * 0.5))
                }
                ctx.stroke(ticks, with: .color(Color.black.opacity(0.38)), lineWidth: 0.8)
            }
            // A slightly dished cap and the pointer.
            let cap = body.insetBy(dx: d * 0.17, dy: d * 0.17)
            ctx.fill(Path(ellipseIn: cap), with: .linearGradient(Gradient(colors: [Retro.shade(face, -0.28), Retro.shade(face, 0.12)]),
                                                                  startPoint: CGPoint(x: cap.minX, y: cap.minY), endPoint: CGPoint(x: cap.maxX, y: cap.maxY)))
            let a = (angle - 90) * .pi / 180
            var pointer = Path()
            pointer.move(to: CGPoint(x: center.x + cos(a) * d * 0.10, y: center.y + sin(a) * d * 0.10))
            pointer.addLine(to: CGPoint(x: center.x + cos(a) * d * 0.40, y: center.y + sin(a) * d * 0.40))
            ctx.stroke(pointer, with: .color(Retro.isLight(face) ? Color.black.opacity(0.75) : Color.white.opacity(0.88)),
                       style: StrokeStyle(lineWidth: max(1, d * 0.09), lineCap: .round))
        }
        .frame(width: diameter + 1, height: diameter + 2)
    }
}

/// A speaker grille: a sunken panel of horizontal slots.
struct CRTGrille: View {
    let slits: Int
    let plastic: Color

    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            let light = Look.isLight   // the light preset: a pale grille with dark slots, not a black one
            let back = light ? Retro.shade(Look.wellPaper, -0.04) : Retro.shade(plastic, -0.55)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(back))
            let pitch = size.height / CGFloat(max(1, slits))
            let slot = max(1, pitch * 0.42)
            for i in 0..<slits {
                let y = pitch * (CGFloat(i) + 0.5) - slot / 2
                let r = CGRect(x: 2.5, y: y, width: size.width - 5, height: slot)
                ctx.fill(Path(roundedRect: r, cornerRadius: slot / 2), with: .color(Color.black.opacity(light ? 0.45 : 0.85)))
                ctx.fill(Path(CGRect(x: r.minX + 0.5, y: r.maxY, width: r.width - 1, height: 0.7)), with: .color(Retro.shade(plastic, 0.12).opacity(0.5)))
            }
        }
        .frame(height: CGFloat(max(1, slits)) * 3.6)
    }
}

/// The red power light.
struct CRTPowerLight: View {
    let on: Bool

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            if on {
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)), with: .radialGradient(
                    Gradient(colors: [Retro.Ink.ledRed.opacity(0.40), Retro.Ink.ledRed.opacity(0)]), center: c, startRadius: 0, endRadius: 8))
            }
            let lamp = CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)
            ctx.fill(Path(ellipseIn: lamp.insetBy(dx: -1, dy: -1)), with: .color(Color.black.opacity(0.7)))
            ctx.fill(Path(ellipseIn: lamp), with: .radialGradient(
                Gradient(colors: on ? [Color(red: 1, green: 0.82, blue: 0.78), Retro.Ink.ledRed, Retro.shade(Retro.Ink.ledRed, -0.35)]
                                    : [Retro.shade(Retro.Ink.ledRed, -0.55), Retro.shade(Retro.Ink.ledRed, -0.72)]),
                center: CGPoint(x: c.x - 1, y: c.y - 1), startRadius: 0, endRadius: 4))
        }
        .frame(width: 8, height: 8)
    }
}

/// The ON AIR lamp: pixel letters on a red lens, bright when lit, dark red when not.
struct CRTAirLamp: View {
    let lit: Bool
    let stacked: Bool
    var pixel: CGFloat = 1

    var body: some View {
        let ink = lit ? Color(red: 1.0, green: 0.93, blue: 0.88) : Retro.Ink.ledRed.opacity(0.42)
        let face = lit ? Retro.Ink.ledRed : Retro.shade(Retro.Ink.ledRed, -0.80)
        Group {
            if stacked {
                VStack(spacing: pixel) {
                    RetroPixelText("ON", pixel: pixel, color: ink)
                    RetroPixelText("AIR", pixel: pixel, color: ink)
                }
                .padding(.vertical, 2.5 * pixel)
                .frame(width: 21 * pixel)
            } else {
                RetroPixelText("ON AIR", pixel: pixel, color: ink)
                    .padding(.horizontal, 3 * pixel)
                    .padding(.vertical, 2.5 * pixel)
            }
        }
        .retroBevel(.sunken, cornerRadius: 2, depth: 1, face: face)
        .background(lit ? Retro.Ink.ledRed.opacity(0.35) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .shadow(color: lit ? Retro.Ink.ledRed.opacity(0.55) : .clear, radius: 3)
    }
}

private struct CRTGlassExtendLeftKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// A CRT set's glass reaches this much further left than its frame; its knobs stay in place.
    var crtGlassExtendLeft: CGFloat {
        get { self[CRTGlassExtendLeftKey.self] }
        set { self[CRTGlassExtendLeftKey.self] = newValue }
    }
}
