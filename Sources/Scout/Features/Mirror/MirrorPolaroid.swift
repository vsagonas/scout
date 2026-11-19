import AppKit
import SwiftUI

// The Mirror's Share key makes a polaroid: a white instant-photo frame with a thick bottom margin, the person's picture in the square, the
// agents' pixel faces standing along the bottom edge of the picture (each with its project name in small pixel capitals; with no agents,
// the app's own face mark), and on the white margin the app's name, "me and my agents" and the App Store link
// The card is plain SwiftUI drawn at a fixed size and turned into an image by ImageRenderer at 2x. Nothing here touches the camera: the
// picture is handed in (the Mirror's own still, already flipped and zoomed as the viewfinder shows it).

/// One agent on the polaroid: who it is and how its face looks.
struct PolaroidAgent: Identifiable, Equatable {
    var id: String
    /// The project's name (the folder), shown in pixel capitals.
    var project: String
    var kind: AgentKind
    var mood: AgentFaceMood
    /// Which of the faces this agent wears (`AgentFaceArt.variants`).
    var variant: Int
}

enum MirrorPolaroid {
    // MARK: What is on it

    static let appName = "Scout"
    /// Drawn in the pixel font: the translation when the font has every letter of it, else the English words.
    static let tagline: String = {
        let words = String(localized: "me and my agents")
        return Dash90.pixelSafe(words) ? words : "me and my agents"
    }()
    /// The short link to Scout's page; the share text carries it too.
    static let appLink = "https://apps.v-sag.com/scout"
    /// The same link as printed on the card, without the scheme.
    static let printedLink = "apps.v-sag.com/scout"
    /// The words that go with the picture in the share sheet.
    static let shareText = String(localized: "Scout: my AI agents in my notch. \(appLink)")
    /// How many agents stand on the picture.
    static let maxAgents = 6

    // MARK: Size (points; the image is twice as many pixels)

    static let width: CGFloat = 360
    static let side: CGFloat = 18
    static let top: CGFloat = 18
    static let photo: CGFloat = 324
    static let bottom: CGFloat = 108
    static var height: CGFloat { top + photo + bottom }
    static var size: CGSize { CGSize(width: width, height: height) }
    static let scale: CGFloat = 2

    /// The picture's square, in the card's top-left coordinates.
    static var photoRect: CGRect { CGRect(x: side, y: top, width: photo, height: photo) }

    /// The paper: a white that is not quite pure, like instant film.
    static let paper = Color(red: 0.985, green: 0.985, blue: 0.98)
    static let ink = Color(red: 0.14, green: 0.14, blue: 0.17)
    static let softInk = Color(red: 0.42, green: 0.42, blue: 0.46)

    // MARK: Where the faces stand

    /// A face is 12 pixel cells wide: 4 pt a cell for up to three agents, 3 pt for more.
    static func cell(count: Int) -> CGFloat { count <= 3 ? 4 : 3 }
    static func faceSide(count: Int) -> CGFloat { CGFloat(AgentFaceArt.cells) * cell(count: count) }
    /// The room one agent gets along the bottom edge, and how many letters of its name fit in it (a pixel letter is 6 pt wide).
    static func slot(count: Int) -> CGFloat { count <= 3 ? 84 : 50 }
    static func nameLetters(count: Int) -> Int { Int((slot(count: count) - 4) / 6) }
    /// The space between the last line of names and the picture's bottom edge.
    static let edgeGap: CGFloat = 11

    /// The faces' boxes in the card's top-left coordinates (the row is centred; its names sit under the faces, over the picture's bottom edge).
    static func faceRects(count: Int) -> [CGRect] {
        guard count > 0 else { return [] }
        let n = min(count, maxAgents)
        let face = faceSide(count: n)
        let rowWidth = CGFloat(n) * slot(count: n)
        let x0 = photoRect.midX - rowWidth / 2
        let y = photoRect.maxY - edgeGap - nameHeight - nameGap - face
        return (0..<n).map { CGRect(x: x0 + (CGFloat($0) + 0.5) * slot(count: n) - face / 2, y: y, width: face, height: face) }
    }

    static let nameGap: CGFloat = 5
    /// A name is seven pixel rows plus the one-pixel outline on both sides.
    static let nameHeight: CGFloat = 9

    /// The name as it fits under its face: capitals, cut with a full stop when too long.
    static func label(_ project: String, count: Int) -> String {
        let letters = nameLetters(count: count)
        let name = project.trimmingCharacters(in: .whitespaces).uppercased()
        guard name.count > letters else { return name }
        return String(name.prefix(max(1, letters - 1))) + "."
    }

    /// The agents that stand on the picture: those the notch shows (in its fixed order; with more than fit, the ones that need you).
    static func agents(sessions: [AgentSession]) -> [PolaroidAgent] {
        let ordered = AgentTileMetrics.ordered(sessions)
        let shown = AgentTileMetrics.keepOrder(ordered, limit: maxAgents) { AgentTileMetrics.urgency($0) }
        let variants = AgentFaceArt.variants(for: sessions.map(\.id))
        return shown.map { s in
            PolaroidAgent(id: s.id, project: s.project, kind: s.agent, mood: AgentFaceMood(AgentNookLook.of(s)), variant: variants[s.id] ?? 0)
        }
    }

    // MARK: Making the image

    /// The polaroid as an image: `photo` is the picture exactly as the Mirror shows it (already mirrored and zoomed); the card takes the
    /// square from its middle. Nil when the renderer gives nothing.
    @MainActor
    static func render(photo picture: CGImage, agents: [PolaroidAgent]) -> CGImage? {
        render(agents: agents) { Image(decorative: picture, scale: 1).resizable().aspectRatio(contentMode: .fill) }
    }

    @MainActor
    static func render<Photo: View>(agents: [PolaroidAgent], @ViewBuilder photo: () -> Photo) -> CGImage? {
        let picture = photo()
        let renderer = ImageRenderer(content: MirrorPolaroidCard(agents: agents) { picture })
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(size)
        return renderer.cgImage
    }

    /// The image the share sheet gets: the polaroid at its size in points (720 x 900 pixels).
    @MainActor
    static func image(photo picture: CGImage, agents: [PolaroidAgent]) -> NSImage? {
        guard let cg = render(photo: picture, agents: agents) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: size.width, height: size.height))
    }

    /// PNG bytes of an image (what Save writes).
    static func pngData(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// The name Save suggests: "Scout polaroid 2026-11-16.png".
    static func fileName(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "Scout polaroid \(f.string(from: date)).png"
    }

    // MARK: Sample data (the gallery and the tests; never a real camera frame, never real agents)

    /// A drawn picture of a person (the Mirror's stand-in, 16:9) as an image.
    @MainActor
    static func samplePhoto() -> CGImage? {
        let renderer = ImageRenderer(content: MirrorStandIn().frame(width: 640, height: 360))
        renderer.scale = 1
        return renderer.cgImage
    }

    /// Up to six made-up agents with fixed faces (the same every time): a few moods, both kinds.
    static func sampleAgents(_ count: Int) -> [PolaroidAgent] {
        let all: [PolaroidAgent] = [
            PolaroidAgent(id: "p1", project: "scout", kind: .claude, mood: .working, variant: AgentFaceArt.variant(style: 1, colour: 0, skin: 1)),
            PolaroidAgent(id: "p2", project: "website", kind: .codex, mood: .asking, variant: AgentFaceArt.variant(style: 2, colour: 4, skin: 3)),
            PolaroidAgent(id: "p3", project: "notes", kind: .claude, mood: .finished, variant: AgentFaceArt.variant(style: 4, colour: 3, skin: 5)),
            PolaroidAgent(id: "p4", project: "billing-server", kind: .codex, mood: .working, variant: AgentFaceArt.variant(style: 3, colour: 5, skin: 2)),
            PolaroidAgent(id: "p5", project: "game-app", kind: .claude, mood: .idle, variant: AgentFaceArt.variant(style: 5, colour: 7, skin: 6)),
            PolaroidAgent(id: "p6", project: "tv", kind: .codex, mood: .stopped, variant: AgentFaceArt.variant(style: 0, colour: 1, skin: 4)),
        ]
        return Array(all.prefix(max(0, min(count, all.count))))
    }
}

// MARK: - The card

/// The polaroid itself. `photo` fills the square (it is cropped to it from the middle).
struct MirrorPolaroidCard<Photo: View>: View {
    var agents: [PolaroidAgent]
    @ViewBuilder var photo: () -> Photo

    private typealias P = MirrorPolaroid

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(P.paper)
            picture.offset(x: P.side, y: P.top)
            margin.offset(x: 0, y: P.top + P.photo)
            Rectangle().strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
        }
        .frame(width: P.width, height: P.height, alignment: .topLeading)
        .environment(\.colorScheme, .light)
    }

    /// The picture, a soft shade along its bottom edge so the names read, and the agents (or the app's face) standing on that edge.
    private var picture: some View {
        ZStack(alignment: .topLeading) {
            photo().frame(width: P.photo, height: P.photo).clipped()
            LinearGradient(colors: [.clear, Color.black.opacity(0.42)], startPoint: .top, endPoint: .bottom)
                .frame(width: P.photo, height: 120).offset(y: P.photo - 120)
            if agents.isEmpty { mark } else { standing }
        }
        .frame(width: P.photo, height: P.photo, alignment: .topLeading)
        .clipped()
        .overlay(Rectangle().strokeBorder(Color.black.opacity(0.22), lineWidth: 0.5))
    }

    private var standing: some View {
        let shown = Array(agents.prefix(P.maxAgents))
        let boxes = P.faceRects(count: shown.count)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, agent in
                let box = boxes[index]
                PolaroidFace(agent: agent, cell: P.cell(count: shown.count))
                    .offset(x: box.minX - P.side, y: box.minY - P.top)
                PolaroidPixelText(P.label(agent.project, count: shown.count), pixel: 1, color: .white, outline: Color.black.opacity(0.9))
                    .frame(width: P.slot(count: shown.count), height: P.nameHeight)
                    .offset(x: box.midX - P.slot(count: shown.count) / 2 - P.side, y: box.maxY + P.nameGap - P.top)
            }
        }
    }

    /// No agents: the app's own face mark (the outline and two eyes) in white with a dark edge, where a lone agent's face would stand.
    private var mark: some View {
        let box = P.faceRects(count: 1)[0]
        return PolaroidMark(cell: P.cell(count: 1))
            .offset(x: box.minX - P.side, y: box.minY - P.top)
    }

    /// The white margin: the app's name in big pixel capitals, "me and my agents", and the link in small type.
    private var margin: some View {
        VStack(spacing: 0) {
            PolaroidPixelText(P.appName, pixel: 4, color: P.ink)
            PolaroidPixelText(P.tagline, pixel: 1.5, color: P.softInk).padding(.top, 9)
            Text(verbatim: P.printedLink).font(.system(size: 8.5, weight: .regular, design: .monospaced)).foregroundStyle(P.softInk)
                .lineLimit(1).fixedSize().padding(.top, 13)
        }
        .frame(width: P.width, height: P.bottom)
    }
}

/// An agent's face: its own 12 x 12 pixel face (its kind's colour, its headwear, its mood), a hard shadow under it.
struct PolaroidFace: View {
    var agent: PolaroidAgent
    var cell: CGFloat

    /// A step of the face's life that is not a blink (a working face is looking ahead).
    static let tick = 3

    var body: some View {
        let sprite = AgentFaceArt.frame(agent.mood, tick: Self.tick, burst: false, variant: agent.variant)
        let palette = AgentFaceArt.palette(agent.kind, agent.mood, variant: agent.variant)
        let side = CGFloat(AgentFaceArt.cells) * cell
        return Canvas { ctx, _ in
            var c = ctx
            AgentPixel.draw(sprite, in: &c, at: .zero, px: cell, palette: palette)
        }
        .frame(width: side, height: side)
        .shadow(color: .black.opacity(0.45), radius: 0, x: 0, y: cell * 0.75)
        .accessibilityHidden(true)
    }
}

/// The app's face mark (the menu-bar icon: the face's outline and two eyes) in white, with a dark edge and a hard shadow so it reads
/// over any picture. One path, so the cells have no seams.
struct PolaroidMark: View {
    var cell: CGFloat

    var body: some View {
        let sprite = AppIconInUse.menuBarSprite
        let side = CGFloat(sprite.width) * cell
        return Canvas { ctx, _ in
            var path = Path()
            for (r, row) in sprite.rows.enumerated() {
                for (c, ch) in row.enumerated() where AppIconInUse.isInk(ch) {
                    path.addRect(CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell, width: cell, height: cell))
                }
            }
            let edge = Color.black.opacity(0.85)
            ctx.fill(path.offsetBy(dx: 0, dy: cell * 0.75), with: .color(Color.black.opacity(0.45)))
            for (dx, dy) in [(-1.25, 0.0), (1.25, 0.0), (0.0, -1.25), (0.0, 1.25)] as [(CGFloat, CGFloat)] {
                ctx.fill(path.offsetBy(dx: dx, dy: dy), with: .color(edge))
            }
            ctx.fill(path, with: .color(.white))
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// Pixel capitals (the announcement board's 5 x 7 dot font) in any look, optionally with a one-pixel outline so they read over a picture.
struct PolaroidPixelText: View {
    let text: String
    let pixel: CGFloat
    let color: Color
    var outline: Color?

    init(_ text: String, pixel: CGFloat, color: Color, outline: Color? = nil) {
        self.text = text
        self.pixel = pixel
        self.color = color
        self.outline = outline
    }

    var body: some View {
        let cols = RetroPixelLayout.columns(text)
        let pad: CGFloat = outline == nil ? 0 : 1
        return Canvas { ctx, _ in
            func rects(_ pixels: [(col: Int, row: Int)], shift: Int) -> Path {
                var path = Path()
                for (c, r) in pixels {
                    path.addRect(CGRect(x: CGFloat(c + shift) * pixel, y: CGFloat(r + shift) * pixel, width: pixel, height: pixel))
                }
                return path
            }
            guard !cols.isEmpty else { return }
            if let outline {
                ctx.fill(rects(RetroPixelLayout.outlinePixels(cols), shift: 0), with: .color(outline))
                ctx.fill(rects(RetroPixelLayout.litPixels(cols), shift: 1), with: .color(color))
            } else {
                ctx.fill(rects(RetroPixelLayout.litPixels(cols), shift: 0), with: .color(color))
            }
        }
        .frame(width: RetroPixelLayout.width(text, pixel: pixel) + 2 * pad * pixel, height: RetroPixelLayout.height(pixel: pixel) + 2 * pad * pixel)
        .accessibilityLabel(text)
    }
}
