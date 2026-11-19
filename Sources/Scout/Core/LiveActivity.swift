import SwiftUI

// Live activities sit in the "wings" left and right of the CLOSED notch (artwork + visualizer, a countdown,
// AirPods battery, a download ring…). Cards drop below the notch for a few seconds (download finished,
// new message, screenshot copied…). Any part of the app posts here; the notch code renders them.

enum LiveActivityKind: String, CaseIterable, Codable, Identifiable {
    case hud, announcement, agent, ai, message, calendar, timer, pomodoro, recording, download, video, conversion, tray, bluetooth, battery, media, radio, update

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hud: EditionTitles.hudActivity
        case .announcement: String(localized: "Announcements")
        case .agent: String(localized: "AI agents")
        case .ai: String(localized: "Ask AI")
        case .message: String(localized: "Messages")
        case .calendar: String(localized: "Calendar")
        case .timer: String(localized: "Timers")
        case .pomodoro: String(localized: "Pomodoro")
        case .recording: String(localized: "Recording")
        case .download: String(localized: "Downloads")
        case .video: String(localized: "Video downloads")
        case .conversion: String(localized: "File conversions")
        case .tray: String(localized: "Tray")
        case .bluetooth: String(localized: "AirPods & Bluetooth")
        case .battery: String(localized: "Battery")
        case .media: String(localized: "Now playing")
        case .radio: String(localized: "Radio")
        case .update: String(localized: "Updates")
        }
    }

    var symbol: String {
        switch self {
        case .hud: "speaker.wave.2"
        case .announcement: "megaphone"
        case .agent: "sparkles"
        case .ai: "sparkles"
        case .message: "message"
        case .calendar: "calendar"
        case .timer: "timer"
        case .pomodoro: "leaf"
        case .recording: "record.circle"
        case .download: "arrow.down.circle"
        case .video: "play.rectangle"
        case .conversion: "arrow.triangle.2.circlepath"
        case .tray: "tray.full"
        case .bluetooth: "airpodspro"
        case .battery: "battery.75percent"
        case .media: "music.note"
        case .radio: "radio"
        case .update: "arrow.down.app"
        }
    }

    /// Higher wins the wings. Order of the enum = default importance.
    var defaultPriority: Int {
        let all = Self.allCases
        return (all.count - (all.firstIndex(of: self) ?? 0)) * 10
    }

    /// Settings key the notch's Live Activities page writes; posters don't need to check it.
    var enabledKey: String { "activity.\(rawValue).enabled" }
}

struct LiveActivity: Identifiable {
    let id: String
    var kind: LiveActivityKind
    var priority: Int
    var leading: AnyView
    var trailing: AnyView
    /// Optional summary shown when the pointer rests on the closed notch.
    var detail: AnyView?
    var expiresAt: Date?
    var onTap: (() -> Void)?
    var postedAt = Date()

    init<L: View, T: View>(
        id: String,
        kind: LiveActivityKind,
        priority: Int? = nil,
        expiresAfter: TimeInterval? = nil,
        onTap: (() -> Void)? = nil,
        @ViewBuilder leading: () -> L,
        @ViewBuilder trailing: () -> T
    ) {
        self.id = id
        self.kind = kind
        self.priority = priority ?? kind.defaultPriority
        self.leading = AnyView(leading())
        self.trailing = AnyView(trailing())
        self.expiresAt = expiresAfter.map { Date().addingTimeInterval($0) }
        self.onTap = onTap
    }

    func withDetail<D: View>(@ViewBuilder _ detail: () -> D) -> LiveActivity {
        var copy = self
        copy.detail = AnyView(detail())
        return copy
    }
}

/// A card that drops below the notch for `duration` seconds.
struct NotchCard: Identifiable {
    let id: String
    var kind: LiveActivityKind?
    var duration: TimeInterval
    var content: AnyView
    var onTap: (() -> Void)?

    init<C: View>(id: String = UUID().uuidString, kind: LiveActivityKind? = nil, duration: TimeInterval = 4,
                  onTap: (() -> Void)? = nil, @ViewBuilder content: () -> C) {
        self.id = id
        self.kind = kind
        self.duration = duration
        self.content = AnyView(content())
        self.onTap = onTap
    }
}

@MainActor
final class LiveActivityCenter: ObservableObject {
    static let shared = LiveActivityCenter()

    @Published private(set) var activities: [LiveActivity] = []
    @Published private(set) var cards: [NotchCard] = []

    private var expiryTokens: [String: UUID] = [:]
    private var cardTokens: [String: UUID] = [:]

    /// The activity that owns the wings right now: highest priority, then newest.
    var primary: LiveActivity? {
        activities.max { a, b in a.priority == b.priority ? a.postedAt < b.postedAt : a.priority < b.priority }
    }

    /// Everything else, for the small bubble beside the wings.
    var secondary: [LiveActivity] {
        guard let primary else { return [] }
        return activities.filter { $0.id != primary.id }
    }

    func isEnabled(_ kind: LiveActivityKind) -> Bool {
        UserDefaults.standard.object(forKey: kind.enabledKey) as? Bool ?? true
    }

    /// Add or replace (same id) an activity. Disabled kinds are dropped here.
    func show(_ activity: LiveActivity) {
        guard isEnabled(activity.kind) else { dismiss(id: activity.id); return }
        var activity = activity
        if let i = activities.firstIndex(where: { $0.id == activity.id }) {
            activity.postedAt = activities[i].postedAt
            activities[i] = activity
        } else {
            activities.append(activity)
        }
        scheduleExpiry(for: activity)
    }

    func dismiss(id: String) {
        activities.removeAll { $0.id == id }
        expiryTokens[id] = nil
    }

    func dismissAll(kind: LiveActivityKind) {
        activities.removeAll { $0.kind == kind }
    }

    func present(_ card: NotchCard) {
        if let kind = card.kind, !isEnabled(kind) { return }
        cards.removeAll { $0.id == card.id }
        cards.append(card)
        let token = UUID()
        cardTokens[card.id] = token
        let id = card.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(card.duration * 1_000_000_000))
            guard let self, self.cardTokens[id] == token else { return }
            self.dismissCard(id: id)
        }
    }

    func dismissCard(id: String) {
        cards.removeAll { $0.id == id }
        cardTokens[id] = nil
    }

    private func scheduleExpiry(for activity: LiveActivity) {
        guard let expiresAt = activity.expiresAt else { expiryTokens[activity.id] = nil; return }
        let token = UUID()
        expiryTokens[activity.id] = token
        let id = activity.id
        let delay = max(0, expiresAt.timeIntervalSinceNow)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.expiryTokens[id] == token else { return }
            self.dismiss(id: id)
        }
    }
}

// MARK: - Toasts ("Copied", "Screenshot saved and copied"…) — shown as a small card under the notch.

enum ToastStyle { case success, info, warning, error }

enum Toast {
    @MainActor
    static func show(_ message: LocalizedStringKey, symbol: String = "checkmark.circle.fill", style: ToastStyle = .success, duration: TimeInterval = 2) {
        present(Text(message), symbol: symbol, style: style, duration: duration)
    }

    /// A message that is already a finished string (an error text, a name): shown as it is.
    @MainActor
    static func show(verbatim message: String, symbol: String = "checkmark.circle.fill", style: ToastStyle = .success, duration: TimeInterval = 2) {
        present(Text(verbatim: message), symbol: symbol, style: style, duration: duration)
    }

    @MainActor
    private static func present(_ message: Text, symbol: String, style: ToastStyle, duration: TimeInterval) {
        LiveActivityCenter.shared.present(NotchCard(id: "toast", duration: duration) {
            ToastView(message: message, symbol: symbol, style: style)
        })
    }
}

struct ToastView: View {
    let message: Text
    let symbol: String
    let style: ToastStyle

    init(message: Text, symbol: String, style: ToastStyle) { self.message = message; self.symbol = symbol; self.style = style }
    init(message: LocalizedStringKey, symbol: String, style: ToastStyle) { self.init(message: Text(message), symbol: symbol, style: style) }

    private var tint: Color {
        switch style {
        case .success: .green
        case .info: Theme.accent
        case .warning: .orange
        case .error: .red
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            message.font(.system(size: 13, weight: .medium)).lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - Navigation of the notch (the notch's controller observes this; everyone may call it)

@MainActor
final class NotchNavigator: ObservableObject {
    static let shared = NotchNavigator()

    @Published var isOpen = false
    /// What the open island shows: `.nook` = the DASHBOARD (the grid of panels), anything else = the detail a panel expanded
    /// into (the full Calendar, the full Agents view…). Kept as a plain property for older callers; `expanded` is the same
    /// thing with nil for the dashboard. The notch opens on the dashboard (or on the tab the lock key keeps, `NotchPrefs.lockedTab`), so nothing else saves this between runs.
    @Published var workspace: WorkspaceKind = .nook {
        didSet {
            if workspace == .todo { workspace = NotchPrefs.merged(workspace) }   // the To-dos are in the Calendar view now
            #if !APPSTORE
            if activeTab != nil { activeTab = nil }   // choosing a workspace leaves the agent tab
            #endif
            if isOpen, workspace != oldValue { NookHaptics.tick() }   // a panel expanded, or the island went back
        }
    }
    /// A part of the app can ask the notch to open on a detail while something is happening (e.g. an agent needs an answer).
    @Published var preferredWorkspace: WorkspaceKind?
    /// True while files or a link are dragged over the notch (the notch code sets it; the features' drop targets show).
    @Published var isDropTargeting = false
    /// The open notch stays open while true (typing in a text field, a menu open, a drag in progress).
    @Published var holdOpenReasons: Set<String> = []
    /// A workspace may ask the open island to grow DOWN to this height (Ask AI while it answers); nil = the
    /// height setting. The island's top never moves.
    @Published var workspaceHeight: CGFloat?
    /// How tall the island can usefully be dragged for the shown workspace: the height that shows ALL its content
    /// (a long chat, every row of agents). nil = everything already fits, so there is no resize grip.
    @Published var resizeMax: CGFloat?
    /// Heights the user chose by dragging the open island's bottom edge, per workspace (saved). They win over
    /// `workspaceHeight` until a double-click on the grip clears them.
    @Published private(set) var draggedHeights: [String: CGFloat] = NotchNavigator.savedDraggedHeights()

    /// The detail that is open now (a panel expanded into it); nil = the dashboard.
    var expanded: WorkspaceKind? {
        get { workspace == .nook ? nil : workspace }
        set { workspace = newValue ?? .nook }
    }

    /// True while the island shows a detail (or, in the full edition, an agent tab) instead of the dashboard.
    var isExpanded: Bool {
        #if !APPSTORE
        if activeTab != nil { return true }
        #endif
        return workspace != .nook
    }

    /// Back to the dashboard.
    func collapse() {
        #if !APPSTORE
        if activeTab != nil { activeTab = nil }
        #endif
        if workspace != .nook { workspace = .nook }
    }

    /// Esc in the open notch: back to the dashboard first, then close.
    func escape() {
        if isExpanded { collapse() } else { forceClose() }
    }

    /// A panel grows into the whole island.
    func expand(_ kind: WorkspaceKind) { open(kind) }

    /// The least a drag on the grip may leave the island at, for the tab on show: its automatic height (so nothing it needs is cut off). A
    /// chat scrolls, so the Ask AI tab may be made shorter than its automatic height, down to `chatFloor` (a height chosen there is kept).
    static let chatFloor: CGFloat = 240

    func resizeFloor(shown: WorkspaceKind, automatic: CGFloat) -> CGFloat {
        shown == .askAI ? min(automatic, Self.chatFloor) : automatic
    }

    func draggedHeight(for kind: WorkspaceKind) -> CGFloat? { draggedHeights[kind.rawValue] }
    func draggedHeight(key: String) -> CGFloat? { draggedHeights[key] }

    /// What a drag on the grip resizes: the shown workspace, or (full edition) all agent tabs together.
    func resizeKey(shown: WorkspaceKind) -> String {
        #if !APPSTORE
        if activeTab != nil { return "agentTab" }
        #endif
        return shown.rawValue
    }

    func setDraggedHeight(_ height: CGFloat?, for kind: WorkspaceKind, save: Bool) {
        setDraggedHeight(height, key: kind.rawValue, save: save)
    }

    func setDraggedHeight(_ height: CGFloat?, key: String, save: Bool) {
        draggedHeights[key] = height
        guard save else { return }
        UserDefaults.standard.set(draggedHeights.mapValues { Double($0) }, forKey: "notch.draggedHeights")
    }

    private static func savedDraggedHeights() -> [String: CGFloat] {
        let raw = UserDefaults.standard.dictionary(forKey: "notch.draggedHeights") as? [String: Double] ?? [:]
        return raw.mapValues { CGFloat($0) }
    }

    #if !APPSTORE
    /// Full edition: the id of the agent tab (a terminal running Claude Code, Codex or a shell) the open notch shows,
    /// expanded from its dashboard panel, instead of a workspace; nil = no tab. Setting `workspace` clears it.
    @Published var activeTab: String? {
        didSet { if isOpen, activeTab != oldValue { NookHaptics.tick() } }
    }
    /// How tall the island grows while an agent tab is shown.
    static let agentTabHeight: CGFloat = 420
    #endif

    /// The height the open island must reach for what it shows (an agent tab, or the workspace's own request).
    func neededHeight(shown: WorkspaceKind) -> CGFloat {
        #if !APPSTORE
        if activeTab != nil { return Self.agentTabHeight }
        #endif
        return shown == workspace && (heightOwner == nil || heightOwner == shown) ? (workspaceHeight ?? 0) : 0
    }

    /// Which view's request `workspaceHeight` and `resizeMax` hold. A view that is leaving gets its `onDisappear` AFTER the
    /// next view's `onAppear`, so an unowned "clear" wiped the next view's request: going from Agents to Ask AI the island
    /// grew and then suddenly shrank (the owner, 2026-11-15). A request now belongs to the workspace that made it.
    private(set) var heightOwner: WorkspaceKind?

    /// A full view asks for its height (nil = the height setting) and for how far the grip may pull it.
    func requestHeight(_ height: CGFloat?, resizeMax limit: CGFloat?, by owner: WorkspaceKind) {
        // Only the view on show may ask. A view on its way out can still fire a late request: Ask AI did as its height changed while it left,
        // took the height from the Agents view, then gave it up, and the den opened at the small default height
        guard owner == NotchPrefs.resolve(workspace) else { return }
        heightOwner = owner
        if workspaceHeight != height { workspaceHeight = height }
        if resizeMax != limit { resizeMax = limit }
    }

    /// A full view is leaving: its request goes, unless another view has asked since.
    func releaseHeight(by owner: WorkspaceKind) {
        guard heightOwner == owner else { return }
        heightOwner = nil
        if workspaceHeight != nil { workspaceHeight = nil }
        if resizeMax != nil { resizeMax = nil }
    }

    /// How far the grip may pull the island for `shown` (nil: everything fits, or the request is another view's).
    func resizeMax(shown: WorkspaceKind) -> CGFloat? {
        heightOwner == nil || heightOwner == shown ? resizeMax : nil
    }

    /// Opens the notch. With a workspace it opens with that DETAIL expanded (`.nook` = the dashboard); without one it opens on
    /// the dashboard (or, when a part of the app asked for it, the preferred detail; or, when the lock key keeps one, that tab). An already open
    /// notch keeps what it shows.
    func open(_ workspace: WorkspaceKind? = nil) {
        if let workspace { self.workspace = NotchPrefs.merged(workspace) }
        else if let preferredWorkspace { self.workspace = NotchPrefs.merged(preferredWorkspace) }
        else if !isOpen { self.workspace = NotchPrefs.openingWorkspace }
        isOpen = true
    }

    func close() {
        guard holdOpenReasons.isEmpty else { return }
        isOpen = false
    }

    func forceClose() {
        holdOpenReasons.removeAll()
        isOpen = false
    }

    func toggle(_ workspace: WorkspaceKind? = nil) {
        #if !APPSTORE
        let shown: WorkspaceKind? = activeTab != nil ? nil : self.workspace
        #else
        let shown: WorkspaceKind? = self.workspace
        #endif
        let workspace = workspace.map(NotchPrefs.merged)   // a hotkey for the To-dos toggles the Calendar
        if isOpen, workspace == nil || workspace == shown { forceClose() } else { open(workspace) }
    }

    func hold(_ reason: String) { holdOpenReasons.insert(reason) }
    func release(_ reason: String) { holdOpenReasons.remove(reason) }
}
