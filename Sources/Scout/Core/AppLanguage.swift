import AppKit

/// Scout's own language (Settings › General): "Same as the Mac" (the default: the system's languages decide) or one of the languages Scout is
/// translated into. The choice is written as the app's own `AppleLanguages`, the same value System Settings › General › Language & Region ›
/// Applications writes. macOS reads it once, at launch, so a change needs a restart: `restart()` opens a new Scout and quits this one, and the
/// new one waits in `ScoutMain.main()` until the old one is gone (so it never meets the old one's listener, hot keys or windows).
@MainActor
enum AppLanguage {
    /// The chosen code, or "" for "Same as the Mac".
    static let key = "app.language"
    /// The new Scout's argument: wait for this process id to end before starting.
    static let afterFlag = "--after-pid"

    /// The language this run started in (read in `atLaunch()`): the Settings row offers Restart while the choice differs from it.
    private(set) static var launchedWith = ""
    /// What `atLaunch()` waited for (the self-test reads it): the old Scout's process id, whether it was gone in time, and how long it took.
    private(set) static var waitedFor: Int32 = 0
    private(set) static var oldOneGone = true
    private(set) static var waitedSeconds = 0.0

    static var chosen: String { UserDefaults.standard.string(forKey: key) ?? "" }

    /// Every language Scout is translated into (CFBundleLocalizations, English included), ordered by their own names.
    static var codes: [String] {
        let listed = (Bundle.main.object(forInfoDictionaryKey: "CFBundleLocalizations") as? [String]) ?? ["en"]
        return listed.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }

    /// A language in its own words, capitalised the way it writes: Deutsch, Ελληνικά, Português (Brasil), 中文（简体）, العربية.
    static func name(_ code: String) -> String {
        let locale = Locale(identifier: code)
        guard let own = locale.localizedString(forIdentifier: code), !own.isEmpty else { return code }
        return own.prefix(1).uppercased(with: locale) + own.dropFirst()
    }

    /// Stores the choice; "" goes back to the Mac's languages. Takes effect at the next launch.
    static func choose(_ code: String) {
        let defaults = UserDefaults.standard
        if code.isEmpty {
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set(code, forKey: key)
            defaults.set([code], forKey: "AppleLanguages")
        }
    }

    /// First thing in `ScoutMain.main()` (after the scripted-run settings are in place): when this Scout was opened by `restart()`, wait until
    /// the old one has quit (10 s at most), then note the language this run starts in.
    static func atLaunch() {
        let args = CommandLine.arguments
        var waited: (Int32, Bool, Double) = (0, true, 0)
        if let i = args.firstIndex(of: afterFlag), i + 1 < args.count, let pid = Int32(args[i + 1]), pid > 0, pid != getpid() {
            let start = Date()
            while isRunning(pid), Date().timeIntervalSince(start) < 10 { Thread.sleep(forTimeInterval: 0.1) }
            waited = (pid, !isRunning(pid), Date().timeIntervalSince(start))
        }
        (waitedFor, oldOneGone, waitedSeconds) = waited
        launchedWith = chosen
    }

    private static func isRunning(_ pid: Int32) -> Bool {
        if let app = NSRunningApplication(processIdentifier: pid) { return !app.isTerminated }
        return getpgid(pid) >= 0   // a process LaunchServices does not list (a plain tool in the self-test) still counts while it exists
    }

    /// Opens a new Scout in the chosen language and quits this one. `failed` gets macOS's reason when the new one could not open (this one stays).
    static func restart(failed: @escaping (String) -> Void = { _ in }) {
        guard !ScoutRuntime.isScripted else { return }
        relaunch(arguments: [], failed: failed)
    }

    /// The new Scout gets `afterFlag` + this process id (plus `arguments`, and in scripted runs the SCOUT_ settings of this run). This one quits
    /// when LaunchServices says the new one is starting, or after a second at most (the new one waits in `atLaunch()` before it starts its app).
    static func relaunch(arguments: [String], failed: @escaping (String) -> Void) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = false
        config.arguments = [afterFlag, String(getpid())] + arguments
        if ScoutRuntime.isScripted { config.environment = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("SCOUT_") } }
        var settled = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            Task { @MainActor in
                guard !settled else { return }
                settled = true
                if let error { failed(String(localized: "macOS would not change it: \(error.localizedDescription)")) } else { NSApp.terminate(nil) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard !settled else { return }
            settled = true
            NSApp.terminate(nil)
        }
    }
}

/// `scout://language.selftest?out=<file>` (headless runs): the language list and names, choosing and going back to the Mac's languages.
/// `scout://language.selftest.restart?out=<file>`: the real restart through LaunchServices. This run opens a new headless Scout that waits for
/// it to quit, then writes `out` (its own process id, the one it waited for, whether that one was gone, how long it took); kill that pid after.
@MainActor
enum AppLanguageSelfTest {
    static func register() {
        DebugCommands.register("language.selftest") { params in
            guard ScoutRuntime.isAutomation else { return }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("language-selftest.txt")
            try? run().joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        }
        DebugCommands.register("language.selftest.restart") { params in
            guard ScoutRuntime.isAutomation, let out = params["out"] else { return }
            AppLanguage.relaunch(arguments: ["--automation", "--headless", "--run", "scout://language.selftest.child?out=\(out)"]) { reason in
                try? "language selftest FAIL the new Scout did not open (\(reason))".write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        DebugCommands.register("language.selftest.child") { params in
            guard ScoutRuntime.isAutomation, let out = params["out"] else { return }
            let me = getpid(), old = AppLanguage.waitedFor
            let ok = old > 0 && old != me && AppLanguage.oldOneGone
            let line = "language selftest \(ok ? "ok  " : "FAIL") restarted: pid=\(me) waited for \(old), gone \(AppLanguage.oldOneGone), "
                + String(format: "%.2f s", AppLanguage.waitedSeconds)
            try? line.write(toFile: out, atomically: true, encoding: .utf8)
        }
    }

    static func run() -> [String] {
        var lines: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            lines.append("language selftest \(ok ? "ok  " : "FAIL") \(name)\(ok || detail.isEmpty ? "" : "  (\(detail))")")
        }
        let listed = (Bundle.main.object(forInfoDictionaryKey: "CFBundleLocalizations") as? [String]) ?? []
        let codes = AppLanguage.codes
        check("the menu offers every language of CFBundleLocalizations (\(listed.count))", Set(codes) == Set(listed) && codes.count == listed.count && listed.count >= 30, "\(codes.count) of \(listed.count)")
        let missing = codes.filter { $0 != "en" && !Bundle.main.localizations.contains($0) }
        check("  each one has its translation in the app", missing.isEmpty, "\(missing)")
        let names = codes.map(AppLanguage.name)
        check("  each one has a name of its own, none twice", names.allSatisfy { !$0.isEmpty } && Set(names).count == names.count && zip(codes, names).allSatisfy { $0 != $1 }, "\(names)")
        let want = ["en": "English", "de": "Deutsch", "el": "Ελληνικά", "fr": "Français", "ja": "日本語", "ar": "العربية", "tr": "Türkçe", "ru": "Русский"]
        let got = want.keys.sorted().map { "\($0)=\(AppLanguage.name($0))" }
        check("  written in its own words and capitalised (Deutsch, Ελληνικά, Français…)", want.allSatisfy { AppLanguage.name($0.key) == $0.value }, got.joined(separator: " "))
        check("  ordered by name (English among the Latin ones, Ελληνικά after them)", (codes.firstIndex(of: "de") ?? 99) < (codes.firstIndex(of: "en") ?? 0) && (codes.firstIndex(of: "en") ?? 99) < (codes.firstIndex(of: "el") ?? 0), "\(names)")

        let before = AppLanguage.chosen
        let defaults = UserDefaults.standard
        AppLanguage.choose("el")
        #if !APPSTORE
        let domain = defaults.persistentDomain(forName: DefaultsIsolation.suiteName) ?? [:]
        check("choosing Ελληνικά stores it and the app's own AppleLanguages", AppLanguage.chosen == "el" && (domain["AppleLanguages"] as? [String]) == ["el"], "\(AppLanguage.chosen) \(domain["AppleLanguages"] ?? "none")")
        #endif
        AppLanguage.choose("")
        #if !APPSTORE
        let cleared = defaults.persistentDomain(forName: DefaultsIsolation.suiteName) ?? [:]
        check("  «Same as the Mac» removes both (the Mac's languages decide again)", AppLanguage.chosen.isEmpty && cleared["AppleLanguages"] == nil && cleared[AppLanguage.key] == nil)
        #endif
        AppLanguage.choose(before)
        check("the language this run started in is noted (\(AppLanguage.launchedWith.isEmpty ? "the Mac's" : AppLanguage.launchedWith))", AppLanguage.launchedWith == before)
        check("a plain start waits for nobody", AppLanguage.waitedFor == 0 && AppLanguage.oldOneGone)
        let failed = lines.filter { $0.contains("FAIL") }.count
        lines.append("language selftest \(failed == 0 ? "PASSED" : "FAILED") (\(lines.count) checks, \(failed) failed)")
        return lines
    }
}
