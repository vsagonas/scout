import SwiftUI

/// Agents workspace: the big vintage place. Every agent lives in ONE 90s den (`AgentDenView`); a click on an agent opens its window
/// beside the den without leaving it. This view owns which agent is open, takes `store.focusID` (the automatic opening and a click on the
/// dashboard's TV), tells the store which agent it shows (`shownDetailID`) and asks the notch for the den's height.
struct AgentsWorkspaceView: View {
    @ObservedObject private var store: AgentsStore
    /// nil = just the den; a session id = that agent's window is open beside it.
    @State private var detailID: String?
    /// The view's own width (the minimal look lays its cards out by it).
    @State private var width: CGFloat = 900
    /// Tests: told where the den's parts are.
    private var onFrames: (([String: CGRect]) -> Void)?

    func reportingFrames(_ report: @escaping ([String: CGRect]) -> Void) -> AgentsWorkspaceView { var copy = self; copy.onFrames = report; return copy }

    @MainActor init(store: AgentsStore? = nil, detail: String? = nil) {
        let shown = store ?? AgentsStore.shared
        _store = ObservedObject(wrappedValue: shown)
        _detailID = State(initialValue: detail ?? shown.announcement?.sessionID)   // an automatic opening's banner belongs to that agent's window
    }

    private var inDetail: Bool { detailID != nil && store.sessions.contains { $0.id == detailID } }
    /// The session whose window is open (nil: only the den). `AgentsAutoOpen` reads it from the store to see who is shown.
    private var shownDetail: String? { inDetail ? detailID : nil }
    /// The banner of an automatic opening, while that agent's window is the one open.
    private var banner: AgentAnnouncement? {
        guard inDetail, let a = store.announcement, a.sessionID == detailID else { return nil }
        return a
    }

    /// The island height (header included) this workspace needs: the den, and a little more while the open window shows a banner.
    private var neededHeight: CGFloat {
        let extra = inDetail ? AgentDenLayout.extraHeight(banner: banner != nil) : 0
        // The minimal look: the list and one agent's history, the den's height; pulling the notch down gives more.
        if !Retro.is8bit { return (store.sessions.isEmpty ? 200 : AgentDenLayout.baseHeight + extra) + AgentDenLayout.chrome }
        guard inDetail else { return AgentDenLayout.islandHeight() }
        return AgentDenLayout.islandHeight(extra: AgentDenLayout.drawerHeight + extra)   // the window lies under the den
    }

    private func syncHeight() {
        guard store === AgentsStore.shared else { return }
        NotchNavigator.shared.requestHeight(neededHeight, resizeMax: resizeMax, by: .agents)
    }

    /// Where pulling the notch down shows more: a window's steps, and the minimal look's list and history. (The den itself always shows everything.)
    private var resizeMax: CGFloat? { inDetail || (!Retro.is8bit && !store.sessions.isEmpty) ? .greatestFiniteMagnitude : nil }

    var body: some View {
        AgentDenView(store: store, detailID: shownDetail, banner: banner, empty: emptyNote, onSelect: { id in
            detailID = id
            if let id { store.selectedID = id }
        }, onFrames: onFrames)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GeometryReader { g in Color.clear.preference(key: AgentsWidthKey.self, value: g.size.width) })
        .onPreferenceChange(AgentsWidthKey.self) { if abs($0 - width) > 1 { width = $0 } }
        .notchContent()
        .onAppear { takeFocus(); syncHeight(); store.shownDetailID = shownDetail }
        .onChange(of: neededHeight) { syncHeight() }
        // Coming back to this tab quickly (CPU, Ask AI, CPU) keeps this view alive through its exit, so it never "appears" again: it asks
        // for its height every time the notch switches to it.
        // The navigator tells the change before it happens, so the request goes a moment later.
        .onReceive(NotchNavigator.shared.$workspace) { kind in
            if NotchPrefs.resolve(kind) == .agents { DispatchQueue.main.async { syncHeight() } }
        }
        .onChange(of: resizeMax) { syncHeight() }
        .onChange(of: store.focusID) { takeFocus() }
        .onChange(of: shownDetail) { store.shownDetailID = shownDetail }
        .onDisappear {
            if store.shownDetailID == shownDetail { store.shownDetailID = nil }
            if store === AgentsStore.shared { NotchNavigator.shared.releaseHeight(by: .agents) }
        }
    }

    private func takeFocus() {
        guard let id = store.focusID else { return }
        store.focusID = nil
        if store.sessions.contains(where: { $0.id == id }) { detailID = id; store.selectedID = id }
    }

    /// The empty den's line and key: the folders cannot be read yet (the App Store edition asks once), or nothing is running.
    private var emptyNote: AgentDenEmptyNote { Self.emptyNote(store: store) }

    /// The note the empty den shows for a store (the gallery draws the same one).
    static func emptyNote(store: AgentsStore) -> AgentDenEmptyNote {
        let denied = store.scanStatus.access.values.contains(.denied)
        if denied {
            return AgentDenEmptyNote(line: String(localized: "Scout can't see your agents' folders yet. Allow it once and every Claude Code and Codex session moves in by itself."),
                                     keyTitle: String(localized: "Allow Scout to see your agents"), asksAction: true) { AgentAccessButton.run(store: store) }
        }
        return AgentDenEmptyNote(line: AgentNookEmptyRoom.line, keyTitle: String(localized: "Agents settings"), opensSettings: true) { SettingsWindowController.shared.show(.agents) }
    }
}

private struct AgentsWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 900
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// "Allow Scout to see your agents": the App Store edition's one-time fallback when the folders can't be read.
@MainActor
enum AgentAccessButton {
    /// Asks for whichever agent folder can't be read (Claude Code first), then looks again.
    static func run(store: AgentsStore) {
        let denied = AgentKind.allCases.filter { store.scanStatus.access[$0] == .denied }
        guard let agent = denied.first else { return }
        AgentAccess.requestAccess(for: agent) { _ in
            store.refreshScanSources()
            if denied.count > 1, let next = denied.dropFirst().first { AgentAccess.requestAccess(for: next) { _ in store.refreshScanSources() } }
        }
    }
}
