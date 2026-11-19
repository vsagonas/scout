import AppKit
import SwiftUI

/// What happens when things are dropped on the Tray, the Keep zone or the Tray widget.
@MainActor
enum TrayDrop {
    static func handle(_ providers: [NSItemProvider], into store: TrayStore, opensTray: Bool) async {
        let things = await DropReader.read(providers)
        guard !things.isEmpty else { return }
        store.start()
        let added = store.add(things)
        if !added.isEmpty {
            store.selection = Set(added.map(\.id))
            let n = added.count
            Toast.show(n == 1 ? "Kept in the Tray" : "Items kept in the Tray: \(n)", symbol: "tray.full.fill")
        }
        // A dropped video link can be offered for download (C9).
        for case .link(let url) in things { VideoOfferHook.linkDropped(url) }
        if opensTray { NotchNavigator.shared.open(.tray) }
    }
}

/// C9 plugs in here: when the Tray opens (clipboard link) or a link is dropped, the video offer may appear.
@MainActor
enum VideoOfferHook {
    static var onTrayOpened: (() -> Void)?
    static var onLinkDropped: ((URL) -> Void)?
    static func trayOpened() { onTrayOpened?() }
    static func linkDropped(_ url: URL) { onLinkDropped?(url) }
}
