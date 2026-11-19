import Combine
import SwiftUI

// live.downloads: browser downloads in progress (DownloadsWatcher) and file conversions in progress (the Tray reports
// only how many run). Live while something runs, plus 4 s of "Done" after the last download ended with its file in place.

struct LiveTransfer: Equatable, Identifiable {
    var id: String
    var name: String
    var bytes: Int64 = 0
    var total: Int64?
    var speed: Double = 0

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(bytes) / Double(total))
    }
}

struct LiveDownloadsSnapshot: Equatable {
    var downloads: [LiveTransfer] = []   // oldest first
    var conversions = 0
    /// Set by the feed when the last download ended and its file is there; shown for `linger` seconds.
    var done: LiveTransfer?
    var doneAt: Date?

    var isBusy: Bool { !downloads.isEmpty || conversions > 0 }
}

@MainActor
final class LiveDownloadsPanel: LiveDriven {
    static let linger: TimeInterval = 4

    let id = "live.downloads"
    let title = String(localized: "Downloads")
    let symbol = "arrow.down.circle"
    let priority = 50
    let span = 4

    let feed: LiveFeed<LiveDownloadsSnapshot>
    private let clock: () -> Date

    var changes: AnyPublisher<Void, Never> { feed.changes }

    init(feed: LiveFeed<LiveDownloadsSnapshot>, clock: @escaping () -> Date = Date.init) {
        self.feed = feed
        self.clock = clock
    }

    /// The merge that notices "the last download just ended": `finished` says whether its file is there (not cancelled).
    static func merge(finished: @escaping (LiveTransfer) -> Bool, clock: @escaping () -> Date = Date.init) -> (LiveDownloadsSnapshot, LiveDownloadsSnapshot) -> LiveDownloadsSnapshot {
        { old, new in
            var next = new
            if new.isBusy { return next }
            if old.isBusy, let ended = old.downloads.last(where: finished) {
                next.done = ended
                next.doneAt = clock()
            } else {
                next.done = old.done
                next.doneAt = old.doneAt
            }
            return next
        }
    }

    static func live() -> LiveDownloadsPanel {
        let watcher = DownloadsWatcher.shared
        let tray = TrayStore.shared
        let finished: (LiveTransfer) -> Bool = { t in
            let partial = PartialDownload(path: t.id, displayName: t.name, bytes: t.bytes, total: t.total, source: .chromium)
            return DownloadProbe.finishedFile(for: partial, in: watcher.downloadsURL) != nil
        }
        let feed = LiveFeed<LiveDownloadsSnapshot>(read: {
            let tracked = watcher.active.values.sorted { ($0.startedAt, $0.partial.path) < ($1.startedAt, $1.partial.path) }
            let downloads = tracked.map {
                LiveTransfer(id: $0.partial.path, name: $0.partial.displayName, bytes: $0.partial.bytes, total: $0.partial.total, speed: $0.speed)
            }
            return LiveDownloadsSnapshot(downloads: downloads, conversions: tray.converting)
        }, triggers: [watcher.liveTrigger, tray.liveTrigger], merge: merge(finished: finished))
        return LiveDownloadsPanel(feed: feed)
    }

    private var lingering: Bool {
        guard let at = feed.value.doneAt, feed.value.done != nil else { return false }
        return clock().timeIntervalSince(at) < Self.linger
    }

    var isLive: Bool { feed.value.isBusy || lingering }

    /// The Tray holds converted files, so a click opens it, while only conversions run.
    var expandTo: WorkspaceKind? { feed.value.downloads.isEmpty && feed.value.conversions > 0 ? .tray : nil }

    func nextWake(after now: Date) -> Date? {
        guard let at = feed.value.doneAt, feed.value.done != nil else { return nil }
        let due = at.addingTimeInterval(Self.linger)
        return due > now ? due : nil
    }

    func makeView() -> AnyView { AnyView(LiveDownloadsView(feed: feed)) }
}

// MARK: - View

struct LiveDownloadsView: View {
    @ObservedObject var feed: LiveFeed<LiveDownloadsSnapshot>

    var body: some View {
        let s = feed.value
        if s.isBusy { busy(s) } else if let done = s.done { finished(done) } else { Color.clear }
    }

    private func busy(_ s: LiveDownloadsSnapshot) -> some View {
        let total = s.downloads.count + s.conversions
        let first = s.downloads.first
        let shortTitle: String.LocalizationValue = first == nil ? "Convert" : "Download"   // a typed constant: both words reach the key list
        return LiveRetroFrame(symbol: first == nil ? "arrow.triangle.2.circlepath" : "arrow.down.circle",
                              title: first == nil ? "Converting" : "Downloading", short: shortTitle, tint: Retro.Ink.teal, trailing: {
            if total > 1 { LiveRetroFact(text: "+\(total - 1)") }
        }) {
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: 10) {
                if Retro.is8bit { Dash90Floppy(tint: Retro.Ink.teal, size: 34) } else { MiniSymbol(name: first == nil ? "arrow.triangle.2.circlepath" : "arrow.down.circle", size: 24) }
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: first?.name ?? (s.conversions == 1 ? String(localized: "Converting files") : String(localized: "Conversions: \(s.conversions)")))
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    LiveRetroBar(fraction: first?.fraction, tint: Retro.Ink.ledGreen)
                    Text(verbatim: first.map(Self.line) ?? String(localized: "Writing the new files")).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8).monospacedDigit()
                }
            }
            if first != nil, total > 1 {
                Text("+\(total - 1) more").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func finished(_ t: LiveTransfer) -> some View {
        LiveRetroFrame(symbol: "checkmark.circle.fill", title: "Download done", short: "Done", tint: Retro.Ink.lime) {
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: 10) {
                if Retro.is8bit { Dash90Floppy(tint: Retro.Ink.lime, size: 34) } else { MiniSymbol(name: "checkmark.circle", size: 24) }
                VStack(alignment: .leading, spacing: 5) {
                    Text(t.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    LiveRetroBar(fraction: 1, tint: Retro.Ink.ledGreen)
                    Text(verbatim: String(localized: "Done") + (t.total.map { " · " + FeatureFormat.bytes($0) } ?? "")).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// "43 % · 23 MB of 48 MB", or "23 MB so far" when the size is unknown.
    static func line(_ t: LiveTransfer) -> String {
        guard let fraction = t.fraction, let total = t.total else { return String(localized: "\(FeatureFormat.bytes(t.bytes)) so far") }
        return String(localized: "\(LiveFormat.percent(fraction)) · \(FeatureFormat.bytes(t.bytes)) of \(FeatureFormat.bytes(total))")
    }
}
