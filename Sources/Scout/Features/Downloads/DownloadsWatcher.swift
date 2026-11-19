import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum DownloadStyle: String, CaseIterable, Identifiable {
    case ring, file, bar
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ring: String(localized: "Ring")
        case .file: String(localized: "Filling file")
        case .bar: String(localized: "Bar")
        }
    }
}

/// Watches ~/Downloads for browser downloads and shows them next to the notch. Off until the user turns it
/// on (macOS asks for Downloads access the first time the folder is read).
@MainActor
final class DownloadsWatcher: ObservableObject {
    static let shared = DownloadsWatcher()

    enum Key {
        static let enabled = "dl.enabled"
        static let style = "dl.style"
        static let cardSeconds = "dl.cardSeconds"
        static let finishedCard = "dl.finishedCard"
    }

    struct Tracked {
        var partial: PartialDownload
        var startedAt = Date()
        var speed: Double = 0
        var lastTick = Date()
        var lastBytes: Int64 = 0
    }

    @Published private(set) var active: [String: Tracked] = [:]

    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var timer: Timer?
    private var running = false
    private var lastEnabled: Bool?
    private var demoTimer: Timer?

    /// The user's Downloads folder (not `NSHomeDirectory() + "/Downloads"`, which inside the sandbox is Scout's container).
    static var downloadsFolder: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
    var downloadsURL: URL { Self.downloadsFolder }
    var style: DownloadStyle { DownloadStyle(rawValue: Pref.string(Key.style, "ring")) ?? .ring }

    // MARK: Lifecycle

    func start() {
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        settingsChanged()
    }

    private func settingsChanged() {
        let enabled = Pref.bool(Key.enabled, false) && !ScoutRuntime.isScripted
        guard lastEnabled != enabled else { return }
        lastEnabled = enabled
        enabled ? watch() : unwatch()
    }

    private func watch() {
        guard !running else { return }
        running = true
        fd = open(downloadsURL.path, O_EVTONLY)
        if fd >= 0 {
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
            s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
            s.resume()
            source = s
        }
        // Chrome and Safari update the partial file without touching the folder: poll while anything is active.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.active.isEmpty == false { self?.tick() } }
        }
        tick()
    }

    private func unwatch() {
        running = false
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
        timer?.invalidate()
        timer = nil
        for key in active.keys { LiveActivityCenter.shared.dismiss(id: activityID(key)) }
        active = [:]
    }

    // MARK: Ticks

    private func activityID(_ path: String) -> String { "download.\(abs(path.hashValue))" }

    func tick() {
        let now = Date()
        let found = DownloadProbe.scan(downloadsURL)
        var next: [String: Tracked] = [:]
        for partial in found {
            var t = active[partial.path] ?? Tracked(partial: partial, startedAt: now, lastTick: now, lastBytes: partial.bytes)
            let dt = now.timeIntervalSince(t.lastTick)
            if dt > 0.4 {
                let instant = Double(max(0, partial.bytes - t.lastBytes)) / dt
                t.speed = t.speed == 0 ? instant : t.speed * 0.6 + instant * 0.4
                t.lastTick = now
                t.lastBytes = partial.bytes
            }
            t.partial = partial
            next[partial.path] = t
        }
        // Finished (or cancelled) downloads: partials that vanished.
        for (path, t) in active where next[path] == nil {
            LiveActivityCenter.shared.dismiss(id: activityID(path))
            if let file = DownloadProbe.finishedFile(for: t.partial, in: downloadsURL) { finished(file) }
        }
        active = next
        for t in next.values { LiveActivityCenter.shared.show(Self.activity(for: t, id: activityID(t.partial.path), style: style)) }
    }

    private func finished(_ file: URL) {
        guard Pref.bool(Key.finishedCard, true) else { return }
        let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        LiveActivityCenter.shared.present(Self.finishedCard(name: file.lastPathComponent, size: size, url: file))
    }

    // MARK: Views

    static func activity(for t: Tracked, id: String, style: DownloadStyle) -> LiveActivity {
        let name = t.partial.displayName
        let fraction = t.partial.fraction
        let bytes = t.partial.bytes
        let total = t.partial.total
        let speed = t.speed
        return LiveActivity(id: id, kind: .download, onTap: { if !ScoutRuntime.isScripted { NSWorkspace.shared.open(DownloadsWatcher.downloadsFolder) } }, leading: {
            DownloadFileIcon(name: name, fraction: style == .file ? fraction : nil, size: 20)
        }, trailing: {
            DownloadIndicator(style: style, fraction: fraction, bytes: bytes)
        }).withDetail {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(DownloadProgressText.line(bytes: bytes, total: total, speed: speed)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
            }.foregroundStyle(.white)
        }
    }

    static func finishedCard(name: String, size: Int64, url: URL?) -> NotchCard {
        NotchCard(id: "download.done", kind: .download, duration: Double(Pref.int(Key.cardSeconds, 3)), onTap: {
            if let url, !ScoutRuntime.isScripted { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }) {
            DownloadFinishedCard(name: name, size: size)
        }
    }

    // MARK: Demo (scripted checks)

    /// Fakes a download of "Quarterly report.pdf" (48 MB) over `seconds` seconds: activity, then the card.
    func demo(seconds: Double = 6, indeterminate: Bool = false) {
        demoTimer?.invalidate()
        let total: Int64 = 48_000_000
        let begin = Date()
        let id = "download.demo"
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = min(1, Date().timeIntervalSince(begin) / seconds)
                if p >= 1 {
                    timer.invalidate()
                    LiveActivityCenter.shared.dismiss(id: id)
                    LiveActivityCenter.shared.present(Self.finishedCard(name: "Quarterly report.pdf", size: total, url: nil))
                    return
                }
                let partial = PartialDownload(path: "/demo", displayName: "Quarterly report.pdf", bytes: Int64(Double(total) * p),
                                              total: indeterminate ? nil : total, source: .safari)
                var t = Tracked(partial: partial)
                t.speed = 8_000_000
                LiveActivityCenter.shared.show(Self.activity(for: t, id: id, style: self.style))
            }
        }
    }
}

enum DownloadProgressText {
    static func line(bytes: Int64, total: Int64?, speed: Double) -> String {
        var parts: [String] = []
        if let total, total > 0 { parts.append(String(localized: "\(FeatureFormat.bytes(bytes)) of \(FeatureFormat.bytes(total))")) }
        else { parts.append(String(localized: "\(FeatureFormat.bytes(bytes)) so far")) }
        if speed > 1000 { parts.append("\(FeatureFormat.bytes(Int64(speed)))/s") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Pieces drawn in the wings

/// The file's icon (by extension). With a fraction, it fills from the bottom as the download progresses.
struct DownloadFileIcon: View {
    let name: String
    var fraction: Double?
    var size: CGFloat = 20

    private var icon: NSImage {
        let ext = (name as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    var body: some View {
        let image = Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
        if let fraction {
            ZStack {
                image.saturation(0).opacity(0.35)
                image.mask(alignment: .bottom) { Rectangle().frame(height: size * CGFloat(fraction)).frame(maxHeight: .infinity, alignment: .bottom) }
            }
            .frame(width: size, height: size)
        } else {
            image
        }
    }
}

/// Progress on the right wing: a ring, a bar, or (file style) a percent.
struct DownloadIndicator: View {
    let style: DownloadStyle
    let fraction: Double?
    let bytes: Int64

    var body: some View {
        switch style {
        case .ring: ring
        case .bar: bar
        case .file: label
        }
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.22), lineWidth: 2.5)
            if let fraction {
                Circle().trim(from: 0, to: max(0.02, fraction)).stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                    let angle = (ctx.date.timeIntervalSinceReferenceDate * 360 / 1.1).truncatingRemainder(dividingBy: 360)
                    Circle().trim(from: 0, to: 0.28).stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(angle))
                }
            }
        }
        .frame(width: 16, height: 16)
    }

    private var bar: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.22))
            if let fraction {
                Capsule().fill(Theme.accent).frame(width: max(4, 38 * fraction))
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                    let t = (ctx.date.timeIntervalSinceReferenceDate / 1.2).truncatingRemainder(dividingBy: 1)
                    Capsule().fill(Theme.accent).frame(width: 14).offset(x: (38 - 14) * (0.5 - 0.5 * cos(t * 2 * .pi)))
                }
            }
        }
        .frame(width: 38, height: 4)
    }

    private var label: some View {
        Group {
            if let fraction { Text(verbatim: "\(Int((fraction * 100).rounded()))%") } else { Text(FeatureFormat.bytes(bytes)) }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
    }
}

/// "Download finished": icon, name, size. Click shows it in Finder.
struct DownloadFinishedCard: View {
    let name: String
    let size: Int64

    var body: some View {
        HStack(spacing: 12) {
            DownloadFileIcon(name: name, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("Download finished · \(FeatureFormat.bytes(size))").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(.secondary).help("Show in Finder")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(width: 340)
    }
}
