#if !APPSTORE
import AppKit
import SwiftUI

// Gallery scenes (`termtabs-*`) for the agent tabs. Everything here is fake: sample tabs without a process and
// mock terminal text. Nothing starts, and no real agent is ever run.

/// The real NotchRootView on a mock menu bar, with sample agent tabs in the shared store.
struct AgentTabScene: View {
    let size: CGSize
    @ObservedObject var model: NotchScreenModel
    @ObservedObject var center: LiveActivityCenter
    @ObservedObject var navigator: NotchNavigator
    @ObservedObject var nook: NookStore
    let geometry: NotchGeometry
    let widthCap: CGFloat?
    let showNotchRect: Bool

    @MainActor
    init(size: CGSize, activeTab: String? = nil, workspace: WorkspaceKind = .nook, geometry: NotchGeometry = .sample16,
         widthCap: CGFloat? = nil, showNotchRect: Bool = false) {
        self.size = size
        self.geometry = geometry
        self.widthCap = widthCap
        self.showNotchRect = showNotchRect
        let model = NotchScreenModel(geometry: geometry, panelSize: size)
        model.isOpen = true
        let navigator = NotchNavigator()
        navigator.workspace = workspace
        navigator.activeTab = activeTab
        self.model = model
        self.center = LiveActivityCenter()
        self.navigator = navigator
        self.nook = NookStore(persist: false, layout: nil)
    }

    var body: some View {
        ZStack(alignment: .top) {
            MockMenuBar(notch: geometry)
            NotchRootView(model: model, center: center, navigator: navigator, nook: nook, styleOverride: .classic,
                          widthCapOverride: widthCap, openHeightOverride: nil)
            if showNotchRect {
                // Proof overlay: nothing may sit inside this outline (the camera housing hides it).
                Rectangle().strokeBorder(Color.red, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .defaultAppStorage(Self.factoryDefaults)
    }

    /// Settings as a fresh install has them (the shared automation defaults may hold another run's test values).
    static let factoryDefaults = UserDefaults(suiteName: "com.vsag.Scout.termtabs-gallery") ?? .standard
}

/// A picture of the "+" menu (the real one is a system menu, which cannot be drawn offscreen): the main menu and
/// the folder list of its first entry, read from the same `AgentTabMenuModel`.
struct AgentTabMenuMock: View {
    let model: AgentTabMenuModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            panel(width: 230) {
                ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                    row(entry.kind.menuTitle, symbol: entry.kind.symbol, chevron: true, highlighted: index == 0)
                }
                if !model.resumable.isEmpty {
                    divider
                    Text("Resume").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 2)
                    ForEach(model.resumable) { record in
                        row(AgentTabMenuModel.resumeTitle(record), symbol: record.kind.symbol)
                    }
                    row("Forget Previous Tabs")
                }
            }
            if let first = model.entries.first {
                panel(width: 270) {
                    ForEach(first.folders) { folder in
                        row(folder.parent.isEmpty ? folder.name : "\(folder.name)  —  \(folder.parent)")
                    }
                    divider
                    row("Choose Folder…")
                }
                .padding(.top, 2)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 8)
    }

    private func row(_ title: String, symbol: String? = nil, chevron: Bool = false, highlighted: Bool = false) -> some View {
        HStack(spacing: 7) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11)).frame(width: 14) } else { Color.clear.frame(width: 14, height: 1) }
            Text(title).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 6)
            if chevron { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(highlighted ? Color.white : Color.secondary) }
        }
        .foregroundStyle(highlighted ? Color.white : Color.primary)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(highlighted ? Color.accentColor : Color.clear))
        .padding(.horizontal, 5)
    }

    private func panel<C: View>(width: CGFloat, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.vertical, 5)
            .frame(width: width, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(scheme == .dark ? Color(white: 0.20) : Color(white: 0.97)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.primary.opacity(0.18)))
            .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
    }
}

@MainActor
enum AgentTabGallery {
    private static var base: String { NSHomeDirectory() + "/Dev" }

    static func sampleTabs(_ count: Int, endedLast: Bool = false) -> [AgentTab] {
        var tabs = [
            AgentTab.sample(.claude, folder: base + "/Scout", state: .waiting, id: "sample-1"),
            AgentTab.sample(.codex, folder: base + "/Website", state: .running, id: "sample-2"),
            AgentTab.sample(.shell, folder: base + "/site", state: endedLast ? .ended(1) : .running, id: "sample-3"),
        ]
        tabs = Array(tabs.prefix(count))
        return tabs
    }

    static func install(_ count: Int, endedLast: Bool = false, confirming: String? = nil) {
        let tabs = sampleTabs(count, endedLast: endedLast)
        for tab in tabs { tab.confirmingClose = (tab.id == confirming) }
        let records = [
            AgentTabRecord(id: "old-1", kind: .claude, folder: base + "/Scout", startedAt: Date().addingTimeInterval(-86_400)),
            AgentTabRecord(id: "old-2", kind: .codex, folder: base + "/Website", startedAt: Date().addingTimeInterval(-90_000)),
        ]
        AgentTabStore.shared.installSamples(tabs: tabs, resumable: records, recents: [],
                                            tools: AgentTabStore.Tools(checked: true, claude: "/Users/me/.local/bin/claude", codex: "/opt/homebrew/bin/codex"))
    }

    static func registerGallery() {
        let wide = CGSize(width: 1120, height: 290)
        let tall = CGSize(width: 1120, height: 480)

        Gallery.register("termtabs-header", size: wide) {
            let _ = NowPlayingService.shared.showSample(NowPlayingService.sampleTrack)
            let _ = install(2)
            AgentTabScene(size: wide, showNotchRect: true)
        }
        Gallery.register("termtabs-header-three", size: wide) {
            let _ = NowPlayingService.shared.showSample(NowPlayingService.sampleTrack)
            let _ = install(3, endedLast: true)
            AgentTabScene(size: wide, showNotchRect: true)
        }
        Gallery.register("termtabs-header-narrow", size: CGSize(width: 760, height: 480)) {
            let _ = install(3, endedLast: true)
            AgentTabScene(size: CGSize(width: 760, height: 480), activeTab: "sample-3", widthCap: 640, showNotchRect: true)
        }
        Gallery.register("termtabs-plus-menu", size: CGSize(width: 1120, height: 400)) {
            let _ = NowPlayingService.shared.showSample(NowPlayingService.sampleTrack)
            let _ = install(2)
            ZStack(alignment: .topLeading) {
                AgentTabScene(size: CGSize(width: 1120, height: 400))
                AgentTabMenuMock(model: menuModel()).offset(x: plusX(width: 1120) - 8, y: 36)
            }
        }
        Gallery.register("termtabs-open", size: tall) {
            let _ = install(2)
            AgentTabScene(size: tall, activeTab: "sample-1")
        }
        Gallery.register("termtabs-open-shell", size: tall) {
            let _ = install(3)
            AgentTabScene(size: tall, activeTab: "sample-3")
        }
        Gallery.register("termtabs-close-confirm", size: tall) {
            let _ = install(2, confirming: "sample-1")
            AgentTabScene(size: tall, activeTab: "sample-1")
        }
        Gallery.register("termtabs-ended", size: tall) {
            let _ = install(3, endedLast: true)
            AgentTabScene(size: tall, activeTab: "sample-3")
        }
        Gallery.register("termtabs-settings", size: CGSize(width: 640, height: 840), backdrop: .window) {
            let _ = install(2)
            ScrollView {
                TerminalSettingsPane().padding(24).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    static func menuModel() -> AgentTabMenuModel {
        let folders = [base + "/Scout", base + "/Website", NSHomeDirectory()].map(AgentTabMenuModel.Folder.init)
        let kinds = AgentTabKind.allCases.map { AgentTabMenuModel.Entry(kind: $0, folders: folders) }
        return AgentTabMenuModel(entries: kinds, resumable: AgentTabStore.shared.resumable)
    }

    /// Where the "+" sits (x, in the scene): at the left end of the header, as wide as the Nook's default panel.
    static func plusX(width: CGFloat) -> CGFloat {
        let nookWidth: CGFloat = 876
        return (width - nookWidth) / 2 + 12 + 12
    }
}
#endif
