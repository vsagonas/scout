import SwiftUI

@MainActor
enum PocketsFeature {
    static func start() {
        PocketsController.shared.start()
        // scout://pocket.demo makes a Pocket with the sample files (works in scripted runs).
        DebugCommands.register("pocket.demo") { _ in
            let store = PocketStore.shared
            store.load()
            let id = store.create()
            store.add(TraySamples.makeFiles(), to: id)
            PocketsController.shared.show(id, near: NSEvent.mouseLocation)
        }
        DebugCommands.register("pocket.minimize") { _ in
            if let p = PocketStore.shared.pockets.first(where: { !$0.minimized }) { PocketsController.shared.minimize(p.id) }
        }
    }

    static func registerSelfTests() {
        FeaturesSelfTest.add("pockets: shake detector fires on a shake, not on a drag") {
            var gentle = ShakeDetector()
            var t = 0.0
            var fired = false
            var x: CGFloat = 400
            for step in 0..<16 {            // zig-zag: 45 pt per move, a change every two moves
                x += (step / 2) % 2 == 0 ? 45 : -45
                t += 0.04
                if gentle.feed(x: x, at: t) { fired = true }
            }
            var straight = ShakeDetector()
            var firedStraight = false
            for step in 0..<40 { if straight.feed(x: 100 + CGFloat(step) * 12, at: Double(step) * 0.02) { firedStraight = true } }
            // A slow wobble (changes spread over several seconds) is not a shake.
            var slow = ShakeDetector()
            var firedSlow = false
            for step in 0..<12 { if slow.feed(x: 300 + (step % 2 == 0 ? 60 : -60), at: Double(step) * 0.9) { firedSlow = true } }
            // Firm ignores a small wiggle (22 pt moves) but still catches a big one (45 pt moves).
            var firm = ShakeDetector()
            firm.sensitivity = .firm
            var firedSmall = false
            x = 400; t = 0
            for step in 0..<16 { x += (step / 2) % 2 == 0 ? 22 : -22; t += 0.04; if firm.feed(x: x, at: t) { firedSmall = true } }
            var firm2 = ShakeDetector()
            firm2.sensitivity = .firm
            var firedBig = false
            x = 400; t = 0
            for step in 0..<20 { x += (step / 2) % 2 == 0 ? 45 : -45; t += 0.04; if firm2.feed(x: x, at: t) { firedBig = true } }
            return fired && !firedStraight && !firedSlow && !firedSmall && firedBig
        }
    }

    static func registerGallery() {
        Gallery.register("pocket-view", size: CGSize(width: 260, height: 270), backdrop: .wallpaper) {
            PocketPreview(files: TraySamples.makeFiles(), minimized: false)
        }
        Gallery.register("pocket-view-empty", size: CGSize(width: 260, height: 270), backdrop: .wallpaper) {
            PocketPreview(files: [], minimized: false)
        }
        Gallery.register("pocket-switcher", size: CGSize(width: 320, height: 90), backdrop: .wallpaper) {
            PocketPreview(files: TraySamples.makeFiles(), minimized: true)
        }
    }
}

/// Gallery stand-in: a Pocket with its own store (never the real one).
struct PocketPreview: View {
    let files: [URL]
    let minimized: Bool

    var body: some View {
        if minimized {
            HStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(Theme.accent).font(.system(size: 12))
                ForEach([5, 2], id: \.self) { n in
                    Text(verbatim: "\(n) files").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 9).padding(.vertical, 4).background(Capsule().fill(Color.primary.opacity(0.10)))
                }
            }
            .padding(.horizontal, 12).frame(height: 44).background(GlassBackground(Capsule()))
        } else {
            PocketPreviewBody(files: files)
        }
    }
}

private struct PocketPreviewBody: View {
    let files: [URL]
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(Theme.accent).font(.system(size: 12))
                Text("Pocket").font(.system(size: 12, weight: .semibold))
                Spacer()
                Image(systemName: "minus").font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20).background(Circle().fill(.quaternary))
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20).background(Circle().fill(.quaternary))
            }
            ZStack {
                if files.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.down.doc").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                        Text("Drop files here").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4])).foregroundStyle(.tertiary))
                } else {
                    ForEach(Array(files.prefix(4).enumerated().reversed()), id: \.offset) { index, url in
                        FileThumbnail(url: url, side: 64).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                            .rotationEffect(.degrees(Double(index) * 5 - 4)).offset(x: CGFloat(index) * 7 - 10, y: CGFloat(index) * -4 + 4)
                    }
                    VStack { Spacer(); HStack { Spacer(); Text("\(files.count)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(Color.black.opacity(0.85)).padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Theme.accent)) } }
                }
            }
            .frame(height: 100)
            HStack(spacing: 6) {
                ForEach(["airplayaudio", "arrow.triangle.2.circlepath", "tray.full"], id: \.self) { s in
                    Image(systemName: s).font(.system(size: 11, weight: .semibold)).frame(width: 30, height: 26).background(Capsule().fill(.quaternary))
                }
                Spacer()
                Image(systemName: "trash").font(.system(size: 11, weight: .semibold)).frame(width: 30, height: 26).background(Capsule().fill(.quaternary))
            }
        }
        .padding(10).frame(width: 196, height: 212).background(GlassBackground(cornerRadius: 20))
    }
}
