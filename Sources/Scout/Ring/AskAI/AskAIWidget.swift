import SwiftUI

/// The Ask AI panel on the dashboard: one input line (with the Monitor chip, off by default: one click sends the screen with
/// the question) and the Fast Ask AI history above it. A question asked here is answered IN the panel and goes into the one "Fast Ask AI"
/// conversation; the dashboard keeps its height and never jumps to the Ask AI tab.
/// A click on the panel's title still opens the whole Ask AI. It
/// shares the draft and the key with the full view.
/// The 90s look (R3): a terminal. A title bar, a prompt line on a small CRT ("> " in phosphor green, a block cursor that never
/// blinks, the real text field), the Monitor chip as a small key with a tiny screen on it (lit when on), send as a key.
struct AskAIWidgetView: View {
    @ObservedObject private var store: AIChatStore
    @ObservedObject private var draft: AskAINotchDraft
    private let quick = AskAIQuick.shared
    @Environment(\.notchNavigator) private var navigator
    @AppStorage(AIMonitor.key) private var monitorOn = false
    @State private var windowBox = WindowBox()
    @FocusState private var fieldFocused: Bool

    @MainActor init(store: AIChatStore? = nil, draft: AskAINotchDraft? = nil) {
        _store = ObservedObject(wrappedValue: store ?? AIChatStore.shared)
        _draft = ObservedObject(wrappedValue: draft ?? AskAINotchDraft.shared)
    }

    /// The quiet line while the conversation is empty.
    static let emptyTitle = String(localized: "No questions yet")

    /// True while a quick answer streams and nothing of it has come yet: the history shows "Thinking…".
    private var isThinking: Bool {
        let answer = store.quickChat?.messages.last(where: { $0.role == .assistant })
        if let answer, !answer.isError, !answer.text.isEmpty { return false }
        return store.isBusy && store.streamingChatID == store.quickID && store.quickID != nil
    }

    /// The history of the Fast Ask AI conversation on top, the question line at the bottom
    var body: some View {
        // No title: the history starts at the top.
        VStack(alignment: .leading, spacing: 6) {
            history
            Group { if store.hasKey { input } else { noKey } }.reportDashRow("control")
        }
        .padding(DashGrid.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .notchContent()
        // The real panel tells the closed notch's answer card that the owner is looking at the answers here.
        .background(WindowReader(box: windowBox))
        // A tap anywhere in the panel (the ">", the history, the empty room) puts the cursor in its field; it never opens the Ask AI tab
        .contentShape(Rectangle())
        .onTapGesture { focusField() }
        .onAppear { if store === AIChatStore.shared { quick.onScreen(true) } }
        .onDisappear { if store === AIChatStore.shared { quick.onScreen(false) } }
    }

    /// The last questions and answers of Fast Ask AI, whole, newest at the bottom (it opens there); it scrolls inside the panel.
    @ViewBuilder private var history: some View {
        let messages = Array((store.quickChat?.messages ?? []).suffix(8))
        if messages.isEmpty {
            // An empty list says so where the list starts, like every panel (`DashEmpty`: "No agents running", "Nothing left today").
            Group {
                if store.hasKey { DashEmpty(symbol: "sparkles", title: .verbatim(Self.emptyTitle), detail: .verbatim(AIDisclosure.goesToAnswersStayHere(store.quickChat?.provider))) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                            historyRow(message).id(index)
                        }
                        if isThinking {
                            Text("Thinking…").font(.system(size: 11)).foregroundStyle(NotchInk.tertiary).id(messages.count)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { proxy.scrollTo(messages.count - 1, anchor: .bottom) }
                .onChange(of: messages.count) { proxy.scrollTo(messages.count - 1, anchor: .bottom) }
                .onChange(of: messages.last?.text) { proxy.scrollTo(messages.count - 1, anchor: .bottom) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { focusField() }   // a click on the answers stays here and puts the cursor in the field
        }
    }

    @ViewBuilder private func historyRow(_ message: AIChatMessage) -> some View {
        if message.role == .user {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: "›").font(.system(size: 11, weight: .bold)).foregroundStyle(NotchInk.tertiary)
                Text(message.text).font(DashGrid.infoFont(.semibold)).foregroundStyle(NotchInk.secondary).lineLimit(2)
            }
        } else {
            if message.isError {
                Text("That one did not go through").font(DashGrid.rowText).foregroundStyle(NotchInk.primary.opacity(0.88))
            } else {
                AIMarkdownView(text: message.text, font: 11).foregroundStyle(NotchInk.primary.opacity(0.88))
            }
        }
    }

    @ViewBuilder private var input: some View {
        if Retro.is8bit { retroInput } else { minimalInput }
    }

    /// The minimal look: a plain rounded text field with a normal placeholder, a Screen toggle (a monitor symbol, lit in the accent when on)
    /// and a plain send button. Same actions, labels and help as the 90s line.
    private var minimalInput: some View {
        HStack(spacing: 6) {
            Button { AIMonitor.toggle(); focusField() } label: { Image(systemName: "display") }
                .buttonStyle(MiniIconButtonStyle(size: DashGrid.controlHeight, lit: monitorOn))
                .help(AIDisclosure.screenHelp(store.quickChat?.provider))
                .accessibilityLabel("Screen")
                .accessibilityValue(monitorOn ? "On" : "Off")
            TextField("", text: $draft.text, prompt: Text(monitorOn ? "Ask about your screen" : "Ask anything").foregroundStyle(NotchInk.tertiary))
                .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(NotchInk.primary)
                .focused($fieldFocused)
                .onSubmit(send)
                .miniField(height: DashGrid.controlHeight)
            Button(action: send) { Image(systemName: "arrow.up") }
                .buttonStyle(MiniIconButtonStyle(size: DashGrid.controlHeight, lit: draft.canSend))
                .disabled(!draft.canSend || store.isBusy).help("Ask")
                .nookControl()
        }
        .nookControl()
    }

    private var retroInput: some View {
        HStack(spacing: 4) {
            Button { AIMonitor.toggle(); focusField() } label: { Dash90ScreenGlyph(on: monitorOn) }
                .buttonStyle(.dash90Key(tint: monitorOn ? Retro.Ink.phosphorAmber : Retro.Ink.plasticMid, width: DashGrid.controlHeight, height: DashGrid.controlHeight, lit: monitorOn))
                .help(AIDisclosure.screenHelp(store.quickChat?.provider))
                .accessibilityLabel("Screen")
                .accessibilityValue(monitorOn ? "On" : "Off")
            HStack(spacing: 3) {
                Text(verbatim: ">").font(.system(size: 12.5, weight: .bold, design: .monospaced)).foregroundStyle(Dash90.green)
                if draft.text.isEmpty {
                    Rectangle().fill(Dash90.green).frame(width: 6, height: 12)   // the block cursor: still, it never blinks
                }
                TextField("", text: $draft.text, prompt: Text(monitorOn ? "Ask about your screen" : "Ask anything").foregroundStyle(Dash90.green.opacity(0.45)))
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Dash90.green)
                    .focused($fieldFocused)
                    .onSubmit(send)
            }
            .padding(.horizontal, 7)
            .frame(height: DashGrid.controlHeight)
            .askField()
            Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 10, weight: .black)) }
                .buttonStyle(.dash90Key(tint: draft.canSend ? Retro.Ink.lime : Retro.Ink.plasticMid, width: DashGrid.controlHeight, height: DashGrid.controlHeight, lit: draft.canSend))
                .disabled(!draft.canSend || store.isBusy).help("Ask")
                .nookControl()
        }
        .nookControl()
    }

    @ViewBuilder private var noKey: some View {
        if Retro.is8bit { retroNoKey } else {
            HStack(spacing: 6) {
                Image(systemName: "key").font(.system(size: 10.5)).foregroundStyle(Retro.quietInk)
                Text("Add a key to start").font(.system(size: 11.5, weight: .medium)).foregroundStyle(NotchInk.secondary)
            }
            .padding(.horizontal, 9).frame(height: DashGrid.controlHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .miniCard(radius: 7)
        }
    }

    private var retroNoKey: some View {
        HStack(spacing: 6) {
            Image(systemName: "key").font(.system(size: 10.5)).foregroundStyle(Dash90.amber)
            Text("Add a key to start").font(.system(size: 11.5, weight: .medium)).foregroundStyle(NotchInk.secondary)
        }
        .padding(.horizontal, 8).frame(height: DashGrid.controlHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lookWell()
        .retroBevel(.sunken, cornerRadius: 4, depth: 1.2, face: Dash90.lcdFace)
    }

    /// The cursor into the field: the notch panel takes the keyboard first (it may need a moment to allow it).
    private func focusField(attempt: Int = 0) {
        guard store.hasKey else { return }
        if let panel = windowBox.window as? NotchPanel, panel.allowsKey {
            if !panel.isKeyWindow { panel.makeKey() }
            fieldFocused = true
        } else if attempt < 4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { focusField(attempt: attempt + 1) }
        }
    }

    /// The question goes into Fast Ask AI and its answer streams into the history above. The notch stays on the dashboard, at its height.
    private func send() {
        guard store.hasKey, draft.canSend, !store.isBusy else { return }
        store.sendQuick(text: draft.text, imageFiles: draft.attachments)
        draft.clear()
    }
}

/// A tiny screen on a key for Monitor: dark glass at rest, lit amber with a scanline when Monitor is on. Our own drawing.
struct Dash90ScreenGlyph: View {
    var on: Bool

    var body: some View {
        Canvas { ctx, s in
            let glass = CGRect(x: 1.5, y: 1, width: s.width - 3, height: s.height - 5)
            let body = Path(roundedRect: glass, cornerRadius: 2)
            ctx.fill(body, with: .color(on ? Retro.Ink.phosphorAmber : Color(red: 0.05, green: 0.06, blue: 0.06)))
            ctx.stroke(body, with: .color(on ? Retro.shade(Retro.Ink.phosphorAmber, -0.45) : Look.ink(0.55)), lineWidth: 1.2)
            if on {
                var rows = Path()
                var y = glass.minY + 2.5
                while y < glass.maxY - 1 { rows.addRect(CGRect(x: glass.minX + 1.5, y: y, width: glass.width - 3, height: 0.8)); y += 2.4 }
                ctx.fill(rows, with: .color(Color.black.opacity(0.28)))
                ctx.fill(Path(CGRect(x: glass.minX + 2, y: glass.minY + 1.5, width: 4, height: 1.2)), with: .color(Color.white.opacity(0.7)))
            }
            // The stand.
            ctx.fill(Path(CGRect(x: s.width / 2 - 1, y: glass.maxY, width: 2, height: 1.5)), with: .color(on ? Color.black.opacity(0.7) : Look.ink(0.55)))
            ctx.fill(Path(CGRect(x: s.width / 2 - 3.5, y: glass.maxY + 1.5, width: 7, height: 1.4)), with: .color(on ? Color.black.opacity(0.7) : Look.ink(0.55)))
        }
        .frame(width: 17, height: 15)
        .accessibilityHidden(true)
    }
}

private extension View {
    /// The question field's glass: the dark terminal screen (a CRT) in the dark preset, as it always was; the light preset's light well, with a
    /// sunken edge and dark ink, so no black box sits on the paper.
    @ViewBuilder func askField() -> some View {
        if Look.isLight {
            lookWell().retroBevel(.sunken, cornerRadius: 5, depth: 1.2, face: Dash90.lcdFace)
        } else {
            crtScreen(cornerRadius: 5, scanlines: 0.08, tint: nil, vignette: 0.25)
        }
    }
}
