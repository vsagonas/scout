import AppKit
import SwiftUI

/// Colours and small helpers shared by every AgentNook drawing.
enum AgentNookInk {
    static let eye = Color(red: 0.14, green: 0.10, blue: 0.10)
    static let cream = Color(red: 0.98, green: 0.94, blue: 0.84)
    static let wood = Color(red: 0.50, green: 0.35, blue: 0.24)
    static let woodDark = Color(red: 0.32, green: 0.22, blue: 0.16)
    static let amber = Color(red: 1.0, green: 0.69, blue: 0.13)
    static let green = Color(red: 0.36, green: 0.82, blue: 0.52)
    static let red = Color(red: 0.96, green: 0.40, blue: 0.38)
    static let gold = Color(red: 1.0, green: 0.86, blue: 0.40)
    static let blush = Color(red: 1.0, green: 0.62, blue: 0.60)

    /// Lighter (amount > 0, toward white) or darker (amount < 0, toward black).
    static func shade(_ color: Color, _ amount: Double) -> Color { Retro.shade(color, amount) }
}

/// What moves, and when: seconds since some moment (nil = a still picture, which every state must read in), and whether the
/// Mac allows movement. With Reduce Motion ON nothing moves, lamps and lights only fade; with it off the scout has a second frame
/// (a bob, typing hands, a wave) and blinks now and then.
struct AgentNookClock: Equatable {
    var t: Double?
    var motion: Bool

    static let still = AgentNookClock(t: nil, motion: false)
    /// The same clock moved on by `seconds`: each agent's figure runs on its own time (`AgentFaceArt.phase(for:)`), so they never move in step.
    func shifted(_ seconds: Double) -> AgentNookClock { AgentNookClock(t: t.map { $0 + seconds }, motion: motion) }

    /// This moment of a big figure's face (nil in a still picture): the step on the wing's own beat, 0.2 s, and 0.4 s while Reduce Motion is
    /// on (the small faces keep moving then too, slower); `burst` says the couple of seconds after something happened are not over.
    /// A shifted clock gives each agent its own start, the same as its wing's face.
    func faceStep(burst: Bool) -> AgentFaceStep? {
        t.map { AgentFaceStep(tick: AgentFaceArt.tick(at: $0, calm: !motion), burst: burst) }
    }

    /// 0...1, a slow sine; `still` while there is no time. This is what fades lamps and lights under Reduce Motion.
    func pulse(period: Double, phase: Double = 0, still: Double = 1) -> Double {
        guard let t else { return still }
        return (sin(2 * .pi * (t / period + phase)) + 1) / 2
    }

    /// 0 or 1: which of the two frames of the pixel animation. Always 0 under Reduce Motion and in a still picture.
    func frame(period: Double = 0.5, phase: Double = 0) -> Int {
        guard motion, let t else { return 0 }
        return Int(floor(t / period + phase)) & 1
    }

    /// Eyes shut for a moment every few seconds (never under Reduce Motion).
    func blinking(phase: Double = 0) -> Bool {
        guard motion, let t else { return false }
        let p = (t + phase).truncatingRemainder(dividingBy: 4.4)
        return p > 4.22
    }
}

/// The scout: a small round creature in its kind's colour, in 8-bit pixels. One picture per state, each readable in a still frame:
/// at a chunky pixel computer with the step's prop on its screen; a hand up and a "?" bubble; happy eyes and a check mark;
/// dizzy eyes and a plaster; asleep with Z's. It fills its frame with whole pixels (a multiple of half a point each).
struct AgentNookCritter: View {
    var kind: AgentKind
    /// Its own face, like in the wing (`AgentFaceArt.variants`): its skin and its headwear (the head is that face); two agents never look the same.
    var variant = 0
    var pose: AgentNookLook.Pose
    var prop: AgentNookProp?
    var clock: AgentNookClock = .still
    /// Draws the desk, the computer and the beanbag; false is the scout alone.
    var furniture = true
    /// Kept for the compact rooms (the pictures are already tight).
    var crop = false
    /// One pixel in points, chosen for the whole screen (every scout of a screen is the same size); nil fits the frame.
    var pixel: CGFloat?

    static func look(of pose: AgentNookLook.Pose) -> AgentNookLook {
        switch pose {
        case .typing: .working
        case .doorWave: .needsYou
        case .holdingCheck: .finished
        case .dizzy: .stopped
        case .asleep: .idle
        }
    }

    /// The picture for a look at a moment of the clock.
    /// `burst`: the couple of seconds after the look began, when the face moves its mouth (asks, laughs, goes dizzy).
    static func picture(look: AgentNookLook, prop: AgentNookProp?, clock: AgentNookClock, furniture: Bool = true, variant: Int = 0, burst: Bool = false) -> PixelPicture {
        AgentPixelWorld.picture(look: look, prop: prop, frame: clock.frame(), blink: clock.blinking(), furniture: furniture, variant: variant,
                                face: clock.faceStep(burst: burst))
    }

    /// True for the couple of seconds after the pose began (the room appears or the agent's state changes), like the wing's face.
    @State private var burst = true

    var body: some View {
        let pic = Self.picture(look: Self.look(of: pose), prop: prop, clock: clock, furniture: furniture, variant: variant, burst: burst)
        let palette = PixelPalette.face(kind, variant: variant)
        Canvas { ctx, size in
            let fit = AgentPixel.size(grid: (pic.w, pic.h), in: size)
            let px = pixel.map { min($0, fit) } ?? fit
            let origin = CGPoint(x: (((size.width - CGFloat(pic.w) * px) / 2) * 2).rounded(.down) / 2,
                                 y: (((size.height - CGFloat(pic.h) * px)) * 2).rounded(.down) / 2)   // standing on the floor of its frame
            var c = ctx
            pic.draw(&c, origin: origin, px: px, palette: palette)
        }
        .aspectRatio(CGFloat(pic.w) / CGFloat(pic.h), contentMode: .fit)
        .task(id: pose) {
            burst = true
            try? await Task.sleep(nanoseconds: UInt64(AgentFaceArt.burstSeconds * 1_000_000_000))
            if !Task.isCancelled { burst = false }
        }
        .accessibilityHidden(true)
    }
}

/// One prop alone, large (the gallery's judging sheet and the tests).
struct AgentNookPropView: View {
    var prop: AgentNookProp
    var kind: AgentKind = .claude

    var body: some View {
        Canvas { ctx, size in
            let px = AgentPixel.size(grid: (8, 8), in: size, highest: 16)
            let side = 8 * px
            var c = ctx
            AgentPixel.draw(AgentPixelSprites.prop(prop), in: &c, at: CGPoint(x: ((size.width - side) / 2 * 2).rounded(.down) / 2, y: ((size.height - side) / 2 * 2).rounded(.down) / 2),
                            px: px, palette: .world(kind))
        }
        .accessibilityHidden(true)
    }
}
