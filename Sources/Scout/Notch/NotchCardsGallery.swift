import SwiftUI

// Gallery scenes `notch-cards-*`: the REAL notch (NotchRootView, 16-inch notch, the camera housing outlined in red) with a card hanging
// from its island: an LED board, faces and a notification card, the battery card, a permission request, several cards stacked, no activity
// at all, and the open notch with a card. In every picture the card must read as the island growing down: one black shape, its middle
// under the island's middle, as wide as the island's body. Made-up agents and text only.

@MainActor
enum NotchCardsGallery {
    private static let claude = AgentKind.claude.tint

    private static func led(_ text: String) -> LiveActivity {
        var playback = LEDPlayback(schedule: LEDSchedule(text: text, mode: .step), start: Date(), tint: claude, frozenAt: nil)
        playback.frozenAt = 1.2
        return LEDAnnouncements.activity(playback, symbol: AgentKind.claude.symbol, expiresAfter: 600)
    }

    /// Faces on the left only, as the notch sits most of the time (the right wing has stepped aside).
    private static func restFaces(_ picks: [Int], name: String) -> LiveActivity {
        let store = AgentsStore(directory: AppPaths.folder(name))
        let all = AgentSession.synthetic(6)
        store.loadSessions(picks.map { all[$0] })
        return LiveActivity(id: "agents.main", kind: .agent, expiresAfter: nil, onTap: nil, leading: { AgentWingLeft(store: store, frozenAt: 0.6) }, trailing: { EmptyView() })
    }

    /// Both wings: faces left, the latest message right.
    private static func newsFaces(_ picks: [Int], name: String) -> LiveActivity {
        let store = AgentsStore(directory: AppPaths.folder(name))
        let all = AgentSession.synthetic(6)
        store.loadSessions(picks.map { all[$0] })
        return AgentsStore.wings(store: store, expiresAfter: nil)
    }

    private static func doneCard() -> NotchCard {
        NotchCard(id: "agent.done.demo", kind: .agent, duration: 600) { AgentDoneCard(session: AgentSession.samples()[2]) }
    }

    private static func batteryCard() -> NotchCard {
        NotchCard(id: "battery.low", kind: .battery, duration: 600) {
            DemoCardContent(symbol: "battery.25percent", title: "Battery is low", subtitle: "19 % left. Time to plug in.")
        }
    }

    private static func permissionCard() -> NotchCard {
        let store = AgentsStore(directory: AppPaths.folder("notch-cards-pending"))
        let request = AgentPending(sessionID: "syn-1", kind: .permission, tool: "Bash", summary: "npm run lint && npm run build", detail: "npm run lint && npm run build",
                                   questions: [], rawToolInput: nil, agent: .claude)
        return NotchCard(id: "agent.pending.demo", kind: .agent, duration: 600) { PendingView(request: request, store: store, compact: true) }
    }

    static func register() {
        func closed(_ name: String, height: CGFloat = 150, activities: [LiveActivity], cards: [NotchCard]) {
            Gallery.register(name, size: CGSize(width: 520, height: height), backdrop: .screenTop) {
                NotchScene(size: CGSize(width: 520, height: height), showNotchRect: true, activities: activities, extraCards: cards)
            }
        }
        closed("notch-cards-led-done", activities: [led("WELCOME DEV \(LEDFont.heart)")], cards: [doneCard()])
        closed("notch-cards-faces1-done", activities: [restFaces([0], name: "notch-cards-f1")], cards: [doneCard()])
        closed("notch-cards-faces2-battery", activities: [restFaces([0, 1], name: "notch-cards-f2")], cards: [batteryCard()])
        closed("notch-cards-faces4-battery", activities: [restFaces([0, 1, 3, 5], name: "notch-cards-f4")], cards: [batteryCard()])
        closed("notch-cards-news3-done", activities: [newsFaces([0, 1, 3], name: "notch-cards-n3")], cards: [doneCard()])
        closed("notch-cards-news6-done", activities: [newsFaces([0, 1, 2, 3, 4, 5], name: "notch-cards-n6")], cards: [doneCard()])
        closed("notch-cards-faces2-permission", height: 270, activities: [restFaces([0, 1], name: "notch-cards-fp")], cards: [permissionCard()])
        closed("notch-cards-bare-battery", activities: [], cards: [batteryCard()])
        closed("notch-cards-stacked", height: 240, activities: [restFaces([0, 1], name: "notch-cards-fs")], cards: [doneCard(), batteryCard()])
        // The same on the bare wallpaper (no black strip), to judge the join: the island's flares, its square bottom and the card as one shape.
        func shape(_ name: String, activities: [LiveActivity], cards: [NotchCard]) {
            Gallery.register(name, size: CGSize(width: 520, height: 150), backdrop: .wallpaper) {
                NotchScene(size: CGSize(width: 520, height: 150), activities: activities, extraCards: cards)
            }
        }
        shape("notch-cards-shape-led-done", activities: [led("WELCOME DEV \(LEDFont.heart)")], cards: [doneCard()])
        shape("notch-cards-shape-faces2-battery", activities: [restFaces([0, 1], name: "notch-cards-sf2")], cards: [batteryCard()])
        shape("notch-cards-shape-bare-battery", activities: [], cards: [batteryCard()])
        // The open notch with a card: the card hangs centred under the open island.
        Gallery.register("notch-cards-open-battery", size: CGSize(width: 1120, height: 330), backdrop: .screenTop) {
            NotchScene(size: CGSize(width: 1120, height: 330), open: true, workspace: .agents, openHeight: 200, showNotchRect: true, extraCards: [batteryCard()])
        }
    }
}
