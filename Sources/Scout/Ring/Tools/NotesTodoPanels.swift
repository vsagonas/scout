import AppKit
import SwiftUI

// B2 Notes (scratchpad) and To-do panels. The widgets in the notch reuse `TodoListView` and `NoteEditorView`.

@MainActor
enum NotesPanel {
    static func show(noteID: UUID? = nil) {
        if let noteID { NotesStore.shared.selectedID = noteID }
        NotesStore.shared.resort()
        ToolPanels.show("notes", size: CGSize(width: 600, height: 400), minSize: CGSize(width: 460, height: 300), resizable: true) {
            NotesPanelView()
        }
    }
}

@MainActor
enum TodoPanel {
    static func show() {
        ToolPanels.show("todo", size: CGSize(width: 340, height: 440), minSize: CGSize(width: 300, height: 320), resizable: true) {
            TodoPanelView()
        }
    }
}

// MARK: - Notes

struct NotesPanelView: View {
    @ObservedObject var store: NotesStore = .shared
    @State private var query = ""

    var body: some View {
        ToolPanelFrame("Notes", symbol: "note.text", accessory: {
            Button {
                query = ""
                store.add()
            } label: { Image(systemName: "square.and.pencil").font(.system(size: 13)) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("New note")
        }) {
            HStack(spacing: 0) {
                VStack(spacing: 8) {
                    ToolSearchField(prompt: String(localized: "Search"), text: $query)
                    list
                }
                .frame(width: 200)
                .padding(.leading, 10).padding(.bottom, 10)
                Divider().padding(.vertical, 4)
                editorColumn.padding(.bottom, 10)
            }
        }
    }

    private var list: some View {
        let shown = store.search(query)
        return Group {
            if shown.isEmpty {
                ToolEmptyState(symbol: "note.text", message: query.isEmpty ? String(localized: "No notes yet.") : String(localized: "No matches."),
                               actionTitle: query.isEmpty ? String(localized: "New note") : nil) { store.add() }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(shown) { note in
                            NoteRow(note: note, selected: note.id == store.selectedID)
                                .onTapGesture { store.selectedID = note.id }
                                .contextMenu { Button("Delete", role: .destructive) { store.delete(note.id) } }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var editorColumn: some View {
        if let note = store.selected {
            VStack(spacing: 0) {
                NoteEditorView(noteID: note.id, store: store)
                Divider()
                HStack(spacing: 10) {
                    Text("Edited \(note.modified.formatted(.relative(presentation: .named)))").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    NoteActionsMenu(note: note, store: store)
                }
                .padding(.horizontal, 12).padding(.top, 6)
            }
        } else {
            ToolEmptyState(symbol: "square.and.pencil", message: String(localized: "Select a note or start a new one."), actionTitle: String(localized: "New note")) { store.add() }
        }
    }
}

struct NoteRow: View {
    let note: ScoutNote
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            HStack(spacing: 6) {
                Text(ToolFormat.ago(note.modified)).foregroundStyle(.tertiary)
                (note.snippet.isEmpty ? Text("No more text") : Text(verbatim: note.snippet)).lineLimit(1)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.accent.opacity(0.22) : .clear))
        .contentShape(Rectangle())
    }
}

/// A plain-text editor bound to one note. Edits go to the store as you type (the store saves debounced).
struct NoteEditorView: View {
    let noteID: UUID
    @ObservedObject var store: NotesStore
    @State private var text = ""
    @State private var loadedID: UUID?
    @AppStorage("notes.fontSize") private var fontSize = 13

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: CGFloat(fontSize) + 0.5))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 8).padding(.top, 4)
            .onAppear(perform: load)
            .onChange(of: noteID) { _, _ in load() }
            .onChange(of: text) { _, new in if loadedID == noteID { store.update(noteID, text: new) } }
    }

    private func load() {
        loadedID = nil
        text = store.note(noteID)?.text ?? ""
        loadedID = noteID
    }
}

struct NoteActionsMenu: View {
    let note: ScoutNote
    @ObservedObject var store: NotesStore

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(NotesStore.ExportFormat.allCases) { f in
                    Button("Export as \(f.title)…") { store.export(note, as: f) }
                }
                Divider()
                #if APPSTORE
                Button("Share…") { store.share(note) }
                #else
                Button("Send to Apple Notes") { store.sendToAppleNotes(note) }
                #endif
            } label: { Image(systemName: "square.and.arrow.up") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Export")
            Button { store.delete(note.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Delete note")
        }
    }
}

// MARK: - To-dos

struct TodoPanelView: View {
    @ObservedObject var store: TodoStore = .shared
    @AppStorage("todo.showCompleted") private var showDone = true

    var body: some View {
        ToolPanelFrame("To-do", symbol: "checklist", accessory: {
            HStack(spacing: 8) {
                Text("\(store.openCount) open").font(.system(size: 11)).foregroundStyle(.secondary)
                Button { TodoWindowController.shared.show() } label: { Image(systemName: "calendar").font(.system(size: 13)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Open the to-do calendar")
            }
        }) {
            TodoListView(store: store, showCompleted: $showDone, compact: false)
                .padding(.horizontal, 12).padding(.bottom, 10)
        }
    }
}

/// Add field, checklist, show/hide completed. Used by the panel and the To-dos widget.
struct TodoListView: View {
    @ObservedObject var store: TodoStore
    @Binding var showCompleted: Bool
    var compact: Bool
    @State private var newTitle = ""
    @FocusState private var addFocused: Bool

    var body: some View {
        VStack(spacing: compact ? 4 : 8) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent).font(.system(size: compact ? 13 : 15))
                TextField("Add a task", text: $newTitle).textFieldStyle(.plain).font(.system(size: compact ? 12 : 13.5))
                    .focused($addFocused).onSubmit(add)
            }
            .padding(.horizontal, 8).padding(.vertical, compact ? 4 : 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
            let open = store.openTasks
            let done = showCompleted ? store.doneTasks : []
            if open.isEmpty, done.isEmpty {
                ToolEmptyState(symbol: "checkmark.circle", message: String(localized: "Nothing to do. Enjoy it."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(open) { TodoRow(task: $0, store: store, compact: compact) }
                        ForEach(done) { TodoRow(task: $0, store: store, compact: compact) }
                    }
                }
            }
            if !compact {
                HStack {
                    Toggle("Show completed", isOn: $showCompleted).toggleStyle(.checkbox).font(.system(size: 11.5)).controlSize(.small)
                    Spacer()
                    if !store.doneTasks.isEmpty {
                        Button("Clear completed") { store.clearCompleted() }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear { if !compact { addFocused = true } }
    }

    private func add() {
        store.add(newTitle)
        newTitle = ""
    }
}

struct TodoRow: View {
    let task: TodoTask
    @ObservedObject var store: TodoStore
    var compact: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button { store.toggle(task.id) } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: compact ? 14 : 17)).foregroundStyle(task.done ? Theme.accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .nookControl()
            Text(task.title)
                .font(.system(size: compact ? 12 : 13.5)).lineLimit(compact ? 1 : 2)
                .strikethrough(task.done).foregroundStyle(task.done ? .secondary : .primary)
            Spacer(minLength: 4)
            if task.focusMinutes > 0, !compact {
                Label("\(task.focusMinutes) min", systemImage: "leaf").font(.system(size: 10.5)).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            }
            if hovering {
                Button { store.delete(task.id) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).nookControl()
            }
        }
        .padding(.horizontal, 6).padding(.vertical, compact ? 3 : 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Color.primary.opacity(0.05) : .clear))
        .onHover { hovering = $0 }
    }
}
