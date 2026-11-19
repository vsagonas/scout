import AppKit
import QuickLookThumbnailing
import SwiftUI

/// QuickLook thumbnails with a cache. Falls back to the file's icon while loading (and when QuickLook has none).
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSString, NSImage>()

    private func key(_ url: URL, _ side: CGFloat) -> NSString { "\(url.path)|\(Int(side))" as NSString }

    func cached(_ url: URL, side: CGFloat) -> NSImage? { cache.object(forKey: key(url, side)) }

    func thumbnail(_ url: URL, side: CGFloat) async -> NSImage? {
        if let hit = cached(url, side: side) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: 2, representationTypes: .all)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = rep.nsImage
        cache.setObject(image, forKey: key(url, side))
        return image
    }

    func invalidate(_ url: URL) { cache.removeAllObjects() }
}

/// A file's thumbnail (or its icon) in a square.
struct FileThumbnail: View {
    let url: URL
    var side: CGFloat = 64
    @State private var image: NSImage?

    var body: some View {
        Image(nsImage: image ?? Thumbnails.shared.cached(url, side: side) ?? NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: side, height: side)
            .task(id: url) { image = await Thumbnails.shared.thumbnail(url, side: side) }
    }
}
