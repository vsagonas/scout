#if !APPSTORE
import Foundation

enum YtDlpEvent: Sendable {
    case meta(title: String, thumbnail: String?)
    case progress(fraction: Double?, bytes: Int64, total: Int64?, speed: Double?, eta: Double?)
    case destination(String)
}

struct YtDlpRequest: Sendable {
    var url: URL
    var quality: VideoQuality
    var outputDir: URL
    var ytdlp: URL
    var ffmpegDir: String?
}

enum YtDlpError: LocalizedError {
    case failed(String)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .failed(let m): m
        case .cancelled: String(localized: "Cancelled")
        }
    }
}

/// Parses yt-dlp's output lines (our own progress template plus the usual messages).
enum YtDlpOutput {
    static let progressPrefix = "SCOUTP|"
    static let metaPrefix = "SCOUTM|"
    static let filePrefix = "SCOUTF|"

    static func number(_ s: Substring) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t == "NA" || t.isEmpty || t == "None" ? nil : Double(t)
    }

    static func parse(_ line: String) -> YtDlpEvent? {
        if line.hasPrefix(progressPrefix) {
            // SCOUTP|downloaded|total|total_estimate|speed|eta
            let parts = line.dropFirst(progressPrefix.count).split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 5 else { return nil }
            let done = number(parts[0]) ?? 0
            let total = number(parts[1]) ?? number(parts[2])
            let fraction = total.flatMap { $0 > 0 ? min(1, done / $0) : nil }
            return .progress(fraction: fraction, bytes: Int64(done), total: total.map { Int64($0) }, speed: number(parts[3]), eta: number(parts[4]))
        }
        if line.hasPrefix(metaPrefix) {
            let parts = line.dropFirst(metaPrefix.count).split(separator: "\t", omittingEmptySubsequences: false)
            guard let title = parts.first else { return nil }
            let thumb = parts.count > 1 ? String(parts[1]) : nil
            return .meta(title: String(title), thumbnail: thumb == "NA" ? nil : thumb)
        }
        if line.hasPrefix(filePrefix) { return .destination(String(line.dropFirst(filePrefix.count))) }
        if line.hasPrefix("[download] Destination: ") { return .destination(String(line.dropFirst("[download] Destination: ".count))) }
        if let r = line.range(of: "[Merger] Merging formats into \"") {
            return .destination(String(line[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }
        if line.hasPrefix("[ExtractAudio] Destination: ") { return .destination(String(line.dropFirst("[ExtractAudio] Destination: ".count))) }
        if line.hasPrefix("[download] "), line.hasSuffix(" has already been downloaded") {
            return .destination(String(line.dropFirst("[download] ".count).dropLast(" has already been downloaded".count)))
        }
        return nil
    }
}

/// Runs yt-dlp as a child process and reports progress. Never installs anything.
final class YtDlpRunner: @unchecked Sendable {
    private var process: Process?
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        let p: Process? = lock.withLock { cancelled = true; return process }
        p?.terminate()
    }

    static func arguments(for r: YtDlpRequest) -> [String] {
        var args = ["--no-playlist", "--newline", "--no-colors", "--no-warnings", "--no-mtime",
                    "--progress-template", "download:\(YtDlpOutput.progressPrefix)%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
                    "--progress",
                    "--print", "before_dl:\(YtDlpOutput.metaPrefix)%(title)s\t%(thumbnail)s",
                    "--print", "after_move:\(YtDlpOutput.filePrefix)%(filepath)s",
                    "--no-simulate",
                    "-f", r.quality.selector,
                    "-o", r.outputDir.appendingPathComponent("%(title).150B [%(id)s].%(ext)s").path]
        if r.quality.isAudio { args += ["-x", "--audio-format", "m4a"] } else { args += ["--merge-output-format", "mp4"] }
        if let dir = r.ffmpegDir { args += ["--ffmpeg-location", dir] }
        args.append(r.url.absoluteString)
        return args
    }

    /// Returns the downloaded file. `onEvent` is called from a background thread.
    func run(_ r: YtDlpRequest, onEvent: @escaping @Sendable (YtDlpEvent) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: r.outputDir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = r.ytdlp
        process.arguments = Self.arguments(for: r)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (VideoTools.searchFolders + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        lock.withLock { self.process = process }

        let state = LineState()
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in state.feed(data) {
                if let event = YtDlpOutput.parse(line) {
                    if case .destination(let path) = event { state.setDestination(path) }
                    onEvent(event)
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            state.addError(String(decoding: data, as: UTF8.self))
        }
        do { try process.run() } catch { throw YtDlpError.failed(String(localized: "Couldn't start yt-dlp")) }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in c.resume() }
            if !process.isRunning { c.resume() }   // finished before the handler was set
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        let wasCancelled = lock.withLock { cancelled }
        if wasCancelled { throw YtDlpError.cancelled }
        guard process.terminationStatus == 0 else { throw YtDlpError.failed(state.errorSummary) }
        guard let path = state.destination else { throw YtDlpError.failed(String(localized: "yt-dlp didn't say where it saved the file")) }
        return URL(fileURLWithPath: path)
    }

    /// Splits the byte stream into lines and remembers the last destination and error text.
    private final class LineState: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private(set) var destination: String?
        private var errors = ""

        func feed(_ data: Data) -> [String] {
            lock.lock(); defer { lock.unlock() }
            buffer.append(data)
            var lines: [String] = []
            while let i = buffer.firstIndex(of: 10) {
                lines.append(String(decoding: buffer[buffer.startIndex..<i], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...i)
            }
            return lines
        }

        func setDestination(_ p: String) { lock.lock(); destination = p; lock.unlock() }
        func addError(_ s: String) { lock.lock(); errors += s; lock.unlock() }

        var errorSummary: String {
            lock.lock(); defer { lock.unlock() }
            let line = errors.split(separator: "\n").last { $0.contains("ERROR") } ?? errors.split(separator: "\n").last
            let text = line.map { String($0).replacingOccurrences(of: "ERROR: ", with: "") } ?? String(localized: "The download failed")
            return String(text.prefix(140))
        }
    }
}
#endif
