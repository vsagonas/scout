import AppKit
import Foundation

// B2 Ask AI — the chats, the current conversation and the streaming session.

@MainActor
final class AIChatStore: ObservableObject {
    /// The one store the ring's panel and the notch share. The first use also wakes the drop-down under the notch.
    static let shared: AIChatStore = {
        let store = AIChatStore()
        DispatchQueue.main.async { MainActor.assumeIsolated { AskAIDropDown.shared.attach(store) } }
        return store
    }()

    @Published private(set) var chats: [AIChat] = []
    /// The chat that is open. It is remembered, so a restart reopens the same conversation.
    @Published var currentID: UUID? {
        didSet { if persists, currentID != oldValue { Pref.set(currentID?.uuidString, Self.currentKey) } }
    }
    private static let currentKey = "ai.currentChat"
    @Published private(set) var isStreaming = false
    @Published private(set) var searching = false
    @Published private(set) var streamingID: UUID?
    /// The chat being answered right now (the open one, or the dashboard's Fast Ask AI).
    @Published private(set) var streamingChatID: UUID?
    /// Monitor: the question whose picture of the screen is being taken (its answer starts the moment it is attached).
    @Published private(set) var capturingID: UUID?
    /// Why the last question went without its picture (shown under the input, with a button to System Settings).
    @Published var monitorNote: AIMonitorNote?
    /// True when the last answer ended because the user pressed Stop (the drop-down stays quiet then).
    private(set) var lastFinishWasStop = false
    private var stopRequested = false

    private let file = JSONFile<[AIChat]>("ai-chats.json")
    private let saver = Debouncer(delay: 0.8)
    private var task: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var persists: Bool { !ScoutRuntime.isScripted }

    init() {
        if ScoutRuntime.isScripted {
            chats = Self.sampleChats()
        } else {
            chats = file.load() ?? []
        }
        chats.sort { $0.updated > $1.updated }
        // Fast Ask AI is one conversation: duplicates older builds left behind become one again (see `mergeQuick`).
        if persists {
            let marked = UUID(uuidString: Pref.string(Self.quickKey, ""))
            let merged = Self.mergeQuick(chats, marked: marked)
            if merged.chats != chats {
                chats = merged.chats
                save()
            }
            if let q = merged.quickID, q != marked { Pref.set(q.uuidString, Self.quickKey) }
        }
        if persists, let saved = Pref.string(Self.currentKey, "").isEmpty ? nil : UUID(uuidString: Pref.string(Self.currentKey, "")),
           chats.contains(where: { $0.id == saved }) {
            currentID = saved
        } else {
            currentID = chats.first?.id
        }
    }

    enum Demo { case empty, searching, thinking, error, haikuAnswer, streaming, conversation, monitorSent, monitorCapturing, quick }

    /// Gallery states.
    init(demo: Demo) {
        var chat = AIChat(provider: .anthropic, model: AIModels.autoID)
        var history: [AIChat] = []
        switch demo {
        case .empty:
            history = Self.sampleChats()
        case .conversation:
            chats = Self.sampleChats()
            currentID = chats.first?.id
            return
        case .monitorSent, .monitorCapturing:
            chat.title = "What does this error mean?"
            let screen = demo == .monitorSent ? (AIMonitor.sampleScreenFile().map { [$0] } ?? []) : []
            let question = AIChatMessage(role: .user, text: "What does this error mean?", imageFiles: screen)
            chat.messages = [question]
            if demo == .monitorSent {
                chat.messages.append(AIChatMessage(role: .assistant, text: Self.monitorSample, model: AIModels.sonnet))
            } else {
                capturingID = question.id
            }
            history = Array(Self.sampleChats().dropFirst())
        case .searching, .thinking:
            chat.title = "Latest Swift release"
            chat.messages = [AIChatMessage(role: .user, text: "What changed in the latest Swift release?"),
                             AIChatMessage(role: .assistant, text: "", model: AIModels.sonnet)]
            streamingID = chat.messages[1].id
            isStreaming = true
            searching = demo == .searching
        case .streaming:
            chat.title = "A weekend in Lisbon"
            chat.messages = [AIChatMessage(role: .user, text: "Plan a relaxed two-day weekend in Lisbon. I like coffee, tiles and long walks."),
                             AIChatMessage(role: .assistant, text: Self.streamingSample, model: AIModels.sonnet)]
            streamingID = chat.messages[1].id
            isStreaming = true
            history = Array(Self.sampleChats().dropFirst())
        case .haikuAnswer:
            chat.model = AIModels.autoID
            chat.title = "Capital of Peru"
            chat.messages = [AIChatMessage(role: .user, text: "What's the capital of Peru?"),
                             AIChatMessage(role: .assistant, text: "The capital of Peru is **Lima**. It sits on the Pacific coast and is home to about a third of the country's people.", model: AIModels.haiku)]
        case .quick:
            // The dashboard's own conversation with one question answered: what the Ask AI panel shows in its history.
            chat.title = Self.quickTitle
            chat.messages = [AIChatMessage(role: .user, text: "What's the capital of Peru?"),
                             AIChatMessage(role: .assistant, text: "The capital of Peru is **Lima**. It sits on the Pacific coast and is home to about a third of the country's people.", model: AIModels.haiku)]
            scriptedQuickID = chat.id
            history = Self.sampleChats()
        case .error:
            chat.messages = [AIChatMessage(role: .user, text: "Summarise this page for me"),
                             { var m = AIChatMessage(role: .assistant, text: "That API key was rejected. Check it in Settings › Ask AI.", model: AIModels.haiku); m.isError = true; return m }()]
        }
        chats = [chat] + history
        currentID = chat.id
    }

    /// Gallery: an answer about the screen Monitor sent along.
    static let monitorSample = """
        The error is on the line in the red band: **`Route` has no member named `default`**.

        - `plan(day:)` reads `Route.default.stops`, but `Route` never defines a `default` value.
        - Add a `default` value to `Route`, or pass a route into `plan(day:)` instead.
        """

    /// Gallery: an answer that is half written.
    static let streamingSample = """
        Here is a plan that keeps the walking easy and the coffee stops frequent.

        **Saturday**
        1. Start in *Alfama* with a coffee at a small café, then wander uphill to the Sé.
        2. Lunch near **Praça do Comércio**, then the tile museum in the afternoon.

        **Sunday**
        - Take tram 28 early, before the queues.
        - Walk along the river to Belém and stop for a pastel de
        """

    var current: AIChat? { chats.first { $0.id == currentID } }
    /// The chat has something to read (the notch grows only then).
    var hasConversation: Bool { !(current?.messages.isEmpty ?? true) }
    var hasKey: Bool { AIKeys.hasKey(current?.provider ?? AIModels.defaultProvider) }

    // MARK: Chats

    @discardableResult
    func newChat() -> AIChat {
        if let c = current, c.messages.isEmpty { return c }
        let provider = AIModels.defaultProvider
        let chat = AIChat(provider: provider, model: AIModels.defaultModel(for: provider))
        chats.insert(chat, at: 0)
        currentID = chat.id
        save()
        return chat
    }

    /// Streaming an answer or taking Monitor's picture: no second question, no switching chats.
    var isBusy: Bool { isStreaming || capturingID != nil }

    func select(_ id: UUID) {
        guard !isBusy else { return }
        currentID = id
    }

    /// The dashboard's conversation (Fast Ask AI) is never deleted from a list or by Clear all: the dashboard always shows its history, and
    /// it is cleared only from its own chat
    func canDelete(_ id: UUID) -> Bool { id != quickID }

    /// Empties Fast Ask AI (the chat stays, so the dashboard keeps its conversation's place).
    func clearQuick() {
        guard let id = quickID, let i = index(of: id) else { return }
        if streamingID == id { stop() }
        cancelCapture()
        chats[i].messages = []
        chats[i].updated = Date()
        save()
    }

    func delete(_ id: UUID) {
        guard canDelete(id) else { return }
        if streamingID == id { stop() }
        cancelCapture()
        chats.removeAll { $0.id == id }
        if currentID == id { currentID = chats.first?.id }
        save()
    }

    /// Every chat but Fast Ask AI (cleared from its own chat), and every attached picture it does not use.
    func clearAll() {
        stop()
        cancelCapture()
        let quick = quickID
        chats = chats.filter { $0.id == quick }
        currentID = nil
        save()
        guard persists else { return }
        let kept = Set(chats.flatMap { $0.messages.flatMap(\.imageFiles) })
        let folder = AIImages.folder
        for file in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !kept.contains(file) && !kept.contains(folder.appendingPathComponent(file).path) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
    }

    func setModel(_ model: String, provider: AIProvider) {
        UserDefaults.standard.set(provider.rawValue, forKey: "ai.provider")
        UserDefaults.standard.set(model, forKey: "ai.model.\(provider.rawValue)")
        guard let i = chats.firstIndex(where: { $0.id == currentID }) else { return }
        if chats[i].messages.isEmpty || chats[i].provider == provider {
            chats[i].provider = provider
            chats[i].model = model
        } else {
            // Different provider mid-chat: the history stays readable but starts a fresh chat.
            let chat = AIChat(provider: provider, model: model)
            chats.insert(chat, at: 0)
            currentID = chat.id
        }
        save()
    }

    private func index(of id: UUID) -> Int? { chats.firstIndex { $0.id == id } }

    // MARK: Fast Ask AI (the dashboard's one saved conversation)

    /// A question asked on the dashboard is answered ON the dashboard,
    /// One chat holds those questions: it is saved
    /// with the others (and can be opened in the Ask AI tab), asking never makes it the open chat, and it keeps its name.
    /// The stored name of that chat: an identifier, kept English in the file and never shown as it is (`AIChat.displayTitle` gives the words a person reads).
    static let quickTitle = "Fast Ask AI"
    private static let quickKey = "ai.quickChat"
    /// How many messages it keeps, and sends along as context.
    static let quickLimit = 24
    private var scriptedQuickID: UUID?

    /// The dashboard's conversation, if it exists.
    var quickID: UUID? {
        let saved = persists ? UUID(uuidString: Pref.string(Self.quickKey, "")) : scriptedQuickID
        guard let saved, chats.contains(where: { $0.id == saved }) else { return nil }
        return saved
    }

    var quickChat: AIChat? { quickID.flatMap { id in chats.first { $0.id == id } } }

    /// Fast Ask AI is ONE conversation.
    /// When the saved marker pointed at nothing, older builds started another one and the old ones stayed as plain chats with the same
    /// name. Every chat named Fast Ask AI (and the marked one) becomes one again: the marked one, else the most recent, keeps its place and
    /// takes the others' messages in time order, the newest `quickLimit` of them, starting on a question. Nothing else is touched.
    nonisolated static func mergeQuick(_ chats: [AIChat], marked: UUID?) -> (chats: [AIChat], quickID: UUID?) {
        let quick = chats.filter { $0.id == marked || $0.title == quickTitle }
        guard let keeper = quick.first(where: { $0.id == marked }) ?? quick.max(by: { $0.updated < $1.updated }) else { return (chats, nil) }
        guard quick.count > 1 else { return (chats, keeper.id) }
        var seen = Set<UUID>()
        var messages = quick.flatMap(\.messages).sorted { $0.date < $1.date }.filter { seen.insert($0.id).inserted }
        if messages.count > quickLimit { messages.removeFirst(messages.count - quickLimit) }
        while messages.first?.role == .assistant { messages.removeFirst() }
        var merged = keeper
        merged.title = quickTitle
        merged.messages = messages
        merged.updated = quick.map(\.updated).max() ?? keeper.updated
        let gone = Set(quick.map(\.id)).subtracting([keeper.id])
        return (chats.compactMap { $0.id == keeper.id ? merged : (gone.contains($0.id) ? nil : $0) }, keeper.id)
    }

    /// A chat named Fast Ask AI when the marker points at nothing: it is taken back as the dashboard's conversation (never a second one).
    private func adoptQuick() -> UUID? {
        guard let found = chats.filter({ $0.title == Self.quickTitle }).max(by: { $0.updated < $1.updated }) else { return nil }
        if persists { Pref.set(found.id.uuidString, Self.quickKey) } else { scriptedQuickID = found.id }
        return found.id
    }

    /// A question from the dashboard: it goes into the Fast Ask AI conversation (made on first use).
    func sendQuick(text: String, imageFiles: [String]) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, !clean.isEmpty || !imageFiles.isEmpty else { return }
        let id: UUID
        if let existing = quickID ?? adoptQuick() {
            id = existing
        } else {
            let provider = AIModels.defaultProvider
            var chat = AIChat(provider: provider, model: AIModels.defaultModel(for: provider))
            chat.title = Self.quickTitle
            chats.append(chat)
            id = chat.id
            if persists { Pref.set(id.uuidString, Self.quickKey) } else { scriptedQuickID = id }
        }
        send(text: text, imageFiles: imageFiles, in: id)
    }

    /// Keeps the dashboard's conversation short: the oldest messages go (it always starts with a question), and older
    /// questions give up their pictures, so a long day of quick questions never sends a pile of screenshots along.
    private func trimQuick(at i: Int) {
        let room = Self.quickLimit - 2   // the new question and its answer
        while chats[i].messages.count > room || chats[i].messages.first?.role == .assistant { chats[i].messages.removeFirst() }
        for m in chats[i].messages.indices where !chats[i].messages[m].imageFiles.isEmpty { chats[i].messages[m].imageFiles = [] }
    }

    // MARK: Sending

    /// `chatID` nil: the open chat (the usual way). The dashboard passes its Fast Ask AI conversation, and the open chat stays.
    func send(text: String, imageFiles: [String], in chatID: UUID? = nil) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, !clean.isEmpty || !imageFiles.isEmpty else { return }
        // A follow-up goes on in the open chat; only with no chat at all does this start one.
        let chat = chatID.flatMap { id in chats.first { $0.id == id } } ?? current ?? newChat()
        guard let i = index(of: chat.id) else { return }
        let quick = chat.id == quickID
        if chats[i].messages.isEmpty, !quick { chats[i].title = String((clean.isEmpty ? String(localized: "Image") : clean).prefix(44)) }
        if quick { trimQuick(at: i) }
        let question = AIChatMessage(role: .user, text: clean, imageFiles: imageFiles)
        chats[i].messages.append(question)
        chats[i].updated = Date()
        streamingChatID = chat.id
        // Monitor: the picture is taken now, the answer starts as soon as it is attached (without a key there is nothing to send it to).
        if AIMonitor.isOn, AIKeys.hasKey(chats[i].provider) {
            beginCapture(chatID: chat.id, messageID: question.id)
        } else {
            startReply(chatID: chat.id, forcedModel: nil)
        }
    }

    private func beginCapture(chatID: UUID, messageID: UUID) {
        capturingID = messageID
        captureTask = Task { @MainActor in
            let outcome = await AIMonitor.capture()
            guard !Task.isCancelled else { return }
            capturingID = nil
            captureTask = nil
            guard let c = index(of: chatID) else { return }
            switch outcome {
            case .picture(let name):
                if let m = chats[c].messages.firstIndex(where: { $0.id == messageID }) { chats[c].messages[m].imageFiles.append(name) }
                monitorNote = nil
            case .noAccess:
                monitorNote = .noAccess
            case .failed:
                monitorNote = .failed
            }
            startReply(chatID: chatID, forcedModel: nil)
        }
    }

    private func cancelCapture() {
        captureTask?.cancel()
        captureTask = nil
        capturingID = nil
    }

    /// The "Ask Sonnet" button: throws away the last (Haiku) answer and asks the same question again on Sonnet.
    func askSonnet() {
        guard !isStreaming, let c = current, let i = index(of: c.id), let last = chats[i].messages.last, last.role == .assistant,
              chats[i].messages.dropLast().last?.role == .user else { return }
        chats[i].messages.removeLast()
        startReply(chatID: c.id, forcedModel: AIModels.sonnet)
    }

    /// Whether the last answer can be re-asked on Sonnet.
    var canAskSonnet: Bool {
        guard !isStreaming, let last = current?.messages.last else { return false }
        return last.role == .assistant && last.model == AIModels.haiku && !last.isError
    }

    /// Adds the assistant's placeholder and starts streaming (or the canned answer in scripted runs).
    private func startReply(chatID: UUID, forcedModel: String?) {
        guard let i = index(of: chatID) else { return }
        let provider = chats[i].provider
        let history = chats[i].messages
        let route: AIRouter.Route
        if let forcedModel {
            route = AIRouter.Route(model: forcedModel, effort: "medium")
        } else if provider == .anthropic {
            route = AIRouter.route(chatModel: chats[i].model, history: history)
        } else {
            route = AIRouter.Route(model: chats[i].model, effort: AIRouter.manualEffort)
        }
        var reply = AIChatMessage(role: .assistant, text: "")
        reply.model = route.model
        chats[i].messages.append(reply)
        chats[i].updated = Date()
        let chatID = chats[i].id, replyID = reply.id
        stopRequested = false
        isStreaming = true
        streamingID = replyID
        searching = false
        save()

        if ScoutRuntime.isScripted {
            task = Task { await self.runCanned(chatID: chatID, replyID: replyID) }
            return
        }
        guard let key = AIKeys.key(for: provider) else {
            finish(chatID: chatID, replyID: replyID, error: String(localized: "Add your \(provider.title) API key in Settings › Ask AI first."), opensSettings: true)
            return
        }
        let request = AIClient.Request(provider: provider, model: route.model, history: history,
                                       webSearch: UserDefaults.standard.bool("ai.webSearch", default: false),
                                       effort: route.effort, apiKey: key)
        task = Task {
            do {
                let result = try await AIClient.stream(request) { state in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.apply(state, chatID: chatID, replyID: replyID) } }
                }
                await MainActor.run {
                    self.apply(result, chatID: chatID, replyID: replyID)
                    self.finish(chatID: chatID, replyID: replyID, blocks: result.blocks)
                }
            } catch is CancellationError {
                await MainActor.run { self.finish(chatID: chatID, replyID: replyID, cancelled: true) }
            } catch let urlError as URLError where urlError.code == .cancelled {
                await MainActor.run { self.finish(chatID: chatID, replyID: replyID, cancelled: true) }
            } catch {
                let message = (error as? AIError)?.message ?? ((error as? URLError)?.code == .notConnectedToInternet ? String(localized: "You're offline. Check your connection and try again.") : error.localizedDescription)
                let opensSettings = (error as? AIError)?.opensSettings ?? false
                await MainActor.run { self.finish(chatID: chatID, replyID: replyID, error: message, opensSettings: opensSettings) }
            }
        }
    }

    func stop() {
        if isStreaming { stopRequested = true }
        task?.cancel()
    }

    private func apply(_ state: AIStreamState, chatID: UUID, replyID: UUID) {
        guard let c = index(of: chatID), let m = chats[c].messages.firstIndex(where: { $0.id == replyID }) else { return }
        chats[c].messages[m].text = state.text
        chats[c].messages[m].sources = state.sources
        searching = state.searching
    }

    private func finish(chatID: UUID, replyID: UUID, blocks: [JSONValue]? = nil, error: String? = nil, opensSettings: Bool = false, cancelled: Bool = false) {
        defer {
            lastFinishWasStop = stopRequested
            stopRequested = false
            isStreaming = false
            streamingID = nil
            streamingChatID = nil
            searching = false
            task = nil
            save()
        }
        guard let c = index(of: chatID), let m = chats[c].messages.firstIndex(where: { $0.id == replyID }) else { return }
        if let error {
            chats[c].messages[m].text = error
            chats[c].messages[m].isError = true
            chats[c].messages[m].opensSettings = opensSettings
            chats[c].messages[m].blocks = []
        } else if cancelled {
            // A cut-off answer keeps its text only (partial blocks can't be replayed).
            if chats[c].messages[m].text.isEmpty { chats[c].messages.remove(at: m) }
        } else if let blocks {
            chats[c].messages[m].blocks = blocks
        }
        chats[c].updated = Date()
    }

    // MARK: Scripted runs: a canned answer, no network

    private func runCanned(chatID: UUID, replyID: UUID) async {
        let answer = Self.cannedAnswer
        var shown = ""
        for word in answer.split(separator: " ", omittingEmptySubsequences: false) {
            if Task.isCancelled { break }
            shown += (shown.isEmpty ? "" : " ") + word
            apply(AIStreamState(text: shown, blocks: [], sources: [], searching: false, stopReason: ""), chatID: chatID, replyID: replyID)
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        finish(chatID: chatID, replyID: replyID, blocks: [])
    }

    static let cannedAnswer = "This is a canned reply from a scripted run — no network is used here.\n\nWith a real key, answers stream in like this, with **bold**, *italic*, `inline code` and lists:\n\n- first point\n- second point"

    // MARK: Saving

    private func save() {
        guard persists else { return }
        saver.call { [weak self] in
            guard let self else { return }
            self.file.save(Array(self.chats.sorted { $0.updated > $1.updated }.prefix(60)))
        }
    }

    // MARK: Samples

    static func sampleChats() -> [AIChat] {
        let now = Date()
        var lisbon = AIChat(provider: .anthropic, model: AIModels.autoID)
        lisbon.title = "A weekend in Lisbon"
        lisbon.updated = now
        lisbon.messages = [
            AIChatMessage(role: .user, text: "Plan a relaxed two-day weekend in Lisbon. I like coffee, tiles and long walks."),
            {
                var m = AIChatMessage(role: .assistant, text: """
                ## A slow weekend in Lisbon

                Here is a plan that keeps the walking easy and the coffee stops frequent.

                **Saturday**
                1. Start in *Alfama* with a coffee at a small café, then wander uphill to the Sé.
                2. Lunch near **Praça do Comércio**.
                3. Visit the National Tile Museum in the afternoon.

                **Sunday**
                - Take tram 28 early, before the queues.
                - Walk along the river to Belém.

                Quick tip for tram tickets — the `Viva Viagem` card works on trams, metro and buses:

                ```swift
                let day = Date().formatted(.dateTime.weekday(.wide))
                print("Enjoy your \\(day) in Lisbon")
                ```

                > Tiles are everywhere: look up at the facades.
                """, model: AIModels.sonnet)
                m.sources = [AISource(title: "Visit Lisbon — official guide", url: "https://www.visitlisboa.com/en"),
                             AISource(title: "National Tile Museum", url: "https://www.museudoazulejo.gov.pt/en")]
                return m
            }(),
        ]
        var old = AIChat(provider: .anthropic, model: "claude-sonnet-5-5")
        old.title = "Explain a regex"
        old.updated = now.addingTimeInterval(-86_400)
        old.messages = [AIChatMessage(role: .user, text: "What does ^\\d{3}-\\d{4}$ match?"),
                        AIChatMessage(role: .assistant, text: "It matches exactly a phone-style number: three digits, a dash, four digits.", model: "claude-sonnet-5-5")]
        var older = AIChat(provider: .openai, model: "gpt-6-astra")
        older.title = "Names for a coffee shop"
        older.updated = now.addingTimeInterval(-3 * 86_400)
        older.messages = [AIChatMessage(role: .user, text: "Five names for a tiny coffee shop"),
                          AIChatMessage(role: .assistant, text: "1. Little Cup\n2. The Slow Pour\n3. Corner Bean\n4. Morning Ledger\n5. Tin Kettle", model: "gpt-6-astra")]
        return [lisbon, old, older]
    }
}
