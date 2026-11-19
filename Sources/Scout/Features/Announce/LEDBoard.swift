import AppKit
import SwiftUI

// The board itself: a grid of round LEDs drawn in a Canvas. Lit dots are the message's colour with a soft glow, unlit dots stay
// faintly visible like a real LED sign. Every size follows the dot pitch, so the same view draws the tiny closed-notch wing
// (pitch 2.65 pt, about 18 pt for the seven rows) and the big pictures the gallery judges the look with.

enum LEDStyle {
    /// Dot pitch in the closed notch: 41 columns (seven letters) are 108 pt, the most a wing can hold.
    static let wingPitch: CGFloat = 2.65
    /// Fixed height of the board in a wing (seven rows plus room for the glow).
    static let wingHeight: CGFloat = 22
    /// The sign frame's plastic: a little lighter than black, so its edge shows on the notch.
    static var signPlastic: Color { Retro.shade(Retro.Ink.plasticMid, -0.50) }
    /// The plastic ring around the dots' black plate.
    static let signRing: CGFloat = 1.1

    /// The sign frame's outer size for a board of `columns` columns: the dots keep the wing pitch (so the letters keep their size), the
    /// frame adds a ring and a little air at each side, and its height is the wing's.
    static func signSize(columns: Int, pitch: CGFloat = wingPitch) -> CGSize {
        CGSize(width: CGFloat(columns) * pitch + 2 * signAir + 2 * signRing, height: wingHeight)
    }

    /// The room the black plate gives the dots, top to bottom.
    static var signPlateHeight: CGFloat { wingHeight - 2 * signRing }

    /// The most a wing can take beside the notch: the leading padding (10) is already taken off 130.
    static let wingRoom: CGFloat = 120
    /// Air between the dots and the frame at each side.
    static let signAir: CGFloat = 3.2
}

struct LEDBoardView: View {
    var frame: LEDFrame
    var tint: Color
    var pitch: CGFloat = LEDStyle.wingPitch
    /// A dark board behind the dots (the gallery's big pictures); the closed notch's wing is already black.
    var plate = false

    private var columns: Int { frame.columns.count }
    /// The dots' own area; the glow is drawn a little beyond it.
    private var area: CGSize { CGSize(width: CGFloat(columns) * pitch, height: CGFloat(LEDFont.rows) * pitch) }
    private var margin: CGFloat { max(2, pitch * 0.9) }

    var body: some View {
        Canvas { ctx, size in
            draw(ctx, size: size)
        }
        .frame(width: area.width + 2 * margin, height: area.height + 2 * margin)
        .padding(-margin)   // the glow may bleed outside; the layout is just the dots
        .frame(width: area.width, height: area.height)
        .allowsHitTesting(false)
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize) {
        let diameter = pitch * 0.74
        let origin = CGPoint(x: margin, y: margin)
        let dark = Color(red: 0.05, green: 0.05, blue: 0.06)
        if plate {
            let r = RoundedRectangle(cornerRadius: pitch * 1.4, style: .continuous)
            ctx.fill(r.path(in: CGRect(x: margin - pitch * 0.9, y: margin - pitch * 0.9, width: area.width + pitch * 1.8, height: area.height + pitch * 1.8)),
                     with: .color(dark))
        }
        // Unlit dots first, then the glows, then the lit cores on top.
        for c in 0..<columns {
            let col = frame.columns[c]
            for r in 0..<LEDFont.rows {
                let centre = CGPoint(x: origin.x + (CGFloat(c) + 0.5) * pitch, y: origin.y + (CGFloat(r) + 0.5) * pitch)
                if !col.isLit(row: r) {
                    let d = diameter * 0.82
                    ctx.fill(Path(ellipseIn: CGRect(x: centre.x - d / 2, y: centre.y - d / 2, width: d, height: d)), with: .color(tint.opacity(0.17)))
                }
            }
        }
        for c in 0..<columns {
            let col = frame.columns[c]
            guard col.bits != 0 else { continue }
            let colour = col.accent.color ?? tint
            let hot = frame.hot == c
            for r in 0..<LEDFont.rows where col.isLit(row: r) {
                let centre = CGPoint(x: origin.x + (CGFloat(c) + 0.5) * pitch, y: origin.y + (CGFloat(r) + 0.5) * pitch)
                let reach = pitch * (hot ? 1.6 : 1.3)
                ctx.fill(Path(ellipseIn: CGRect(x: centre.x - reach, y: centre.y - reach, width: reach * 2, height: reach * 2)),
                         with: .radialGradient(Gradient(colors: [colour.opacity(hot ? 0.5 : 0.36), colour.opacity(0)]), center: centre, startRadius: 0, endRadius: reach))
            }
        }
        for c in 0..<columns {
            let col = frame.columns[c]
            guard col.bits != 0 else { continue }
            let colour = col.accent.color ?? tint
            let hot = frame.hot == c
            for r in 0..<LEDFont.rows where col.isLit(row: r) {
                let centre = CGPoint(x: origin.x + (CGFloat(c) + 0.5) * pitch, y: origin.y + (CGFloat(r) + 0.5) * pitch)
                let d = diameter
                let rect = CGRect(x: centre.x - d / 2, y: centre.y - d / 2, width: d, height: d)
                let core = hot ? colour.mix(with: .white, 0.6) : colour
                ctx.fill(Path(ellipseIn: rect), with: .radialGradient(Gradient(colors: [Color.white.opacity(hot ? 0.9 : 0.55), core]),
                                                                       center: CGPoint(x: centre.x - d * 0.12, y: centre.y - d * 0.14), startRadius: 0, endRadius: d * 0.62))
            }
        }
    }
}

/// One message playing: the schedule, when it began, the colour. `frozenAt` draws one still frame (galleries and tests).
struct LEDPlayback: Equatable {
    var schedule: LEDSchedule
    var start: Date
    var tint: Color
    var frozenAt: Double?

    func frame(at date: Date) -> LEDFrame { schedule.frame(at: frozenAt ?? date.timeIntervalSince(start)) }
}

/// The board with its clock. It draws a timeline ONLY for a message that is playing (the activity is posted when the message
/// starts and goes away when it ends), so there is nothing ticking while the notch shows nothing.
struct LEDPlaybackView: View {
    let playback: LEDPlayback
    var pitch: CGFloat = LEDStyle.wingPitch
    var plate = false

    var body: some View {
        if playback.frozenAt != nil {
            LEDBoardView(frame: playback.frame(at: playback.start), tint: playback.tint, pitch: pitch, plate: plate)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                LEDBoardView(frame: playback.frame(at: ctx.date), tint: playback.tint, pitch: pitch, plate: plate)
            }
        }
    }
}

/// Left wing: the board on the notch's black, with no border. It is the wing's height, so the letters keep their size:
/// seven rows of 2.65 pt dots plus a little air above and below.
struct LEDWingLeft: View {
    let playback: LEDPlayback

    var body: some View {
        LEDSignFrame { LEDPlaybackView(playback: playback) }
    }
}

/// The board's place in the wing: no plastic frame and no plate any more;
/// the dots stand straight on the notch's black. The size is the old frame's (`LEDStyle.signSize`), so the
/// wing and the letters keep their room. Its height is `LEDStyle.wingHeight`; the sides are a few points wider than the dots.
struct LEDSignFrame<Board: View>: View {
    @ViewBuilder var board: () -> Board

    var body: some View {
        board()
            .padding(.horizontal, LEDStyle.signAir)
            .frame(height: LEDStyle.wingHeight - 2 * LEDStyle.signRing)
            .padding(LEDStyle.signRing)
    }
}

/// Right wing: something small that fits the message (the agent kind's glyph), or nothing.
struct LEDWingRight: View {
    var symbol: String?
    var tint: Color

    var body: some View {
        if let symbol {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .shadow(color: tint.opacity(0.55), radius: 3)
                .frame(width: 22, height: 22)
        } else {
            EmptyView()
        }
    }
}

private extension Color {
    /// This colour with `amount` (0...1) of `other` mixed in.
    func mix(with other: Color, _ amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .white
        func lerp(_ x: CGFloat, _ y: CGFloat) -> Double { Double(x + (y - x) * CGFloat(amount)) }
        return Color(.sRGB, red: lerp(a.redComponent, b.redComponent), green: lerp(a.greenComponent, b.greenComponent), blue: lerp(a.blueComponent, b.blueComponent))
    }
}
