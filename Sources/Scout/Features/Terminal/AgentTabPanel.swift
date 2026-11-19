#if !APPSTORE
import SwiftUI

/// The dashboard panel of one agent tab (full edition): the agent's glyph, the folder it runs in and a status line.
/// A click (or the pointer resting on it) expands the island into the tab's terminal; the small x closes the tab.
struct AgentTabPanelView: View {
    let tabID: String
    @ObservedObject private var store: AgentTabStore

    @MainActor init(tabID: String, store: AgentTabStore? = nil) {
        self.tabID = tabID
        _store = ObservedObject(wrappedValue: store ?? AgentTabStore.shared)
    }

    var body: some View {
        if let tab = store.tab(id: tabID) {
            AgentTabPanelBody(tab: tab, store: store)
        } else {
            Color.clear
        }
    }
}

private struct AgentTabPanelBody: View {
    @ObservedObject var tab: AgentTab
    let store: AgentTabStore
    @State private var hover = false

    private var dotColor: Color? {
        if tab.hasEnded { return (tab.exitCode ?? 0) == 0 ? Color.gray : Color.red }
        return tab.waiting ? Theme.accent : nil
    }

    /// One short line: what it needs, how it ended, or what it is doing (the terminal's own title when the agent sets one).
    private var status: (text: String, color: Color) {
        if tab.hasEnded {
            let code = tab.exitCode ?? 0
            return (code == 0 ? String(localized: "Ended") : String(localized: "Ended (code \(code))"), NotchInk.tertiary)
        }
        if tab.waiting { return (String(localized: "Waiting for you"), Theme.accent) }
        if !tab.title.isEmpty { return (tab.title, NotchInk.secondary) }
        return (tab.kind.isAgent ? String(localized: "Working") : String(localized: "Ready"), NotchInk.secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: tab.kind.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                Text(tab.kind.title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(NotchInk.secondary).lineLimit(1)
                Spacer(minLength: 2)
                if let dotColor { AgentTabDot(color: dotColor) }
                if hover {
                    Button { store.requestClose(tab) } label: { Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)) }
                        .buttonStyle(NotchIconButtonStyle(size: 18)).nookControl().help("Close this tab")
                }
            }
            Spacer(minLength: 4)
            Text(tab.folderName).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(AgentTabFolder.abbreviated(tab.folder))
                .font(.system(size: 9.5)).foregroundStyle(NotchInk.tertiary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                if tab.isRunning, !tab.waiting { AgentSpinner(size: 8) }
                Text(status.text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(status.color).lineLimit(1)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .notchContent()
        .onHover { hover = $0 }
        .help(tab.helpText)
        .contextMenu { Button("Close Tab") { store.requestClose(tab) } }
    }
}
#endif
