import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Ask AI in the open notch. It is the SAME Ask AI as the ring's floating panel: it reads and writes
/// `AIChatStore.shared`, so a chat started in one place goes on in the other (same history, model, key).
/// Left: the chats. Right: a title bar (model, pop out), the messages and the input.
/// The island stays compact while there is nothing to read and grows downward once there is a conversation.
struct AskAINotchView: View {
    @Environment(\.askAINotchPreview) private var preview

    var body: some View {
        AskAINotchContent(store: preview?.store ?? .shared, draft: preview?.draft ?? .shared, forceNoKey: preview?.forceNoKey ?? false,
                          previewMonitor: preview?.monitor)
    }

    /// The conversation height lives with the content; this keeps one name for the gallery and the report.
    static let conversationHeight = AskAINotchContent.conversationHeight
    static let attachingHeight = AskAINotchContent.attachingHeight
}

/// Gallery only: the state the notch's Ask AI shows (its own chats and draft, never the real store).
struct AskAINotchPreview {
    var store: AIChatStore
    var draft: AskAINotchDraft
    var forceNoKey = false
    /// Draw the Monitor chip on or off whatever the setting says.
    var monitor: Bool?
}

private struct AskAINotchPreviewKey: EnvironmentKey {
    static let defaultValue: AskAINotchPreview? = nil
}

extension EnvironmentValues {
    var askAINotchPreview: AskAINotchPreview? {
        get { self[AskAINotchPreviewKey.self] }
        set { self[AskAINotchPreviewKey.self] = newValue }
    }
}

struct AskAINotchContent: View {
    @ObservedObject var store: AIChatStore
    @ObservedObject var draft: AskAINotchDraft
    @ObservedObject private var focusRequests = AskAINotchFocus.shared
    /// Gallery: force the "no key" state.
    var forceNoKey = false
    var previewMonitor: Bool?
    @AppStorage(AIMonitor.key) private var monitorOn = false
    @AppStorage("ai.notch.chats") private var showChats = true
    @State private var dropTargeted = false
    @State private var windowBox = WindowBox()
    @FocusState private var inputFocused: Bool

    /// The open island's height while a chat has messages (the ring panel is 580 tall; the notch stays a little under).
    static let conversationHeight: CGFloat = 400
    /// A picture is attached to a first question: a little more room for its thumbnail.
    static let attachingHeight: CGFloat = 250

    init(store: AIChatStore, draft: AskAINotchDraft, forceNoKey: Bool = false, previewMonitor: Bool? = nil) {
        self.store = store
        self.draft = draft
        self.forceNoKey = forceNoKey
        self.previewMonitor = previewMonitor
    }

    private var monitorShown: Bool { previewMonitor ?? monitorOn }

    private var hasKey: Bool { !forceNoKey && store.hasKey }
    private var chat: AIChat? { store.current }

    /// The height the Ask AI tab asks for. With a key it is the conversation height for EVERY chat: an empty one, one with a picture waiting
    /// and one with a long answer all keep the same island, so clicking between chats never makes it shorter.
    /// A height dragged on the grip is the person's own, saved for this tab.
    static func requestedHeight(hasKey: Bool) -> CGFloat? { hasKey ? conversationHeight : nil }

    private var wantedHeight: CGFloat? { Self.requestedHeight(hasKey: hasKey) }

    var body: some View {
        Group {
            if hasKey { content } else { noKey }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .notchContent()
        .background(WindowReader(box: windowBox))
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in draft.add(providers: providers) }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4])).padding(2)
            }
        }
        .onAppear {
            syncHeight()
            if store === AIChatStore.shared { AskAITabHold.opened() }   // the real tab (pictures use their own store)
            if focusRequests.isPending {
                focusRequests.consume()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focusInput() }
            }
        }
        .onDisappear {
            NotchNavigator.shared.releaseHeight(by: .askAI)
            AskAITabHold.ended()
        }
        .onChange(of: draft.text) { _, text in if !text.isEmpty { AskAITabHold.engaged() } }   // typing: stays open until a click away
        .onChange(of: monitorOn) { AskAITabHold.engaged() }   // the Screen share switched: the same
        .onChange(of: wantedHeight) { syncHeight() }
        .onReceive(NotchNavigator.shared.$workspace) { kind in   // back on this tab quickly: ask again (see AgentsWorkspaceView)
            if NotchPrefs.resolve(kind) == .askAI { DispatchQueue.main.async { syncHeight() } }
        }
        .onChange(of: store.hasConversation) { syncHeight() }
        .onReceive(focusRequests.$token.dropFirst()) { _ in
            focusRequests.consume()
            focusInput()
        }
        .onChange(of: store.isStreaming) { _, streaming in
            // The answer is done and the keyboard is still in the notch: ready for the follow-up.
            if !streaming, (windowBox.window as? NotchPanel)?.isKeyWindow == true { inputFocused = true }
        }
    }

    private func syncHeight() {
        let more: CGFloat? = hasKey ? .greatestFiniteMagnitude : nil   // the tab can always be resized, whichever chat is open (the grip and the saved height)
        NotchNavigator.shared.requestHeight(wantedHeight, resizeMax: more, by: .askAI)
    }

    /// Makes the notch's panel the key window (it never activates Scout) and puts the cursor in the input.
    private func focusInput(attempt: Int = 0) {
        guard hasKey else { return }
        if let panel = windowBox.window as? NotchPanel, panel.allowsKey {
            if !panel.isKeyWindow { panel.makeKey() }
            inputFocused = true
        } else if attempt < 4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { focusInput(attempt: attempt + 1) }
        }
    }

    // MARK: No key

    private var noKey: some View {
        NotchEmptyState(symbol: "key",
                        message: Edition.isAppStore ? "Paste your Anthropic API key to chat with Claude." : "Add an API key to chat with Claude or GPT.",
                        detail: "It stays in your Mac's Keychain.",
                        actionTitle: "Open Settings › Ask AI") {
            SettingsWindowController.shared.show(.askAI)
            NotchNavigator.shared.forceClose()
        }
    }

    // MARK: Layout

    private var content: some View {
        HStack(alignment: .top, spacing: 0) {
            if showChats {
                chatList.frame(width: 190)
                Rectangle().fill(NotchInk.hairline).frame(width: 1).padding(.horizontal, 12)
            }
            mainColumn
        }
        .padding(.horizontal, 2)
    }

    private var mainColumn: some View {
        VStack(spacing: 6) {
            toolbar
            messages
            inputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Chats

    private var chatList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Chats").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(NotchInk.secondary).textCase(.uppercase)
                Spacer(minLength: 4)
                newChatButton
            }
            .frame(height: 24)
            if store.chats.isEmpty {
                Text("No chats yet").font(.system(size: 11)).foregroundStyle(NotchInk.tertiary).padding(.top, 4)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.chats) { c in
                            AskAIChatRow(chat: c, selected: c.id == store.currentID, locked: store.isBusy,
                                         onSelect: { store.select(c.id) }, onDelete: store.canDelete(c.id) ? { store.delete(c.id) } : nil)
                        }
                    }
                }
            }
        }
    }

    private var newChatButton: some View {
        Button {
            store.newChat()
            focusInput()
        } label: { Image(systemName: "square.and.pencil") }
            .buttonStyle(NotchIconButtonStyle(size: 22))
            .disabled(store.isBusy).opacity(store.isBusy ? 0.4 : 1)
            .help("New chat")
    }

    // MARK: Title bar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { withAnimation(Theme.quick) { showChats.toggle() } } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(NotchIconButtonStyle(size: 22)).help(showChats ? "Hide the chats" : "Show the chats")
            Text(verbatim: store.hasConversation ? (chat?.displayTitle ?? String(localized: "New chat")) : String(localized: "New chat"))
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(NotchInk.secondary).lineLimit(1)
            Spacer(minLength: 8)
            // Fast Ask AI (the dashboard's conversation) clears here, and only here.
            if let chat, chat.id == store.quickID, !chat.messages.isEmpty {
                Button { store.clearQuick() } label: { Image(systemName: "trash") }
                    .buttonStyle(NotchIconButtonStyle(size: 22))
                    .disabled(store.isBusy).opacity(store.isBusy ? 0.4 : 1)
                    .help("Clear Fast Ask AI (the dashboard's conversation)")
                    .accessibilityLabel("Clear Fast Ask AI")
            }
            if !showChats { newChatButton }
            modelMenu
            Button { AskAIPlace.popOut() } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(NotchIconButtonStyle(size: 22)).help("Open this chat in a window")
        }
        .frame(height: 24)
    }

    private var modelMenu: some View {
        let current = chat?.model ?? AIModels.defaultModel(for: AIModels.defaultProvider)
        return Menu {
            Section("Claude") { ForEach(AIModels.anthropic) { modelButton($0, current: current) } }
            Section("OpenAI") { ForEach(AIModels.openai) { modelButton($0, current: current) } }
        } label: {
            HStack(spacing: 3) {
                Text(AIModels.shortTitle(of: current)).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(NotchInk.primary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(NotchInk.tileStrong))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Choose the model")
    }

    private func modelButton(_ m: AIModelInfo, current: String) -> some View {
        Button { store.setModel(m.id, provider: m.provider) } label: {
            if m.id == current { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
        }
    }

    // MARK: Messages

    @ViewBuilder private var messages: some View {
        if let chat, !chat.messages.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(chat.messages) { m in
                            AIMessageView(message: m, streaming: store.streamingID == m.id, searching: store.searching && store.streamingID == m.id,
                                          canAskSonnet: store.canAskSonnet && m.id == chat.messages.last?.id, onAskSonnet: { store.askSonnet() },
                                          fontSize: 13, onDark: true, capturingScreen: store.capturingID == m.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: 780, alignment: .leading)
                    .padding(.vertical, 4).padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .mask(alignment: .top) {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 12)
                        Rectangle()
                    }
                }
                .onChange(of: chat.messages.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.id) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        } else if draft.attachments.isEmpty {
            VStack(spacing: 3) {
                Image(systemName: "sparkles").font(.system(size: 17)).foregroundStyle(Theme.accent)
                Text("Ask anything").font(.system(size: 12, weight: .semibold))
                Text("Return sends, ⌥Return adds a line. Drop a picture to attach it.").font(.system(size: 10.5)).foregroundStyle(NotchInk.secondary)
                Text(AIDisclosure.emptyLine(chat?.provider)).font(.system(size: 10.5)).foregroundStyle(NotchInk.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Spacer(minLength: 0)
        }
    }

    // MARK: Input

    private var inputBar: some View {
        VStack(spacing: 5) {
            if !draft.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(draft.attachments, id: \.self) { file in
                            ZStack(alignment: .topTrailing) {
                                AIImageThumb(file: file, size: 44)
                                Button { draft.remove(file) } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.7))
                                }
                                .buttonStyle(.plain).offset(x: 4, y: -4)
                            }
                        }
                    }
                    .padding(.top, 4).padding(.leading, 2)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button("Choose image…") { draft.chooseImages() }
                    Button("Paste image from clipboard") { draft.pasteImage() }
                } label: { Image(systemName: "paperclip").font(.system(size: 14)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(NotchInk.secondary).padding(.bottom, 5)
                    .help("Attach a picture")
                AIMonitorChip(isOn: monitorShown, provider: chat?.provider) { if previewMonitor == nil { AIMonitor.toggle() } }.padding(.bottom, 4)
                TextField(monitorShown ? "Ask about your screen" : "Ask anything", text: $draft.text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...4)
                    .focused($inputFocused).onSubmit(send)
                    .padding(.vertical, 6)
                Button(action: store.isStreaming ? store.stop : send) {
                    Image(systemName: store.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill").font(.system(size: 23))
                        .foregroundStyle((draft.canSend && !store.isBusy) || store.isStreaming ? Theme.accent : NotchInk.tertiary)
                }
                .buttonStyle(.plain).disabled((!draft.canSend || store.isBusy) && !store.isStreaming)
                .padding(.bottom, 1)
                .help(store.isStreaming ? "Stop" : "Send")
            }
            .padding(.horizontal, 11).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(NotchInk.tile))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(inputFocused ? Theme.accent.opacity(0.6) : NotchInk.hairline, lineWidth: 1))
            if let note = store.monitorNote {
                AIMonitorNoteView(note: note, onDismiss: { store.monitorNote = nil }, afterSettings: { NotchNavigator.shared.forceClose() })
            }
        }
        .onPasteCommand(of: [.png, .tiff, .image]) { providers in draft.add(providers: providers) }
    }

    private func send() {
        guard draft.canSend, !store.isBusy else { return }
        store.send(text: draft.text, imageFiles: draft.attachments)
        draft.clear()
        // Let go of the keyboard: when the pointer leaves, the notch can close and the answer drops down from it.
        inputFocused = false
    }
}

/// One chat in the list on the left.
private struct AskAIChatRow: View {
    let chat: AIChat
    let selected: Bool
    let locked: Bool
    var onSelect: () -> Void
    /// Nil: this chat cannot be deleted here (Fast Ask AI clears from its own chat).
    var onDelete: (() -> Void)?
    @State private var hover = false

    private static func age(_ date: Date) -> String { ToolFormat.ago(date) }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: chat.messages.isEmpty ? String(localized: "New chat") : chat.displayTitle).font(.system(size: 11.5, weight: selected ? .semibold : .regular)).lineLimit(1)
                Text(Self.age(chat.updated) + " · " + AIModels.shortTitle(of: chat.model))
                    .font(.system(size: 9.5)).foregroundStyle(NotchInk.secondary).lineLimit(1)
            }
            Spacer(minLength: 2)
            if hover, !locked, let onDelete {
                Button(action: onDelete) { Image(systemName: "trash").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(NotchInk.secondary).help("Delete this chat")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.accent.opacity(0.2) : (hover ? NotchInk.tile : .clear)))
        .contentShape(Rectangle())
        .opacity(locked && !selected ? 0.5 : 1)
        .onTapGesture { if !locked { onSelect() } }
        .onHover { hover = $0 }
    }
}

// MARK: - The notch's panel, found from inside the view

final class WindowBox {   // shared with the dashboard's Ask AI panel
    weak var window: NSWindow?
}

private final class WindowProbe: NSView {
    var onWindow: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow?(window)
    }
}

struct WindowReader: NSViewRepresentable {
    let box: WindowBox

    func makeNSView(context: Context) -> NSView {
        let probe = WindowProbe()
        probe.onWindow = { box.window = $0 }
        return probe
    }

    func updateNSView(_ view: NSView, context: Context) { box.window = view.window }
}
