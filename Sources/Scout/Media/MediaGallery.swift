import SwiftUI

@MainActor
enum MediaGalleryItems {
    static func register() {
        let sample = NowPlayingService.sampleTrack
        var paused = NowPlayingService.sampleTracks[1]
        paused.isPlaying = false
        var longTitle = NowPlayingService.sampleTracks[2]
        longTitle.title = "Northbound (Extended Midnight Mix) [2026 Remaster]"
        longTitle.artist = "Low Tide Club feat. The Harbour Lights Orchestra"

        Gallery.register("media-widgets", size: CGSize(width: 620, height: 490)) {
            let _ = NowPlayingService.shared.showSample(sample)
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    widget(layout: "compact", track: sample)
                    widget(layout: "expanded", track: sample)
                }
                HStack(spacing: 10) {
                    widget(layout: "compact", track: longTitle)
                    widget(layout: "expanded", track: paused)
                }
                widget(layout: "compact", track: nil)
            }
            .environment(\.colorScheme, .dark)
        }
        Gallery.register("media-music-workspace", size: CGSize(width: 1120, height: 290)) {
            let _ = NowPlayingService.shared.showSample(sample)
            NotchScene(size: CGSize(width: 1120, height: 290), open: true, workspace: .music)
        }
        Gallery.register("media-music-workspace-glass", size: CGSize(width: 1120, height: 290)) {
            let _ = NowPlayingService.shared.showSample(sample)
            NotchScene(size: CGSize(width: 1120, height: 290), open: true, workspace: .music, style: .glass)
        }
        Gallery.register("media-music-empty", size: CGSize(width: 1120, height: 290)) {
            let _ = NowPlayingService.shared.showSample(nil)
            NotchScene(size: CGSize(width: 1120, height: 290), open: true, workspace: .music)
        }
        Gallery.register("media-wings", size: CGSize(width: 520, height: 160)) {
            let _ = NowPlayingService.shared.showSample(sample)
            NotchScene(size: CGSize(width: 520, height: 160), kinds: [.media], detail: true)
        }
        Gallery.register("media-quickpeek", size: CGSize(width: 520, height: 150)) {
            let _ = NowPlayingService.shared.showSample(sample)
            ZStack(alignment: .top) {
                MockMenuBar()
                QuickPeekCard(track: sample).background(GlassBackground(cornerRadius: 22)).padding(.top, 40)
            }
        }
        NotchGalleryItems.settingsPage("media", .media, height: 640)
    }

    private static func widget(layout: String, track: NowPlayingTrack?) -> some View {
        MediaWidgetPreview(layout: layout, track: track)
    }
}

/// A Media widget frame (250 x 140) with a given layout and track, as the Nook shows it.
private struct MediaWidgetPreview: View {
    let layout: String
    let service: NowPlayingService

    init(layout: String, track: NowPlayingTrack?) {
        self.layout = layout
        let service = NowPlayingService()
        service.showSample(track)
        self.service = service
    }

    var body: some View {
        MediaWidgetView(service: service, layout: layout)
            .frame(width: CGFloat(WidgetKind.media.defaultSpan) * NookMetrics.cell, height: NookMetrics.widgetHeight)
            .nookPanelFace()
            .padding(10)
            .background(Color.black.opacity(0.8))
    }
}
