import AppKit
import Foundation

/// Where the transcript folders are, and (App Store edition) how Scout gets to read them.
///
/// The sandboxed edition has a read-only entitlement for `~/.claude/projects/` and `~/.codex/sessions/`, so nothing is
/// asked. If that read ever fails at runtime, the user can allow the folder once: an open panel pointed at `~/.claude`
/// (or `~/.codex`) and a security-scoped READ-ONLY bookmark. Scout never writes in either folder.
enum AgentAccess {
    /// The real home folder. A sandboxed app's `NSHomeDirectory()` is its container, so ask the user database.
    static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir), isDirectory: true) }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// `~/.claude` or `~/.codex`.
    static func folder(for agent: AgentKind) -> URL {
        realHome.appendingPathComponent(agent == .claude ? ".claude" : ".codex", isDirectory: true)
    }

    /// The folder the scanner reads: `~/.claude/projects` or `~/.codex/sessions`.
    static func defaultRoot(for agent: AgentKind) -> URL {
        folder(for: agent).appendingPathComponent(agent == .claude ? "projects" : "sessions", isDirectory: true)
    }

    /// Scripted runs never read the real folders: a test folder under Scout-Automation, or the one named on the command line
    /// (`--agents-scan-claude <dir>`, `--agents-scan-codex <dir>`).
    static func automationRoot(for agent: AgentKind) -> URL {
        let flag = agent == .claude ? "--agents-scan-claude" : "--agents-scan-codex"
        let args = ScoutRuntime.arguments
        if let i = args.firstIndex(of: flag), i + 1 < args.count { return URL(fileURLWithPath: args[i + 1], isDirectory: true) }
        return AppPaths.folder("agents-scan").appendingPathComponent(agent == .claude ? "claude-projects" : "codex-sessions", isDirectory: true)
    }

    enum Probe: Equatable { case ok, missing, denied }

    /// Can the folder be listed?
    static func probe(_ url: URL) -> Probe {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
            return .ok
        } catch {
            let ns = error as NSError
            if ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError { return .missing }
            if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError, under.domain == NSPOSIXErrorDomain, under.code == Int(ENOENT) { return .missing }
            return .denied
        }
    }

    // MARK: Bookmarks (App Store edition fallback)

    private static func key(_ agent: AgentKind) -> String { "agents.access.\(agent.rawValue)" }

    private static var openScopes: [AgentKind: URL] = [:]

    /// The folder the user allowed earlier, opened for reading (nil when none, or the bookmark went stale).
    static func allowedRoot(for agent: AgentKind) -> URL? {
        if let url = openScopes[agent] { return root(in: url, agent: agent) }
        guard let data = UserDefaults.standard.data(forKey: key(agent)) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        openScopes[agent] = url
        if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: key(agent))
        }
        return root(in: url, agent: agent)
    }

    /// The user may pick `.claude`, or the `projects` folder itself, or the home folder: take what leads to the transcripts.
    private static func root(in picked: URL, agent: AgentKind) -> URL {
        let leaf = agent == .claude ? "projects" : "sessions"
        let direct = picked.appendingPathComponent(leaf, isDirectory: true)
        if probe(direct) == .ok { return direct }
        let nested = picked.appendingPathComponent(agent == .claude ? ".claude" : ".codex", isDirectory: true).appendingPathComponent(leaf, isDirectory: true)
        if probe(nested) == .ok { return nested }
        return picked
    }

    /// "Allow Scout to see your agents": an open panel at `~/.claude` (or `~/.codex`); keeps a read-only bookmark.
    @MainActor
    static func requestAccess(for agent: AgentKind, completion: @escaping @MainActor (Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = folder(for: agent)
        panel.prompt = String(localized: "Allow")
        let folderName = agent == .claude ? ".claude" : ".codex"
        panel.message = String(localized: "Choose the \(folderName) folder so Scout can see your \(agent.title) sessions. Scout only reads it.")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url,
                      let data = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) else { completion(false); return }
                openScopes[agent]?.stopAccessingSecurityScopedResource()
                openScopes[agent] = nil
                UserDefaults.standard.set(data, forKey: key(agent))
                completion(allowedRoot(for: agent) != nil)
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }
}
