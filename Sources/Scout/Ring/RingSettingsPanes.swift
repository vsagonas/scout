import AppKit
import SwiftUI

// B4 settings pages of the Ring group: Ring, Ring Tools, Ask AI, Screenshots.

// MARK: - Ask AI

struct AskAISettingsPane: View {
    @AppStorage("ai.provider") private var provider = "anthropic"
    @AppStorage("ai.model.anthropic") private var claudeModel = "auto"
    @AppStorage("ai.model.openai") private var openaiModel = "gpt-6.1-sol"
    @AppStorage("ai.webSearch") private var webSearch = false
    @AppStorage("ai.effort") private var effort = "quick"
    @AppStorage(AskAIPlace.key) private var openIn = ""
    @AppStorage(AIMonitor.key) private var monitorOn = false
    @AppStorage("notch.workspaces") private var notchWorkspaces = ""
    @State private var keyDrafts: [AIProvider: String] = [:]
    /// The last four characters of each saved key (nil = no key). Never more than that is held in memory here.
    @State private var tails: [AIProvider: String?]
    @State private var replacing: Set<AIProvider> = []
    @State private var openaiList = AIModels.openai.map(\.id)
    @State private var customModel = ""
    @State private var confirmClear = false

    /// Gallery: draw the Monitor switch on or off, and with the permission line, whatever the real state is.
    private var previewMonitor: Bool?
    private var previewNoAccess = false

    /// `previewKeyTail` and `previewNoKeys` are for the gallery only (show the saved-key / empty states without reading the Keychain).
    init(previewKeyTail: String? = nil, previewNoKeys: Bool = false, previewMonitor: Bool? = nil, previewNoAccess: Bool = false) {
        self.previewMonitor = previewMonitor
        self.previewNoAccess = previewNoAccess
        func tail(_ p: AIProvider) -> String? { AIKeys.key(for: p).map { String($0.suffix(4)) } }
        if previewNoKeys {
            let none: String? = nil
            _tails = State(initialValue: [.anthropic: none, .openai: none])
        } else {
            _tails = State(initialValue: [.anthropic: previewKeyTail ?? tail(.anthropic), .openai: tail(.openai)])
        }
    }

    /// The provider Ask AI sends to (the Default provider above), so the Screen words name the real company.
    private var chosenProvider: AIProvider { AIProvider(rawValue: provider) ?? .anthropic }

    var body: some View {
        BPage(intro: "Ask AI uses your own API key. Keys stay in your Mac's Keychain and are only sent to the provider you chose.") {
            keySection(.anthropic, footerLink: Edition.isAppStore ? "Get an API key at console.anthropic.com" : "Get a Claude key in the Anthropic Console")
            keySection(.openai, footerLink: "Get an OpenAI key")
            BSection(title: "Models") {
                BRow(title: "Default provider") {
                    Picker("", selection: $provider) { ForEach(AIProvider.allCases) { Text($0.title).tag($0.rawValue) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 170)
                }
                BRow(title: "Claude model", subtitle: claudeModel == "auto" ? "Auto uses Haiku for quick questions and Sonnet for hard ones." : nil) {
                    Picker("", selection: $claudeModel) { ForEach(AIModels.anthropic) { Text($0.title).tag($0.id) } }.labelsHidden().frame(width: 190)
                }
                BRow(title: "OpenAI model") {
                    Picker("", selection: $openaiModel) { ForEach(openaiList, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 190)
                }
                BRow(title: "OpenAI model list", subtitle: "Add any model name your key can use.") {
                    HStack(spacing: 6) {
                        TextField("model name", text: $customModel).textFieldStyle(.roundedBorder).frame(width: 130).onSubmit(addModel)
                        Button("Add", action: addModel).disabled(customModel.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if openaiList.count > 1 {
                    BRow(title: "Remove “\(openaiModel)” from the list") {
                        Button("Remove") {
                            openaiList.removeAll { $0 == openaiModel }
                            StoredList.set(openaiList, key: "ai.openai.models")
                            openaiModel = openaiList.first ?? AIModels.openaiDefaults[0]
                        }
                    }
                }
            }
            BSection(title: "Answers") {
                BRow(title: "Style", subtitle: "For models you pick yourself. Auto chooses how hard to think on its own.") {
                    Picker("", selection: $effort) { Text("Quick").tag("quick"); Text("Thorough").tag("thorough") }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 170)
                }
                BToggleRow(title: "Search the web", subtitle: "Lets the model look things up and list its sources. Uses extra tokens.", isOn: $webSearch)
            }
            BSection(title: "Screen", footer: .verbatim(AIDisclosure.screenFooter(chosenProvider))) {
                BToggleRow(title: "Screen", subtitle: .verbatim(AIDisclosure.screenRow(chosenProvider)),
                           isOn: Binding(get: { previewMonitor ?? monitorOn }, set: { if previewMonitor == nil { AIMonitor.setOn($0) } }))
                if previewMonitor ?? monitorOn, previewNoAccess || (previewMonitor == nil && !CGPreflightScreenCaptureAccess()) {
                    BRow(title: "Screen Recording is off for Scout", subtitle: "Until it is on, questions go without a picture.") {
                        Button("Open Settings") { Permissions.openSettings(.screenRecording) }
                    }
                }
            }
            BSection(title: "History") {
                BActionRow(title: "Clear all chats…", symbol: "trash", role: .destructive) { confirmClear = true }
            }
        }
        .alert("Clear all chats?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { AIChatStore.shared.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your saved conversations and attached images on this Mac will be removed. Fast Ask AI, the dashboard's conversation, stays: clear it from its own chat in the Ask AI tab.") }
    }

    private func keySection(_ p: AIProvider, footerLink: LocalizedStringKey) -> some View {
        let tail = tails[p] ?? nil
        return BSection(title: "\(p.title) key") {
            if let tail, !replacing.contains(p) {
                BRow(title: "Saved in Keychain ••••\(tail)", subtitle: p == .anthropic ? "Used by Ask AI and anything else in Scout that needs AI." : nil) {
                    HStack(spacing: 6) {
                        Button("Replace…") { replacing.insert(p) }
                        Button("Remove", role: .destructive) { AIKeys.save("", for: p); tails[p] = .some(nil) }
                    }
                }
            } else {
                BRow(title: .verbatim(emptyKeyTitle(p, hasKey: tail != nil)), subtitle: tail == nil ? .verbatim(emptyKeySubtitle(p)) : nil) {
                    HStack(spacing: 6) {
                        SecureField(p.keyPlaceholder, text: Binding(get: { keyDrafts[p] ?? "" }, set: { keyDrafts[p] = $0 }))
                            .textFieldStyle(.roundedBorder).frame(width: 190)
                        Button("Save") {
                            AIKeys.save(keyDrafts[p] ?? "", for: p)
                            keyDrafts[p] = ""
                            replacing.remove(p)
                            tails[p] = .some(AIKeys.key(for: p).map { String($0.suffix(4)) })
                        }
                        .disabled((keyDrafts[p] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                        if replacing.contains(p) { Button("Cancel") { replacing.remove(p); keyDrafts[p] = "" } }
                    }
                }
            }
            BActionRow(title: footerLink, symbol: "arrow.up.right.square") { NSWorkspace.shared.open(p.keyURL) }
        }
    }

    /// The App Store edition has no key import, so the empty Anthropic row says exactly what to do.
    private func emptyKeyTitle(_ p: AIProvider, hasKey: Bool) -> String {
        if hasKey { return String(localized: "Paste the new key") }
        return Edition.isAppStore && p == .anthropic ? String(localized: "Paste your Anthropic API key") : String(localized: "No key saved")
    }

    private func emptyKeySubtitle(_ p: AIProvider) -> String {
        Edition.isAppStore && p == .anthropic ? String(localized: "Ask AI needs a key from your own Anthropic account. It stays in your Mac's Keychain.") : String(localized: "Paste a key to start chatting.")
    }

    private func addModel() {
        let name = customModel.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !openaiList.contains(name) else { return }
        openaiList.append(name)
        StoredList.set(openaiList, key: "ai.openai.models")
        openaiModel = name
        customModel = ""
    }
}
