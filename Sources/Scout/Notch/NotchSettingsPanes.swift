import SwiftUI

// Settings pages of the notch: Notch (A1/A2), Live Activities (A4), Nook (A3).

struct NotchSettingsPane: View {
    @AppStorage("notch.style") private var style = NotchStyle.classic.rawValue
    @AppStorage("notch.hover") private var hover = NotchHover.open.rawValue
    @AppStorage("notch.hoverDelay") private var hoverDelay = 0.15
    @AppStorage("notch.clickToOpen") private var clickToOpen = true
    @AppStorage("notch.openWidth") private var width = 1040.0
    @AppStorage("notch.gestures") private var gestures = true
    @AppStorage("notch.gestureInvert") private var gestureInvert = false
    @AppStorage("notch.haptics") private var openTick = true
    @AppStorage("notch.workspaces") private var tabsRaw = ""
    @AppStorage("notch.tabsEdited") private var tabsEdited = false
    @ObservedObject private var nook = NookStore.shared

    /// The real page reads the connected displays; a picture of the page names the kinds of display it pretends to have.
    var shownKinds: [CutoutKind]?
    init(shownKinds: [CutoutKind]? = nil) { self.shownKinds = shownKinds }

    var body: some View {
        Form {
            // The notch's look (style, 8-bit, size, colours) is in Settings › Appearance now (the owner, 2026-11-16).
            Section {
                Picker("Pointing at the notch", selection: $hover) {
                    ForEach(NotchHover.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if hover == NotchHover.open.rawValue {
                    LabeledContent("Wait before opening") {
                        ValueSlider(value: $hoverDelay, range: 0...1, step: 0.05, unit: " s", decimals: 2)
                    }
                }
                Toggle("Clicking the notch opens it", isOn: $clickToOpen).toggleStyle(.switch)
                Toggle("Tick when the notch opens", isOn: $openTick).toggleStyle(.switch)
            } header: {
                Text("Opening")
            } footer: {
                SettingsFootnote("Leaving the open notch closes it after a moment, unless you are typing in it.")
            }

            Section {
                LabeledContent("Widest") {
                    ValueSlider(value: $width, range: NotchPrefs.widthRange, step: 10, unit: " pt")
                }
                NotchSizePreview(width: width, height: NotchPrefs.openHeight, classic: style == NotchStyle.classic.rawValue)
                    .frame(maxWidth: .infinity)
            } header: {
                Text("Size")
            } footer: {
                SettingsFootnote("The open notch is as wide as the widgets on your dashboard, up to this width.")
            }

            NotchCutoutSections(shownKinds: shownKinds)

            Section {
                Toggle("Two-finger swipe on the notch", isOn: $gestures).toggleStyle(.switch)
                Toggle("Swap the swipe directions", isOn: $gestureInvert).toggleStyle(.switch).disabled(!gestures)
            } header: {
                Text("Gestures")
            } footer: {
                SettingsFootnote("Swipe down to open, up to close. While music plays, swipe sideways over the closed notch for the next or previous song.")
            }

            Section {
                PanelOrderEditor(store: nook)
            } header: {
                HStack {
                    Text("Pinned widgets")
                    Spacer()
                    Button("Edit Nook") { nook.beginEditing() }.controlSize(.small)
                }
            } footer: {
                SettingsFootnote("The open notch is one dashboard: the Agents widget and the Ask AI line are always there, and music, a meeting about to start, a timer, a download, a recording, AirPods and open to-dos show up by themselves while they are live. Click a widget and it grows into its full view; Esc goes back, a second Esc closes. Pinned widgets always show, next to the live ones: pin or unpin them here, arrange them by hand with Edit Nook (or right-click a widget).")
            }

            Section {
                TabOrderEditor(raw: $tabsRaw, edited: $tabsEdited)
            } header: {
                Text("Tabs")
            } footer: {
                SettingsFootnote("The icons along the open notch: click one and it opens; the dashboard tab goes back. They start left of the camera and carry on to its right; the Mirror always stands right of it. The lock key next to the gear keeps the tab you are on as the one the notch opens on, instead of the dashboard; press it again to let go. At least one tab stays on.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

}

/// Settings › Notch › Displays and Camera cutout: which displays get the notch, what the Mac's camera cutout is, what Scout draws where there is
/// none, and the button that copies what the system says about the displays (for a Mac Scout reads wrongly). A short section that fits the window
/// without scrolling.
struct NotchCutoutSections: View {
    @AppStorage("notch.screens") private var screens = NotchScreenMode.main.rawValue
    @AppStorage("notch.hideInFullscreen") private var hideInFullscreen = true
    @AppStorage("notch.cutout") private var cutout = CutoutOverride.automatic.rawValue
    @AppStorage("notch.shape") private var noneShape = NoneShape.tab.rawValue
    @AppStorage("notch.agentStyle") private var agentStyle = AgentWingStyle.faces.rawValue
    @State private var copied = false
    @State private var displayChange = 0

    var shownKinds: [CutoutKind]?

    /// Whether a display with a classic notch is connected (the choice of agent style is about it).
    private var hasNotch: Bool {
        _ = displayChange
        let kinds = shownKinds ?? NSScreen.screens.map { NotchGeometry.make(for: $0).kind }
        return kinds.contains(.notch)
    }

    var body: some View {
        Section("Displays") {
            Picker("Show the notch on", selection: $screens) {
                ForEach(NotchScreenMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("On displays without a camera cutout", selection: $noneShape) {
                ForEach(NoneShape.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .disabled(screens == NotchScreenMode.notched.rawValue)
            if hasNotch {
                Picker("Agents beside the notch", selection: $agentStyle) {
                    ForEach(AgentWingStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            Toggle("Hide it while an app is full screen", isOn: $hideInFullscreen).toggleStyle(.switch)
        }

        // Its own section, so its footnote reads as being about these two rows only.
        Section {
            Picker("Camera cutout", selection: $cutout) {
                ForEach(CutoutOverride.allCases) { Text($0.title).tag($0.rawValue) }
            }
            HStack {
                Spacer()
                if copied { Image(systemName: "checkmark").foregroundStyle(.green).accessibilityHidden(true) }
                Button("Copy display details") {
                    guard DisplayReport.copyToClipboard() else { return }
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
            }
        } header: {
            Text("Camera cutout")
        } footer: {
            SettingsFootnote("Only for a Mac that Scout reads wrongly. A Mac with a notch cannot preview a pill.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in displayChange += 1 }
        .onChange(of: agentStyle) { _, _ in showClosedNotch() }
        .onChange(of: noneShape) { _, _ in showClosedNotch() }
    }

    /// These two choices change the CLOSED notch, and Settings holds the notch open behind its window: the notch steps aside for a few seconds
    /// so the change can be seen, then opens again behind Settings.
    private func showClosedNotch() {
        guard !ScoutRuntime.isScripted else { return }
        let until = Date().addingTimeInterval(6)
        SettingsWindowController.shared.notchHold.stepAside { Date() < until }
    }
}

/// Pictures of the Camera cutout section at the Settings window's real size (the page is 660 pt wide beside the 240 pt sidebar of the 900 pt
/// window, 28 pt of margin on both sides), with and without a classic notch among the displays.
@MainActor
enum NotchSettingsGallery {
    static func register() {
        let window: [(name: String, kinds: [CutoutKind])] = [("settings-notch-cutout", [.notch]), ("settings-notch-cutout-nonotch", [.pill, .none])]
        for (name, kinds) in window {
            Gallery.register(name, size: CGSize(width: 660, height: 420), backdrop: .window) {
                Form { NotchCutoutSections(shownKinds: kinds) }
                    .formStyle(.grouped)
                    .scrollDisabled(true)
                    .padding(.horizontal, 28)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

/// Settings › Appearance › Notch: the notch style, the size and the lines between panels (the 8-bit switch and the one light/dark setting
/// head the Appearance page).
struct NotchLookSection: View {
    @AppStorage("notch.style") private var style = NotchStyle.classic.rawValue
    @AppStorage(Look.scaleKey) private var lookSize = Look.Size.normal.rawValue
    @AppStorage("nook.dividers") private var dividers = false

    var body: some View {
            Section {
                Picker("Style", selection: $style) {
                    ForEach(NotchStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Picker("Size", selection: $lookSize) {
                    ForEach(Look.Size.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                // The notch's colours follow the one System / Light / Dark setting above (the owner, 2026-11-16).
                Picker("Lines between widgets", selection: $dividers) {
                    Text("Yes").tag(true)
                    Text("No").tag(false)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Notch")
            } footer: {
                SettingsFootnote("Size draws the open notch bigger, up to a lot bigger, for easier reading. Lines between widgets draws thin lines instead of leaving the widgets as one surface. You can pick the look again in the welcome tour (Settings › General › Show).")
            }
    }
}

/// A scaled picture of the open panel under the notch, so the sliders have something to show.
struct NotchSizePreview: View {
    let width: Double
    let height: Double
    var classic = true
    private let scale: CGFloat = 0.27

    var body: some View {
        let w = CGFloat(width) * scale
        let h = CGFloat(height) * scale
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.14))
                .frame(width: 1300 * scale + 20, height: 440 * scale + 14)
            NotchShape(topRadius: 4, bottomRadius: 9)
                .fill(classic ? Color.black : Color.primary.opacity(0.22))
                .frame(width: w, height: h)
                .overlay(alignment: .top) {
                    UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3).fill(Color.black)
                        .frame(width: 185 * scale, height: 32 * scale)
                }
                .overlay {
                    Text(verbatim: "\(Int(width)) × \(Int(height))")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(classic ? Color.white.opacity(0.8) : Color.secondary)
                        .padding(.top, 14)
                }
                .animation(Theme.quick, value: width)
                .animation(Theme.quick, value: height)
        }
        .frame(height: 440 * scale + 14, alignment: .top)
        .padding(.vertical, 4)
    }
}

/// Which panels are on the dashboard (the same list Edit Nook arranges). A panel marked "opens" has a detail it expands into.
struct PanelOrderEditor: View {
    @ObservedObject var store: NookStore

    var body: some View {
        ForEach(WidgetKind.available) { kind in
            let isOn = store.layout.contains(kind)
            HStack(spacing: 10) {
                Image(systemName: kind.symbol).frame(width: 20).foregroundStyle(isOn ? Theme.accent : Color.secondary)
                Text(kind.title)
                if kind.detail != nil {
                    Text("opens full size").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { isOn }, set: { on in
                    if on { store.add(kind) } else { store.remove(kind) }
                }))
                .labelsHidden().toggleStyle(.switch)
            }
        }
    }
}

/// Switches and order for the tab icons along the open notch's header (the list is `notch.workspaces`, as in older versions).
struct TabOrderEditor: View {
    @Binding var raw: String
    @Binding var edited: Bool

    private var enabled: [WorkspaceKind] { NotchPrefs.parseTabs(raw, edited: edited) }
    private var disabled: [WorkspaceKind] { NotchPrefs.allTabsInOrder.filter { !enabled.contains($0) } }

    var body: some View {
        ForEach(enabled + disabled) { kind in
            let isOn = enabled.contains(kind)
            HStack(spacing: 10) {
                Image(systemName: kind.symbol).frame(width: 20).foregroundStyle(isOn ? Theme.accent : Color.secondary)
                Text(kind.title)
                Spacer()
                if isOn {
                    Button { move(kind, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).disabled(enabled.first == kind).help("Move left")
                    Button { move(kind, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).disabled(enabled.last == kind).help("Move right")
                }
                Toggle("", isOn: Binding(get: { isOn }, set: { set(kind, on: $0) }))
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(isOn && enabled.count == 1)
            }
        }
    }

    private func set(_ kind: WorkspaceKind, on: Bool) {
        var list = enabled
        if on { if !list.contains(kind) { list.append(kind) } } else if list.count > 1 { list.removeAll { $0 == kind } }
        save(list)
    }

    private func move(_ kind: WorkspaceKind, by delta: Int) {
        var list = enabled
        guard let i = list.firstIndex(of: kind), list.indices.contains(i + delta) else { return }
        list.swapAt(i, i + delta)
        save(list)
    }

    private func save(_ list: [WorkspaceKind]) {
        NotchPrefs.saveTabs(list)
        raw = list.map(\.rawValue).joined(separator: ",")
        edited = true
    }
}

// MARK: - Live Activities

struct LiveActivitiesSettingsPane: View {
    @AppStorage("bluetooth.monitor") private var bluetoothMonitor = false
    @AppStorage("media.quickPeek") private var quickPeek = true
    @AppStorage("battery.lowWarning") private var lowWarning = true
    @AppStorage("battery.lowThreshold") private var lowThreshold = 20.0
    @ObservedObject private var battery = BatteryService.shared

    var body: some View {
        Form {
            Section {
                ForEach(LiveActivityKind.allCases.filter(\.listedInSettings)) { kind in
                    ActivityKindRow(kind: kind)
                }
            } header: {
                HStack {
                    Text("Show next to the notch")
                    Spacer()
                    Text("Full screen").font(.caption).foregroundStyle(.secondary).frame(width: 74)
                }
            } footer: {
                SettingsFootnote("Several at once? The most important one takes the sides and the others become a small dot.")
            }
            Section("Cards") {
                Toggle("Peek at the song when it changes", isOn: $quickPeek).toggleStyle(.switch)
            }
            LEDSettingsSection()   // the announcement board's switch and Test button
            Section {
                LabeledContent("Battery now") {
                    Text(batteryNow).foregroundStyle(.secondary).monospacedDigit()
                }
                Toggle("Warn when the battery is low", isOn: $lowWarning).toggleStyle(.switch).disabled(battery.state == nil)
                LabeledContent("Warn at") {
                    ValueSlider(value: $lowThreshold, range: 5...50, step: 5, unit: " %")
                }
                .disabled(!lowWarning || battery.state == nil)
            } header: {
                Text("Battery")
            } footer: {
                SettingsFootnote("Plugging in, unplugging and reaching a full charge show up next to the notch. Macs without a battery show a dash.")
            }
            if !bluetoothMonitor {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AirPods notices need Bluetooth")
                            Text("Scout only watches for connections once you allow it.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Turn on") { bluetoothMonitor = true }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var batteryNow: String {
        guard let state = battery.state else { return "—" }
        if state.isCharged { return String(localized: "\(state.level) %, fully charged") }
        return state.isPluggedIn ? String(localized: "\(state.level) %, charging") : String(localized: "\(state.level) %, on battery")
    }
}

private struct ActivityKindRow: View {
    let kind: LiveActivityKind
    @AppStorage private var enabled: Bool
    @AppStorage private var fullscreen: Bool

    init(kind: LiveActivityKind) {
        self.kind = kind
        _enabled = AppStorage(wrappedValue: true, kind.enabledKey)
        _fullscreen = AppStorage(wrappedValue: false, "activity.\(kind.rawValue).fullscreen")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.symbol).frame(width: 20).foregroundStyle(enabled ? Theme.accent : Color.secondary)
            Text(kind.displayTitle)
            Spacer()
            Toggle("Show in full screen", isOn: $fullscreen)
                .labelsHidden().toggleStyle(.checkbox)
                .frame(width: 74)
                .disabled(!enabled)
                .help("Also show it while an app is full screen")
            Toggle("", isOn: $enabled).labelsHidden().toggleStyle(.switch)
        }
    }
}

// MARK: - Nook

struct NookSettingsPane: View {
    @ObservedObject private var store = NookStore.shared

    var body: some View {
        Form {
            QuickAppsSettingsSection()
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Arrange the widgets")
                        Text("Drag to reorder, drag out to remove, click a widget for its options.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit Nook") { store.beginEditing() }
                }
                // The lines between the panels are in Settings › Appearance › Notch now
            } header: {
                Text("Layout")
            }

            Section("On the dashboard now") {
                if store.layout.isEmpty {
                    Text("No widgets yet").foregroundStyle(.secondary)
                }
                ForEach(store.layout) { kind in
                    HStack(spacing: 10) {
                        Image(systemName: kind.symbol).frame(width: 20).foregroundStyle(Theme.accent)
                        Text(kind.title)
                        Spacer()
                        Button("Options") { SettingsWindowController.shared.show(kind.settingsPane) }.buttonStyle(.link)
                        Button { store.remove(kind) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove from the dashboard")
                    }
                }
            }

            Section("Not on the dashboard") {
                ForEach(store.palette) { kind in
                    HStack(spacing: 10) {
                        Image(systemName: kind.symbol).frame(width: 20).foregroundStyle(.secondary)
                        Text(kind.title)
                        Spacer()
                        Button { store.add(kind) } label: { Image(systemName: "plus.circle") }
                            .buttonStyle(.borderless).help("Add to the dashboard")
                    }
                }
                HStack {
                    Spacer()
                    Button("Restore default widgets") { store.restoreDefaults() }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

extension LiveActivityKind {
    /// The name in settings lists: the App Store edition has no brightness.
    var displayTitle: String { Edition.isAppStore && self == .hud ? String(localized: "Volume") : title }

    /// What the Live Activities page offers a switch for. The App Store edition also leaves out "Updates" (the store updates the app).
    var listedInSettings: Bool { isAvailable && !(Edition.isAppStore && self == .update) }
}

/// The Quick Apps widget's apps, up to `PinnedAppsStore.maxApps`. They were set on the Ring Tools page, which went with the ring (2026-11-16).
struct QuickAppsSettingsSection: View {
    @ObservedObject private var apps = PinnedAppsStore.shared

    var body: some View {
        Section {
            ForEach(apps.apps) { app in
                HStack(spacing: 8) {
                    Image(nsImage: AppIcons.icon(forPath: app.path)).resizable().frame(width: 20, height: 20)
                    Text(app.name)
                    Spacer()
                    Button { apps.remove(app) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Take \(app.name) off the Quick Apps widget")
                }
            }
            Button("Add app…") { apps.chooseApp() }.disabled(apps.isFull)
        } header: {
            Text("Quick Apps")
        } footer: {
            SettingsFootnote("Apps for the Quick Apps widget on the dashboard (up to \(PinnedAppsStore.maxApps)).")
        }
    }
}
