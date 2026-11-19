import AppKit
import SwiftUI

// Candidates for a new app icon.
// Three drawings, each a 1024 x 1024 macOS icon: the rounded square of the current icon (824 wide, 100 px margins,
// a soft shadow), smooth shapes for the body and the notch, crisp square pixels for the scout. The scout's pixels sit on a grid of 32 px
// (64 px in the third), so every Retina size of the icon (32, 64, 128, 256, 512, 1024 px) shows whole pixels.
// CANDIDATES ONLY: nothing here touches `Support/AppIcon.icns`, the asset catalog or `Info.plist`. The owner chooses first.
// Also here: three minimal menu-bar faces (one-colour template glyphs), candidates as well; the menu bar still shows the binoculars.
// Our own drawings. No image files.

/// The three candidates.
enum AppIconCandidate: String, CaseIterable, Identifiable {
    /// The open black island on an amber desktop, the whole scout standing inside in warm light.
    case nook
    /// The scout is the island: its face fills the notch, on a night-blue desktop.
    case island
    /// The dark body of today's icon with its small glowing notch, and a big scout that peeks up from the bottom edge.
    case peek

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nook: "1 · Nook"
        case .island: "2 · Island"
        case .peek: "3 · Peek"
        }
    }

    var idea: String {
        switch self {
        case .nook: "a scout at home in the open black island"
        case .island: "the scout is the notch: its face fills it"
        case .peek: "a scout peeks up at its glowing notch"
        }
    }
}

enum AppIconArt {
    /// The icon is drawn in a square of 1024 and scaled from there.
    static let canvas: CGFloat = 1024
    /// The rounded square: the macOS icon grid (824 of 1024, 100 px of air on every side for the shadow).
    static let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    /// One scout pixel in the 1024 square.
    static let cell: CGFloat = 32

    // MARK: Shapes

    /// The rounded square of a macOS icon (the same curve as the current icon: a superellipse).
    static func superellipse(_ rect: CGRect, exponent n: CGFloat = 5) -> Path {
        var path = Path()
        let a = rect.width / 2, b = rect.height / 2
        let steps = 720
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
            let c = cos(t), s = sin(t)
            let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
            let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        path.closeSubpath()
        return path
    }

    /// The notch: it hangs from above the icon down to `bottom`, with round lower corners (the body cuts its top).
    static func notch(left: CGFloat, right: CGFloat, bottom: CGFloat, radius: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: left, y: -400, width: right - left, height: bottom + 400), cornerRadius: radius, style: .continuous)
    }

    // MARK: Colours (fixed: an icon never follows a setting)

    static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    /// The scout's sand-orange.
    static let scoutTint = rgb(0.93, 0.55, 0.38)
    static let notchBlack = rgb(0.03, 0.03, 0.04)

    /// The scout's letters (the same as the den's) plus the few colours of the icon's room.
    static let palette: PixelPalette = {
        let t = scoutTint
        return PixelPalette(colors: [
            "o": Retro.shade(t, -0.78), "b": t, "s": Retro.shade(t, -0.26), "h": Retro.shade(t, 0.30),
            "c": rgb(0.98, 0.93, 0.80), "w": rgb(1, 1, 1), "k": rgb(0.10, 0.08, 0.12), "r": rgb(1.0, 0.56, 0.58),
            "l": rgb(0.78, 0.55, 0.33), "n": rgb(0.58, 0.38, 0.23), "m": rgb(0.30, 0.18, 0.12),
            "Y": rgb(1.0, 0.86, 0.36), "H": rgb(1.0, 0.96, 0.74), "N": rgb(0.09, 0.12, 0.30), "L": rgb(0.86, 0.90, 1.0),
        ])
    }()

    /// The same colours with a near-black outline (for a scout that stands in front of light).
    static let darkOutline: PixelPalette = {
        var p = palette
        p.colors["o"] = Retro.shade(scoutTint, -0.91)
        return p
    }()

    // MARK: Sprites (frozen copies: the icon does not change when the den's scouts do)

    /// The scout: a round body, a sprout, a cream neckerchief, big eyes, two feet. 16 x 16.
    static let scout = PixelSprite([
        "........ooo.....",
        ".......obbho....",
        "........oo......",
        "....oooooooo....",
        "..ohhhbbbbbbbo..",
        ".ohhbbbbbbbbbso.",
        ".obbwkbbbbwkbso.",
        ".obbkkbbbbkkbso.",
        ".obbkkbbbbkkbso.",
        ".obrbbbbbbbbrso.",
        ".obbbbbkkbbbbso.",
        ".occcccccccccco.",
        "..ossssccsssso..",
        "....oooooooo....",
        "...osso..osso...",
        "...oooo..oooo...",
    ])

    // MARK: Drawing

    /// Draws a candidate into a square of `side` points.
    static func draw(_ candidate: AppIconCandidate, in context: GraphicsContext, side: CGFloat) {
        var ctx = context
        ctx.scaleBy(x: side / canvas, y: side / canvas)
        switch candidate {
        case .nook: drawNook(&ctx)
        case .island: drawIsland(&ctx)
        case .peek: drawPeek(&ctx)
        }
    }

    /// The body: a soft shadow, the fill from `top` to `bottom`, the wallpaper, a hairline edge, then what stands in front.
    private static func body(_ ctx: inout GraphicsContext, top: Color, bottom: Color, edge: Color,
                             wallpaper: (inout GraphicsContext) -> Void = { _ in }, content: (inout GraphicsContext) -> Void) {
        let shape = superellipse(bodyRect)
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.34), radius: 14, x: 0, y: 14))
            layer.fill(shape, with: .color(bottom))
        }
        ctx.fill(shape, with: .linearGradient(Gradient(colors: [top, bottom]), startPoint: CGPoint(x: 512, y: bodyRect.minY), endPoint: CGPoint(x: 512, y: bodyRect.maxY)))
        var inner = ctx
        inner.clip(to: shape)
        wallpaper(&inner)
        inner.stroke(superellipse(bodyRect.insetBy(dx: 1.5, dy: 1.5)), with: .color(edge), lineWidth: 3)
        content(&inner)
    }

    private static func sprite(_ ctx: inout GraphicsContext, _ s: PixelSprite, x: CGFloat, y: CGFloat, px: CGFloat = cell) {
        AgentPixel.draw(s, in: &ctx, at: CGPoint(x: x * px, y: y * px), px: px, palette: palette)
    }

    private static func block(_ ctx: inout GraphicsContext, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, _ color: Color, px: CGFloat = cell) {
        ctx.fill(Path(CGRect(x: x * px, y: y * px, width: w * px, height: h * px)), with: .color(color))
    }

    private static func ink(_ letter: Character) -> Color { palette.color(letter) ?? .clear }

    // MARK: 1 · Nook

    /// An amber desktop with soft hills; the open island hangs from the top, black as the notch, and the scout stands in it on a wooden
    /// floor with warm light on the wall behind.
    private static func drawNook(_ ctx: inout GraphicsContext) {
        body(&ctx, top: rgb(1.0, 0.80, 0.34), bottom: rgb(1.0, 0.60, 0.20), edge: rgb(1, 1, 1, 0.22), wallpaper: { c in
            c.fill(Path(ellipseIn: CGRect(x: 330, y: 760, width: 900, height: 560)), with: .color(rgb(0.98, 0.50, 0.18, 0.55)))
            c.fill(Path(ellipseIn: CGRect(x: -180, y: 800, width: 860, height: 520)), with: .color(rgb(0.94, 0.42, 0.16, 0.60)))
        }, content: { c in
            // the island: 608 wide, down to row 23
            let island = notch(left: 208, right: 816, bottom: 736, radius: 96)
            c.fill(island, with: .color(notchBlack))
            var inside = c
            inside.clip(to: island)
            // warm light on the back wall, brightest behind the scout and gone before the island's edge
            inside.fill(Path(ellipseIn: CGRect(x: 112, y: 20, width: 800, height: 800)),
                        with: .radialGradient(Gradient(colors: [rgb(1.0, 0.58, 0.24, 0.52), rgb(1.0, 0.58, 0.24, 0.26), rgb(1.0, 0.58, 0.24, 0)]),
                                              center: CGPoint(x: 512, y: 430), startRadius: 0, endRadius: 400))
            block(&inside, x: 6, y: 21, w: 20, h: 1, ink("l"))
            block(&inside, x: 6, y: 22, w: 20, h: 1, ink("n"))
            // a darker outline here, so the scout stands clear of the light
            AgentPixel.draw(scout, in: &inside, at: CGPoint(x: 8 * cell, y: 6 * cell), px: cell, palette: darkOutline)
        })
    }

    // MARK: 2 · Island

    /// A night-blue desktop; the notch is a window that the scout's face fills (big eyes, cheeks, a small mouth).
    private static func drawIsland(_ ctx: inout GraphicsContext) {
        body(&ctx, top: rgb(0.33, 0.36, 0.90), bottom: rgb(0.15, 0.13, 0.46), edge: rgb(1, 1, 1, 0.20), wallpaper: { c in
            c.fill(Path(ellipseIn: CGRect(x: -140, y: 740, width: 1300, height: 620)), with: .color(rgb(0.46, 0.40, 0.95, 0.35)))
        }, content: { c in
            // No feet under the island any more.
            let frame = notch(left: 200, right: 824, bottom: 528, radius: 96)
            c.fill(frame, with: .color(notchBlack))
            var face = c
            face.clip(to: superellipse(bodyRect.insetBy(dx: 30, dy: 30)))
            face.clip(to: notch(left: 230, right: 794, bottom: 498, radius: 66))
            block(&face, x: 7, y: 3, w: 18, h: 13, ink("b"))
            block(&face, x: 8, y: 4, w: 5, h: 1, ink("h"))      // the highlight, top left
            block(&face, x: 8, y: 5, w: 2, h: 1, ink("h"))
            block(&face, x: 24, y: 3, w: 1, h: 13, ink("s"))    // the shaded side
            block(&face, x: 7, y: 14, w: 18, h: 2, ink("s"))    // and the chin
            for x in [CGFloat(10), 18] {
                block(&face, x: x, y: 7, w: 4, h: 5, ink("k"))  // an eye
                block(&face, x: x, y: 7, w: 2, h: 2, ink("w"))  // its spark
            }
            block(&face, x: 8, y: 12, w: 2, h: 1, ink("r"))
            block(&face, x: 22, y: 12, w: 2, h: 1, ink("r"))
            block(&face, x: 15, y: 13, w: 2, h: 1, ink("k"))
        })
    }

    // MARK: 3 · Peek

    /// Today's dark body and small notch with its amber glow, and a big scout that looks up from the bottom edge (pixels of 48).
    private static func drawPeek(_ ctx: inout GraphicsContext) {
        body(&ctx, top: rgb(0.15, 0.16, 0.20), bottom: rgb(0.06, 0.06, 0.08), edge: rgb(1, 1, 1, 0.17), wallpaper: { c in
            c.fill(Path(ellipseIn: CGRect(x: 30, y: -120, width: 640, height: 640)),
                   with: .radialGradient(Gradient(colors: [rgb(1, 1, 1, 0.10), rgb(1, 1, 1, 0)]), center: CGPoint(x: 350, y: 200), startRadius: 0, endRadius: 320))
        }, content: { c in
            // the notch and the thin amber glow under it
            let tab = notch(left: 372, right: 652, bottom: 190, radius: 36)
            c.drawLayer { layer in
                layer.addFilter(.shadow(color: rgb(1.0, 0.69, 0.13, 0.85), radius: 24, x: 0, y: 14))
                layer.fill(tab, with: .color(notchBlack))
            }
            c.fill(tab, with: .color(notchBlack))
            c.fill(Path(roundedRect: CGRect(x: 432, y: 204, width: 160, height: 6), cornerRadius: 3), with: .color(rgb(1.0, 0.69, 0.13, 0.80)))
            // the scout from its neckerchief up, 16 cells of 48 wide, cut by the bottom edge
            AgentPixel.draw(scout.droppingRows(12...15), in: &c, at: CGPoint(x: 128, y: 352), px: 48, palette: palette)
        })
    }
}

// MARK: - Bitmaps (the master at 1024 px, the small sizes scaled from it as an icon set is)

extension AppIconArt {
    @MainActor private static var bitmaps: [String: CGImage] = [:]

    /// The candidate as a bitmap of `pixels` x `pixels` with a clear background. 1024 and larger are drawn; a smaller one is the 1024
    /// master with every block of its pixels averaged into one, so a scout pixel that covers whole pixels stays a sharp square.
    @MainActor
    static func render(_ candidate: AppIconCandidate, pixels: Int) -> CGImage? {
        let key = "\(candidate.rawValue)-\(pixels)"
        if let hit = bitmaps[key] { return hit }
        var image: CGImage?
        if pixels >= Int(canvas) {
            let renderer = ImageRenderer(content: AppIconCanvas(candidate: candidate, side: canvas))
            renderer.scale = CGFloat(pixels) / canvas
            image = renderer.cgImage
        } else if let master = render(candidate, pixels: Int(canvas)) {
            image = Int(canvas) % pixels == 0 ? averaged(master, block: Int(canvas) / pixels) : scaled(master, to: pixels)
        }
        if let image { bitmaps[key] = image }
        return image
    }

    /// Every `block` x `block` pixels of `image` become one: their plain average.
    private static func averaged(_ image: CGImage, block: Int) -> CGImage? {
        let w = image.width, h = image.height, ow = w / block, oh = h / block
        guard block > 0, ow > 0, oh > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        var src = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = src.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: info) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var dst = [UInt8](repeating: 0, count: ow * oh * 4)
        let count = block * block
        for y in 0..<oh {
            for x in 0..<ow {
                var sum = [0, 0, 0, 0]
                for by in 0..<block {
                    let start = ((y * block + by) * w + x * block) * 4
                    for bx in 0..<block {
                        for c in 0..<4 { sum[c] += Int(src[start + bx * 4 + c]) }
                    }
                }
                for c in 0..<4 { dst[(y * ow + x) * 4 + c] = UInt8((sum[c] + count / 2) / count) }
            }
        }
        guard let provider = CGDataProvider(data: Data(dst) as CFData) else { return nil }
        return CGImage(width: ow, height: oh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: ow * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// A bitmap of `pixels` x `pixels` shown `factor` times larger, every pixel a sharp square (to judge the small sizes).
    @MainActor
    static func enlarged(_ candidate: AppIconCandidate, pixels: Int, factor: Int) -> CGImage? {
        let key = "\(candidate.rawValue)-\(pixels)x\(factor)"
        if let hit = bitmaps[key] { return hit }
        guard let small = render(candidate, pixels: pixels), let image = scaled(small, to: pixels * factor, quality: .none) else { return nil }
        bitmaps[key] = image
        return image
    }

    private static func scaled(_ image: CGImage, to pixels: Int, quality: CGInterpolationQuality = .high) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = quality
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return ctx.makeImage()
    }
}

/// A candidate drawn live (the master picture: `AppIconArt.render` takes its bitmap from this).
struct AppIconCanvas: View {
    var candidate: AppIconCandidate
    var side: CGFloat = AppIconArt.canvas

    var body: some View {
        Canvas { ctx, size in
            AppIconArt.draw(candidate, in: ctx, side: min(size.width, size.height))
        }
        .frame(width: side, height: side)
    }
}

/// A candidate as a picture of `pixels` x `pixels`, shown in a square of `side` points with every pixel left as it is.
struct AppIconPicture: View {
    var candidate: AppIconCandidate
    var side: CGFloat
    var pixels: Int
    /// Above 1: the bitmap is enlarged this many times with sharp pixels first.
    var zoom = 1

    var body: some View {
        Group {
            if let image = zoom > 1 ? AppIconArt.enlarged(candidate, pixels: pixels, factor: zoom) : AppIconArt.render(candidate, pixels: pixels) {
                Image(decorative: image, scale: 1).interpolation(.none).resizable()
            } else {
                Color.red
            }
        }
        .frame(width: side, height: side)
    }
}

// MARK: - Menu-bar faces (candidates for the menu-bar item: one colour, the system tints it)

/// Three minimal faces for the menu bar.
enum MenuBarFace: String, CaseIterable, Identifiable {
    /// The scout's square face as the notch's wings show it, solid, with its eyes and mouth cut out.
    case face
    /// The scout drawn as a thin line: round head, sprout, two eyes, a mouth.
    case sprout
    /// The notch with big eyes and two feet: the island that is a scout.
    case island

    var id: String { rawValue }

    var title: String {
        switch self {
        case .face: "A · Face"
        case .sprout: "B · Sprout"
        case .island: "C · Island"
        }
    }

    /// The glyph; "k" is ink, "." is clear.
    var sprite: PixelSprite {
        switch self {
        case .face:
            PixelSprite([
                "..kkkkkkkk..",
                ".kkkkkkkkkk.",
                "kkkkkkkkkkkk",
                "kkkkkkkkkkkk",
                "kkk..kk..kkk",
                "kkk..kk..kkk",
                "kkk..kk..kkk",
                "kkkkkkkkkkkk",
                "kkkkk..kkkkk",
                "kkkkkkkkkkkk",
                ".kkkkkkkkkk.",
                "..kkkkkkkk..",
            ])
        case .sprout:
            PixelSprite([
                "........kk......",
                ".......kkk......",
                ".......k........",
                "...kkkkkkkkkk...",
                "..k..........k..",
                ".k............k.",
                ".k..kk....kk..k.",
                ".k..kk....kk..k.",
                ".k..kk....kk..k.",
                ".k............k.",
                ".k.....kk.....k.",
                ".k............k.",
                "..k..........k..",
                "...kkkkkkkkkk...",
            ])
        case .island:
            PixelSprite([
                "kkkkkkkkkkkkkkkk",
                "kkkkkkkkkkkkkkkk",
                "kkkk..kkkk..kkkk",
                "kkkk..kkkk..kkkk",
                "kkkk..kkkk..kkkk",
                "kkkkkkkkkkkkkkkk",
                "kkkkkkk..kkkkkkk",
                "kkkkkkkkkkkkkkkk",
                ".kkkkkkkkkkkkkk.",
                "..kkkkkkkkkkkk..",
                "....kk....kk....",
                "....kk....kk....",
            ])
        }
    }

    /// One cell in points (1.5 pt and 1 pt both land on whole device pixels at 2x).
    var px: CGFloat { self == .face ? 1.5 : 1 }

    var size: CGSize { CGSize(width: CGFloat(sprite.width) * px, height: CGFloat(sprite.height) * px) }

    /// The face as a template image for an `NSStatusItem` button (macOS tints it for the light and the dark menu bar).
    var image: NSImage {
        let sprite = sprite, px = px
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            for (r, row) in sprite.rows.enumerated() {
                for (c, ch) in row.enumerated() where ch != "." {
                    NSRect(x: CGFloat(c) * px, y: CGFloat(r) * px, width: px, height: px).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// A menu-bar face drawn in one colour, `zoom` times its size.
struct MenuBarFaceGlyph: View {
    var face: MenuBarFace
    var color: Color
    var zoom: CGFloat = 1

    var body: some View {
        let sprite = face.sprite, px = face.px * zoom
        Canvas { ctx, _ in
            var path = Path()
            for (r, row) in sprite.rows.enumerated() {
                for (c, ch) in row.enumerated() where ch != "." {
                    path.addRect(CGRect(x: CGFloat(c) * px, y: CGFloat(r) * px, width: px, height: px))
                }
            }
            ctx.fill(path, with: .color(color))
        }
        .frame(width: face.size.width * zoom, height: face.size.height * zoom)
    }
}

// MARK: - Pictures

/// A plain desktop to judge an icon on: light or dark with the scene.
private struct AppIconDesk<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            LinearGradient(colors: scheme == .dark
                           ? [AppIconArt.rgb(0.17, 0.18, 0.22), AppIconArt.rgb(0.08, 0.09, 0.11)]
                           : [AppIconArt.rgb(0.93, 0.94, 0.96), AppIconArt.rgb(0.80, 0.84, 0.90)],
                           startPoint: .top, endPoint: .bottom)
            content()
        }
    }
}

/// The three candidates side by side at 512, 128, 32 and 16 points (as a Retina screen shows them: twice the pixels), and the two
/// smallest bitmaps enlarged so every pixel can be judged.
private struct AppIconSheet: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        AppIconDesk {
            HStack(alignment: .top, spacing: 48) {
                ForEach(AppIconCandidate.allCases) { candidate in
                    VStack(spacing: 0) {
                        label(candidate.title, size: 22, weight: .bold).frame(height: 34)
                        label(candidate.idea, size: 13, weight: .regular).frame(height: 22)
                        AppIconPicture(candidate: candidate, side: 512, pixels: 1024)
                        label("512", size: 12, weight: .medium).frame(height: 22)
                        HStack(alignment: .bottom, spacing: 32) {
                            sized(candidate, 128)
                            sized(candidate, 32)
                            sized(candidate, 16)
                        }
                        .frame(height: 156)
                        HStack(alignment: .bottom, spacing: 32) {
                            zoomed(candidate, pixels: 32, note: "16 pt at 2x, enlarged")
                            zoomed(candidate, pixels: 16, note: "16 px at 1x, enlarged")
                        }
                        .frame(height: 190)
                    }
                    .frame(width: 512)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 20)
            label("Sizes in points, drawn as a Retina screen shows them (twice the pixels). The last row enlarges the two smallest bitmaps.", size: 12, weight: .regular)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 16)
        }
    }

    private func sized(_ candidate: AppIconCandidate, _ points: CGFloat) -> some View {
        VStack(spacing: 0) {
            AppIconPicture(candidate: candidate, side: points, pixels: Int(points) * 2)
            label("\(Int(points))", size: 12, weight: .medium).frame(height: 22)
        }
    }

    private func zoomed(_ candidate: AppIconCandidate, pixels: Int, note: String) -> some View {
        VStack(spacing: 0) {
            AppIconPicture(candidate: candidate, side: 160, pixels: pixels, zoom: 320 / pixels)
            label(note, size: 12, weight: .medium).frame(height: 22)
        }
    }

    private func label(_ text: String, size: CGFloat, weight: Font.Weight) -> some View {
        Text(text).font(.system(size: size, weight: weight)).foregroundStyle(scheme == .dark ? Color.white.opacity(0.82) : Color.black.opacity(0.72))
    }
}

/// The three menu-bar faces in a menu bar at their real size (between the usual neighbours) and enlarged.
private struct MenuBarFaceSheet: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = scheme == .dark ? Color.white : Color.black
        AppIconDesk {
            VStack(alignment: .leading, spacing: 26) {
                ForEach(MenuBarFace.allCases) { face in
                    HStack(spacing: 28) {
                        Text(face.title).font(.system(size: 15, weight: .bold)).foregroundStyle(ink.opacity(0.8)).frame(width: 96, alignment: .leading)
                        MenuBarFaceGlyph(face: face, color: ink, zoom: 6).frame(width: 120, height: 110)
                        bar(face, ink: ink)
                    }
                }
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// A stretch of menu bar, 24 pt tall: the face between the things that usually sit there.
    private func bar(_ face: MenuBarFace, ink: Color) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "wifi").font(.system(size: 14, weight: .medium))
            MenuBarFaceGlyph(face: face, color: ink)
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium))
            Image(systemName: "switch.2").font(.system(size: 13, weight: .medium))
            Text("Mon 16 Nov  9:41").font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 16)
        .frame(height: 24)
        .background(scheme == .dark ? AppIconArt.rgb(0.13, 0.13, 0.15) : AppIconArt.rgb(0.95, 0.95, 0.96))
    }
}

/// Gallery: `appicon-peek`, `appicon-nook`, `appicon-island` (1024 each), `appicon-sheet` (every size), `appicon-menubar` (the faces).
@MainActor
enum AppIconGallery {
    static func register() {
        for candidate in AppIconCandidate.allCases {
            Gallery.register("appicon-\(candidate.rawValue)", size: CGSize(width: 1024, height: 1024)) {
                AppIconDesk { AppIconPicture(candidate: candidate, side: 1024, pixels: 2048) }
            }
        }
        Gallery.register("appicon-sheet", size: CGSize(width: 1760, height: 1010)) { AppIconSheet() }
        Gallery.register("appicon-menubar", size: CGSize(width: 640, height: 440)) { MenuBarFaceSheet() }
    }
}

// MARK: - The app icon in use: Island

/// The icon the app ships with, and the menu-bar face it shows.
@MainActor
enum AppIconInUse {
    static let app: AppIconCandidate = .island
    static let menuBar: MenuBarFace = .face

    /// The menu-bar icon: the agent face's square outline and its two eyes, nothing filled.
    /// A template: the menu bar draws it in its own colour.
    static let menuBarSprite = PixelSprite([
        "..oooooooo..",
        ".o........o.",
        "o..........o",
        "o..........o",
        "o..kk..kk..o",
        "o..kk..kk..o",
        "o..kk..kk..o",
        "o..........o",
        "o..........o",
        "o..........o",
        ".o........o.",
        "..oooooooo..",
    ])
    /// Every drawn cell is ink (the outline and the eyes).
    static func isInk(_ ch: Character) -> Bool { ch == "o" || ch == "k" }
    static let menuBarCell: CGFloat = 1.5   // 12 cells = 18 pt, three device pixels a cell at 2x

    static var menuBarImage: NSImage {
        let sprite = menuBarSprite, px = menuBarCell
        let image = NSImage(size: NSSize(width: CGFloat(sprite.width) * px, height: CGFloat(sprite.height) * px), flipped: true) { _ in
            for (r, row) in sprite.rows.enumerated() {
                for (c, ch) in row.enumerated() where ch != "." {
                    guard isInk(ch) else { continue }
                    NSColor.black.setFill()
                    NSRect(x: CGFloat(c) * px, y: CGFloat(r) * px, width: px, height: px).fill()
                }
            }
            return true
        }
        image.isTemplate = true   // the menu bar tints it: black on a light bar, white on a dark one
        return image
    }

    /// `scout://icon.export?dir=<folder>&out=<file>` (automation only): writes the app icon at every macOS size, named as the asset catalog
    /// names them (icon_16x16.png … icon_512x512@2x.png); `scripts/export-icon.sh` turns them into Support/AppIcon.icns and the catalog.
    static func register() {
        DebugCommands.register("icon.export") { params in
            guard ScoutRuntime.isAutomation, let dir = params["dir"].map({ URL(fileURLWithPath: $0) }) else { return }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? dir.appendingPathComponent("export.txt")
            Task { @MainActor in export(to: dir, out: out) }
        }
    }

    private static func export(to dir: URL, out: URL) {
        do {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var lines: [String] = []
            for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                guard let image = AppIconArt.render(app, pixels: points * scale) else { lines.append("FAIL \(name)"); continue }
                let rep = NSBitmapImageRep(cgImage: image)
                if let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: dir.appendingPathComponent(name))) != nil {
                    lines.append("ok \(name) \(image.width)x\(image.height)")
                } else {
                    lines.append("FAIL \(name)")
                }
            }
            lines.append("icon.export done")
            try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        }
    }
}

/// The menu bar's agent face (the outline and two eyes) as a view (the tour's last page, the pictures' mock menu bar), `zoom` times its size.
struct AgentFaceMark: View {
    var zoom: CGFloat = 1
    var color: Color = .primary

    var body: some View {
        let sprite = AppIconInUse.menuBarSprite, px = AppIconInUse.menuBarCell * zoom
        Canvas { ctx, _ in
            for (r, row) in sprite.rows.enumerated() {
                for (c, ch) in row.enumerated() where AppIconInUse.isInk(ch) {
                    ctx.fill(Path(CGRect(x: CGFloat(c) * px, y: CGFloat(r) * px, width: px, height: px)), with: .color(color))
                }
            }
        }
        .frame(width: CGFloat(sprite.width) * px, height: CGFloat(sprite.height) * px)
        .accessibilityHidden(true)
    }
}
