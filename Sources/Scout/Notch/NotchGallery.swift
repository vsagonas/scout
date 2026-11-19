import SwiftUI

// Gallery scenes for the notch: a mock menu bar + the real NotchRootView with its own sample state.

/// A mock menu bar with the hardware notch, so the island can be judged against what it grows from.
struct MockMenuBar: View {
    var notch = NotchGeometry.sample16
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(scheme == .dark ? Color.black.opacity(0.28) : Color.white.opacity(0.42))
                .frame(height: notch.size.height)
            HStack(spacing: 14) {
                Image(systemName: "applelogo").font(.system(size: 13))
                Text("Finder").font(.system(size: 12, weight: .bold))
                Text("File").font(.system(size: 12))
                Text("Edit").font(.system(size: 12))
                Text("View").font(.system(size: 12))
                Spacer()
                AgentFaceMark()
                Image(systemName: "wifi").font(.system(size: 12))
                Text("Fri 15 Nov  10:41").font(.system(size: 12))
            }
            .foregroundStyle(scheme == .dark ? Color.white : Color.black)
            .padding(.horizontal, 14)
            .frame(height: notch.size.height)
            .frame(maxWidth: .infinity, alignment: .top)
            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous)
                .fill(Color.black)
                .frame(width: notch.size.width, height: notch.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct NotchScene: View {
    let size: CGSize
    @ObservedObject var model: NotchScreenModel
    @ObservedObject var center: LiveActivityCenter
    @ObservedObject var navigator: NotchNavigator
    @ObservedObject var nook: NookStore
    let style: NotchStyle
    let geometry: NotchGeometry
    let widthCap: CGFloat?
    let openHeight: CGFloat?
    let showNotchRect: Bool

    init(size: CGSize, open: Bool = false, workspace: WorkspaceKind = .nook, kinds: [LiveActivityKind] = [],
         cards: Bool = false, editing: Bool = false, drop: Bool = false, detail: Bool = false,
         layout: [WidgetKind]? = nil, live: NookLive? = nil, prepare: (NookStore) -> Void = { _ in },
         style: NotchStyle = .classic, geometry: NotchGeometry = .sample16,
         widthCap: CGFloat? = nil, openHeight: CGFloat? = nil, showNotchRect: Bool = false,
         activities: [LiveActivity] = [], extraCards: [NotchCard] = []) {
        self.size = size
        self.style = style
        self.geometry = geometry
        self.widthCap = widthCap
        self.openHeight = openHeight
        self.showNotchRect = showNotchRect
        let model = NotchScreenModel(geometry: geometry, panelSize: size)
        model.isOpen = open
        model.detailVisible = detail
        let center = LiveActivityCenter()
        for kind in kinds { center.show(SampleActivities.make(kind)) }
        for activity in activities { center.show(activity) }
        for card in extraCards { center.present(card) }
        if cards {
            center.present(NotchCard(id: "c1", duration: 600) {
                DemoCardContent(symbol: "arrow.down.circle.fill", title: "Download finished", subtitle: "Scout-0.1.0.zip · 75 MB")
            })
            center.present(NotchCard(id: "toast", duration: 600) {
                ToastView(message: "Screenshot saved and copied", symbol: "camera.viewfinder", style: .success)
            })
        }
        let navigator = NotchNavigator()
        navigator.workspace = workspace
        navigator.isDropTargeting = drop
        let nook = NookStore(persist: false, layout: layout)
        nook.isEditing = editing
        nook.liveOverride = live
        prepare(nook)
        self.model = model
        self.center = center
        self.navigator = navigator
        self.nook = nook
    }

    var body: some View {
        ZStack(alignment: .top) {
            MockMenuBar(notch: geometry)
            NotchRootView(model: model, center: center, navigator: navigator, nook: nook, styleOverride: style,
                          widthCapOverride: widthCap, openHeightOverride: openHeight)
                .modifier(NotchLeftToRight())   // as NotchWindow's root does: the island keeps left and right in Arabic (the mock menu bar mirrors, like macOS's)
            if showNotchRect {
                // Proof overlay: nothing may sit inside this outline (the camera housing hides it).
                Rectangle().strokeBorder(Color.red, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }
}

@MainActor
enum NotchGalleryItems {
    /// A settings page as it sits in the Settings window (scroll view + padding), at the window's detail width.
    static func settingsPage(_ name: String, _ pane: SettingsPane, height: CGFloat = 560) {
        Gallery.register("settings-\(name)", size: CGSize(width: 640, height: height), backdrop: .window) {
            ScrollView {
                Registry.settingsView(pane).padding(24).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    static func register() {
        DashGallery.register()
        let closedKinds = LiveActivityKind.allCases.filter(\.isAvailable)
        let rowHeight: CGFloat = 78
        Gallery.register("notch-closed-kinds", size: CGSize(width: 520, height: CGFloat(closedKinds.count + 1) * rowHeight + 12)) {
            VStack(spacing: 0) {
                ForEach(closedKinds) { kind in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(kind.title).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 8).frame(height: 14)
                        NotchScene(size: CGSize(width: 520, height: 58), kinds: [kind]).frame(width: 520, height: 58).clipped()
                        Color.clear.frame(height: 6)
                    }
                    .frame(width: 520, height: rowHeight, alignment: .top)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Nothing playing (the hardware notch is untouched)").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8).frame(height: 14)
                    NotchScene(size: CGSize(width: 520, height: 58)).frame(width: 520, height: 58).clipped()
                    Color.clear.frame(height: 6)
                }
                .frame(width: 520, height: rowHeight, alignment: .top)
            }
            .padding(.top, 6)
        }
        Gallery.register("notch-open-narrow", size: CGSize(width: 760, height: 560)) {
            VStack(spacing: 6) {
                NotchScene(size: CGSize(width: 760, height: 150), open: true, editing: false, widthCap: 640, showNotchRect: true)
                    .frame(width: 760, height: 150).clipped()
                NotchScene(size: CGSize(width: 760, height: 190), open: true, editing: true, layout: [.media, .pulse, .timer, .todo],
                           widthCap: 640, showNotchRect: true)
                    .frame(width: 760, height: 190).clipped()
                NotchScene(size: CGSize(width: 760, height: 190), open: true, workspace: .music, editing: true,
                           layout: [.media, .pulse, .timer], geometry: NotchGeometry(size: NotchGeometry.virtualSize, isHardware: false),
                           widthCap: 640, showNotchRect: true)
                    .frame(width: 760, height: 190).clipped()
            }
        }
        // The hover on the dashboard: a column of the one screen, trimmed by the island's outline at its edges (first, middle, last panel).
        for (name, id) in [("first", "agents"), ("middle", "pulse"), ("last", "today")] {
            Gallery.register("notch-open-hover-\(name)", size: CGSize(width: 1000, height: 260)) {
                NotchScene(size: CGSize(width: 1000, height: 260), open: true, layout: [.agents, .askAI, .pulse, .today])
                    .environment(\.nookPreviewHover, id)
            }
        }
        // The camera's Snap: the picture lifts off as a small print on its way into the Clipboard key (drawn a moment into the flight).
        Gallery.register("notch-open-mirror-snap", size: CGSize(width: 1000, height: 330)) {
            let _ = NotchFly.shared.launch(image: NSImage(cgImage: MirrorPolaroid.samplePhoto()!, size: CGSize(width: 640, height: 360)),
                                           from: MirrorSnap.from, to: MirrorSnap.to)
            NotchScene(size: CGSize(width: 1000, height: 330), open: true, workspace: .mirror, layout: [.agents, .askAI, .pulse, .today])
        }
        // Panels that only have their own keys light up too.
        Gallery.register("notch-open-hover-pomodoro", size: CGSize(width: 1000, height: 260)) {
            NotchScene(size: CGSize(width: 1000, height: 260), open: true, layout: [.agents, .pomodoro, .pulse, .timer])
                .environment(\.nookPreviewHover, "pomodoro")
        }
        // The radio beside the agents (the owner, 2026-11-18: the radio did not show while agents owned the wings): agents at work and the
        // radio's station and song at the outer end; then an agent that waits with its message, and the radio after it.
        for (name, waiting) in [("working", false), ("message", true)] {
            Gallery.register("notch-closed-agents-radio-\(name)", size: CGSize(width: 1000, height: 44), backdrop: .screenTop) {
                let store = AgentsStore(directory: AppPaths.folder("gallery-agents-radio-\(name)"))
                let _ = {
                    var list = Array(AgentSession.synthetic(6).prefix(2))
                    for i in list.indices { list[i].state = .working; list[i].finishedAt = nil }
                    if waiting { list[1].state = .waiting; list[1].finishedAt = Date().addingTimeInterval(-20); list[1].lastMessage = "I changed the footer links and pushed the branch." }
                    store.loadSessions(list)
                }()
                NotchScene(size: CGSize(width: 1000, height: 44), activities: [AgentsStore.wings(store: store, expiresAfter: nil), RadioNotchPresenter.sample()])
            }
        }
        // The dashboard in rows, the height automatic:
        // few widgets, one row at 180 pt;
        // more, a second row from the left; many, three rows.
        let rowLayouts: [(String, [WidgetKind])] = [
            ("1", [.agents, .askAI, .pulse, .today]),
            ("2", [.agents, .askAI, .pulse, .today, .weather, .calendar, .todo]),
            ("3", [.agents, .askAI, .pulse, .today, .weather, .calendar, .todo, .timer, .media, .pomodoro, .clipboard, .notes]),
        ]
        // Edit Nook with many widgets: the same rows, the palette under them.
        Gallery.register("notch-open-rows-edit", size: CGSize(width: 1000, height: 640)) {
            NotchScene(size: CGSize(width: 1000, height: 640), open: true, editing: true, layout: rowLayouts[2].1)
        }
        for (name, layout) in rowLayouts {
            Gallery.register("notch-open-rows-\(name)", size: CGSize(width: 1000, height: 560)) {
                NotchScene(size: CGSize(width: 1000, height: 560), open: true, layout: layout)
            }
        }
        Gallery.register("notch-closed-secondary", size: CGSize(width: 520, height: 70)) {
            NotchScene(size: CGSize(width: 520, height: 70), kinds: [.timer, .download, .battery])
        }
        Gallery.register("notch-closed-detail", size: CGSize(width: 520, height: 150)) {
            NotchScene(size: CGSize(width: 520, height: 150), kinds: [.calendar], detail: true)
        }
        Gallery.register("notch-cards", size: CGSize(width: 520, height: 280)) {
            NotchScene(size: CGSize(width: 520, height: 280), kinds: [.timer], cards: true)
        }
        Gallery.register("notch-open-nook", size: CGSize(width: 1120, height: 290)) {
            let _ = NowPlayingService.shared.showSample(NowPlayingService.sampleTrack)
            NotchScene(size: CGSize(width: 1120, height: 290), open: true)
        }
        Gallery.register("notch-open-nook-glass", size: CGSize(width: 1120, height: 290)) {
            let _ = NowPlayingService.shared.showSample(NowPlayingService.sampleTrack)
            NotchScene(size: CGSize(width: 1120, height: 290), open: true, style: .glass)
        }
        Gallery.register("notch-open-nook-edit", size: CGSize(width: 1120, height: 380)) {
            NotchScene(size: CGSize(width: 1120, height: 380), open: true, editing: true,
                       layout: [.media, .pulse, .timer, .weather, .calendar])
        }
        Gallery.register("notch-open-drop", size: CGSize(width: 1120, height: 290)) {
            NotchScene(size: CGSize(width: 1120, height: 290), open: true, drop: true)
        }
        settingsPage("appearance", .appearance, height: 1100)
        // The two previews under the 8-bit switch, each at one still moment.
        Gallery.register("settings-style-previews", size: CGSize(width: 640, height: 240), backdrop: .window) {
            VStack(spacing: 16) {
                AppearanceEightBitPreview(frozenAt: 1000.3).frame(height: 96)
                AppearanceMinimalPreview(frozenAt: 1000.3).frame(height: 96)
            }
            .padding(16)
        }
        settingsPage("general", .general, height: 560)
        // A language picked in this run: the Restart row under it (Settings › General › Language, 2026-11-18).
        Gallery.register("settings-general-language", size: CGSize(width: 640, height: 620), backdrop: .window) {
            ScrollView { GeneralSettingsPane(previewChoice: "el").padding(24).frame(maxWidth: .infinity, alignment: .topLeading) }
        }
        settingsPage("notch", .notch, height: 3700)
        settingsPage("liveactivities", .liveActivities, height: 1260)
        settingsPage("nook", .nook, height: 1080)
        Gallery.register("notch-open-with-cards", size: CGSize(width: 1120, height: 420)) {
            NotchScene(size: CGSize(width: 1120, height: 420), open: true, cards: true)
        }
        // Every workspace in the open notch, at the default and the smallest height: the header must stay in the
        // menu-bar band and the content inside the island (the Calendar once pushed the header off the screen).
        for kind in WorkspaceKind.available {
            for (suffix, height) in [("", CGFloat(200)), ("-min", CGFloat(NotchPrefs.heightRange.lowerBound))] {
                Gallery.register("notch-open-ws-\(kind.rawValue)\(suffix)", size: CGSize(width: 1120, height: 330)) {
                    let _ = NowPlayingService.shared.showSample(NowPlayingService.sampleTrack)
                    NotchScene(size: CGSize(width: 1120, height: 330), open: true, workspace: kind, openHeight: height)
                }
            }
        }
    }
}
