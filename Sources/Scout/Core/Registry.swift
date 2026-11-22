import Combine
import SwiftUI

/// Which part of the app a piece belongs to (lead = the core).
enum Lane: String { case lead, a, b, c }

// MARK: - Workspaces (what the OPEN notch shows)

/// What the open notch can show. `.nook` is the DASHBOARD (the grid of panels); every other kind is the DETAIL a panel
/// expands into (the full Calendar, the full Agents view…). The notch always opens on the dashboard, and
/// `NotchNavigator.expanded` is the detail that is open now (nil = the dashboard).
enum WorkspaceKind: String, CaseIterable, Codable, Identifiable {
    case nook, askAI, tray, calendar, clipboard, agents, terminal, prompter, music, todo, notes, radio, mirror

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nook: String(localized: "Dashboard")
        case .askAI: String(localized: "Ask AI")
        case .tray: String(localized: "Tray")
        case .calendar: String(localized: "Calendar")
        case .clipboard: String(localized: "Clipboard")
        case .agents: String(localized: "Agents")
        case .terminal: String(localized: "Terminal")
        case .prompter: String(localized: "Prompter")
        case .music: String(localized: "Music")
        case .todo: String(localized: "To-dos")
        case .notes: String(localized: "Notes")
        case .radio: String(localized: "Radio")
        case .mirror: String(localized: "Mirror")
        }
    }

    var symbol: String {
        switch self {
        case .nook: "square.grid.2x2"
        case .askAI: "sparkles"
        case .tray: "tray.full"
        case .calendar: "calendar"
        case .clipboard: "doc.on.clipboard"
        case .agents: "cpu"   // not "sparkles": that is Ask AI's
        case .terminal: "terminal"
        case .prompter: "text.viewfinder"
        case .music: "music.note"
        case .todo: "checklist"
        case .notes: "note.text"
        case .radio: "radio"
        case .mirror: "person.crop.square"
        }
    }

    var owner: Lane {
        switch self {
        case .nook, .music: .a
        case .clipboard, .askAI, .todo, .notes: .b
        case .tray, .calendar, .agents, .terminal, .prompter, .radio, .mirror: .c
        }
    }
}

// MARK: - Nook widgets

/// Widgets that can sit in the Nook grid (and some on the lock screen).
enum WidgetKind: String, CaseIterable, Codable, Identifiable {
    case media, calendar, weather, mirror, pulse, timer, pomodoro, todo, notes, clipboard, shortcuts, volume, tray, aiUsage, quickApps, agents, askAI, prompter, today

    var id: String { rawValue }

    var title: String {
        switch self {
        case .media: String(localized: "Media")
        case .calendar: String(localized: "Calendar")
        case .weather: String(localized: "Weather")
        case .mirror: String(localized: "Mirror")
        case .pulse: String(localized: "Pulse")
        case .timer: String(localized: "Timer")
        case .pomodoro: String(localized: "Pomodoro")
        case .todo: String(localized: "To-dos")
        case .notes: String(localized: "Notes")
        case .clipboard: String(localized: "Clipboard")
        case .shortcuts: String(localized: "Shortcuts")
        case .volume: String(localized: "Volume")
        case .tray: String(localized: "Tray")
        case .aiUsage: String(localized: "AI Usage")
        case .quickApps: String(localized: "Quick Apps")
        case .agents: String(localized: "Agents")
        case .askAI: String(localized: "Ask AI")
        case .prompter: String(localized: "Prompter")
        case .today: String(localized: "Today")
        }
    }

    var symbol: String {
        switch self {
        case .media: "play.circle"
        case .calendar: "calendar"
        case .weather: "cloud.sun"
        case .mirror: "person.crop.square"
        case .pulse: "waveform.path.ecg"
        case .timer: "timer"
        case .pomodoro: "leaf"
        case .todo: "checklist"
        case .notes: "note.text"
        case .clipboard: "doc.on.clipboard"
        case .shortcuts: "square.stack.3d.up"
        case .volume: "speaker.wave.2"
        case .tray: "tray.full"
        case .aiUsage: "gauge.with.dots.needle.33percent"
        case .quickApps: "square.grid.3x3"
        case .agents: "cpu"
        case .askAI: "sparkles"
        case .prompter: "text.viewfinder"
        case .today: "calendar.day.timeline.left"
        }
    }

    /// The detail this panel expands into when it is clicked (or the pointer rests on it); nil = the panel has no detail
    /// and its own controls are all it does. The Weather panel has no bigger forecast, so it does not expand.
    var detail: WorkspaceKind? {
        switch self {
        case .calendar, .today: .calendar
        case .agents: .agents
        case .media: .music
        case .clipboard: .clipboard
        case .tray: .tray
        case .todo: .calendar   // the to-dos live in the Calendar view, beside the month
        case .notes: .notes
        case .askAI: .askAI
        case .prompter: .prompter
        case .mirror: .mirror
        case .weather, .pulse, .timer, .pomodoro, .shortcuts, .volume, .aiUsage, .quickApps: nil
        }
    }

    /// Default width in Nook grid cells (`NookMetrics.cell` points each). Widgets must lay out fluidly:
    /// the default dashboard (agents 4 + Ask AI 4 cells, plus what is live) opens as wide as the width setting allows; the agents
    /// dashboard shrinks to 3 cells when everything else is live, and widens (up to 16) when music or to-dos step aside.
    var defaultSpan: Int {
        switch self {
        case .media, .clipboard: 5
        case .pulse: PulsePrefs.cardsShowGPU(PulsePrefs.selected) ? (Retro.is8bit ? 5 : 6) : 4   // CPU, memory and GPU side by side (2026-11-22): the pixel letters fit in 5 cells, the minimal look's system text needs 6; a tight row takes the extra cells back (`NookStore.minSpan`) and shows CPU and memory alone
        case .calendar, .todo, .notes, .tray, .agents, .askAI, .prompter, .today: 4
        case .volume, .weather, .mirror, .timer, .pomodoro, .shortcuts, .aiUsage, .quickApps: 3
        }
    }

    /// The settings page that holds this widget's options.
    var settingsPane: SettingsPane {
        switch self {
        case .media: .media
        case .calendar, .today: .calendar
        case .weather: .weather
        case .mirror, .pulse, .shortcuts: .widgets
        case .timer, .pomodoro: .clock
        case .todo, .notes: .notesTodo
        case .clipboard: .clipboard
        case .volume: .hud
        case .tray: .tray
        case .aiUsage: .agents
        case .quickApps: .nook   // its settings were on the Ring Tools page, which went with the ring
        case .agents: .agents
        case .askAI: .askAI
        case .prompter: .prompter
        }
    }

    var owner: Lane {
        switch self {
        case .media, .volume: .a
        case .timer, .pomodoro, .todo, .notes, .clipboard, .quickApps, .askAI: .b
        case .calendar, .weather, .mirror, .pulse, .shortcuts, .tray, .aiUsage, .agents, .prompter, .today: .c
        }
    }

    /// What a fresh install shows on the dashboard: the Agents panel, the Ask AI line, the CPU and memory graph and Today (the day's
    /// events and to-dos in one; the date, time and year when there is nothing).
    /// The rest shows while it is live.
    static let defaultLayout: [WidgetKind] = [.agents, .askAI, .pulse, .today]

    /// The name in the "+" menu.
    var menuTitle: String { self == .pulse ? String(localized: "CPU & Memory") : title }

    /// The dashboard before the panels could expand: a saved layout equal to this was never changed by the user.
    static let previousDefaultLayout: [WidgetKind] = [.agents, .media, .pulse, .timer, .todo]
}

enum NookMetrics {
    static let cell: CGFloat = 50
    static let widgetHeight: CGFloat = 140
    static let spacing: CGFloat = 8
    /// An agent tab's panel on the dashboard (full edition), in cells.
    static let tabSpan = 3
}

// MARK: - Settings pages

enum SettingsGroup: String, CaseIterable, Identifiable {
    case app = "Scout"
    case notch = "Notch"
    case ring = "Tools"   // the radial ring itself was removed (2026-11-16); these panes (Ask AI, Clipboard, Timers…) stay
    case features = "Features"
    var id: String { rawValue }

    /// The heading in the Settings sidebar (the raw value is an identifier and stays English).
    var title: String {
        switch self {
        case .app: "Scout"
        case .notch: String(localized: "Notch")
        case .ring: String(localized: "Tools")
        case .features: String(localized: "Features")
        }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    // Scout; Appearance right under General
    case general, appearance, shortcuts, permissions
    // Notch
    case notch, liveActivities, nook, media, hud, lockScreen
    // Ring
    case askAI, clipboard, clock, notesTodo
    // Features
    case calendar, weather, widgets, tray, downloads, prompter, terminal, messages, agents, windows, radio
    // About
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .appearance: String(localized: "Appearance")
        case .shortcuts: String(localized: "Keyboard Shortcuts")
        case .permissions: String(localized: "Permissions")
        case .notch: String(localized: "Notch")
        case .liveActivities: String(localized: "Live Activities")
        case .nook: String(localized: "Nook")
        case .media: String(localized: "Media")
        case .hud: EditionTitles.hudPane
        case .lockScreen: String(localized: "Lock Screen")
        case .askAI: String(localized: "Ask AI")
        case .clipboard: String(localized: "Clipboard")
        case .clock: String(localized: "Timers & Pomodoro")
        case .notesTodo: String(localized: "Notes & To-dos")
        case .calendar: String(localized: "Calendar")
        case .weather: String(localized: "Weather")
        case .widgets: String(localized: "Mirror, Pulse & Shortcuts")
        case .tray: String(localized: "Tray & Pockets")
        case .downloads: EditionTitles.downloadsPane
        case .prompter: String(localized: "Prompter")
        case .terminal: String(localized: "Terminal")
        case .messages: String(localized: "Messages")
        case .agents: EditionTitles.agentsPane
        case .windows: String(localized: "Windows")
        case .radio: String(localized: "Radio")
        case .about: String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .shortcuts: "keyboard"
        case .permissions: "lock.shield"
        case .notch: "rectangle.topthird.inset.filled"
        case .liveActivities: "dot.radiowaves.left.and.right"
        case .nook: "square.grid.2x2"
        case .media: "music.note"
        case .hud: "speaker.wave.2"
        case .lockScreen: "lock"
        case .askAI: "sparkles"
        case .clipboard: "doc.on.clipboard"
        case .clock: "timer"
        case .notesTodo: "checklist"
        case .calendar: "calendar"
        case .weather: "cloud.sun"
        case .widgets: "square.grid.3x2"
        case .tray: "tray.full"
        case .downloads: "arrow.down.circle"
        case .prompter: "text.viewfinder"
        case .terminal: "terminal"
        case .messages: "message"
        case .agents: "cpu"
        case .windows: "rectangle.split.2x1"
        case .radio: "radio"
        case .about: "info.circle"
        }
    }

    var group: SettingsGroup {
        switch self {
        case .general, .appearance, .shortcuts, .permissions, .about: .app
        case .notch, .liveActivities, .nook, .media, .hud, .lockScreen: .notch
        case .askAI, .clipboard, .clock, .notesTodo: .ring
        case .calendar, .weather, .widgets, .tray, .downloads, .prompter, .terminal, .messages, .agents, .windows, .radio: .features
        }
    }

    var owner: Lane {
        switch group {
        case .app, .notch: .a
        case .ring: .b
        case .features: .c
        }
    }
}

// MARK: - View factories (the only place that maps kinds to each module's view types)

@MainActor
enum Registry {
    static func workspaceView(_ kind: WorkspaceKind) -> AnyView {
        switch kind {
        case .nook: AnyView(NookWorkspaceView())
        case .askAI: AnyView(AskAINotchView())
        case .tray: AnyView(TrayWorkspaceView())
        case .calendar: AnyView(CalendarWorkspaceView())
        case .clipboard: AnyView(ClipboardWorkspaceView())
        case .agents: AnyView(AgentsWorkspaceView())
        case .terminal: AnyView(TerminalWorkspaceView())
        case .prompter: AnyView(PrompterWorkspaceView())
        case .music: AnyView(MusicWorkspaceView())
        case .todo: AnyView(CalendarWorkspaceView())   // the To-dos are part of the Calendar view (the owner, 2026-11-16)
        case .notes: AnyView(NotesWorkspaceView())
        case .radio: AnyView(RadioWorkspaceView())
        case .mirror: AnyView(MirrorWorkspaceView())
        }
    }

    static func widgetView(_ kind: WidgetKind) -> AnyView {
        switch kind {
        case .media: AnyView(MediaWidgetView())
        case .calendar: AnyView(CalendarWidgetView())
        case .today: AnyView(TodayWidgetView())
        case .weather: AnyView(WeatherWidgetView())
        case .mirror: AnyView(MirrorWidgetView())
        case .pulse: AnyView(PulseWidgetView())
        case .timer: AnyView(TimerWidgetView())
        case .pomodoro: AnyView(PomodoroWidgetView())
        case .todo: AnyView(TodoWidgetView())
        case .notes: AnyView(NotesWidgetView())
        case .clipboard: AnyView(ClipboardWidgetView())
        case .shortcuts: AnyView(ShortcutsWidgetView())
        case .volume: AnyView(VolumeWidgetView())
        case .tray: AnyView(TrayWidgetView())
        case .aiUsage: AnyView(AIUsageWidgetView())
        case .quickApps: AnyView(QuickAppsWidgetView())
        case .agents: AnyView(AgentNookDashboardPanel())   // the AgentNook: each agent a little room (was AgentsWidgetView's rows)
        case .askAI: AnyView(AskAIWidgetView())
        case .prompter: AnyView(PrompterWidgetView())
        }
    }

    static func settingsView(_ pane: SettingsPane) -> AnyView {
        switch pane {
        case .general: AnyView(GeneralSettingsPane())
        case .appearance: AnyView(AppearanceSettingsPane())
        case .shortcuts: AnyView(ShortcutsSettingsPane())
        case .permissions: AnyView(PermissionsSettingsPane())
        case .notch: AnyView(NotchSettingsPane())
        case .liveActivities: AnyView(LiveActivitiesSettingsPane())
        case .nook: AnyView(NookSettingsPane())
        case .media: AnyView(MediaSettingsPane())
        case .hud: AnyView(HUDSettingsPane())
        case .lockScreen: AnyView(LockScreenSettingsPane())
        case .askAI: AnyView(AskAISettingsPane())
        case .clipboard: AnyView(ClipboardSettingsPane())
        case .clock: AnyView(ClockSettingsPane())
        case .notesTodo: AnyView(NotesTodoSettingsPane())
        case .calendar: AnyView(CalendarSettingsPane())
        case .weather: AnyView(WeatherSettingsPane())
        case .widgets: AnyView(WidgetsSettingsPane())
        case .tray: AnyView(TraySettingsPane())
        case .downloads: AnyView(DownloadsSettingsPane())
        case .prompter: AnyView(PrompterSettingsPane())
        case .terminal: AnyView(TerminalSettingsPane())
        case .messages: AnyView(MessagesSettingsPane())
        case .agents: AnyView(AgentsSettingsPane())
        case .windows: AnyView(WinSettingsPane())
        case .radio: AnyView(RadioSettingsPane())
        case .about: AnyView(AboutSettingsPane())
        }
    }

    /// Shown in the open notch while files or a link are dragged over it (the features code: Tray / AirDrop / Convert).
    static func dropTargetsView() -> AnyView { AnyView(NotchDropTargetsView()) }

    // MARK: Agent tabs on the dashboard (full edition; the App Store edition has none)

    /// Fires when a tab is opened, closed or changes state (the dashboard sizes itself from the tabs).
    static func agentTabChanges() -> AnyPublisher<Void, Never> {
        #if !APPSTORE
        return AgentTabStore.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        #else
        return Empty<Void, Never>().eraseToAnyPublisher()
        #endif
    }

    /// The ids of the open agent tabs, in the order they were made.
    static func agentTabIDs() -> [String] {
        #if !APPSTORE
        return AgentTabStore.shared.tabs.map(\.id)
        #else
        return []
        #endif
    }

    /// The dashboard panel of one agent tab: the agent's glyph, its folder and a status line.
    static func agentTabPanel(_ id: String) -> AnyView {
        #if !APPSTORE
        return AnyView(AgentTabPanelView(tabID: id))
        #else
        return AnyView(EmptyView())
        #endif
    }

    /// A tab panel was clicked: the island expands into that tab's terminal.
    static func expandAgentTab(_ id: String) {
        #if !APPSTORE
        if let tab = AgentTabStore.shared.tab(id: id) { AgentTabStore.shared.select(tab) }
        #endif
    }

    /// The name on the back control while a tab is expanded.
    static func agentTabTitle(_ id: String) -> String {
        #if !APPSTORE
        return AgentTabStore.shared.tab(id: id)?.menuTitle ?? String(localized: "Terminal")
        #else
        return String(localized: "Terminal")
        #endif
    }
}

// MARK: - Module bootstrap

/// Each module starts its services and registers debug commands + gallery items.
@MainActor
enum Modules {
    static func startAll() {
        NotchModule.start()          // notch, live activities, media, HUD, system activities
        RingModule.start()           // Ask AI's start and the tools' commands (the radial ring itself was removed, 2026-11-16)
        ProductivityModule.start()   // clipboard, notes, to-dos, clock stores + their notch faces
        FeaturesModule.start()       // calendar, weather, tray, prompter, terminal, messages, agents…
        WindowsFeature.start()       // Windows: Scout's own windows come back after a restart
        LEDFeature.start()           // LED announcement board: welcome, bye and done for the agents
    }

    static func registerGalleryAll() {
        LeadGallery.register()
        NotchModule.registerGallery()
        RingModule.registerGallery()
        ProductivityModule.registerGallery()
        FeaturesModule.registerGallery()
        WindowsFeature.registerGallery()
        LEDGallery.register()        // led-*: the LED announcement board
        RetroGallery.register()      // retro-*: the 90s kit
        StoreShots.register()        // App Store screenshot scenes
        AppIconGallery.register()    // appicon-*: candidates for a new app icon and menu-bar faces (nothing in use yet)
    }
}
