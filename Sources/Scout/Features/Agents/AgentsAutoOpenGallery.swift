import SwiftUI

// Gallery scenes `auto-*` for the notch opening by itself over the Agents view: an agent that needs you (the banner and the answer
// controls), a long task that finished, a task that stopped with an error, and the lit row on the dashboard when the notch was in
// use. Synthetic data only. The scenes seed the shared store INSIDE their body: the Agents view clears its banner when it goes
// away, and every picture is drawn twice (light, dark).

@MainActor
enum AgentsAutoOpenGallery {
    /// The request the infra agent (the 6th synthetic one) is held on.
    static var held: AgentPending {
        AgentPending(sessionID: "syn-6", kind: .permission, tool: "Bash", summary: "terraform apply -auto-approve", detail: "terraform apply -auto-approve",
                     questions: [], rawToolInput: nil, agent: .codex)
    }

    /// A question held for the infra agent (the answer controls with options).
    static var heldQuestion: AgentPending {
        AgentPending(sessionID: "syn-6", kind: .question, tool: "AskUserQuestion", summary: "Which region?", detail: "",
                     questions: [AgentQuestion(question: "Which region should the bucket move to?", header: "Region",
                                               options: [.init(label: "eu-west-1", detail: ""), .init(label: "us-east-1", detail: "")], multiSelect: false)],
                     rawToolInput: nil, agent: .codex)
    }

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
    private static func opened(_ name: String, height: CGFloat, openHeight: CGFloat, sessions: @escaping () -> [AgentSession], pending: [AgentPending] = [],
                               announce: @escaping ([AgentSession]) -> AgentAnnouncement, width: CGFloat? = nil) {
        // The same scene twice: `auto-*` (this feature's pictures) and `tv-auto-*` (the TV round's pictures).
        for prefix in ["auto-", "tv-auto-"] {
            Gallery.register(prefix + name, size: CGSize(width: 1120, height: height)) {
                let list = sessions()
                let note = announce(list)
                let store = AgentsStore.shared
                let _ = store.loadSessions(list, pending: pending, selecting: note.sessionID)
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
        // The den's height (and what its window adds for a banner and a request), the notch's header and a little air below.
        let den = AgentDenLayout.islandHeight(extra: AgentDenLayout.extraHeight(pending: [held], banner: true))
        let denQuestion = AgentDenLayout.islandHeight(extra: AgentDenLayout.extraHeight(pending: [heldQuestion], banner: true))
        let denPlain = AgentDenLayout.islandHeight(extra: AgentDenLayout.extraHeight(pending: [], banner: true))
        opened("needsyou", height: den + 60, openHeight: den, sessions: needs, pending: [held],
               announce: { AgentAnnouncement(sessionID: $0[0].id, kind: .needsYou, at: Date()) })
        opened("needsyou-question", height: denQuestion + 60, openHeight: denQuestion, sessions: needs, pending: [heldQuestion],
               announce: { AgentAnnouncement(sessionID: $0[0].id, kind: .needsYou, at: Date()) })
        opened("needsyou-narrow", height: den + 60, openHeight: den, sessions: needs, pending: [held],
               announce: { AgentAnnouncement(sessionID: $0[0].id, kind: .needsYou, at: Date()) }, width: 680)
        opened("finished", height: denPlain + 60, openHeight: denPlain, sessions: { [finished(minutes: 12)] + AgentSession.synthetic(2) },
               announce: { AgentAnnouncement(sessionID: $0[0].id, kind: .finished(minutes: 12), at: Date()) })
        opened("error", height: denPlain + 60, openHeight: denPlain, sessions: { [failed()] + AgentSession.synthetic(2) },
               announce: { AgentAnnouncement(sessionID: $0[0].id, kind: .error, at: Date()) })

        // The notch was in use (open on the dashboard, the pointer on it): it did not switch, the agent's row is lit.
        func lit(_ name: String, agents: Int, asking: Bool, lit: String, width: CGFloat? = nil) {
            Gallery.register(name, size: CGSize(width: 1120, height: 290)) {
                let _ = DashGallery.seed(agents: agents, asking: asking, playing: false)
                let _ = AgentsStore.shared.previewFlashed([lit])
                NotchScene(size: CGSize(width: 1120, height: 290), open: true, live: NookLive(playing: false, openTodos: 0, agents: agents), widthCap: width, showNotchRect: true)
            }
        }
        lit("auto-litrow", agents: 3, asking: false, lit: "syn-2")
        lit("auto-litrow-asking", agents: 6, asking: true, lit: "syn-6")
        lit("auto-litrow-narrow", agents: 3, asking: false, lit: "syn-2", width: 640)
    }
}
