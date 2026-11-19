import SwiftUI

// Small 90s parts the Radio and the Mirror share, built on the kit in Core/Retro: a chunky key that can stay pressed in, a fader
// (a groove and a plastic cap you drag), and pixel letters that fall back to the system font for letters the dot font lacks.
// Nothing here moves by itself.

// MARK: - Keys

/// A key's look: raised, sunken while pressed or `latched` (a PLAY key stays down while the tape runs). It reads `isEnabled`.
struct DeckKeyStyle: ButtonStyle {
    var latched = false
    var tint: Color = Retro.Ink.plasticMid
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        DeckKeyBody(configuration: configuration, latched: latched, tint: tint, compact: compact)
    }
}

private struct DeckKeyBody: View {
    let configuration: ButtonStyleConfiguration
    let latched: Bool
    let tint: Color
    let compact: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        RetroKeyFace(pressed: configuration.isPressed || latched, tint: tint, compact: compact) { configuration.label }
            .opacity(enabled ? 1 : 0.45)
    }
}

/// A key with an SF Symbol: hover only lightens it, a press sinks it. `size` is the symbol's box; the key adds its own padding.
struct DeckKey: View {
    let symbol: String
    var latched = false
    var tint: Color = Retro.Ink.plasticMid
    var compact = false
    var size = CGSize(width: 18, height: 14)
    var help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        if Retro.is8bit {
            Button(action: action) {
                Image(systemName: symbol).frame(width: size.width, height: size.height)
            }
            .buttonStyle(DeckKeyStyle(latched: latched, tint: hover ? Retro.shade(tint, 0.10) : tint, compact: compact))
            .onHover { hover = $0 }
            .help(help)
            .accessibilityLabel(help)
        } else {
            // The minimal look: a plain rounded icon button, lit in the accent while it is "down" (latched).
            Button(action: action) { Image(systemName: symbol) }
                .buttonStyle(MiniIconButtonStyle(size: compact ? 22 : 28, lit: latched))
                .help(help)
                .accessibilityLabel(help)
        }
    }
}

// MARK: - Fader

/// A 90s fader: a sunken groove with tick marks and a plastic cap. A press or a drag anywhere on it moves the cap there. It fills
/// the width it is given and is 22 pt tall.
struct RetroFader: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var tint: Color = Retro.Ink.teal
    var ticks = 11
    var label = String(localized: "Level")
    /// True: a pale groove with dark ticks for a fader on a light plastic (the light preset's Radio deck); the Mirror's stays dark.
    var light = false

    static let capWidth: CGFloat = 12
    static let capHeight: CGFloat = 16

    /// Where the cap sits, 0 to 1.
    static func fraction(_ value: Double, in range: ClosedRange<Double>) -> Double {
        guard range.upperBound > range.lowerBound, !value.isNaN else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }

    /// The value for a press at `x` in a fader `width` wide: the cap's middle goes under the pointer.
    static func value(atX x: CGFloat, width: CGFloat, in range: ClosedRange<Double>) -> Double {
        let travel = max(1, width - capWidth)
        let f = min(1, max(0, Double((x - capWidth / 2) / travel)))
        return range.lowerBound + f * (range.upperBound - range.lowerBound)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let f = Self.fraction(value, in: range)
            let travel = max(1, w - Self.capWidth)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let groove = CGRect(x: 1, y: size.height / 2 - 3, width: size.width - 2, height: 6)
                    ctx.fill(Path(roundedRect: groove, cornerRadius: 2), with: .color(light ? Look.wellPaper : Color(red: 0.03, green: 0.035, blue: 0.04)))
                    if light { ctx.stroke(Path(roundedRect: groove, cornerRadius: 2), with: .color(Color.black.opacity(0.35)), lineWidth: 0.8) }
                    let lit = max(0, Self.capWidth / 2 + CGFloat(f) * travel - 2)
                    ctx.fill(Path(roundedRect: CGRect(x: groove.minX + 1, y: groove.minY + 1.5, width: lit, height: 3), cornerRadius: 1), with: .color(tint))
                    ctx.fill(Path(CGRect(x: groove.minX + 1, y: groove.maxY, width: groove.width - 2, height: 0.8)), with: .color(Color.white.opacity(0.16)))
                    var marks = Path()
                    let n = max(2, ticks)
                    for i in 0..<n {
                        let x = ctx.snapped(Self.capWidth / 2 + CGFloat(i) / CGFloat(n - 1) * travel)
                        marks.addRect(CGRect(x: x - 0.5, y: groove.maxY + 3, width: 1, height: i % 5 == 0 ? 4 : 2.5))
                    }
                    ctx.fill(marks, with: .color(light ? Color.black.opacity(0.42) : Color.white.opacity(0.34)))
                }
                Color.clear.frame(width: Self.capWidth, height: Self.capHeight)
                    .retroBevel(.raised, cornerRadius: 2, depth: 1, face: Retro.Ink.plasticMid)
                    .overlay(Rectangle().fill(Color.black.opacity(0.55)).frame(width: 1, height: Self.capHeight - 6))
                    .offset(x: CGFloat(f) * travel, y: (h - Self.capHeight) / 2)
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                value = Self.value(atX: g.location.x, width: w, in: range)
            })
        }
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((Self.fraction(value, in: range) * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) * 0.1
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }
}

// MARK: - Letters

/// Text for the little screens: pixel capitals when the dot font knows every letter, else the system font (Greek, Cyrillic, symbols):
/// readable first. The choice and the size are plain functions, so the self-test and the drawing agree.
enum RadioLCDText {
    struct Fit: Equatable {
        var text: String
        /// The dot size in points; nil means "draw this in the system font".
        var pixel: CGFloat?
    }

    static func canPixel(_ text: String) -> Bool { !text.isEmpty && text.allSatisfy { LEDFont.hasGlyph($0) } }

    /// The biggest pixel size that fits `width`, else a cut-short text with ".." at the smallest size; nil pixel for the system font.
    static func fit(_ text: String, width: CGFloat, sizes: [CGFloat] = [2, 1.5]) -> Fit {
        guard canPixel(text) else { return Fit(text: text, pixel: nil) }
        for p in sizes where RetroPixelLayout.width(text, pixel: p) <= width { return Fit(text: text, pixel: p) }
        let p = sizes.last ?? 1.5
        var chars = Array(text)
        while chars.count > 1, RetroPixelLayout.width(String(chars) + "..", pixel: p) > width { chars.removeLast() }
        return Fit(text: String(chars).trimmingCharacters(in: .whitespaces) + "..", pixel: p)
    }
}

/// One line of LCD text, fitted to the room it gets (`height` is the line's height; the text sits on its middle).
struct RadioLCDLine: View {
    let text: String
    var color: Color = RadioBoom.green
    var sizes: [CGFloat] = [2, 1.5]
    var systemSize: CGFloat = 12
    var height: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let fit = RadioLCDText.fit(text, width: geo.size.width, sizes: sizes)
            Group {
                if let p = fit.pixel {
                    RetroPixelText(fit.text, pixel: p, color: color)
                } else {
                    Text(text).font(.system(size: systemSize, weight: .bold, design: .monospaced)).foregroundStyle(color).lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
        .frame(height: height)
    }
}

/// The red "LIVE" lamp: a lit dot and pixel letters. Still (no breathing): what it says is simply true while a station plays.
struct RadioLiveLamp: View {
    var pixel: CGFloat = 1.25

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(Retro.Ink.ledRed).frame(width: 5, height: 5).shadow(color: Retro.Ink.ledRed.opacity(0.8), radius: 2.5)
            RetroPixelText("LIVE", pixel: pixel, color: Retro.Ink.ledRed)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live")
    }
}
