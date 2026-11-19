import SwiftUI

/// The wide set of a panel 10 cells and wider: a long console TV instead of a stretched one. The glass keeps a sensible length (at most
/// `AgentTVLayout.glassMax`); the rest of the width is a speaker each side of it (one at the left when there is little), and the control strip (badge, two knobs, grille, ON AIR
/// lamp, power light) is the kit's own parts at the right. Same inputs as the kit's `CRTSet`: the screen draws on the glass.
struct AgentTVConsole<Screen: View>: View {
    let badge: String
    let onAir: Bool
    let plastic: Color
    let screen: Screen

    init(badge: String = pixelLabel("AGENT TV"), onAir: Bool = false, plastic: Color = Retro.Ink.plasticDark, @ViewBuilder screen: () -> Screen) {
        self.badge = badge
        self.onAir = onAir
        self.plastic = plastic
        self.screen = screen()
    }

    var body: some View {
        GeometryReader { geo in
            let g = AgentTVLayout.glass(panelWidth: geo.size.width)
            let h = geo.size.height
            let bezel = AgentTVLayout.consoleBezel
            let mask = AgentTVLayout.consoleMask
            let well = g.rect.insetBy(dx: -mask, dy: -mask)
            let left = AgentTVLayout.leftSpeaker(g.speaker)
            ZStack(alignment: .topLeading) {
                Color.clear.retroBevel(.raised, cornerRadius: CRTSetLayout.glassRadius(compact: false) + bezel, depth: 1.5, face: Look.well(dark: plastic))   // round like the island's corners; the body is charcoal in the dark preset, light in the light one
                AgentTVSpeaker(plastic: plastic)
                    .frame(width: max(0, left - 3), height: h - 2 * bezel)
                    .offset(x: bezel, y: bezel)
                if g.speaker - left > 8 {
                    AgentTVSpeaker(plastic: plastic)
                        .frame(width: max(0, g.speaker - left - 3), height: h - 2 * bezel)
                        .offset(x: well.maxX + 3, y: bezel)
                }
                Color.clear
                    .frame(width: well.width, height: well.height)
                    .retroBevel(.sunken, cornerRadius: CRTSetLayout.glassRadius(compact: false) + mask, depth: 1.5, face: Look.isLight ? CRTDrawing.paperMask : Color(red: 0.03, green: 0.03, blue: 0.035))
                    .offset(x: well.minX, y: well.minY)
                screen
                    .frame(width: g.rect.width, height: g.rect.height)
                    .clipped()
                    .modifier(CRTScreenModifier(cornerRadius: CRTSetLayout.glassRadius(compact: false), scanlines: 0.10, tint: nil, vignette: 0.35, lit: true, paper: Look.isLight))
                    .offset(x: g.rect.minX, y: g.rect.minY)
                strip(width: g.strip, height: h - 2 * bezel)
                    .offset(x: geo.size.width - bezel - g.strip, y: bezel)
            }
        }
    }

    private var knobFace: Color { Color(red: 0.62, green: 0.62, blue: 0.60) }
    private var inkColor: Color { Look.isLight ? CRTDrawing.paperInk : Color(red: 0.74, green: 0.74, blue: 0.70) }

    /// The control strip: the kit's own knobs, grille and lamps, in the order the kit's side strip has them.
    private func strip(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            if !badge.isEmpty {
                VStack(spacing: 2) {
                    ForEach(badge.split(separator: " ").map(String.init), id: \.self) { RetroPixelText($0, pixel: 1, color: inkColor) }
                }
                .padding(.top, 1)
            }
            Spacer(minLength: 3)
            CRTKnob(diameter: 20, angle: -35, face: knobFace).padding(.bottom, 4)
            CRTKnob(diameter: 20, angle: 50, face: knobFace)
            Spacer(minLength: 3)
            CRTGrille(slits: 4, plastic: plastic).frame(width: max(8, width - 10))
            Spacer(minLength: 3)
            CRTAirLamp(lit: onAir, stacked: true, pixel: 1)
            Spacer(minLength: 3)
            CRTPowerLight(on: true)
        }
        .frame(width: width, height: height)
        .padding(.vertical, 2)
    }
}

/// The console's speaker: a sunken panel of fine slits with a round cone ring when it is wide enough.
struct AgentTVSpeaker: View {
    let plastic: Color

    var body: some View {
        Canvas { ctx, size in
            guard size.width > 8, size.height > 8 else { return }
            let rect = CGRect(origin: .zero, size: size)
            let light = Look.isLight   // the light preset: a pale cloth with dark slits, not a black one
            let back = light ? Retro.shade(Look.wellPaper, -0.04) : Retro.shade(plastic, -0.62)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(back))
            // The cloth: horizontal slits, a lighter lip under each.
            var y: CGFloat = 4
            while y < size.height - 4 {
                ctx.fill(Path(CGRect(x: 4, y: y, width: size.width - 8, height: 1.4)), with: .color(Color.black.opacity(light ? 0.40 : 0.8)))
                ctx.fill(Path(CGRect(x: 4, y: y + 1.4, width: size.width - 8, height: 0.7)), with: .color(Retro.shade(plastic, 0.1).opacity(0.28)))
                y += 3.6
            }
            // A cone ring in the middle of a wide speaker.
            if size.width >= 62 {
                let r = min(size.width * 0.34, size.height * 0.30)
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let ring = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
                ctx.fill(Path(ellipseIn: ring), with: .color(Color.black.opacity(light ? 0.26 : 0.55)))
                ctx.stroke(Path(ellipseIn: ring), with: .color(Retro.shade(plastic, 0.12).opacity(0.5)), lineWidth: 1.2)
                ctx.stroke(Path(ellipseIn: ring.insetBy(dx: r * 0.34, dy: r * 0.34)), with: .color(Retro.shade(plastic, 0.08).opacity(0.3)), lineWidth: 0.9)
                ctx.fill(Path(ellipseIn: ring.insetBy(dx: r * 0.7, dy: r * 0.7)), with: .color(light ? Retro.shade(Look.wellPaper, -0.30) : Retro.shade(plastic, -0.4)))
            }
            // The sunken edge.
            ctx.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 4), with: .color(Color.black.opacity(light ? 0.30 : 0.7)), lineWidth: 1)
        }
    }
}
