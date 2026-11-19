import AppKit
import SwiftUI

/// The polaroid first, in a small window of its own, before anything is shared.
/// The picture, then Copy, Save… and Close, and Share…
/// (the system share sheet from that key). The window floats one step above the island, in the middle of the screen; a new polaroid replaces
/// the one on show. Choosing a service in the share sheet closes it; Save… hangs its panel from it as a sheet.
@MainActor
final class MirrorSharePreview {
    static let shared = MirrorSharePreview()

    private var window: ScoutWindow?
    private let offscreen: Bool
    /// The window, for Save… and the self-test.
    var currentWindow: NSWindow? { window?.isVisible == true ? window : nil }

    /// `offscreen`: a self-test's own preview (the window stays at x -20000 and never takes the keyboard).
    init(offscreen: Bool = false) {
        self.offscreen = offscreen
    }

    func show(_ polaroid: NSImage) {
        guard offscreen || !ScoutRuntime.isScripted else { return }
        let hosting = NSHostingView(rootView: MirrorSharePreviewView(image: polaroid) { [weak self] in self?.close() })
        let size = hosting.fittingSize
        let w: ScoutWindow
        if let existing = window {
            w = existing
        } else {
            w = ScoutWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
            w.allowsOffscreen = offscreen
            w.title = String(localized: "Polaroid")
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.level = SettingsNotchHold.aboveNotch
            window = w
        }
        w.contentView = hosting
        w.setContentSize(size)
        if offscreen {
            w.setFrameOrigin(CGPoint(x: -20000, y: -20000))
            w.orderFrontRegardless()
        } else {
            w.center()
            WindowFront.show(w)
        }
    }

    func close() {
        window?.orderOut(nil)
    }
}

/// The preview's content: the polaroid at 0.8 of its size, and the keys under it.
struct MirrorSharePreviewView: View {
    let image: NSImage
    let close: () -> Void
    @State private var anchor = MirrorShareAnchor.Box()

    static let pictureWidth: CGFloat = MirrorPolaroid.size.width * 0.8
    /// The narrowest the window is; it grows when the four keys need more (a longer language).
    static let width: CGFloat = 420

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: Self.pictureWidth)
                .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
                .accessibilityLabel("The polaroid")
            HStack(spacing: 8) {
                Button { MirrorShare.copy(image) } label: { Label("Copy", systemImage: "doc.on.doc").fixedSize() }
                Button { MirrorShare.save(image, on: MirrorSharePreview.shared.currentWindow) } label: { Label("Save…", systemImage: "square.and.arrow.down").fixedSize() }
                Spacer(minLength: 8)
                Button(action: close) { Text("Close").fixedSize() }.keyboardShortcut(.cancelAction)
                Button {
                    MirrorShare.shared.present(image, from: anchor.view, holdNotch: false, onChosen: close)
                } label: {
                    Label("Share…", systemImage: "square.and.arrow.up").fixedSize()
                }
                .keyboardShortcut(.defaultAction)
                .background(MirrorShareAnchor(box: anchor))
            }
        }
        .padding(.top, 36)
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
        // At least 420 pt, and as wide as the four keys need in the language shown: Greek's names did not fit a fixed 420 and the first and last
        // key were cut by the window's edges.
        .frame(minWidth: Self.width)
        .fixedSize()
    }
}
