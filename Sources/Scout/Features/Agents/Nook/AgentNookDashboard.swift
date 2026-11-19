import SwiftUI

/// The dashboard's Agents panel: Agent TV, a 90s CRT television whose glass shows the agents' rooms in 8-bit pixels (it replaced the
/// AgentNook house, which had replaced the text rows of `AgentsWidgetView`).
/// The room of an agent the automatic opening lit instead of opening (`store.flashed`, the notch was in use) glows.
struct AgentNookDashboardPanel: View {
    @ObservedObject private var store: AgentsStore

    @MainActor init(store: AgentsStore? = nil) { _store = ObservedObject(wrappedValue: store ?? AgentsStore.shared) }

    var body: some View {
        AgentNookPanelView(store: store, highlighted: store.flashed.sorted().first)
    }
}
