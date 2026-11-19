import AppKit

/// The windows of an offscreen run (headless self-tests, galleries) stand far outside every screen (-20000, -20000), but Mission Control
/// gathers every ordinary window of every app: while a test ran it showed them as loose thumbnails in the corner of the owner's screen.
/// In such a run every window Scout opens is marked
/// transient (Mission Control and Exposé leave transient windows out) and out of the window cycle. The real app never does this.
@MainActor
enum OffscreenWindows {
    private static var timer: Timer?

    /// True in the runs whose windows nobody is meant to see.
    static var applies: Bool { ScoutRuntime.isHeadless || ScoutRuntime.isGallery }

    /// Marks every window of this run, now and as they come (a short timer on the common modes: a test opens its windows at any moment,
    /// also while it turns the run loop by hand).
    static func keepOutOfMissionControl() {
        guard applies, timer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { NSApp.windows.forEach(mark) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Transient instead of managed or stationary; the rest of the window's behaviour stays as its owner set it.
    static func mark(_ window: NSWindow) {
        var behavior = window.collectionBehavior
        guard !behavior.contains(.transient) else { return }
        behavior.subtract([.managed, .stationary, .participatesInCycle])
        behavior.formUnion([.transient, .ignoresCycle])
        window.collectionBehavior = behavior
    }

    static func registerSelfTests() {
        FeaturesSelfTest.add("offscreen run: a window a test opens is transient within a moment, so Mission Control never shows it") {
            guard applies else { return true }
            let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 120, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let before = window.collectionBehavior.contains(.transient)
            window.orderFrontRegardless()
            let deadline = Date().addingTimeInterval(1)
            while !window.collectionBehavior.contains(.transient) && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            let after = window.collectionBehavior
            window.orderOut(nil)
            return !before && after.contains(.transient) && after.contains(.ignoresCycle) && !after.contains(.managed) && !after.contains(.stationary)
        }
    }
}
