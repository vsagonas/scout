import CoreGraphics
import SwiftUI

/// What the person does in the Mirror tab: zoom, the ring light, the frozen frame. One per tab visit (leaving the tab
/// forgets all of it except the light's brightness). Nothing here is ever written to disk.
@MainActor
final class MirrorTools: ObservableObject {
    @Published private(set) var zoom = MirrorZoom()
    @Published var lightOn = false
    @Published var lightLevel: Double {
        didSet { Pref.set(lightLevel, MirrorModel.Key.lightLevel) }
    }
    /// The held frame while Freeze is on (in memory only).
    @Published private(set) var frozen: CGImage?
    @Published private(set) var freezing = false

    /// Where the toolbar's buttons are, in the scene's coordinates (the self-test clicks them).
    var buttonRects: [String: CGRect] = [:]
    /// Drags in progress hold the notch open, so a pan that leaves the island does not close it.
    var holdsOpen: (Bool) -> Void = { on in
        if on { NotchNavigator.shared.hold("mirror.drag") } else { NotchNavigator.shared.release("mirror.drag") }
    }

    private var generation = 0

    /// The Mirror tab that is on screen now (so `MirrorCamera.currentStill()` can apply its zoom); nil when there is none.
    static weak var active: MirrorTools?

    init() {
        lightLevel = min(1, max(Self.lightRange.lowerBound, Pref.double(MirrorModel.Key.lightLevel, 0.7)))
    }

    static let lightRange: ClosedRange<Double> = 0.2...1
    /// The −/+ buttons walk this ladder (a click on the picture uses `MirrorZoom.steps`).
    static let ladder: [CGFloat] = [1, 1.5, 2, 3, 4, 5]

    /// The centre of the view: where the slider and the −/+ buttons zoom around.
    private let centre = CGPoint(x: 0.5, y: 0.5)

    // MARK: Zoom

    /// A change that eases in over a moment, and is instant with Reduce Motion.
    private func eased(_ change: () -> Void) {
        withAnimation(ScoutRuntime.reduceMotion ? nil : .easeOut(duration: 0.22)) { change() }
    }

    /// A click on a spot: 2×, then 3×, around that spot.
    func click(at u: CGPoint) { eased { zoom.click(at: u) } }

    /// A double-click: the whole picture again.
    func doubleClick() { eased { zoom.reset() } }

    func resetZoom() { eased { zoom.reset() } }

    /// The wheel and the pinch follow the fingers, so they never ease.
    func scroll(dy: CGFloat, precise: Bool, at u: CGPoint) { zoom.zoom(by: Self.scrollFactor(dy: dy, precise: precise), around: u) }

    func magnify(_ magnification: CGFloat, at u: CGPoint) { zoom.zoom(by: 1 + magnification, around: u) }

    func pan(by delta: CGPoint) { zoom.pan(by: delta) }

    /// The slider: follows the thumb.
    func setScale(_ scale: CGFloat) { zoom.zoom(to: scale, around: centre) }

    /// − and +: the next step of the ladder, around the centre.
    func stepZoom(_ direction: Int) {
        let now = zoom.scale
        let next: CGFloat? = direction > 0 ? Self.ladder.first { $0 > now + 0.01 } : Self.ladder.last { $0 < now - 0.01 }
        guard let next else { return }
        eased { zoom.zoom(to: next, around: centre) }
    }

    /// The flip was switched: a zoomed view moves to the mirrored part of the picture.
    func flipSwitched() { zoom.mirrorHorizontally() }

    /// Mouse wheel and trackpad scroll as a zoom factor (up = in). A trackpad sends many small steps, a wheel a few big ones.
    static func scrollFactor(dy: CGFloat, precise: Bool) -> CGFloat {
        let amount = precise ? dy * 0.01 : dy * 0.12
        return exp(min(0.5, max(-0.5, amount)))
    }

    private var holding = false

    func dragBegan() {
        guard zoom.isZoomed, !holding else { return }
        holding = true
        holdsOpen(true)
    }

    func dragEnded() {
        guard holding else { return }
        holding = false
        holdsOpen(false)
    }

    // MARK: Freeze

    var isFrozen: Bool { frozen != nil || freezing }

    /// Holds the current frame, or lets go of it.
    func toggleFreeze(using model: MirrorModel) {
        if isFrozen {
            unfreeze()
            return
        }
        freezing = true
        generation += 1
        let mine = generation
        model.snapshot { [weak self] image in
            guard let self, mine == self.generation else { return }
            self.freezing = false
            self.frozen = image
        }
    }

    func unfreeze() {
        generation += 1
        freezing = false
        frozen = nil
    }
}
