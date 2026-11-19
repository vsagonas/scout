#if !APPSTORE
import AppKit
import Foundation

/// Where yt-dlp, ffmpeg and deno live. Nothing is ever installed automatically.
enum VideoTools {
    static let searchFolders = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
    static let brewPath = "/opt/homebrew/bin/brew"

    static func find(_ name: String) -> URL? {
        if name == "yt-dlp", let custom = UserDefaults.standard.string(forKey: "video.ytdlpPath"), !custom.isEmpty,
           FileManager.default.isExecutableFile(atPath: custom) { return URL(fileURLWithPath: custom) }
        for folder in searchFolders {
            let path = "\(folder)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    static var ytdlp: URL? { find("yt-dlp") }
    static var ffmpeg: URL? { find("ffmpeg") }
    static var deno: URL? { find("deno") }
    static var hasBrew: Bool { FileManager.default.isExecutableFile(atPath: brewPath) }

    static var videosFolder: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        return movies.appendingPathComponent("Scout Videos", isDirectory: true)
    }
}

/// Which links count as videos Scout can download.
enum VideoLink {
    static func service(for url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let host = (url.host ?? "").lowercased()
        func isHost(_ d: String) -> Bool { host == d || host.hasSuffix("." + d) }
        if isHost("youtube.com") || host == "youtu.be" { return "YouTube" }
        if isHost("x.com") || isHost("twitter.com") { return url.path.contains("/status/") ? "X" : nil }
        if isHost("instagram.com") { return ["/reel", "/p/", "/tv/"].contains { url.path.contains($0) } ? "Instagram" : nil }
        if isHost("tiktok.com") { return "TikTok" }
        if isHost("vimeo.com") { return "Vimeo" }
        if isHost("reddit.com") || host == "redd.it" { return "Reddit" }
        return nil
    }

    /// The first video link in a piece of text (a copied link, usually the whole string).
    static func find(in text: String) -> (url: URL, service: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let s = service(for: url) { return (url, s) }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for m in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let url = m.url, let s = service(for: url) { return (url, s) }
        }
        return nil
    }
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case best, p1080, p720, p480, audio
    var id: String { rawValue }

    var title: String {
        switch self {
        case .best: String(localized: "Best")
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        case .audio: String(localized: "Audio")
        }
    }

    /// A quality as the history file stored it: its raw value (new entries) or its old English title (entries from before).
    init?(stored: String) {
        if let q = VideoQuality(rawValue: stored) { self = q; return }
        switch stored {
        case "Best": self = .best
        case "1080p": self = .p1080
        case "720p": self = .p720
        case "480p": self = .p480
        case "Audio": self = .audio
        default: return nil
        }
    }

    var isAudio: Bool { self == .audio }

    /// The yt-dlp `-f` selector.
    var selector: String {
        switch self {
        case .best: "bv*+ba/b"
        case .p1080: "bv*[height<=1080]+ba/b[height<=1080]/b"
        case .p720: "bv*[height<=720]+ba/b[height<=720]/b"
        case .p480: "bv*[height<=480]+ba/b[height<=480]/b"
        case .audio: "ba/b"
        }
    }
}
#endif
