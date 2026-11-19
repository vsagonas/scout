import CryptoKit
import SwiftUI

#if !APPSTORE

// A6 — synced lyrics from LRCLIB (https://lrclib.net), cached on disk. Never fetched in scripted runs.
// Not in the App Store edition (unlicensed song lyrics, guideline 5.2.1): the whole file is compiled out there.

struct LyricLine: Codable, Equatable, Identifiable {
    let id: Int
    let time: Double
    let text: String
}

enum LyricsState: Equatable {
    case idle
    case loading
    case synced([LyricLine])
    case none
}

@MainActor
final class LyricsService: ObservableObject {
    static let shared = LyricsService()

    @Published private(set) var state: LyricsState = .idle
    private var currentKey: String?
    private var task: Task<Void, Never>?

    private struct Cached: Codable {
        var lines: [LyricLine]
        var fetched: Date
    }

    func load(for track: NowPlayingTrack?) {
        guard let track, MediaPrefs.lyrics else {
            task?.cancel()
            currentKey = nil
            state = .idle
            return
        }
        let key = "\(track.key)|\(Int(track.duration.rounded()))"
        guard key != currentKey else { return }
        currentKey = key
        task?.cancel()
        if ScoutRuntime.isScripted {
            let lines = Self.sampleLines(for: track.title)
            state = lines.isEmpty ? .none : .synced(lines)
            return
        }
        if let cached = readCache(key) {
            state = cached.lines.isEmpty ? .none : .synced(cached.lines)
            return
        }
        state = .loading
        task = Task { [weak self] in
            let lines = await Self.fetch(track)
            guard !Task.isCancelled, let self, self.currentKey == key else { return }
            if let lines {
                self.writeCache(key, lines)
                self.state = lines.isEmpty ? .none : .synced(lines)
            } else {
                // Network trouble: say "none" for now but do not remember it.
                self.state = .none
            }
        }
    }

    // MARK: Fetch

    /// nil = could not ask (offline); empty = LRCLIB has no synced lyrics for it.
    nonisolated private static func fetch(_ track: NowPlayingTrack) async -> [LyricLine]? {
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        comps.queryItems = [
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "album_name", value: track.album),
            URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))),
        ]
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Scout/0.1 (macOS menu-bar app)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return [] }
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let synced = json["syncedLyrics"] as? String, !synced.isEmpty else { return [] }
        return parse(synced)
    }

    /// "[mm:ss.xx] words" (a line may carry several time tags).
    nonisolated static func parse(_ text: String) -> [LyricLine] {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#) else { return [] }
        var raw: [(Double, String)] = []
        for row in text.split(whereSeparator: \.isNewline) {
            let line = String(row)
            let ns = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let words = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                raw.append((minutes * 60 + seconds, words))
            }
        }
        raw.sort { $0.0 < $1.0 }
        return raw.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }

    // MARK: Cache

    private func cacheURL(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(40)
        return AppPaths.folder("Lyrics").appendingPathComponent("\(hash).json")
    }

    private func readCache(_ key: String) -> Cached? {
        guard let data = try? Data(contentsOf: cacheURL(key)),
              let cached = try? JSONDecoder.scout.decode(Cached.self, from: data) else { return nil }
        // "No lyrics" answers are asked again after a week.
        if cached.lines.isEmpty, Date().timeIntervalSince(cached.fetched) > 7 * 86400 { return nil }
        return cached
    }

    private func writeCache(_ key: String, _ lines: [LyricLine]) {
        guard let data = try? JSONEncoder.scout.encode(Cached(lines: lines, fetched: Date())) else { return }
        let url = cacheURL(key)
        DispatchQueue.global(qos: .utility).async { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Sample (scripted runs and the gallery)

    static func sampleLines(for title: String) -> [LyricLine] {
        let words: [String]
        switch title {
        case "Midnight Cartography":
            words = ["Fold the map along the river line", "Every road still smells like rain",
                     "I marked the place where the streetlights end", "And wrote your name in the margin, plain",
                     "We were only ever chasing north", "A needle trembling in the dark",
                     "If the compass lies, I'll walk it still", "Redraw the world from a single spark",
                     "Midnight cartography", "Tracing home in the quiet blue",
                     "Midnight cartography", "Every wrong turn led to you",
                     "Hold the lantern, count the stars", "We'll name the ones that have no name",
                     "Fold the map, the morning's here", "And nothing out there is the same"]
        case "Paper Lanterns":
            words = ["Paper lanterns on the water", "Drifting slow past the bridge", "Every wish a little flame",
                     "Every flame a little ridge", "Carry me, carry me", "Down to where the river bends"]
        default:
            return []
        }
        return words.enumerated().map { LyricLine(id: $0.offset, time: 6 + Double($0.offset) * 12.5, text: $0.element) }
    }
}
#endif
