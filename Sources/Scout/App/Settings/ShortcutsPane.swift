import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutsSettingsPane: View {
    @State private var refresh = 0   // bumped when a recorder changes a value, so conflict notes update

    var body: some View {
        Form {
            Section {
                ForEach([ShortcutEntry.clipboardShelf, .notch]) { row($0) }
            } header: {
                Text("Open things")
            } footer: {
                SettingsFootnote("A shortcut needs a modifier key (⌘ ⌥ ⌃ ⇧), or can be a function key on its own. Clear one with the ✕ next to it.")
            }
            Section {
                ForEach(ShortcutEntry.workspaceEntries) { row($0) }
            } header: {
                Text("Open a widget full size")
            } footer: {
                SettingsFootnote("Opens the notch with that widget already expanded. Press it again to close. The notch itself always opens on the dashboard.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .id(refresh)
    }

    private func row(_ entry: ShortcutEntry) -> some View {
        let binding = Binding<KeyCombo?>(get: { entry.combo }, set: { entry.save($0); refresh += 1 })
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: entry.symbol).frame(width: 20).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                if let detail = entry.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                if let note = Self.conflict(for: entry) { Text(note).font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            ShortcutRecorder(combo: binding)
        }
    }

    /// A warning when another Scout shortcut, or a well-known macOS one, already uses this combo.
    static func conflict(for entry: ShortcutEntry) -> String? {
        guard let combo = entry.combo else { return nil }
        if let other = ShortcutEntry.all.first(where: { $0.id != entry.id && $0.combo == combo }) {
            return String(localized: "Also used for “\(other.title)”: only one of them will work.")
        }
        let system: [(KeyCombo, String)] = [   // each with its whole sentence, so a translator can reorder the words
            (KeyCombo(keyCode: UInt32(kVK_Space), modifiers: .command), String(localized: "macOS uses this for Spotlight; it may not reach Scout.")),
            (KeyCombo(keyCode: UInt32(kVK_Space), modifiers: .control), String(localized: "macOS uses this for switching the input language; it may not reach Scout.")),
            (KeyCombo(keyCode: UInt32(kVK_Space), modifiers: [.command, .option]), String(localized: "macOS uses this for Finder search; it may not reach Scout.")),
            (KeyCombo(keyCode: UInt32(kVK_Space), modifiers: [.command, .control]), String(localized: "macOS uses this for the emoji picker; it may not reach Scout.")),
            (KeyCombo(keyCode: UInt32(kVK_Tab), modifiers: .command), String(localized: "macOS uses this for the app switcher; it may not reach Scout.")),
            (KeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: [.command, .shift]), String(localized: "macOS uses this for screenshots; it may not reach Scout.")),
            (KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: [.command, .shift]), String(localized: "macOS uses this for screenshots; it may not reach Scout.")),
            (KeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: [.command, .shift]), String(localized: "macOS uses this for screenshots; it may not reach Scout.")),
            (KeyCombo(keyCode: UInt32(kVK_ANSI_Q), modifiers: [.command, .control]), String(localized: "macOS uses this for locking the screen; it may not reach Scout.")),
        ]
        if let hit = system.first(where: { $0.0 == combo }) { return hit.1 }
        return nil
    }
}
