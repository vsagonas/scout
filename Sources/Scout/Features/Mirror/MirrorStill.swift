import CoreGraphics
import SwiftUI

/// The Mirror's current picture as a still, for whatever wants one (the "Photo with my agents" card). It is the picture exactly as
/// the Mirror shows it: the flip and the zoom are applied, so what is on screen is what comes out.
@MainActor
enum MirrorCamera {
    /// The picture the Mirror shows now, as an image; nil in scripted runs and when the camera is off. While Freeze holds a frame
    /// it is that frame. It is `async` because a live camera keeps no frame to hand over (nothing is kept): the next frame is taken
    /// when asked. Zoom comes from the Mirror tab on screen (1× when only the panel is up); flip is the Mirror's own setting.
    /// Nothing is written anywhere: whoever calls this decides whether the image is shown, shared or saved.
    static func currentStill() async -> CGImage? {
        await still(model: .shared, tools: MirrorTools.active, flip: Pref.bool(MirrorModel.Key.flip, true))
    }

    static func still(model: MirrorModel, tools: MirrorTools?, flip: Bool) async -> CGImage? {
        guard !model.scripted, model.state == .running else { return nil }
        let zoom = tools?.zoom ?? MirrorZoom()
        if let held = tools?.frozen { return MirrorStill.render(held, zoom: zoom, flip: flip) }
        let raw: CGImage? = await withCheckedContinuation { continuation in
            model.snapshot { continuation.resume(returning: $0) }
        }
        guard let raw else { return nil }
        return MirrorStill.render(raw, zoom: zoom, flip: flip)
    }
}

enum MirrorStill {
    /// The camera's own frame (unmirrored) as the Mirror shows it: the visible part of the zoom, mirrored when `flip` is on.
    /// The result keeps the camera's pixels (a 2× zoom of a 1080-high frame is 540 high), in the picture's own proportions.
    static func render(_ raw: CGImage, zoom: MirrorZoom, flip: Bool) -> CGImage? {
        let w = CGFloat(raw.width)
        let h = CGFloat(raw.height)
        guard w > 0, h > 0 else { return nil }
        let v = zoom.visible
        // The Mirror's picture is already mirrored on screen: the same part of the camera's own frame lies on the other side.
        let sourceX = flip ? 1 - v.maxX : v.minX
        let crop = CGRect(x: (sourceX * w).rounded(), y: (v.minY * h).rounded(), width: max(1, (v.width * w).rounded()), height: max(1, (v.height * h).rounded()))
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !crop.isEmpty, let part = raw.cropping(to: crop) else { return nil }
        guard flip else { return part }
        guard let context = CGContext(data: nil, width: part.width, height: part.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: CGFloat(part.width), y: 0)
        context.scaleBy(x: -1, y: 1)
        context.draw(part, in: CGRect(x: 0, y: 0, width: part.width, height: part.height))
        return context.makeImage()
    }
}
