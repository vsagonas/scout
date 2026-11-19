import SwiftUI

// Store/: the Mac App Store screenshots, rendered through the gallery as "store-*" items
// (1440 x 900 points, 2x = 2880 x 1800). Nine frames: the first six lead with the agentic features (the Nook's Agents
// dashboard, the Agents grid, the wings, answering from the notch, Ask AI and its Monitor), then the calendar, the clipboard
// and the tray. (The ring's frame went with the ring, 2026-11-16.) The real views on sample data (the sessions are made up, see StoreAgentSamples.swift).
// Classic (black) notch: glass cannot be captured offscreen. Render with:  scripts/store-screenshots.sh
// Heights are never chosen here: StoreNotch opens each view at the height the app itself gives it (180 pt for the dashboard,
// NotchPrefs.minimumOpenHeight(for:), the height the view asks for), see StoreCanvas.swift.

@MainActor
enum StoreShots {
    /// Notch widgets that set the width of the open notch for the workspaces (the width follows the Nook row).
    private static let wideLayout: [WidgetKind] = [.media, .clipboard, .pulse, .todo]
    /// The row the older frames (calendar, tray) were laid out with: the agents dashboard has no room in it.
    private static let plainLayout: [WidgetKind] = [.media, .pulse, .timer, .todo]

    static func register() {
        let size = StoreScreen.size
        let centerX = size.width / 2

        // 1. The agentic Nook: the dashboard as it comes (the Agents TV, Ask AI, the Mac's pulse and today).
        Gallery.register("store-01-agents", size: size, backdrop: .window) {
            let _ = StoreAgents.loadShared(StoreAgents.live)
            let _ = { TodayWidgetView.sceneMoment = Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: Date()) }()
            StoreScene(tint: .sky, zoom: 1.25, menus: 2, extras: 1) { width in
                StoreNotch(screenWidth: width, open: true,
                           layout: WidgetKind.defaultLayout, live: NookLive(playing: false, openTodos: 0, agents: StoreAgents.live.count))
            } caption: {
                StoreCaption(headline: "Every agent, at a glance", subline: "Claude Code and Codex sessions show up live in your notch.")
                    .frame(width: 1240)
                    .position(x: centerX, y: 590)
            }
        }

        // 2. The Agents workspace: one live tile per session, found by Scout itself.
        Gallery.register("store-02-found", size: size, backdrop: .window) {
            let _ = StoreAgents.loadShared(StoreAgents.grid)
            StoreScene(tint: .mint, zoom: 1.25, menus: 2, extras: 1) { width in
                StoreNotch(screenWidth: width, open: true, workspace: .agents, layout: plainLayout)
            } caption: {
                StoreCaption(headline: "Found automatically", subline: "Claude Code and Codex sessions show up by themselves. Nothing to connect.")
                    .frame(width: 1300)
                    .position(x: centerX, y: 650)
            }
        }

        // 3. The closed notch: a face per agent beside the camera, the question on the right (the list is the "details" hover setting).
        Gallery.register("store-03-wings", size: size, backdrop: .window) {
            let store = StoreAgents.store("store-agents-wings", names: StoreAgents.live)
            StoreScene(tint: .peach, zoom: 1.9, menus: 3, extras: 1) { width in
                StoreNotch(screenWidth: width, open: false, panelHeight: 300, detail: true) { center in
                    center.show(StoreAgents.wings(store))
                }
            } caption: {
                StoreCaption(headline: "Who needs you, right by the camera", subline: "Each agent's face sits beside the notch, and the one that needs you shows its question.")
                    .frame(width: 1340)
                    .position(x: centerX, y: 540)
            }
        }

        // 5. Ask AI under the closed notch: the answer drops down while it streams.
        Gallery.register("store-05-askai", size: size, backdrop: .window) {
            let chat = AIChatStore(demo: .streaming)
            StoreScene(tint: .ocean, zoom: 1.7, menus: 3, extras: 1) { width in
                StoreMockWindow(width: 520, height: 270).offset(x: width / 2 - 260, y: 78)
                StoreNotch(screenWidth: width, open: false, panelHeight: 300) { center in
                    center.show(AskAIDropDown.activity(question: chat.current?.messages.first?.text ?? ""))
                    center.present(NotchCard(id: AskAIDropDown.cardID, kind: .ai, duration: 600) {
                        AskAIDropCard(store: chat, chatID: chat.currentID)
                    })
                }
            } caption: {
                StoreCaption(headline: "Ask AI, right in the notch", subline: "Ask Claude or GPT and the answer drops down from the notch while it streams.")
                    .frame(width: 1340)
                    .position(x: centerX, y: 700)
            }
        }

        // 6. Monitor on: a question that went out with a picture of the screen.
        Gallery.register("store-06-monitor", size: size, backdrop: .window) {
            let chat = AIChatStore(demo: .monitorSent)
            let preview = AskAINotchPreview(store: chat, draft: AskAINotchDraft(), monitor: true)
            StoreScene(tint: .sand, zoom: 1.35, menus: 2, extras: 1) { width in
                StoreNotch(screenWidth: width, open: true, workspace: .askAI, openWidth: 900, layout: plainLayout,
                           request: AskAINotchContent.requestedHeight(hasKey: true))
                    .environment(\.askAINotchPreview, preview)
            } caption: {
                StoreCaption(headline: "Ask about your screen", subline: "Switch Screen on and every question comes with a picture of your screen.")
                    .frame(width: 1300)
                    .position(x: centerX, y: 750)
            }
        }

        // 8. The Calendar workspace: month, agenda, Join, and the to-dos beside them.
        Gallery.register("store-08-calendar", size: size, backdrop: .window) {
            StoreScene(tint: .lilac, zoom: 1.25, menus: 2, extras: 1) { width in
                StoreNotch(screenWidth: width, open: true, workspace: .calendar, layout: plainLayout)
            } caption: {
                StoreCaption(headline: "Your day at a glance", subline: "A month, today's agenda with a Join button for every call, and your to-dos.")
                    .position(x: centerX, y: 650)
            }
        }

        // 9. The Clipboard workspace.
        Gallery.register("store-09-clipboard", size: size, backdrop: .window) {
            StoreScene(tint: .sand, zoom: 1.2, menus: 2, extras: 1) { width in
                StoreNotch(screenWidth: width, open: true, workspace: .clipboard, openWidth: 954, layout: wideLayout)
            } caption: {
                StoreCaption(headline: "Everything you copied, within reach", subline: "Search, filter and pin your clipboard history without leaving what you're doing.")
                    .frame(width: 1300)
                    .position(x: centerX, y: 620)
            }
        }

        // 10. The Tray: drop targets on the open notch while files are dragged in.
        Gallery.register("store-10-tray", size: size, backdrop: .window) {
            StoreScene(tint: .rose, zoom: 1.25, menus: 2, extras: 1) { width in
                StoreNotch(screenWidth: width, open: true, layout: plainLayout, drop: true)
            } caption: {
                ZStack {
                    StoreDragChip().scaleEffect(1.25).position(x: centerX, y: 410)
                    StoreCaption(headline: "Drop it on the notch", subline: "Keep files in the Tray, AirDrop them, or convert them on the spot.")
                        .position(x: centerX, y: 680)
                }
                .frame(width: size.width, height: size.height)
            }
        }
    }
}

/// Three files being dragged toward the notch (drawn here, nothing real is dragged).
struct StoreDragChip: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let tilt = Double(i - 1) * 7
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(scheme == .dark ? Color(white: 0.22) : Color.white)
                    .frame(width: 66, height: 84)
                    .overlay(
                        Image(systemName: ["photo", "doc.richtext", "film"][i])
                            .font(.system(size: 26, weight: .regular))
                            .foregroundStyle(Theme.amber)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.black.opacity(0.10), lineWidth: 1))
                    .rotationEffect(.degrees(tilt))
                    .offset(x: CGFloat(i - 1) * 16, y: CGFloat(abs(i - 1)) * 4)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
            }
            Text("3")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.red))
                .offset(x: 46, y: -42)
        }
        .frame(width: 180, height: 120)
    }
}
