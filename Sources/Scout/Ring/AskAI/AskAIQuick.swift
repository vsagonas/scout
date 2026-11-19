import Combine
import SwiftUI

// The dashboard's quick answer.
// A question typed in the dashboard's Ask AI field goes into the one
// "Fast Ask AI" conversation (`AIChatStore.sendQuick`). Since 2026-11-16 the answer stays in the Ask AI panel's own history and the
// dashboard keeps its height: nothing opens the strip below any more.
// `isOnScreen` now says the dashboard's Ask AI panel is showing.

@MainActor
final class AskAIQuick: ObservableObject {
    static let shared = AskAIQuick()

    /// The strip is wanted: a question was just asked, or the panel's answer line was clicked.
    @Published var showing = false
    /// The strip is drawn right now (the dashboard is the view on screen): the card under the closed notch stays away.
    private(set) var isOnScreen = false

    /// The strip's height under the panels.
    static let stripHeight: CGFloat = 210

    private var closing: AnyCancellable?

    init() {
        // A notch that closes folds the strip away once the answer is complete; the conversation itself is kept.
        closing = NotchNavigator.shared.$isOpen.removeDuplicates().dropFirst().sink { [weak self] open in
            guard !open else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !AIChatStore.shared.isBusy else { return }
                    if self.showing { self.showing = false }
                }
            }
        }
    }

    func show() { if !showing { showing = true } }
    func hide() { if showing { showing = false } }
    func toggle() { showing.toggle() }
    func onScreen(_ on: Bool) { isOnScreen = on }
}

/// Gallery only: the conversation the strip shows (its own store, never the real one).
struct AskAIQuickPreview {
    var store: AIChatStore
    var chat: AIChat
}

private struct AskAIQuickPreviewKey: EnvironmentKey {
    static let defaultValue: AskAIQuickPreview? = nil
}

extension EnvironmentValues {
    var askAIQuickPreview: AskAIQuickPreview? {
        get { self[AskAIQuickPreviewKey.self] }
        set { self[AskAIQuickPreviewKey.self] = newValue }
    }
}

/// The strip under the dashboard's panels: the Fast Ask AI conversation, the newest answer at the bottom.
struct AskAIQuickStrip: View {
    @ObservedObject private var store: AIChatStore
    @ObservedObject private var quick = AskAIQuick.shared
    @Environment(\.notchNavigator) private var navigator
    private let previewChat: AIChat?

    @MainActor init(preview: AskAIQuickPreview? = nil) {
        _store = ObservedObject(wrappedValue: preview?.store ?? AIChatStore.shared)
        previewChat = preview?.chat
    }

    private var chat: AIChat? { previewChat ?? store.quickChat }
    private var answering: Bool { previewChat == nil && store.isBusy && store.streamingChatID == store.quickID }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if Retro.is8bit { retroHead } else { minimalHead }
            if Retro.is8bit {
                messages
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Dash90ScreenLines())
                    .crtScreen(cornerRadius: 8, scanlines: 0, tint: nil, vignette: 0.28)
            } else {
                // The minimal look: the conversation as plain text on a flat dark card.
                messages
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .miniCard(radius: 8)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: AskAIQuick.stripHeight)
        .nookPanelFace()
        .onAppear {
            quick.onScreen(true)
            // The island's whole height: the tab row in the menu-bar band (up to 38 pt on a notched Mac), the row of panels,
            // the strip, and the island's own padding (6 above, 10 between, 16 below, a little air).
            navigator.requestHeight(NookMetrics.widgetHeight + AskAIQuick.stripHeight + 74, resizeMax: nil, by: .nook)
        }
        .onDisappear {
            quick.onScreen(false)
            navigator.releaseHeight(by: .nook)
        }
    }

    /// The 90s terminal window: a title bar with the keys.
    private var retroHead: some View {
        RetroTitleBar(pixelLabel("FAST ASK AI"), symbol: "sparkles", tint: Retro.Ink.lime) {
            HStack(spacing: 4) {
                if answering { AgentSpinner(size: 8) }
                if answering {
                    Button("Stop") { store.stop() }.buttonStyle(.retro(compact: true)).nookControl()
                }
                Button("Open in Ask AI") { openInTab() }.buttonStyle(.retro(compact: true)).nookControl()
                    .help("See the whole conversation in the Ask AI tab")
                Button { quick.hide() } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .black)) }
                    .buttonStyle(.retro(compact: true)).nookControl().help("Hide the answer")
            }
        }
    }

    /// The minimal look: the title as quiet text and plain buttons (no bar, no colour).
    private var minimalHead: some View {
        HStack(spacing: 6) {
            Text("Fast Ask AI").font(.system(size: 11, weight: .semibold)).foregroundStyle(Retro.quietInk).lineLimit(1)
                .padding(.leading, 4)
            Spacer(minLength: 4)
            if answering { AgentSpinner(size: 8) }
            if answering {
                Button("Stop") { store.stop() }.buttonStyle(.notchPillCompact).nookControl()
            }
            Button("Open in Ask AI") { openInTab() }.buttonStyle(.notchPillCompact).nookControl()
                .help("See the whole conversation in the Ask AI tab")
            Button { quick.hide() } label: { Image(systemName: "xmark") }
                .buttonStyle(MiniIconButtonStyle(size: 22)).nookControl().help("Hide the answer")
        }
        .frame(height: RetroTitleBar<EmptyView>.barHeight + 2)
    }

    @ViewBuilder private var messages: some View {
        if let chat, !chat.messages.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(chat.messages) { m in
                            AIMessageView(message: m, streaming: store.streamingID == m.id, searching: store.searching && store.streamingID == m.id,
                                          fontSize: 12, onDark: true, capturingScreen: store.capturingID == m.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: chat.messages.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        } else {
            Text(verbatim: AIDisclosure.askAboveAnswerShowsHere(chat?.provider)).font(.system(size: 11)).foregroundStyle(Retro.is8bit ? Dash90.green.opacity(0.8) : NotchInk.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The same conversation in the Ask AI tab (the only way this strip ever leaves the dashboard).
    private func openInTab() {
        if let id = store.quickID { store.select(id) }
        quick.hide()
        navigator.expand(.askAI)
    }
}

/// Faint scanlines for a screen's background: they sit UNDER the text (the glass's own scanlines would go over it).
struct Dash90ScreenLines: View {
    var strength = 0.16

    var body: some View {
        Canvas { ctx, size in
            var rows = Path()
            var y: CGFloat = 0
            while y < size.height {
                let top = ctx.snapped(y)
                rows.addRect(CGRect(x: 0, y: top, width: size.width, height: max(1 / max(1, ctx.environment.displayScale), ctx.snapped(y + 1) - top)))
                y += 3
            }
            ctx.fill(rows, with: .color(Color.white.opacity(strength * 0.5)))
        }
        .allowsHitTesting(false)
    }
}
