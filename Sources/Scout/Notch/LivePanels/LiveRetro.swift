import SwiftUI

// The 90s frame of the live panels (R3): the kit's title bar over the content, 8 pt of plastic around it, filling the 140 pt cell.
// `LivePanelFrame` and friends in LiveKit.swift stay as they were (the radio's live panel still uses them).

/// A live panel's frame: a 90s title bar (symbol, pixel title, a short fact at its right) over the content.
struct LiveRetroFrame<Trailing: View, Content: View>: View {
    let symbol: String
    let title: String.LocalizationValue
    var short: String.LocalizationValue?
    var tint: Color
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        let stack = VStack(alignment: .leading, spacing: 6) {
            Dash90Title(title, short: short, symbol: symbol, tint: tint) { trailing() }
            content()
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        stack   // both looks follow the preset: the panel face is the surface (black, or the light preset's paper), so its inks follow it too
    }
}

extension LiveRetroFrame where Trailing == EmptyView {
    init(symbol: String, title: String.LocalizationValue, short: String.LocalizationValue? = nil, tint: Color, @ViewBuilder content: @escaping () -> Content) {
        self.init(symbol: symbol, title: title, short: short, tint: tint, trailing: { EmptyView() }, content: content)
    }
}

/// The short fact at the right of a live panel's title bar ("2 ACTIVE", "PAUSED"), in pixel letters.
struct LiveRetroFact: View {
    let text: String
    var color: Color = Look.osd

    var body: some View {
        if Retro.is8bit { Dash90Text(text, pixel: 1, color: color) } else {
            // The minimal look: the same fact in the system font, sentence case, quiet.
            Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(color == Look.osd ? Retro.quietInk : color).lineLimit(1).fixedSize()
        }
    }
}

/// The progress of a live panel as LED segments in one colour. `fraction` nil = unknown: a still run of lit segments at the left.
struct LiveRetroBar: View {
    var fraction: Double?
    var tint: Color = Retro.Ink.teal
    var segments = 18
    var height: CGFloat = 12

    /// How many segments are lit for a fraction (unknown shows a quarter of them, still).
    static func lit(_ fraction: Double?, segments: Int) -> Int {
        RetroLEDBar.litCount(value: fraction ?? 0.25, segments: segments)
    }

    var body: some View {
        if Retro.is8bit {
            GeometryReader { geo in
                Dash90LEDBar(value: fraction ?? 0.25, segments: segments, size: CGSize(width: geo.size.width, height: height), color: { _, _ in tint })
            }
            .frame(height: height)
        } else {
            MiniBar(fraction: fraction, tint: Theme.accent, height: 4)   // the minimal look: a slim plain bar
        }
    }
}

/// Numbers for the minimal look: the system font, one width for every digit, the tallest of three sizes that fits.
struct MiniDigits: View {
    let text: String
    var size: CGFloat = 30
    var color: Color = NotchInk.primary

    var body: some View {
        ViewThatFits(in: .horizontal) {
            digits(size)
            digits((size * 0.8).rounded())
            digits((size * 0.62).rounded())
        }
    }

    private func digits(_ s: CGFloat) -> some View {
        Text(text).font(.system(size: s, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(color).lineLimit(1).fixedSize()
    }
}

/// A plain SF Symbol in a quiet tone: the minimal look of a picture (the floppy, the camcorder).
struct MiniSymbol: View {
    let name: String
    var size: CGFloat = 22
    var color: Color = Retro.quietInk

    var body: some View {
        LookSymbol(name: name, size: size, weight: .regular).foregroundStyle(color)   // a template image: it takes the ink on the light paper too
            .frame(width: size * 1.4, height: size * 1.4)
            .accessibilityHidden(true)
    }
}
