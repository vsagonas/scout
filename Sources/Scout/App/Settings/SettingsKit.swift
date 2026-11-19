import SwiftUI

// Small shared pieces for the settings pages (the notch's pages use them; other parts may too).

/// Footer text under a grouped section: left-aligned, small, secondary.
struct SettingsFootnote: View {
    let text: Text
    init(_ key: LocalizedStringKey) { self.text = Text(key) }
    init(verbatim: String) { self.text = Text(verbatim: verbatim) }

    var body: some View {
        text
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
    }
}

/// A slider with its value written next to it.
struct ValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit = ""
    var decimals = 0

    var body: some View {
        HStack {
            Slider(value: $value, in: range, step: step).frame(width: 180)
            Text(verbatim: value.formatted(.number.precision(.fractionLength(decimals)).grouping(.never)) + unit)
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
    }
}

/// A status pill ("Allowed", "Not asked yet"…).
struct StatusPill: View {
    enum Tone { case good, neutral, warn }
    let text: Text
    var tone: Tone = .neutral

    init(_ key: LocalizedStringKey, tone: Tone = .neutral) { self.text = Text(key); self.tone = tone }
    init(verbatim: String, tone: Tone = .neutral) { self.text = Text(verbatim: verbatim); self.tone = tone }

    var body: some View {
        text
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private var color: Color {
        switch tone {
        case .good: .green
        case .neutral: .secondary
        case .warn: .orange
        }
    }
}
