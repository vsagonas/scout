import SwiftUI

/// Settings > Windows: only save and resume now (the window snapping and the Magnet-style features are gone, 2026-11-16).
struct WinSettingsPane: View {
    @AppStorage(WinResume.prefKey) private var resume = true

    var body: some View {
        Form {
            Section {
                Toggle("Reopen Scout's windows at launch", isOn: $resume).toggleStyle(.switch)
            } header: {
                Text("Save and resume")
            } footer: {
                SettingsFootnote("Scout's own windows (Ask AI, notes, to-dos, the calculator and the others) reopen where they were, with their size and their text, after a quit, an update or a restart. When a display is no longer there they open on the main one.")
            }
        }
        .formStyle(.grouped)
    }
}
