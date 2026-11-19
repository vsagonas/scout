import SwiftUI

// Gallery scenes `notch-cards-*`: the REAL notch (NotchRootView, 16-inch notch, the camera housing outlined in red) with a card hanging
// from its island: an LED board, faces and the download-finished card, the battery card, several cards stacked, no activity
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
    private static func restFaces(_ picks: [Int]) -> LiveActivity {
        let store = AgentsStore()
        let all = AgentSession.synthetic(6)
        store.loadSessions(picks.map { all[$0] })
        return LiveActivity(id: "agents.main", kind: .agent, expiresAfter: nil, onTap: nil, leading: { AgentWingLeft(store: store, frozenAt: 0.6) }, trailing: { EmptyView() })
    }

    /// Both wings: faces left, the latest message right.
    private static func newsFaces(_ picks: [Int]) -> LiveActivity {
        let store = AgentsStore()
        let all = AgentSession.synthetic(6)
        store.loadSessions(picks.map { all[$0] })
        return AgentsStore.wings(store: store, expiresAfter: nil)
    }

    /// The card the app drops when a download finishes (`DownloadsWatcher.finishedCard`), held long enough for the picture.
    private static func downloadCard() -> NotchCard {
        NotchCard(id: "download.done", kind: .download, duration: 600) { DownloadFinishedCard(name: "Quarterly report.pdf", size: 48_000_000) }
    }

    private static func batteryCard() -> NotchCard {
        NotchCard(id: "battery.low", kind: .battery, duration: 600) {
            DemoCardContent(symbol: "battery.25percent", title: "Battery is low", subtitle: "19 % left. Time to plug in.")
        }
    }

    static func register() {
        func closed(_ name: String, height: CGFloat = 150, activities: [LiveActivity], cards: [NotchCard]) {
            Gallery.register(name, size: CGSize(width: 520, height: height), backdrop: .screenTop) {
                NotchScene(size: CGSize(width: 520, height: height), showNotchRect: true, activities: activities, extraCards: cards)
            }
        }
        closed("notch-cards-led-download", activities: [led("WELCOME DEV \(LEDFont.heart)")], cards: [downloadCard()])
        closed("notch-cards-faces1-download", activities: [restFaces([0])], cards: [downloadCard()])
        closed("notch-cards-faces2-battery", activities: [restFaces([0, 1])], cards: [batteryCard()])
        closed("notch-cards-faces4-battery", activities: [restFaces([0, 1, 3, 5])], cards: [batteryCard()])
        closed("notch-cards-news3-download", activities: [newsFaces([0, 1, 3])], cards: [downloadCard()])
        closed("notch-cards-news6-download", activities: [newsFaces([0, 1, 2, 3, 4, 5])], cards: [downloadCard()])
        closed("notch-cards-bare-battery", activities: [], cards: [batteryCard()])
        closed("notch-cards-stacked", height: 240, activities: [restFaces([0, 1])], cards: [downloadCard(), batteryCard()])
        // The same on the bare wallpaper (no black strip), to judge the join: the island's flares, its square bottom and the card as one shape.
        func shape(_ name: String, activities: [LiveActivity], cards: [NotchCard]) {
            Gallery.register(name, size: CGSize(width: 520, height: 150), backdrop: .wallpaper) {
                NotchScene(size: CGSize(width: 520, height: 150), activities: activities, extraCards: cards)
            }
        }
        shape("notch-cards-shape-led-download", activities: [led("WELCOME DEV \(LEDFont.heart)")], cards: [downloadCard()])
        shape("notch-cards-shape-faces2-battery", activities: [restFaces([0, 1])], cards: [batteryCard()])
        shape("notch-cards-shape-bare-battery", activities: [], cards: [batteryCard()])
        // The open notch with a card: the card hangs centred under the open island.
        Gallery.register("notch-cards-open-battery", size: CGSize(width: 1120, height: 330), backdrop: .screenTop) {
            NotchScene(size: CGSize(width: 1120, height: 330), open: true, workspace: .agents, openHeight: 200, showNotchRect: true, extraCards: [batteryCard()])
        }
    }
}
