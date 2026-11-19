import AppKit
import CryptoKit
import ImageIO
import SwiftUI

// B3 — the clipboard history. Polls the general pasteboard every 0.5 s, keeps text, images, files, links and
// colors, skips confidential copies and ignored apps, and offers `copy(_:)` / `paste(_:)` helpers.

struct ClipboardItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case text, image, file, link, color

        var title: String {
            switch self {
            case .text: String(localized: "Text")
            case .image: String(localized: "Images")
            case .file: String(localized: "Files")
            case .link: String(localized: "Links")
            case .color: String(localized: "Colors")
            }
        }

        /// One item's kind ("Image"), where `title` names the whole group ("Images").
        var singularTitle: String {
            switch self {
            case .text: String(localized: "Text")
            case .image: String(localized: "Image")
            case .file: String(localized: "File")
            case .link: String(localized: "Link")
            case .color: String(localized: "Color")
            }
        }

        var symbol: String {
            switch self {
            case .text: "text.alignleft"
            case .image: "photo"
            case .file: "doc"
            case .link: "link"
            case .color: "paintpalette"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    /// Text, link, or hex color.
    var text: String?
    var filePaths: [String] = []
    /// PNG file name inside `AppPaths.folder("Clipboard")`.
    var imageFile: String?
    var imageWidth: Int?
    var imageHeight: Int?
    var sourceBundleID: String?
    var sourceName: String?
    var date = Date()
    var isPinned = false
    var isFavorite = false
    var fingerprint: String

    /// One line for lists.
    var preview: String {
        switch kind {
        case .text, .link, .color:
            let line = (text ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return line.trimmingCharacters(in: .whitespaces)
        case .image:
            if let w = imageWidth, let h = imageHeight { return String(localized: "Image \(w)×\(h)") }
            return String(localized: "Image")
        case .file:
            let names = filePaths.map { ($0 as NSString).lastPathComponent }
            if names.count > 1 { return String(localized: "\(names[0]) + \(names.count - 1) more") }
            return names.first ?? String(localized: "File")
        }
    }

    var imageURL: URL? { imageFile.map { AppPaths.folder("Clipboard").appendingPathComponent($0) } }

    var color: Color? { kind == .color ? text.flatMap { Color(hex: $0) } : nil }
}

enum ClipboardRetention: String, CaseIterable, Identifiable {
    case hour, day, week, month, forever
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hour: String(localized: "One hour")
        case .day: String(localized: "One day")
        case .week: String(localized: "One week")
        case .month: String(localized: "One month")
        case .forever: String(localized: "Forever")
        }
    }
    var seconds: TimeInterval? {
        switch self {
        case .hour: 3600
        case .day: 86_400
        case .week: 86_400 * 7
        case .month: 86_400 * 30
        case .forever: nil
        }
    }
}

enum ClipboardImages {
    private static let cache = NSCache<NSString, NSImage>()

    /// A downscaled thumbnail (long edge `maxPixel`), cached.
    static func thumbnail(for item: ClipboardItem, maxPixel: Int = 240) -> NSImage? {
        guard let url = item.imageURL else { return nil }
        let key = "\(url.lastPathComponent)-\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key)
        return image
    }
}

@MainActor
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    /// The notch's menu-bar item toggles this. Keep the name stable.
    @Published var isPaused: Bool {
        didSet { UserDefaults.standard.set(isPaused, forKey: "clip.paused") }
    }
    @Published private(set) var items: [ClipboardItem] = []

    static let defaultIgnoredApps = ["com.apple.Passwords", "com.1password.1password", "com.agilebits.onepassword7",
                                     "com.agilebits.onepassword-osx", "com.bitwarden.desktop", "org.keepassxc.keepassxc",
                                     "com.apple.keychainaccess"]

    private let file = JSONFile<[ClipboardItem]>("clipboard.json")
    private let saver = Debouncer(delay: 0.8)
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var selfChangeCount: Int?
    private var persists: Bool { !ScoutRuntime.isScripted }

    init() {
        isPaused = UserDefaults.standard.bool(forKey: "clip.paused")
        if ScoutRuntime.isScripted { items = Self.sampleItems() }
    }

    // MARK: Settings

    var isEnabled: Bool { UserDefaults.standard.bool("clip.enabled", default: true) }
    var limit: Int { max(10, UserDefaults.standard.int("clip.limit", default: 200)) }
    var retention: ClipboardRetention { ClipboardRetention(rawValue: UserDefaults.standard.string("clip.retention", default: "week")) ?? .week }
    var skipsConfidential: Bool { UserDefaults.standard.bool("clip.skipConfidential", default: true) }
    var pastesOnPick: Bool { UserDefaults.standard.bool("clip.pasteOnPick", default: true) }
    var ignoredApps: [String] { StoredList.strings("clip.ignoredApps", default: Self.defaultIgnoredApps) }

    // MARK: Lifecycle

    func start() {
        guard !ScoutRuntime.isScripted, timer == nil else { return }
        items = file.load() ?? []
        purgeExpired()
        lastChangeCount = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Reading the pasteboard

    private func poll() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        if let own = selfChangeCount, own == count { selfChangeCount = nil; return }
        guard isEnabled, !isPaused else { return }

        let types = pb.types ?? []
        if skipsConfidential {
            let hidden = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
                          "com.agilebits.onepassword"]
            if types.contains(where: { hidden.contains($0.rawValue) }) { return }
        }
        let app = NSWorkspace.shared.frontmostApplication
        if let id = app?.bundleIdentifier, ignoredApps.contains(id) { return }

        guard var item = Self.read(pasteboard: pb) else { return }
        item.sourceBundleID = app?.bundleIdentifier
        item.sourceName = app?.localizedName
        add(item)
    }

    static func read(pasteboard pb: NSPasteboard) -> ClipboardItem? {
        // Files
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let paths = urls.map(\.path)
            return ClipboardItem(kind: .file, text: nil, filePaths: paths, fingerprint: "f:" + paths.joined(separator: "|"))
        }
        let plain = pb.string(forType: .string)
        // Images (only when there is no plain text next to them: browsers add text to image copies)
        if plain?.isEmpty ?? true, let image = readImage(pb) { return image }
        // Text, links, colors
        if let text = plain, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let clipped = String(text.prefix(200_000))
            let trimmed = clipped.trimmingCharacters(in: .whitespacesAndNewlines)
            if isHexColor(trimmed) {
                return ClipboardItem(kind: .color, text: trimmed.uppercased(), fingerprint: "t:" + clipped)
            }
            if isLink(trimmed) { return ClipboardItem(kind: .link, text: trimmed, fingerprint: "t:" + clipped) }
            return ClipboardItem(kind: .text, text: clipped, fingerprint: "t:" + clipped)
        }
        if let rtf = pb.data(forType: .rtf), let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil),
           !attributed.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let text = String(attributed.string.prefix(200_000))
            return ClipboardItem(kind: .text, text: text, fingerprint: "t:" + text)
        }
        if pb.types?.contains(.color) == true, let color = NSColor(from: pb) {
            let hex = Color(nsColor: color).hexString
            return ClipboardItem(kind: .color, text: hex, fingerprint: "c:" + hex)
        }
        return readImage(pb)
    }

    private static func readImage(_ pb: NSPasteboard) -> ClipboardItem? {
        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff), data.count < 40_000_000,
              let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let name = "\(UUID().uuidString).png"
        var item = ClipboardItem(kind: .image, text: nil, imageFile: name, imageWidth: rep.pixelsWide, imageHeight: rep.pixelsHigh,
                                 fingerprint: "i:" + hash)
        item.imageFile = name
        // The file is written when the item is really added (see `add`), so a duplicate costs nothing.
        pendingImages[item.id] = png
        return item
    }

    private static var pendingImages: [UUID: Data] = [:]

    private static func isHexColor(_ s: String) -> Bool {
        guard s.hasPrefix("#"), s.count == 7 || s.count == 9 else { return false }
        return s.dropFirst().allSatisfy(\.isHexDigit)
    }

    private static func isLink(_ s: String) -> Bool {
        guard !s.contains(where: \.isWhitespace), let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "ftp", "mailto"].contains(scheme) && (scheme == "mailto" || url.host != nil)
    }

    // MARK: Changing the list

    /// Adds an item (or moves the same content to the front).
    func add(_ item: ClipboardItem) {
        var item = item
        if let i = items.firstIndex(where: { $0.fingerprint == item.fingerprint }) {
            var existing = items.remove(at: i)
            existing.date = Date()
            existing.sourceBundleID = item.sourceBundleID ?? existing.sourceBundleID
            existing.sourceName = item.sourceName ?? existing.sourceName
            items.insert(existing, at: 0)
            Self.pendingImages[item.id] = nil
        } else {
            if item.kind == .image, let png = Self.pendingImages.removeValue(forKey: item.id), let url = item.imageURL {
                try? png.write(to: url)
            }
            item.date = Date()
            items.insert(item, at: 0)
        }
        trim()
        changed()
    }

    func togglePin(_ item: ClipboardItem) { update(item) { $0.isPinned.toggle() } }
    func toggleFavorite(_ item: ClipboardItem) { update(item) { $0.isFavorite.toggle() } }

    private func update(_ item: ClipboardItem, _ change: (inout ClipboardItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        change(&items[i])
        changed()
    }

    func delete(_ item: ClipboardItem) {
        remove(items.filter { $0.id == item.id })
        changed()
    }

    func clear(keepingPinned: Bool = true) {
        remove(items.filter { !(keepingPinned && ($0.isPinned || $0.isFavorite)) })
        changed()
    }

    private func remove(_ gone: [ClipboardItem]) {
        let ids = Set(gone.map(\.id))
        items.removeAll { ids.contains($0.id) }
        guard persists else { return }
        for item in gone { if let url = item.imageURL { try? FileManager.default.removeItem(at: url) } }
    }

    private func trim() {
        purgeExpired()
        let removable = items.filter { !$0.isPinned && !$0.isFavorite }
        if removable.count > limit { remove(Array(removable.suffix(removable.count - limit))) }
    }

    private func purgeExpired() {
        guard let seconds = retention.seconds else { return }
        let cutoff = Date().addingTimeInterval(-seconds)
        remove(items.filter { !$0.isPinned && !$0.isFavorite && $0.date < cutoff })
    }

    private func changed() {
        guard persists else { return }
        saver.call { [weak self] in
            guard let self else { return }
            self.file.save(self.items)
        }
    }

    // MARK: Queries

    /// Pinned first, then newest first.
    func ordered(kind: ClipboardItem.Kind? = nil, query: String = "") -> [ClipboardItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = items.filter { item in
            if let kind, item.kind != kind { return false }
            guard !q.isEmpty else { return true }
            return item.preview.lowercased().contains(q) || (item.text ?? "").lowercased().contains(q)
                || (item.sourceName ?? "").lowercased().contains(q) || item.filePaths.contains { $0.lowercased().contains(q) }
        }
        return list.filter(\.isPinned) + list.filter { !$0.isPinned }
    }

    // MARK: Putting an item back on the pasteboard

    /// Copies the item. Returns false in scripted runs (the real pasteboard is never touched there).
    @discardableResult
    func copy(_ item: ClipboardItem) -> Bool {
        guard !ScoutRuntime.isScripted else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text, .link, .color:
            pb.setString(item.text ?? "", forType: .string)
        case .image:
            if let url = item.imageURL, let image = NSImage(contentsOf: url) { pb.writeObjects([image]) }
        case .file:
            pb.writeObjects(item.filePaths.map { URL(fileURLWithPath: $0) as NSURL })
        }
        selfChangeCount = pb.changeCount
        lastChangeCount = pb.changeCount
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            var moved = items.remove(at: i)
            moved.date = Date()
            items.insert(moved, at: 0)
            changed()
        }
        return true
    }

    /// Copy, then (when allowed) paste into the app you were in. The caller closes its panel first.
    func paste(_ item: ClipboardItem) {
        guard copy(item) else { Toast.show("Copied", symbol: "doc.on.clipboard"); return }
        if PasteBack.canPost() {
            PasteBack.commandV()
        } else {
            Toast.show("Copied — allow Accessibility to paste automatically", symbol: "doc.on.clipboard", style: .info, duration: 3)
        }
    }

    /// What a pick does: paste when the setting is on, else copy and say so.
    func pick(_ item: ClipboardItem) {
        if pastesOnPick { paste(item) } else {
            if copy(item) { Toast.show("Copied", symbol: "doc.on.clipboard") }
        }
    }

    // MARK: Sample data (scripted runs)

    private static func sampleItems() -> [ClipboardItem] {
        let now = Date()
        func make(_ kind: ClipboardItem.Kind, _ text: String?, app: String, id: String, ago: TimeInterval, paths: [String] = []) -> ClipboardItem {
            var item = ClipboardItem(kind: kind, text: text, filePaths: paths, sourceBundleID: id, sourceName: app, fingerprint: UUID().uuidString)
            item.date = now.addingTimeInterval(-ago)
            return item
        }
        var list: [ClipboardItem] = []
        var color = make(.color, "#FFB021", app: "Preview", id: "com.apple.Preview", ago: 40)
        color.isFavorite = true
        list.append(color)
        list.append(make(.text, "Meeting notes: ship the notch on Friday, then polish the agents.", app: "Notes", id: "com.apple.Notes", ago: 130))
        list.append(make(.link, "https://developer.apple.com/documentation/swiftui", app: "Safari", id: "com.apple.Safari", ago: 420))
        if let name = sampleImage() {
            var image = ClipboardItem(kind: .image, text: nil, imageFile: name, imageWidth: 1200, imageHeight: 760,
                                      sourceBundleID: "com.apple.screencaptureui", sourceName: "Screenshot", fingerprint: UUID().uuidString)
            image.date = now.addingTimeInterval(-900)
            list.append(image)
        }
        list.append(make(.file, nil, app: "Finder", id: "com.apple.finder", ago: 2400, paths: ["/Users/sample/Documents/Quarterly report.pdf"]))
        var pinned = make(.text, "hello@example.com", app: "Mail", id: "com.apple.mail", ago: 7200)
        pinned.isPinned = true
        list.append(pinned)
        list.append(make(.text, "let scout = AgentScanner()\nscout.start()", app: "Xcode", id: "com.apple.dt.Xcode", ago: 15_000))
        list.append(make(.link, "https://www.example.com/articles/the-radial-menu", app: "Safari", id: "com.apple.Safari", ago: 90_000))
        list.append(make(.color, "#2F6FED", app: "Preview", id: "com.apple.Preview", ago: 200_000))
        list.append(make(.text, "Buy oat milk, stamps, batteries (AA).", app: "Notes", id: "com.apple.Notes", ago: 400_000))
        return list
    }

    private static func sampleImage() -> String? {
        let name = "sample-gradient.png"
        let url = AppPaths.folder("Clipboard").appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return name }
        let size = NSSize(width: 480, height: 300)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [NSColor(red: 0.98, green: 0.62, blue: 0.30, alpha: 1), NSColor(red: 0.55, green: 0.30, blue: 0.85, alpha: 1)])?
            .draw(in: NSRect(origin: .zero, size: size), angle: 35)
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 200, height: 120), xRadius: 14, yRadius: 14).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        try? png.write(to: url)
        return name
    }
}
