import AppKit
import SwiftUI

// Pictures and quick checks of the polaroid (`MirrorPolaroid`): the gallery sheet, and the checks that run with
//   SCOUT_SELFTEST=1 build/Scout.app/Contents/MacOS/Scout --gallery <dir> --only zzz
// They build the polaroid from a drawn picture and made-up agents, read its pixels, and never open a camera or a share sheet.

/// A gallery picture: the polaroid the Share key makes, from the drawn stand-in picture and made-up agents (never a camera frame).
struct MirrorPolaroidSheet: View {
    var agents: [PolaroidAgent]

    var body: some View {
        let made = MirrorPolaroid.samplePhoto().flatMap { MirrorPolaroid.image(photo: $0, agents: agents) }
        Group {
            if let made {
                Image(nsImage: made).interpolation(.none).shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            } else {
                Text(verbatim: "The polaroid could not be drawn").foregroundStyle(.red)
            }
        }
        .padding(30)
    }
}

@MainActor
enum MirrorPolaroidChecks {
    typealias RGB = (r: Int, g: Int, b: Int)

    /// A flat picture of one colour.
    static func flat(_ r: Double, _ g: Double, _ b: Double, width: Int = 200, height: Int = 200) -> CGImage? {
        guard let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return c.makeImage()
    }

    /// A picture with red on its left half and yellow on its right (16:9), to see which way the card puts it.
    static func halves() -> CGImage? {
        guard let c = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: 160, height: 180))
        c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1))
        c.fill(CGRect(x: 160, y: 0, width: 160, height: 180))
        return c.makeImage()
    }

    /// The pixel at a point of the card (top-left origin, in points; the image is `MirrorPolaroid.scale` pixels a point).
    static func pixel(_ image: CGImage, _ pt: CGPoint) -> RGB {
        let x = min(image.width - 1, max(0, Int((pt.x * MirrorPolaroid.scale).rounded(.down))))
        let y = min(image.height - 1, max(0, Int((pt.y * MirrorPolaroid.scale).rounded(.down))))
        var data = [UInt8](repeating: 0, count: 4)
        guard let c = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (-1, -1, -1) }
        c.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    static func distance(_ a: RGB, _ b: RGB) -> Int { abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) }
    static func isWhite(_ p: RGB, _ least: Int = 240) -> Bool { p.r >= least && p.g >= least && p.b >= least }

    /// Every pixel of a box (points) that `test` accepts, counted over the box's pixels.
    static func share(_ image: CGImage, in box: CGRect, _ test: (CGPoint, RGB) -> Bool) -> Double {
        var hit = 0, all = 0
        var y = box.minY
        while y < box.maxY {
            var x = box.minX
            while x < box.maxX {
                let p = CGPoint(x: x, y: y)
                if test(p, pixel(image, p)) { hit += 1 }
                all += 1
                x += 1 / MirrorPolaroid.scale
            }
            y += 1 / MirrorPolaroid.scale
        }
        return all == 0 ? 0 : Double(hit) / Double(all)
    }

    static func register() {
        let photoBlue: RGB = (38, 89, 191)
        let sessions = AgentSession.synthetic(3)
        FeaturesSelfTest.add("mirror polaroid: 720 x 900 pixels (360 x 450 pt, twice over), a white frame with the thick margin at the bottom") {
            guard let photo = flat(0.15, 0.35, 0.75), let image = MirrorPolaroid.image(photo: photo, agents: MirrorPolaroid.agents(sessions: sessions, pending: [])),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("  no image"); return false }
            let margin = MirrorPolaroid.photoRect.maxY
            // Empty spots of the white frame: the top and the sides, and the bottom margin where no word stands (left of "Scout").
            let spots = [CGPoint(x: 9, y: 9), CGPoint(x: 180, y: 9), CGPoint(x: 351, y: 9), CGPoint(x: 9, y: 200), CGPoint(x: 351, y: 200),
                         CGPoint(x: 9, y: margin + 50), CGPoint(x: 351, y: margin + 50), CGPoint(x: 40, y: margin + 54), CGPoint(x: 320, y: margin + 54),
                         CGPoint(x: 40, y: MirrorPolaroid.height - 12), CGPoint(x: 9, y: MirrorPolaroid.height - 9)]
            let bad = spots.filter { !isWhite(pixel(cg, $0)) }
            let sized = cg.width == 720 && cg.height == 900 && image.size == NSSize(width: 360, height: 450)
            let middle = pixel(cg, CGPoint(x: 180, y: 120))
            if !sized || !bad.isEmpty || distance(middle, photoBlue) > 30 { print("  size \(cg.width)x\(cg.height) \(image.size), not white: \(bad), photo middle \(middle), space \(String(describing: cg.colorSpace?.name)), alpha \(cg.alphaInfo.rawValue), bpc \(cg.bitsPerComponent)") }
            return sized && bad.isEmpty && distance(middle, photoBlue) <= 30
        }
        FeaturesSelfTest.add("mirror polaroid: the agents' faces and their names are drawn along the bottom edge of the picture (3 and 6 agents)") {
            for count in [3, 6] {
                let agents = MirrorPolaroid.agents(sessions: AgentSession.synthetic(count), pending: [])
                guard agents.count == count, let photo = flat(0.15, 0.35, 0.75), let cg = MirrorPolaroid.render(photo: photo, agents: agents) else { print("  \(count): no image or agents \(agents.count)"); return false }
                let boxes = MirrorPolaroid.faceRects(count: count)
                for (agent, box) in zip(agents, boxes) {
                    // The picture's colour of the same row (the shade only changes from row to row), left of every face.
                    let drawn = share(cg, in: box) { p, c in distance(c, pixel(cg, CGPoint(x: MirrorPolaroid.side + 4, y: p.y))) > 36 }
                    let nameBox = CGRect(x: box.midX - MirrorPolaroid.slot(count: count) / 2, y: box.maxY + MirrorPolaroid.nameGap, width: MirrorPolaroid.slot(count: count), height: MirrorPolaroid.nameHeight)
                    let letters = share(cg, in: nameBox) { _, c in isWhite(c, 235) }
                    if drawn < 0.6 || letters <= 0.02 { print("  \(count): \(agent.project) face covers \(drawn), name pixels \(letters)") }
                    if drawn < 0.6 || letters <= 0.02 { return false }
                }
                let inside = boxes.allSatisfy { MirrorPolaroid.photoRect.contains($0) }
                let apart = zip(boxes, boxes.dropFirst()).allSatisfy { $0.maxX <= $1.minX }
                if !inside || !apart { print("  \(count): faces inside the picture \(inside), side by side \(apart)"); return false }
            }
            return true
        }
        FeaturesSelfTest.add("mirror polaroid: the app's name is on the white margin (dark pixels), the link line too; with no agents the app's face mark stands on the picture") {
            guard let dark = flat(0.05, 0.05, 0.2), let withAgents = MirrorPolaroid.render(photo: dark, agents: MirrorPolaroid.sampleAgents(3)),
                  let none = MirrorPolaroid.render(photo: dark, agents: []) else { print("  no image"); return false }
            let top = MirrorPolaroid.photoRect.maxY
            let name = CGRect(x: 110, y: top + 12, width: 140, height: 30)
            let link = CGRect(x: 60, y: MirrorPolaroid.height - 38, width: 240, height: 24)
            let inkName = share(none, in: name) { _, c in c.r < 120 && c.g < 120 && c.b < 130 }
            let inkLink = share(none, in: link) { _, c in c.r < 160 && c.g < 160 && c.b < 170 }
            let mark = MirrorPolaroid.faceRects(count: 1)[0]
            let bright = share(none, in: mark) { _, c in isWhite(c, 235) }
            let noMarkWithAgents = share(withAgents, in: CGRect(x: 22, y: top - 60, width: 20, height: 40)) { _, c in isWhite(c, 235) }
            if inkName < 0.03 || inkLink < 0.01 || bright < 0.03 { print("  name ink \(inkName), link ink \(inkLink), mark white \(bright)") }
            return inkName >= 0.03 && inkLink >= 0.01 && bright >= 0.03 && noMarkWithAgents < 0.02
        }
        FeaturesSelfTest.add("mirror polaroid: the picture is drawn as it is handed in (left stays left), cropped to the square from its middle") {
            guard let halves = halves(), let cg = MirrorPolaroid.render(photo: halves, agents: []) else { print("  no image"); return false }
            let y = MirrorPolaroid.photoRect.midY - 40
            let left = pixel(cg, CGPoint(x: MirrorPolaroid.photoRect.minX + 20, y: y)), right = pixel(cg, CGPoint(x: MirrorPolaroid.photoRect.maxX - 20, y: y))
            let ok = left.r > 200 && left.g < 60 && right.r > 200 && right.g > 200 && right.b < 80
            if !ok { print("  left \(left) right \(right)") }
            return ok
        }
        FeaturesSelfTest.add("mirror polaroid: the words and the link (apps.v-sag.com/scout), up to six agents with their own names in capitals") {
            let agents = MirrorPolaroid.agents(sessions: AgentSession.synthetic(6), pending: [])
            let manyNames = MirrorPolaroid.agents(sessions: AgentSession.synthetic(6), pending: []).map { MirrorPolaroid.label($0.project, count: 6) }
            let long = MirrorPolaroid.label("a-very-long-project-name", count: 6)
            let words = MirrorPolaroid.shareText == "Scout: my AI agents in my notch. https://apps.v-sag.com/scout"
                && MirrorPolaroid.appLink == "https://apps.v-sag.com/scout" && MirrorPolaroid.printedLink == "apps.v-sag.com/scout" && MirrorPolaroid.appName == "Scout"
            let tooMany = MirrorPolaroid.agents(sessions: AgentSession.synthetic(6) + AgentSession.samples(), pending: []).count
            let ok = words && agents.count == 6 && tooMany == 6 && manyNames.allSatisfy { $0 == $0.uppercased() && $0.count <= MirrorPolaroid.nameLetters(count: 6) }
                && long == "A-VERY." && MirrorPolaroid.fileName(date: Date(timeIntervalSince1970: 0)).hasSuffix(".png")
            if !ok { print("  words \(words), agents \(agents.count), capped \(tooMany), names \(manyNames), long \(long)") }
            return ok
        }
        FeaturesSelfTest.add("mirror polaroid: the PNG for Save… is a real PNG of the same size") {
            guard let photo = flat(0.5, 0.4, 0.3), let image = MirrorPolaroid.image(photo: photo, agents: MirrorPolaroid.sampleAgents(2)), let data = MirrorPolaroid.pngData(image) else { return false }
            let isPNG = data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            let size = NSBitmapImageRep(data: data).map { ($0.pixelsWide, $0.pixelsHigh) } ?? (0, 0)
            if !isPNG || size != (720, 900) { print("  png \(isPNG) \(size)") }
            return isPNG && size == (720, 900)
        }
    }
}
