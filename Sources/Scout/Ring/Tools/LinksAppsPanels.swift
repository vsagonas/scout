import AppKit
import SwiftUI

@MainActor
enum LinksPanel {
    static func show() {
        ToolPanels.show("links", size: CGSize(width: 400, height: 440), minSize: CGSize(width: 340, height: 300), resizable: true) {
            LinksView(text: ToolMemory.string(ToolMemory.linksSearch) ?? "")
        }
    }
}

@MainActor
enum AppsPanel {
    static func show() {
        ToolPanels.show("apps", size: CGSize(width: 360, height: 270), position: .nearPointer, closesWhenInactive: true) {
            AppsLauncherView()
        }
    }
}

// MARK: - Links

struct LinksView: View {
    @ObservedObject var store: LinksStore
    @State private var text: String
    @State private var copiedLink: String?
    @FocusState private var focused: Bool

    init(store: LinksStore? = nil, text: String = "") {
        self.store = store ?? LinksStore.shared
        _text = State(initialValue: text)
    }

    private var typedURL: URL? { LinksStore.normalize(text) }
    private var shown: [SavedLink] { typedURL == nil ? store.search(text) : store.links }

    var body: some View {
        ToolPanelFrame("Links", symbol: "link") {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: typedURL == nil ? "magnifyingglass" : "plus.circle.fill")
                        .foregroundStyle(typedURL == nil ? Color.secondary : Theme.accent)
                    TextField("Paste a link to save it, or search", text: $text).textFieldStyle(.plain).font(.system(size: 13))
                        .focused($focused).onSubmit(add)
                    if typedURL != nil {
                        Text("↩ Save").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
                .padding(.horizontal, 12)

                if let copiedLink, typedURL == nil, text.isEmpty, !store.links.contains(where: { $0.url == copiedLink }) {
                    Button { store.add(copiedLink); self.copiedLink = nil } label: {
                        Label("Save the copied link — \(URL(string: copiedLink)?.host ?? copiedLink)", systemImage: "doc.on.clipboard")
                            .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent.opacity(0.18)))
                    }
                    .buttonStyle(.plain).padding(.horizontal, 12)
                }

                if shown.isEmpty {
                    ToolEmptyState(symbol: "link", message: text.isEmpty ? String(localized: "No saved links yet.\nPaste one above.") : String(localized: "No matches."))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(shown) { link in LinkRow(link: link, store: store) }
                        }
                        .padding(.horizontal, 6)
                    }
                }
            }
            .padding(.bottom, 10)
        }
        .onAppear {
            focused = true
            if !ScoutRuntime.isScripted, let s = NSPasteboard.general.string(forType: .string), LinksStore.normalize(s) != nil {
                copiedLink = LinksStore.normalize(s)?.absoluteString
            } else if ScoutRuntime.isGallery {
                copiedLink = "https://www.example.com/copied-article"
            }
        }
        .onChange(of: text) { _, new in ToolMemory.set(new, ToolMemory.linksSearch) }
    }

    private func add() {
        guard typedURL != nil, store.add(text) else { return }
        text = ""
    }
}

struct LinkRow: View {
    let link: SavedLink
    @ObservedObject var store: LinksStore
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe").font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
            VStack(alignment: .leading, spacing: 1) {
                Text(link.displayTitle).font(.system(size: 13)).lineLimit(1)
                Text(verbatim: "\(link.host) · \(ToolFormat.ago(link.date))").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                Button { store.delete(link.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Delete")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { store.open(link) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open") { store.open(link) }
            Button("Copy link") {
                if !ScoutRuntime.isScripted { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link.url, forType: .string) }
            }
            Divider()
            Button("Delete", role: .destructive) { store.delete(link.id) }
        }
    }
}

// MARK: - Apps

struct AppsLauncherView: View {
    @ObservedObject var store: PinnedAppsStore = .shared
    @Environment(\.panelID) private var panelID

    var body: some View {
        ToolPanelFrame("Apps", symbol: "square.grid.2x2", accessory: {
            Button { store.chooseApp() } label: { Image(systemName: "plus.circle").font(.system(size: 14)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Pin an app").disabled(store.isFull)
        }) {
            if store.apps.isEmpty {
                ToolEmptyState(symbol: "square.grid.2x2", message: String(localized: "No pinned apps yet."), actionTitle: String(localized: "Pin an app")) { store.chooseApp() }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 10) {
                    ForEach(store.apps) { app in
                        Button {
                            if let panelID { Panels.close(panelID) }
                            store.open(app)
                        } label: {
                            VStack(spacing: 5) {
                                Image(nsImage: AppIcons.icon(forPath: app.path)).resizable().frame(width: 44, height: 44)
                                Text(app.name).font(.system(size: 10.5)).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu { Button("Unpin", role: .destructive) { store.remove(app) } }
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
                Spacer(minLength: 0)
            }
        }
    }
}
