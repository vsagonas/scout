import AppKit
import SwiftUI

/// Tray workspace: a row of file cards (QuickLook thumbnails). Click to select (⌘ and ⇧ extend), drag out,
/// double-click opens, right-click for more. Toolbar: AirDrop, Show in Finder, Convert, Remove.
struct TrayWorkspaceView: View {
    @ObservedObject private var store: TrayStore
    @State private var targeted = false
    @State private var lastClicked: UUID?

    @MainActor init(store: TrayStore? = nil) { _store = ObservedObject(wrappedValue: store ?? TrayStore.shared) }

    private var targets: [URL] { store.targetURLs() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
            VideoBanner()
            if store.convertBarOpen && !store.items.isEmpty { convertBar }
            if store.items.isEmpty { emptyState } else { cards }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.accent.opacity(targeted ? 0.9 : 0), lineWidth: 2).padding(4))
        .animation(Theme.quick, value: targeted)
        .notchContent()
        .onDrop(of: DropReader.acceptedTypes, isTargeted: $targeted) { providers in
            Task { await TrayDrop.handle(providers, into: store, opensTray: false) }
            return true
        }
        .onAppear { store.start(); store.refresh(); VideoOfferHook.trayOpened() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.full").foregroundStyle(Theme.accent)
            Text("Tray").font(.system(size: 13, weight: .semibold))
            if !store.items.isEmpty {
                (store.selection.isEmpty ? Text("Items: \(store.items.count)") : Text("Selected: \(store.selection.count)"))
                    .font(.system(size: 11)).foregroundStyle(NotchInk.secondary)
            }
            Spacer()
            if !store.items.isEmpty {
                Button { store.airDrop(airDropItems()) } label: { Label("AirDrop", systemImage: "airplayaudio") }.buttonStyle(.notchPillCompact)
                Button { store.showInFinder(targets) } label: { Label("Show in Finder", systemImage: "folder") }.buttonStyle(.notchPillCompact)
                Button { store.convertBarOpen.toggle() } label: { Label("Convert", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(NotchPillButtonStyle(prominent: store.convertBarOpen, compact: true))
                Button { removeTargets() } label: { Label(store.selection.isEmpty ? "Clear" : "Remove", systemImage: "xmark.bin") }.buttonStyle(.notchPillCompact)
            }
        }
        .frame(height: 24)
    }

    private func removeTargets() {
        if store.selection.isEmpty { store.clear() } else { store.remove(ids: store.selection) }
    }

    private func airDropItems() -> [Any] {
        let chosen = store.selection.isEmpty ? store.items : store.selectedItems()
        return chosen.compactMap { item -> Any? in
            guard let url = store.url(for: item) else { return nil }
            if item.kind == .link, let data = try? Data(contentsOf: url), let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let text = plist["URL"] as? String, let link = URL(string: text) { return link }
            return url
        }
    }

    // MARK: Convert bar

    private var convertBar: some View {
        let urls = targets
        let formats = Converter.formats(for: urls)
        return HStack(spacing: 6) {
            Text(verbatim: Converter.convertTitle(urls)).font(.system(size: 11, weight: .medium)).foregroundStyle(NotchInk.secondary)
            ForEach(formats) { f in
                NotchChip(title: Text(verbatim: f.title), symbol: f.symbol) { store.convert(urls, to: f) }
            }
            if store.converting > 0 { ProgressView().controlSize(.small).scaleEffect(0.8) }
            Spacer()
        }
        .frame(height: 24)
    }

    // MARK: Cards

    private var cards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(store.items) { item in TrayCell(item: item, store: store, lastClicked: $lastClicked, thumb: store.convertBarOpen ? 62 : 86) }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.clear.contentShape(Rectangle()).onTapGesture { store.selection = [] })
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 26, weight: .light)).foregroundStyle(targeted ? Theme.accent : NotchInk.tertiary)
            Text("Drop files here").font(.system(size: 13, weight: .semibold))
            Text("They stay where they are. Drag them out when you're ready, or convert and AirDrop them.")
                .font(.system(size: 11)).foregroundStyle(NotchInk.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4])).foregroundStyle(NotchInk.tertiary))
    }
}

/// One file card.
struct TrayCell: View {
    let item: TrayItem
    @ObservedObject var store: TrayStore
    @Binding var lastClicked: UUID?
    var thumb: CGFloat = 66

    private var url: URL? { store.url(for: item) }
    private var selected: Bool { store.selection.contains(item.id) }
    private var isMissing: Bool { store.missing.contains(item.id) }

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                if let url, !isMissing {
                    FileThumbnail(url: url, side: thumb).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Image(systemName: "questionmark.folder").font(.system(size: 30, weight: .light)).foregroundStyle(NotchInk.tertiary).frame(width: thumb, height: thumb)
                }
                if item.kind == .link { badge("link") } else if item.kind == .text { badge("text.alignleft") } else if item.kind == .converted { badge("arrow.triangle.2.circlepath") }
            }
            (isMissing ? Text("Missing") : Text(verbatim: item.name)).font(.system(size: 10, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
                .foregroundStyle(isMissing ? NotchInk.tertiary : NotchInk.primary).frame(width: thumb + 18, height: 26, alignment: .top)
        }
        .padding(.vertical, 6).padding(.horizontal, 6)
        .frame(width: thumb + 30)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Theme.accent.opacity(0.22) : NotchInk.tile))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent, lineWidth: selected ? 1.5 : 0))
        .opacity(isMissing ? 0.6 : 1)
        .overlay(CellInteraction(dragURLs: dragURLs, onMouseDown: mouseDown, onClickWithoutDrag: clickUp, onDoubleClick: open, makeMenu: menu))
        .help(url.map { Text(verbatim: $0.path) } ?? Text("This file is gone"))
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
            .padding(3).background(Circle().fill(Color.black.opacity(0.65))).offset(x: 3, y: 3)
    }

    // MARK: Interaction

    private func dragURLs() -> [URL] {
        if selected { return store.selectedURLs() }
        return url.map { [$0] } ?? []
    }

    private func mouseDown(_ mods: NSEvent.ModifierFlags) {
        if mods.contains(.command) {
            if selected { store.selection.remove(item.id) } else { store.selection.insert(item.id) }
        } else if mods.contains(.shift), let last = lastClicked,
                  let a = store.items.firstIndex(where: { $0.id == last }), let b = store.items.firstIndex(where: { $0.id == item.id }) {
            for i in min(a, b)...max(a, b) { store.selection.insert(store.items[i].id) }
        } else if !selected {
            store.selection = [item.id]
        }
        lastClicked = item.id
    }

    private func clickUp(_ mods: NSEvent.ModifierFlags) {
        if !mods.contains(.command), !mods.contains(.shift) { store.selection = [item.id] }
    }

    private func open() {
        guard let url, !ScoutRuntime.isScripted else { return }
        NSWorkspace.shared.open(url)
    }

    private func menu() -> NSMenu? {
        if !selected { store.selection = [item.id] }
        let targets = store.selectedURLs()
        let m = NSMenu()
        m.addItem(BlockMenuItem(String(localized: "Open"), symbol: "arrow.up.forward.app") { [store] in store.selectedURLs().forEach { if !ScoutRuntime.isScripted { NSWorkspace.shared.open($0) } } })
        m.addItem(BlockMenuItem(String(localized: "Show in Finder"), symbol: "folder") { [store] in store.showInFinder(targets) })
        m.addItem(BlockMenuItem(String(localized: "AirDrop…"), symbol: "airplayaudio") { [store] in store.airDrop(targets) })
        m.addItem(BlockMenuItem(String(localized: "Convert…"), symbol: "arrow.triangle.2.circlepath") { [store] in store.convertBarOpen = true })
        m.addItem(BlockMenuItem(String(localized: "Copy"), symbol: "doc.on.doc") {
            guard !ScoutRuntime.isScripted else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(targets as [NSURL])
        })
        m.addItem(.separator())
        m.addItem(BlockMenuItem(String(localized: "Remove from Tray"), symbol: "xmark.bin") { [store] in store.remove(ids: store.selection) })
        return m
    }
}
