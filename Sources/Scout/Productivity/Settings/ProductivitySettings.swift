import AppKit
import SwiftUI

// B4 settings pages: Clipboard, Timers & Pomodoro, Notes & To-dos.

// MARK: - Clipboard

struct ClipboardSettingsPane: View {
    @ObservedObject private var store = ClipboardStore.shared
    @AppStorage("clip.enabled") private var enabled = true
    @AppStorage("clip.retention") private var retention = "week"
    @AppStorage("clip.limit") private var limit = 200
    @AppStorage("clip.skipConfidential") private var skipConfidential = true
    @AppStorage("clip.pasteOnPick") private var pasteOnPick = true
    @AppStorage("clip.ignoredApps") private var ignoredRaw = StoredList.encode(ClipboardStore.defaultIgnoredApps)
    @State private var shelfHotkey = ComboStorageBinding.binding("clip.shelfHotkey", default: .shiftCommandV)
    @State private var confirmClear = false
    @State private var accessibilityOK = Permissions.accessibilityGranted

    private var ignored: [String] { StoredList.decode(ignoredRaw) }

    var body: some View {
        BPage(intro: "Scout remembers what you copy so you can paste it again from the notch or the bottom shelf. Everything stays on this Mac.") {
            BSection(title: "History") {
                BToggleRow(title: "Keep a clipboard history", isOn: $enabled)
                BToggleRow(title: "Paused", subtitle: "Nothing new is saved while this is on. Also in the menu bar.", isOn: $store.isPaused)
                BRow(title: "Keep items for") {
                    Picker("", selection: $retention) { ForEach(ClipboardRetention.allCases) { Text($0.title).tag($0.rawValue) } }.labelsHidden().frame(width: 140)
                }
                BRow(title: "Most items to keep", subtitle: "Pinned and favorite items never expire or count toward this.") {
                    BStepper(value: $limit, range: 20...1000, step: 20)
                }
                BToggleRow(title: "Skip confidential copies", subtitle: "Passwords copied from password managers are marked hidden by those apps.", isOn: $skipConfidential)
            }
            .opacity(enabled ? 1 : 0.55)
            BSection(title: "Picking an item", footer: accessibilityOK || !pasteOnPick ? nil : "Allow Accessibility so Scout can press ⌘V for you. Without it the item is only copied.") {
                BToggleRow(title: "Paste into the app you were in", subtitle: "Off: picking only copies the item.", isOn: $pasteOnPick)
                BRow(title: "Bottom shelf shortcut", subtitle: "A wide shelf of cards sliding up from the bottom of the screen.") { ShortcutRecorder(combo: shelfHotkey) }
                if pasteOnPick, !accessibilityOK {
                    BActionRow(title: "Allow Accessibility…", symbol: "lock.shield") {
                        Permissions.requestAccessibility()
                        Permissions.openSettings(.accessibility)
                    }
                }
            }
            BSection(title: "Ignored apps", footer: "Copies made while one of these apps is in front are never saved.") {
                ForEach(ignored, id: \.self) { id in
                    BRow(title: .verbatim(AppIcons.name(forBundleID: id)), subtitle: id == AppIcons.name(forBundleID: id) ? nil : .verbatim(id)) {
                        HStack(spacing: 8) {
                            if let icon = AppIcons.icon(forBundleID: id) { Image(nsImage: icon).resizable().frame(width: 20, height: 20) }
                            Button { ignoredRaw = StoredList.encode(ignored.filter { $0 != id }) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                }
                BActionRow(title: "Add app…", symbol: "plus.circle", action: addIgnoredApp)
            }
            BSection(title: "Data") {
                BRow(title: "Items saved: \(store.items.count)")
                BActionRow(title: "Clear history…", symbol: "trash", role: .destructive) { confirmClear = true }
            }
        }
        .alert("Clear the clipboard history?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { store.clear(keepingPinned: true) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Pinned items stay.") }
        .onAppear { accessibilityOK = Permissions.accessibilityGranted }
    }

    private func addIgnoredApp() {
        guard !ScoutRuntime.isScripted else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "Ignore")
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier, !ignored.contains(id) else { return }
        ignoredRaw = StoredList.encode(ignored + [id])
    }
}

// MARK: - Timers & Pomodoro

struct ClockSettingsPane: View {
    @AppStorage("clock.pomo.work") private var work = 25
    @AppStorage("clock.pomo.short") private var shortBreak = 5
    @AppStorage("clock.pomo.long") private var longBreak = 15
    @AppStorage("clock.pomo.every") private var every = 4
    @AppStorage("clock.pomo.autoStart") private var autoStart = false
    @AppStorage("clock.soundOn") private var soundOn = true
    @AppStorage("clock.sound") private var sound = "Glass"

    var body: some View {
        BPage(intro: "A running timer or Pomodoro shows its countdown beside the notch. When time is up Scout rings and drops a card with Stop and Snooze.") {
            BSection(title: "Pomodoro") {
                BRow(title: "Focus session") { BStepper(value: $work, range: 1...120, unit: String(localized: "min")) }
                BRow(title: "Short break") { BStepper(value: $shortBreak, range: 1...60, unit: String(localized: "min")) }
                BRow(title: "Long break") { BStepper(value: $longBreak, range: 1...90, unit: String(localized: "min")) }
                BRow(title: "Long break after", subtitle: "Focus sessions in a row.") { BStepper(value: $every, range: 2...10) }
                BToggleRow(title: "Start the next phase automatically", isOn: $autoStart)
            }
            BSection(title: "Sound") {
                BToggleRow(title: "Ring when time is up", isOn: $soundOn)
                BRow(title: "Sound") {
                    HStack(spacing: 8) {
                        Picker("", selection: $sound) { ForEach(ProdSound.names, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 130)
                        Button { ProdSound.play(sound) } label: { Image(systemName: "play.fill") }.help("Preview")
                    }
                }
                .opacity(soundOn ? 1 : 0.5)
            }
            BSection(title: "Alarms", footer: "Alarms ring at the set time, once or every day. Add and remove them here or in the Clock tool.") {
                AlarmsTabView(clock: .shared).frame(height: 300).padding(.vertical, 8)
            }
        }
    }
}

// MARK: - Notes & To-dos

struct NotesTodoSettingsPane: View {
    @AppStorage("notes.fontSize") private var fontSize = 13
    @AppStorage("notes.exportFormat") private var exportFormat = "md"
    @AppStorage("todo.showCompleted") private var showCompleted = true
    @AppStorage("todo.autoClearDays") private var autoClear = 0
    @ObservedObject private var notes = NotesStore.shared
    @ObservedObject private var todos = TodoStore.shared

    var body: some View {
        BPage(intro: "Notes and to-dos are saved on this Mac and shown in the notch's widgets and views.") {
            BSection(title: "Notes") {
                BRow(title: "Text size") { BStepper(value: $fontSize, range: 11...20, unit: "pt") }
                BRow(title: "Quick export format", subtitle: "Used by the share button in the Notes widget.") {
                    Picker("", selection: $exportFormat) { ForEach(NotesStore.ExportFormat.allCases) { Text($0.title).tag($0.rawValue) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                }
                BRow(title: "Notes saved: \(notes.notes.count)")
                BActionRow(title: "Open Notes", symbol: "note.text") { NotesPanel.show() }
            }
            BSection(title: "To-dos") {
                BToggleRow(title: "Show completed tasks", subtitle: "In the To-do list and the To-dos widget.", isOn: $showCompleted)
                BRow(title: "Clear completed tasks after") {
                    Picker("", selection: $autoClear) {
                        Text("Never").tag(0); Text("1 day").tag(1); Text("1 week").tag(7); Text("1 month").tag(30)
                    }
                    .labelsHidden().frame(width: 120)
                }
                BRow(title: "\(todos.openCount) open, \(todos.doneTasks.count) done")
                BActionRow(title: "Open To-do", symbol: "checklist") { TodoPanel.show() }
            }
        }
    }
}
