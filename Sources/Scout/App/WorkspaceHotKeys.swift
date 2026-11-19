import AppKit
import Carbon.HIToolbox

/// One shortcut the user can set on the Keyboard Shortcuts page.
struct ShortcutEntry: Identifiable {
    let id: String          // the UserDefaults key (a `KeyCombo.stringValue`)
    let title: String
    let detail: String?
    let symbol: String
    let fallback: KeyCombo?

    /// The saved combo: missing = the default, empty string = switched off.
    var combo: KeyCombo? {
        guard let saved = UserDefaults.standard.string(forKey: id) else { return fallback }
        return saved.isEmpty ? nil : KeyCombo(string: saved)
    }

    func save(_ combo: KeyCombo?) {
        UserDefaults.standard.set(combo?.stringValue ?? "", forKey: id)
    }

    static let clipboardShelf = ShortcutEntry(id: "clip.shelfHotkey", title: String(localized: "Clipboard shelf"), detail: String(localized: "Slides up from the bottom of the screen."),
                                              symbol: "doc.on.clipboard", fallback: KeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: [.shift, .command]))
    static let notch = ShortcutEntry(id: "notch.hotkey.toggle", title: String(localized: "Open or close the notch"), detail: nil,
                                     symbol: "rectangle.topthird.inset.filled", fallback: nil)

    /// One shortcut per detail: it opens the notch with that panel expanded (`.nook` = the dashboard itself).
    static func workspace(_ kind: WorkspaceKind) -> ShortcutEntry {
        ShortcutEntry(id: "notch.hotkey.\(kind.rawValue)", title: kind == .nook ? String(localized: "Open the dashboard") : (kind == .todo ? String(localized: "Open the Calendar with the To-dos, full size") : String(localized: "Open \(kind.title), full size")),
                      detail: nil, symbol: kind.symbol, fallback: nil)
    }

    /// The To-dos shortcut is listed only while one is saved: the To-dos are in the Calendar now (it opens the Calendar), which has its own.
    static var workspaceEntries: [ShortcutEntry] {
        WorkspaceKind.available.map(workspace).filter { $0.id != workspace(.todo).id || $0.combo != nil }
    }
    static var all: [ShortcutEntry] { [clipboardShelf, notch] + workspaceEntries }
}

/// Global shortcuts that open the notch: one for open/close, one per panel detail (opens it expanded).
@MainActor
final class WorkspaceHotKeys {
    static let shared = WorkspaceHotKeys()
    private var hotKeys: [String: HotKey] = [:]
    private var signature = ""
    private var observer: NSObjectProtocol?
    private var work: DispatchWorkItem?

    func start() {
        refresh()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
    }

    private func scheduleRefresh() {
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func refresh() {
        let entries = [ShortcutEntry.notch] + ShortcutEntry.workspaceEntries
        let sig = entries.map { "\($0.id)=\($0.combo?.stringValue ?? "-")" }.joined(separator: ";")
        guard sig != signature else { return }
        signature = sig
        hotKeys.removeAll()
        for entry in entries {
            guard let combo = entry.combo, combo.isValidGlobalShortcut else { continue }
            let kind = WorkspaceKind.available.first { ShortcutEntry.workspace($0).id == entry.id }
            let hotKey = HotKey(combo, onPress: {
                MainActor.assumeIsolated {
                    // Ask AI: the owner pressed its key to type, so the input gets the keyboard.
                    if kind == .askAI, !(NotchNavigator.shared.isOpen && NotchNavigator.shared.workspace == .askAI) { AskAINotchFocus.shared.request() }
                    if let kind { NotchNavigator.shared.toggle(kind) } else { NotchNavigator.shared.toggle() }
                }
            })
            if let hotKey { hotKeys[entry.id] = hotKey } else { NSLog("Scout: shortcut \(combo.display) for \(entry.title) is taken") }
        }
    }
}
