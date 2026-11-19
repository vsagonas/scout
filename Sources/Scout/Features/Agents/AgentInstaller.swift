import Foundation

/// Merges Scout's hook entries into Claude Code's and Codex's hook files. The full edition works on the home folder; the App Store
/// edition only on a folder the person picked in an Open panel (`AgentFolderAccess`: the sandbox lets it write there and nowhere else),
/// and it can still show the same entries as a block to paste instead.
/// EVERY function takes the base folder (the home folder in real use). Tests and scripted runs pass a
/// temporary folder: the real ~/.claude and ~/.codex are never touched by builds or tests.
///
/// The commands are the same inline one-liners the App Store edition shows (`AgentHooks`), so there is no script
/// file: nothing but `settings.json` / `hooks.json` is written, and "Disconnect" removes exactly Scout's entries.
enum AgentInstaller {
    enum InstallError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let file): String(localized: "\(file) isn't valid JSON, so Scout left it alone.")
            }
        }
    }

    enum State: Equatable {
        case notConnected
        case connected
        /// Scout's entries are there, but they name another port (or are an older kind): Connect again to update.
        case outdated
    }

    static func settingsFile(_ agent: AgentKind, base: URL) -> URL {
        switch agent {
        case .claude: base.appendingPathComponent(".claude/settings.json")
        case .codex: base.appendingPathComponent(".codex/hooks.json")
        }
    }

    // MARK: Files

    private static func load(_ file: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let data = try Data(contentsOf: file)
        if data.isEmpty || String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw InstallError.unreadable(file.lastPathComponent) }
        return json
    }

    private static func save(_ json: [String: Any], to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)
    }

    /// Copies the existing file next to itself before the first change.
    private static func backUp(_ file: URL) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")   // a file name: the same digits in every language and calendar
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let backup = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".scout-backup-" + f.string(from: Date()))
        if !FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.copyItem(at: file, to: backup) }
    }

    // MARK: Connect / disconnect

    private static func isScouts(_ hook: Any) -> Bool {
        guard let dict = hook as? [String: Any], let command = dict["command"] as? String else { return false }
        return AgentHooks.isScouts(command: command)
    }

    /// Drops Scout's commands from one event's groups; groups left empty go too.
    private static func withoutScout(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group in
            let all = group["hooks"] as? [Any] ?? []
            let inner = all.filter { !isScouts($0) }
            if inner.count == all.count { return group }
            if inner.isEmpty { return nil }
            var g = group
            g["hooks"] = inner
            return g
        }
    }

    /// Adds Scout's entries (and replaces older Scout entries): idempotent, other entries untouched.
    static func connect(_ agent: AgentKind, base: URL, port: UInt16, token: String) throws {
        try connect(agent, file: settingsFile(agent, base: base), port: port, token: token)
    }

    /// The same on the hook file itself (the App Store edition: inside the folder the person picked).
    static func connect(_ agent: AgentKind, file: URL, port: UInt16, token: String) throws {
        var json = try load(file)                    // throws (and changes nothing) when the file isn't valid JSON
        try backUp(file)
        var hooks = json["hooks"] as? [String: Any] ?? [:]
        let mine = AgentHooks.hooksObject(agent, port: port, token: token)
        for (event, groups) in mine {
            let kept = withoutScout(hooks[event] as? [[String: Any]] ?? [])
            hooks[event] = kept + groups
        }
        // Entries for events Scout no longer registers (an older version's) go too.
        for event in Array(hooks.keys) where mine[event] == nil {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let kept = withoutScout(groups)
            hooks[event] = kept.isEmpty ? nil : kept
        }
        json["hooks"] = hooks
        try save(json, to: file)
    }

    /// Removes only Scout's entries.
    static func disconnect(_ agent: AgentKind, base: URL) throws {
        try disconnect(agent, file: settingsFile(agent, base: base))
    }

    static func disconnect(_ agent: AgentKind, file: URL) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        var json = try load(file)
        guard var hooks = json["hooks"] as? [String: Any] else { return }
        try backUp(file)
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = withoutScout(groups)
            hooks[event] = kept.isEmpty ? nil : kept
        }
        json["hooks"] = hooks.isEmpty ? nil : hooks
        try save(json, to: file)
    }

    /// Every Scout command in the file.
    private static func scoutCommands(_ agent: AgentKind, base: URL) -> [String] { scoutCommands(file: settingsFile(agent, base: base)) }

    private static func scoutCommands(file: URL) -> [String] {
        guard let json = try? load(file), let hooks = json["hooks"] as? [String: Any] else { return [] }
        var commands: [String] = []
        for (_, value) in hooks {
            for group in (value as? [[String: Any]] ?? []) {
                for hook in (group["hooks"] as? [Any] ?? []) where isScouts(hook) {
                    if let command = (hook as? [String: Any])?["command"] as? String { commands.append(command) }
                }
            }
        }
        return commands
    }

    /// Not connected, connected, or connected to a port / protocol that is out of date.
    static func state(_ agent: AgentKind, base: URL, port: UInt16, token: String) -> State {
        state(agent, file: settingsFile(agent, base: base), port: port, token: token)
    }

    static func state(_ agent: AgentKind, file: URL, port: UInt16, token: String) -> State {
        let commands = scoutCommands(file: file)
        guard !commands.isEmpty else { return .notConnected }
        let expected = Set(AgentHooks.entries(for: agent).map { AgentHooks.command(agent, $0, port: port, token: token) })
        return Set(commands) == expected ? .connected : .outdated
    }

    /// True when Scout's entries are in the file.
    static func isConnected(_ agent: AgentKind, base: URL) -> Bool { !scoutCommands(agent, base: base).isEmpty }
}

/// The App Store edition's way into an agent's settings folder: the person picks
/// ~/.claude (or ~/.codex) in an Open panel, the sandbox then lets Scout read and write in that one folder, and a security-scoped bookmark
/// keeps the permission for later (Update, Disconnect). Nothing outside the picked folder is ever touched.
enum AgentFolderAccess {
    static func folderName(_ agent: AgentKind) -> String { agent == .claude ? ".claude" : ".codex" }
    static func fileName(_ agent: AgentKind) -> String { agent == .claude ? "settings.json" : "hooks.json" }
    private static func key(_ agent: AgentKind) -> String { "agents.folderBookmark.\(agent.rawValue)" }

    /// The real home folder (in the sandbox `homeDirectoryForCurrentUser` is the app's container).
    static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir), isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// True when `url` is the agent's own folder (~/.claude or ~/.codex), not any other folder.
    static func isAgentFolder(_ url: URL, _ agent: AgentKind) -> Bool {
        url.standardizedFileURL.path == realHome.appendingPathComponent(folderName(agent)).standardizedFileURL.path
    }

    static func remember(_ folder: URL, for agent: AgentKind) {
        let options: URL.BookmarkCreationOptions = Edition.isAppStore ? [.withSecurityScope] : []
        if let data = try? folder.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: key(agent))
        }
    }

    static func forget(_ agent: AgentKind) { UserDefaults.standard.removeObject(forKey: key(agent)) }

    static func hasFolder(_ agent: AgentKind) -> Bool { UserDefaults.standard.data(forKey: key(agent)) != nil }

    /// Hooks in a folder the person picked that name an old port or token (or an older kind) are rewritten by themselves: connected stays
    /// connected without asking again.
    static func updateIfOutdated(port: UInt16, token: String) {
        for agent in AgentKind.allCases where hasFolder(agent) {
            _ = try? withFile(agent) { file in
                if AgentInstaller.state(agent, file: file, port: port, token: token) == .outdated { try AgentInstaller.connect(agent, file: file, port: port, token: token) }
            }
        }
    }

    /// Runs `work` with the agent's hook file while the remembered folder is open to Scout; nil when there is no usable folder.
    static func withFile<T>(_ agent: AgentKind, _ work: (URL) throws -> T) rethrows -> T? {
        guard let data = UserDefaults.standard.data(forKey: key(agent)) else { return nil }
        var stale = false
        let options: URL.BookmarkResolutionOptions = Edition.isAppStore ? [.withSecurityScope] : []
        guard let folder = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        let open = folder.startAccessingSecurityScopedResource()
        defer { if open { folder.stopAccessingSecurityScopedResource() } }
        if stale { remember(folder, for: agent) }
        return try work(folder.appendingPathComponent(fileName(agent)))
    }
}
