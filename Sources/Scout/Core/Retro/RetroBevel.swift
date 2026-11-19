import SwiftUI

// The 90s 3D edge: light on the top and left, dark on the bottom and right; sunken is the reverse; a groove is a sunken line
// with a raised one inside (an etched line). The edges meet at the corners in a clean 45 degree miter.

/// The three edges of the 90s look.
enum RetroBevelStyle: CaseIterable {
    case raised, sunken, groove

    /// For each ring of the edge, outermost first: true when the light edge is the top-left one.
    var rings: [Bool] {
        switch self {
        case .raised: [true]
        case .sunken: [false]
        case .groove: [false, true]
        }
    }

    /// The light and dark edge colours of one ring for a face colour: `topLeft` is the light one when the ring is raised.
    func edges(face: Color) -> [RetroBevelEdges] {
        let lum = Retro.luminance(face)
        let light = Retro.shade(face, min(0.34 + 0.20 * (1 - lum), 0.12 + 2.4 * lum))   // a near-black face gets a gentler highlight
        let dark = Retro.shade(face, -(0.50 + 0.10 * lum))
        return rings.map { lightTopLeft in
            lightTopLeft ? RetroBevelEdges(topLeft: light, bottomRight: dark) : RetroBevelEdges(topLeft: dark, bottomRight: light)
        }
    }
}

/// The colours of one ring of a bevel.
struct RetroBevelEdges: Equatable {
    var topLeft: Color
    var bottomRight: Color
}

extension View {
    /// The 90s 3D edge around a plastic face: raised (light top-left), sunken (the reverse) or a groove. It fills `face` behind the
    /// view and draws the edge on top, so keep the content a point or two inside.
    func retroBevel(_ style: RetroBevelStyle = .raised, cornerRadius: CGFloat = 4, depth: CGFloat = 1.5, face: Color = Retro.Ink.plasticDark) -> some View {
        modifier(RetroBevelModifier(style: style, cornerRadius: cornerRadius, depth: depth, face: face))
    }
}

struct RetroBevelModifier: ViewModifier {
    let style: RetroBevelStyle
    let cornerRadius: CGFloat
    let depth: CGFloat
    let face: Color
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, Retro.isLight(face) ? scheme : .dark)   // a dark face (an LCD window, a dark key) keeps its light-on-dark inks in the light preset
            .background(Canvas { ctx, size in
                RetroBevelDrawing.drawFace(&ctx, size: size, style: style, cornerRadius: cornerRadius, face: face)
            })
            .overlay(Canvas { ctx, size in
                RetroBevelDrawing.drawEdges(&ctx, size: size, style: style, cornerRadius: cornerRadius, depth: depth, face: face)
            }.allowsHitTesting(false))
    }
}

/// The drawing of a bevel, shared by every kit piece that has one.
enum RetroBevelDrawing {
    /// The face: a flat plastic colour with a very slight sheen (raised catches light on top, sunken is shadowed on top).
    static func drawFace(_ ctx: inout GraphicsContext, size: CGSize, style: RetroBevelStyle, cornerRadius: CGFloat, face: Color) {
        guard size.width > 0, size.height > 0 else { return }
        let rect = CGRect(origin: .zero, size: size)
        let path = Path(roundedRect: rect, cornerRadius: min(cornerRadius, min(size.width, size.height) / 2))
        if !Retro.is8bit {   // the minimal look: one flat colour (a pressed-in face a little darker)
            ctx.fill(path, with: .color(style == .sunken ? Retro.shade(face, -0.10) : face))
            return
        }
        let top = Retro.shade(face, style == .raised ? 0.07 : -0.10)
        let bottom = Retro.shade(face, style == .raised ? -0.07 : 0.03)
        ctx.fill(path, with: .linearGradient(Gradient(colors: [top, face, bottom]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
    }

    /// The edge rings, outermost first, each `depth / rings` thick.
    static func drawEdges(_ ctx: inout GraphicsContext, size: CGSize, style: RetroBevelStyle, cornerRadius: CGFloat, depth: CGFloat, face: Color) {
        guard size.width > 1, size.height > 1, depth > 0 else { return }
        if !Retro.is8bit {   // the minimal look: a hairline around a raised shape, nothing around a pressed-in one
            guard style != .sunken else { return }
            let line = CGRect(origin: .zero, size: size).insetBy(dx: 0.25, dy: 0.25)
            ctx.stroke(Path(roundedRect: line, cornerRadius: min(cornerRadius, min(line.width, line.height) / 2)), with: .color(Retro.hairline), lineWidth: 0.5)
            return
        }
        let edges = style.edges(face: face)
        let ring = depth / CGFloat(edges.count)
        for (i, e) in edges.enumerated() {
            let inset = ring * CGFloat(i)
            let rect = CGRect(x: inset, y: inset, width: size.width - 2 * inset, height: size.height - 2 * inset)
            guard rect.width > ring * 2, rect.height > ring * 2 else { continue }
            drawRing(&ctx, rect: rect, cornerRadius: max(0, cornerRadius - inset), width: ring, topLeft: e.topLeft, bottomRight: e.bottomRight)
        }
    }

    /// One ring: the whole outline in the bottom-right colour, then the top-left half over it, cut on a 45 degree miter.
    static func drawRing(_ ctx: inout GraphicsContext, rect: CGRect, cornerRadius: CGFloat, width: CGFloat, topLeft: Color, bottomRight: Color) {
        let radius = min(cornerRadius, min(rect.width, rect.height) / 2)
        let line = rect.insetBy(dx: width / 2, dy: width / 2)
        let outline = Path(roundedRect: line, cornerRadius: max(0, radius - width / 2))
        ctx.stroke(outline, with: .color(bottomRight), lineWidth: width)
        let t = min(rect.width, rect.height) / 2
        var half = Path()
        half.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        half.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        half.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        half.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        half.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - t))
        half.closeSubpath()
        var lit = ctx
        lit.clip(to: half)
        lit.stroke(outline, with: .color(topLeft), lineWidth: width)
    }
}

// MARK: - Keys

/// A chunky plastic key: raised, sunken (and a hair lower) while pressed. `tint` is the plastic's colour, `compact` a smaller key.
struct RetroButtonStyle: ButtonStyle {
    var tint: Color = Retro.Ink.plasticMid
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        RetroKeyBody(configuration: configuration, tint: tint, compact: compact)
    }
}

private struct RetroKeyBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    let compact: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        RetroKeyFace(pressed: configuration.isPressed, tint: tint, compact: compact) { configuration.label }
            .opacity(enabled ? 1 : 0.45)
    }
}

/// The look of a key, with its state given from outside (the button style uses it; the gallery shows `pressed` with it).
struct RetroKeyFace<Label: View>: View {
    let pressed: Bool
    let tint: Color
    let compact: Bool
    @ViewBuilder var label: () -> Label

    init(pressed: Bool = false, tint: Color = Retro.Ink.plasticMid, compact: Bool = false, @ViewBuilder label: @escaping () -> Label) {
        self.pressed = pressed
        self.tint = tint
        self.compact = compact
        self.label = label
    }

    var body: some View {
        let minimal = !Retro.is8bit
        let quiet = minimal && tint == Retro.Ink.plasticMid   // the plain grey key becomes a quiet dark one with a light label
        let ink = quiet ? Color.white.opacity(0.9) : (Retro.isLight(tint) ? Color(red: 0.08, green: 0.08, blue: 0.09) : Retro.Ink.osdWhite)
        let tint = quiet ? Color(white: 0.2) : tint
        label()
            .font(.system(size: compact ? 10 : 12, weight: minimal ? .semibold : .heavy))
            .foregroundStyle(ink)
            .lineLimit(1)
            .padding(.horizontal, compact ? 7 : 11)
            .padding(.vertical, compact ? 2.5 : 5)
            .offset(y: pressed && !minimal ? 0.75 : 0)
            .retroBevel(pressed ? .sunken : .raised, cornerRadius: minimal ? (compact ? 5 : 7) : (compact ? 3 : 4), depth: compact ? 1 : 1.5, face: pressed ? Retro.shade(tint, -0.14) : tint)
            .opacity(minimal && pressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == RetroButtonStyle {
    /// A grey plastic key.
    static var retro: RetroButtonStyle { RetroButtonStyle() }
    /// A plastic key in `tint`; `compact` is the small one.
    static func retro(tint: Color, compact: Bool = false) -> RetroButtonStyle { RetroButtonStyle(tint: tint, compact: compact) }
}

// MARK: - The panel face

extension View {
    /// The standard dashboard-panel face in the 90s look: dark plastic with a slim raised edge and, with a `tint`, a coloured label
    /// stripe along the top. It paints the face behind the view and clips to it; the caller frames the size (a panel is 140 pt tall).
    func retroPanel(tint: Color? = nil) -> some View {
        modifier(RetroPanelModifier(tint: tint))
    }
}

struct RetroPanelModifier: ViewModifier {
    let tint: Color?
    static let radius: CGFloat = 10
    static let face = Color(red: 0.115, green: 0.115, blue: 0.13)

    func body(content: Content) -> some View {
        content
            .background(Canvas { ctx, size in
                guard size.width > 0, size.height > 0 else { return }
                let shape = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: Self.radius)
                if !Retro.is8bit {   // the minimal look: one flat face, no coloured stripe
                    ctx.fill(shape, with: .color(Self.face))
                    return
                }
                ctx.fill(shape, with: .linearGradient(Gradient(colors: [Retro.shade(Self.face, 0.06), Self.face, Retro.shade(Self.face, -0.30)]),
                                                      startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                if let tint {
                    var c = ctx
                    c.clip(to: shape)
                    c.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 3)), with: .color(tint))
                    c.fill(Path(CGRect(x: 0, y: 3, width: size.width, height: 22)), with: .linearGradient(
                        Gradient(colors: [tint.opacity(0.16), tint.opacity(0)]), startPoint: CGPoint(x: 0, y: 3), endPoint: CGPoint(x: 0, y: 25)))
                }
            })
            .overlay(Canvas { ctx, size in
                RetroBevelDrawing.drawEdges(&ctx, size: size, style: .raised, cornerRadius: Self.radius, depth: 1.5, face: Self.face)
            }.allowsHitTesting(false))
            .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .circular))
    }
}
