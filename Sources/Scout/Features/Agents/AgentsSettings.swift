import AppKit
import SwiftUI

/// Settings › Agents. Both editions lead with "Scout finds Claude Code and Codex sessions by itself" (it reads their
/// transcript files, read only). Under "Optional: answer from the notch": the bridge switch and its status, and per agent a
/// one-click Connect (backs up and edits `~/.claude/settings.json`). That section is in the full edition only:
/// the App Store edition has no hooks and never writes outside its own container.
struct AgentsSettingsPane: View {
    @ObservedObject private var store: AgentsStore
    @AppStorage(AgentsStore.Key.enabled) private var enabled = AgentsStore.Key.enabledByDefault
    @AppStorage(AgentsStore.Key.scan) private var scan = true
    @AppStorage(AgentsAutoOpen.enabledKey) private var autoOpen = true
    @AppStorage(AgentsStore.Key.permissionCards) private var permissionCards = true
    @AppStorage(AgentsStore.Key.attention) private var attention = AgentAttention.peek.rawValue
    @State private var copied: AgentKind?
    /// The paste steps and code show only when asked for
    @State private var showPaste: Set<AgentKind> = []
    /// The last connect / disconnect result and the agent it is about (shown beside that agent's buttons).
    @State private var message: (agent: AgentKind, text: String)?
    @State private var refresh = 0
    #if !APPSTORE
    @State private var confirm: AgentKind?
    #endif
    private let forceManual: Bool?

    /// `manual`: nil = the edition's own way (App Store: paste; full: Connect). The gallery forces both wordings
    /// and may pass its own store.
    @MainActor init(manual: Bool? = nil, store: AgentsStore? = nil) {
        forceManual = manual
        _store = ObservedObject(wrappedValue: store ?? AgentsStore.shared)
    }

    private var manual: Bool { forceManual ?? Edition.isAppStore }

    var body: some View {
        FeaturePane {
            scanSection
            if Edition.answersAgents {   // the App Store edition has no answering, no hooks and no listener (2026-11-18)
                bridgeSection
                agentSection(.claude)
                agentSection(.codex)
            }
            Section("Notch") {
                if Edition.answersAgents {
                    Toggle("Answer permissions and questions from the notch", isOn: $permissionCards)
                    Picker("When an agent needs an answer", selection: $attention) {
                        ForEach(AgentAttention.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .disabled(!permissionCards)
                }
                Toggle("Open the notch when an agent needs you", isOn: $autoOpen)   // a finish or an error only gets the small card below (2026-11-18)
            }
            #if !APPSTORE
            AIUsageSettingsSection()
            #endif
        }
        .onAppear {
            if store === AgentsStore.shared { store.start() }   // gallery previews never listen
            if Edition.answersAgents, store === AgentsStore.shared, !ScoutRuntime.isScripted { AgentFolderAccess.updateIfOutdated(port: store.bridge.advertisedPort, token: store.bridge.token) }
        }
        #if !APPSTORE
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Connect") { if let k = confirm { connect(k) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let k = confirm { Text("Scout will add its hooks to \(AgentInstaller.settingsFile(k, base: Self.base).path) after backing the file up.") }
        }
        #endif
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
        let active = store.sessions.filter { $0.scanned && $0.agent == agent }.count
        switch store.scanStatus.access[agent] ?? .unknown {
        case .ok: return StatusRow(title: Text(verbatim: agent.title), status: Text(active == 0 ? "Watching \(folder): none running" : "Watching \(folder): \(active) running"), level: .good)
        case .missing: return StatusRow(title: Text(verbatim: agent.title), status: Text("Not found on this Mac"), level: .neutral)
        case .denied: return StatusRow(title: Text(verbatim: agent.title), status: Text("Can't read \(folder) yet"), level: .warn)
        case .unknown: return StatusRow(title: Text(verbatim: agent.title), status: Text(ScoutRuntime.isGallery ? "Off in the gallery" : "Starting…"), level: .neutral)
        }
    }

    // MARK: The bridge (optional)

    private var bridgeSection: some View {
        Section {
            Toggle("Listen for AI agents on this Mac", isOn: Binding(get: { enabled }, set: { on in
                enabled = on
                // Switched on and Claude Code is not connected yet: go straight to Connect (one click in the Open panel; the App Store sandbox
                // lets Scout write in ~/.claude only once the person chose that folder).
                if on, manual, !ScoutRuntime.isScripted, AgentFolderAccess.withFile(.claude, { AgentInstaller.state(.claude, file: $0, port: store.bridge.advertisedPort, token: store.bridge.token) }) != .connected {
                    DispatchQueue.main.async { pickFolder(.claude) }
                }
            }))
            bridgeStatus
        } header: {
            Text("Optional: answer from the notch")
        } footer: {
            SettingsNote(manual
                ? "Only needed to Allow, Deny and answer questions from the notch; everything above works without it. Each agent runs a one-line hook that posts to Scout on this Mac (127.0.0.1 only, with a private key). Scout changes your agent's settings only when you click Connect and choose its folder (backed up first, only Scout's own entries), or you paste the hooks yourself. If Scout isn't running the hook does nothing and the agent asks in its terminal as usual."
                : "Only needed to Allow, Deny and answer questions from the notch; everything above works without it. Each hook is a one-line command that posts to Scout on this Mac (127.0.0.1 only, with a private key). If Scout isn't running the hook does nothing and the agent asks in its terminal as usual.")
        }
    }

    @ViewBuilder private var bridgeStatus: some View {
        let info = store.bridgeInfo
        if info.running && info.fallback {
            StatusRow(title: "Local bridge", status: "Listening on 127.0.0.1:\(String(info.port)) (\(String(AgentHooks.defaultPort)) was busy)", level: .warn)   // String(): a number would show as 47,231
        } else if info.running {
            StatusRow(title: "Local bridge", status: "Listening on 127.0.0.1:\(String(info.port))", level: .good)
        } else if enabled, let failure = info.failure {
            StatusRow(title: "Local bridge", status: "Can't listen (\(failure))", level: .bad)
        } else {
            StatusRow(title: "Local bridge", status: enabled ? (ScoutRuntime.isGallery ? "Off in the gallery" : "Starting…") : "Off", level: .neutral)
        }
    }

    // MARK: Per agent

    @ViewBuilder private func agentSection(_ agent: AgentKind) -> some View {
        #if APPSTORE
        pasteSection(agent)
        #else
        if manual { pasteSection(agent) } else { installSection(agent) }
        #endif
    }

    private var portNote: String? {
        let info = store.bridgeInfo
        guard info.running, info.fallback else { return nil }
        return String(localized: "Port \(AgentHooks.defaultPort) was busy, so this block names port \(info.port). If Scout starts on \(AgentHooks.defaultPort) again later, copy it again.")
    }

    /// The App Store way: Connect through an Open panel on ~/.claude (or ~/.codex), or three steps and a block to copy.
    private func pasteSection(_ agent: AgentKind) -> some View {
        let file = agent == .claude ? "~/.claude/settings.json" : "~/.codex/hooks.json"
        let snippet = store.snippet(agent)
        return Section {
            folderConnect(agent)
            Button(showPaste.contains(agent) ? "Hide the paste code" : "Show me the paste code") {
                if showPaste.contains(agent) { showPaste.remove(agent) } else { showPaste.insert(agent) }
            }
            .buttonStyle(.link)
            if showPaste.contains(agent) {
            VStack(alignment: .leading, spacing: 5) {
                step(1, "Click Copy hooks.")
                step(2, "Open \(file) (create it if it isn't there) and paste. If it already has a \"hooks\" section, add these entries inside it.")
                step(3, agent == .claude ? "Start a new Claude Code session. It appears in the notch." : "Start Codex and type /hooks to trust Scout's hooks the first time. Then start a new session.")
            }
            ScrollView(.vertical) {
                Text(snippet).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            HStack {
                Button { copy(snippet, for: agent) } label: { Label("Copy hooks", systemImage: "doc.on.doc") }
                if copied == agent { Text("Copied").font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }
            if let portNote { Text(portNote).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            }
        } header: {
            Text(agent == .claude ? "Connect Claude Code" : "Connect Codex")
        } footer: {
            SettingsNote("Connect asks you to choose the \(AgentFolderAccess.folderName(agent)) folder once; Scout backs up \(AgentFolderAccess.fileName(agent)), adds only its own entries and can take them out again (Disconnect). Every hook is a single curl command to 127.0.0.1; with Scout closed it does nothing.")
        }
        .id("\(agent.rawValue)-paste-\(refresh)")
    }

    /// Connected / not, with Connect…, Update and Disconnect, on the folder the person picked.
    @ViewBuilder private func folderConnect(_ agent: AgentKind) -> some View {
        let state = AgentFolderAccess.withFile(agent) { AgentInstaller.state(agent, file: $0, port: store.bridge.advertisedPort, token: store.bridge.token) }
        switch state {
        case .some(.connected): StatusRow(title: Text(verbatim: agent.title), status: Text("Connected"), level: .good)
        case .some(.outdated): StatusRow(title: Text(verbatim: agent.title), status: Text("Connected, but out of date"), level: .warn)
        default: StatusRow(title: Text(verbatim: agent.title), status: Text("Not connected"), level: .neutral)
        }
        HStack {
            switch state {
            case .some(.connected):
                Button("Disconnect") { disconnectFolder(agent) }
            case .some(.outdated):
                Button("Update") { connectFolder(agent) }
                Button("Disconnect") { disconnectFolder(agent) }
            default:
                Button(agent == .claude ? "Connect Claude Code…" : "Connect Codex…") { pickFolder(agent) }
            }
            if let message, message.agent == agent { Text(verbatim: message.text).font(.caption).foregroundStyle(.secondary) }
            Spacer()
        }
        if agent == .codex, state == .some(.connected) { Text("Codex asks you to review new hooks once: type /hooks in Codex and trust Scout's.").font(.caption).foregroundStyle(.secondary) }
    }

    private func pickFolder(_ agent: AgentKind) {
        guard !ScoutRuntime.isScripted else { return }
        let folder = AgentFolderAccess.folderName(agent), file = AgentFolderAccess.fileName(agent)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = AgentFolderAccess.realHome.appendingPathComponent(folder)
        panel.prompt = String(localized: "Connect")
        panel.message = String(localized: "Choose the \(folder) folder in your home folder. Scout backs up \(file) there and adds its hooks; nothing else changes.")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard AgentFolderAccess.isAgentFolder(url, agent) else {
                message = (agent, String(localized: "That isn't the \(folder) folder in your home folder. Connect again and choose it."))
                refresh += 1
                return
            }
            AgentFolderAccess.remember(url, for: agent)
            connectFolder(agent)
        }
    }

    private func connectFolder(_ agent: AgentKind) {
        do {
            let done = try AgentFolderAccess.withFile(agent) { try AgentInstaller.connect(agent, file: $0, port: store.bridge.advertisedPort, token: store.bridge.token) }
            if done == nil {
                AgentFolderAccess.forget(agent)
                message = (agent, String(localized: "Scout can no longer open that folder. Connect again."))
            } else {
                enabled = true   // the hooks need Scout listening
                message = (agent, String(localized: "Connected. New sessions report to Scout."))
            }
        } catch {
            message = (agent, error.localizedDescription)
        }
        refresh += 1
    }

    private func disconnectFolder(_ agent: AgentKind) {
        do {
            _ = try AgentFolderAccess.withFile(agent) { try AgentInstaller.disconnect(agent, file: $0) }
            message = (agent, String(localized: "Disconnected. Your own hooks are untouched."))
        } catch {
            message = (agent, error.localizedDescription)
        }
        refresh += 1
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(n).").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).frame(width: 16, alignment: .trailing)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copy(_ text: String, for agent: AgentKind) {
        enabled = true   // the pasted hooks need Scout listening
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = agent
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if copied == agent { copied = nil } }
    }

    #if !APPSTORE
    /// The home folder. Scripted runs use a throwaway folder so the real ~/.claude and ~/.codex are never touched.
    static var base: URL {
        ScoutRuntime.isScripted ? AppPaths.folder("agents-sandbox") : FileManager.default.homeDirectoryForCurrentUser
    }

    private var confirmTitle: String { confirm.map { String(localized: "Connect \($0.title)?") } ?? "" }

    /// The full edition's way: one click, backed up first, and Disconnect removes only Scout's entries.
    @ViewBuilder private func installSection(_ agent: AgentKind) -> some View {
        let state = AgentInstaller.state(agent, base: Self.base, port: store.bridge.advertisedPort, token: store.bridge.token)
        Section {
            switch state {
            case .connected: StatusRow(title: Text(verbatim: agent.title), status: Text("Connected"), level: .good)
            case .outdated: StatusRow(title: Text(verbatim: agent.title), status: Text("Connected, but out of date"), level: .warn)
            case .notConnected: StatusRow(title: Text(verbatim: agent.title), status: Text("Not connected"), level: .neutral)
            }
            HStack {
                switch state {
                case .connected: Button("Disconnect") { disconnect(agent) }
                case .outdated:
                    Button("Update") { connect(agent) }
                    Button("Disconnect") { disconnect(agent) }
                case .notConnected: Button("Connect \(agent.title)…") { confirm = agent }
                }
                Button("Copy hooks instead") { copy(store.snippet(agent), for: agent) }
                if copied == agent { Text("Copied").font(.caption).foregroundStyle(.secondary) }
                if let message, message.agent == agent { Text(verbatim: message.text).font(.caption).foregroundStyle(.secondary) }
            }
            if state == .outdated { Text("Scout now listens on port \(store.bridge.advertisedPort) (or its hooks are from an older version). Update rewrites only Scout's entries.").font(.caption).foregroundStyle(.orange) }
            if ScoutRuntime.isScripted { Text("Scripted run: this page works on a test folder, not on your real settings.").font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text(agent.title)
        } footer: {
            SettingsNote(agent == .claude
                ? "Adds Scout's hooks to ~/.claude/settings.json (progress events, permission requests and questions) and leaves your own hooks alone. The file is backed up first."
                : "Adds Scout's hooks to ~/.codex/hooks.json. Codex asks you to review new hooks the first time: type /hooks in Codex and trust Scout's.")
        }
        .id("\(agent.rawValue)-\(refresh)")
    }

    private func connect(_ agent: AgentKind) {
        do {
            try AgentInstaller.connect(agent, base: Self.base, port: store.bridge.advertisedPort, token: store.bridge.token)
            message = (agent, String(localized: "Connected. New sessions report to Scout."))
        } catch {
            message = (agent, error.localizedDescription)
        }
        refresh += 1
    }

    private func disconnect(_ agent: AgentKind) {
        do {
            try AgentInstaller.disconnect(agent, base: Self.base)
            message = (agent, String(localized: "Disconnected. Your own hooks are untouched."))
        } catch {
            message = (agent, error.localizedDescription)
        }
        refresh += 1
    }
    #endif
}

#if !APPSTORE
/// Filled in by C14 (AI Usage): the full edition only (it reads another app's Keychain item).
struct AIUsageSettingsSection: View {
    var body: some View { EmptyView() }
}
#endif
