import AppKit
import SwiftUI

// The 90s kit (Core/Retro): one shared look for the whole app. Everything is drawn in code, no image files, no font files.
// Reduce Motion is ON on the owner's Mac: nothing in the kit moves by itself; it reads in a still picture.

/// The kit's namespace.
enum Retro {
    /// Accents on the black island, plastic bodies, screen colours and LEDs. All fixed colours: they do not follow light or dark mode.
    enum Ink {
        // Accents on the black island.
        static let teal = Color(red: 0.00, green: 0.80, blue: 0.78)
        static let magenta = Color(red: 0.96, green: 0.20, blue: 0.62)
        static let purple = Color(red: 0.60, green: 0.38, blue: 0.95)
        static let yellow = Color(red: 1.00, green: 0.84, blue: 0.20)
        static let lime = Color(red: 0.56, green: 0.92, blue: 0.24)
        static let orange = Color(red: 1.00, green: 0.54, blue: 0.14)
        static let red = Color(red: 0.96, green: 0.24, blue: 0.22)

        // Plastic: beige, grey, charcoal bodies.
        static let plastic = Color(red: 0.80, green: 0.76, blue: 0.64)
        static let plasticMid = Color(red: 0.56, green: 0.56, blue: 0.55)
        static let plasticDark = Color(red: 0.19, green: 0.19, blue: 0.21)

        // Screens.
        static let screenBlack = Color(red: 0.02, green: 0.03, blue: 0.03)
        static let phosphorGreen = Color(red: 0.32, green: 1.00, blue: 0.48)
        static let phosphorAmber = Color(red: 1.00, green: 0.70, blue: 0.16)
        static let osdWhite = Color(red: 0.94, green: 0.96, blue: 0.92)

        // LEDs.
        static let ledGreen = Color(red: 0.26, green: 0.95, blue: 0.36)
        static let ledYellow = Color(red: 1.00, green: 0.86, blue: 0.12)
        static let ledRed = Color(red: 1.00, green: 0.22, blue: 0.18)
    }

    /// A colour's sRGB parts (0 to 1).
    static func rgb(_ color: Color) -> (r: Double, g: Double, b: Double, a: Double) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
    }

    /// Perceived brightness, 0 (black) to 1 (white).
    static func luminance(_ color: Color) -> Double {
        let c = rgb(color)
        return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
    }

    /// True when dark text reads best on this colour.
    static func isLight(_ color: Color) -> Bool { luminance(color) > 0.52 }

    /// The colour mixed toward white (`amount` > 0) or toward black (`amount` < 0), 1 = fully.
    static func shade(_ color: Color, _ amount: Double) -> Color {
        let c = rgb(color)
        let target = amount >= 0 ? 1.0 : 0.0
        let t = min(1, abs(amount))
        return Color(.sRGB, red: c.r + (target - c.r) * t, green: c.g + (target - c.g) * t, blue: c.b + (target - c.b) * t, opacity: c.a)
    }

    /// A tiny deterministic random source (so `seed` always draws the same picture): xorshift, 0 to 1.
    struct Dice {
        private var state: UInt64
        init(seed: Int) { state = UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15 | 1 }
        mutating func next() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * next() }
        mutating func int(_ n: Int) -> Int { min(n - 1, Int(next() * Double(n))) }
    }
}

extension GraphicsContext {
    /// Rounds a point value to a whole device pixel, so thin lines and pixel squares stay crisp.
    func snapped(_ v: CGFloat) -> CGFloat {
        let s = max(1, environment.displayScale)
        return (v * s).rounded() / s
    }
}
