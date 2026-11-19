import AppKit
import PDFKit
import SwiftUI

/// Sample files for scripted runs and the gallery, written inside Scout-Automation (never anywhere else).
enum TraySamples {
    static var folder: URL { AppPaths.folder("Tray-Samples") }

    @discardableResult
    static func makeFiles() -> [URL] {
        var urls: [URL] = []
        urls.append(image("Beach.png", colors: [NSColor(red: 0.98, green: 0.72, blue: 0.45, alpha: 1), NSColor(red: 0.25, green: 0.55, blue: 0.85, alpha: 1)], png: true))
        urls.append(image("Sunset.jpg", colors: [NSColor(red: 0.95, green: 0.35, blue: 0.40, alpha: 1), NSColor(red: 0.40, green: 0.20, blue: 0.55, alpha: 1)], png: false))
        urls.append(pdf("Invoice 1042.pdf"))
        urls.append(text("Meeting notes.txt", "Agenda\n- Roadmap\n- Hiring\n- Budget\n"))
        urls.append(text("Budget 2026.csv", "Month,Spend\nJan,1200\nFeb,1350\nMar,990\n"))
        return urls
    }

    private static func image(_ name: String, colors: [NSColor], png: Bool) -> URL {
        let url = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let size = NSSize(width: 640, height: 420)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: colors)?.draw(in: rect, angle: 70)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 420, y: 250, width: 90, height: 90)).fill()
            NSColor.black.withAlphaComponent(0.18).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 640, height: 90)).fill()
            return true
        }
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let data = rep.representation(using: png ? .png : .jpeg, properties: [.compressionFactor: 0.9]) {
            try? data.write(to: url)
        }
        return url
    }

    private static func pdf(_ name: String) -> URL {
        let url = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        var box = CGRect(x: 0, y: 0, width: 420, height: 560)
        if let ctx = CGContext(url as CFURL, mediaBox: &box, nil) {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSAttributedString(string: "Invoice 1042", attributes: [.font: NSFont.systemFont(ofSize: 28, weight: .bold)]).draw(at: NSPoint(x: 40, y: 480))
            NSAttributedString(string: "Total due: 480.00", attributes: [.font: NSFont.systemFont(ofSize: 16)]).draw(at: NSPoint(x: 40, y: 440))
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
            ctx.closePDF()
        }
        return url
    }

    private static func text(_ name: String, _ body: String) -> URL {
        let url = folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try? body.write(to: url, atomically: true, encoding: .utf8) }
        return url
    }

    /// Fills a store with the samples plus a dropped text and a dropped link.
    @MainActor
    static func fill(_ store: TrayStore) {
        store.start()
        guard store.items.isEmpty else { return }
        store.add(files: makeFiles())
        store.add(text: "Remember to send the slides before Friday.")
        store.add(link: URL(string: "https://www.swift.org/blog/")!)
    }
}
