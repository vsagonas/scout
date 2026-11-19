import Foundation

/// Which build this is. The Mac App Store edition (compiled with `-D APPSTORE`) is sandboxed and leaves out
/// what App Review does not allow: private system frameworks (brightness, media-key interception),
/// reading other apps' data (Messages database, other apps' Keychain items), editing other apps' files
/// (Agents there has no hooks and never writes in ~/.claude), running unbundled tools
/// (yt-dlp, ffmpeg, cwebp, a login shell), and downloading videos from other sites.
/// The full ("direct") edition keeps everything.
enum Edition {
    #if APPSTORE
    static let isAppStore = true
    #else
    static let isAppStore = false
    #endif

    static var name: String { isAppStore ? "App Store" : "Full" }

    /// Answering agents from the notch (Allow, Deny, a question's answer), fed by hooks and a listener on 127.0.0.1: NOT in the App Store
    /// edition, which is also the one in the DMG.
    /// It never listens, has no
    /// network.server entitlement and shows no Connect, Copy hooks or answer controls; an agent that needs you is shown, and you answer it
    /// in its own window. The development edition keeps the code for its self-tests.
    static var answersAgents: Bool { !isAppStore }
}

extension WorkspaceKind {
    /// False for workspaces the App Store edition leaves out. Every menu, palette and shortcut list filters on this.
    var isAvailable: Bool {
        guard Edition.isAppStore else { return true }
        switch self {
        case .terminal: return false
        default: return true
        }
    }

    static var available: [WorkspaceKind] { allCases.filter(\.isAvailable) }
}

extension WidgetKind {
    var isAvailable: Bool { self != .aiUsage }

    static var available: [WidgetKind] { allCases.filter(\.isAvailable) }
}

extension SettingsPane {
    var isAvailable: Bool {
        guard Edition.isAppStore else { return true }
        switch self {
        case .terminal, .messages, .lockScreen: return false
        default: return true
        }
    }

    static var available: [SettingsPane] { allCases.filter(\.isAvailable) }
}

extension LiveActivityKind {
    var isAvailable: Bool {
        guard Edition.isAppStore else { return true }
        switch self {
        case .message, .video, .update: return false   // the App Store updates the app itself
        default: return true
        }
    }
}

/// Titles that name left-out features exist only in the full edition's binary.
enum EditionTitles {
    #if APPSTORE
    static let hudActivity = String(localized: "Volume")
    static let hudPane = String(localized: "Volume")
    static let downloadsPane = String(localized: "Downloads")
    static let agentsPane = String(localized: "Agents")
    #else
    static let hudActivity = String(localized: "Volume & brightness")
    static let hudPane = String(localized: "Volume & Brightness")
    static let downloadsPane = String(localized: "Downloads & Video")
    static let agentsPane = String(localized: "Agents & AI Usage")
    #endif
}
