import AppKit
import SwiftUI

/// Apple Shortcuts. Full edition: the `shortcuts` command line tool (list, run by name).
/// App Store edition: the `shortcuts://run-shortcut?name=` URL scheme, and the user types the names
/// (a sandboxed app cannot list or run the tool).
@MainActor
final class ShortcutsService: ObservableObject {
    static let shared = ShortcutsService()

    enum Key { static let favorites = "shortcuts.favorites" }

    @Published private(set) var all: [String] = []
    @Published private(set) var loaded = false
    @Published private(set) var running: Set<String> = []

    static let maxFavorites = 8

    /// `shortcuts://run-shortcut?name=Morning%20routine`
    nonisolated static func runURL(for name: String) -> URL? {
        var c = URLComponents()
        c.scheme = "shortcuts"
        c.host = "run-shortcut"
        c.queryItems = [URLQueryItem(name: "name", value: name)]
        return c.url
    }

    static let appURL = URL(fileURLWithPath: "/System/Applications/Shortcuts.app")

    var favorites: [String] {
        get { (UserDefaults.standard.string(forKey: Key.favorites) ?? "").split(separator: "\n").map(String.init) }
        set { UserDefaults.standard.set(newValue.joined(separator: "\n"), forKey: Key.favorites); objectWillChange.send() }
    }

    func isFavorite(_ name: String) -> Bool { favorites.contains(name) }

    func setFavorite(_ name: String, _ on: Bool) {
        var list = favorites
        if on { if !list.contains(name), list.count < Self.maxFavorites { list.append(name) } } else { list.removeAll { $0 == name } }
        favorites = list
    }

    #if APPSTORE

    var toolAvailable: Bool { true }

    // MARK: List (the user types the names)

    func reload() { loaded = true }

    var visibleFavorites: [String] { favorites }

    func addFavorite(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        setFavorite(trimmed, true)
    }

    func openShortcutsApp() {
        guard !ScoutRuntime.isScripted else { return }
        NSWorkspace.shared.open(Self.appURL)
    }

    // MARK: Run

    func run(_ name: String) {
        if ScoutRuntime.isScripted { Toast.show("Would run \(name)", symbol: "bolt.fill", style: .info); return }
        guard let url = Self.runURL(for: name) else { return }
        NSWorkspace.shared.open(url)
    }

    #else

    nonisolated static let toolPath = "/usr/bin/shortcuts"

    var toolAvailable: Bool { FileManager.default.isExecutableFile(atPath: Self.toolPath) }

    // MARK: List

    func reload() {
        if ScoutRuntime.isScripted {
            all = ["Morning routine", "Resize image", "Start focus", "Log water", "New note", "Text last photo", "Play playlist", "Lock screen"]
            loaded = true
            return
        }
        guard toolAvailable else { loaded = true; return }
        Task.detached(priority: .utility) {
            let out = Shell.run(Self.toolPath, ["list"]) ?? ""
            let names = out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            await MainActor.run { self.all = names; self.loaded = true }
        }
    }

    /// Favorites that still exist (a deleted shortcut disappears from the widget once the list is loaded).
    var visibleFavorites: [String] {
        loaded && !ScoutRuntime.isScripted && !all.isEmpty ? favorites.filter(all.contains) : favorites
    }

    // MARK: Run

    func run(_ name: String) {
        guard !running.contains(name) else { return }
        if ScoutRuntime.isScripted { Toast.show("Would run \(name)", symbol: "bolt.fill", style: .info); return }
        guard toolAvailable else { Toast.show("Shortcuts isn't available on this Mac", symbol: "exclamationmark.triangle.fill", style: .warning); return }
        running.insert(name)
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.toolPath)
            process.arguments = ["run", name]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            var status: Int32 = -1
            do { try process.run(); process.waitUntilExit(); status = process.terminationStatus } catch {}
            let ok = status == 0
            await MainActor.run {
                self.running.remove(name)
                if ok { Toast.show("Ran \(name)", symbol: "bolt.fill") } else { Toast.show("\(name) didn't finish", symbol: "exclamationmark.triangle.fill", style: .warning) }
            }
        }
    }

    #endif
}
