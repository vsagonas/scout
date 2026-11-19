import AppKit
import SwiftUI

/// A picture flying across the open island into one of its tab keys: the camera's Snap sends the picture it copied into the Clipboard key.
/// A flight names where it starts and
/// where it lands by the rects the island reports (`reportRect`, "mirror.picture" and "tab.clipboard"); the island draws it on top of
/// everything (`NotchFlyLayer`), takes no clicks through it, and lets it go when it has landed.
@MainActor
final class NotchFly: ObservableObject {
    static let shared = NotchFly()

    struct Flight: Identifiable {
        let id = UUID()
        let image: NSImage
        let from: String
        let to: String
    }

    @Published private(set) var flight: Flight?
    /// The last flight launched (self-tests read it).
    private(set) var last: Flight?

    func launch(image: NSImage, from: String, to: String) {
        let flight = Flight(image: image, from: from, to: to)
        last = flight
        self.flight = flight
    }

    func land(_ id: UUID) {
        if flight?.id == id { flight = nil }
    }

    /// The whole flight, in seconds: the flash, the lift, the trip to the key and the ring where it lands.
    static let duration = 1.35
}

/// Draws the flight over the island (the panel's own coordinates, "notchPanel"). Nothing when there is no flight or its start is not on screen.
struct NotchFlyLayer: View {
    @ObservedObject private var fly = NotchFly.shared
    let rects: () -> [String: CGRect]
    /// The open island's own rect: the flash stays inside it.
    var island: () -> CGRect = { .zero }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let flight = fly.flight {
                // The island's rects are not published (they change every frame of a resize): while a flight is on, read them every frame,
                // so it starts as soon as the picture has reported where it is and lands where the key is now.
                TimelineView(.animation) { _ in
                    if let from = rects()[flight.from] {
                        NotchFlyPhoto(flight: flight, from: from, to: rects()[flight.to], island: island()).id(flight.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// One flight (the white flash is the picture's own, `NotchFlyFlash`, so the island's outline clips it): the picture lifts off as a small print with a white edge, flies up into the key and shrinks
/// into it, and a ring opens around the key as it lands. With no key on screen (the Clipboard tab switched off) it flies to the top middle.
private struct NotchFlyPhoto: View {
    let flight: NotchFly.Flight
    let from: CGRect
    let to: CGRect?
    var island: CGRect = .zero
    /// 0 the picture and the flash, 1 lifted as a print, 2 at the key, 3 landed (the ring opens, the print is gone).
    @State private var stage = 0

    private var target: CGRect { to ?? CGRect(x: from.midX - 10, y: 4, width: 20, height: 20) }
    /// The print keeps the photo's own shape (the camera's 16:9), not the view's.
    private var aspect: CGFloat {
        let size = flight.image.size
        if size.width > 0, size.height > 0 { return size.height / size.width }
        return from.width > 0 ? from.height / from.width : 0.75
    }


    var body: some View {
        let liftWidth = min(170, from.width * 0.42, from.height * 0.6 / max(0.1, aspect))
        let lifted = CGSize(width: liftWidth, height: liftWidth * aspect)
        let small = CGSize(width: 20, height: 20 * aspect)
        let size = stage == 0 ? from.size : (stage == 1 ? lifted : small)
        let center = stage == 0 ? CGPoint(x: from.midX, y: from.midY)
            : (stage == 1 ? CGPoint(x: from.midX, y: from.midY - 14) : CGPoint(x: target.midX, y: target.midY))
        let edge: CGFloat = stage == 0 ? 0 : (stage == 1 ? 5 : 1.5)
        ZStack(alignment: .topLeading) {
            Image(nsImage: flight.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()
                .padding(edge)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: stage == 0 ? 0 : 3, style: .continuous))
                .shadow(color: .black.opacity(stage == 1 ? 0.45 : 0), radius: 8, y: 3)
                .rotationEffect(.degrees(stage == 1 ? -4 : 0))
                .opacity(stage >= 3 ? 0 : 1)
                .position(center)
            Circle()
                .strokeBorder(Theme.accent, lineWidth: 2)
                .frame(width: 30, height: 30)
                .scaleEffect(stage >= 3 ? 1.7 : 0.6)
                .opacity(stage == 2 ? 0.9 : 0)
                .position(x: target.midX, y: target.midY)
        }
        .task {
            try? await Task.sleep(nanoseconds: 40_000_000)
            withAnimation(.easeOut(duration: 0.28)) { stage = 1 }
            try? await Task.sleep(nanoseconds: 380_000_000)
            withAnimation(.easeIn(duration: 0.5)) { stage = 2 }
            try? await Task.sleep(nanoseconds: 520_000_000)
            withAnimation(.easeOut(duration: 0.35)) { stage = 3 }
            try? await Task.sleep(nanoseconds: 380_000_000)
            NotchFly.shared.land(flight.id)
        }
    }
}

/// The camera's flash: a white wash over the view a flight starts from, fading at once. The view draws it itself (inside the island's outline).
struct NotchFlyFlash: View {
    let from: String
    @ObservedObject private var fly = NotchFly.shared
    @State private var lit = false

    var body: some View {
        Color.white
            .opacity(lit ? 0.9 : 0)
            .allowsHitTesting(false)
            .onChange(of: fly.flight?.id) {
                guard let flight = fly.flight, flight.from == from else { return }
                lit = true
                withAnimation(.easeOut(duration: 0.3)) { lit = false }
            }
    }
}
