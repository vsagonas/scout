import AVFoundation
import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// One output format the Tray can convert to.
struct ConvertFormat: Identifiable, Hashable {
    let id: String
    let title: String
    let ext: String
    let symbol: String

    static let png = ConvertFormat(id: "png", title: "PNG", ext: "png", symbol: "photo")
    static let jpeg = ConvertFormat(id: "jpeg", title: "JPEG", ext: "jpg", symbol: "photo")
    static let heic = ConvertFormat(id: "heic", title: "HEIC", ext: "heic", symbol: "photo")
    static let tiff = ConvertFormat(id: "tiff", title: "TIFF", ext: "tiff", symbol: "photo")
    static let webp = ConvertFormat(id: "webp", title: "WebP", ext: "webp", symbol: "photo")
    static let pdf = ConvertFormat(id: "pdf", title: "PDF", ext: "pdf", symbol: "doc.richtext")
    static let mp4 = ConvertFormat(id: "mp4", title: "MP4", ext: "mp4", symbol: "film")
    static let m4a = ConvertFormat(id: "m4a", title: String(localized: "M4A audio"), ext: "m4a", symbol: "waveform")
    static let mp3 = ConvertFormat(id: "mp3", title: "MP3", ext: "mp3", symbol: "waveform")
    static let zip = ConvertFormat(id: "zip", title: "ZIP", ext: "zip", symbol: "doc.zipper")
}

enum ConvertError: LocalizedError {
    case unreadable(String)
    case unsupported(String)
    case toolMissing(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let n): String(localized: "Couldn't read \(n)")
        case .unsupported(let m): m
        case .toolMissing(let t): String(localized: "\(t) isn't installed")
        case .failed(let m): m
        }
    }
}

/// File conversions. Every conversion writes NEW files; the originals are never touched.
enum Converter {
    #if APPSTORE
    // The sandboxed edition converts only with system frameworks (ImageIO, PDFKit, AVFoundation): no WebP or MP3.
    static var hasCwebp: Bool { false }
    static var hasFFmpeg: Bool { false }
    #else
    static let cwebpPath = "/opt/homebrew/bin/cwebp"
    static let ffmpegPath = "/opt/homebrew/bin/ffmpeg"

    static var hasCwebp: Bool { FileManager.default.isExecutableFile(atPath: cwebpPath) }
    static var hasFFmpeg: Bool { FileManager.default.isExecutableFile(atPath: ffmpegPath) }
    #endif

    // MARK: Which formats apply

    static func formats(for urls: [URL]) -> [ConvertFormat] {
        guard !urls.isEmpty else { return [] }
        var list: [ConvertFormat] = []
        if urls.allSatisfy(\.isImageFile) {
            list = [.png, .jpeg, .heic, .tiff]
            if hasCwebp { list.append(.webp) }
            list.append(.pdf)
        } else if urls.allSatisfy(\.isMovieFile) {
            list = [.mp4, .m4a]
            if hasFFmpeg { list.append(.mp3) }
        } else if urls.allSatisfy({ $0.isAudioFile || $0.isMovieFile }) {
            list = [.m4a]
            if hasFFmpeg { list.append(.mp3) }
        }
        list.append(.zip)
        return list
    }

    /// "Convert image to", "Convert movies to", "Convert files to": the chip bar's title (no number, so no plural forms to translate).
    static func convertTitle(_ urls: [URL]) -> String {
        let one = urls.count == 1
        if urls.allSatisfy(\.isImageFile) { return one ? String(localized: "Convert image to") : String(localized: "Convert images to") }
        if urls.allSatisfy(\.isMovieFile) { return one ? String(localized: "Convert movie to") : String(localized: "Convert movies to") }
        if urls.allSatisfy({ $0.isAudioFile || $0.isMovieFile }) { return one ? String(localized: "Convert audio file to") : String(localized: "Convert audio files to") }
        return one ? String(localized: "Convert file to") : String(localized: "Convert files to")
    }

    // MARK: Convert

    /// Converts `urls` to `format` and returns the NEW files. `destination` decides the folder per source file.
    static func convert(_ urls: [URL], to format: ConvertFormat, destination: (URL) -> URL) async throws -> [URL] {
        switch format.id {
        case "zip":
            return [try await zip(urls, destination: destination(urls[0]))]
        case "pdf":
            return [try pdf(from: urls, destination: destination(urls[0]))]
        default:
            var results: [URL] = []
            for url in urls {
                let dir = destination(url)
                let base = url.deletingPathExtension().lastPathComponent
                if url.pathExtension.lowercased() == format.ext || (format.id == "jpeg" && url.pathExtension.lowercased() == "jpeg") {
                    throw ConvertError.unsupported(String(localized: "\(url.lastPathComponent) is already \(format.title)"))
                }
                let out = UniqueName.url(in: dir, base: base, ext: format.ext)
                switch format.id {
                case "png", "jpeg", "heic", "tiff": try convertImage(url, to: format, dest: out)
                case "webp": try await convertWebP(url, dest: out)
                case "mp4": try await exportMovie(url, dest: out, type: .mp4, audioOnly: false)
                case "m4a": try await exportMovie(url, dest: out, type: .m4a, audioOnly: true)
                case "mp3": try await convertMP3(url, dest: out)
                default: throw ConvertError.unsupported(String(localized: "Unknown format"))
                }
                results.append(out)
            }
            return results
        }
    }

    // MARK: Images (ImageIO)

    private static func utType(_ format: ConvertFormat) -> UTType {
        switch format.id {
        case "png": .png
        case "jpeg": .jpeg
        case "heic": .heic
        case "tiff": .tiff
        default: .png
        }
    }

    static func convertImage(_ src: URL, to format: ConvertFormat, dest: URL) throws {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
              var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ConvertError.unreadable(src.lastPathComponent) }
        let type = utType(format)
        let supported = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        guard supported.contains(type.identifier) else { throw ConvertError.unsupported(String(localized: "\(format.title) isn't supported on this Mac")) }
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let orientation = props[kCGImagePropertyOrientation] {
            options[kCGImagePropertyOrientation] = orientation
        }
        if format.id == "jpeg", image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst, image.alphaInfo != .noneSkipLast {
            image = flattened(image)
        }
        guard let destination = CGImageDestinationCreateWithURL(dest as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConvertError.failed(String(localized: "Couldn't create \(dest.lastPathComponent)"))
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConvertError.failed(String(localized: "Couldn't write \(dest.lastPathComponent)")) }
    }

    /// JPEG has no transparency: paint the image on white.
    private static func flattened(_ image: CGImage) -> CGImage {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    #if APPSTORE
    private static func convertWebP(_ src: URL, dest: URL) async throws { throw ConvertError.unsupported(String(localized: "WebP isn't available here")) }
    private static func convertMP3(_ src: URL, dest: URL) async throws { throw ConvertError.unsupported(String(localized: "MP3 isn't available here")) }
    #else
    private static func convertWebP(_ src: URL, dest: URL) async throws {
        guard hasCwebp else { throw ConvertError.toolMissing("cwebp") }
        // cwebp reads PNG/JPEG/TIFF only: go through a temporary PNG for anything else.
        var input = src
        var temp: URL?
        if !["png", "jpg", "jpeg", "tif", "tiff"].contains(src.pathExtension.lowercased()) {
            let t = FileManager.default.temporaryDirectory.appendingPathComponent("scout-\(UUID().uuidString).png")
            try convertImage(src, to: .png, dest: t)
            input = t
            temp = t
        }
        defer { if let temp { try? FileManager.default.removeItem(at: temp) } }
        try await runTool(cwebpPath, ["-quiet", "-q", "85", input.path, "-o", dest.path])
        guard FileManager.default.fileExists(atPath: dest.path) else { throw ConvertError.failed(String(localized: "cwebp didn't write a file")) }
    }
    #endif

    // MARK: Images to one PDF

    static func pdf(from urls: [URL], destination dir: URL) throws -> URL {
        let document = PDFDocument()
        for url in urls {
            guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else { throw ConvertError.unreadable(url.lastPathComponent) }
            document.insert(page, at: document.pageCount)
        }
        let base = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : String(localized: "\(urls[0].deletingPathExtension().lastPathComponent) and \(urls.count - 1) more")
        let out = UniqueName.url(in: dir, base: base, ext: "pdf")
        guard document.write(to: out) else { throw ConvertError.failed(String(localized: "Couldn't write the PDF")) }
        return out
    }

    // MARK: Movies and audio

    private static func exportMovie(_ src: URL, dest: URL, type: AVFileType, audioOnly: Bool) async throws {
        let asset = AVURLAsset(url: src)
        let wanted = audioOnly ? AVAssetExportPresetAppleM4A : AVAssetExportPreset1920x1080
        var preset = wanted
        if await !AVAssetExportSession.compatibility(ofExportPreset: wanted, with: asset, outputFileType: type) {
            preset = audioOnly ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality
        }
        guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: type),
              let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConvertError.unsupported(audioOnly ? String(localized: "This file can't be converted to audio") : String(localized: "This file can't be converted to MP4"))
        }
        if audioOnly {
            let hasAudio = (try? await asset.loadTracks(withMediaType: .audio))?.isEmpty == false
            guard hasAudio else { throw ConvertError.unsupported(String(localized: "\(src.lastPathComponent) has no sound")) }
        }
        session.shouldOptimizeForNetworkUse = !audioOnly
        if #available(macOS 15.0, *) {
            try await session.export(to: dest, as: type)
        } else {
            session.outputURL = dest
            session.outputFileType = type
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in session.exportAsynchronously { c.resume() } }
            if session.status != .completed { throw ConvertError.failed(session.error?.localizedDescription ?? String(localized: "The export failed")) }
        }
    }

    #if !APPSTORE
    private static func convertMP3(_ src: URL, dest: URL) async throws {
        guard hasFFmpeg else { throw ConvertError.toolMissing("ffmpeg") }
        try await runTool(ffmpegPath, ["-nostdin", "-y", "-loglevel", "error", "-i", src.path, "-vn", "-codec:a", "libmp3lame", "-q:a", "2", dest.path])
        guard FileManager.default.fileExists(atPath: dest.path) else { throw ConvertError.failed(String(localized: "ffmpeg didn't write a file")) }
    }
    #endif

    // MARK: ZIP

    #if APPSTORE
    /// The sandboxed edition writes the archive itself (no `ditto`).
    private static func zip(_ urls: [URL], destination dir: URL) async throws -> URL {
        let base = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
        let out = UniqueName.url(in: dir, base: base, ext: "zip")
        try ZipWriter.write(urls, to: out, rootName: urls.count == 1 ? nil : "Archive")
        return out
    }
    #else

    private static func zip(_ urls: [URL], destination dir: URL) async throws -> URL {
        let fm = FileManager.default
        if urls.count == 1 {
            let out = UniqueName.url(in: dir, base: urls[0].deletingPathExtension().lastPathComponent, ext: "zip")
            try await runTool("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", urls[0].path, out.path])
            return out
        }
        // Several files: copy them (APFS clones, instant) into a staging folder and zip that.
        let staging = fm.temporaryDirectory.appendingPathComponent("scout-zip-\(UUID().uuidString)", isDirectory: true)
        let folder = staging.appendingPathComponent("Archive", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for url in urls {
            let target = UniqueName.url(in: folder, base: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension)
            try fm.copyItem(at: url, to: target)
        }
        let out = UniqueName.url(in: dir, base: "Archive", ext: "zip")
        try await runTool("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, out.path])
        return out
    }

    // MARK: Tools

    private static func runTool(_ path: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                let err = Pipe()
                process.standardError = err
                process.standardOutput = Pipe()
                do {
                    try process.run()
                    let errData = err.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 { c.resume() } else {
                        let text = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        c.resume(throwing: ConvertError.failed(text.isEmpty ? String(localized: "\((path as NSString).lastPathComponent) failed") : String(text.prefix(160))))
                    }
                } catch {
                    c.resume(throwing: error)
                }
            }
        }
    }
    #endif
}
