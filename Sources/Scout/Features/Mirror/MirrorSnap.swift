import AppKit
import SwiftUI

// The Snap key of the Mirror tab.
// One click takes one still of the picture on screen (only while the camera is already on and showing), puts it on
// the clipboard as a picture (PNG and TIFF, ready to paste anywhere), and the island shows it flying into the Clipboard key (`NotchFly`).
// The clipboard history keeps it like any other copied picture. Nothing is taken without the click, and nothing leaves the Mac.

@MainActor
enum MirrorSnap {
    /// The pasteboard the picture goes to; tests give their own, so a headless run never touches the real clipboard.
    static var pasteboard: () -> NSPasteboard = { .general }
    /// The flight into the Clipboard key; tests watch `NotchFly.shared.last`.
    static let from = "mirror.picture"
    static let to = "tab.clipboard"
    private static var busy = false

    static func start(model: MirrorModel, tools: MirrorTools, flip: Bool) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            guard let still = await MirrorCamera.still(model: model, tools: tools, flip: flip) else {
                Toast.show("Turn on the camera first", symbol: "camera", style: .info)
                return
            }
            guard copy(still) else {
                Toast.show("Couldn't copy the picture", symbol: "exclamationmark.triangle.fill", style: .error)
                return
            }
            NotchFly.shared.launch(image: NSImage(cgImage: still, size: CGSize(width: still.width, height: still.height)), from: from, to: to)
        }
    }

    /// Puts the picture on the pasteboard as PNG and TIFF (what apps paste). False when it cannot be encoded.
    @discardableResult
    static func copy(_ image: CGImage) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        let pb = pasteboard()
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        pb.setData(png, forType: .png)
        if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        return true
    }
}
