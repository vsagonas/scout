import Foundation

/// Security-scoped bookmarks for the sandboxed (Mac App Store) edition. A file the user drops or picks is
/// only readable until Scout quits, unless Scout keeps a security-scoped bookmark to it and opens that scope
/// while the file is in use. The full edition is not sandboxed and keeps plain bookmarks.
enum FileScope {
    static var creation: URL.BookmarkCreationOptions { Edition.isAppStore ? [.withSecurityScope] : [] }

    static var resolution: URL.BookmarkResolutionOptions {
        Edition.isAppStore ? [.withSecurityScope, .withoutUI, .withoutMounting] : [.withoutUI, .withoutMounting]
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var open: Set<String> = []

    /// Starts access once per file (a second call for the same file does nothing). No-op outside the sandbox.
    static func begin(_ url: URL) {
        guard Edition.isAppStore else { return }
        let key = url.standardizedFileURL.path
        let first = lock.withLock { open.insert(key).inserted }
        if first, !url.startAccessingSecurityScopedResource() {
            // Not a scoped URL (a path inside the container, say): nothing to balance.
            lock.withLock { _ = open.remove(key) }
        }
    }

    /// Ends access when the file leaves the Tray or Pocket.
    static func end(_ url: URL) {
        guard Edition.isAppStore else { return }
        let key = url.standardizedFileURL.path
        if lock.withLock({ open.remove(key) != nil }) { url.stopAccessingSecurityScopedResource() }
    }

    /// A bookmark for a folder the user picked (conversion results), kept in the defaults.
    static func saveFolder(_ url: URL, key: String) {
        guard let data = try? url.bookmarkData(options: creation, includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// The picked folder, with access opened (nil when none was picked or it is gone).
    static func folder(key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: resolution, relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        if stale { saveFolder(url, key: key) }
        begin(url)
        return url
    }
}
