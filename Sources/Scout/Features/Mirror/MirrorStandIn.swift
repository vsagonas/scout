import SwiftUI

/// A drawn stand-in for the camera picture: galleries, scripted runs and live checks show this and never open a camera. Plain
/// shapes only (no photo). It leans on two things that are not symmetric (a lock of hair on one side, a mole on the other), so
/// the flip and the zoom show in a still image. Everything is sized from the frame it gets, so it stays sharp at any zoom.
struct MirrorStandIn: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let cx = w * 0.5
            let head = CGPoint(x: cx, y: h * 0.47)
            let u = h   // the unit of everything below
            ZStack {
                LinearGradient(colors: [Color(red: 0.30, green: 0.38, blue: 0.50), Color(red: 0.58, green: 0.53, blue: 0.49)],
                               startPoint: .top, endPoint: .bottom)
                // A window's light on the wall.
                RadialGradient(colors: [Color.white.opacity(0.20), .clear], center: .init(x: 0.18, y: 0.2), startRadius: 0, endRadius: w * 0.35)

                // Shoulders and neck.
                Ellipse().fill(Color(red: 0.20, green: 0.26, blue: 0.38))
                    .frame(width: u * 1.05, height: u * 0.62).position(x: cx, y: h * 1.0)
                RoundedRectangle(cornerRadius: u * 0.04, style: .continuous).fill(Color(red: 0.76, green: 0.60, blue: 0.49))
                    .frame(width: u * 0.15, height: u * 0.22).position(x: cx, y: h * 0.76)

                // Hair behind the head, and one lock on the viewer's left only.
                Ellipse().fill(Color(red: 0.20, green: 0.14, blue: 0.11))
                    .frame(width: u * 0.47, height: u * 0.56).position(x: head.x, y: head.y - u * 0.02)
                Capsule().fill(Color(red: 0.20, green: 0.14, blue: 0.11))
                    .frame(width: u * 0.09, height: u * 0.30).rotationEffect(.degrees(8)).position(x: head.x - u * 0.235, y: head.y + u * 0.14)

                // The face.
                Ellipse().fill(Color(red: 0.87, green: 0.71, blue: 0.59))
                    .frame(width: u * 0.40, height: u * 0.50).position(head)
                // Fringe, parted to the viewer's right.
                Ellipse().fill(Color(red: 0.20, green: 0.14, blue: 0.11))
                    .frame(width: u * 0.42, height: u * 0.20).position(x: head.x + u * 0.012, y: head.y - u * 0.205)

                // Eyes and brows.
                ForEach([-1.0, 1.0], id: \.self) { side in
                    ZStack {
                        Ellipse().fill(Color.white).frame(width: u * 0.062, height: u * 0.032)
                        Circle().fill(Color(red: 0.16, green: 0.12, blue: 0.10)).frame(width: u * 0.026)
                    }
                    .position(x: head.x + side * u * 0.085, y: head.y - u * 0.035)
                    Capsule().fill(Color(red: 0.20, green: 0.14, blue: 0.11))
                        .frame(width: u * 0.075, height: u * 0.011).rotationEffect(.degrees(side * 4))
                        .position(x: head.x + side * u * 0.085, y: head.y - u * 0.085)
                }
                // Nose and mouth.
                Capsule().fill(Color(red: 0.77, green: 0.60, blue: 0.49))
                    .frame(width: u * 0.026, height: u * 0.10).position(x: head.x, y: head.y + u * 0.03)
                MirrorSmile().stroke(Color(red: 0.69, green: 0.33, blue: 0.31), style: StrokeStyle(lineWidth: max(1.5, u * 0.012), lineCap: .round))
                    .frame(width: u * 0.11, height: u * 0.04).position(x: head.x, y: head.y + u * 0.14)
                // A mole on the viewer's right cheek.
                Circle().fill(Color(red: 0.36, green: 0.22, blue: 0.17))
                    .frame(width: u * 0.014).position(x: head.x + u * 0.115, y: head.y + u * 0.09)
            }
            .frame(width: w, height: h)
            .clipped()
        }
    }
}

/// The picture the dashboard panel's gallery items show (kept for the panel).
struct SamplePortrait: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            MirrorStandIn()
            Text("Sample").font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.6)).padding(6)
        }
    }
}

/// A gentle smile: one shallow curve.
private struct MirrorSmile: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY * 1.7))
        return p
    }
}
