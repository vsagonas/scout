import AppKit

/// Scout is a menu-bar app (no Dock icon). Its ordinary windows (Settings, the welcome tour, To-dos) must come
/// to the front AND take the keyboard when they open, whatever app is active. macOS 14's cooperative
/// `NSApp.activate()` is often refused for a menu-bar app: the window then opened behind the frontmost app,
/// unfocused. The older call below still brings Scout forward (checked on macOS 27 by `settings.selftest`).
@MainActor
enum WindowFront {
    static func show(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
