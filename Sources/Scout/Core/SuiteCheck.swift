import Foundation

/// The bookkeeping of a headless self-test: one line per check ("<suite> selftest ok  …" or "<suite> selftest FAIL …"), a last line
/// "<suite> selftest done: all passed" or "… N FAILED", printed and written to the `out` file the run was given.
@MainActor
final class SuiteCheck {
    let suite: String
    private(set) var lines: [String] = []
    private(set) var failed = 0

    init(_ suite: String) { self.suite = suite }

    func callAsFunction(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if !ok { failed += 1 }
        let extra = ok ? "" : detail()
        lines.append("\(suite) selftest \(ok ? "ok  " : "FAIL") \(name)\(extra.isEmpty ? "" : "  (\(extra))")")
    }

    func finish(out: URL) {
        lines.append("\(suite) selftest done: \(failed == 0 ? "all passed" : "\(failed) FAILED")")
        for line in lines { print(line) }
        fflush(stdout)
        try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
    }

    /// Registers `scout://<command>?out=<file>` (automation runs only): runs `body`, then writes the result.
    static func register(_ command: String, suite: String, _ body: @escaping @MainActor (SuiteCheck) -> Void) {
        DebugCommands.register(command) { params in
            guard ScoutRuntime.isAutomation else { return }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("\(command).txt")
            Task { @MainActor in
                let check = SuiteCheck(suite)
                body(check)
                check.finish(out: out)
            }
        }
    }
}
