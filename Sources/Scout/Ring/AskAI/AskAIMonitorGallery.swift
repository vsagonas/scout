import AppKit
import SwiftUI

// Gallery items for Ask AI's Monitor chip (names start with askai-monitor-). Drawn sample screens only:
// nothing here takes a picture of the real screen, reads the Keychain or uses the network.

@MainActor
enum AskAIMonitorGallery {
    private static func notch(_ demo: AIChatStore.Demo, monitor: Bool, height: CGFloat, note: AIMonitorNote? = nil) -> some View {
        AskAIPlace.enableInNotch()   // the scripted-run settings may hold a workspace list saved before Ask AI existed
        let store = AIChatStore(demo: demo)
        store.monitorNote = note
        let preview = AskAINotchPreview(store: store, draft: AskAINotchDraft(), monitor: monitor)
        return NotchScene(size: CGSize(width: 1120, height: height + 140), open: true, workspace: .askAI, openHeight: height)
            .environment(\.askAINotchPreview, preview)
    }

    private static func panel(_ name: String, height: CGFloat, demo: AIChatStore.Demo, monitor: Bool, note: AIMonitorNote? = nil) {
        Gallery.register("askai-monitor-panel-\(name)", size: CGSize(width: 480, height: height + 40)) {
            let store = AIChatStore(demo: demo)
            let _ = store.monitorNote = note
            AskAIView(store: store, monitor: monitor).frame(width: 440, height: height).shadow(color: .black.opacity(0.2), radius: 14, y: 5)
        }
    }

    static func register() {
        Gallery.register("askai-monitor-notch-off", size: CGSize(width: 1120, height: 340)) {
            notch(.empty, monitor: false, height: 200)
        }
        Gallery.register("askai-monitor-notch-on", size: CGSize(width: 1120, height: 340)) {
            notch(.empty, monitor: true, height: 200)
        }
        Gallery.register("askai-monitor-notch-sent", size: CGSize(width: 1120, height: 540)) {
            notch(.monitorSent, monitor: true, height: AskAINotchView.conversationHeight)
        }
        Gallery.register("askai-monitor-notch-capturing", size: CGSize(width: 1120, height: 540)) {
            notch(.monitorCapturing, monitor: true, height: AskAINotchView.conversationHeight)
        }
        Gallery.register("askai-monitor-notch-note", size: CGSize(width: 1120, height: 390)) {
            notch(.empty, monitor: true, height: AskAINotchView.attachingHeight, note: .noAccess)
        }
        panel("off", height: 420, demo: .empty, monitor: false)
        panel("on", height: 420, demo: .empty, monitor: true)
        panel("sent", height: 580, demo: .monitorSent, monitor: true)
        panel("capturing", height: 420, demo: .monitorCapturing, monitor: true)
        panel("note", height: 420, demo: .empty, monitor: true, note: .noAccess)
        // The chip close up, off and on, on the panel's glass and on the notch's black.
        Gallery.register("askai-monitor-chip", size: CGSize(width: 420, height: 150)) {
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    AIMonitorChip(isOn: false) {}
                    AIMonitorChip(isOn: true) {}
                }
                .padding(14).background(GlassBackground(cornerRadius: 14))
                HStack(spacing: 14) {
                    AIMonitorChip(isOn: false) {}
                    AIMonitorChip(isOn: true) {}
                }
                .padding(14).background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black)).notchContent()
            }
        }
        FeatureGallery.settings("askai-monitor-settings", height: 1190) {
            AskAISettingsPane(previewKeyTail: "k3Qa", previewMonitor: true, previewNoAccess: true)
        }
    }
}
