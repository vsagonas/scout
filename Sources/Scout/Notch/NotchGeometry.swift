import AppKit
import SwiftUI

/// The size of the (hardware or virtual) notch of one screen.
struct NotchGeometry: Equatable {
    var size: CGSize
    var isHardware: Bool

    /// The MacBook Pro 16" notch, used by the gallery.
    static let sample16 = NotchGeometry(size: CGSize(width: 185, height: 32), isHardware: true)
    static let virtualSize = CGSize(width: 190, height: 32)

    @MainActor
    static func make(for screen: NSScreen) -> NotchGeometry {
        let top = screen.safeAreaInsets.top
        guard top > 0 else { return NotchGeometry(size: virtualSize, isHardware: false) }
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        var width = screen.frame.width - left - right
        if width < 80 || width > 420 { width = 185 }
        return NotchGeometry(size: CGSize(width: width, height: top), isHardware: true)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    var hasHardwareNotch: Bool { safeAreaInsets.top > 0 }
}

/// The notch outline: flush with the top edge, small outward "shoulders" at the top corners (radius
/// `topRadius`, the body walls start that far inside the frame) and rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let t = max(0, min(topRadius, rect.height / 2, rect.width / 4))
        let b = max(0, min(bottomRadius, (rect.height - t) / 1.2, (rect.width - 2 * t) / 2))
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        if t > 0.25 {
            p.addArc(tangent1End: CGPoint(x: rect.minX + t, y: rect.minY),
                     tangent2End: CGPoint(x: rect.minX + t, y: rect.minY + t), radius: t)
        } else {
            p.addLine(to: CGPoint(x: rect.minX + t, y: rect.minY))
        }
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        if b > 0.25 {
            p.addArc(tangent1End: CGPoint(x: rect.minX + t, y: rect.maxY),
                     tangent2End: CGPoint(x: rect.minX + t + b, y: rect.maxY), radius: b)
            p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
            p.addArc(tangent1End: CGPoint(x: rect.maxX - t, y: rect.maxY),
                     tangent2End: CGPoint(x: rect.maxX - t, y: rect.maxY - b), radius: b)
        } else {
            p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.maxY))
        }
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        if t > 0.25 {
            p.addArc(tangent1End: CGPoint(x: rect.maxX - t, y: rect.minY),
                     tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: t)
        } else {
            p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY))
        }
        p.closeSubpath()
        return p
    }
}
