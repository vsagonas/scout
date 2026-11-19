#if !APPSTORE
import Foundation

// Agent tabs (full edition only): each one a panel on the dashboard that expands into a live terminal that runs a
// command-line agent (Claude Code, Codex) or a plain login shell in a folder. The App Store edition is sandboxed
// and cannot run the user's tools, so none of this is compiled there.

/// What a tab runs.
enum AgentTabKind: String, Codable, CaseIterable, Identifiable {
    case claude, codex, shell

    var id: String { rawValue }
    var isAgent: Bool { self != .shell }

    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .shell: String(localized: "Terminal")
        }
    }

    var menuTitle: String {
        switch self {
        case .claude: String(localized: "New Claude Code tab")
        case .codex: String(localized: "New Codex tab")
        case .shell: String(localized: "New terminal")
        }
    }

    /// SF Symbols: the asterisk (Claude's spark), the code brackets, a terminal in a window.
    var symbol: String {
        switch self {
        case .claude: "asterisk"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .shell: "apple.terminal"
        }
    }

    // MARK: Settings (Settings › Terminal › Agent tabs)

    var commandKey: String { "term.tab.\(rawValue).command" }
    var resumeKey: String { "term.tab.\(rawValue).resume" }

    var defaultCommand: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .shell: ""
        }
    }

    var defaultResume: String {
        switch self {
        case .claude: "claude --continue"
        case .codex: "codex resume --last"
        case .shell: ""
        }
    }

    /// The command that starts the agent (after the login shell has set up the folder and PATH).
    var command: String {
        let chosen = Pref.string(commandKey, "").trimmingCharacters(in: .whitespacesAndNewlines)
        return chosen.isEmpty ? defaultCommand : chosen
    }

    /// The command that continues the folder's last conversation (the "Resume" entries).
    var resumeCommand: String {
        let chosen = Pref.string(resumeKey, "").trimmingCharacters(in: .whitespacesAndNewlines)
        return chosen.isEmpty ? defaultResume : chosen
    }

    /// The program name of the command, for "is it installed?" (never run).
    var commandWord: String {
        command.split(separator: " ").first.map(String.init) ?? defaultCommand
    }
}

/// A tab as it is written to disk, so the next launch can offer "Resume".
struct AgentTabRecord: Codable, Identifiable, Equatable {
    var id: String
    var kind: AgentTabKind
    var folder: String
    var startedAt: Date
}

/// Everything the store keeps on disk (Application Support, `terminal-tabs.json`).
struct AgentTabState: Codable, Equatable {
    var tabs: [AgentTabRecord] = []
    var recentFolders: [String] = []
}

/// Where a tab runs and since when, public so another part of Scout (the Agents tiles) can find the tab that
/// started a session: same folder, started a moment before the session, `pid` = the agent itself (the login shell
/// `exec`s into it).
struct AgentTabInfo: Identifiable, Equatable {
    let id: String
    let kind: AgentTabKind
    /// Absolute path of the folder the tab started in.
    let folder: String
    let startedAt: Date
    let isRunning: Bool
    /// The tab's process id while it runs.
    let pid: Int32?
}

// MARK: - Folders

enum AgentTabFolder {
    static var home: String { NSHomeDirectory() }

    static func normalized(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }

    static func exists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// "Scout" for /Users/me/Dev/Scout, "Home" for the home folder.
    static func name(_ path: String) -> String {
        let p = normalized(path)
        if p == home { return String(localized: "Home") }
        let last = (p as NSString).lastPathComponent
        return last.isEmpty ? p : last
    }

    /// One capital letter for the header: the folder name's first letter or digit, "~" for home.
    static func initial(_ path: String) -> String {
        let p = normalized(path)
        if p == home { return "~" }
        let last = (p as NSString).lastPathComponent
        if let c = last.first(where: { $0.isLetter || $0.isNumber }) { return String(c).uppercased() }
        return "/"
    }

    /// "~/Dev" for /Users/me/Dev/Scout (the folder's parent, with the home folder as a tilde).
    static func parent(_ path: String) -> String {
        let p = normalized(path)
        let dir = (p as NSString).deletingLastPathComponent
        return (dir as NSString).abbreviatingWithTildeInPath
    }

    static func abbreviated(_ path: String) -> String { (normalized(path) as NSString).abbreviatingWithTildeInPath }
}

// MARK: - The command a tab starts

struct AgentTabLaunch: Equatable {
    var executable: String
    var args: [String]
    var directory: String
    /// The text after `-c` ("" for a plain login shell).
    var script: String
}

enum AgentTabLauncher {
    /// Single-quotes a string for a POSIX shell (and fish): every `'` becomes `'\''`.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `/bin/zsh -l -i -c 'cd <folder> && exec claude'`: a login shell (so the profile sets PATH), interactive too
    /// (so a PATH set in ~/.zshrc, where installers put it, applies), then the agent replaces the shell.
    /// `override` is the scripted-run test command (never an agent): it runs under /bin/sh without any profile.
    static func make(kind: AgentTabKind, folder: String, resume: Bool, shell: String, override: String? = nil) -> AgentTabLaunch {
        let path = AgentTabFolder.normalized(folder)
        let directory = AgentTabFolder.exists(path) ? path : AgentTabFolder.home
        if let override, !override.isEmpty {
            let script = "cd \(quote(path)) && exec \(override)"
            return AgentTabLaunch(executable: "/bin/sh", args: ["-c", script], directory: directory, script: script)
        }
        guard kind.isAgent else {
            return AgentTabLaunch(executable: shell, args: ["-l"], directory: directory, script: "")
        }
        let command = resume ? kind.resumeCommand : kind.command
        let script = "cd \(quote(path)) && exec \(command)"
        return AgentTabLaunch(executable: shell, args: ["-l", "-i", "-c", script], directory: directory, script: script)
    }

    /// The child's environment: Scout's own (so SSH_AUTH_SOCK and the like arrive) with a terminal's TERM.
    static func environment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if !(env["LANG"] ?? "").uppercased().contains("UTF-8") { env["LANG"] = "en_US.UTF-8" }
        for key in env.keys where key.hasPrefix("SCOUT_") { env[key] = nil }
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }
}
#endif
