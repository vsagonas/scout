import AppKit
import SwiftUI

/// A Pocket: a small floating collection of files that appeared when you shook a drag.
struct Pocket: Identifiable, Codable, Hashable {
    struct Entry: Identifiable, Codable, Hashable {
        var id = UUID()
        var bookmark: Data
        var name: String
    }

    var id = UUID()
    var entries: [Entry] = []
    var minimized = false
    var created = Date()
}

@MainActor
final class PocketStore: ObservableObject {
    static let shared = PocketStore()

    enum Key {
        static let enabled = "pocket.enabled"
        static let sensitivity = "pocket.sensitivity"
        static let restore = "pocket.restore"
    }

    @Published private(set) var pockets: [Pocket] = []
    private let file = JSONFile<[Pocket]>("pockets.json")
    private var loaded = false

    func load() {
        guard !loaded else { return }
        loaded = true
        pockets = (file.load() ?? []).filter { !$0.entries.isEmpty }
    }

    private func save() { file.save(pockets) }

    func pocket(_ id: UUID) -> Pocket? { pockets.first { $0.id == id } }

    func urls(of id: UUID) -> [URL] {
        guard let p = pocket(id) else { return [] }
        return p.entries.compactMap { Self.resolve($0) }
    }

    static func resolve(_ entry: Pocket.Entry) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: entry.bookmark, options: FileScope.resolution, relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        FileScope.begin(url)    // sandboxed edition: the file stays readable while it is in a Pocket
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    @discardableResult
    func create() -> UUID {
        let p = Pocket()
        pockets.append(p)
        return p.id
    }

    func add(_ files: [URL], to id: UUID) {
        guard let i = pockets.firstIndex(where: { $0.id == id }) else { return }
        for url in files {
            let std = url.standardizedFileURL
            if pockets[i].entries.contains(where: { Self.resolve($0)?.standardizedFileURL == std }) { continue }
            FileScope.begin(url)
            guard let data = try? url.bookmarkData(options: FileScope.creation, includingResourceValuesForKeys: nil, relativeTo: nil) else { continue }
            pockets[i].entries.append(Pocket.Entry(bookmark: data, name: std.lastPathComponent))
        }
        save()
    }

    func remove(entry: UUID, from id: UUID) {
        guard let i = pockets.firstIndex(where: { $0.id == id }) else { return }
        if let e = pockets[i].entries.first(where: { $0.id == entry }), let url = Self.resolve(e) { FileScope.end(url) }
        pockets[i].entries.removeAll { $0.id == entry }
        save()
    }

    func empty(_ id: UUID) {
        guard let i = pockets.firstIndex(where: { $0.id == id }) else { return }
        for e in pockets[i].entries { if let url = Self.resolve(e) { FileScope.end(url) } }
        pockets[i].entries = []
        save()
    }

    func setMinimized(_ minimized: Bool, _ id: UUID) {
        guard let i = pockets.firstIndex(where: { $0.id == id }) else { return }
        pockets[i].minimized = minimized
        save()
    }

    func discard(_ id: UUID) {
        if let p = pocket(id) { for e in p.entries { if let url = Self.resolve(e) { FileScope.end(url) } } }
        pockets.removeAll { $0.id == id }
        save()
    }
}
