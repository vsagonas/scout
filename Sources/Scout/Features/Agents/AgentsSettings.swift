import AppKit
import SwiftUI

/// Settings › Agents: "Scout finds Claude Code and Codex sessions by itself" (it reads their transcript files, read only), and the one
/// switch for the notch opening by itself when an agent needs you.
struct AgentsSettingsPane: View {
    @ObservedObject private var store: AgentsStore
    @AppStorage(AgentsStore.Key.scan) private var scan = true
    @AppStorage(AgentsAutoOpen.enabledKey) private var autoOpen = true

    /// The gallery may pass its own store.
    @MainActor init(store: AgentsStore? = nil) {
        _store = ObservedObject(wrappedValue: store ?? AgentsStore.shared)
    }

    var body: some View {
        FeaturePane {
            scanSection
            Section("Notch") {
                Toggle("Open the notch when an agent needs you", isOn: $autoOpen)   // a finish or an error never opens the notch; the right wing's two lines say it
            }
            #if !APPSTORE
            AIUsageSettingsSection()
            #endif
        }
        .onAppear {
            if store === AgentsStore.shared { store.start() }   // gallery previews never read
        }
    }

    // MARK: Found by itself

    private var scanSection: some View {
        Section {
            Toggle("Find Claude Code and Codex sessions automatically", isOn: $scan)
            if scan {
                scanRow(.claude)
                scanRow(.codex)
                if store.scanStatus.access.values.contains(.denied) {
                    HStack {
                        Button("Allow Scout to see your agents") { AgentAccessButton.run(store: store) }
                        Spacer()
                    }
                }
            }
        } header: {
            Text("Scout finds Claude Code and Codex sessions by itself")
        } footer: {
            SettingsNote(verbatim: String(localized: "Nothing to connect: every session running on this Mac shows up in the notch with its progress. Scout reads the progress files Claude Code (~/.claude/projects) and Codex (~/.codex/sessions) keep while they work. It only reads them, keeps nothing from them beyond what you see in the notch while Scout runs, and nothing leaves your Mac."))   // verbatim: Text would read the two of the paths as strikethrough
        }
    }

    private func scanRow(_ agent: AgentKind) -> some View {
        let folder = agent == .claude ? "~/.claude/projects" : "~/.codex/sessions"
        let active = store.sessions.filter { $0.agent == agent }.count
        switch store.scanStatus.access[agent] ?? .unknown {
        case .ok: return StatusRow(title: Text(verbatim: agent.title), status: Text(active == 0 ? "Watching \(folder): none running" : "Watching \(folder): \(active) running"), level: .good)
        case .missing: return StatusRow(title: Text(verbatim: agent.title), status: Text("Not found on this Mac"), level: .neutral)
        case .denied: return StatusRow(title: Text(verbatim: agent.title), status: Text("Can't read \(folder) yet"), level: .warn)
        case .unknown: return StatusRow(title: Text(verbatim: agent.title), status: Text(ScoutRuntime.isGallery ? "Off in the gallery" : "Starting…"), level: .neutral)
        }
    }
}

#if !APPSTORE
/// Filled in by C14 (AI Usage): the full edition only (it reads another app's Keychain item).
struct AIUsageSettingsSection: View {
    var body: some View { EmptyView() }
}
#endif
