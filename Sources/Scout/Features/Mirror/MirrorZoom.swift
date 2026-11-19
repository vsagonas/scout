import CoreGraphics

/// How far and where the Mirror is zoomed. Pure math, no views: the Mirror view and its self-test both use it.
///
/// Everything is in UNIT coordinates, so the numbers mean the same at any size: the visible picture is the square 0…1 across and
/// down, and a point is "left quarter, upper third" whatever the pixels. The picture is the one on screen (after the flip), so
/// the flip never changes the zoom math; `sourcePoint` says where a spot of the screen sits in the camera's own, unmirrored image.
///
/// The picture is drawn `scale` times as wide and as tall as the view, with its top-left corner at `origin` (in view units).
/// At 1× that is 0,0. Zoomed, `origin` runs from `1 - scale` (the picture's bottom-right corner at the view's) to 0: the view
/// never shows anything outside the picture.
struct MirrorZoom: Equatable {
    /// The scales a click steps through (1× → 2× → 3×).
    static let steps: [CGFloat] = [1, 2, 3]
    /// The most the scroll wheel, the pinch and the slider zoom in.
    static let maxScale: CGFloat = 5
    /// Closer than this to a scale counts as being on it.
    private static let epsilon: CGFloat = 0.01

    private(set) var scale: CGFloat = 1
    private(set) var origin: CGPoint = .zero

    init() {}

    init(scale: CGFloat, origin: CGPoint) {
        self.scale = min(Self.maxScale, max(1, scale))
        self.origin = origin
        clamp()
    }

    /// A zoom around a spot of the view (a gallery picture, or a test): `scale`× with `spot` staying where it is.
    static func zoomed(_ scale: CGFloat, around spot: CGPoint) -> MirrorZoom {
        var z = MirrorZoom()
        z.zoom(to: scale, around: spot)
        return z
    }

    var isZoomed: Bool { scale > 1 + Self.epsilon }

    /// The part of the picture on screen, in picture units.
    var visible: CGRect {
        CGRect(x: -origin.x / scale, y: -origin.y / scale, width: 1 / scale, height: 1 / scale)
    }

    /// The spot of the picture under a spot of the view (both in unit coordinates).
    func picturePoint(atView u: CGPoint) -> CGPoint {
        CGPoint(x: (u.x - origin.x) / scale, y: (u.y - origin.y) / scale)
    }

    /// The same spot in the camera's own image, which the flip mirrors left to right.
    static func sourcePoint(of picturePoint: CGPoint, flipped: Bool) -> CGPoint {
        CGPoint(x: flipped ? 1 - picturePoint.x : picturePoint.x, y: picturePoint.y)
    }

    /// A point in view pixels as a unit point (clamped to the view: a click that lands on the edge's rounding stays inside).
    static func unit(_ point: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: min(1, max(0, point.x / size.width)), y: min(1, max(0, point.y / size.height)))
    }

    // MARK: Changes

    /// Keeps the view inside the picture; at 1× the picture sits exactly in the view.
    private mutating func clamp() {
        if scale <= 1 + Self.epsilon {
            scale = 1
            origin = .zero
            return
        }
        origin.x = min(0, max(1 - scale, origin.x))
        origin.y = min(0, max(1 - scale, origin.y))
    }

    /// Zooms to `newScale` (1…`maxScale`) with the spot under `u` staying under it, as far as the picture's edges allow.
    mutating func zoom(to newScale: CGFloat, around u: CGPoint) {
        let target = min(Self.maxScale, max(1, newScale))
        let spot = CGPoint(x: min(1, max(0, u.x)), y: min(1, max(0, u.y)))
        let ratio = target / scale
        origin = CGPoint(x: spot.x - (spot.x - origin.x) * ratio, y: spot.y - (spot.y - origin.y) * ratio)
        scale = target
        clamp()
    }

    /// The scroll wheel and the pinch: `factor` above 1 zooms in.
    mutating func zoom(by factor: CGFloat, around u: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        zoom(to: scale * factor, around: u)
    }

    /// A click on a spot: the next step (2×, then 3×) around THAT spot. At 3× or closer, a click changes nothing.
    mutating func click(at u: CGPoint) {
        guard let next = Self.steps.first(where: { $0 > scale + Self.epsilon }) else { return }
        zoom(to: next, around: u)
    }

    /// Double-click or the 1× button: the whole picture again.
    mutating func reset() {
        scale = 1
        origin = .zero
    }

    /// A drag by `delta` (unit coordinates): the picture follows the pointer. At 1× there is nothing to drag.
    mutating func pan(by delta: CGPoint) {
        guard isZoomed else { return }
        origin = CGPoint(x: origin.x + delta.x, y: origin.y + delta.y)
        clamp()
    }

    /// The flip was switched while zoomed: the picture mirrors, so the view moves to the mirrored part to keep looking at the
    /// same part of the scene.
    mutating func mirrorHorizontally() {
        guard isZoomed else { return }
        origin.x = 1 - scale - origin.x
        clamp()
    }
}
