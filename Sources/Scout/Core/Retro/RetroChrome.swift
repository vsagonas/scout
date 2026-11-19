import SwiftUI

// Window chrome and decoration: a 90s title bar and the faint Memphis confetti.

/// A 90s window title bar: a coloured bar with a raised edge, a close box, pinstripes either side of a pixel-capital title (and an
/// optional symbol), and room for small controls at the right. 20 pt tall; it takes the width it is given.
struct RetroTitleBar<Trailing: View>: View {
    let title: String
    let symbol: String?
    let tint: Color
    let trailing: Trailing

    init(_ title: String, symbol: String? = nil, tint: Color = Retro.Ink.teal, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.trailing = trailing()
    }

    static var barHeight: CGFloat { 20 }

    var body: some View {
        if Retro.is8bit { barBody } else { plainBody }
    }

    /// The minimal look: just the title as a quiet label, with the controls at the right.
    private var plainBody: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(Retro.quietInk) }
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(Retro.quietInk).lineLimit(1)
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 4)
        .frame(height: Self.barHeight)
    }

    private var barBody: some View {
        let light = Look.isLight   // the light preset: a pale tinted bar with dark lettering instead of a dark one
        let bar = light ? Retro.shade(tint, 0.62) : Retro.shade(tint, -0.52)
        return HStack(spacing: 5) {
            // The close box.
            Color.clear.frame(width: 8, height: 8)
                .retroBevel(.raised, cornerRadius: 1, depth: 1, face: Retro.shade(tint, 0.10))
            Stripes(tint: tint, light: light)
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(light ? Look.accent(tint) : tint)
                }
                RetroPixelText(title, pixel: 1.5, color: light ? CRTDrawing.paperInk : Retro.Ink.osdWhite)
            }
            Stripes(tint: tint, light: light)
            trailing
        }
        .padding(.horizontal, 5)
        .frame(height: Self.barHeight)
        .retroBevel(.raised, cornerRadius: 3, depth: 1, face: bar)
    }

    /// Pinstripes that fill the room between the box, the title and the controls.
    private struct Stripes: View {
        let tint: Color
        var light = false
        var body: some View {
            Canvas { ctx, size in
                var rows = Path()
                var y = ctx.snapped((size.height - 8) / 2)
                let end = y + 8
                while y < end - 0.4 {
                    rows.addRect(CGRect(x: 0, y: y, width: size.width, height: max(0.5, 1 / max(1, ctx.environment.displayScale))))
                    y += 2
                }
                ctx.fill(rows, with: .color(light ? Retro.shade(tint, 0.15) : Retro.shade(tint, 0.05)))
            }
            .frame(minWidth: 6, maxWidth: .infinity)
            .frame(height: 10)
        }
    }
}

extension RetroTitleBar where Trailing == EmptyView {
    /// A title bar with nothing at the right.
    init(_ title: String, symbol: String? = nil, tint: Color = Retro.Ink.teal) {
        self.init(title, symbol: symbol, tint: tint) { EmptyView() }
    }
}

// MARK: - Memphis

/// Faint 90s confetti: triangles, squiggles, dots, rings and plus signs in the accent colours, scattered evenly (never overlapping),
/// the same every time for a `seed`. Draw it behind content; `opacity` is its overall strength (about 0.12 for a background).
struct MemphisPattern: View {
    let seed: Int
    let opacity: Double

    init(seed: Int = 1, opacity: Double = 0.12) {
        self.seed = seed
        self.opacity = opacity
    }

    var body: some View {
        if Retro.is8bit { confetti }
    }

    private var confetti: some View {
        Canvas { ctx, size in
            guard size.width > 4, size.height > 4 else { return }
            var dice = Retro.Dice(seed: seed &* 7919 &+ 13)
            let palette = [Retro.Ink.teal, Retro.Ink.magenta, Retro.Ink.purple, Retro.Ink.yellow, Retro.Ink.orange]
            let cell: CGFloat = 30
            let cols = Int((size.width / cell).rounded(.up)), rows = Int((size.height / cell).rounded(.up))
            for r in 0..<rows {
                for c in 0..<cols {
                    if dice.next() < 0.28 { continue }   // some cells stay empty
                    let center = CGPoint(x: (CGFloat(c) + 0.5 + CGFloat(dice.range(-0.22, 0.22))) * cell, y: (CGFloat(r) + 0.5 + CGFloat(dice.range(-0.22, 0.22))) * cell)
                    let color = palette[dice.int(palette.count)].opacity(opacity)
                    let s = CGFloat(dice.range(4.5, 7.5))
                    let angle = dice.range(0, 2 * .pi)
                    var c2 = ctx
                    c2.translateBy(x: center.x, y: center.y)
                    c2.rotate(by: .radians(angle))
                    switch dice.int(5) {
                    case 0:   // a triangle
                        var p = Path()
                        p.move(to: CGPoint(x: 0, y: -s)); p.addLine(to: CGPoint(x: s * 0.95, y: s * 0.7)); p.addLine(to: CGPoint(x: -s * 0.95, y: s * 0.7)); p.closeSubpath()
                        c2.fill(p, with: .color(color))
                    case 1:   // a squiggle
                        var p = Path()
                        p.move(to: CGPoint(x: -s * 1.5, y: 0))
                        for i in 1...6 { p.addLine(to: CGPoint(x: -s * 1.5 + CGFloat(i) * s * 0.5, y: i % 2 == 0 ? s * 0.38 : -s * 0.38)) }
                        c2.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    case 2:   // a dot
                        c2.fill(Path(ellipseIn: CGRect(x: -s * 0.45, y: -s * 0.45, width: s * 0.9, height: s * 0.9)), with: .color(color))
                    case 3:   // a ring
                        c2.stroke(Path(ellipseIn: CGRect(x: -s * 0.7, y: -s * 0.7, width: s * 1.4, height: s * 1.4)), with: .color(color), lineWidth: 1.6)
                    default:  // a plus
                        var p = Path()
                        p.move(to: CGPoint(x: -s * 0.8, y: 0)); p.addLine(to: CGPoint(x: s * 0.8, y: 0))
                        p.move(to: CGPoint(x: 0, y: -s * 0.8)); p.addLine(to: CGPoint(x: 0, y: s * 0.8))
                        c2.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineCap: .butt))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
