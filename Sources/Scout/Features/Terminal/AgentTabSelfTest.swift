#if !APPSTORE
import AppKit
import SwiftTerm
import SwiftUI

// Self-checks for the agent tabs. Run (offscreen, no windows) with:
//   SCOUT_SELFTEST=1 build/Scout.app/Contents/MacOS/Scout --gallery /tmp/x --only zzz
// They start harmless commands only (/bin/cat, /bin/echo, /bin/pwd) through the store's test override, never an agent.

@MainActor
enum AgentTabSelfTest {
    static func register() {
        FeaturesSelfTest.add("termtabs: the folder is quoted safely and the command line is a login shell") { quoting() }
        FeaturesSelfTest.add("termtabs: the dashboard has one panel per tab, right after the Agents panel, and none in the App Store layout") { dashboardRow() }
        FeaturesSelfTest.add("termtabs: the login-shell lookup script and its output parse") { lookup() }
        // The checks that start processes need the main queue free to see a process end, so they run as a task while
        // the gallery renders (run with `--only termtabs`): their results follow as "selftest ok/FAIL" lines.
        FeaturesSelfTest.add("termtabs: process checks started (results follow while the gallery renders)") { startProcessChecks(); return true }
        FeaturesSelfTest.add("termtabs: the + menu offers Codex only when codex is found") { menu() }
    }

    // MARK: Headless: tabs come back after a relaunch

    /// Called from `HeadlessChecks.registerAll()`: `scout://termtab.selftest.relaunch?out=<file>`.
    static func registerHeadless() {
        DebugCommands.register("termtab.selftest.relaunch") { params in
            guard ScoutRuntime.isAutomation else { return }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("termtab-relaunch-selftest.txt")
            Task { @MainActor in
                let lines = await relaunchLines()
                try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Never starts a real agent: the agent commands in the (scripted run's own) settings are pointed at `echo`, and the tabs
    /// run under /bin/sh, so the output says which of "start" and "resume" ran.
    static func relaunchLines() async -> [String] {
        var lines: [String] = []
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failed += 1 }
            lines.append("termtab selftest \(ok ? "ok  " : "FAIL") \(name)\(ok || detail.isEmpty ? "" : "  (\(detail))")")
        }
        let fakes: [(AgentTabKind, String)] = [(.claude, "claude"), (.codex, "codex")]
        for (kind, word) in fakes {
            Pref.set("/bin/echo fake-\(word)-start", kind.commandKey)
            Pref.set("/bin/echo fake-\(word)-resume", kind.resumeKey)
        }
        defer {
            for (kind, _) in fakes { Pref.set(nil, kind.commandKey); Pref.set(nil, kind.resumeKey) }
            Pref.set(nil, AgentTabStore.restoreKey)
        }
        guard AgentTabKind.claude.command == "/bin/echo fake-claude-start", AgentTabKind.codex.resumeCommand == "/bin/echo fake-codex-resume" else {
            lines.append("termtab selftest FAIL the agent commands could not be faked: refusing to start anything")
            return lines
        }
        check("the real defaults resume where the agent left off (claude --continue, codex resume --last)",
              AgentTabKind.claude.defaultResume == "claude --continue" && AgentTabKind.codex.defaultResume == "codex resume --last" && AgentTabKind.shell.defaultResume.isEmpty)

        let dir = scratch("restore")
        let alpha = dir.appendingPathComponent("alpha", isDirectory: true), beta = dir.appendingPathComponent("beta", isDirectory: true)
        for folder in [alpha, beta] { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        func makeStore() -> AgentTabStore {
            let store = AgentTabStore(stateURL: dir.appendingPathComponent("tabs.json"), commandOverride: nil, navigator: NotchNavigator(), persistent: false)
            store.shellOverride = "/bin/sh"
            return store
        }

        // The first run: a Claude tab, a Codex tab and a plain terminal; the terminal is closed on purpose.
        let first = makeStore()
        let claude = first.create(kind: .claude, folder: alpha.path, select: false)
        let codex = first.create(kind: .codex, folder: beta.path, select: false)
        let shell = first.create(kind: .shell, folder: alpha.path, select: false)
        let started = await wait(5) { text(of: claude).contains("fake-claude-start") && text(of: codex).contains("fake-codex-start") && shell.isRunning }
        check("the first run starts its tabs with the start commands", started && !claude.startedWithResume)
        first.close(shell)
        // "Quit": the processes end, the records stay on disk (they were written when the tabs were made and closed).
        for tab in first.tabs { tab.terminate() }
        _ = await wait(3) { first.tabs.allSatisfy { !$0.isRunning } }

        // The relaunch: a new store reads the file; its tabs come back by themselves and resume.
        let second = makeStore()
        check("a relaunch finds last run's two tabs (the closed terminal is not among them) and has not started anything",
              second.tabs.isEmpty && second.resumable.count == 2 && second.resumable.map(\.kind) == [.claude, .codex], "\(second.resumable.map(\.kind))")
        second.restoreOnLaunch()
        guard second.tabs.count == 2 else {
            check("the tabs come back by themselves", false, "tabs \(second.tabs.count)")
            lines.append("termtab selftest done: \(failed) FAILED")
            return lines
        }
        let back = second.tabs
        let ran = await wait(5) { text(of: back[0]).contains("fake-claude-resume") && text(of: back[1]).contains("fake-codex-resume") }
        check("the tabs come back by themselves, in their folders, as Claude Code and Codex",
              back.map(\.kind) == [.claude, .codex] && back[0].folder == AgentTabFolder.normalized(alpha.path) && back[1].folder == AgentTabFolder.normalized(beta.path)
              && second.resumable.isEmpty, "kinds \(back.map(\.kind)) folders \(back.map(\.folder))")
        check("  and each runs its RESUME command, not the start command", ran && back.allSatisfy(\.startedWithResume)
              && !text(of: back[0]).contains("fake-claude-start") && !text(of: back[1]).contains("fake-codex-start"))
        check("  none of them is shown or selected (they are panels on the dashboard, nothing opens)", second.navigator.activeTab == nil && !second.navigator.isOpen)
        check("  and they are saved again for the next restart", ((try? String(contentsOf: dir.appendingPathComponent("tabs.json"), encoding: .utf8)) ?? "").contains(back[0].id))

        // The setting off: the tabs wait under "+ › Resume" instead.
        for tab in second.tabs { tab.terminate() }
        _ = await wait(3) { second.tabs.allSatisfy { !$0.isRunning } }
        Pref.set(false, AgentTabStore.restoreKey)
        let third = makeStore()
        third.restoreOnLaunch()
        check("with \"Bring my tabs back when Scout restarts\" off nothing starts and the tabs are offered under Resume", third.tabs.isEmpty && third.resumable.count == 2)

        lines.append("termtab selftest done: \(failed == 0 ? "all passed" : "\(failed) FAILED")")
        return lines
    }

    // MARK: Helpers

    static func wait(_ seconds: TimeInterval, until: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if until() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return until()
    }

    static func startProcessChecks() {
        Task { @MainActor in
            let checks: [(String, () async -> Bool)] = [
                ("termtabs: + creates a tab, its process runs, the notch shows it at 420 pt, a workspace leaves it", { await createAndSelect() }),
                ("termtabs: the terminal is hosted when the tab is shown", { await hosting() }),
                ("termtabs: waiting and ended raise the attention dot, viewing clears waiting", { await attention() }),
                ("termtabs: ⌘W asks first, then closes and ends the process", { await closing() }),
                ("termtabs: a relaunch offers the tabs as Resume and starts nothing", { await relaunch() }),
            ]
            var passed = 0
            for (name, check) in checks {
                let ok = await check()
                if ok { passed += 1 }
                print("selftest \(ok ? "ok  " : "FAIL") \(name)")
                fflush(stdout)
            }
            print("selftest done (termtabs processes): \(passed)/\(checks.count) passed")
            fflush(stdout)
        }
    }

    /// Prints where a check stopped (only when it fails) and returns false.
    static func fail(_ line: Int) -> Bool {
        print("termtabs selftest: stopped at AgentTabSelfTest.swift:\(line)")
        return false
    }

    static func scratch(_ name: String) -> URL {
        let dir = AppPaths.folder("termtab-selftest").appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func text(of tab: AgentTab) -> String {
        guard let view = tab.view else { return "" }
        return String(decoding: view.getBufferAsData(), as: UTF8.self)
    }

    static func makeStore(_ dir: URL, command: String = "/bin/cat") -> (AgentTabStore, NotchNavigator) {
        let nav = NotchNavigator()
        nav.isOpen = true
        let store = AgentTabStore(stateURL: dir.appendingPathComponent("tabs.json"), commandOverride: command, navigator: nav, persistent: false)
        return (store, nav)
    }

    // MARK: Checks

    static func quoting() -> Bool {
        let dir = scratch("quote").appendingPathComponent("it's a dir", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let real = AgentTabLauncher.make(kind: .claude, folder: dir.path, resume: false, shell: "/bin/zsh")
        let expected = "cd '\(AgentTabFolder.normalized(dir.path).replacingOccurrences(of: "'", with: "'\\''"))' && exec \(AgentTabKind.claude.command)"
        guard real.executable == "/bin/zsh", real.args == ["-l", "-i", "-c", expected], real.script == expected else { return fail(#line) }
        let resume = AgentTabLauncher.make(kind: .claude, folder: dir.path, resume: true, shell: "/bin/zsh")
        guard resume.script.hasSuffix("exec \(AgentTabKind.claude.resumeCommand)") else { return fail(#line) }
        let shell = AgentTabLauncher.make(kind: .shell, folder: dir.path, resume: false, shell: "/bin/zsh")
        guard shell.args == ["-l"], shell.script.isEmpty else { return fail(#line) }
        // The quoted script really lands in the folder, whatever is in its name.
        let probe = AgentTabLauncher.make(kind: .claude, folder: dir.path, resume: false, shell: "/bin/zsh", override: "/bin/pwd")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: probe.executable)
        process.arguments = probe.args
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && (out as NSString).lastPathComponent == "it's a dir"
    }

    static func dashboardRow() -> Bool {
        // No live panels in this check (a scripted run's sample to-dos are live since the live panels merged).
        let savedLive = LivePanelLookup.override
        LivePanelLookup.override = []
        defer { LivePanelLookup.override = savedLive }
        let nook = NookStore(persist: false, layout: [.media, .agents, .calendar])
        nook.liveOverride = NookLive(playing: true, openTodos: 0, agents: 2)
        nook.tabIDs = { ["t1", "t2"] }
        let items = nook.row
        guard items == [.panel(.media), .panel(.agents), .tab("t1"), .tab("t2"), .panel(.calendar)] else { return fail(#line) }
        // Tab panels are panels with a detail, and they are as wide as the Nook says; Edit Nook leaves them out.
        guard items.filter({ if case .tab = $0 { return true } else { return false } }).allSatisfy({ $0.hasDetail && $0.defaultSpan == NookMetrics.tabSpan }) else { return fail(#line) }
        nook.isEditing = true
        guard nook.row == [.panel(.media), .panel(.agents), .panel(.calendar)] else { return fail(#line) }
        nook.isEditing = false
        // No Agents panel: the tabs lead the row.
        let plain = NookStore(persist: false, layout: [.media, .calendar])
        plain.liveOverride = NookLive(playing: true, openTodos: 0, agents: 0)
        plain.tabIDs = { ["t1"] }
        return plain.row == [.tab("t1"), .panel(.media), .panel(.calendar)]
    }

    static func lookup() -> Bool {
        let script = AgentTabStore.lookupScript(words: ["claude", "codex"])
        guard script.contains("command -v 'claude'"), script.contains("command -v 'codex'"), !script.contains("for ") else { return fail(#line) }
        let found = AgentTabStore.parseLookup("zsh: noise\nSCOUTFOUND:claude=/opt/bin/claude\nSCOUTFOUND:codex=\nSCOUTFOUND:x=not-a-path\n")
        return found == ["claude": "/opt/bin/claude"]
    }

    static func createAndSelect() async -> Bool {
        let dir = scratch("create")
        let (store, nav) = makeStore(dir)
        let tab = store.create(kind: .claude, folder: dir.path)
        defer { store.close(tab) }
        guard await wait(3, until: { tab.isRunning && tab.pid != nil }) else { return fail(#line) }
        tab.view?.send(txt: "scout-tab-ok\n")
        guard await wait(3, until: { text(of: tab).contains("scout-tab-ok") }) else { return fail(#line) }
        let info = store.infos.first
        guard store.tabs.count == 1, info?.folder == AgentTabFolder.normalized(dir.path), info?.kind == .claude,
              info?.pid == tab.pid, let started = info?.startedAt, abs(started.timeIntervalSinceNow) < 10,
              store.tab(forFolder: dir.path)?.id == tab.id else { return fail(#line) }
        // Selected on creation: the island grows to the tab height; choosing a workspace leaves the tab.
        guard nav.activeTab == tab.id, nav.neededHeight(shown: .nook) == 420 else { return fail(#line) }
        nav.workspace = .tray
        guard nav.activeTab == nil, nav.neededHeight(shown: .tray) == (nav.workspaceHeight ?? 0) else { return fail(#line) }
        store.select(tab)
        guard nav.activeTab == tab.id, store.recentFolders.first == AgentTabFolder.normalized(dir.path) else { return fail(#line) }
        // The tab is on disk.
        let data = (try? Data(contentsOf: dir.appendingPathComponent("tabs.json"))) ?? Data()
        return String(decoding: data, as: UTF8.self).contains(tab.id)
    }

    static func hosting() async -> Bool {
        let dir = scratch("host")
        let (store, nav) = makeStore(dir)
        let tab = store.create(kind: .codex, folder: dir.path)
        defer { store.close(tab) }
        guard await wait(3, until: { tab.isRunning }), let terminal = tab.view else { return fail(#line) }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 320), styleMask: [.borderless], backing: .buffered, defer: true)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        window.contentView = container
        AgentTerminalHost.attach(terminal, to: container)
        container.layoutSubtreeIfNeeded()
        guard terminal.superview === container, terminal.window === window, terminal.frame.size == container.bounds.size else { return fail(#line) }
        // Scout has no Edit menu: the store routes ⌘A (and ⌘C / ⌘V) to a tab's terminal itself, and nothing else.
        guard store.handleEditingKey(flags: .command, characters: "a", terminal: terminal),
              !store.handleEditingKey(flags: .command, characters: "q", terminal: terminal),
              !store.handleEditingKey(flags: [.command, .shift], characters: "a", terminal: terminal),
              !store.handleEditingKey(flags: .command, characters: "a", terminal: nil) else { return fail(#line) }
        // Through the SwiftUI view the notch uses.
        let hosting = NSHostingView(rootView: AgentTabContentView(tabID: tab.id, navigator: nav, store: store))
        hosting.frame = CGRect(x: 0, y: 0, width: 640, height: 320)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        func contains(_ view: NSView) -> Bool { view === terminal || view.subviews.contains(where: contains) }
        let shown = contains(hosting)
        window.contentView = NSView()
        return shown
    }

    static func attention() async -> Bool {
        let dir = scratch("attention")
        let (store, _) = makeStore(dir)
        let tab = store.create(kind: .claude, folder: dir.path, select: false)
        defer { store.close(tab) }
        guard await wait(3, until: { tab.isRunning }), !tab.needsAttention else { return fail(#line) }
        tab.view?.send(txt: "x\n")
        guard await wait(3, until: { text(of: tab).contains("x") }) else { return fail(#line) }
        tab.tick(viewed: false, now: Date())
        guard !tab.waiting else { return fail(#line) }   // still busy: output just arrived
        tab.tick(viewed: false, now: Date().addingTimeInterval(AgentTab.quietSeconds + 1))
        guard tab.waiting, tab.needsAttention else { return fail(#line) }
        tab.tick(viewed: true, now: Date().addingTimeInterval(30))
        guard !tab.waiting else { return fail(#line) }
        // Ended: a dot that stays.
        tab.terminate()
        guard await wait(4, until: { tab.hasEnded }) else { return fail(#line) }
        return tab.needsAttention && !tab.isRunning && tab.pid == nil
    }

    static func closing() async -> Bool {
        let dir = scratch("close")
        let (store, nav) = makeStore(dir)
        let tab = store.create(kind: .claude, folder: dir.path)
        guard await wait(3, until: { tab.isRunning }), let terminal = tab.view else { return fail(#line) }
        store.requestClose(tab)
        guard tab.confirmingClose, store.tabs.count == 1, terminal.process.running else { return fail(#line) }   // asks first
        let handled = store.handleKeyDown(flags: .command, characters: "w", requireNotchKey: false)         // ⌘W confirms
        guard handled, store.tabs.isEmpty, nav.activeTab == nil else { return fail(#line) }
        guard await wait(4, until: { !terminal.process.running }) else { return fail(#line) }
        let data = (try? Data(contentsOf: dir.appendingPathComponent("tabs.json"))) ?? Data()
        return !String(decoding: data, as: UTF8.self).contains(tab.id)
    }

    static func relaunch() async -> Bool {
        let dir = scratch("relaunch")
        let (first, _) = makeStore(dir)
        let tab = first.create(kind: .claude, folder: dir.path)
        let shell = first.create(kind: .shell, folder: dir.path, select: false)
        defer { first.close(tab); first.close(shell) }
        guard await wait(3, until: { tab.isRunning && shell.isRunning }) else { return fail(#line) }
        // A new run reads the same file: both tabs are Resume entries and nothing is started.
        let (second, nav) = makeStore(dir, command: "/bin/echo scout-resumed")
        guard second.tabs.isEmpty, second.resumable.count == 2,
              second.resumable.contains(where: { $0.kind == .claude && $0.folder == AgentTabFolder.normalized(dir.path) }) else { return fail(#line) }
        guard let record = second.resumable.first(where: { $0.kind == .claude }) else { return fail(#line) }
        let resumed = second.resume(record)
        defer { second.close(resumed) }
        guard second.resumable.count == 1, second.tabs.count == 1, nav.activeTab == resumed.id else { return fail(#line) }
        guard await wait(4, until: { text(of: resumed).contains("scout-resumed") && resumed.hasEnded }), resumed.exitCode == 0 else { return fail(#line) }
        // Resume runs the agent's continue command in the same folder.
        let launch = AgentTabLauncher.make(kind: .claude, folder: dir.path, resume: true, shell: "/bin/zsh")
        return launch.script.contains(AgentTabFolder.normalized(dir.path)) && launch.script.hasSuffix(AgentTabKind.claude.resumeCommand)
            && !first.tabs.isEmpty
    }

    static func menu() -> Bool {
        let (store, _) = makeStore(scratch("menu"))
        store.installSamples(tabs: [], resumable: [AgentTabRecord(id: "r", kind: .claude, folder: NSHomeDirectory(), startedAt: Date())], recents: [], tools: .init(checked: true, claude: "/x/claude", codex: nil))
        let without = AgentTabMenuModel.make(store)
        store.tools = .init(checked: true, claude: "/x/claude", codex: "/x/codex")
        let with = AgentTabMenuModel.make(store)
        return without.entries.map(\.kind) == [.claude, .shell] && with.entries.map(\.kind) == [.claude, .codex, .shell]
            && with.resumable.count == 1 && with.entries.allSatisfy { $0.folders.contains { $0.path == NSHomeDirectory() } }
    }
}
#endif
