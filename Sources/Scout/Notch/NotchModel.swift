import AppKit
import SwiftUI

/// The state of ONE notch (one per screen) that its SwiftUI view reads. The manager writes it.
@MainActor
final class NotchScreenModel: ObservableObject {
    var geometry: NotchGeometry
    /// Size of the fixed window frame the SwiftUI content lives in.
    var panelSize: CGSize

    /// This screen's notch is the open one.
    @Published var isOpen = false
    /// The pointer rests on the closed notch and the hover setting is "show what's happening".
    @Published var detailVisible = false
    /// Hidden because an app is fullscreen on this screen (unless the activity may show in fullscreen).
    @Published var hiddenForFullscreen = false
    /// Rects (panel-local, top-left origin) that must take mouse events: the island, then the cards.
    /// Not @Published on purpose: they change every animation frame and only the mouse logic reads them.
    var islandRect: CGRect = .zero
    var cardRects: [CGRect] = []
    /// The dashboard's panels ("panel.<id>") and the back control ("back"), in the same space (self-tests click them).
    var panelRects: [String: CGRect] = [:]
    /// The closed island's own shapes by name (`IslandHit`: "bubble.<agent id>", "capsule.news", "drawn"…), in the same space: what takes
    /// the pointer while separate shapes are drawn beside the housing.
    var hitRects: [String: CGRect] = [:]
    /// The name of the shape under the pointer (the manager writes it; that shape is highlighted).
    @Published var hoveredHit: String?

    init(geometry: NotchGeometry, panelSize: CGSize = CGSize(width: 1400, height: 720)) {
        self.geometry = geometry
        self.panelSize = panelSize
    }
}

/// Reports a view's frame in the "notchPanel" coordinate space.
struct NotchRectKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func reportRect(_ name: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: NotchRectKey.self, value: [name: proxy.frame(in: .named("notchPanel"))])
        })
    }
}
