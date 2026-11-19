import AppKit
import SwiftUI

// The Settings window shell. Each module writes its own pages (see Registry.settingsView);
// the shell gives every page the same header (icon, title, one line) and scrolling.

@MainActor
final class SettingsSelection: ObservableObject {
    static let shared = SettingsSelection()
    @Published var pane: SettingsPane? = .general
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    /// Keeps the notch open behind the window while it shows (and the window one level above the notch).
    let notchHold: SettingsNotchHold
    private let front: (NSWindow) -> Void
    private let makeContent: () -> NSView
    private let offscreen: Bool
    /// The window, for the self-test.
    var currentWindow: NSWindow? { window }

    /// The app uses `shared`. A self-test gives its own notch hold (on its own navigator), its own way to bring the window forward, a light content
    /// view, and `offscreen` (the window stays where the test puts it and never saves a frame).
    init(notchHold: SettingsNotchHold? = nil, front: ((NSWindow) -> Void)? = nil, content: (() -> NSView)? = nil, offscreen: Bool = false) {
        self.notchHold = notchHold ?? SettingsNotchHold()
        self.front = front ?? { WindowFront.show($0) }
        makeContent = content ?? { NSHostingView(rootView: SettingsRootView().retroStyleRoot()) }
        self.offscreen = offscreen
    }

    func show(_ pane: SettingsPane? = nil) {
        // Opening Settings (it was not on show) starts fresh: the first page, the sidebar and the page both at their tops, whatever was
        // open last time.
        // Asked for a page, it opens on that page.
        let opening = window.map { !$0.isVisible || $0.isMiniaturized } ?? true
        if let pane { SettingsSelection.shared.pane = pane.isAvailable ? pane : .general }
        else if opening { SettingsSelection.shared.pane = .general }
        if let window, opening { window.contentView = makeContent() }   // a new view: both lists start at their tops
        if window == nil {
            let w = ScoutWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 640),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
            w.allowsOffscreen = offscreen
            w.title = String(localized: "Scout Settings")
            w.isReleasedWhenClosed = false
            w.contentMinSize = CGSize(width: 740, height: 480)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden   // the page header names the page; a drawn title sat over the sidebar's search field
            w.toolbarStyle = .unified
            w.contentView = makeContent()
            if !offscreen {
                if !w.setFrameUsingName("Scout.Settings") { w.center() }
                w.setFrameAutosaveName("Scout.Settings")
            }
            window = w
            notchHold.attach(w)
        }
        guard let window else { return }
        front(window)
        notchHold.windowShown()   // the notch opens behind it and stays open while it shows
    }
}

extension SettingsPane {
    /// The title shown in the sidebar and the page header: the App Store edition drops what it leaves out (brightness, video downloads).
    var displayTitle: String {
        guard Edition.isAppStore else { return title }
        switch self {
        case .hud: return String(localized: "Volume")
        case .downloads: return String(localized: "Downloads")
        default: return title
        }
    }

    /// The color of the pane's icon tile in the sidebar.
    var tint: Color {
        switch self {
        case .general: Color(white: 0.5)
        case .appearance: .purple
        case .shortcuts: .blue
        case .permissions: .green
        case .about: Color(white: 0.45)
        case .notch: Theme.amber
        case .liveActivities: .orange
        case .nook: .teal
        case .media: .pink
        case .hud: .blue
        case .lockScreen: .indigo
        case .askAI: .orange
        case .clipboard: .cyan
        case .clock: .red
        case .notesTodo: .yellow
        case .calendar: .red
        case .weather: .blue
        case .widgets: .mint
        case .tray: .brown
        case .downloads: .green
        case .prompter: .purple
        case .terminal: Color(white: 0.2)
        case .messages: .green
        case .agents: .orange
        case .windows: .cyan
        case .radio: .pink
        }
    }

    /// One line under the page title (the App Store edition leaves out brightness and video downloads).
    var blurb: String {
        switch self {
        case .general: String(localized: "Start-up and housekeeping.")
        case .appearance: String(localized: "The 8-bit look, light or dark, colours, sizes and styles.")
        case .shortcuts: String(localized: "Every global shortcut in one place.")
        case .permissions: String(localized: "What Scout can reach, and why it asks.")
        case .about: String(localized: "Version, credits and licenses.")
        case .notch: String(localized: "How the notch looks, opens and where it lives.")
        case .liveActivities: String(localized: "What shows next to the notch while it is closed.")
        case .nook: String(localized: "The widgets in the open notch.")
        #if APPSTORE
        case .media: String(localized: "Spotify, Music and covers.")
        #else
        case .media: String(localized: "Spotify, Music, covers and lyrics.")
        #endif
        #if APPSTORE
        case .hud: String(localized: "The volume pop-up.")
        case .downloads: String(localized: "Download progress.")
        #else
        case .hud: String(localized: "The volume and brightness pop-up.")
        case .downloads: String(localized: "Download progress and video downloads.")
        #endif
        #if APPSTORE
        case .lockScreen, .terminal, .messages, .agents: ""   // not in the App Store edition (never listed)
        #else
        case .lockScreen: String(localized: "Widgets over the lock screen.")
        #endif
        case .askAI: String(localized: "Chat with Claude or GPT in the notch.")
        case .clipboard: String(localized: "The clipboard history.")
        case .clock: String(localized: "Timers, Pomodoro and alarms.")
        case .notesTodo: String(localized: "Quick notes and to-dos.")
        case .calendar: String(localized: "Events, countdowns and meeting links.")
        case .weather: String(localized: "Forecast and location.")
        case .widgets: String(localized: "Mirror, Pulse and Shortcuts widgets.")
        case .tray: String(localized: "The tray, drop targets and pockets.")
        case .prompter: String(localized: "The teleprompter.")
        case .windows: String(localized: "Snap windows to edges, corners and thirds, with the mouse or shortcuts.")
        case .radio: String(localized: "Radio stations by place, and what the Radio tab remembers.")
        #if !APPSTORE
        case .terminal: String(localized: "The terminal in the notch.")
        case .messages: String(localized: "Message cards under the notch.")
        case .agents: String(localized: "Claude Code and Codex activity, and usage.")
        #endif
        }
    }
}

struct SettingsIconTile: View {
    let pane: SettingsPane
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [pane.tint.opacity(0.95), pane.tint.opacity(0.72)], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(Image(systemName: pane.symbol).font(.system(size: size * 0.52, weight: .semibold)).foregroundStyle(.white))
    }
}

struct SettingsRootView: View {
    @ObservedObject private var selection = SettingsSelection.shared
    @State private var search = ""

    private func panes(in group: SettingsGroup) -> [SettingsPane] {
        let all = SettingsPane.available.filter { $0.group == group }
        guard !search.isEmpty else { return all }
        return all.filter { $0.displayTitle.localizedCaseInsensitiveContains(search) || $0.blurb.localizedCaseInsensitiveContains(search) }
    }

    /// The sidebar never hides and never changes width: a plain row
    /// of a fixed sidebar and the page, no split view (its hide key and its drag-to-collapse are gone), and the search field is the sidebar's
    /// own, under the window's buttons.
    static let sidebarWidth: CGFloat = 240

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Self.sidebarWidth)
            Divider().ignoresSafeArea()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            SettingsSearchField(text: $search)
                .frame(height: 28)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)
            List(selection: $selection.pane) {
                ForEach(SettingsGroup.allCases) { group in
                    let items = panes(in: group)
                    if !items.isEmpty {
                        Section(group.title) {
                            ForEach(items) { pane in
                                // The tag must be the plain pane: List matches tags of its selection's element type, so
                                // `Optional(pane)` left every row unselectable (the sidebar ignored clicks).
                                Label { Text(pane.displayTitle) } icon: { SettingsIconTile(pane: pane) }
                                    .tag(pane)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(VisualEffectBackground(material: .sidebar, blending: .behindWindow).ignoresSafeArea())
    }

    private var detail: some View {
        let pane = (selection.pane ?? .general).isAvailable ? (selection.pane ?? .general) : .general
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SettingsPageHeader(pane: pane)
                Registry.settingsView(pane)
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 28)
            .frame(maxWidth: 720, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        // A new scroll view for every page: picking a page on the left shows it from its top at once.
        // On the content, the id kept the offset.
        .id(pane)
        .transaction { $0.animation = nil }
        .clipped()
    }
}

/// The sidebar's search field: the Mac's own search field (the magnifier, the clear key), filtering the pages as you type.
struct SettingsSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = String(localized: "Search")
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("settings.search")
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

struct SettingsPageHeader: View {
    let pane: SettingsPane

    var body: some View {
        HStack(spacing: 12) {
            SettingsIconTile(pane: pane, size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(pane.displayTitle).font(.system(size: 22, weight: .semibold))
                Text(pane.blurb).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 6)
    }
}
