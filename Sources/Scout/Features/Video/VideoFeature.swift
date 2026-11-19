#if !APPSTORE
import SwiftUI

@MainActor
enum VideoFeature {
    static func start() {
        VideoManager.shared.start()
        // scout://video.offer?url=... shows the offer (scripted runs simulate the download).
        DebugCommands.register("video.offer") { params in
            let url = URL(string: params["url"] ?? "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
            VideoManager.shared.makeOffer(url)
            if params["open"] != "0" { NotchNavigator.shared.open(.tray) }
        }
        DebugCommands.register("video.start") { params in
            let url = URL(string: params["url"] ?? "https://vimeo.com/76979871")!
            VideoManager.shared.start(url, quality: VideoQuality(rawValue: params["quality"] ?? "best") ?? .best)
            NotchNavigator.shared.open(.tray)
        }
    }

    static func registerSelfTests() {
        FeaturesSelfTest.add("video: links, yt-dlp output parser") {
            guard VideoLink.service(for: URL(string: "https://www.youtube.com/watch?v=abc")!) == "YouTube",
                  VideoLink.service(for: URL(string: "https://youtu.be/abc")!) == "YouTube",
                  VideoLink.service(for: URL(string: "https://x.com/user/status/123")!) == "X",
                  VideoLink.service(for: URL(string: "https://x.com/user")!) == nil,
                  VideoLink.service(for: URL(string: "https://www.instagram.com/reel/CxYz/")!) == "Instagram",
                  VideoLink.service(for: URL(string: "https://vm.tiktok.com/ZM123/")!) == "TikTok",
                  VideoLink.service(for: URL(string: "https://vimeo.com/76979871")!) == "Vimeo",
                  VideoLink.service(for: URL(string: "https://www.reddit.com/r/x/comments/1/t/")!) == "Reddit",
                  VideoLink.service(for: URL(string: "https://example.com/video")!) == nil,
                  VideoLink.find(in: "check this https://youtu.be/xyz now")?.service == "YouTube" else { return false }
            guard case .progress(let f, let b, let t, let speed, let eta)? = YtDlpOutput.parse("SCOUTP|2500000|10000000|NA|1250000.5|6"),
                  f == 0.25, b == 2_500_000, t == 10_000_000, speed == 1_250_000.5, eta == 6 else { return false }
            guard case .progress(let f2, _, let t2, _, _)? = YtDlpOutput.parse("SCOUTP|500|NA|2000|NA|NA"), f2 == 0.25, t2 == 2000 else { return false }
            guard case .progress(let f3, _, let t3, _, _)? = YtDlpOutput.parse("SCOUTP|500|NA|NA|NA|NA"), f3 == nil, t3 == nil else { return false }
            guard case .meta(let title, let thumb)? = YtDlpOutput.parse("SCOUTM|A title\thttps://i.ytimg.com/x.jpg"), title == "A title", thumb == "https://i.ytimg.com/x.jpg" else { return false }
            guard case .destination(let p)? = YtDlpOutput.parse("SCOUTF|/Users/me/Movies/Scout Videos/A title [x].mp4"), p.hasSuffix("[x].mp4") else { return false }
            guard case .destination(let m)? = YtDlpOutput.parse("[Merger] Merging formats into \"/tmp/a b.mp4\""), m == "/tmp/a b.mp4" else { return false }
            return YtDlpOutput.parse("[youtube] Extracting URL") == nil
        }
        FeaturesSelfTest.add("video: a fake yt-dlp runs end to end (progress, file, history)") {
            let work = AppPaths.folder("SelfTest").appendingPathComponent("Videos", isDirectory: true)
            try? FileManager.default.removeItem(at: work)
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let fake = AppPaths.folder("SelfTest").appendingPathComponent("fake-yt-dlp")
            // A stand-in that prints what yt-dlp prints and writes a file. It never touches the network.
            let script = """
            #!/bin/bash
            out=""
            while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done
            dir="$(dirname "$out")"
            echo "SCOUTM|Fake clip\tNA"
            echo "SCOUTP|1000|4000|NA|1000|3"
            sleep 0.1
            echo "SCOUTP|4000|4000|NA|2000|0"
            echo "SCOUTP|200|NA|800|NA|NA"
            echo "SCOUTP|800|NA|800|NA|NA"
            echo "hello" > "$dir/Fake clip [abc].mp4"
            echo "SCOUTF|$dir/Fake clip [abc].mp4"
            """
            try? script.write(to: fake, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
            let request = YtDlpRequest(url: URL(string: "https://vimeo.com/1")!, quality: .best, outputDir: work, ytdlp: fake, ffmpegDir: nil)
            let events = EventLog()
            let result = FeaturesSelfTest.block { try await YtDlpRunner().run(request) { events.add($0) } }
            guard case .success(let file) = result, file.lastPathComponent == "Fake clip [abc].mp4", FileManager.default.fileExists(atPath: file.path) else { print("  run failed"); return false }
            let snapshot = events.snapshot
            return snapshot.progress >= 4 && snapshot.title == "Fake clip" && snapshot.lastFraction == 1.0
        }
        FeaturesSelfTest.add("video: a failing download reports yt-dlp's error") {
            let fake = AppPaths.folder("SelfTest").appendingPathComponent("fake-yt-dlp-fail")
            try? "#!/bin/bash\necho 'ERROR: Video unavailable' >&2\nexit 1\n".write(to: fake, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
            let work = AppPaths.folder("SelfTest").appendingPathComponent("Videos", isDirectory: true)
            let request = YtDlpRequest(url: URL(string: "https://vimeo.com/1")!, quality: .p720, outputDir: work, ytdlp: fake, ffmpegDir: nil)
            let result = FeaturesSelfTest.block { try await YtDlpRunner().run(request) { _ in } }
            if case .failure(let error) = result, error.localizedDescription.contains("Video unavailable") { return true }
            return false
        }
    }

    /// Collects runner events from the background thread.
    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var progress = 0
        private var title: String?
        private var lastFraction: Double?
        func add(_ e: YtDlpEvent) {
            lock.lock(); defer { lock.unlock() }
            switch e {
            case .progress(let f, _, _, _, _): progress += 1; lastFraction = f ?? lastFraction
            case .meta(let t, _): title = t
            default: break
            }
        }
        var snapshot: (progress: Int, title: String?, lastFraction: Double?) { lock.lock(); defer { lock.unlock() }; return (progress, title, lastFraction) }
    }

    static func registerGallery() {
        Gallery.register("video-offer-card", size: CGSize(width: 460, height: 100)) {
            VideoOfferCard(service: "YouTube", quality: .best).background(GlassBackground(cornerRadius: 22))
        }
        Gallery.register("video-result-card", size: CGSize(width: 460, height: 100)) {
            VideoResultCard(title: "A walk through the old town", thumbnail: nil, file: URL(fileURLWithPath: "/tmp/x.mp4")).background(GlassBackground(cornerRadius: 22))
        }
        FeatureGallery.workspace("video-banner-offer", height: 60) {
            VideoBannerPreview(kind: .offer).padding(14)
        }
        FeatureGallery.workspace("video-banner-running", height: 60) {
            VideoBannerPreview(kind: .running).padding(14)
        }
        FeatureGallery.workspace("video-banner-missing", height: 60) {
            VideoBannerPreview(kind: .missing).padding(14)
        }
    }
}

/// Gallery stand-in for the banner (the real one reads the shared manager).
struct VideoBannerPreview: View {
    enum Kind { case offer, running, missing }
    let kind: Kind

    var body: some View {
        switch kind {
        case .offer:
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
                Text(verbatim: "Download this YouTube video?").font(.system(size: 11, weight: .semibold))
                ForEach(VideoQuality.allCases) { q in NotchChip(title: Text(verbatim: q.title), selected: q == .best) {} }
                Spacer()
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 18, height: 18).background(Circle().fill(NotchInk.tileStrong))
            }
            .padding(.horizontal, 10).frame(height: 28).notchTile(radius: 9, fill: Theme.accent.opacity(0.16))
        case .running:
            HStack(spacing: 8) {
                VideoThumbnailView(image: nil, size: 20)
                Text(verbatim: "A walk through the old town").font(.system(size: 11, weight: .semibold)).lineLimit(1).frame(maxWidth: 190, alignment: .leading)
                ProgressBar(fraction: 0.46).frame(height: 5)
                Text(verbatim: "46% · 38 MB of 82 MB · 9 MB/s · 0:05 left").font(.system(size: 10)).foregroundStyle(NotchInk.secondary).lineLimit(1).monospacedDigit()
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 18, height: 18).background(Circle().fill(NotchInk.tileStrong))
            }
            .padding(.horizontal, 10).frame(height: 28).notchTile(radius: 9)
        case .missing:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Needs yt-dlp and ffmpeg. Open Settings › Downloads & Video.").font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer()
                Button("Settings") {}.buttonStyle(.notchPillCompact)
            }
            .padding(.horizontal, 10).frame(height: 28).notchTile(radius: 9)
        }
    }
}
#endif
