import Combine
import SwiftUI

// A6 — the Music workspace: big artwork, controls, progress and (full edition only) synced lyrics.

struct MusicWorkspaceView: View {
    @ObservedObject private var service = NowPlayingService.shared
    #if !APPSTORE
    @ObservedObject private var lyrics = LyricsService.shared
    @AppStorage("media.lyrics") private var lyricsOn = true
    #endif

    var body: some View {
        Group {
            if let track = service.track {
                player(track)
            } else {
                MediaEmptyState()
            }
        }
        #if !APPSTORE
        .onAppear { lyrics.load(for: service.track) }
        .onChange(of: service.track?.key) { _, _ in lyrics.load(for: service.track) }
        .onChange(of: lyricsOn) { _, _ in lyrics.load(for: service.track) }
        #endif
    }

    private func player(_ track: NowPlayingTrack) -> some View {
        GeometryReader { geo in
            let art = min(geo.size.height, 140)
            #if APPSTORE
            // No lyrics column in this edition: artwork and the player block sit together in the middle, with a roomy block.
            HStack(spacing: 28) {
                ArtworkView(track: track, size: art, radius: 20)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
                info(track, height: art)
                    .frame(width: 360, height: art)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            #else
            HStack(spacing: 20) {
                ArtworkView(track: track, size: art, radius: 20)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
                info(track, height: art)
                    .frame(width: 262, height: art)
                if lyricsOn {
                    lyricsColumn
                        .frame(maxWidth: .infinity)
                        .frame(height: art)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            #endif
        }
    }

    private func info(_ track: NowPlayingTrack, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            MarqueeText(text: track.title, font: .system(size: 16, weight: .bold))
            MarqueeText(text: track.artist, font: .system(size: 13, weight: .medium), color: .secondary)
            if !track.album.isEmpty {
                MarqueeText(text: track.album, font: .system(size: 12), color: Color.secondary.opacity(0.8))
            }
            Spacer(minLength: 4)
            SeekBar(service: service)
            HStack(spacing: 0) {
                toggle("shuffle", on: track.isShuffling ?? false, help: "Shuffle") { service.toggleShuffle() }
                Spacer()
                MediaControls(service: service, size: 1.1)
                Spacer()
                if service.canFavorite {
                    toggle(track.isFavorite == true ? "heart.fill" : "heart", on: track.isFavorite == true, help: "Favorite") { service.toggleFavorite() }
                } else {
                    toggle("arrow.up.forward.app", on: false, help: "Open the player") { service.openPlayer() }
                }
            }
            .padding(.top, 2)
        }
    }

    private func toggle(_ symbol: String, on: Bool, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Theme.accent : Color.secondary)
                .frame(width: 26, height: 24)
        }
        .buttonStyle(MediaPressStyle())
        .help(help)
    }

    #if !APPSTORE
    @ViewBuilder
    private var lyricsColumn: some View {
        switch lyrics.state {
        case .synced(let lines):
            LyricsView(lines: lines, service: service)
        case .loading:
            VStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Looking for lyrics").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .none, .idle:
            VStack(spacing: 6) {
                Image(systemName: "text.quote").font(.system(size: 20)).foregroundStyle(.secondary)
                Text("No synced lyrics").font(.system(size: 12, weight: .medium))
                Text("This song has none yet").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    #endif
}

#if !APPSTORE
/// Lyrics with the current line highlighted and centered; click a line to jump there.
struct LyricsView: View {
    let lines: [LyricLine]
    @ObservedObject var service: NowPlayingService
    @State private var current = 0
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 9) {
                    Color.clear.frame(height: 44)
                    ForEach(lines) { line in
                        let isCurrent = line.id == current
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: isCurrent ? 15 : 13, weight: isCurrent ? .bold : .medium))
                            .foregroundStyle(isCurrent ? Color.primary : Color.secondary.opacity(line.id < current ? 0.4 : 0.6))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .id(line.id)
                            .contentShape(Rectangle())
                            .onTapGesture { service.seek(to: line.time) }
                    }
                    Color.clear.frame(height: 44)
                }
                .padding(.horizontal, 6)
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.2),
                                         .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onReceive(timer) { _ in
                let index = index(at: service.elapsed())
                if index != current {
                    current = index
                    withAnimation(Theme.quick) { proxy.scrollTo(index, anchor: .center) }
                }
            }
            .onAppear {
                current = index(at: service.elapsed())
                proxy.scrollTo(current, anchor: .center)
            }
        }
    }

    /// The last line whose time has passed (0 before the first line).
    private func index(at elapsed: TimeInterval) -> Int {
        var result = 0
        for line in lines where line.time <= elapsed + 0.15 { result = line.id }
        return result
    }
}
#endif
