import AppKit
import SwiftUI

// B4 Clipboard in the notch: the workspace (horizontal cards + search + filters), the compact widget, and the
// card itself (shared with the bottom shelf).

enum ClipboardPicking {
    /// Picks an item from a notch surface: close the notch first so the app you were in stays frontmost.
    @MainActor
    static func pick(_ item: ClipboardItem, store: ClipboardStore) {
        NotchNavigator.shared.forceClose()
        store.pick(item)
    }
}

struct ClipboardCard: View {
    let item: ClipboardItem
    var width: CGFloat = 132
    var height: CGFloat = 108
    var large = false
    @ObservedObject var store: ClipboardStore
    var onPick: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: item.kind.symbol).font(.system(size: large ? 11 : 10)).foregroundStyle(.secondary)
                Text(item.kind.singularTitle).font(.system(size: large ? 11 : 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                if item.isPinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.accent) }
                if item.isFavorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow) }
                SourceAppIcon(bundleID: item.sourceBundleID, size: large ? 15 : 13)
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Text(ProdFormat.age(item.date)).font(.system(size: large ? 10.5 : 9.5)).foregroundStyle(.tertiary)
        }
        .padding(large ? 11 : 9)
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(hovering ? 0.14 : 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hovering ? Theme.accent.opacity(0.7) : Color.primary.opacity(0.06), lineWidth: hovering ? 1.2 : 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onPick)
        .contextMenu {
            Button(item.isPinned ? "Unpin" : "Pin") { store.togglePin(item) }
            Button(item.isFavorite ? "Remove from favorites" : "Add to favorites") { store.toggleFavorite(item) }
            Divider()
            Button("Delete", role: .destructive) { store.delete(item) }
        }
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .text:
            Text(item.text ?? "").font(.system(size: large ? 12.5 : 11)).lineLimit(large ? 6 : 4).multilineTextAlignment(.leading)
        case .link:
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(string: item.text ?? "")?.host?.replacingOccurrences(of: "www.", with: "") ?? "").font(.system(size: large ? 13 : 11.5, weight: .semibold)).lineLimit(1)
                Text(item.text ?? "").font(.system(size: large ? 11 : 10)).foregroundStyle(.secondary).lineLimit(large ? 3 : 2)
            }
        case .image:
            GeometryReader { geo in
                if let image = ClipboardImages.thumbnail(for: item, maxPixel: 320) {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: geo.size.width, height: geo.size.height).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else { Image(systemName: "photo").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        case .file:
            HStack(spacing: 7) {
                if let path = item.filePaths.first { Image(nsImage: AppIcons.icon(forPath: path)).resizable().frame(width: large ? 34 : 28, height: large ? 34 : 28) }
                Text(item.preview).font(.system(size: large ? 12 : 11)).lineLimit(3)
            }
        case .color:
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(item.color ?? .gray)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                Text(item.text ?? "").font(.system(size: large ? 12 : 10.5, design: .monospaced))
            }
        }
    }
}

/// A row of cards with search and filter chips. Used by the workspace; the bottom shelf passes bigger cards.
struct ClipboardCardStrip: View {
    @ObservedObject var store: ClipboardStore
    var query: String
    var filter: ClipboardItem.Kind?
    var cardWidth: CGFloat = 132
    var cardHeight: CGFloat = 108
    var large = false
    var onPick: (ClipboardItem) -> Void

    var body: some View {
        let items = store.ordered(kind: filter, query: query)
        if items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 22, weight: .light)).foregroundStyle(.secondary)
                Text(query.isEmpty && filter == nil ? "Nothing copied yet. Copy something and it will show up here." : "No matches.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: large ? 12 : 8) {
                    ForEach(items) { item in
                        ClipboardCard(item: item, width: cardWidth, height: cardHeight, large: large, store: store) { onPick(item) }
                    }
                }
                .padding(.horizontal, 2).padding(.vertical, 2)
            }
        }
    }
}

struct ClipboardFilterChips: View {
    @Binding var filter: ClipboardItem.Kind?
    var large = false

    var body: some View {
        HStack(spacing: 5) {
            chip(String(localized: "All"), symbol: nil, on: filter == nil) { filter = nil }
            ForEach(ClipboardItem.Kind.allCases, id: \.self) { kind in
                chip(kind.title, symbol: kind.symbol, on: filter == kind) { filter = filter == kind ? nil : kind }
            }
        }
    }

    private func chip(_ title: String, symbol: String?, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let symbol { LookSymbol(name: symbol, size: large ? 11 : 9.5, weight: .regular) }
                Text(title).font(.system(size: large ? 12 : 10.5, weight: .medium))
            }
            .padding(.horizontal, large ? 10 : 7).padding(.vertical, large ? 5 : 3.5)
            .background(Capsule().fill(on ? Theme.accent.opacity(0.3) : Color.primary.opacity(0.08)))
            .foregroundStyle(on ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Workspace

struct ClipboardWorkspaceView: View {
    @ObservedObject var store: ClipboardStore
    @State private var query: String
    @State private var filter: ClipboardItem.Kind?
    @FocusState private var searchFocused: Bool

    init(store: ClipboardStore? = nil, query: String = "", filter: ClipboardItem.Kind? = nil) {
        self.store = store ?? ClipboardStore.shared
        _query = State(initialValue: query)
        _filter = State(initialValue: filter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProdSearchField(prompt: "Search clipboard", text: $query, focus: $searchFocused).frame(width: 190)
                ClipboardFilterChips(filter: $filter)
                Spacer(minLength: 6)
                if store.isPaused {
                    Label("Paused", systemImage: "pause.circle").font(.system(size: 10.5)).foregroundStyle(.orange)
                }
                Button { store.isPaused.toggle() } label: { Image(systemName: store.isPaused ? "play.circle" : "pause.circle").font(.system(size: 14)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(store.isPaused ? "Resume history" : "Pause history")
                Menu {
                    Button("Clear history (keep pinned)") { store.clear(keepingPinned: true) }
                    Button("Clipboard settings…") { SettingsWindowController.shared.show(.clipboard) }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 14)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary)
            }
            ClipboardCardStrip(store: store, query: query, filter: filter, cardWidth: 138, cardHeight: 118) { item in
                ClipboardPicking.pick(item, store: store)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .onChange(of: searchFocused) { _, focused in
            if focused { NotchNavigator.shared.hold("clipboard") } else { NotchNavigator.shared.release("clipboard") }
        }
        .onDisappear { NotchNavigator.shared.release("clipboard") }
    }
}

// MARK: - Widget

struct ClipboardWidgetView: View {
    @ObservedObject var store: ClipboardStore

    init(store: ClipboardStore? = nil) { self.store = store ?? ClipboardStore.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Dash90Title("Clipboard", symbol: "doc.on.clipboard", tint: Retro.Ink.teal) {
                if store.isPaused { Dash90Lamp(text: "paused", color: Retro.Ink.ledYellow).help("History is paused") }
            }
            let items = Array(store.ordered().prefix(4))
            if items.isEmpty {
                DashEmpty(symbol: "doc.on.clipboard", title: "Nothing copied yet", detail: "Copy something and it shows up here.")
            } else {
                Dash90LCD(padding: 3) {
                    VStack(spacing: 0) {
                        ForEach(items) { item in ClipboardWidgetRow(item: item, store: store) }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ClipboardWidgetRow: View {
    let item: ClipboardItem
    @ObservedObject var store: ClipboardStore
    @State private var hovering = false

    var body: some View {
        // One grid row each (`DashGrid.rowHeight`), so four rows and the title fit the 140 pt panel: taller rows pushed the title up out
        // of line with its neighbours' first lines.
        HStack(spacing: 7) {
            ClipboardGlyph(item: item, size: 18)
            Text(item.preview.isEmpty ? item.kind.title : item.preview).font(.system(size: 11.5)).lineLimit(1)
            Spacer(minLength: 2)
            Dash90Text(ProdFormat.age(item.date), pixel: 1, color: Dash90.amber.opacity(0.8))
        }
        .padding(.horizontal, 4)
        .frame(height: DashGrid.rowHeight)
        .background(RoundedRectangle(cornerRadius: 3, style: .circular).fill(hovering ? Look.hoverWash : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { ClipboardPicking.pick(item, store: store) }
        .nookControl()
    }
}
