import SwiftUI

// Gallery `tv-denfill-*`: the den inside the REAL open notch (NotchRootView, its header, its rounded corners), at the island height the app
// really gives it, so what is left under the room shows. The `tv-den-*` pictures draw the den alone in a frame of exactly its own height and
// cannot show it. The size (SCOUT_SCALE) and the colours (SCOUT_PRESET) come from the environment like every `look-*` picture.
// Synthetic agents only.

@MainActor
enum AgentDenFillGallery {
    /// The panel the scene draws in: tall enough for the island at the biggest size (1.45), so the island's own height is never cut by the picture.
    private static let closedPanel: CGFloat = 720
    private static let windowPanel: CGFloat = 1160

    private static func scene(_ name: String, sessions: Int, detail: String? = nil, banner: Bool = false, width: CGFloat = 1120, widthCap: CGFloat? = nil,
                              denied: Bool = false) {
        let height = detail == nil ? closedPanel : windowPanel
        Gallery.register("tv-denfill-\(name)", size: CGSize(width: width, height: height)) {
            let list = AgentNookSamples.sessions(sessions)
            let store = AgentsStore.shared
            let _ = store.loadSessions(list, selecting: detail)
            let _ = store.previewDoneToday(sessions == 0 ? 0 : 5)
            let _ = store.previewScan(denied ? AgentScanner.Status(access: [.claude: .denied, .codex: .denied]) : AgentScanner.Status())
            let _ = store.announcement = banner ? detail.map { AgentAnnouncement(sessionID: $0, kind: .needsYou, at: Date()) } : nil
            let _ = store.focusID = detail
            // The workspace asks the real notch's navigator for its height; a picture's navigator is its own, so the same number is given here.
            NotchScene(size: CGSize(width: width, height: height), open: true, workspace: .agents, widthCap: widthCap,
                       openHeight: detail == nil ? nil : AgentDenLayout.islandHeight(extra: AgentDenLayout.drawerHeight + AgentDenLayout.extraHeight(banner: banner)))
                .environment(\.agentDenTime, AgentTVGallery.day)
        }
    }

    static func register() {
        for n in [0, 1, 3, 6, 9] { scene("\(n)", sessions: n) }
        for n in [0, 3, 9] { scene("narrow-\(n)", sessions: n, width: 760, widthCap: 640) }
        scene("empty-denied", sessions: 0, denied: true)
        // An agent's window under the den: the den keeps its place, the window takes what is left down to the island's bottom.
        scene("window-6", sessions: 6, detail: "nk-1")
        scene("window-9", sessions: 9, detail: "nk-2")
        scene("banner-6", sessions: 6, detail: "nk-3", banner: true)
    }
}
