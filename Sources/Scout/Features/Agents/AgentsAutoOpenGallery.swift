import SwiftUI

// Gallery scenes `auto-*` for the notch opening by itself over the Agents view: an agent that needs you (the banner), a long task that finished, a task that stopped with an error, and the lit row on the dashboard when the notch was in
// use. Synthetic data only. The scenes seed the shared store INSIDE their body: the Agents view clears its banner when it goes
// away, and every picture is drawn twice (light, dark).

@MainActor
enum AgentsAutoOpenGallery {
    /// A long task that finished ("docs", 12 min, waits for the next prompt).
    static func finished(minutes: Int) -> AgentSession {
        var s = AgentSession.synthetic(5)[4]
        s.state = .waiting
        s.note = "Finished: waiting for your next message"
        s.turnStartedAt = Date().addingTimeInterval(-Double(minutes) * 60 - 30)
        s.finishedAt = Date().addingTimeInterval(-30)
        s.lastMessage = "The changelog is rewritten and the links are checked."
        return s
    }

    /// A task that stopped on a failed step ("scout").
    static func failed() -> AgentSession {
        var s = AgentSession.synthetic(4)[3]
        s.state = .waiting
        s.note = "Finished: waiting for your next message"
        s.turnStartedAt = Date().addingTimeInterval(-9 * 60)
        s.finishedAt = Date().addingTimeInterval(-20)
        s.lastMessage = "The build stopped on a type error in the router."
        s.steps = [AgentStep(id: "f1", tool: "Read", summary: "router.rs", at: Date().addingTimeInterval(-300), done: true),
                   AgentStep(id: "f2", tool: "Bash", summary: "swift build", at: Date().addingTimeInterval(-60), done: true, failed: true)]
        return s
    }

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
        opened("finished", height: den + 60, openHeight: den, sessions: { [finished(minutes: 12)] + AgentSession.synthetic(2) },
               announce: { AgentAnnouncement(sessionID: $0[0].id, kind: .finished(minutes: 12), at: Date()) })
        opened("error", height: den + 60, openHeight: den, sessions: { [failed()] + AgentSession.synthetic(2) },
               announce: { AgentAnnouncement(sessionID: $0[0].id, kind: .error, at: Date()) })

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
