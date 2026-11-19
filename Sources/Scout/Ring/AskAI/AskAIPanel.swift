import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum AskAIPanel {
    static func show(newChat: Bool = false) {
        if newChat { AIChatStore.shared.newChat() }
        ToolPanels.show("askai", size: CGSize(width: 440, height: 580), minSize: CGSize(width: AskAIMetrics.minPanelWidth, height: 420), resizable: true) {
            AskAIView(input: ToolMemory.string(ToolMemory.askDraft) ?? "")
        }
    }
}

struct AskAIView: View {
    @ObservedObject var store: AIChatStore
    /// Gallery: force the "no key" state.
    var forceNoKey = false
    /// Gallery: draw the Monitor chip on or off whatever the setting says.
    var previewMonitor: Bool?
    @AppStorage(AIMonitor.key) private var monitorOn = false
    @State private var input: String
    @State private var attachments: [String]
    @State private var dropTargeted = false
    @State private var panelWidth: CGFloat = 0

    init(store: AIChatStore? = nil, forceNoKey: Bool = false, input: String = "", attachments: [String] = [], monitor: Bool? = nil) {
        self.store = store ?? AIChatStore.shared
        self.forceNoKey = forceNoKey
        self.previewMonitor = monitor
        _input = State(initialValue: input)
        _attachments = State(initialValue: attachments)
    }

    private var hasKey: Bool { !forceNoKey && store.hasKey }
    private var chat: AIChat? { store.current }
    private var monitorShown: Bool { previewMonitor ?? monitorOn }
    /// With Monitor on the placeholder says so, when the row is wide enough to show all of it; else it is the short one.
    private var placeholder: String {
        let long = String(localized: "Ask about your screen")
        guard monitorShown, panelWidth == 0 || panelWidth >= AskAIMetrics.rowWidth(placeholder: long, collapsed: true) else { return String(localized: "Ask anything") }
        return long
    }
    /// Too little room for the word "Screen" next to the whole placeholder: the chip keeps only its icon.
    private var chipCollapsed: Bool { panelWidth > 0 && panelWidth < AskAIMetrics.collapseBelow(placeholder: placeholder) }

    var body: some View {
        ToolPanelFrame("Ask AI", symbol: "sparkles", accessory: { AskAIHeaderControls(store: store) }) {
            VStack(spacing: 0) {
                if !hasKey {
                    ToolEmptyState(symbol: "key", message: Edition.isAppStore ? String(localized: "Paste your Anthropic API key to chat with Claude.\nIt stays in your Mac's Keychain.") : String(localized: "Add an API key to chat with Claude or GPT.\nIt stays in your Mac's Keychain."),
                                   actionTitle: String(localized: "Open Settings › Ask AI")) { SettingsWindowController.shared.show(.askAI) }
                } else {
                    messages
                    inputBar
                }
            }
        }
        .background(GeometryReader { g in Color.clear.preference(key: AskAIWidthKey.self, value: g.size.width) })
        .onPreferenceChange(AskAIWidthKey.self) { panelWidth = $0 }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in handleDrop(providers) }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4])).padding(4)
            }
        }
    }

    // MARK: Messages

    @ViewBuilder private var messages: some View {
        if let chat, !chat.messages.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(chat.messages) { m in
                            AIMessageView(message: m, streaming: store.streamingID == m.id, searching: store.searching && store.streamingID == m.id,
                                          canAskSonnet: store.canAskSonnet && m.id == chat.messages.last?.id, onAskSonnet: { store.askSonnet() },
                                          capturingScreen: store.capturingID == m.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                }
                .onChange(of: chat.messages.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        } else {
            ToolEmptyState(symbol: "sparkles", message: AIDisclosure.panelEmptyText(chat?.provider))
        }
    }

    // MARK: Input

    private var inputBar: some View {
        VStack(spacing: 6) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments, id: \.self) { file in
                            ZStack(alignment: .topTrailing) {
                                AIImageThumb(file: file, size: 52)
                                Button { attachments.removeAll { $0 == file } } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .buttonStyle(.plain).offset(x: 4, y: -4)
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.top, 4)
                }
            }
            AskAIInputRow(text: $input, placeholder: placeholder, monitorOn: monitorShown, collapsed: chipCollapsed,
                          isStreaming: store.isStreaming, canSend: canSend, monitorNoteShown: store.monitorNote != nil, provider: chat?.provider,
                          onChooseImage: chooseImage, onPasteImage: pasteImage,
                          onMonitor: { if previewMonitor == nil { AIMonitor.toggle() } },
                          onSend: send, onStop: store.stop)
            if let note = store.monitorNote {
                AIMonitorNoteView(note: note, onDismiss: { store.monitorNote = nil })
                    .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .onPasteCommand(of: [.png, .tiff, .image]) { providers in
            for p in providers { loadImage(from: p) }
        }
        .onChange(of: input) { _, new in draftChanged(new) }
    }

    private func draftChanged(_ text: String) {
        guard previewMonitor == nil, !forceNoKey else { return }
        ToolMemory.set(text, ToolMemory.askDraft)
    }

    private var canSend: Bool { !store.isBusy && (!input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) }

    private func send() {
        guard canSend else { return }
        store.send(text: input, imageFiles: attachments)
        input = ""
        attachments = []
        ToolMemory.set(nil, ToolMemory.askDraft)
    }

    private func chooseImage() {
        guard !ScoutRuntime.isScripted else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { if let image = NSImage(contentsOf: url), let name = AIImages.store(image) { attachments.append(name) } }
    }

    private func pasteImage() {
        guard !ScoutRuntime.isScripted, let image = NSImage(pasteboard: .general), let name = AIImages.store(image) else {
            Toast.show("No image on the clipboard", symbol: "photo", style: .info)
            return
        }
        attachments.append(name)
    }

    private func loadImage(from provider: NSItemProvider) {
        _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
            guard let image = object as? NSImage else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { if let name = AIImages.store(image) { attachments.append(name) } } }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let image = NSImage(contentsOf: url) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { if let name = AIImages.store(image) { attachments.append(name) } } }
            }
        }
        return handled
    }
}


// MARK: - The pieces the panel's width depends on

struct AskAIWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The header's controls: the model, the history, a new chat.
struct AskAIHeaderControls: View {
    @ObservedObject var store: AIChatStore
    @State private var showHistory = false
    @State private var showModels = false
    private var chat: AIChat? { store.current }

    var body: some View {
        HStack(spacing: 10) {
            Button { showModels.toggle() } label: {
                // At the narrowest panel there is no room for the model's name: the capsule keeps a small icon (the tooltip says what it is).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 3) {
                        Text(AIModels.shortTitle(of: chat?.model ?? AIModels.defaultModel(for: AIModels.defaultProvider))).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "sparkle").font(.system(size: 10, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain).help("Choose the model")
            .popover(isPresented: $showModels, arrowEdge: .bottom) {
                AIModelPicker(selected: chat?.model ?? AIModels.defaultModel(for: AIModels.defaultProvider)) { m in
                    store.setModel(m.id, provider: m.provider)
                    showModels = false
                }
            }
            Button { showHistory.toggle() } label: { Image(systemName: "clock.arrow.circlepath").font(.system(size: 13)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Chat history")
                .popover(isPresented: $showHistory, arrowEdge: .bottom) { historyList }
            Button { store.newChat() } label: { Image(systemName: "square.and.pencil").font(.system(size: 13)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("New chat").disabled(store.isBusy)
        }
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if store.chats.isEmpty {
                Text("No chats yet").font(.system(size: 12)).foregroundStyle(.secondary).padding(14)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.chats) { c in
                            HStack(spacing: 8) {
                                Image(systemName: c.provider == .anthropic ? "sparkle" : "circle.hexagongrid").font(.system(size: 10)).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: c.displayTitle).font(.system(size: 12.5)).lineLimit(1)
                                    Text(verbatim: "\(ToolFormat.ago(c.updated)) · \(AIModels.title(of: c.model))").font(.system(size: 10.5)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 6)
                                if store.canDelete(c.id) {
                                    Button { store.delete(c.id) } label: { Image(systemName: "trash").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(c.id == store.currentID ? Theme.accent.opacity(0.2) : .clear))
                            .contentShape(Rectangle())
                            .onTapGesture { store.select(c.id); showHistory = false }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 280)
    }

}

/// The input row: attach, the Monitor chip, the field, send. A view of its own so its width can be measured (`AskAIMetrics`).
struct AskAIInputRow: View {
    @Binding var text: String
    var placeholder: String
    var monitorOn: Bool
    /// The chip shows only its icon.
    var collapsed: Bool
    var isStreaming: Bool
    var canSend: Bool
    var monitorNoteShown = false
    /// The provider a question goes to, for the Screen chip's tooltip (nil: the one chosen in Settings).
    var provider: AIProvider?
    var onChooseImage: () -> Void = {}
    var onPasteImage: () -> Void = {}
    var onMonitor: () -> Void = {}
    var onSend: () -> Void = {}
    var onStop: () -> Void = {}
    /// Measuring only: the field is its placeholder as plain text, so the row's natural width is the width that shows it whole.
    var measuring = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Button("Choose image…", action: onChooseImage)
                Button("Paste image from clipboard", action: onPasteImage)
            } label: { Image(systemName: "paperclip").font(.system(size: 14)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary).padding(.bottom, 5)
            AIMonitorChip(isOn: monitorOn, provider: provider, action: onMonitor).environment(\.aiMonitorCompact, collapsed).padding(.bottom, 4)
            field
            Button(action: isStreaming ? onStop : onSend) {
                Image(systemName: isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill").font(.system(size: 24))
                    .foregroundStyle(canSend || isStreaming ? Theme.accent : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain).disabled(!canSend && !isStreaming).keyboardShortcut(.return, modifiers: .command)
            .help(isStreaming ? "Stop" : "Send")
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.07)))
        .padding(.horizontal, 12).padding(.bottom, monitorNoteShown ? 4 : 12)
        .onAppear { focused = true }
    }

    @ViewBuilder private var field: some View {
        if measuring {
            Text(placeholder).font(.system(size: 13.5)).lineLimit(1).padding(.vertical, 6)
        } else {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13.5)).lineLimit(1...6)
                .focused($focused).onSubmit(onSend)
                .padding(.vertical, 6)
        }
    }
}

/// Measured, not guessed: how wide the panel must be for the input row to show the whole placeholder.
@MainActor
enum AskAIMetrics {
    /// A TextField draws its text a little inside its frame, so the measured Text gets this much more room.
    static let fieldInset: CGFloat = 8

    private static var widths: [String: CGFloat] = [:]

    /// The width of the row (with its margins) when it shows `placeholder` whole. Measured once per case.
    static func rowWidth(placeholder: String, collapsed: Bool) -> CGFloat {
        let key = "\(collapsed)|\(placeholder)"
        if let hit = widths[key] { return hit }
        let row = AskAIInputRow(text: .constant(""), placeholder: placeholder, monitorOn: false, collapsed: collapsed,
                                isStreaming: false, canSend: true, measuring: true)
        let host = NSHostingView(rootView: row.fixedSize(horizontal: true, vertical: false))
        let width = ceil(host.fittingSize.width + fieldInset)
        widths[key] = width
        return width
    }

    /// The header's natural width: title, model, history, new chat, close.
    static func headerWidth() -> CGFloat {
        let host = NSHostingView(rootView: PanelHeader("Ask AI", symbol: "sparkles", accessory: { AskAIHeaderControls(store: AIChatStore(demo: .empty)) }).fixedSize(horizontal: true, vertical: false))
        return ceil(host.fittingSize.width)
    }

    /// The narrowest panel: the whole "Ask anything" with the Monitor chip as its icon, and every other button in the row.
    static var minPanelWidth: CGFloat { rowWidth(placeholder: String(localized: "Ask anything"), collapsed: true) }

    /// Below this width the chip keeps only its icon: the word "Screen" and the whole placeholder no longer fit together.
    static func collapseBelow(placeholder: String) -> CGFloat { rowWidth(placeholder: placeholder, collapsed: false) }
}

struct AIImageThumb: View {
    let file: String
    var size: CGFloat

    var body: some View {
        Group {
            if let image = NSImage(contentsOf: AIImages.url(file)) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.primary.opacity(0.1).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct AIMessageView: View {
    let message: AIChatMessage
    var streaming: Bool
    var searching: Bool
    var canAskSonnet = false
    var onAskSonnet: () -> Void = {}
    /// The notch shows the same messages a little smaller, and closes itself after the Settings button.
    var fontSize: CGFloat = 13.5
    /// Drawn on the notch's black: the faintest text is a little brighter than the system's `.tertiary`.
    var onDark = false
    /// Monitor is taking this question's picture of the screen right now.
    var capturingScreen = false
    var onOpenSettings: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistant
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 6) {
                if !message.imageFiles.isEmpty || capturingScreen {
                    HStack(spacing: 4) {
                        ForEach(message.imageFiles, id: \.self) { file in
                            if AIImages.isScreen(file) { AIScreenThumb(file: file) } else { AIImageThumb(file: file, size: 90) }
                        }
                        if capturingScreen { AIMonitorPending() }
                    }
                }
                if !message.text.isEmpty {
                    Text(message.text).font(.system(size: fontSize)).textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accent.opacity(0.24)))
                }
            }
        }
    }

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.isError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message.text).font(.system(size: fontSize - 0.5)).fixedSize(horizontal: false, vertical: true)
                        if message.opensSettings ?? message.text.contains("Settings ›") {
                            Button("Open Settings › Ask AI") { SettingsWindowController.shared.show(.askAI); onOpenSettings() }.controlSize(.small)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.12)))
            } else {
                if message.text.isEmpty, streaming {
                    HStack(spacing: 6) {
                        if searching { Image(systemName: "globe").foregroundStyle(Theme.accent) } else { ProgressView().controlSize(.small) }
                        Text(searching ? "Searching the web…" : "Thinking…").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                } else {
                    AIMarkdownView(text: message.text, font: fontSize)
                    if searching {
                        Label("Searching the web…", systemImage: "globe").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                if !message.sources.isEmpty { sourcesView }
                if !streaming, !message.text.isEmpty {
                    HStack(spacing: 10) {
                        Button { copy() } label: { Label("Copy", systemImage: "doc.on.doc").font(.system(size: 11)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                        if let model = message.model { Text(AIModels.shortTitle(of: model)).font(.system(size: 10.5)).foregroundStyle(.secondary) }
                        if canAskSonnet {
                            Button(action: onAskSonnet) {
                                Label("Ask Sonnet", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 10.5, weight: .medium))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(Theme.accent.opacity(0.22)))
                            }
                            .buttonStyle(.plain).help("Ask the same question again on Claude Sonnet 5.5")
                        }
                    }
                    .opacity(hovering || canAskSonnet ? 1 : 0.7)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
    }

    private var sourcesView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sources").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(Array(message.sources.enumerated()), id: \.element.id) { i, s in
                Button {
                    if !ScoutRuntime.isScripted, let url = URL(string: s.url) { NSWorkspace.shared.open(url) }
                } label: {
                    HStack(spacing: 6) {
                        Text(verbatim: "\(i + 1)").font(.system(size: 10, weight: .bold, design: .rounded)).frame(width: 16, height: 16)
                            .background(Circle().fill(Color.primary.opacity(0.1)))
                        Text(s.title).lineLimit(1)
                        Text(s.host).foregroundStyle(onDark ? AnyShapeStyle(NotchInk.secondary) : AnyShapeStyle(.tertiary)).lineLimit(1)
                    }
                    .font(.system(size: 11.5))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    private func copy() {
        if !ScoutRuntime.isScripted { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) }
        Toast.show("Answer copied", symbol: "doc.on.doc")
    }
}

/// The model menu: Auto, the Claude models, then the OpenAI models, each with a short line about it.
struct AIModelPicker: View {
    var selected: String
    var onPick: (AIModelInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header("Claude")
            ForEach(AIModels.anthropic) { row($0) }
            header("OpenAI").padding(.top, 6)
            ForEach(AIModels.openai) { row($0) }
        }
        .padding(8)
        .frame(width: 290)
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase).padding(.horizontal, 8).padding(.top, 2)
    }

    private func row(_ m: AIModelInfo) -> some View {
        Button { onPick(m) } label: {
            HStack(spacing: 8) {
                Image(systemName: selected == m.id ? "checkmark" : "").font(.system(size: 11, weight: .semibold)).frame(width: 14).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.title).font(.system(size: 13, weight: m.id == AIModels.autoID ? .semibold : .regular))
                    if let blurb = AIModels.blurb(of: m.id) { Text(blurb).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected == m.id ? Theme.accent.opacity(0.16) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
