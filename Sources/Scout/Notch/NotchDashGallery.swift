import SwiftUI

// Gallery scenes (`dash-*`) for the dashboard: the one-screen notch of panels, the details a panel expands into, the back control,
// Edit Nook, the Agents panel with the Mac's load and its one-line rows. Synthetic data only (never real transcripts, calendars or chats).

@MainActor
enum DashGallery {
    nonisolated static let wide: CGFloat = 1120

    /// Synthetic agents, music and the like on the shared stores the panels read.
    static func seed(agents: Int, playing: Bool, live: [any LivePanelSource] = []) {
        LivePanelLookup.override = live
        #if !APPSTORE
        AgentTabStore.shared.installSamples(tabs: [])
        #endif
        AgentsStore.shared.loadSessions(AgentSession.synthetic(agents))
        AgentsStore.shared.previewDoneToday(agents == 0 ? 0 : 5)
        NowPlayingService.shared.showSample(playing ? NowPlayingService.sampleTrack : nil)
    }

    /// A store of its own for the Agents panel pictures (never the shared one).
    static func agentsStore(_ count: Int) -> AgentsStore {
        let store = AgentsStore()
        store.loadSessions(AgentSession.synthetic(count))
        store.previewDoneToday(count == 0 ? 0 : 5)
        return store
    }

    private static func scene(_ name: String, height: CGFloat, width: CGFloat = wide, open: Bool = true, workspace: WorkspaceKind = .nook,
                              agents: Int = 3, playing: Bool = false, live: [any LivePanelSource] = [],
                              layout: [WidgetKind]? = nil, editing: Bool = false, openHeight: CGFloat? = nil, notchRect: Bool = false,
                              widthCap: CGFloat? = nil) {
        Gallery.register(name, size: CGSize(width: width, height: height)) {
            let _ = seed(agents: agents, playing: playing, live: live)
            NotchScene(size: CGSize(width: width, height: height), open: open, workspace: workspace, editing: editing, layout: layout,
                       live: NookLive(playing: playing, openTodos: 0, agents: agents),
                       widthCap: widthCap, openHeight: openHeight, showNotchRect: notchRect)
        }
    }

    /// The header with the lock key as the setting would leave it (`locked`: nil = no lock), on its own.
    private static func lockScene(_ name: String, workspace: WorkspaceKind, locked: WorkspaceKind?, widthCap: CGFloat? = nil, editing: Bool = false) {
        let height: CGFloat = editing ? 150 : 120
        Gallery.register(name, size: CGSize(width: wide, height: height)) {
            let _ = seed(agents: 3, playing: false)
            NotchScene(size: CGSize(width: wide, height: height), open: true, workspace: workspace, editing: editing,
                       live: NookLive(playing: false, openTodos: 0, agents: 3), widthCap: widthCap, showNotchRect: true)
                .environment(\.notchLockPreview, NotchLockPreview(locked: locked))
        }
    }

    /// The live panels the pictures show: the real ones from `Notch/LivePanels/`, fed sample data.
    static func meeting(in minutes: Int?) -> any LivePanelSource {
        let now = Date()
        let start = minutes.map { now.addingTimeInterval(TimeInterval($0 * 60)) } ?? now.addingTimeInterval(-10 * 60)
        return LiveSamples.meeting([LiveSamples.event("Design review", start: start, length: 60 * 60, link: LiveSamples.meet)])
    }

    static func download() -> any LivePanelSource {
        LiveSamples.downloads(LiveDownloadsSnapshot(downloads: [LiveSamples.transfer("Scout-0.1.0.zip", fraction: 0.64, total: 75_000_000)]))
    }

    static func timer() -> any LivePanelSource {
        LiveSamples.timer(LiveTimerSnapshot(pomodoro: PomodoroState(phase: .work, endDate: Date().addingTimeInterval(14 * 60 + 12.6), sessions: 2), pomodoroTotal: 25 * 60))
    }

    static func register() {
        // The live dashboard: Agents and the Ask AI line always; everything else only while it is live.
        scene("dash-live-busy", height: 290, agents: 3, playing: true, live: [meeting(in: 20), download()], notchRect: true)
        scene("dash-live-quiet", height: 290, agents: 0, notchRect: true)
        scene("dash-live-quiet-agents", height: 290, agents: 3, notchRect: true)
        scene("dash-live-meeting-now", height: 290, agents: 2, live: [meeting(in: nil)], notchRect: true)
        scene("dash-live-timer", height: 290, agents: 1, live: [timer()], notchRect: true)
        scene("dash-live-music", height: 290, agents: 2, playing: true)
        // Pinned panels stay (Calendar, Weather and Notes here), and the Pulse panel steps aside when the row is tight.
        scene("dash-pinned", height: 290, agents: 2, layout: [.agents, .askAI, .calendar, .weather, .notes])
        scene("dash-dashboard-pulse-aside", height: 290, agents: 2, layout: [.agents, .pulse, .calendar, .todo, .media])
        scene("dash-dashboard-narrow", height: 290, agents: 3, playing: true, live: [meeting(in: 20)], widthCap: 640)
        // What the panels expand into (the header's tabs show which one; the camera area stays empty).
        scene("dash-expanded-calendar", height: 480, workspace: .calendar, live: [meeting(in: 20)], notchRect: true)
        scene("dash-expanded-agents", height: 330, workspace: .agents, agents: 3, openHeight: 262)
        scene("dash-expanded-agents-6", height: 480, workspace: .agents, agents: 6, openHeight: 380)
        scene("dash-expanded-music", height: 290, workspace: .music, playing: true, notchRect: true)
        scene("dash-expanded-todos", height: 480, workspace: .todo)   // the To-dos entry opens the Calendar view (the to-dos are in it)
        scene("dash-expanded-notes", height: 300, workspace: .notes)
        scene("dash-expanded-clipboard", height: 290, workspace: .clipboard)
        scene("dash-expanded-clipboard-low", height: 290, workspace: .clipboard, openHeight: 180)   // the lowest notch height setting
        scene("dash-expanded-tray", height: 290, workspace: .tray)
        scene("dash-expanded-prompter", height: 290, workspace: .prompter)
        Gallery.register("dash-expanded-askai", size: CGSize(width: wide, height: 540)) {
            let preview = AskAINotchPreview(store: AIChatStore(demo: .conversation), draft: AskAINotchDraft())
            NotchScene(size: CGSize(width: wide, height: 540), open: true, workspace: .askAI, openHeight: AskAINotchView.conversationHeight)
                .environment(\.askAINotchPreview, preview)
        }
        // The header on its own, with the camera housing outlined.
        scene("dash-header-back", height: 120, workspace: .calendar, notchRect: true)
        scene("dash-header-back-narrow", height: 120, workspace: .agents, notchRect: true, widthCap: 640)
        // The lock key beside the gear: no lock, kept on the tab on show (pressed in, the tab key wears a tiny lock), kept on another tab,
        // on the Mirror (dim: the camera never opens by itself), at the narrow width and in Edit Nook.
        lockScene("dash-header-lock-off", workspace: .calendar, locked: nil)
        lockScene("dash-header-lock-on", workspace: .calendar, locked: .calendar)
        lockScene("dash-header-lock-elsewhere", workspace: .agents, locked: .calendar)
        lockScene("dash-header-lock-mirror", workspace: .mirror, locked: .calendar)
        lockScene("dash-header-lock-narrow", workspace: .calendar, locked: .calendar, widthCap: 700)
        lockScene("dash-header-lock-editing", workspace: .nook, locked: .calendar, editing: true)
        // Edit Nook.
        scene("dash-edit", height: 390, layout: [.agents, .askAI, .calendar, .weather], editing: true)
        // The Ask AI and Prompter panels.
        scene("dash-panels-askai-prompter", height: 290, agents: 0, layout: [.askAI, .prompter, .notes, .tray, .clipboard])
        // The Agents panel with the Mac's CPU and memory, and its one-line rows.
        func agentsWidget(_ name: String, span: Int, _ store: AgentsStore) {
            FeatureGallery.widget(name, span: span) { AgentsWidgetView(store: store) }
        }
        let none = agentsStore(0)
        let three = agentsStore(3)
        let six = agentsStore(6)
        agentsWidget("dash-agents-cpu-0agents", span: 6, none)
        agentsWidget("dash-agents-cpu-0agents-narrow", span: 3, none)
        agentsWidget("dash-agents-cpu-3agents", span: 8, three)
        agentsWidget("dash-agents-cpu-3agents-narrow", span: 3, three)
        agentsWidget("dash-agents-rows-6-wide", span: 16, six)
        agentsWidget("dash-agents-rows-6-medium", span: 8, six)
        agentsWidget("dash-agents-rows-6-narrow", span: 3, six)
        // The same Mac line in the expanded Agents view and in the closed notch's hover detail.
        FeatureGallery.workspace("dash-agents-expanded-cpu", width: 988, height: 220) { AgentsWorkspaceView(store: three) }
        FeatureGallery.workspace("dash-agents-expanded-cpu-0", width: 988, height: 150) { AgentsWorkspaceView(store: none) }
        Gallery.register("dash-closed-hover-mac", size: CGSize(width: 520, height: 190), backdrop: .screenTop) {
            VStack(spacing: 6) {
                ZStack {
                    UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous).fill(Color.black).frame(width: 340, height: 34)
                }
                AgentWingDetail(store: three).padding(.horizontal, 14).padding(.vertical, 10)
                    .background(UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18, style: .continuous).fill(Color.black))
            }
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // The Ask AI panel with a quick answer in its history, at its real size on the notch: the answer stays inside the panel and nothing hangs below.
        FeatureGallery.widget("dash-askai-answer", span: 4) { AskAIWidgetView(store: AIChatStore(demo: .quick), draft: AskAINotchDraft()) }
        Dash90Gallery.register()
        NotchCardsGallery.register()   // notch-cards-*: a card hanging from the island, closed and open
        #if !APPSTORE
        // Full edition: agent tabs are panels on the dashboard, with a "+" in the header.
        Gallery.register("dash-tabs-two", size: CGSize(width: wide, height: 290)) {
            let _ = seed(agents: 3, playing: true)
            let _ = AgentTabGallery.install(2)
            AgentTabScene(size: CGSize(width: wide, height: 290), showNotchRect: true)
        }
        Gallery.register("dash-tabs-three-ended", size: CGSize(width: wide, height: 290)) {
            let _ = seed(agents: 0, playing: false)
            let _ = AgentTabGallery.install(3, endedLast: true)
            AgentTabScene(size: CGSize(width: wide, height: 290), showNotchRect: true)
        }
        Gallery.register("dash-tab-expanded", size: CGSize(width: wide, height: 480)) {
            let _ = AgentTabGallery.install(2)
            AgentTabScene(size: CGSize(width: wide, height: 480), activeTab: "sample-1", showNotchRect: true)
        }
        #endif
    }
}
