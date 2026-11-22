import SwiftUI

// Gallery scenes `auto-*` for the notch opening by itself over the Agents view: an agent that needs you (the banner), and the lit row on the
// dashboard when the notch was in use. Synthetic data only. The scenes seed the shared store INSIDE their body: the Agents view clears
// its banner when it goes away, and every picture is drawn twice (light, dark).

@MainActor
enum AgentsAutoOpenGallery {
    /// The open notch on the Agents view, as the automatic opening leaves it: that agent in detail, the banner on top.
    private static func opened(_ name: String, height: CGFloat, openHeight: CGFloat, sessions: @escaping () -> [AgentSession],
                               announce: @escaping ([AgentSession]) -> AgentAnnouncement, width: CGFloat? = nil) {
        // The same scene twice: `auto-*` (this feature's pictures) and `tv-auto-*` (the Agent TV pictures).
        for prefix in ["auto-", "tv-auto-"] {
            Gallery.register(prefix + name, size: CGSize(width: 1120, height: height)) {
                let list = sessions()
                let note = announce(list)
                let store = AgentsStore.shared
                let _ = store.loadSessions(list, selecting: note.sessionID)
                let _ = store.previewDoneToday(5)
                let _ = store.announcement = note
                let _ = store.focusID = note.sessionID
                NotchScene(size: CGSize(width: 1120, height: height), open: true, workspace: .agents, widthCap: width, openHeight: openHeight)
                    .environment(\.agentDenTime, AgentTVGallery.day)
            }
        }
    }

    static func register() {
        let infra = AgentSession.synthetic(6)[5]
        let needs: () -> [AgentSession] = { [infra] + [AgentSession.synthetic(6)[0], AgentSession.synthetic(6)[1]] }
        // The den's height (and what its window adds for a banner), the notch's header and a little air below.
        let den = AgentDenLayout.islandHeight(extra: AgentDenLayout.extraHeight(banner: true))
        opened("needsyou", height: den + 60, openHeight: den, sessions: needs,
               announce: { AgentAnnouncement(sessionID: $0[0].id, kind: .needsYou, at: Date()) })
        opened("needsyou-narrow", height: den + 60, openHeight: den, sessions: needs,
               announce: { AgentAnnouncement(sessionID: $0[0].id, kind: .needsYou, at: Date()) }, width: 680)

        // The notch was in use (open on the dashboard, the pointer on it): it did not switch, the agent's row is lit.
        func lit(_ name: String, agents: Int, lit: String, width: CGFloat? = nil) {
            Gallery.register(name, size: CGSize(width: 1120, height: 290)) {
                let _ = DashGallery.seed(agents: agents, playing: false)
                let _ = AgentsStore.shared.previewFlashed([lit])
                NotchScene(size: CGSize(width: 1120, height: 290), open: true, live: NookLive(playing: false, openTodos: 0, agents: agents), widthCap: width, showNotchRect: true)
            }
        }
        lit("auto-litrow", agents: 3, lit: "syn-2")
        lit("auto-litrow-asking", agents: 6, lit: "syn-6")
        lit("auto-litrow-narrow", agents: 3, lit: "syn-2", width: 640)
    }
}
