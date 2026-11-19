import AppKit
import ApplicationServices
import SwiftUI

// B2: Screenshot, Windows, Color Picker, Volume — the tools that act on the Mac rather than open a panel.

// MARK: - Screenshot

@MainActor
enum ScreenshotTool {
    enum Mode: String, CaseIterable, Identifiable {
        case region, window, screen
        var id: String { rawValue }
        var title: String {
            switch self {
            case .region: String(localized: "Region")
            case .window: String(localized: "Window")
            case .screen: String(localized: "Screen")
            }
        }
    }

    static var defaultMode: Mode { Mode(rawValue: UserDefaults.standard.string("shot.defaultMode", default: "region")) ?? .region }
    static var savesToDisk: Bool { UserDefaults.standard.bool("shot.saveToDisk", default: false) }
    static var playsSound: Bool { UserDefaults.standard.bool("shot.sound", default: true) }
    static var showsCard: Bool { UserDefaults.standard.bool("shot.showCard", default: true) }

    #if APPSTORE
    /// The App Store edition saves into the Pictures folder (entitlement), with the container as a fallback.
    static var folder: URL { UserFolders.saveFolder(.picturesDirectory, named: "Scout Screenshots") }
    #else
    static var folder: URL {
        if let path = UserDefaults.standard.string(forKey: "shot.folder"), !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }
    #endif

    static func fileName(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Scout Screenshot \(f.string(from: date)).png"
    }

    static func capture(_ mode: Mode) {
        guard !ScoutRuntime.isScripted else {
            #if APPSTORE
            // Scripted runs show the sample card (no capture, no permission, no file).
            present(image: ArtworkFactory.image(seed: "Screenshot", size: 240), message: String(localized: "Screenshot copied"), savedURL: nil)
            #else
            Toast.show("Screenshot (\(mode.title.lowercased())) skipped in a scripted run", symbol: "camera.viewfinder", style: .info)
            #endif
            return
        }
        #if APPSTORE
        let toDisk = savesToDisk
        let sound = playsSound
        SandboxedCapture.capture(mode) { cgImage, scale in
            finish(cgImage: cgImage, scale: scale, toDisk: toDisk, sound: sound)
        }
        #else
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scout-shot-\(UUID().uuidString).png")
        var args: [String] = []
        if !playsSound { args.append("-x") }
        switch mode {
        case .region: args += ["-i", "-s"]
        case .window: args += ["-i", "-w"]
        case .screen: args += ["-m"]
        }
        args.append(temp.path)
        let toDisk = savesToDisk
        let destination = folder
        // A short pause lets the ring fade out so it isn't in the picture.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
            Shell.run("/usr/sbin/screencapture", args)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { finish(temp: temp, toDisk: toDisk, folder: destination) }
            }
        }
        #endif
    }

    #if APPSTORE
    /// A ScreenCaptureKit picture: clipboard always, a PNG in Pictures when "save to disk" is on.
    private static func finish(cgImage: CGImage, scale: CGFloat, toDisk: Bool, sound: Bool) {
        let image = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        var savedURL: URL?
        if toDisk, let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) {
            let target = folder.appendingPathComponent(fileName())
            if (try? data.write(to: target, options: .atomic)) != nil { savedURL = target }
        }
        if sound { playShutter() }
        present(image: image, message: savedURL != nil ? String(localized: "Screenshot saved and copied") : String(localized: "Screenshot copied"), savedURL: savedURL)
    }

    private static func playShutter() {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        if FileManager.default.fileExists(atPath: path) { NSSound(contentsOfFile: path, byReference: true)?.play() }
    }
    #else
    private static func finish(temp: URL, toDisk: Bool, folder: URL) {
        guard FileManager.default.fileExists(atPath: temp.path), let image = NSImage(contentsOf: temp) else { return }   // cancelled
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        var savedURL: URL?
        if toDisk {
            let target = folder.appendingPathComponent(fileName())
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if (try? FileManager.default.moveItem(at: temp, to: target)) != nil { savedURL = target }
        }
        if savedURL == nil { try? FileManager.default.removeItem(at: temp) }
        present(image: image, message: savedURL != nil ? String(localized: "Screenshot saved and copied") : String(localized: "Screenshot copied"), savedURL: savedURL)
    }
    #endif

    /// The card under the notch (or a toast when cards are off).
    private static func present(image: NSImage, message: String, savedURL: URL?) {
        if showsCard {
            LiveActivityCenter.shared.present(NotchCard(id: "toast", duration: 3, onTap: {
                if let savedURL { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) }
            }) {
                ScreenshotCardView(image: image, message: message, canReveal: savedURL != nil)
            })
        } else {
            Toast.show(verbatim: message, symbol: "camera.viewfinder")
        }
    }
}

struct ScreenshotCardView: View {
    let image: NSImage
    let message: String
    var canReveal = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: image).resizable().scaledToFill().frame(width: 54, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 1) {
                Text(message).font(.system(size: 13, weight: .medium))
                Text(canReveal ? "Click to show in Finder" : "Ready to paste").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

// MARK: - Color picker

@MainActor
enum ColorPickerTool {
    enum Format: String, CaseIterable, Identifiable {
        case hex, rgb, hsl
        var id: String { rawValue }
        var title: String { rawValue.uppercased() }
    }

    private static var sampler: NSColorSampler?

    static var format: Format { Format(rawValue: UserDefaults.standard.string("ring.colorFormat", default: "hex")) ?? .hex }

    static func pick() {
        guard !ScoutRuntime.isScripted else {
            present(NSColor(srgbRed: 1, green: 0.69, blue: 0.13, alpha: 1))
            return
        }
        let s = NSColorSampler()
        sampler = s
        s.show { color in
            MainActor.assumeIsolated {
                sampler = nil
                if let color { present(color) }
            }
        }
    }

    static func string(for color: NSColor, format: Format) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded()), b = Int((c.blueComponent * 255).rounded())
        switch format {
        case .hex: return String(format: "#%02X%02X%02X", r, g, b)
        case .rgb: return "rgb(\(r), \(g), \(b))"
        case .hsl:
            let h = Int((c.hueComponent * 360).rounded())
            let rf = c.redComponent, gf = c.greenComponent, bf = c.blueComponent
            let maxV = max(rf, gf, bf), minV = min(rf, gf, bf)
            let l = (maxV + minV) / 2
            let d = maxV - minV
            let s = d == 0 ? 0 : d / (1 - abs(2 * l - 1))
            return "hsl(\(h), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
        }
    }

    private static func present(_ color: NSColor) {
        let text = string(for: color, format: format)
        if !ScoutRuntime.isScripted {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        let swatch = Color(nsColor: color)
        LiveActivityCenter.shared.present(NotchCard(id: "toast", duration: 2.5) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(swatch).frame(width: 26, height: 26)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 0) {
                    Text(text).font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text("Copied").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        })
    }
}
