import AppKit


@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()
    private var appearanceObserver: NSObjectProtocol?
    /// macOS turning light or dark: the notch follows when the setting is System.
    private var systemAppearanceObserver: NSKeyValueObservation?

    func applicationWillFinishLaunching(_ notification: Notification) {
        DebugCommands.install()
        AppAppearance.mergeOnce()
        AppAppearance.apply()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Scripted checks that must stay invisible: only the Agents store and scanner run.
        if ScoutRuntime.isHeadless { AgentsFeature.startHeadless(); HeadlessChecks.registerAll(); return }
        // Read before the modules start (they write their own settings at once): has Scout run on this Mac before?
        let usedBefore = ["notch.lastWorkspace", "nook.layout", "agents.nook.migrated"].contains { UserDefaults.standard.object(forKey: $0) != nil }
        NoneShapeMigration.runOnce(usedBefore: usedBefore)   // what a display without a camera cutout shows, decided once, before any module reads it
        StatusMenu.shared.install()
        Modules.startAll()
        WorkspaceHotKeys.shared.start()
        appearanceObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppAppearance.apply() }
        }
        systemAppearanceObserver = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in AppAppearance.syncNotch() }
        }
        // First launch: a short welcome, ONCE. (It came back at every launch until its last button was pressed, so a
        // tour closed with the red button reappeared after every update.) Never in scripted runs.
        if !ScoutRuntime.isScripted, !Pref.bool("app.onboarded", false) {
            Pref.set(true, "app.onboarded")
            if !usedBefore { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { OnboardingWindow.shared.show() } }
        }
    }

    /// Opening the app again (Finder, Spotlight) shows Settings, like other menu-bar apps.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return String(localized: "System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }

    @MainActor
    static func apply() {
        let wanted: NSAppearance?
        switch AppAppearance(rawValue: Pref.string("app.appearance", "system")) ?? .system {
        case .system: wanted = nil
        case .light: wanted = NSAppearance(named: .aqua)
        case .dark: wanted = NSAppearance(named: .darkAqua)
        }
        if NSApp.appearance?.name != wanted?.name { NSApp.appearance = wanted }
        syncNotch()
    }

    static var current: AppAppearance { AppAppearance(rawValue: Pref.string("app.appearance", "system")) ?? .system }

    /// ONE light/dark setting for everything:
    /// Scout's windows and the open notch follow it together.
    @MainActor static func set(_ choice: AppAppearance) {
        Pref.set(choice.rawValue, "app.appearance")
        apply()
    }

    /// The open notch's colours from that one setting: Light and Dark directly, System as macOS is now (and again whenever macOS changes).
    /// Scripted runs keep the colours they set themselves.
    @MainActor static func syncNotch() {
        guard !ScoutRuntime.isScripted else { return }
        let want = notchPreset(for: current, systemDark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua).rawValue
        if Pref.string(Look.presetKey, Look.Preset.dark.rawValue) != want { Pref.set(want, Look.presetKey) }
    }

    /// The notch's colours for a choice: Light and Dark directly, System as macOS is.
    static func notchPreset(for choice: AppAppearance, systemDark: Bool) -> Look.Preset {
        switch choice {
        case .light: .light
        case .dark: .dark
        case .system: systemDark ? .dark : .light
        }
    }

    /// Once, when the two settings became one: the notch keeps the colours it had. A picked notch colour becomes the one setting; with
    /// nothing picked the notch was dark (the default) and stays dark, unless the windows had been set to Light or Dark on purpose.
    @MainActor static func mergeOnce() {
        guard !ScoutRuntime.isScripted, !Pref.bool("appearance.merged", false) else { return }
        Pref.set(true, "appearance.merged")
        if let picked = UserDefaults.standard.string(forKey: Look.presetKey), AppAppearance(rawValue: picked) != nil {
            Pref.set(picked, "app.appearance")
        } else if UserDefaults.standard.string(forKey: "app.appearance") == nil {
            Pref.set(AppAppearance.dark.rawValue, "app.appearance")
        }
    }
}
