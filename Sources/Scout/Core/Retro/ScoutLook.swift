import AppKit
import SwiftUI

// The owner's two extra appearance settings, next to the 8-bit / minimal switch (`Retro.styleKey`), 2026-11-16.
//   Size   (Pref "ui.scale"):  normal 1.0 · large 1.2 · extra large 1.45. The OPEN notch is drawn that much bigger (the island grows to match,
//          its top stays at the screen edge); the closed notch's wings grow a little (1.0 · 1.15 · 1.3).
//   Colours (Pref "ui.preset"): dark (the open notch and every panel are one BLACK screen, the default) or light (one light warm surface, dark
//          text, colourful accents). The CLOSED notch is always black: it merges with the camera housing.
// A window rebuilds itself once when a setting changes (`retroStyleRoot`), so a plain read of the Pref is enough while drawing.
//
// The ink: views that sit on the open notch's surface use the SEMANTIC inks (`Look.primary`, `.secondary`, `.quiet`, `.faint`, or `Look.ink(opacity)`),
// which are dynamic colours that follow the view's colour scheme: white in a dark scheme, near-black in a light one. The open notch sets its
// content's scheme from the preset, and a picture that is a SCREEN (the Agent TV glass, the den, an LCD window, the Radio's display) sets
// `.environment(\.colorScheme, .dark)` (`.lookScreen()`) so everything inside it keeps its light-on-dark inks.

enum Look {
    static let scaleKey = "ui.scale"
    static let presetKey = "ui.preset"

    /// The size of the open notch.
    enum Size: String, CaseIterable, Identifiable {
        case normal, large, xlarge

        var id: String { rawValue }

        var title: String {
            switch self {
            case .normal: String(localized: "Normal")
            case .large: String(localized: "Large")
            case .xlarge: String(localized: "Extra large")
            }
        }

        /// How much bigger the open notch is drawn.
        var factor: CGFloat {
            switch self {
            case .normal: 1.0
            case .large: 1.2
            case .xlarge: 1.45
            }
        }

        /// How much bigger the closed notch's wings (the agents' faces, the message) are drawn.
        var wingFactor: CGFloat {
            switch self {
            case .normal: 1.0
            case .large: 1.15
            case .xlarge: 1.3
            }
        }
    }

    /// The colours of the open notch.
    enum Preset: String, CaseIterable, Identifiable {
        case dark, light

        var id: String { rawValue }

        var title: String {
            switch self {
            case .dark: String(localized: "Dark")
            case .light: String(localized: "Light")
            }
        }

        /// The longer name the tour and Settings use.
        var longTitle: String {
            switch self {
            case .dark: String(localized: "Dark")
            case .light: String(localized: "Light colourful")
            }
        }
    }

    // MARK: The settings

    /// Galleries and tests can force a value for a whole run: `SCOUT_SCALE=normal|large|xlarge`, `SCOUT_PRESET=dark|light`.
    private static let forcedSize: Size? = ProcessInfo.processInfo.environment["SCOUT_SCALE"].flatMap { Size(rawValue: $0) }
    private static let forcedPreset: Preset? = ProcessInfo.processInfo.environment["SCOUT_PRESET"].flatMap { Preset(rawValue: $0) }

    static var size: Size { forcedSize ?? Size(rawValue: Pref.string(scaleKey, Size.normal.rawValue)) ?? .normal }
    static var preset: Preset { forcedPreset ?? Preset(rawValue: Pref.string(presetKey, Preset.dark.rawValue)) ?? .dark }

    /// How much bigger the open notch is drawn (1 = as designed).
    static var scale: CGFloat { size.factor }
    /// How much bigger the closed notch's wings are drawn.
    static var wingScale: CGFloat { size.wingFactor }
    /// True while the light preset is on.
    static var isLight: Bool { preset == .light }
    /// The colour scheme the open notch's content is drawn in.
    static var contentScheme: ColorScheme { isLight ? .light : .dark }

    // MARK: The surface

    /// The light preset's warm paper.
    static let paper = Color(red: 0.953, green: 0.937, blue: 0.902)
    /// The dark ink of the light preset (a warm near-black).
    static let inkDark = NSColor(red: 0.105, green: 0.098, blue: 0.086, alpha: 1)

    /// The open notch's one surface, under the island and every panel: black in the dark preset, warm paper in the light one. (The closed
    /// notch is always `Color.black`.)
    static var surface: Color { isLight ? paper : .black }

    // MARK: The wells (sunken boxes, fields, LCD windows, LED tracks)

    /// The light preset's sunken well: the paper a shade deeper, so a box, a field or an LCD window reads as pressed into the surface and the
    /// dark ink (`Look.ink`, `.primary`) written on it keeps its contrast.
    static let wellPaper = Color(red: 0.902, green: 0.882, blue: 0.835)
    /// The same well while something is dragged over it (the Edit Nook palette bar): a warm tint.
    static let wellHot = Color(red: 0.945, green: 0.875, blue: 0.690)

    /// The face of a sunken well. The dark preset keeps `dark` (each well's own dark glass, exactly as it was); the light preset gives every
    /// well the one `wellPaper` (or `wellHot`), so no dark box sits on the paper.
    /// Screens that are physical objects (a TV glass) do not use it.
    static func well(dark: Color, hot: Bool = false) -> Color { isLight ? (hot ? wellHot : wellPaper) : dark }

    /// The colour scheme the inside of a well is drawn in: dark glass keeps light inks, the light well takes the dark ones.
    static var wellScheme: ColorScheme { isLight ? .light : .dark }

    // MARK: The inks (dynamic: they follow the colour scheme of the view they are used in)

    /// True when this appearance is a dark one.
    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// The text and line ink at `opacity`: white in a dark scheme, near-black in a light one (a little firmer there: soft dark ink on paper
    /// reads weaker than soft white on black).
    static func ink(_ opacity: Double = 1) -> Color {
        let firmer = pow(min(1, max(0, opacity)), 0.75)
        return Color(nsColor: NSColor(name: nil) { appearance in
            isDark(appearance) ? NSColor(white: 1, alpha: opacity) : inkDark.withAlphaComponent(firmer)
        })
    }

    /// The colour at `opacity` in a dark scheme and `light` in a light one (for tiles, rules and shadows that need a different strength).
    static func pair(dark: Color, light: Color) -> Color {
        let d = NSColor(dark), l = NSColor(light)
        return Color(nsColor: NSColor(name: nil) { isDark($0) ? d : l })
    }

    /// The kit's on-screen white (`Retro.Ink.osdWhite`) for text that sits on the open notch's surface: the very same soft white in a dark
    /// scheme, the warm near-black in a light one. Text on plastic or on a screen keeps the fixed `Retro.Ink.osdWhite`.
    static let osd = pair(dark: Retro.Ink.osdWhite, light: Color(nsColor: inkDark))

    static let primary = ink(1)
    static let secondary = ink(0.62)
    static let quiet = ink(0.62)
    static let faint = ink(0.38)
    /// A soft tile behind a group, a hairline, a stronger tile.
    static let tile = pair(dark: Color.white.opacity(0.07), light: Color.black.opacity(0.055))
    static let tileStrong = pair(dark: Color.white.opacity(0.13), light: Color.black.opacity(0.10))
    static let hairline = pair(dark: Color.white.opacity(0.10), light: Color.black.opacity(0.12))
    /// The wash a panel gets under the pointer.
    static let hoverWash = pair(dark: Color.white.opacity(0.07), light: Color.black.opacity(0.055))

    /// An accent colour that reads on the surface: itself in a dark scheme, a deeper shade of it in a light one (yellow, lime and teal are
    /// unreadable as text on warm paper). Only for the kit's fixed accents (`Retro.Ink.*`).
    static func accent(_ color: Color) -> Color {
        let c = Retro.rgb(color)
        let base = NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
        let amount = Retro.luminance(color) > 0.45 ? -0.44 : -0.22
        let deepC = NSColor(Retro.shade(color, amount)).usingColorSpace(.sRGB) ?? base
        return Color(nsColor: NSColor(name: nil) { isDark($0) ? base : deepC })
    }

    /// The accents as the surface wears them.
    static let teal = accent(Retro.Ink.teal)
    static let magenta = accent(Retro.Ink.magenta)
    static let purple = accent(Retro.Ink.purple)
    static let yellow = accent(Retro.Ink.yellow)
    static let lime = accent(Retro.Ink.lime)
    static let orange = accent(Retro.Ink.orange)
    static let red = accent(Retro.Ink.red)

    /// The ink on a coloured key or pill: the fixed near-black when the colour is light, else the soft white (does not follow the scheme).
    static func onColor(_ color: Color) -> Color {
        Retro.isLight(color) ? Color(red: 0.08, green: 0.08, blue: 0.09) : Retro.Ink.osdWhite
    }
}

/// Lays a view out at `content` points and draws it `scale` times bigger from its top edge, in a frame of the bigger size (hit testing and
/// the reported rects follow the transform). At scale 1 it changes nothing.
private struct LookScaled: ViewModifier {
    let scale: CGFloat
    let size: CGSize

    @ViewBuilder func body(content: Content) -> some View {
        if abs(scale - 1) < 0.001 {
            content
        } else {
            content
                .frame(width: size.width, height: size.height, alignment: .top)
                .scaleEffect(scale, anchor: .top)
                .frame(width: size.width * scale, height: size.height * scale, alignment: .top)
        }
    }
}

/// A view of a known width and a natural height (a notification card), drawn `scale` times bigger from its top edge, taking the room it needs.
private struct Magnified: ViewModifier {
    let scale: CGFloat
    let width: CGFloat
    @State private var natural: CGFloat = 0

    @ViewBuilder func body(content: Content) -> some View {
        if abs(scale - 1) < 0.001 {
            content
        } else {
            content
                .background(GeometryReader { proxy in Color.clear.onAppear { natural = proxy.size.height }.onChange(of: proxy.size.height) { natural = proxy.size.height } })
                .scaleEffect(scale, anchor: .top)
                .frame(width: width * scale, height: natural > 0 ? natural * scale : nil, alignment: .top)
        }
    }
}

/// An SF Symbol drawn as a plain template image, so the foreground style tints it every time. (A few symbols drawn with `Image(systemName:)`
/// in the open notch's header ignored the foreground style and came out white: on the light preset they vanished.)
struct LookSymbol: View {
    let name: String
    var size: CGFloat = 12
    var weight: Font.Weight = .semibold

    private var nsWeight: NSFont.Weight {
        switch weight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }

    var body: some View {
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: nsWeight)) {
            let template = (image.copy() as? NSImage) ?? image
            let _ = { template.isTemplate = true }()
            Image(nsImage: template).renderingMode(.template)
        } else {
            Image(systemName: name).font(.system(size: size, weight: weight))
        }
    }
}

/// Sets the appearance of the window this view sits in: dark or light. SwiftUI draws some SF Symbols through AppKit views that ignore the
/// SwiftUI colour scheme and the foreground style and follow the window's appearance instead (the open notch's header keys did: white on the
/// light surface on a Mac in dark mode); with the window's appearance set to the notch's own, they read right.
struct WindowAppearance: NSViewRepresentable {
    let dark: Bool

    final class Probe: NSView {
        var dark = true { didSet { apply() } }
        override func viewDidMoveToWindow() { apply() }
        private func apply() { window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.dark = dark
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) { probe.dark = dark }
}

extension View {
    /// The open notch's content, laid out at `content` points and drawn `scale` times bigger from the top edge.
    func lookScaled(_ scale: CGFloat, content: CGSize) -> some View { modifier(LookScaled(scale: scale, size: content)) }

    /// A card (known width, natural height) drawn `scale` times bigger from its top edge.
    func magnified(_ scale: CGFloat, width: CGFloat) -> some View { modifier(Magnified(scale: scale, width: width)) }

    /// A picture that is a SCREEN (a TV glass, an LCD window, the den): dark inside whatever the preset, so its light-on-dark inks keep working.
    func lookScreen() -> some View { environment(\.colorScheme, .dark) }

    /// A sunken well that follows the preset (`Look.well`): dark glass with light inks in the dark preset, a light well with dark inks in the light one.
    func lookWell() -> some View { environment(\.colorScheme, Look.wellScheme) }
}
