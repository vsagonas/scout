#if !APPSTORE
import AppKit
import SwiftUI

struct VideoHistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: String
    var path: String
    var service: String
    var quality: String
    var date = Date()
}

/// The video download feature: offers (clipboard / dropped link), the running job, history.
@MainActor
final class VideoManager: ObservableObject {
    static let shared = VideoManager()

    enum Key {
        static let offer = "video.offer"            // offer clipboard links when the Tray opens (default on)
        static let quality = "video.quality"        // default quality
        static let addToTray = "video.addToTray"    // put the finished video in the Tray (default on)
    }

    struct Offer: Equatable { var url: URL; var service: String }

    enum Phase: Equatable {
        case preparing
        case downloading
        case failed(String)
        case done(URL)
    }

    struct Job {
        var url: URL
        var service: String
        var quality: VideoQuality
        var title: String
        var thumbnail: NSImage?
        var fraction: Double?
        var bytes: Int64 = 0
        var total: Int64?
        var speed: Double?
        var eta: Double?
        var phase: Phase = .preparing
        /// The failure is about missing tools: the banner then offers the Settings page (never read from the message's words).
        var needsSettings = false
    }

    @Published private(set) var offer: Offer?
    @Published private(set) var job: Job?
    @Published private(set) var history: [VideoHistoryEntry] = []

    private let historyFile = JSONFile<[VideoHistoryEntry]>("video-history.json")
    private var runner: YtDlpRunner?
    private var lastOffered: String?
    private var streamCount = 0
    private var lastBytes: Int64 = 0
    /// Injected by self-tests: where the files go and which tool runs.
    var testOverride: (outputDir: URL, ytdlp: URL)?

    var defaultQuality: VideoQuality { VideoQuality(rawValue: Pref.string(Key.quality, "best")) ?? .best }
    var isBusy: Bool { if let job, job.phase == .preparing || job.phase == .downloading { return true } else { return false } }

    func start() {
        history = historyFile.load() ?? []
        VideoOfferHook.onTrayOpened = { [weak self] in self?.checkClipboard() }
        VideoOfferHook.onLinkDropped = { [weak self] url in self?.makeOffer(url) }
    }

    // MARK: Offers

    /// When the Tray opens: is there a copied video link? Reading the clipboard from the background can raise
    /// a macOS prompt on 15.4+, so Scout only reads when the user allowed it for Scout.
    func checkClipboard() {
        guard Pref.bool(Key.offer, true), !ScoutRuntime.isScripted, !isBusy else { return }
        if #available(macOS 15.4, *), NSPasteboard.general.accessBehavior != .alwaysAllow { return }
        guard let text = NSPasteboard.general.string(forType: .string), text != lastOffered, let link = VideoLink.find(in: text) else { return }
        lastOffered = text
        makeOffer(link.url)
    }

    func makeOffer(_ url: URL) {
        guard let service = VideoLink.service(for: url), !isBusy else { return }
        offer = Offer(url: url, service: service)
        LiveActivityCenter.shared.present(NotchCard(id: "video.offer", kind: .video, duration: 12, onTap: { [weak self] in
            if let self, let offer = self.offer { self.start(offer.url, quality: self.defaultQuality) }
        }) {
            VideoOfferCard(service: service, quality: self.defaultQuality)
        })
    }

    func dismissOffer() {
        offer = nil
        LiveActivityCenter.shared.dismissCard(id: "video.offer")
    }

    // MARK: Download

    var toolsReady: Bool { testOverride != nil || (VideoTools.ytdlp != nil && VideoTools.ffmpeg != nil) }

    func start(_ url: URL, quality: VideoQuality) {
        guard !isBusy else { return }
        dismissOffer()
        let service = VideoLink.service(for: url) ?? String(localized: "Video")
        guard toolsReady, let ytdlp = testOverride?.ytdlp ?? VideoTools.ytdlp else {
            job = Job(url: url, service: service, quality: quality, title: String(localized: "Video download"), phase: .failed(String(localized: "Needs yt-dlp and ffmpeg. Open Settings › Downloads & Video.")), needsSettings: true)
            return
        }
        if service == "YouTube", VideoTools.deno == nil, testOverride == nil {
            job = Job(url: url, service: service, quality: quality, title: String(localized: "Video download"), phase: .failed(String(localized: "YouTube also needs deno. Open Settings › Downloads & Video.")), needsSettings: true)
            return
        }
        if ScoutRuntime.isScripted, testOverride == nil { simulate(url: url, service: service, quality: quality); return }
        let outputDir = testOverride?.outputDir ?? VideoTools.videosFolder
        job = Job(url: url, service: service, quality: quality, title: String(localized: "Getting the video…"))
        streamCount = 0
        lastBytes = 0
        let runner = YtDlpRunner()
        self.runner = runner
        let request = YtDlpRequest(url: url, quality: quality, outputDir: outputDir, ytdlp: ytdlp, ffmpegDir: VideoTools.ffmpeg?.deletingLastPathComponent().path)
        Task {
            do {
                let file = try await runner.run(request) { event in
                    Task { @MainActor in self.handle(event, merge: !quality.isAudio) }
                }
                finish(file: file)
            } catch YtDlpError.cancelled {
                job = nil
                LiveActivityCenter.shared.dismiss(id: "video.job")
            } catch {
                job?.phase = .failed(error.localizedDescription)
                LiveActivityCenter.shared.dismiss(id: "video.job")
            }
            self.runner = nil
        }
    }

    func cancel() { runner?.cancel() }

    func clearJob() { job = nil }

    private func handle(_ event: YtDlpEvent, merge: Bool) {
        guard job != nil else { return }
        switch event {
        case .meta(let title, let thumb):
            job?.title = title
            if let thumb, let url = URL(string: thumb), !ScoutRuntime.isScripted {
                Task {
                    if let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) {
                        self.job?.thumbnail = image
                        self.postActivity()
                    }
                }
            }
        case .progress(let fraction, let bytes, let total, let speed, let eta):
            // Video and audio come as two streams: weight them 90 / 10 so the ring only moves forward.
            if bytes < lastBytes { streamCount += 1 }
            lastBytes = bytes
            var f = fraction
            if merge, let current = fraction { f = streamCount == 0 ? current * 0.9 : 0.9 + current * 0.1 }
            if let f, let old = job?.fraction { job?.fraction = max(old, f) } else { job?.fraction = f }
            job?.bytes = bytes
            job?.total = total
            job?.speed = speed
            job?.eta = eta
            job?.phase = .downloading
        case .destination:
            break
        }
        postActivity()
    }

    private func postActivity() {
        guard let job, job.phase == .downloading || job.phase == .preparing else { return }
        let snapshot = job
        LiveActivityCenter.shared.show(LiveActivity(id: "video.job", kind: .video, onTap: { NotchNavigator.shared.open(.tray) }, leading: {
            VideoThumbnailView(image: snapshot.thumbnail, size: 20)
        }, trailing: {
            DownloadIndicator(style: .ring, fraction: snapshot.fraction, bytes: snapshot.bytes)
        }).withDetail {
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(Self.progressLine(snapshot)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
            }.foregroundStyle(.white)
        })
    }

    static func progressLine(_ j: Job) -> String {
        var parts: [String] = []
        if let f = j.fraction { parts.append(f.formatted(.percent.precision(.fractionLength(0)))) }
        if let total = j.total { parts.append(String(localized: "\(FeatureFormat.bytes(j.bytes)) of \(FeatureFormat.bytes(total))")) }
        if let speed = j.speed, speed > 1000 { parts.append(String(localized: "\(FeatureFormat.bytes(Int64(speed)))/s")) }
        if let eta = j.eta, eta > 0, eta < 36000 { parts.append(String(localized: "\(FeatureFormat.duration(eta)) left")) }
        return parts.isEmpty ? String(localized: "Starting…") : parts.joined(separator: " · ")
    }

    private func finish(file: URL) {
        guard let j = job else { return }
        LiveActivityCenter.shared.dismiss(id: "video.job")
        job?.phase = .done(file)
        let entry = VideoHistoryEntry(title: j.title, url: j.url.absoluteString, path: file.path, service: j.service, quality: j.quality.rawValue)
        history.insert(entry, at: 0)
        history = Array(history.prefix(20))
        historyFile.save(history)
        if testOverride == nil, Pref.bool(Key.addToTray, true) {
            TrayStore.shared.start()
            TrayStore.shared.add(files: [file])
        }
        let thumb = j.thumbnail
        LiveActivityCenter.shared.present(NotchCard(id: "video.done", kind: .video, duration: 6, onTap: {
            if !ScoutRuntime.isScripted { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        }) {
            VideoResultCard(title: j.title, thumbnail: thumb, file: file)
        })
    }

    func removeHistory(_ id: UUID) {
        history.removeAll { $0.id == id }
        historyFile.save(history)
    }

    // MARK: Scripted demo (no yt-dlp, no network)

    private func simulate(url: URL, service: String, quality: VideoQuality) {
        job = Job(url: url, service: service, quality: quality, title: "Sample video: A walk through the old town")
        let begin = Date()
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.job != nil else { timer.invalidate(); return }
                let f = min(1, Date().timeIntervalSince(begin) / 6)
                if f >= 1 {
                    timer.invalidate()
                    LiveActivityCenter.shared.dismiss(id: "video.job")
                    self.job?.phase = .done(URL(fileURLWithPath: "/dev/null"))
                    return
                }
                self.job?.fraction = f
                self.job?.bytes = Int64(f * 82_000_000)
                self.job?.total = 82_000_000
                self.job?.speed = 9_000_000
                self.job?.eta = 6 * (1 - f)
                self.job?.phase = .downloading
                self.postActivity()
            }
        }
    }
}

// MARK: - Views

struct VideoThumbnailView: View {
    let image: NSImage?
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() } else {
                ZStack { Color.white.opacity(0.18); Image(systemName: "play.fill").font(.system(size: size * 0.4)).foregroundStyle(.white) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

/// Card under the notch: "Download video?" (click starts with the default quality).
struct VideoOfferCard: View {
    let service: String
    let quality: VideoQuality

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 26)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Download this \(service) video?").font(.system(size: 13, weight: .semibold))
                Text("Click to save it in \(quality.title). Pick another quality in the Tray.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(width: 400)
    }
}

struct VideoResultCard: View {
    let title: String
    let thumbnail: NSImage?
    let file: URL

    var body: some View {
        HStack(spacing: 12) {
            VideoThumbnailView(image: thumbnail, size: 44).background(Color.black.opacity(0.1))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("Saved in Movies › Scout Videos · added to the Tray").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "folder").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(width: 400)
    }
}

/// The strip at the top of the Tray workspace: an offer, the running download, or an error.
struct VideoBanner: View {
    @ObservedObject private var manager = VideoManager.shared

    var body: some View {
        if let job = manager.job {
            jobRow(job)
        } else if let offer = manager.offer {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
                Text("Download this \(offer.service) video?").font(.system(size: 11, weight: .semibold))
                ForEach(VideoQuality.allCases) { q in
                    NotchChip(title: Text(verbatim: q.title), selected: q == manager.defaultQuality) { manager.start(offer.url, quality: q) }
                }
                Spacer()
                Button { manager.dismissOffer() } label: { Image(systemName: "xmark") }.buttonStyle(NotchIconButtonStyle(size: 18))
            }
            .padding(.horizontal, 10).frame(height: 28).notchTile(radius: 9, fill: Theme.accent.opacity(0.16))
        }
    }

    @ViewBuilder private func jobRow(_ job: VideoManager.Job) -> some View {
        HStack(spacing: 8) {
            VideoThumbnailView(image: job.thumbnail, size: 20)
            switch job.phase {
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer()
                if job.needsSettings { Button("Settings") { SettingsWindowController.shared.show(.downloads) }.buttonStyle(.notchPillCompact) }
                Button { manager.clearJob() } label: { Image(systemName: "xmark") }.buttonStyle(NotchIconButtonStyle(size: 18))
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(job.title) is in the Tray").font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer()
                Button { manager.clearJob() } label: { Image(systemName: "xmark") }.buttonStyle(NotchIconButtonStyle(size: 18))
            default:
                Text(job.title).font(.system(size: 11, weight: .semibold)).lineLimit(1).frame(maxWidth: 190, alignment: .leading)
                ProgressBar(fraction: job.fraction).frame(height: 5)
                Text(VideoManager.progressLine(job)).font(.system(size: 10)).foregroundStyle(NotchInk.secondary).lineLimit(1).monospacedDigit()
                Button { manager.cancel() } label: { Image(systemName: "xmark") }.buttonStyle(NotchIconButtonStyle(size: 18)).help("Cancel the download")
            }
        }
        .padding(.horizontal, 10).frame(height: 28).notchTile(radius: 9)
    }
}

struct ProgressBar: View {
    let fraction: Double?
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                if let fraction { Capsule().fill(Theme.accent).frame(width: max(5, geo.size.width * fraction)) }
                else { TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                    let t = (ctx.date.timeIntervalSinceReferenceDate / 1.2).truncatingRemainder(dividingBy: 1)
                    Capsule().fill(Theme.accent).frame(width: geo.size.width * 0.25).offset(x: geo.size.width * 0.75 * (0.5 - 0.5 * cos(t * 2 * .pi)))
                } }
            }
        }
    }
}
#endif
