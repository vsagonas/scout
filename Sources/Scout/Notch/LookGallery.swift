import SwiftUI

// Gallery scenes `look-*`: the size and colours settings (Core/Retro/ScoutLook.swift) on the open notch. Render one combination at a time:
//   SCOUT_8BIT=1 SCOUT_PRESET=light SCOUT_SCALE=xlarge scripts/gallery.sh look build/gallery-look
// (the environment forces the look, the preset and the size for the whole run).

@MainActor
enum LookGallery {
    /// The width and height the tour's pictures are cut to: the open island exactly
    nonisolated static let pictureWidth: CGFloat = 1016
    nonisolated static let pictureHeight: CGFloat = CGFloat(NotchPrefs.defaultOpenHeight)

    static func register() {
        // The tour's pictures: the real dashboard (three agents, music playing), cut to the island. Render each look and preset with the
        // environment and copy the PNGs to Support/Resources (scripts/tour-pictures.sh does all four).
        Gallery.register("look-tour-dash", size: CGSize(width: pictureWidth, height: pictureHeight), backdrop: .window) {
            let _ = DashGallery.seed(agents: 3, playing: true, live: [])
            let panel = CGSize(width: pictureWidth + 40, height: 300)
            let model = NotchScreenModel(geometry: .sample16, panelSize: panel)
            let _ = { model.isOpen = true }()
            let nook = NookStore(persist: false, layout: nil)
            let _ = { nook.liveOverride = NookLive(playing: true, openTodos: 0, agents: 3) }()
            let navigator = NotchNavigator()
            NotchRootView(model: model, center: LiveActivityCenter(), navigator: navigator, nook: nook, styleOverride: .classic,
                          widthCapOverride: pictureWidth)
                .frame(width: panel.width, height: panel.height, alignment: .top)
                // The island's round bottom corners are filled with its own surface: the tour shows the picture's left part in a card, and a
                // corner showing the window behind looked like a cut (the owner, 2026-11-16).
                .background(Look.isLight ? Look.paper : Color.black)
                .frame(width: pictureWidth, height: pictureHeight, alignment: .top)
                .clipped()
        }
        // The dashboard and every full view as the size and colours settings draw them (set them with the environment).
        Gallery.register("look-dash", size: CGSize(width: 1540, height: 430)) {
            let _ = DashGallery.seed(agents: 3, playing: true,
                                     live: [DashGallery.meeting(in: nil), DashGallery.download(), DashGallery.timer()])
            NotchScene(size: CGSize(width: 1540, height: 430), open: true, live: NookLive(playing: true, openTodos: 0, agents: 3))
        }
        for kind in WorkspaceKind.available where kind != .nook {
            Gallery.register("look-ws-\(kind.rawValue)", size: CGSize(width: 1540, height: 560)) {
                let _ = NowPlayingService.shared.showSample(NowPlayingService.sampleTrack)
                NotchScene(size: CGSize(width: 1540, height: 560), open: true, workspace: kind)
            }
        }
        Gallery.register("look-closed", size: CGSize(width: 520, height: 70)) {
            NotchScene(size: CGSize(width: 520, height: 70), kinds: [.timer, .download, .battery])
        }
        Gallery.register("look-settings", size: CGSize(width: 640, height: 440), backdrop: .window) {
            Form { NotchLookSection() }.formStyle(.grouped).scrollDisabled(true)
        }
        Gallery.register("look-cards", size: CGSize(width: 520, height: 280)) {
            NotchScene(size: CGSize(width: 520, height: 280), kinds: [.timer], cards: true)
        }
        // Every header key on the open notch's surface, as the preset draws them.
        Gallery.register("look-keys", size: CGSize(width: 520, height: 60), backdrop: .window) {
            HStack(spacing: 2) {
                ForEach(WorkspaceKind.available) { kind in
                    NotchIconButton(symbol: kind.symbol, selected: kind == .calendar, help: kind.title, hoverPreview: false, action: {})
                }
            }
            .padding(10)
            .frame(width: 520, height: 60, alignment: .leading)
            .background(Look.surface)
            .environment(\.colorScheme, Look.contentScheme)
        }
        Gallery.register("look-header", size: CGSize(width: 900, height: 60), backdrop: .window) {
            NotchHeader(navigator: NotchNavigator(), nook: NookStore(persist: false, layout: []), hardwareWidth: 185, sideWidth: 350)
                .frame(width: 900, height: 60)
                .background(Look.surface)
                .environment(\.colorScheme, Look.contentScheme)
        }
        Gallery.register("look-keys-hover", size: CGSize(width: 520, height: 60), backdrop: .window) {
            HStack(spacing: 2) {
                ForEach(WorkspaceKind.available) { kind in
                    NotchIconButton(symbol: kind.symbol, selected: kind == .calendar, help: kind.title, hoverPreview: true, action: {})
                }
            }
            .padding(10)
            .frame(width: 520, height: 60, alignment: .leading)
            .background(Look.surface)
            .environment(\.colorScheme, Look.contentScheme)
        }
    }
}
