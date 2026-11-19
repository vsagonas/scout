import AppKit

/// `scout://<command>?key=value` deep links, for scripted checks (`--automation` runs). Outside automation nothing runs
/// (`publicCommands` is empty): the shipped app registers the scheme, so a link on a web page must not be able to do anything.
/// Each module registers its commands in its module's `start()`, e.g. `scout://notch.open?ws=nook`.
@MainActor
enum DebugCommands {
    typealias Handler = ([String: String]) -> Void

    private static var handlers: [String: Handler] = [:]
    private static var installed = false

    static func register(_ name: String, _ handler: @escaping Handler) {
        handlers[name] = handler
    }

    /// Call from `applicationWillFinishLaunching` so URLs that launched the app are not lost.
    static func install() {
        guard !installed else { return }
        installed = true
        NSAppleEventManager.shared().setEventHandler(Receiver.shared, andSelector: #selector(Receiver.handle(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
        runLaunchCommands()
        register("ping") { _ in
            try? "pong \(Date())".write(to: AppPaths.file("debug-ping.txt"), atomically: true, encoding: .utf8)
        }
        register("quit") { _ in NSApp.terminate(nil) }
        register("commands") { params in
            let list = handlers.keys.sorted().joined(separator: "\n")
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("debug-commands.txt")
            try? list.write(to: out, atomically: true, encoding: .utf8)
        }
        // Writes the visible windows (number, class, frame, level) as JSON, for `screencapture -l <number>`.
        register("windows") { params in
            let rows: [[String: Any]] = NSApp.windows.filter(\.isVisible).map { w in
                ["number": w.windowNumber, "class": String(describing: type(of: w)), "title": w.title,
                 "frame": NSStringFromRect(w.frame), "level": w.level.rawValue]
            }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("debug-windows.json")
            if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]) {
                try? data.write(to: out)
            }
        }
    }

    /// `--run <scout://url>` (repeatable, `--automation` only): runs these commands in order one second after launch, so a
    /// check drives ITS OWN build, started directly as `build/Scout.app/Contents/MacOS/Scout --automation --headless --run …`
    /// and stopped with `kill <its pid>`. `open "scout://…"` and `open -a` can hand the URL to the owner's running Scout.
    private static func runLaunchCommands() {
        guard ScoutRuntime.isAutomation else { return }
        let args = ScoutRuntime.arguments
        let urls = args.indices.compactMap { i -> URL? in
            guard args[i] == "--run", i + 1 < args.count else { return nil }
            return URL(string: args[i + 1])
        }
        guard !urls.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated { urls.forEach { run(url: $0) } }
        }
    }

    /// What a `scout://` link may do OUTSIDE automation runs (the shipped app registers the scheme, so any web page can
    /// open such a link): nothing, because the app opens none of its own windows through a link. Everything (quit, recording,
    /// pausing the clipboard, demo and test commands, anything that writes to an `out=` or `dir=` path) runs in `--automation`
    /// runs only. A command the app itself would open through a link goes here, with the only parameters it passes
    /// (`["name": ["x", "y"]]`).
    nonisolated static let publicCommands: [String: Set<String>] = [:]

    /// The name and parameters a command is allowed to run with, or nil when it must not run at all. `listed` is the list of commands
    /// a link may run outside automation: `publicCommands`, unless the self-test passes a list of its own.
    static func permitted(name: String, params: [String: String], automation: Bool,
                          listed: [String: Set<String>] = DebugCommands.publicCommands) -> [String: String]? {
        if automation { return params }
        guard let allowedKeys = listed[name] else { return nil }
        return params.filter { allowedKeys.contains($0.key) }
    }

    /// `automation` defaults to this run's flag, and `listed` to `publicCommands`; only the self-test passes other values.
    static func run(url: URL, automation: Bool = ScoutRuntime.isAutomation, listed: [String: Set<String>] = DebugCommands.publicCommands) {
        guard url.scheme?.lowercased() == "scout" else { return }
        let name = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var params: [String: String] = [:]
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.forEach { params[$0.name] = $0.value ?? "" }
        guard let allowed = permitted(name: name, params: params, automation: automation, listed: listed) else {
            NSLog("Scout: refused command %@ (outside automation a link runs only the listed commands)", name)
            return
        }
        if let handler = handlers[name] {
            handler(allowed)
        } else {
            NSLog("Scout: unknown command %@", name)
        }
    }

    /// For the self-test only: a handler under `name` for the length of `body`, then the previous one (or none) again.
    static func withProbe(_ name: String, _ handler: @escaping Handler, _ body: () -> Void) {
        let previous = handlers[name]
        handlers[name] = handler
        body()
        handlers[name] = previous
    }

    final class Receiver: NSObject {
        static let shared = Receiver()

        @objc func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
            guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
                  let url = URL(string: string) else { return }
            MainActor.assumeIsolated { DebugCommands.run(url: url) }
        }
    }
}
