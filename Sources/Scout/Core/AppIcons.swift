import AppKit

/// App icons and names by bundle id or path, cached (shared by the whole app; was duplicated in two parts of the app).
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(bundleID: String) -> NSImage? { icon(forBundleID: bundleID) }

    static func icon(forBundleID id: String?) -> NSImage? {
        guard let id else { return nil }
        if let hit = cache[id] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[id] = image
        return image
    }

    static func icon(forPath path: String) -> NSImage {
        if let hit = cache[path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }

    /// Friendly names for the default ignored apps (so the list reads well even when they aren't installed).
    private static let knownNames = ["com.apple.Passwords": "Passwords", "com.1password.1password": "1Password",
                                     "com.agilebits.onepassword7": "1Password 7", "com.agilebits.onepassword-osx": "1Password 6",
                                     "com.bitwarden.desktop": "Bitwarden", "org.keepassxc.keepassxc": "KeePassXC",
                                     "com.apple.keychainaccess": "Keychain Access"]

    static func name(forBundleID id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return knownNames[id] ?? id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
