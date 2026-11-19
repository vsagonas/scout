#if !APPSTORE
import AppKit
@preconcurrency import Contacts
import SwiftUI

/// Shows new messages as a card under the notch, and lets you answer from it.
/// Off until the user turns it on. Needs Full Disk Access to read Messages' database.
/// NEVER sends anything in scripted runs.
@MainActor
final class MessagesService: ObservableObject {
    static let shared = MessagesService()

    enum Key {
        static let enabled = "msg.enabled"
        static let showText = "msg.showText"         // false = only "New message"
        static let cardSeconds = "msg.cardSeconds"
        static let contacts = "msg.contacts"         // names and photos from Contacts
    }

    enum Access: Equatable { case off, needsFullDiskAccess, ready, sample }

    @Published private(set) var access: Access = .off
    private var timer: Timer?
    private var db: ChatDB?
    private var lastRow: Int64 = 0
    private var polling = false
    private var lastEnabled: Bool?
    private let queue = DispatchQueue(label: "scout.messages", qos: .utility)
    private var models: [Int64: MessageCardModel] = [:]

    // MARK: Lifecycle

    func start() {
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        settingsChanged()
    }

    private func settingsChanged() {
        let enabled = Pref.bool(Key.enabled, false)
        guard lastEnabled != enabled else { return }
        lastEnabled = enabled
        enabled ? begin() : end()
    }

    func recheckAccess() {
        if ScoutRuntime.isScripted { access = .sample; return }
        guard Pref.bool(Key.enabled, false) else { access = .off; return }
        access = ChatDB() == nil ? .needsFullDiskAccess : .ready
    }

    private func begin() {
        if ScoutRuntime.isScripted { access = .sample; return }
        queue.async { [weak self] in
            let opened = ChatDB()
            Task { @MainActor in
                guard let self else { return }
                guard let opened else { self.access = .needsFullDiskAccess; return }
                self.db = opened
                self.lastRow = opened.maxRowID() ?? 0      // only messages that arrive from now on
                self.access = .ready
                self.timer?.invalidate()
                self.timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.poll() }
                }
            }
        }
    }

    private func end() {
        timer?.invalidate()
        timer = nil
        db = nil
        access = Pref.bool(Key.enabled, false) ? access : (ScoutRuntime.isScripted ? .sample : .off)
    }

    // MARK: Polling

    private func poll() {
        guard !polling, let db else { return }
        polling = true
        let after = lastRow
        queue.async { [weak self] in
            let found = db.messages(after: after)
            Task { @MainActor in
                guard let self else { return }
                self.polling = false
                if let last = found.last { self.lastRow = max(self.lastRow, last.id) }
                for message in found { self.deliver(message) }
            }
        }
    }

    private func isMessagesInFront() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.MobileSMS"
    }

    func deliver(_ message: IncomingMessage) {
        if isMessagesInFront(), !ScoutRuntime.isScripted { return }
        let model = MessageCardModel(message: message, showText: Pref.bool(Key.showText, true))
        models[message.id] = model
        ContactLookup.shared.resolve(handle: message.handle) { [weak model] info in
            model?.apply(info)
        }
        present(model, seconds: Double(Pref.int(Key.cardSeconds, 8)))
    }

    /// (Re)posts the card. Called again with a longer time while you type a reply.
    func present(_ model: MessageCardModel, seconds: Double) {
        LiveActivityCenter.shared.present(NotchCard(id: "message.\(model.message.id)", kind: .message, duration: seconds, onTap: nil) {
            MessageCardView(model: model)
        })
    }

    // MARK: Replying

    /// Sends the typed reply through the Messages app. Scripted runs only pretend.
    func send(_ model: MessageCardModel) {
        let text = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if ScoutRuntime.isScripted {
            model.status = .sent
            model.draft = ""
            return
        }
        guard let guid = model.message.chatGUID else { model.status = .failed(String(localized: "Can't tell which chat this is")); return }
        let ok = AppleScript.run(Self.sendScript(text: text, chatGUID: guid)) == "sent"
        model.status = ok ? .sent : .failed(String(localized: "Messages didn't accept the reply. Allow Scout to control Messages in System Settings › Privacy & Security › Automation."))
        if ok { model.draft = "" }
    }

    /// `send` to a chat by its id works for one-to-one chats, groups and SMS alike.
    nonisolated static func sendScript(text: String, chatGUID: String) -> String {
        """
        tell application "Messages"
            set theChat to chat id "\(escape(chatGUID))"
            send "\(escape(text))" to theChat
            return "sent"
        end tell
        """
    }

    nonisolated static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Sample

    func demo() {
        let samples = [
            IncomingMessage(id: -1, text: String(localized: "Are we still on for dinner at 7? I booked the corner table."), handle: "+15551230101", chatGUID: "iMessage;-;+15551230101",
                            groupName: nil, isGroup: false, date: Date(), hasAttachment: false),
        ]
        for m in samples { deliver(m) }
    }
}

// MARK: - Card model and view

@MainActor
final class MessageCardModel: ObservableObject {
    enum Status: Equatable { case idle, sent, failed(String) }

    let message: IncomingMessage
    let showText: Bool
    @Published var name: String
    @Published var photo: NSImage?
    @Published var draft = ""
    @Published var status: Status = .idle

    init(message: IncomingMessage, showText: Bool) {
        self.message = message
        self.showText = showText
        name = ContactLookup.pretty(message.handle)
    }

    func apply(_ info: ContactLookup.Info) {
        if let n = info.name { name = n }
        if let p = info.photo { photo = p }
    }
}

struct MessageCardView: View {
    @ObservedObject var model: MessageCardModel
    @FocusState private var focused: Bool

    private var title: String { model.message.groupName.map { String(localized: "\(model.name) in \($0)") } ?? model.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Avatar(name: model.name, photo: model.photo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    (model.showText ? Text(verbatim: model.message.text) : Text("New message"))
                        .font(.system(size: 12)).foregroundStyle(model.showText ? .primary : .secondary).lineLimit(3)
                }
                Spacer(minLength: 0)
                Image(systemName: "message.fill").foregroundStyle(.green).font(.system(size: 12))
            }
            switch model.status {
            case .sent:
                Label("Sent", systemImage: "checkmark.circle.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
            case .failed(let why):
                Text(why).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                reply
            case .idle:
                reply
            }
        }
        .padding(12)
        .frame(width: 360)
    }

    private var reply: some View {
        HStack(spacing: 6) {
            TextField("Reply", text: $model.draft)
                .textFieldStyle(.roundedBorder).controlSize(.small).focused($focused)
                .onSubmit { MessagesService.shared.send(model) }
                .onChange(of: focused) {
                    if focused {
                        NotchNavigator.shared.hold("message.reply")
                        MessagesService.shared.present(model, seconds: 45)
                    } else {
                        NotchNavigator.shared.release("message.reply")
                    }
                }
            Button { MessagesService.shared.send(model) } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)) }
                .buttonStyle(.plain).foregroundStyle(model.draft.isEmpty ? Color.secondary : Theme.accent)
                .disabled(model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

struct Avatar: View {
    let name: String
    let photo: NSImage?
    var size: CGFloat = 36

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2).compactMap(\.first)
        let text = String(parts).uppercased()
        return text.isEmpty || !(text.first?.isLetter ?? false) ? "#" : text
    }

    var body: some View {
        Group {
            if let photo { Image(nsImage: photo).resizable().scaledToFill() } else {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.55, green: 0.62, blue: 0.78), Color(red: 0.38, green: 0.44, blue: 0.62)], startPoint: .top, endPoint: .bottom)
                    Text(initials).font(.system(size: size * 0.38, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

// MARK: - Contacts (optional)

/// Names and photos from Contacts. Only asks macOS when the user turns "Use Contacts" on; never in scripted runs.
@MainActor
final class ContactLookup {
    static let shared = ContactLookup()

    struct Info { var name: String?; var photo: NSImage? }

    private var cache: [String: Info] = [:]
    private let store = CNContactStore()

    static func pretty(_ handle: String) -> String {
        handle.isEmpty ? String(localized: "Someone") : handle
    }

    var authorized: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }

    func requestAccess(_ done: @escaping (Bool) -> Void) {
        guard !ScoutRuntime.isScripted else { done(false); return }
        store.requestAccess(for: .contacts) { granted, _ in Task { @MainActor in done(granted) } }
    }

    func resolve(handle: String, _ done: @escaping (Info) -> Void) {
        guard Pref.bool(MessagesService.Key.contacts, false), !ScoutRuntime.isScripted, authorized, !handle.isEmpty else { return }
        if let hit = cache[handle] { done(hit); return }
        let store = self.store
        DispatchQueue.global(qos: .utility).async {
            let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor,
                                           CNContactThumbnailImageDataKey as CNKeyDescriptor]
            let predicate = handle.contains("@") ? CNContact.predicateForContacts(matchingEmailAddress: handle)
                                                 : CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: handle))
            let contacts = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
            let info = contacts.first.map { c -> Info in
                let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                return Info(name: name.isEmpty ? nil : name, photo: c.thumbnailImageData.flatMap { NSImage(data: $0) })
            } ?? Info()
            Task { @MainActor in
                self.cache[handle] = info
                done(info)
            }
        }
    }
}
#endif
