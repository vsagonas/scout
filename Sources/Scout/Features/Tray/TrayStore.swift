import AppKit
import SwiftUI

/// The Tray: files parked while you move between apps. Originals are never moved or deleted;
/// dropped text and links become small files in Scout's own tray folder.
@MainActor
final class TrayStore: ObservableObject {
    static let shared = TrayStore(isShared: true)

    enum Key {
        static let activity = "tray.activity"           // show a count next to the notch (default on)
        static let convertDest = "tray.convertDest"      // "alongside" | "tray"
        static let addResults = "tray.addResults"        // put converted files in the Tray (default on)
    }

    @Published private(set) var items: [TrayItem] = []
    @Published private(set) var urls: [UUID: URL] = [:]
    @Published private(set) var missing: Set<UUID> = []
    @Published var selection: Set<UUID> = []
    /// True while the Tray workspace should show its format chips (set by the Convert drop zone).
    @Published var convertBarOpen = false
    @Published private(set) var converting: Int = 0

    private let file: JSONFile<[TrayItem]>
    private let folderName: String
    /// Only the shared store posts live activities and results; gallery previews use their own stores.
    private let isShared: Bool
    private var started = false

    init(fileName: String = "tray.json", folderName: String = "Tray", isShared: Bool = false) {
        file = JSONFile<[TrayItem]>(fileName)
        self.folderName = folderName
        self.isShared = isShared
    }

    var folder: URL { AppPaths.folder(folderName) }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        items = file.load() ?? []
        resolveAll()
        itemsDidChange(save: false)
    }

    private func resolveAll() {
        var resolved: [UUID: URL] = [:]
        var gone: Set<UUID> = []
        var changed = false
        for i in items.indices {
            if let url = resolve(items[i], refreshing: &items[i], changed: &changed) { resolved[items[i].id] = url } else { gone.insert(items[i].id) }
        }
        urls = resolved
        missing = gone
        if changed { file.save(items) }
    }

    private func resolve(_ item: TrayItem, refreshing copy: inout TrayItem, changed: inout Bool) -> URL? {
        if let stored = item.storedName {
            let url = folder.appendingPathComponent(stored)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        guard let data = item.bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: FileScope.resolution, relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        FileScope.begin(url)    // sandboxed edition: keep the file readable while it is in the Tray
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: FileScope.creation, includingResourceValuesForKeys: nil, relativeTo: nil) { copy.bookmark = fresh; changed = true }
        if copy.name != url.lastPathComponent { copy.name = url.lastPathComponent; changed = true }
        return url
    }

    /// Re-checks every item (a file may have been moved or deleted since). Called when the Tray appears.
    func refresh() { resolveAll(); itemsDidChange(save: false) }

    // MARK: Adding

    func url(for item: TrayItem) -> URL? { urls[item.id] }

    func item(id: UUID) -> TrayItem? { items.first { $0.id == id } }

    @discardableResult
    func add(files: [URL], kind: TrayItem.Kind = .file) -> [TrayItem] {
        var added: [TrayItem] = []
        for url in files {
            let standardized = url.standardizedFileURL
            if let existing = urls.first(where: { $0.value.standardizedFileURL == standardized })?.key, let item = item(id: existing) {
                added.append(item)
                continue
            }
            FileScope.begin(url)    // the dropped URL carries access for now; the scoped bookmark keeps it for later
            guard let bookmark = try? url.bookmarkData(options: FileScope.creation, includingResourceValuesForKeys: nil, relativeTo: nil) else { continue }
            let item = TrayItem(name: standardized.lastPathComponent, kind: kind, bookmark: bookmark)
            items.append(item)
            urls[item.id] = standardized
            added.append(item)
        }
        itemsDidChange()
        return added
    }

    @discardableResult
    func add(text: String) -> TrayItem? {
        let url = UniqueName.url(in: folder, base: String(localized: "Dropped Text"), ext: "txt")
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        let item = TrayItem(name: url.lastPathComponent, kind: .text, storedName: url.lastPathComponent)
        items.append(item)
        urls[item.id] = url
        itemsDidChange()
        return item
    }

    @discardableResult
    func add(link: URL) -> TrayItem? {
        let host = (link.host ?? String(localized: "Link")).replacingOccurrences(of: "www.", with: "")
        let url = UniqueName.url(in: folder, base: host, ext: "webloc")
        let plist: [String: Any] = ["URL": link.absoluteString]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              (try? data.write(to: url)) != nil else { return nil }
        let item = TrayItem(name: url.lastPathComponent, kind: .link, storedName: url.lastPathComponent)
        items.append(item)
        urls[item.id] = url
        itemsDidChange()
        return item
    }

    /// Adds whatever a drop brought. Returns the new (or already present) items.
    @discardableResult
    func add(_ things: [DroppedThing]) -> [TrayItem] {
        var result: [TrayItem] = []
        var files: [URL] = []
        for thing in things {
            switch thing {
            case .file(let url): files.append(url)
            case .link(let url): if let i = add(link: url) { result.append(i) }
            case .text(let text): if let i = add(text: text) { result.append(i) }
            }
        }
        if !files.isEmpty { result += add(files: files) }
        return result
    }

    // MARK: Removing (originals are never touched; only files Scout wrote itself are deleted)

    func remove(ids: Set<UUID>) {
        for item in items where ids.contains(item.id) {
            if let stored = item.storedName { try? FileManager.default.removeItem(at: folder.appendingPathComponent(stored)) }
            else if let url = urls[item.id] { FileScope.end(url) }
            urls[item.id] = nil
        }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        itemsDidChange()
    }

    func clear() { remove(ids: Set(items.map(\.id))) }

    // MARK: Selection helpers

    func selectedItems() -> [TrayItem] { items.filter { selection.contains($0.id) } }

    func selectedURLs() -> [URL] { selectedItems().compactMap { urls[$0.id] } }

    /// The files an action applies to: the selection, or everything when nothing is selected.
    func targetURLs() -> [URL] {
        let selected = selectedURLs()
        return selected.isEmpty ? items.compactMap { urls[$0.id] } : selected
    }

    // MARK: Changes

    private func itemsDidChange(save: Bool = true) {
        missing = Set(items.filter { urls[$0.id] == nil }.map(\.id))
        if save { file.save(items) }
        updateActivity()
    }

    // MARK: Closed-notch activity (icon + count)

    private func updateActivity() {
        guard isShared else { return }
        let center = LiveActivityCenter.shared
        guard Pref.bool(Key.activity, true), !items.isEmpty else { center.dismiss(id: "tray.count"); return }
        let count = items.count
        center.show(LiveActivity(id: "tray.count", kind: .tray, onTap: { NotchNavigator.shared.open(.tray) }, leading: {
            Image(systemName: "tray.full.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
        }, trailing: {
            Text(verbatim: "\(count)").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
        }).withDetail {
            Text("Items in the Tray: \(count)").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
        })
    }

    func activitySettingChanged() { updateActivity() }

    // MARK: Actions

    // MARK: Converting

    static let convertFolderKey = "tray.convertFolder"      // App Store edition: a folder the user picked

    private func destination(for source: URL) -> URL {
        #if APPSTORE
        // A sandboxed app can only write where it was allowed: Downloads, a folder the user picked, or its own folder.
        let fallback = folder.appendingPathComponent("Converted", isDirectory: true)
        if ScoutRuntime.isScripted {   // scripted runs never write into the owner's folders
            try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            return fallback
        }
        switch Pref.string(Key.convertDest, "downloads") {
        case "folder":
            if let picked = FileScope.folder(key: Self.convertFolderKey) { return picked }
        case "tray":
            try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            return fallback
        default:
            break
        }
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
           FileManager.default.isWritableFile(atPath: downloads.path) { return downloads }
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
        #else
        let alongside = Pref.string(Key.convertDest, "alongside") == "alongside"
        let dir = source.deletingLastPathComponent()
        if alongside, FileManager.default.isWritableFile(atPath: dir.path) { return dir }
        let fallback = folder.appendingPathComponent("Converted", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
        #endif
    }

    /// Converts files to a format. NEW files only; shows a result card; adds results to the Tray (setting).
    func convert(_ sources: [URL], to format: ConvertFormat, addToTray: Bool = true, completion: (([URL]) -> Void)? = nil) {
        guard !sources.isEmpty else { return }
        converting += 1
        let center = LiveActivityCenter.shared
        if isShared {
            center.show(LiveActivity(id: "tray.convert", kind: .conversion, leading: {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
            }, trailing: {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
            }).withDetail {
                Text("Converting to \(format.title)").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
            })
        }
        Task {
            defer {
                converting -= 1
                if converting == 0 { center.dismiss(id: "tray.convert") }
            }
            do {
                let results = try await Converter.convert(sources, to: format) { self.destination(for: $0) }
                if addToTray, Pref.bool(Key.addResults, true) {
                    let added = add(files: results, kind: .converted)
                    selection = Set(added.map(\.id))
                }
                completion?(results)
                if isShared, let first = results.first {
                    center.present(NotchCard(id: "tray.result", kind: .conversion, duration: 7, onTap: { self.showInFinder([first]) }) {
                        ConversionResultCard(url: first, extra: results.count - 1, format: format)
                    })
                }
            } catch {
                Toast.show(verbatim: error.localizedDescription, symbol: "exclamationmark.triangle.fill", style: .warning, duration: 3.5)
            }
        }
    }

    func showInFinder(_ urls: [URL]) {
        guard !ScoutRuntime.isScripted, !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func airDrop(_ things: [Any]) {
        guard !things.isEmpty else { return }
        if ScoutRuntime.isScripted { Toast.show("Items to send with AirDrop: \(things.count)", symbol: "airplayaudio", style: .info); return }
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: things) else {
            Toast.show("AirDrop isn't available right now", symbol: "exclamationmark.triangle.fill", style: .warning)
            return
        }
        service.perform(withItems: things)
    }
}
