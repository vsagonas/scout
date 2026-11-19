import AppKit

/// `scout://debug.selftest?out=<file>` (headless runs): a `scout://` link outside automation runs only the app's own
/// commands (`DebugCommands.publicCommands`), with only the parameters the app passes, and never writes to an `out=` path.
/// The check calls `DebugCommands.run(url:automation: false)`, which is what a link from a web page reaches in the shipped app.
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

        // 1. The app's own link (the menu bar's "Open Ring") is on the list and keeps its x and y.
        check("the menu bar's own link (ring.open) is allowed outside automation", DebugCommands.publicCommands["ring.open"] != nil)
        var ringRuns: [[String: String]] = []
        DebugCommands.withProbe("ring.open", { ringRuns.append($0) }) {
            DebugCommands.run(url: link("scout://ring.open?x=120&y=340"), automation: false)
        }
        check("  it runs and gets its x and y", ringRuns.count == 1 && ringRuns.first == ["x": "120", "y": "340"], "\(ringRuns)")
        ringRuns = []
        DebugCommands.withProbe("ring.open", { ringRuns.append($0) }) {
            DebugCommands.run(url: link("scout://ring.open?x=1&y=2&out=\(target.path)&sticky=1&pin=1&page=3"), automation: false)
        }
        check("  every other parameter (out, sticky, pin, page) is dropped", ringRuns.count == 1 && ringRuns.first == ["x": "1", "y": "2"], "\(ringRuns)")

        // 2. Anything else does nothing outside automation.
        var probed: [String] = []
        let others = ["quit", "ping", "commands", "windows", "notch.open", "ring.close", "clipboard.pause", "tool.screenshot", "agents.demo", "agents.decide",
                      "tray.convert", "ai.selftest", "icon.export", "zz.probe"]
        for name in others {
            DebugCommands.withProbe(name, { _ in probed.append(name) }) {
                DebugCommands.run(url: link("scout://\(name)?out=\(target.path)&dir=\(folder.path)"), automation: false)
            }
        }
        check("\(others.count) other commands (quit, ping, windows, recordings, demos, tests…) do not run outside automation", probed.isEmpty, "\(probed)")
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
