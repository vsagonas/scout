#if !APPSTORE
import AppKit
import Combine
import SwiftUI

/// The agent tabs of this run, the previous run's tabs offered as "Resume", the folders used before, and which
/// of the agents are installed. One shared store feeds the notch header, the tab content and Settings.
@MainActor
final class AgentTabStore: ObservableObject {
    static let shared = AgentTabStore()

    /// Which agent commands the user's login shell can find (found by `command -v`, never by running them).
    struct Tools: Equatable {
        var checked = false
        var claude: String?
        var codex: String?
    }

    @Published private(set) var tabs: [AgentTab] = []
    @Published private(set) var resumable: [AgentTabRecord] = []
    @Published private(set) var recentFolders: [String] = []
    @Published var tools = Tools()

    static let holdReason = "terminal.tabs"
    static let maxRecents = 6
    static let maxResumable = 8
    static let confirmCloseKey = "term.tab.confirmClose"
    /// Settings › Terminal › Agent tabs: bring last run's tabs back by themselves after a restart (on by default).
    static let restoreKey = "term.tab.restore"

    /// Where the tabs are kept between runs (scripted runs use Scout-Automation).
    private let stateURL: URL
    private let persistent: Bool
    /// Scripted runs only: runs this command (never an agent) in every tab, under /bin/sh.
    var commandOverride: String?
    /// Self-tests only: the program that runs a tab's command line instead of the user's login shell (with the agent
    /// commands pointed at harmless ones in the settings, a check can see which of start and resume ran).
    var shellOverride: String?
    var navigator: NotchNavigator
    /// The tab whose terminal should take the keyboard as soon as it appears (set by selecting or creating).
    private(set) var focusRequest: String?

    private var timer: Timer?
    /// Forwards each tab's changes (waiting, ended) so the header redraws its dots.
    private var tabWatchers: [String: AnyCancellable] = [:]
    private var monitor: Any?
    private var lastDetect = Date.distantPast
    private var detecting = false

    /// `persistent: false` is for the self-tests: no key monitor, no timer, no login-shell check (the state file
    /// is still written, to the `stateURL` given).
    init(stateURL: URL = AppPaths.file("terminal-tabs.json"), commandOverride: String? = nil,
         navigator: NotchNavigator? = nil, persistent: Bool = true) {
        self.stateURL = stateURL
        self.persistent = persistent
        self.navigator = navigator ?? NotchNavigator.shared
        if let commandOverride {
            self.commandOverride = commandOverride
        } else if ScoutRuntime.isScripted, let env = ProcessInfo.processInfo.environment["SCOUT_TERMTAB_COMMAND"], !env.isEmpty {
            self.commandOverride = env
        }
        load()
        if persistent { installKeyMonitor() }
    }

    // MARK: What may start

    /// Scripted runs never start the user's tools; only a test command may start there.
    var canStartProcesses: Bool { !ScoutRuntime.isScripted || commandOverride != nil || shellOverride != nil }

    private var shell: String { shellOverride ?? TerminalSession.shellPath }

    /// The kinds the "+" menu offers: Codex only when the login shell finds a `codex` command.
    var availableKinds: [AgentTabKind] {
        AgentTabKind.allCases.filter { $0 != .codex || tools.codex != nil }
    }

    var infos: [AgentTabInfo] { tabs.map(\.info) }

    func tab(id: String) -> AgentTab? { tabs.first { $0.id == id } }

    /// The newest running tab that started in `folder` (for linking an Agents tile to its tab).
    func tab(forFolder folder: String, startedBefore date: Date = .distantFuture) -> AgentTab? {
        let path = AgentTabFolder.normalized(folder)
        return tabs.filter { $0.folder == path && $0.isRunning && $0.startedAt <= date }.max { $0.startedAt < $1.startedAt }
    }

    // MARK: Create, resume, close

    @discardableResult
    func create(kind: AgentTabKind, folder: String, resume: Bool = false, select: Bool = true) -> AgentTab {
        let tab = AgentTab(kind: kind, folder: folder)
        tab.store = self
        tabWatchers[tab.id] = tab.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        tabs.append(tab)
        remember(folder: tab.folder)
        if canStartProcesses {
            tab.start(resume: resume, shell: shell, override: commandOverride)
        }
        save()
        updateTimer()
        if select { self.select(tab) }
        return tab
    }

    /// Starts a previous run's tab again (the agent's own "continue" command in the same folder).
    @discardableResult
    func resume(_ record: AgentTabRecord, select: Bool = true) -> AgentTab {
        resumable.removeAll { $0.id == record.id }
        return create(kind: record.kind, folder: record.folder, resume: true, select: select)
    }

    /// After a restart the last run's tabs come back by themselves: each in its folder, the agents continuing where they were
    /// (the kind's resume command; a plain terminal just opens in its folder). Off in Settings: they wait under "+ › Resume".
    /// Never in scripted runs, which start nothing unless a test sets a harmless command.
    func restoreOnLaunch() {
        guard Pref.bool(Self.restoreKey, true), canStartProcesses, tabs.isEmpty else { return }
        for record in resumable { resume(record, select: false) }
    }

    /// Runs an ended tab again, in the same folder (`resume` = the agent's own "continue" command).
    func restart(_ tab: AgentTab, resume: Bool) {
        guard canStartProcesses else { return }
        tab.start(resume: resume, shell: shell, override: commandOverride)
        save()
        updateTimer()
        select(tab)
    }

    func forgetResumable() {
        resumable = []
        save()
    }

    func forgetRecentFolders() {
        recentFolders = []
        save()
    }

    /// Ends a running tab and removes it. With the confirmation setting on, a running tab asks first.
    func requestClose(_ tab: AgentTab) {
        let ask = Pref.bool(Self.confirmCloseKey, true)
        if tab.isRunning, ask, !tab.confirmingClose {
            tab.confirmingClose = true
            if navigator.activeTab != tab.id { select(tab) }
            return
        }
        close(tab)
    }

    func close(_ tab: AgentTab) {
        tab.terminate()
        tabs.removeAll { $0.id == tab.id }
        tabWatchers[tab.id] = nil
        if navigator.activeTab == tab.id { navigator.activeTab = nil }
        if focusRequest == tab.id { focusRequest = nil }
        save()
        updateTimer()
        refreshHold()
    }

    /// Called by a tab when its process ended.
    func tabEnded(_ tab: AgentTab) {
        refreshHold()
        objectWillChange.send()
    }

    // MARK: Selecting and the keyboard

    /// Shows the tab in the open notch (opening it first when closed) and puts the keyboard in its terminal.
    func select(_ tab: AgentTab) {
        focusRequest = tab.id
        tab.markViewed()
        if !navigator.isOpen { navigator.open() }
        if navigator.activeTab == tab.id {
            DispatchQueue.main.async { [weak self] in self?.focus(tab) }
        } else {
            navigator.activeTab = tab.id
        }
    }

    /// The host calls this when the tab's terminal appears: true once per request.
    func consumeFocusRequest(_ id: String) -> Bool {
        guard focusRequest == id else { return false }
        focusRequest = nil
        return true
    }

    /// Makes the notch panel key (it never activates Scout) and the terminal its first responder.
    func focus(_ tab: AgentTab, attempt: Int = 0) {
        guard let v = tab.view else { return }
        if let panel = v.window as? NotchPanel, panel.allowsKey {
            if !panel.isKeyWindow { panel.makeKey() }
            panel.makeFirstResponder(v)
        } else if attempt < 5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.focus(tab, attempt: attempt + 1) }
        }
    }

    /// The notch stays open while a tab's terminal has the keyboard (like typing in a text field).
    func refreshHold() {
        let focused = tabs.contains { tab in
            guard let v = tab.view, let window = v.window else { return false }
            return window.isKeyWindow && window.firstResponder === v
        }
        let held = navigator.holdOpenReasons.contains(Self.holdReason)
        if focused || tabs.contains(where: \.confirmingClose) {
            if !held { navigator.hold(Self.holdReason) }
        } else if held {
            navigator.release(Self.holdReason)
        }
    }

    private func updateTimer() {
        guard persistent else { return }
        if tabs.isEmpty {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        var ticks = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshHold()
                ticks += 1
                if ticks % 4 == 0 {
                    for tab in self.tabs {
                        tab.tick(viewed: self.navigator.isOpen && self.navigator.activeTab == tab.id)
                    }
                }
            }
        }
    }

    // MARK: ⌘W

    private func installKeyMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags
            let characters = event.charactersIgnoringModifiers
            let handled = MainActor.assumeIsolated {
                self.handleKeyDown(flags: flags, characters: characters, requireNotchKey: true)
                    || self.handleEditingKey(flags: flags, characters: characters, terminal: NSApp.keyWindow?.firstResponder as? NotchTerminalView)
            }
            return handled ? nil : event
        }
    }

    /// ⌘W while a tab is shown closes it (asking first while it runs; a second ⌘W confirms).
    @discardableResult
    func handleKeyDown(flags: NSEvent.ModifierFlags, characters: String?, requireNotchKey: Bool) -> Bool {
        guard flags.intersection(.deviceIndependentFlagsMask) == .command,
              characters?.lowercased() == "w",
              navigator.isOpen, let id = navigator.activeTab, let tab = tab(id: id) else { return false }
        if requireNotchKey, !(NSApp.keyWindow is NotchPanel) { return false }
        if tab.confirmingClose { close(tab) } else { requestClose(tab) }
        return true
    }

    /// Scout has no Edit menu, which is what normally routes ⌘V / ⌘C / ⌘A to a terminal, so a tab's terminal gets them here.
    @discardableResult
    func handleEditingKey(flags: NSEvent.ModifierFlags, characters: String?, terminal: NotchTerminalView?) -> Bool {
        guard let terminal, tabs.contains(where: { $0.view === terminal }),
              flags.intersection(.deviceIndependentFlagsMask) == .command else { return false }
        switch characters?.lowercased() {
        case "v": terminal.paste(self)
        case "c": terminal.copy(self)
        case "a": terminal.selectAll(self)
        default: return false
        }
        return true
    }

    // MARK: Folders

    func remember(folder: String) {
        let path = AgentTabFolder.normalized(folder)
        recentFolders.removeAll { $0 == path }
        recentFolders.insert(path, at: 0)
        if recentFolders.count > Self.maxRecents { recentFolders = Array(recentFolders.prefix(Self.maxRecents)) }
    }

    /// Recent folders that still exist, newest first.
    var folderChoices: [String] { recentFolders.filter(AgentTabFolder.exists) }

    /// "Choose Folder…": a folder picker, then the new tab.
    func chooseFolder(for kind: AgentTabKind) {
        guard !ScoutRuntime.isScripted else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.navigator.hold("terminal.choose")
            defer { self.navigator.release("terminal.choose") }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = String(localized: "Choose")
            panel.message = String(localized: "The folder \(kind.title) starts in")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            self.create(kind: kind, folder: url.path)
        }
    }

    // MARK: Appearance

    func applyAppearance() { tabs.forEach { $0.applyAppearance() } }

    // MARK: Which agents are installed

    /// Asks the user's login shell where `claude` and `codex` are (`command -v`, which never runs them).
    /// At most every half hour (or on "Check again"); never in scripted runs.
    func refreshTools(force: Bool = false) {
        guard persistent, !ScoutRuntime.isScripted, !detecting,
              force || Date().timeIntervalSince(lastDetect) > 1800 else { return }
        detecting = true
        let shell = TerminalSession.shellPath
        let words = [AgentTabKind.claude.commandWord, AgentTabKind.codex.commandWord]
        let out = AppPaths.file("tools-check.txt")
        Task.detached(priority: .utility) {
            let text = Self.runLookup(shell: shell, words: words, output: out)
            await MainActor.run {
                let found = Self.parseLookup(text)
                self.tools = Tools(checked: true, claude: found[words[0]], codex: found[words[1]])
                self.lastDetect = Date()
                self.detecting = false
            }
        }
    }

    /// The shell script that prints one `SCOUTFOUND:name=path` line per command (no loops: it must also run in fish).
    nonisolated static func lookupScript(words: [String]) -> String {
        words.map { "printf 'SCOUTFOUND:%s=%s\\n' \(AgentTabLauncher.quote($0)) \"$(command -v \(AgentTabLauncher.quote($0)))\"" }
            .joined(separator: "; ")
    }

    nonisolated static func parseLookup(_ text: String) -> [String: String] {
        var found: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("SCOUTFOUND:") {
            let pair = line.dropFirst("SCOUTFOUND:".count)
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let name = String(pair[pair.startIndex..<eq])
            let path = String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("/") { found[name] = path }
        }
        return found
    }

    /// Runs the lookup in a login + interactive shell with no input, giving up after eight seconds.
    nonisolated private static func runLookup(shell: String, words: [String], output: URL) -> String {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: output) else { return "" }
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", lookupScript(words: words)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.3)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        return (try? String(contentsOf: output, encoding: .utf8)) ?? ""
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder.scout.decode(AgentTabState.self, from: data) else { return }
        recentFolders = state.recentFolders.filter(AgentTabFolder.exists)
        // Last run's tabs come back as "Resume" entries; nothing starts by itself.
        resumable = Array(state.tabs.filter { AgentTabFolder.exists($0.folder) }.suffix(Self.maxResumable))
    }

    private func save() {
        let live = tabs.map(\.record)
        let kept = resumable.filter { old in !live.contains { $0.id == old.id } }
        var all = kept + live
        if all.count > Self.maxResumable + 4 { all = Array(all.suffix(Self.maxResumable + 4)) }
        let state = AgentTabState(tabs: all, recentFolders: recentFolders)
        guard let data = try? JSONEncoder.scout.encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    // MARK: Samples (gallery only)

    func installSamples(tabs sample: [AgentTab], resumable records: [AgentTabRecord] = [], recents: [String] = [], tools: Tools = Tools()) {
        tabs = sample
        resumable = records
        recentFolders = recents
        self.tools = tools
    }
}
#endif
