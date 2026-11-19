import SwiftUI

// This module starts everything in Productivity/: the shared stores (clipboard, notes, to-dos, clock, links,
// pinned apps) and their faces in the notch (widgets, the Clipboard workspace and bottom shelf).

@MainActor
enum ProductivityModule {
    static func start() {
        ClipboardStore.shared.start()
        ClockService.shared.start()
        ClipboardShelfController.shared.start()
        _ = TodoStore.shared   // applies the auto-clear of old completed tasks at launch
    }

    static func registerGallery() {
        ProductivityGallery.register()
    }
}
