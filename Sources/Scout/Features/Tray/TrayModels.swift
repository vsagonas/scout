import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One thing parked in the Tray: a file kept by bookmark (the original never moves), or a text/link file
/// Scout wrote into its own tray folder.
struct TrayItem: Identifiable, Codable, Hashable {
    enum Kind: String, Codable { case file, text, link, converted }

    var id = UUID()
    var name: String
    var kind: Kind
    /// Bookmark to the original file (kind `.file` and `.converted`).
    var bookmark: Data?
    /// File name inside the tray folder (kind `.text` and `.link`).
    var storedName: String?
    var addedAt = Date()
}

/// What came in through a drop or a paste.
enum DroppedThing {
    case file(URL)
    case link(URL)
    case text(String)
}

enum DropReader {
    static let acceptedTypes: [UTType] = [.fileURL, .url, .utf8PlainText, .plainText, .text]

    /// Turns the providers of a drop into files, links and text (files first, then links, then text).
    static func read(_ providers: [NSItemProvider]) async -> [DroppedThing] {
        var things: [DroppedThing] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await loadURL(provider, UTType.fileURL.identifier) {
                things.append(.file(url))
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      let url = await loadURL(provider, UTType.url.identifier) {
                things.append(url.isFileURL ? .file(url) : .link(url))
            } else if let text = await loadText(provider) {
                if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).contains(" ") {
                    things.append(.link(url))
                } else {
                    things.append(.text(text))
                }
            }
        }
        return things
    }

    private static func loadURL(_ provider: NSItemProvider, _ identifier: String) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                if let url = item as? URL { continuation.resume(returning: url) }
                else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { continuation.resume(returning: url) }
                else if let string = item as? String, let url = URL(string: string) { continuation.resume(returning: url) }
                else { continuation.resume(returning: nil) }
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        for identifier in [UTType.utf8PlainText.identifier, UTType.plainText.identifier, UTType.text.identifier]
        where provider.hasItemConformingToTypeIdentifier(identifier) {
            let text: String? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                    if let s = item as? String { continuation.resume(returning: s) }
                    else if let d = item as? Data { continuation.resume(returning: String(data: d, encoding: .utf8)) }
                    else { continuation.resume(returning: nil) }
                }
            }
            if let text, !text.isEmpty { return text }
        }
        return nil
    }
}

enum UniqueName {
    /// `dir/Name.ext`, or `dir/Name 2.ext`, `Name 3.ext`… when that exists.
    static func url(in dir: URL, base: String, ext: String) -> URL {
        let safe = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let fm = FileManager.default
        func candidate(_ n: Int) -> URL {
            let name = n == 1 ? safe : "\(safe) \(n)"
            return dir.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
        }
        var n = 1
        while fm.fileExists(atPath: candidate(n).path) { n += 1 }
        return candidate(n)
    }
}

extension URL {
    var isImageFile: Bool { UTType(filenameExtension: pathExtension)?.conforms(to: .image) ?? false }
    var isMovieFile: Bool { UTType(filenameExtension: pathExtension)?.conforms(to: .movie) ?? false }
    var isAudioFile: Bool { UTType(filenameExtension: pathExtension)?.conforms(to: .audio) ?? false }
}
