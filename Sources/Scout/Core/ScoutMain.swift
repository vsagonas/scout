import AppKit

/// Entry point. Normal launch = menu-bar agent (no Dock icon).
/// `--gallery <dir>` renders every registered view to PNG files and quits (no notch, no ring, no hotkeys).
@main
@MainActor
enum ScoutMain {
    private static var retainedDelegate: NSApplicationDelegate?

    static func main() {
        L10nRuntime.applyScriptedLanguage()
        #if !APPSTORE
        DefaultsIsolation.installIfScripted()   // scripted runs keep their own settings; the App Store edition does not swizzle
        #endif
        AppLanguage.atLaunch()   // after a language restart: wait for the old Scout to quit, then note the language this run starts in
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if let output = ScoutRuntime.galleryOutput {
            retainedDelegate = GalleryRunner(output: output)
        } else {
            retainedDelegate = AppDelegate.shared
        }
        app.delegate = retainedDelegate
        app.run()
    }
}
