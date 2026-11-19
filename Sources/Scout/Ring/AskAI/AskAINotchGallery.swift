import AppKit
import SwiftUI

// Gallery items for Ask AI in the notch (names start with askai-notch-). Sample chats and a frozen stream only:
// nothing here reads the Keychain or touches the network.

@MainActor
enum AskAINotchGallery {
    /// The open notch on the Ask AI workspace with its own state. `height` is what the island is asked to grow to.
    private static func openScene(_ demo: AIChatStore.Demo, height: CGFloat, width: CGFloat? = nil, noKey: Bool = false,
                                  draft: AskAINotchDraft? = nil) -> some View {
        AskAIPlace.enableInNotch()   // the scripted-run settings may hold a workspace list saved before Ask AI existed
        let preview = AskAINotchPreview(store: AIChatStore(demo: demo), draft: draft ?? AskAINotchDraft(), forceNoKey: noKey)
        return NotchScene(size: CGSize(width: 1120, height: height + 140), open: true, workspace: .askAI, widthCap: width, openHeight: height)
            .environment(\.askAINotchPreview, preview)
    }

    /// A small picture to attach (drawn here, saved in the scripted-run folder).
    private static func samplePicture() -> String? {
        let image = NSImage(size: NSSize(width: 160, height: 110), flipped: false) { rect in
            NSGradient(colors: [NSColor(calibratedRed: 0.95, green: 0.62, blue: 0.2, alpha: 1), NSColor(calibratedRed: 0.35, green: 0.2, blue: 0.55, alpha: 1)])?
                .draw(in: rect, angle: 35)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: CGRect(x: 100, y: 58, width: 30, height: 30)).fill()
            return true
        }
        return AIImages.store(image)
    }

    private static func dropScene(_ demo: AIChatStore.Demo, done: Bool = false) -> some View {
        let store = AIChatStore(demo: demo)
        let size = CGSize(width: 520, height: done ? 300 : 280)
        let scene = NotchScene(size: size)
        if !done { scene.center.show(AskAIDropDown.activity(question: store.current?.messages.first?.text ?? "")) }
        scene.center.present(NotchCard(id: AskAIDropDown.cardID, kind: .ai, duration: 600) {
            AskAIDropCard(store: store, chatID: store.currentID)
        })
        return scene
    }

    static func register() {
        Gallery.register("askai-notch-empty", size: CGSize(width: 1120, height: 340)) {
            openScene(.empty, height: 200)
        }
        Gallery.register("askai-notch-conversation", size: CGSize(width: 1120, height: 540)) {
            openScene(.conversation, height: AskAINotchView.conversationHeight)
        }
        Gallery.register("askai-notch-streaming", size: CGSize(width: 1120, height: 540)) {
            openScene(.streaming, height: AskAINotchView.conversationHeight)
        }
        Gallery.register("askai-notch-thinking", size: CGSize(width: 1120, height: 540)) {
            openScene(.thinking, height: AskAINotchView.conversationHeight)
        }
        Gallery.register("askai-notch-error", size: CGSize(width: 1120, height: 540)) {
            openScene(.error, height: AskAINotchView.conversationHeight)
        }
        Gallery.register("askai-notch-narrow", size: CGSize(width: 800, height: 540)) {
            openScene(.conversation, height: AskAINotchView.conversationHeight, width: 680)
        }
        Gallery.register("askai-notch-nokey", size: CGSize(width: 1120, height: 340)) {
            openScene(.empty, height: 200, noKey: true)
        }
        Gallery.register("askai-notch-attach", size: CGSize(width: 1120, height: 390)) {
            let draft = AskAINotchDraft()
            draft.text = "What is in this picture?"
            draft.attachments = samplePicture().map { [$0] } ?? []
            return openScene(.empty, height: AskAINotchView.attachingHeight, draft: draft)
        }
        Gallery.register("askai-notch-dropdown", size: CGSize(width: 520, height: 280)) {
            dropScene(.streaming)
        }
        Gallery.register("askai-notch-dropdown-thinking", size: CGSize(width: 520, height: 280)) {
            dropScene(.thinking)
        }
        Gallery.register("askai-notch-dropdown-done", size: CGSize(width: 520, height: 300)) {
            dropScene(.conversation, done: true)
        }
        Gallery.register("askai-notch-dropdown-error", size: CGSize(width: 520, height: 300)) {
            dropScene(.error, done: true)
        }
        FeatureGallery.settings("askai-notch-settings", height: 1130) { AskAISettingsPane(previewKeyTail: "k3Qa") }
    }
}
