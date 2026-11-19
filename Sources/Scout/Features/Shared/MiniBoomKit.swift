import SwiftUI

// The minimal look's small pieces for the Ask AI, live panels, Radio and Mirror.
// Only used while `Retro.is8bit` is false: flat dark rounded shapes, 0.5 pt hairlines, the system font.
// Nothing here moves.

enum MiniBoom {
    /// The flat dark card that holds a list, an answer or a quiet line (a little darker than the panel's face).
    static let card = Look.pair(dark: Color(white: 0.06), light: Color.black.opacity(0.05))
    /// A text field's or a key's resting fill.
    static let fill = Look.tile
    static let fillStrong = Look.tileStrong
}

extension View {
    /// A flat dark rounded card with a hairline.
    func miniCard(radius: CGFloat = 8, fill: Color = MiniBoom.card) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Retro.hairline, lineWidth: 0.5).allowsHitTesting(false))
    }

    /// A plain rounded text field's frame: a soft fill and a hairline (the field itself stays `.plain`).
    func miniField(height: CGFloat = 26, radius: CGFloat = 7) -> some View {
        padding(.horizontal, 9)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Look.pair(dark: Color.black.opacity(0.30), light: Color.white.opacity(0.65))))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Retro.hairline, lineWidth: 0.5).allowsHitTesting(false))
    }
}

/// A square icon button: a soft rounded fill, the symbol in quiet ink; `lit` fills it with the accent.
struct MiniIconButtonStyle: ButtonStyle {
    var size: CGFloat = 26
    var lit = false
    var radius: CGFloat = 7
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(lit ? Theme.accent : Retro.quietInk)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(lit ? Theme.accent.opacity(0.20) : MiniBoom.fill))
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

/// A slim progress bar (3 pt): still, never moves. `fraction` nil = unknown: a short bar at the left.
struct MiniBar: View {
    var fraction: Double?
    var tint: Color = Theme.accent
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Look.ink(0.12))
                Capsule().fill(tint).frame(width: max(height, geo.size.width * CGFloat(fraction.map { min(1, max(0, $0)) } ?? 0.25)))
            }
        }
        .frame(height: height)
    }
}

/// A small state word with a plain dot ("busy", "1 overdue"): the minimal look of the 90s LED lamp.
struct MiniLamp: View {
    let text: String
    var color: Color = Theme.accent
    /// `text` is a finished string (localized where it is made); `MiniLamp` only shows it.

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text.prefix(1).uppercased() + text.dropFirst()).font(.system(size: 10, weight: .medium)).foregroundStyle(Retro.quietInk).lineLimit(1).fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// The fact at the right of a panel's title: a Dash90 lamp in the 8-bit look, a plain dotted word in the minimal one.
struct LampOrMini: View {
    let text: String
    var color: Color = Retro.Ink.ledRed

    var body: some View {
        if Retro.is8bit { Dash90Lamp(verbatim: text, color: color) } else { MiniLamp(text: text, color: color) }
    }
}

/// A plain slider for the minimal look: a thin track, the part below the value filled, a round knob. A press or a drag anywhere on it moves the
/// knob there (the same maths as the 90s fader, so a test can press it by position). It fills the width it is given and is 22 pt tall.
struct MiniSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var label: LocalizedStringKey = "Level"

    static let knob: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let f = RetroFader.fraction(value, in: range)
            let travel = max(1, w - Self.knob)
            ZStack(alignment: .leading) {
                Capsule().fill(Look.ink(0.16)).frame(height: 3)
                Capsule().fill(Look.ink(0.70)).frame(width: Self.knob / 2 + CGFloat(f) * travel, height: 3)
                Circle().fill(Color.white).frame(width: Self.knob, height: Self.knob)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .offset(x: CGFloat(f) * travel)
            }
            .frame(width: w, height: h, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                value = RetroFader.value(atX: g.location.x, width: w, in: range)
            })
        }
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((RetroFader.fraction(value, in: range) * 100).rounded())) percent")
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
