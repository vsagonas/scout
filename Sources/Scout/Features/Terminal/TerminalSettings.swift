#if !APPSTORE
import SwiftUI

struct TerminalSettingsPane: View {
    @ObservedObject private var session = TerminalSession.shared
    @AppStorage(TerminalSession.Key.shell) private var shell = ""
    @AppStorage(TerminalSession.Key.startFolder) private var folder = ""
    @AppStorage(TerminalSession.Key.optionAsMeta) private var optionAsMeta = true
    @AppStorage(TerminalSession.Key.fontSize) private var fontSize = 12
    @AppStorage(TerminalSession.Key.keepRunning) private var keepRunning = true

    var body: some View {
        FeaturePane {
            Section {
                Picker("Shell", selection: $shell) {
                    Text("Your login shell (\((TerminalSession.loginShell as NSString).lastPathComponent))").tag("")
                    ForEach(TerminalSession.availableShells.filter { $0 != TerminalSession.loginShell }, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Start folder") {
                    HStack {
                        TextField("Home folder", text: $folder).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Button("Restart the terminal to use these") { session.restart() }
            } header: {
                Text("Shell")
            } footer: {
                SettingsNote("The terminal starts your shell as a login shell, so your usual PATH and profile apply.")
            }

            Section("Keys and looks") {
                Toggle("Use the Option key as Meta (Esc prefix)", isOn: $optionAsMeta)
                Stepper("Font size: \(fontSize) pt", value: $fontSize, in: 9...20)
                Toggle("Keep the shell running while the notch is closed", isOn: $keepRunning)
            }
            .onChange(of: optionAsMeta) { session.applyAppearance(); AgentTabStore.shared.applyAppearance() }
            .onChange(of: fontSize) { session.applyAppearance(); AgentTabStore.shared.applyAppearance() }

            AgentTabSettingsSection()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}
#endif
