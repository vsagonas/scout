import AppKit
import SwiftUI

// The gallery renders views offscreen to PNG, so you can see your work without opening anything on
// the owner's screen:  Scout.app/Contents/MacOS/Scout --gallery <dir> [--only <prefix>]
// Each module registers items (with sample data!) in its module's `registerGallery()`.
// Limits: blur/glass can't be captured offscreen (GlassBackground draws a flat fill instead), and the
// camera/terminal/web views show their own placeholders.

@MainActor
enum Gallery {
    enum Backdrop {
        /// A colorful wallpaper (to judge contrast over a busy background).
        case wallpaper
        /// The top of a screen: black menu-bar strip with the notch, wallpaper below.
        case screenTop
        /// Plain window background (settings pages, panels).
        case window
    }

    struct Item {
        let name: String
        let size: CGSize
        let backdrop: Backdrop
        let make: () -> AnyView
    }

    private(set) static var items: [Item] = []

    /// `name` should start with the module's area, e.g. "ring-page1", "nook-weather", "settings-tray".
    static func register<V: View>(_ name: String, size: CGSize, backdrop: Backdrop = .wallpaper,
                                  @ViewBuilder _ make: @escaping () -> V) {
        items.append(Item(name: name, size: size, backdrop: backdrop, make: { AnyView(make()) }))
    }
}

struct GalleryBackdropView: View {
    let backdrop: Gallery.Backdrop
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch backdrop {
        case .window:
            Color(nsColor: .windowBackgroundColor)
        case .wallpaper:
            wallpaper
        case .screenTop:
            ZStack(alignment: .top) {
                wallpaper
                Color.black.frame(height: 37)
            }
        }
    }

    private var wallpaper: some View {
        LinearGradient(colors: scheme == .dark
                       ? [Color(red: 0.10, green: 0.13, blue: 0.28), Color(red: 0.32, green: 0.12, blue: 0.30), Color(red: 0.05, green: 0.25, blue: 0.30)]
                       : [Color(red: 0.55, green: 0.75, blue: 0.98), Color(red: 0.98, green: 0.72, blue: 0.62), Color(red: 0.70, green: 0.92, blue: 0.78)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Built-in items so the gallery always has something, and a sample of the shared styles.
@MainActor
enum LeadGallery {
    static func register() {
        Gallery.register("core-toast", size: CGSize(width: 320, height: 80)) {
            ToastView(message: "Screenshot saved and copied", symbol: "camera.viewfinder", style: .success)
                .background(GlassBackground(Capsule()))
        }
        Gallery.register("core-placeholder", size: CGSize(width: 240, height: 140)) {
            PlaceholderView(title: "Weather", lane: .c)
        }
        Gallery.register("core-panel-header", size: CGSize(width: 360, height: 120), backdrop: .wallpaper) {
            VStack(spacing: 0) {
                PanelHeader("Calculator", symbol: "plusminus")
                Spacer()
            }
            .background(GlassBackground(cornerRadius: 16))
            .padding(10)
        }
        Gallery.register("core-controls", size: CGSize(width: 420, height: 300), backdrop: .window) {
            ControlsSample()
        }
    }
}

/// Proves AppKit-backed controls render in the gallery (text fields, toggles, pickers, sliders, lists).
private struct ControlsSample: View {
    @State private var text = "5 km to mi"
    @State private var on = true
    @State private var value = 0.6
    @State private var pick = "Glass"
    @State private var combo: KeyCombo? = .optionSpace

    var body: some View {
        Form {
            TextField("Expression", text: $text)
            Toggle("Open on hover", isOn: $on)
            Slider(value: $value) { Text("Size") }
            Picker("Style", selection: $pick) { ForEach(["Classic", "Glass"], id: \.self) { Text($0) } }
            LabeledContent("Shortcut") { ShortcutRecorder(combo: $combo) }
        }
        .formStyle(.grouped)
    }
}

final class GalleryRunner: NSObject, NSApplicationDelegate {
    let output: URL

    init(output: URL) { self.output = output }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await self.renderAll()
            NSApp.terminate(nil)
        }
    }

    @MainActor
    private func renderAll() async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        Modules.registerGalleryAll()
        let items = Gallery.items.filter { item in
            guard let prefix = ScoutRuntime.galleryFilter else { return true }
            return item.name.hasPrefix(prefix)
        }
        var written: [String] = []
        for scheme in [ColorScheme.light, .dark] {
            for item in items {
                if let name = await render(item, scheme: scheme) { written.append(name) }
            }
        }
        let list = written.joined(separator: "\n")
        try? list.write(to: output.appendingPathComponent("gallery.txt"), atomically: true, encoding: .utf8)
        print("Scout gallery: \(written.count) images in \(output.path)")
    }

    @MainActor
    private func render(_ item: Gallery.Item, scheme: ColorScheme) async -> String? {
        guard let rep = await Gallery.renderImage(item, scheme: scheme) else { return nil }
        let name = "\(item.name)-\(scheme == .dark ? "dark" : "light").png"
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        try? png.write(to: output.appendingPathComponent(name))
        return name
    }
}

extension Gallery {
    /// One item drawn offscreen at 2x (the gallery's pictures and the pseudo-language check use the same drawing).
    @MainActor
    static func renderImage(_ item: Item, scheme: ColorScheme) async -> NSBitmapImageRep? {
        let size = item.size
        let root = ZStack {
            GalleryBackdropView(backdrop: item.backdrop)
            item.make()
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, scheme)
        .environment(\.layoutDirection, L10nRuntime.scriptedLanguageIsRightToLeft ? .rightToLeft : .leftToRight)   // SCOUT_LANG=ar: ordinary windows mirror, the island's content keeps its own left to right

        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        // Let SwiftUI lay out, run onAppear and settle sample data.
        try? await Task.sleep(nanoseconds: 250_000_000)
        hosting.layoutSubtreeIfNeeded()
        hosting.display()

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }
}
