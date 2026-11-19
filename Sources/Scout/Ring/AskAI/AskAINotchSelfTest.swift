import AppKit
import Foundation

// `scout://ai.selftest.notch` (scripted runs only): walks through the notch's Ask AI with the canned answer —
// opened from the ring, an answer in the open notch, an answer while the notch is shut (wings + card), a tap on
// the card — and writes what it saw to `ai-notch-selftest.txt`. No network, no key, no screenshots.

@MainActor
enum AskAINotchSelfTest {
    static func run(out: URL) {
        guard ScoutRuntime.isScripted else { return }
        Task { @MainActor in
            let store = AIChatStore.shared
            let nav = NotchNavigator.shared
            let center = LiveActivityCenter.shared
            var report = ["preferred=\(AskAIPlace.preferred.rawValue) enabled=\(AskAIPlace.enabledInNotch) available=\(AskAIPlace.notchAvailable)"]

            func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            @MainActor func snap(_ label: String) {
                let panel = NotchManager.shared.active?.panel
                let typing = panel?.firstResponder is NSText
                report.append("\(label): open=\(nav.isOpen) ws=\(nav.workspace.rawValue) height=\(nav.workspaceHeight.map { String(Int($0)) } ?? "nil") "
                              + "key=\(panel?.isKeyWindow ?? false) typing=\(typing) streaming=\(store.isStreaming) messages=\(store.current?.messages.count ?? 0) "
                              + "cards=\(center.cards.map(\.id)) wings=\(center.activities.map(\.id)) panel=\(Panels.isShown("tool.askai"))")
            }

            AskAIPlace.open(newChat: true)
            await wait(0.7); snap("1 opened from the ring")
            store.send(text: "Hello from the notch", imageFiles: [])
            await wait(0.4); snap("2 asked in the open notch")
            await wait(1.2); snap("3 answered in the open notch")
            nav.forceClose()
            await wait(0.4); snap("4 closed")
            store.send(text: "Now with the notch shut", imageFiles: [])
            await wait(0.4); snap("5 streaming, notch shut")
            await wait(1.5); snap("6 answered, notch shut")
            AskAIPlace.openNotch(focus: false)
            await wait(0.5); snap("7 opened from the card")
            nav.forceClose()
            Panels.close("tool.askai")
            await wait(0.3); snap("8 closed again")
            try? report.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        }
    }
}
