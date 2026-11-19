#if !APPSTORE
import SwiftUI

/// Settings › Terminal › Agent tabs: the command each kind of tab runs, and what "Resume" runs.
struct AgentTabSettingsSection: View {
    @ObservedObject private var store = AgentTabStore.shared
    @AppStorage(AgentTabKind.claude.commandKey) private var claudeCommand = ""
    @AppStorage(AgentTabKind.claude.resumeKey) private var claudeResume = ""
    @AppStorage(AgentTabKind.codex.commandKey) private var codexCommand = ""
    @AppStorage(AgentTabKind.codex.resumeKey) private var codexResume = ""
    @AppStorage(AgentTabStore.confirmCloseKey) private var confirmClose = true
    @AppStorage(AgentTabStore.restoreKey) private var restore = true

    var body: some View {
        Section {
            commandRow(.claude, command: $claudeCommand, resume: $claudeResume)
            commandRow(.codex, command: $codexCommand, resume: $codexResume)
            Toggle("Ask before closing a tab that is still running", isOn: $confirmClose)
            Toggle("Bring my tabs back when Scout restarts", isOn: $restore)
            HStack {
                Button("Check again") { store.refreshTools(force: true) }
                Button("Forget previous tabs") { store.forgetResumable() }.disabled(store.resumable.isEmpty)
                Button("Forget recent folders") { store.forgetRecentFolders() }.disabled(store.recentFolders.isEmpty)
            }
        } header: {
            Text("Agent tabs")
        } footer: {
            SettingsNote("The + at the left of the notch's top row starts a tab in a folder you pick: your login shell goes to the folder, then runs the command, so your PATH and the agent's own sign-in apply. Each tab is a widget on the dashboard that opens into its terminal, and it keeps running while the notch is closed. After Scout restarts the tabs come back by themselves, each in its folder, and the agents continue with the resume command; with that switched off they wait under + › Resume instead.")
        }
    }

    @ViewBuilder
    private func commandRow(_ kind: AgentTabKind, command: Binding<String>, resume: Binding<String>) -> some View {
        LabeledContent("\(kind.title) command") {
            TextField(kind.defaultCommand, text: command).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
        }
        LabeledContent("\(kind.title) resume command") {
            TextField(kind.defaultResume, text: resume).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
        }
        status(kind)
    }

    private func status(_ kind: AgentTabKind) -> some View {
        let found = kind == .claude ? store.tools.claude : store.tools.codex
        let level: StatusRow.Level = !store.tools.checked ? .neutral : (found == nil ? .warn : .good)
        let text: Text = !store.tools.checked ? Text("Not checked yet") : (found.map { Text(verbatim: $0) } ?? Text("Not found in your login shell's PATH"))
        return StatusRow(title: Text("\(kind.title) installed"), status: text, level: level)
    }
}
#endif
