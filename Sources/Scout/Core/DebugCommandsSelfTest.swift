import AppKit

/// `scout://debug.selftest?out=<file>` (headless runs): a `scout://` link outside automation runs nothing (`DebugCommands.publicCommands`
/// is empty) and never writes to an `out=` or `dir=` path. A command on a list would run with only the parameters listed for it: the check
/// proves that with a list of its own (`listed:`). It calls `DebugCommands.run(url:automation: false)`, which is what a link from a web page
/// reaches in the shipped app.
@MainActor
enum DebugCommandsSelfTest {
    static func register() {
        DebugCommands.register("debug.selftest") { params in
            guard ScoutRuntime.isAutomation else { return }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("debug-selftest.txt")
            let lines = run()
            try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        }
    }

    static func run() -> [String] {
        var lines: [String] = []
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failed += 1 }
            lines.append("debug selftest \(ok ? "ok  " : "FAIL") \(name)\(ok || detail.isEmpty ? "" : "  (\(detail))")")
        }
        func link(_ text: String) -> URL { URL(string: text)! }
        let fm = FileManager.default
        let folder = AppPaths.folder("SelfTest")
        let target = folder.appendingPathComponent("debug-selftest-written.txt")
        let windows = folder.appendingPathComponent("debug-selftest-windows.json")
        try? fm.removeItem(at: target)
        try? fm.removeItem(at: windows)

        // 1. The list of commands a link may run outside automation is empty.
        check("the list of commands a link may run outside automation is empty", DebugCommands.publicCommands.isEmpty, "\(DebugCommands.publicCommands)")

        // 1b. The mechanism, with a list of its own: a listed name runs with only the parameters listed for it, and a name that is not listed does not run.
        let list: [String: Set<String>] = ["zz.listed": ["x", "y"]]
        var listedRuns: [[String: String]] = []
        DebugCommands.withProbe("zz.listed", { listedRuns.append($0) }) {
            DebugCommands.run(url: link("scout://zz.listed?x=120&y=340"), automation: false, listed: list)
        }
        check("a listed command runs outside automation and gets its x and y", listedRuns.count == 1 && listedRuns.first == ["x": "120", "y": "340"], "\(listedRuns)")
        listedRuns = []
        DebugCommands.withProbe("zz.listed", { listedRuns.append($0) }) {
            DebugCommands.run(url: link("scout://zz.listed?x=1&y=2&out=\(target.path)&sticky=1&pin=1&page=3"), automation: false, listed: list)
        }
        check("  every other parameter (out, sticky, pin, page) is dropped", listedRuns.count == 1 && listedRuns.first == ["x": "1", "y": "2"], "\(listedRuns)")
        listedRuns = []
        DebugCommands.withProbe("zz.listed", { listedRuns.append($0) }) {
            DebugCommands.run(url: link("scout://zz.listed?x=1"), automation: false)
        }
        check("  with the real (empty) list the same link does not run", listedRuns.isEmpty, "\(listedRuns)")
        var unlistedRuns: [String] = []
        DebugCommands.withProbe("zz.other", { _ in unlistedRuns.append("ran") }) {
            DebugCommands.run(url: link("scout://zz.other?x=1"), automation: false, listed: list)
        }
        check("  a command that is not on the list does not run", unlistedRuns.isEmpty, "\(unlistedRuns)")

        // 2. Nothing runs outside automation: real commands, test commands, and names that no longer exist (the ring's) or never did.
        var probed: [String] = []
        let others = ["ring.open", "quit", "ping", "commands", "windows", "notch.open", "ring.close", "clipboard.pause", "tool.screenshot", "agents.demo", "agents.status",
                      "tray.convert", "ai.selftest", "icon.export", "zz.probe"]
        for name in others {
            DebugCommands.withProbe(name, { _ in probed.append(name) }) {
                DebugCommands.run(url: link("scout://\(name)?out=\(target.path)&dir=\(folder.path)"), automation: false)
            }
        }
        check("\(others.count) commands (quit, ping, windows, recordings, demos, tests…) do not run outside automation", probed.isEmpty, "\(probed)")
        check("  none of them is on the list", others.allSatisfy { DebugCommands.publicCommands[$0] == nil })

        // 3. The real commands that write files: refused outside automation, honoured in automation.
        DebugCommands.run(url: link("scout://windows?out=\(windows.path)"), automation: false)
        DebugCommands.run(url: link("scout://commands?out=\(target.path)"), automation: false)
        check("the real windows and commands links write nothing outside automation", !fm.fileExists(atPath: windows.path) && !fm.fileExists(atPath: target.path))
        DebugCommands.run(url: link("scout://windows?out=\(windows.path)"), automation: true)
        check("  in automation the same windows link writes its file", fm.fileExists(atPath: windows.path))
        try? fm.removeItem(at: windows)
        try? fm.removeItem(at: target)

        // 4. Automation keeps every command and every parameter (the self-tests and live.sh depend on it).
        var automated: [String: String] = [:]
        DebugCommands.withProbe("zz.probe", { automated = $0 }) {
            DebugCommands.run(url: link("scout://zz.probe?out=/x&a=1&sticky=1"), automation: true)
        }
        check("in automation a command runs with all its parameters", automated == ["out": "/x", "a": "1", "sticky": "1"], "\(automated)")

        // 5. Other schemes and odd names do nothing and do not crash.
        probed = []
        DebugCommands.withProbe("zz.probe", { _ in probed.append("ran") }) {
            DebugCommands.run(url: link("https://zz.probe/?out=/x"), automation: true)
            DebugCommands.run(url: link("scout://%25n%25@%25d?out=/x"), automation: false)
            DebugCommands.run(url: link("scout://"), automation: false)
        }
        check("a link of another scheme, a name with % signs and an empty link do nothing", probed.isEmpty, "\(probed)")

        lines.append("debug selftest \(failed == 0 ? "PASS" : "FAIL (\(failed))")")
        return lines
    }
}
