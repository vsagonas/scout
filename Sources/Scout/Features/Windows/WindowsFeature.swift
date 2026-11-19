import AppKit

/// Windows: Scout's own windows come back after a quit, an update or a restart as they were (which were open, on which display, where
/// and how big). The window snapping and every Magnet-style feature (magnetic edges, drag to a screen edge, shortcuts, saved layouts, the
/// status menu's Arrange and the ring's Windows tool) are gone at the owner's word.
/// `Modules.startAll()` starts it; `HeadlessChecks` registers its self-tests.
@MainActor
enum WindowsFeature {
    static func start() { WinResume.shared.start() }

    static func registerGallery() {
        FeatureGallery.settings("windows-settings", height: 300) { WinSettingsPane() }
    }

    static func registerSelfTests() { WinSelfTests.register() }
}
