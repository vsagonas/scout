import Foundation
import ObjectiveC

#if !APPSTORE

/// Scripted runs (`--automation`, `--gallery`) must never read or write the owner's real settings.
/// macOS 27 ignores CFFIXED_USER_HOME for preferences, so instead every `UserDefaults.standard` call
/// (including `@AppStorage`) is pointed at a separate domain, `com.vsag.Scout.automation`.
/// Installed first thing in `ScoutMain.main()`, before anything touches defaults. Normal runs are untouched.
/// Full edition only: the App Store build leaves this file out (App Review does not like method swizzling).
enum DefaultsIsolation {
    /// `SCOUT_DEFAULTS_SUITE=com.vsag.Scout.automation.<name>` gives one run a domain of its own, so test runs that happen at the same time
    /// (parallel runs) never flip each other's look or size. It can only name an automation domain, never the real one.
    static let suiteName: String = {
        let base = "com.vsag.Scout.automation"
        guard let wanted = ProcessInfo.processInfo.environment["SCOUT_DEFAULTS_SUITE"], wanted.hasPrefix(base + ".") else { return base }
        return wanted
    }()
    private(set) static var isActive = false

    private static let suite: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard

    static func installIfScripted() {
        guard ScoutRuntime.isScripted, !isActive else { return }
        guard let method = class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard)) else { return }
        let replacement: @convention(block) (AnyObject) -> UserDefaults = { _ in DefaultsIsolation.suite }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        isActive = true
    }
}
#endif   // the Mac App Store edition never swizzles UserDefaults (it is never run in scripted mode)
