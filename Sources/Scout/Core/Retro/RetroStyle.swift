import SwiftUI

// The owner's switch between the app's two looks
//   ON  (the default): the 90s / 8-bit look: bevelled plastic, pixel letters, LCD digits, CRT glass, the pixel scouts and their den.
//   OFF: minimal, normal graphics for everything: flat rounded shapes, hairlines, the system font, plain bars, plain lists.
// The kit's pieces read `Retro.is8bit` while they draw and draw flat when it is off; the pieces that are pictures (the scouts, the TV set,
// the boombox, the viewfinder) have a plain version of their own. A window rebuilds itself once when the setting changes (`retroStyleRoot`).

extension Retro {
    static let styleKey = "ui.retro8bit"

    /// Galleries and tests can force a look for a whole run: `SCOUT_8BIT=0` draws the minimal look, `SCOUT_8BIT=1` the 8-bit one.
    private static let forced: Bool? = ProcessInfo.processInfo.environment["SCOUT_8BIT"].map { $0 != "0" }

    /// True while the 8-bit style is on (the setting; on unless the owner switched it off).
    static var is8bit: Bool { forced ?? Pref.bool(styleKey, true) }

    /// The hairline that edges a flat shape in the minimal look (follows the colour scheme: light on the dark surface, dark on the light one).
    static let hairline = Look.hairline

    /// The ink of a heading or a label in the minimal look: soft white (soft near-black in the light preset), no colour.
    static let quietInk = Look.quiet
}

/// The window root that makes the style switch take effect at once: it watches the setting and rebuilds its content when it changes,
/// so every piece draws in the new look (a switch is rare, so losing the little transient view state is fine).
struct RetroStyleRoot: ViewModifier {
    @AppStorage(Retro.styleKey) private var stored = true
    @AppStorage(Look.scaleKey) private var size = Look.Size.normal.rawValue
    @AppStorage(Look.presetKey) private var preset = Look.Preset.dark.rawValue

    /// The size and the colours rebuild a window the same way the look does.
    func body(content: Content) -> some View {
        content.id("\(stored)-\(size)-\(preset)")
    }
}

extension View {
    /// Put this on the root of every window that draws kit pieces (the notch, the floating windows, Settings).
    func retroStyleRoot() -> some View { modifier(RetroStyleRoot()) }
}
