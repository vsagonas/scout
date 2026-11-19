import AppKit
import ServiceManagement
import SwiftUI

struct GeneralSettingsPane: View {
    @AppStorage("app.haptics") private var haptics = true
    @AppStorage("app.showMenuBarIcon") private var showIcon = true
    @State private var launchAtLogin = false
    @State private var loginNote: String?
    @State private var confirmReset = false
    @State private var language: String
    @State private var restartNote: String?

    /// `previewChoice`: the gallery's picture of a language picked in this run (the Restart row showing).
    init(previewChoice: String? = nil) {
        _language = State(initialValue: previewChoice ?? AppLanguage.chosen)
    }

    var body: some View {
        Form {
            Section("Start-up") {
                Toggle("Open Scout when you log in", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                    .toggleStyle(.switch)
                if let loginNote {
                    Text(loginNote).font(.caption).foregroundStyle(.orange)
                }
                Toggle("Show Scout in the menu bar", isOn: $showIcon).toggleStyle(.switch)
                if !showIcon {
                    Text("With the icon hidden, open Settings from the gear in the open notch, or open Scout again from Finder or Spotlight.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // Scout's own language.
            Section {
                Picker("Language", selection: Binding(get: { language }, set: { language = $0; restartNote = nil; AppLanguage.choose($0) })) {
                    Text("Same as the Mac").tag("")
                    Divider()
                    ForEach(AppLanguage.codes, id: \.self) { code in
                        Text(verbatim: AppLanguage.name(code)).tag(code)
                    }
                }
                if language != AppLanguage.launchedWith {
                    HStack {
                        Text("Restart Scout to show it in the new language.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart") { AppLanguage.restart { restartNote = $0 } }
                    }
                }
                if let restartNote {
                    Text(restartNote).font(.caption).foregroundStyle(.orange)
                }
            }

            // The looks moved to Settings › Appearance (the owner, 2026-11-16).
            Section("Feedback") {
                Toggle("Haptic feedback", isOn: $haptics).toggleStyle(.switch)
            }

            Section("Housekeeping") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Welcome tour")
                        Text("Run the short introduction again.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show") { OnboardingWindow.shared.show() }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reset all settings")
                        Text("Puts every option back to how it was on day one. Your notes, clipboard and files stay.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reset…", role: .destructive) { confirmReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onAppear { launchAtLogin = !ScoutRuntime.isScripted && SMAppService.mainApp.status == .enabled }
        .confirmationDialog("Reset all settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { GeneralSettingsPane.resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every option goes back to its default. This can't be undone.")
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        loginNote = nil
        guard !ScoutRuntime.isScripted else { launchAtLogin = on; return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginNote = String(localized: "macOS would not change it: \(error.localizedDescription)")
        }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        if status == .requiresApproval { loginNote = String(localized: "Allow Scout in System Settings → General → Login Items.") }
    }

    @MainActor
    static func resetAll() {
        UserDefaults.standard.removePersistentDomain(forName: ScoutRuntime.bundleID)
        NookStore.shared.restoreDefaults()
        AppAppearance.apply()
    }
}
