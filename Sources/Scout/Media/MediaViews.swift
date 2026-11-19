import AppKit
import Combine
import SwiftUI

// A6 — the faces of NowPlayingService: wings, Quick Peek, the Media widget.

// MARK: - Small parts

enum MediaPrefs {
    static var artworkRadius: CGFloat { CGFloat(Pref.double("media.artworkRadius", 6)) }
    static var visualizer: Bool { Pref.bool("media.visualizer", true) }
    static var quickPeek: Bool { Pref.bool("media.quickPeek", true) }
    #if !APPSTORE
    static var lyrics: Bool { Pref.bool("media.lyrics", true) }
    #endif
    static var expandedWidget: Bool { Pref.string("media.widgetLayout", "compact") == "expanded" }
}


/// The artwork of a track with rounded corners; a generated cover when the player gave none.
struct ArtworkView: View {
    let track: NowPlayingTrack?
    var size: CGFloat
    var radius: CGFloat?

    var body: some View {
        let r = radius ?? MediaPrefs.artworkRadius * size / 22
        Group {
            if let image = track?.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Image(nsImage: ArtworkFactory.image(seed: track?.key ?? "none", size: 128)).resizable()
                    Image(systemName: "music.note").font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: min(r, size / 2), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: min(r, size / 2), style: .continuous).strokeBorder(Look.hairline, lineWidth: 0.5))
    }
}

/// Bars that dance while music plays; a still icon when paused, with Reduce Motion, or when switched off.
struct MediaBars: View {
    var isPlaying: Bool
    var tint: Color = Theme.accent
    var barCount = 5
    var height: CGFloat = 16

    var body: some View {
        if isPlaying, MediaPrefs.visualizer, !ScoutRuntime.reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 24)) { context in
                bars(at: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            Image(systemName: isPlaying ? "waveform" : "pause.fill")
                .font(.system(size: isPlaying ? 13 : 11, weight: .semibold))
                .foregroundStyle(isPlaying ? tint : Look.ink(0.6))
                .frame(width: CGFloat(barCount) * 4 - 1, height: height)
        }
    }

    private func bars(at t: Double) -> some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                let phase = Double(i) * 1.7
                let a = sin(t * (3.1 + Double(i) * 0.63) + phase)
                let b = sin(t * (5.3 - Double(i) * 0.41) + phase * 2.1)
                let level = 0.28 + 0.72 * (0.5 + 0.5 * (0.6 * a + 0.4 * b))
                Capsule().fill(tint).frame(width: 2.5, height: max(3, height * level))
            }
        }
        .frame(height: height)
    }
}

/// One line of text that scrolls sideways when it does not fit (a plain tail-truncated line with Reduce Motion).
struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 13, weight: .semibold)
    var color: Color = .primary
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0

    private var overflows: Bool { textWidth > boxWidth + 1 && boxWidth > 0 }

    var body: some View {
        ZStack(alignment: .leading) {
            if overflows, !ScoutRuntime.reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let gap: CGFloat = 40
                    let speed = 30.0
                    let move = Double(textWidth + gap) / speed
                    let pause = 1.6
                    let k = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: move + pause)
                    let offset = k < pause ? 0 : (k - pause) * speed
                    HStack(spacing: gap) { label; label }
                        .fixedSize()
                        .offset(x: -offset)
                        .frame(width: boxWidth, alignment: .leading)
                }
            } else {
                label.lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { boxWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, new in boxWidth = new }
        })
        .background(
            label.fixedSize().hidden()
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { textWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, new in textWidth = new }
                })
        )
        .id(text)
    }

    private var label: some View { Text(text).font(font).foregroundStyle(color) }
}

/// A thin progress bar the user can drag to seek.
struct SeekBar: View {
    @ObservedObject var service: NowPlayingService
    var showTimes = true
    var height: CGFloat = 5
    @State private var dragFraction: Double?

    var body: some View {
        let track = service.track
        VStack(spacing: 3) {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let duration = max(1, track?.duration ?? 1)
                let fraction = dragFraction ?? min(1, service.elapsed() / duration)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.18))
                        Capsule().fill(Color.primary.opacity(0.85)).frame(width: max(height, geo.size.width * fraction))
                    }
                    .frame(height: height)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { dragFraction = max(0, min(1, $0.location.x / max(1, geo.size.width))) }
                        .onEnded { value in
                            let f = max(0, min(1, value.location.x / max(1, geo.size.width)))
                            service.seek(to: f * duration)
                            dragFraction = nil
                        })
                }
                .frame(height: 14)
                .nookControl()
                if showTimes {
                    HStack {
                        Text(Self.format(fraction * duration))
                        Spacer()
                        Text("-" + Self.format(max(0, duration - fraction * duration)))
                    }
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds).rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct MediaControls: View {
    @ObservedObject var service: NowPlayingService
    var size: CGFloat = 1

    var body: some View {
        HStack(spacing: 14 * size) {
            control("backward.fill", 14 * size, help: "Previous") { service.previous() }
            control(service.isPlaying ? "pause.fill" : "play.fill", 20 * size, help: service.isPlaying ? "Pause" : "Play") { service.playPause() }
                .frame(width: 26 * size)
            control("forward.fill", 14 * size, help: "Next") { service.next() }
        }
        .nookControl()
    }

    private func control(_ symbol: String, _ pt: CGFloat, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: pt, weight: .semibold)).foregroundStyle(Color.primary)
                .frame(minWidth: 22, minHeight: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(MediaPressStyle())
        .help(help)
    }
}

struct MediaPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.55 : 1)
    }
}

/// "Nothing playing", one action.
struct MediaEmptyState: View {
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 4 : 8) {
            Image(systemName: "music.note.list").font(.system(size: compact ? 20 : 26)).foregroundStyle(.secondary)
            Text("Nothing playing").font(.system(size: 13, weight: .medium))
            Button(playerName.map { "Open \($0)" } ?? "Open Music") { openPlayer() }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var playerName: String? {
        NowPlayingService.shared.preference == .spotify ? "Spotify" : String(localized: "Music")
    }

    private func openPlayer() {
        guard !ScoutRuntime.isScripted else { return }
        let id = NowPlayingService.shared.preference == .spotify ? NowPlayingService.spotifyID : NowPlayingService.musicID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

// MARK: - Live activity (wings of the closed notch)

@MainActor
enum MediaActivity {
    static func make(track: NowPlayingTrack, service: NowPlayingService? = nil, expiresAfter: TimeInterval? = nil) -> LiveActivity {
        let service = service ?? NowPlayingService.shared
        return LiveActivity(id: "media", kind: .media, expiresAfter: expiresAfter, onTap: { NotchNavigator.shared.open(.music) }) {
            MediaWingLeading(service: service)
        } trailing: {
            MediaWingTrailing(service: service)
        }
        .withDetail { MediaWingDetail(service: service) }
    }
}

private struct MediaWingLeading: View {
    @ObservedObject var service: NowPlayingService
    var body: some View { ArtworkView(track: service.track, size: 22) }
}

private struct MediaWingTrailing: View {
    @ObservedObject var service: NowPlayingService
    var body: some View { MediaBars(isPlaying: service.isPlaying).frame(width: 22) }
}

private struct MediaWingDetail: View {
    @ObservedObject var service: NowPlayingService
    var body: some View {
        VStack(spacing: 1) {
            Text(service.track?.title ?? "").font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(service.track?.artist ?? "").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: 250)
    }
}

/// Posts the `.media` activity while something plays and a Quick Peek card when the song changes.
@MainActor
final class MediaActivityController {
    static let shared = MediaActivityController()
    private var lastKey: String?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        NowPlayingService.shared.$track
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in self?.handle(track) }
            .store(in: &bag)
    }

    private var bag = Set<AnyCancellable>()

    private func handle(_ track: NowPlayingTrack?) {
        let center = LiveActivityCenter.shared
        guard let track else {
            center.dismiss(id: "media")
            lastKey = nil
            return
        }
        center.show(MediaActivity.make(track: track, expiresAfter: track.isPlaying ? nil : 6))
        if lastKey != track.key {
            let isFirst = lastKey == nil
            lastKey = track.key
            if !isFirst, track.isPlaying, MediaPrefs.quickPeek, !NotchNavigator.shared.isOpen {
                center.present(NotchCard(id: "media.peek", kind: .media, duration: 3.5, onTap: { NotchNavigator.shared.open(.music) }) {
                    QuickPeekCard(track: track)
                })
            }
        }
    }
}

struct QuickPeekCard: View {
    let track: NowPlayingTrack

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(track: track, size: 46, radius: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(track.artist.isEmpty ? track.album : track.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            MediaBars(isPlaying: track.isPlaying, tint: Theme.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 320)
    }
}

// MARK: - The Media widget (Nook)

/// The dashboard's Now playing panel in the 90s look (R3): a small portable hi-fi. The cover in a recessed bevel, the title and artist
/// on an LCD window, transport as plastic keys (play lit while it plays). The full Music view keeps `MediaControls` and `SeekBar`.
struct MediaWidgetView: View {
    @ObservedObject private var service: NowPlayingService
    @AppStorage("media.widgetLayout") private var storedLayout = "compact"
    private let layoutOverride: String?

    /// `service` and `layout` are only passed by the gallery; the Nook uses the shared service and the setting.
    init(service: NowPlayingService? = nil, layout: String? = nil) {
        _service = ObservedObject(wrappedValue: service ?? NowPlayingService.shared)
        layoutOverride = layout
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Dash90Title("Now playing", short: "Playing", symbol: "music.note", tint: Retro.Ink.magenta) {
                // A lamp: green while it plays, dark while it is paused.
                if let track = service.track {
                    Circle().fill(track.isPlaying ? Retro.Ink.ledGreen : Retro.Ink.ledGreen.opacity(0.2)).frame(width: 6, height: 6)
                        .shadow(color: track.isPlaying ? Retro.Ink.ledGreen.opacity(0.8) : .clear, radius: 2.5)
                }
            }
            if let track = service.track {
                if (layoutOverride ?? storedLayout) == "expanded" { expanded(track) } else { compact(track) }
            } else {
                empty
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .notchContent()
        .contentShape(Rectangle())
    }

    /// The cover in a recessed window, like a window in a cassette case.
    private func cover(_ track: NowPlayingTrack, size: CGFloat) -> some View {
        ArtworkView(track: track, size: size, radius: 3)
            .padding(3)
            .retroBevel(.sunken, cornerRadius: 4, depth: 1.5, face: Dash90.lcdFace)
    }

    private func screen(_ track: NowPlayingTrack) -> some View {
        Dash90LCD(padding: 5) {
            VStack(alignment: .leading, spacing: 1) {
                MarqueeText(text: track.title, font: .system(size: 12.5, weight: .semibold), color: Look.osd)
                MarqueeText(text: track.artist.isEmpty ? track.album : track.artist, font: .system(size: 11), color: Dash90.amber.opacity(0.9))
            }
        }
    }

    private func compact(_ track: NowPlayingTrack) -> some View {
        HStack(alignment: .center, spacing: 8) {
            cover(track, size: 66)
            VStack(alignment: .leading, spacing: 7) {
                screen(track)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Dash90MediaKeys(service: service)
                        Spacer(minLength: 0)
                        MediaBars(isPlaying: service.isPlaying, tint: Retro.Ink.phosphorGreen, barCount: 4, height: 14)
                    }
                    Dash90MediaKeys(service: service)
                }
            }
        }
    }

    private func expanded(_ track: NowPlayingTrack) -> some View {
        VStack(spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    cover(track, size: 36)
                    if let icon = AppIcons.icon(bundleID: track.appBundleID) {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16).offset(x: 5, y: 5)
                    }
                }
                screen(track)
            }
            Dash90SeekBar(service: service)
            Dash90MediaKeys(service: service)
        }
    }

    /// Nothing playing: the dashboard grid's empty line where the track would stand, like every panel's (`DashEmpty`).
    private var empty: some View {
        DashEmpty(symbol: "music.note", title: "Nothing playing", actionTitle: playerName.map { "Open \($0)" } ?? "Open Music") { openPlayer() }
            .padding(.horizontal, 2)
    }

    private var playerName: String? {
        NowPlayingService.shared.preference == .spotify ? "Spotify" : String(localized: "Music")
    }

    private func openPlayer() {
        guard !ScoutRuntime.isScripted else { return }
        let id = NowPlayingService.shared.preference == .spotify ? NowPlayingService.spotifyID : NowPlayingService.musicID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// Previous, play or pause, next: three plastic keys. Play is lit while music plays.
struct Dash90MediaKeys: View {
    @ObservedObject var service: NowPlayingService

    var body: some View {
        HStack(spacing: 4) {
            key("backward.fill", help: "Previous") { service.previous() }
            key(service.isPlaying ? "pause.fill" : "play.fill", help: service.isPlaying ? "Pause" : "Play",
                tint: service.isPlaying ? Retro.shade(Retro.Ink.magenta, -0.1) : Retro.Ink.plasticMid, lit: service.isPlaying) { service.playPause() }
            key("forward.fill", help: "Next") { service.next() }
        }
        .nookControl()
    }

    private func key(_ symbol: String, help: LocalizedStringKey, tint: Color = Retro.Ink.plasticMid, lit: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.dash90Key(tint: tint, width: 28, height: 22, lit: lit))
            .help(help)
    }
}

/// The track's progress as LED segments with its times in LCD digits; drag to seek (like `SeekBar`, dressed for the dashboard).
struct Dash90SeekBar: View {
    @ObservedObject var service: NowPlayingService
    @State private var dragFraction: Double?

    var body: some View {
        let track = service.track
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let duration = max(1, track?.duration ?? 1)
            let fraction = dragFraction ?? min(1, service.elapsed() / duration)
            HStack(spacing: 6) {
                SevenSegmentText(SeekBar.format(fraction * duration), height: 10, color: Dash90.amber, ghost: false)
                GeometryReader { geo in
                    Dash90LEDBar(value: fraction, segments: 26, size: CGSize(width: geo.size.width, height: 12), color: { _, _ in Retro.Ink.magenta })
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { dragFraction = max(0, min(1, $0.location.x / max(1, geo.size.width))) }
                            .onEnded { value in
                                let f = max(0, min(1, value.location.x / max(1, geo.size.width)))
                                service.seek(to: f * duration)
                                dragFraction = nil
                            })
                }
                .frame(height: 12)
                SevenSegmentText("-" + SeekBar.format(max(0, duration - fraction * duration)), height: 10, color: Dash90.amber, ghost: false)
            }
            .nookControl()
        }
    }
}
