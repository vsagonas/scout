import AppKit

/// Launch flags and app facts. Read-only, safe from any thread.
enum ScoutRuntime {
    static let arguments = ProcessInfo.processInfo.arguments

    /// `--automation`: scripted checks. Features must NOT ask for permissions, must NOT touch the network,
    /// and should show sample data. Data lives in a separate folder (see `AppPaths`).
    static let isAutomation = arguments.contains("--automation")

    /// `--headless` (with `--automation` only): no notch, ring, panels, menu-bar item or hotkeys; only the Agents store
    /// and scanner run, for checks that must never show anything on the owner's screen.
    static let isHeadless = isAutomation && arguments.contains("--headless")

    /// `--gallery <dir>`: render every registered view to PNG and quit.
    static let galleryOutput: URL? = {
        guard let i = arguments.firstIndex(of: "--gallery"), i + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
    }()

    /// `--only <prefix>`: with `--gallery`, render only items whose name starts with the prefix.
    static let galleryFilter: String? = {
        guard let i = arguments.firstIndex(of: "--only"), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }()

    static var isGallery: Bool { galleryOutput != nil }

    /// True for every scripted run (automation or gallery): no prompts, no network, sample data.
    static var isScripted: Bool { isAutomation || isGallery }

    static let bundleID = Bundle.main.bundleIdentifier ?? "com.vsag.Scout"
    static let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    static let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"

    /// Reduce Motion may be ON. Every animation must have a calm version.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// Where Scout keeps its files. Scripted runs use a separate folder so they never touch real data.
enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(ScoutRuntime.isScripted ? "Scout-Automation" : "Scout", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func file(_ name: String) -> URL { support.appendingPathComponent(name) }

    static func folder(_ name: String) -> URL {
        let url = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension JSONEncoder {
    static let scout: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

extension JSONDecoder {
    static let scout: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// A Codable value persisted as JSON in Application Support. Writes are atomic and off the main thread.
final class JSONFile<Value: Codable> {
    let url: URL
    private let queue = DispatchQueue(label: "scout.jsonfile", qos: .utility)

    init(_ name: String) { url = AppPaths.file(name) }

    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.scout.decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        guard let data = try? JSONEncoder.scout.encode(value) else { return }
        let url = self.url
        queue.async { try? data.write(to: url, options: .atomic) }
    }
}

/// Runs the last call after `delay` seconds of quiet. Main thread.
final class Debouncer {
    private var work: DispatchWorkItem?
    private let delay: TimeInterval

    init(delay: TimeInterval) { self.delay = delay }

    func call(_ block: @escaping () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem(block: block)
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
