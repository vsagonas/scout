#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - Shared bits

/// The attention dot on a tab's panel: amber while the agent waits for you, grey (red after an error) once it ended.
struct AgentTabDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
    }
}

/// What the "+" menu offers, as plain data (the real menu and the gallery's picture of it both read it).
struct AgentTabMenuModel {
    struct Folder: Identifiable, Equatable {
        let path: String
        var id: String { path }
        var name: String { AgentTabFolder.name(path) }
        var parent: String { path == AgentTabFolder.home ? "" : AgentTabFolder.parent(path) }
    }

    struct Entry: Identifiable {
        let kind: AgentTabKind
        let folders: [Folder]
        var id: String { kind.rawValue }
    }

    var entries: [Entry]
    var resumable: [AgentTabRecord]

    /// Recent folders (newest first), then the home folder when it is not among them.
    @MainActor
    static func make(_ store: AgentTabStore) -> AgentTabMenuModel {
        var folders = store.folderChoices.map(Folder.init)
        if !folders.contains(where: { $0.path == AgentTabFolder.home }) { folders.append(Folder(path: AgentTabFolder.home)) }
        return AgentTabMenuModel(entries: store.availableKinds.map { Entry(kind: $0, folders: folders) }, resumable: store.resumable)
    }

    static func resumeTitle(_ record: AgentTabRecord) -> String { "\(record.kind.title) · \(AgentTabFolder.name(record.folder))" }
}

/// The agent-tab entries of the dashboard's "+" menu: New Claude Code tab / New Codex tab / New terminal, each asking for a
/// folder, then the previous run's tabs as "Resume".
struct AgentTabMenuItems: View {
    @ObservedObject var store: AgentTabStore

    var body: some View {
        let model = AgentTabMenuModel.make(store)
        ForEach(model.entries) { entry in
            Menu {
                ForEach(entry.folders) { folder in
                    Button(folder.parent.isEmpty ? folder.name : "\(folder.name)  —  \(folder.parent)") {
                        store.create(kind: entry.kind, folder: folder.path)
                    }
                }
                Divider()
                Button("Choose Folder…") { store.chooseFolder(for: entry.kind) }
            } label: {
                Label(entry.kind.menuTitle, systemImage: entry.kind.symbol)
            }
        }
        if !model.resumable.isEmpty {
            Divider()
            Section("Resume") {
                ForEach(model.resumable) { record in
                    Button { store.resume(record) } label: {
                        Label(AgentTabMenuModel.resumeTitle(record), systemImage: record.kind.symbol)
                    }
                }
                Button("Forget Previous Tabs") { store.forgetResumable() }
            }
        }
    }
}

// MARK: - The open tab

/// What the open notch shows for the agent tab a dashboard panel expanded into.
struct AgentTabContentView: View {
    let tabID: String
    @ObservedObject var navigator: NotchNavigator
    @ObservedObject private var store: AgentTabStore

    @MainActor init(tabID: String, navigator: NotchNavigator, store: AgentTabStore? = nil) {
        self.tabID = tabID
        self.navigator = navigator
        _store = ObservedObject(wrappedValue: store ?? AgentTabStore.shared)
    }

    var body: some View {
        if let tab = store.tab(id: tabID) {
            AgentTabBody(tab: tab, store: store, navigator: navigator)
        } else {
            NotchEmptyState(symbol: "terminal", message: "This tab is closed").notchContent()
        }
    }
}

struct AgentTabBody: View {
    @ObservedObject var tab: AgentTab
    let store: AgentTabStore
    @ObservedObject var navigator: NotchNavigator

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                if tab.view != nil { AgentTerminalHost(tab: tab, store: store) } else { AgentTabMock(tab: tab) }
                if tab.hasEnded && !tab.confirmingClose { endedBar }
                if tab.confirmingClose { confirmCard }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 10).padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .notchContent()
        .onAppear { tab.markViewed() }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Image(systemName: tab.kind.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
            Text(tab.kind.title).font(.system(size: 11, weight: .semibold))
            Text(tab.folderName).font(.system(size: 11, weight: .medium)).foregroundStyle(NotchInk.secondary).lineLimit(1)
            Text(AgentTabFolder.abbreviated(tab.folder))
                .font(.system(size: 10)).foregroundStyle(NotchInk.tertiary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if tab.hasEnded {
                Text("Ended").font(.system(size: 10, weight: .medium)).foregroundStyle(NotchInk.tertiary)
            } else if tab.waiting {
                Text("Waiting for you").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.accent)
            }
            Button { SettingsWindowController.shared.show(.terminal) } label: { Image(systemName: "gearshape") }
                .buttonStyle(NotchIconButtonStyle(size: 20)).help("Agent tab settings")
            Button { store.requestClose(tab) } label: { Image(systemName: "xmark") }
                .buttonStyle(NotchIconButtonStyle(size: 20)).help("Close this tab (⌘W)")
        }
        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 6)
    }

    private var endedBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Text(endedText).font(.system(size: 12, weight: .medium))
                if tab.kind.isAgent {
                    Button("Resume") { store.restart(tab, resume: true) }.buttonStyle(NotchPillButtonStyle(prominent: true, compact: true))
                    Button("Start again") { store.restart(tab, resume: false) }.buttonStyle(NotchPillButtonStyle(compact: true))
                } else {
                    Button("Restart") { store.restart(tab, resume: false) }.buttonStyle(NotchPillButtonStyle(prominent: true, compact: true))
                }
                Button("Close tab") { store.close(tab) }.buttonStyle(NotchPillButtonStyle(compact: true))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(Color.black.opacity(0.88)).overlay(Capsule().stroke(NotchInk.hairline)))
            .padding(.bottom, 10)
        }
    }

    private var endedText: String {
        let code = tab.exitCode ?? 0
        if tab.kind.isAgent { return code == 0 ? String(localized: "\(tab.kind.title) ended.") : String(localized: "\(tab.kind.title) ended (code \(code)).") }
        return code == 0 ? String(localized: "The shell ended.") : String(localized: "The shell ended (code \(code)).")
    }

    private var confirmCard: some View {
        ZStack {
            Color.black.opacity(0.62)
            VStack(spacing: 10) {
                Text("Close this tab?").font(.system(size: 13, weight: .semibold))
                Text("\(tab.kind.title) is still running in \(tab.folderName). Closing the tab ends it.")
                    .font(.system(size: 11)).foregroundStyle(NotchInk.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Keep open") { tab.confirmingClose = false }
                        .buttonStyle(NotchPillButtonStyle()).keyboardShortcut(.cancelAction)
                    Button("Close tab") { store.close(tab) }
                        .buttonStyle(AgentTabDangerStyle()).keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .frame(maxWidth: 330)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.13))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(NotchInk.hairline)))
        }
    }
}

struct AgentTabDangerStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Color(red: 0.86, green: 0.22, blue: 0.20)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// Hosts the tab's terminal view (the same view each time the tab is shown, like the Terminal workspace's host).
struct AgentTerminalHost: NSViewRepresentable {
    let tab: AgentTab
    let store: AgentTabStore

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        guard let terminal = tab.view else { return container }
        Self.attach(terminal, to: container)
        if store.consumeFocusRequest(tab.id) {
            let tab = tab
            let store = store
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { store.focus(tab) }
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func attach(_ terminal: NSView, to container: NSView) {
        terminal.removeFromSuperview()
        terminal.frame = container.bounds
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        nsView.subviews.forEach { $0.removeFromSuperview() }
    }
}

/// Fake terminal output for the gallery and for tabs without a process (scripted runs). Never a real agent.
struct AgentTabMock: View {
    let tab: AgentTab

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch tab.kind {
            case .claude, .codex: agentLines
            case .shell: shellLines
            }
            Spacer(minLength: 0)
            if tab.kind.isAgent { promptBox }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
    }

    private var dim: Color { Color(white: 0.55) }
    private var text: Color { Color(white: 0.90) }

    @ViewBuilder
    private var agentLines: some View {
        HStack(spacing: 6) {
            Text(verbatim: ">").foregroundStyle(Theme.accent)
            Text(verbatim: "add a font size setting to the agent tabs").foregroundStyle(.white)
        }
        Text(verbatim: " ").font(.system(size: 6))
        mark("I'll look at how the Terminal settings are stored first.")
        mark("Read(Features/Terminal/TerminalSettings.swift)")
        sub("Read 50 lines")
        mark("Update(Features/Terminal/AgentTab.swift)")
        sub("Reads the shared font size when a tab starts")
        sub("Updated 1 file, 6 lines added")
        mark("Build complete. The setting applies to every open tab.")
        Text(verbatim: " ").font(.system(size: 6))
        HStack(spacing: 6) {
            Text(verbatim: "●").foregroundStyle(Theme.accent)
            Text(verbatim: "Reading the folder structure…").foregroundStyle(dim)
        }
    }

    @ViewBuilder
    private var shellLines: some View {
        line("~ % ", "ls")
        Text(verbatim: "Desktop   Documents   Downloads   Projects").foregroundStyle(text)
        line("~ % ", "cd Projects/site && git status -sb")
        Text(verbatim: "## main...origin/main").foregroundStyle(Color.green.opacity(0.85))
        HStack(spacing: 0) {
            Text(verbatim: "site % ").foregroundStyle(Theme.accent)
            Rectangle().fill(Theme.accent).frame(width: 7, height: 14)
        }
    }

    private var promptBox: some View {
        HStack(spacing: 6) {
            Text(verbatim: ">").foregroundStyle(text)
            Rectangle().fill(Theme.accent).frame(width: 7, height: 14)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color(white: 0.35)))
    }

    private func mark(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(verbatim: "●").foregroundStyle(Color.green.opacity(0.85))
            Text(s).foregroundStyle(text)
        }
    }

    private func sub(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(verbatim: "  ⎿").foregroundStyle(dim)
            Text(s).foregroundStyle(dim)
        }
    }

    private func line(_ prompt: String, _ command: String) -> some View {
        HStack(spacing: 0) {
            Text(prompt).foregroundStyle(Theme.accent)
            Text(command).foregroundStyle(.white)
        }
    }
}
#endif
