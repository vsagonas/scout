import AppKit
import SwiftUI

// B2 Clipboard: the picker panel. Search is focused; ↑↓ move, Return pastes into the app you were in, ⌘1–9 picks.

@MainActor
enum ClipboardPickerPanel {
    static func show() {
        // A quick pick starts fresh, except when the panel was just closed (a click away, a mis-key): then the search comes back.
        let m = ToolMemory.load(ClipboardMemory.self, ToolMemory.clipboardState).flatMap { Date().timeIntervalSince($0.date) < 300 ? $0 : nil }
        ToolPanels.show("clipboard", size: CGSize(width: 380, height: 460), minSize: CGSize(width: 320, height: 300), resizable: true,
                        position: .nearPointer, closesWhenInactive: true) {
            ClipboardPickerView(query: m?.query ?? "", filter: m?.kind.flatMap(ClipboardItem.Kind.init(rawValue:)))
        }
    }
}

/// The picker's search and type chip, with the time they were left.
struct ClipboardMemory: Codable, Equatable {
    var query: String
    var kind: String?
    var date = Date()
}

struct ClipboardPickerView: View {
    @ObservedObject var store: ClipboardStore
    @Environment(\.panelID) private var panelID
    @State private var query: String
    @State private var selection = 0
    @State private var filter: ClipboardItem.Kind?
    @FocusState private var searchFocused: Bool

    init(store: ClipboardStore? = nil, query: String = "", filter: ClipboardItem.Kind? = nil) {
        self.store = store ?? ClipboardStore.shared
        _query = State(initialValue: query)
        _filter = State(initialValue: filter)
    }

    private var items: [ClipboardItem] { store.ordered(kind: filter, query: query) }

    var body: some View {
        ToolPanelFrame("Clipboard", symbol: "doc.on.clipboard", accessory: {
            Button { store.isPaused.toggle() } label: {
                Image(systemName: store.isPaused ? "play.circle" : "pause.circle").font(.system(size: 14))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(store.isPaused ? "Resume history" : "Pause history")
        }) {
            VStack(spacing: 8) {
                ToolSearchField(prompt: String(localized: "Search clipboard"), text: $query, focus: $searchFocused)
                    .padding(.horizontal, 12)
                chips
                if store.isPaused {
                    Label("History is paused", systemImage: "pause.circle").font(.system(size: 11)).foregroundStyle(.orange)
                }
                list
            }
            .padding(.bottom, 10)
        }
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in selection = 0; remember() }
        .onChange(of: filter) { _, _ in selection = 0; remember() }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.return) { pickSelected(); return .handled }
        .background(quickPickShortcuts)
    }

    private func remember() {
        ToolMemory.save(query.isEmpty && filter == nil ? nil : ClipboardMemory(query: query, kind: filter?.rawValue), ToolMemory.clipboardState)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("All", symbol: nil, on: filter == nil) { filter = nil }
                ForEach(ClipboardItem.Kind.allCases, id: \.self) { kind in
                    chip(.verbatim(kind.title), symbol: kind.symbol, on: filter == kind) { filter = filter == kind ? nil : kind }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func chip(_ title: LocalizedStringKey, symbol: String?, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10)) }
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(on ? Theme.accent.opacity(0.28) : Color.primary.opacity(0.07)))
            .foregroundStyle(on ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var list: some View {
        let shown = items
        if shown.isEmpty {
            ToolEmptyState(symbol: "doc.on.clipboard", message: query.isEmpty ? String(localized: "Nothing copied yet.\nCopy something and it will show up here.") : String(localized: "No matches for “\(query)”."))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                            ClipboardPickerRow(item: item, index: index, selected: index == selection, store: store) { pick(item) }
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .onChange(of: selection) { _, new in
                    if shown.indices.contains(new) { withAnimation(Theme.quick) { proxy.scrollTo(shown[new].id) } }
                }
            }
        }
    }

    /// Invisible buttons that give ⌘1…⌘9.
    private var quickPickShortcuts: some View {
        ZStack {
            ForEach(1...9, id: \.self) { n in
                Button("") {
                    let list = items
                    if list.indices.contains(n - 1) { pick(list[n - 1]) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
        }
        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false)
    }

    private func move(_ delta: Int) {
        let count = items.count
        guard count > 0 else { return }
        selection = min(count - 1, max(0, selection + delta))
    }

    private func pickSelected() {
        let list = items
        if list.indices.contains(selection) { pick(list[selection]) }
    }

    private func pick(_ item: ClipboardItem) {
        ToolMemory.save(nil as ClipboardMemory?, ToolMemory.clipboardState)   // a finished pick starts fresh next time
        if let panelID { Panels.close(panelID) }
        store.pick(item)
    }
}

struct ClipboardPickerRow: View {
    let item: ClipboardItem
    let index: Int
    let selected: Bool
    @ObservedObject var store: ClipboardStore
    let onPick: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ClipboardGlyph(item: item, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview.isEmpty ? item.kind.title : item.preview)
                    .font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                HStack(spacing: 5) {
                    SourceAppIcon(bundleID: item.sourceBundleID, size: 11)
                    Text(item.sourceName ?? item.kind.title).lineLimit(1)
                    Text(verbatim: "·")
                    Text(ToolFormat.ago(item.date))
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if item.isPinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Theme.accent) }
            if item.isFavorite { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(.yellow) }
            if hovering {
                Button { store.togglePin(item) } label: { Image(systemName: item.isPinned ? "pin.slash" : "pin") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(item.isPinned ? "Unpin" : "Pin")
                Button { store.delete(item) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Delete")
            } else if index < 9 {
                Text(verbatim: "⌘\(index + 1)").font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Theme.accent.opacity(0.22) : (hovering ? Color.primary.opacity(0.06) : .clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onPick)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(item.isPinned ? "Unpin" : "Pin") { store.togglePin(item) }
            Button(item.isFavorite ? "Remove from favorites" : "Add to favorites") { store.toggleFavorite(item) }
            Divider()
            Button("Delete", role: .destructive) { store.delete(item) }
        }
    }
}
