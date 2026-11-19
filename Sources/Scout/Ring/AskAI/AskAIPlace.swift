import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Where Ask AI opens (the notch or the floating window), how the notch's text field gets the keyboard, and the
// draft (text + pictures) the notch keeps while you move between workspaces.

@MainActor
enum AskAIPlace {
    enum Kind: String, CaseIterable, Identifiable {
        case notch, window
        var id: String { rawValue }
        var title: String { self == .notch ? String(localized: "The notch") : String(localized: "A floating window") }
    }

    nonisolated static let key = "ai.openIn"

    /// The saved choice; until the owner picks one, the notch when the main screen has one (real or virtual).
    static var preferred: Kind {
        if let raw = UserDefaults.standard.string(forKey: key), let kind = Kind(rawValue: raw) { return kind }
        return defaultKind
    }

    static var defaultKind: Kind { mainScreenHasNotch ? .notch : .window }

    static var mainScreenHasNotch: Bool {
        guard let main = NSScreen.screens.first else { return false }
        return main.hasHardwareNotch || (NotchPrefs.virtualNotch && NotchPrefs.screens != .notched)
    }

    /// False when the owner switched Ask AI off in Settings › Notch › Workspaces (older saved lists lack it).
    static var enabledInNotch: Bool { NotchPrefs.workspaces.contains(.askAI) }

    /// The notch on the pointer's screen, if it can be seen (a full-screen app hides it).
    private static var targetController: NotchController? {
        let mouse = NSEvent.mouseLocation
        guard let c = NotchManager.shared.controllers.first(where: { $0.screenFrame.contains(mouse) }) else { return nil }
        return c.model.hiddenForFullscreen ? nil : c
    }

    static var notchAvailable: Bool { enabledInNotch && targetController != nil }

    /// The ring's Ask AI tool (and `scout://tool.askai`): the notch or the window, as the setting says.
    static func open(newChat: Bool = false) {
        if newChat { AIChatStore.shared.newChat() }
        if preferred == .notch, notchAvailable { openNotch(focus: true) } else { AskAIPanel.show() }
    }

    /// The notch on the Ask AI workspace (a tap on the drop-down card or the wings). Falls back to the window.
    static func openNotch(focus: Bool) {
        guard notchAvailable else { AskAIPanel.show(); return }
        if focus { AskAINotchFocus.shared.request() }
        NotchNavigator.shared.open(.askAI)
    }

    /// The notch shows the same chat in the floating window and gets out of the way.
    static func popOut() {
        AskAIPanel.show()
        NotchNavigator.shared.forceClose()
    }

    /// Adds Ask AI (right after the Nook) to a SAVED workspace list that lacks it. Nothing saved = everything is on.
    /// Edits the saved text itself, so workspaces another edition leaves out stay in the list.
    static func enableInNotch() {
        let raw = Pref.string("notch.workspaces", "")
        var parts = raw.split(separator: ",").map(String.init)
        guard parts.contains(where: { WorkspaceKind(rawValue: $0) != nil }), !parts.contains(WorkspaceKind.askAI.rawValue) else { return }
        parts.insert(WorkspaceKind.askAI.rawValue, at: (parts.firstIndex(of: WorkspaceKind.nook.rawValue) ?? -1) + 1)
        Pref.set(parts.joined(separator: ","), "notch.workspaces")
    }

    /// Once: lists saved before Ask AI existed get it, so the owner finds it in the notch. Switching it off later sticks.
    static func addToSavedWorkspaceListOnce() {
        let flag = "ai.notch.listMigrated"
        guard !Pref.bool(flag, false) else { return }
        Pref.set(true, flag)
        enableInNotch()
    }
}

/// How the Ask AI tab holds the notch open.
/// five seconds whatever the pointer does once the tab opens; once you type or switch the Screen share on,
/// until a click outside the notch.
@MainActor
enum AskAITabHold {
    static let openedReason = "askai.opened"
    static let engagedReason = "askai.engaged"
    static let seconds: Double = 5
    private static var token = 0

    /// The tab opened: the notch stays open for `seconds`, the pointer anywhere.
    static func opened(navigator: NotchNavigator = .shared) {
        token += 1
        let mine = token
        navigator.hold(openedReason)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if token == mine { navigator.release(openedReason) }
        }
    }

    /// Typing or the Screen share: the notch stays open until a click outside it.
    static func engaged(navigator: NotchNavigator = .shared) { navigator.hold(engagedReason) }

    /// The tab went away, or a click landed outside the notch: the holds end.
    static func ended(navigator: NotchNavigator = .shared) {
        token += 1
        navigator.release(openedReason)
        navigator.release(engagedReason)
    }
}

/// "Give the text field the keyboard": asked for by the ring (the owner just chose Ask AI, so typing goes there) and by the Ask AI tab key.
/// The view may not exist yet when the request is made, so a request stays valid for a moment.
@MainActor
final class AskAINotchFocus: ObservableObject {
    static let shared = AskAINotchFocus()
    @Published private(set) var token = 0
    private var pendingUntil = Date.distantPast

    func request() {
        pendingUntil = Date().addingTimeInterval(1.5)
        token += 1
    }

    var isPending: Bool { pendingUntil > Date() }
    func consume() { pendingUntil = .distantPast }
}

/// What the owner has typed and attached in the notch but not sent yet. Lives outside the view, so closing the
/// notch or another workspace for a moment loses nothing, and the notch's drop zone can add pictures to it.
@MainActor
final class AskAINotchDraft: ObservableObject {
    static let shared = AskAINotchDraft()
    @Published var text = ""
    @Published var attachments: [String] = []

    var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

    func remove(_ file: String) { attachments.removeAll { $0 == file } }

    func clear() {
        text = ""
        attachments = []
    }

    func add(_ image: NSImage) {
        if let name = AIImages.store(image) { attachments.append(name) }
    }

    func add(contentsOf urls: [URL]) {
        for url in urls { if let image = NSImage(contentsOf: url) { add(image) } }
    }

    func chooseImages() {
        guard !ScoutRuntime.isScripted else { return }
        NotchNavigator.shared.hold("askai.choose")
        defer { NotchNavigator.shared.release("askai.choose") }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        add(contentsOf: panel.urls)
    }

    func pasteImage() {
        guard !ScoutRuntime.isScripted, let image = NSImage(pasteboard: .general) else {
            Toast.show("No image on the clipboard", symbol: "photo", style: .info)
            return
        }
        add(image)
    }

    /// Pictures dropped (files or image data). Returns true when something could be read.
    @discardableResult
    func add(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if let image = NSImage(contentsOf: url) { self.add(image) } else { Toast.show("Ask AI reads pictures only", symbol: "photo", style: .info) }
                        }
                    }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = p.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.add(image) } }
                }
            }
        }
        return handled
    }
}
