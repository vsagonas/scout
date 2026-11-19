import SwiftUI

struct MirrorRectsKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// The small floating toolbar over the Mirror's picture, as a row of small plastic keys (the kit's `.retro` keys): zoom (− fader + and the
/// read-out), Snap (a picture to the clipboard). A separate view so one more tool button can join it: pass the button as `extras`; it
/// sits after Snap (Share). It shows the values it is given and acts on `tools` and `model`, so a gallery picture and the live tab use the
/// same view. A tool that is on stays pressed in and lit. The ring light and Freeze keys are gone,
/// and Flip lives in Settings › Mirror.
struct MirrorToolbar<Extras: View>: View {
    @ObservedObject var model: MirrorModel
    @ObservedObject var tools: MirrorTools
    var zoom: MirrorZoom
    var onSnap: () -> Void
    @ViewBuilder var extras: () -> Extras

    var body: some View {
        HStack(spacing: 6) {
            MirrorToolButton(symbol: "minus.magnifyingglass", help: "Zoom out") { tools.stepZoom(-1) }
                .mirrorRect("zoomOut")
            slider(value: Binding(get: { Double(zoom.scale) }, set: { tools.setScale(CGFloat($0)) }), range: 1...Double(MirrorZoom.maxScale),
                   tint: Retro.Ink.teal)
                .frame(width: 84)
                .mirrorRect("zoomSlider")
            MirrorToolButton(symbol: "plus.magnifyingglass", help: "Zoom in") { tools.stepZoom(1) }
                .mirrorRect("zoomIn")
            MirrorScaleButton(scale: zoom.scale) { tools.resetZoom() }
                .mirrorRect("zoomReset")
            divider
            MirrorToolButton(symbol: "camera.fill", help: "Snap: copy a picture of this to the clipboard") { onSnap() }
                .mirrorRect("snap")
            extras()
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .mirrorBarFace()
        .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
        .environment(\.colorScheme, .dark)
    }

    /// The fader of the 90s look, or a plain slider in the minimal one (same maths, same size).
    @ViewBuilder private func slider(value: Binding<Double>, range: ClosedRange<Double>, tint: Color) -> some View {
        if Retro.is8bit { RetroFader(value: value, range: range, tint: tint, ticks: 5, label: String(localized: "Zoom")) } else { MiniSlider(value: value, range: range, label: "Zoom") }
    }

    /// A groove between two groups of keys (a hairline in the minimal look).
    private var divider: some View { MirrorToolbarDivider() }
}

extension View {
    /// The toolbar's face: a raised plastic bar in the 8-bit look, a flat dark rounded card in the minimal one.
    @ViewBuilder fileprivate func mirrorBarFace() -> some View {
        if Retro.is8bit { retroBevel(.raised, cornerRadius: 7, depth: 1.5, face: RadioBoom.body) } else { miniCard(radius: 11, fill: Color(white: 0.13)) }
    }

    /// Tells the Mirror scene where this control is (the self-test clicks it by name).
    func mirrorRect(_ name: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: MirrorRectsKey.self, value: [name: proxy.frame(in: .named("mirrorScene"))])
        })
    }
}

// MARK: - Toolbar controls

/// A small plastic key with a symbol. It stays pressed in and lit (yellow) while its tool is on; hover only lightens it.
struct MirrorToolButton: View {
    let symbol: String
    var on = false
    /// nil: yellow while `on`, the middle plastic otherwise.
    var tint: Color?
    var size = CGSize(width: 15, height: 14)
    var help: LocalizedStringKey
    let action: () -> Void
    @State private var hover = false

    /// The same key `DeckKey` draws (compact), written here so its tooltip is a literal that localizes itself.
    var body: some View {
        let tint: Color = self.tint ?? (on ? Retro.Ink.yellow : Retro.Ink.plasticMid)
        if Retro.is8bit {
            Button(action: action) {
                Image(systemName: symbol).frame(width: size.width, height: size.height)
            }
            .buttonStyle(DeckKeyStyle(latched: on, tint: hover ? Retro.shade(tint, 0.10) : tint, compact: true))
            .onHover { hover = $0 }
            .help(help)
            .accessibilityLabel(help)
        } else {
            Button(action: action) { Image(systemName: symbol) }
                .buttonStyle(MiniIconButtonStyle(size: 22, lit: on))
                .help(help)
                .accessibilityLabel(help)
        }
    }
}

/// The zoom read-out ("1×", "2.0×"); a click goes back to 1×. Lit and pressed in while zoomed.
struct MirrorScaleButton: View {
    let scale: CGFloat
    let action: () -> Void
    @State private var hover = false

    private var label: String {
        if scale < 1.05 { return "1×" }
        return abs(scale - scale.rounded()) < 0.05 ? "\(Int(scale.rounded()))×" : Double(scale).formatted(.number.precision(.fractionLength(1))) + "×"
    }

    var body: some View {
        let zoomed = scale >= 1.05
        let tint: Color = zoomed ? Retro.Ink.yellow : Retro.Ink.plasticMid
        if !Retro.is8bit {
            // The minimal look: the read-out as a small rounded label, lit in the accent while zoomed.
            Button(action: action) {
                Text(label).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(zoomed ? Theme.accent : Retro.quietInk)
                    .frame(width: 32, height: 22)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(zoomed ? Theme.accent.opacity(0.20) : (hover ? MiniBoom.fillStrong : MiniBoom.fill)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help("Back to the whole picture")
            .accessibilityLabel("Zoom \(label), back to the whole picture")
        } else {
        Button(action: action) {
            Text(label).font(.system(size: 11, weight: .heavy).monospacedDigit()).frame(width: 26, height: 14)
        }
        .buttonStyle(DeckKeyStyle(latched: zoomed, tint: hover ? Retro.shade(tint, 0.10) : tint, compact: true))
        .onHover { hover = $0 }
        .help("Back to the whole picture")
        .accessibilityLabel("Zoom \(label), back to the whole picture")
        }
    }
}
