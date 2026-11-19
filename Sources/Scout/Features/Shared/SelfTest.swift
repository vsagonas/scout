import Foundation

/// Tiny self-checks for the features' pure logic. Run with:
///   SCOUT_SELFTEST=1 build/Scout.app/Contents/MacOS/Scout --gallery /tmp/x --only zzz
/// (offscreen, no windows). Each area adds its checks to `FeaturesSelfTest.cases`.
@MainActor
enum FeaturesSelfTest {
    static var cases: [(String, () -> Bool)] = []

    static func add(_ name: String, _ check: @escaping () -> Bool) { cases.append((name, check)) }

    private final class Box<T>: @unchecked Sendable { var value: Result<T, Error>? }

    /// Runs an async operation to completion off the main actor while this (main) thread waits (tests only).
    static func block<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
        let box = Box<T>()
        Task.detached {
            do { box.value = .success(try await operation()) } catch { box.value = .failure(error) }
        }
        let deadline = Date().addingTimeInterval(60)
        while box.value == nil && Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        return box.value ?? .failure(ConvertError.failed("timed out"))
    }

    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["SCOUT_SELFTEST"] == "1" else { return }
        var failed = 0
        for (name, check) in cases {
            let ok = check()
            if !ok { failed += 1 }
            print("selftest \(ok ? "ok  " : "FAIL") \(name)")
        }
        print("selftest done: \(cases.count - failed)/\(cases.count) passed")
    }
}
