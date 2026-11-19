import Foundation

// Headless self-tests share one process when a run asks for several (`--run` twice): every `--run` starts its test as a task at once, so
// two tests interleave on the main actor. Tests that borrow the same global things (the 8-bit or minimal look in the defaults, the shared
// Radio store and model, the notch tab list) take this gate for their whole run and go one after the other, in the order they were asked.
// Each of them also puts back what it borrowed, so the order never matters between processes either (the same settings domain).

@MainActor
final class SelfTestGate {
    static let shared = SelfTestGate()

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Runs `body` alone: when another test holds the gate, this one waits for its turn.
    func exclusive<T>(_ body: () async -> T) async -> T {
        if busy {
            await withCheckedContinuation { waiting.append($0) }   // the gate is handed over still busy
        } else {
            busy = true
        }
        let result = await body()
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        return result
    }
}

/// Settings a self-test borrows: the keys are cleared (so the app's own defaults apply) and `restore()` puts back what each held.
struct SelfTestSettings {
    private let saved: [(key: String, value: Any?)]

    init(clearing keys: [String]) {
        saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    func restore() {
        for item in saved { UserDefaults.standard.set(item.value, forKey: item.key) }   // nil removes the key again
    }
}
