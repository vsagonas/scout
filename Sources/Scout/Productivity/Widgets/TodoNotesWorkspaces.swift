import SwiftUI

// The detail the Notes panel expands into, inside the open notch. (The To-dos panel opens the Calendar view, which has the to-do list
// beside the month: Features/Calendar/CalendarTodos.swift.)

/// Notes, full size: the notes on the left (search, newest first), the chosen note's editor on the right.
struct NotesWorkspaceView: View {
    @ObservedObject var store: NotesStore
    @State private var query = ""

    init(store: NotesStore? = nil) { self.store = store ?? NotesStore.shared }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    ProdSearchField(prompt: "Search notes", text: $query)
                    Button { query = ""; store.add() } label: { Image(systemName: "square.and.pencil") }
                        .buttonStyle(NotchIconButtonStyle(size: 28)).help("New note")
                }
                list
            }
            .frame(width: 250)
            Rectangle().fill(NotchInk.hairline).frame(width: 1)
            editorColumn
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .notchContent()
        .onAppear { store.resort() }
    }

    @ViewBuilder private var list: some View {
        let shown = store.search(query)
        if shown.isEmpty {
            NotchEmptyState(symbol: "note.text", message: query.isEmpty ? "No notes yet" : "No matches",
                            actionTitle: query.isEmpty ? "New note" : nil) { store.add() }
        } else {
            ScrollView(.vertical, showsIndicators: false) {
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

    @ViewBuilder private var editorColumn: some View {
        if let note = store.selected {
            VStack(spacing: 0) {
                NoteEditorView(noteID: note.id, store: store)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(NotchInk.tile))
                HStack(spacing: 10) {
                    Text("Edited \(note.modified.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 10.5)).foregroundStyle(NotchInk.tertiary)
                    Spacer()
                    NoteActionsMenu(note: note, store: store)
                }
                .padding(.horizontal, 6).padding(.top, 6)
            }
        } else {
            NotchEmptyState(symbol: "square.and.pencil", message: "Select a note or start a new one", actionTitle: "New note") { store.add() }
        }
    }
}
