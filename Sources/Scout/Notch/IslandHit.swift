import AppKit

/// The shapes of the closed island that take the pointer, by name, and what a click on each one does. A view reports its frame under its
/// name (`reportRect(name)`, in the "notchPanel" space); the root view keeps the named frames in `NotchScreenModel.hitRects`; the manager
/// tests the pointer against them and runs `perform` for a click, whether the panel got the event or only the global monitor saw it.
@MainActor
enum IslandHit {
    /// "bubble.<agent id>": one agent's round bubble.
    static let bubblePrefix = "bubble."
    /// The "+N" bubble of the agents that do not fit.
    static let more = "bubble.more"
    /// "capsule.<what>": "capsule.news" (the agents' readout), "capsule.lead" and "capsule.trail" (another activity's two sides),
    /// "capsule.companion" (the radio beside the agents).
    static let capsulePrefix = "capsule."
    /// The capsule Scout draws on a display without a cutout.
    static let drawn = "drawn"

    static func isHitName(_ name: String) -> Bool {
        name.hasPrefix(bubblePrefix) || name.hasPrefix(capsulePrefix) || name == drawn
    }

    /// A click on the named shape. Returns false when the display does not open yet (`IslandMode.opens`), when clicking the notch is switched off, or
    /// when the name is unknown.
    @discardableResult
    static func perform(_ name: String, geometry: NotchGeometry, navigator: NotchNavigator? = nil, center: LiveActivityCenter? = nil,
                        agents: AgentsStore? = nil) -> Bool {
        guard isHitName(name) else { return false }
        guard IslandMode.opens(geometry: geometry) else {
            NSLog("Scout: the dashboard does not open on this display yet (%@)", name)
            return false
        }
        guard NotchPrefs.clickToOpen else { return false }   // off: the shapes ignore clicks, as the notch does
        let navigator = navigator ?? .shared, center = center ?? .shared, agents = agents ?? .shared   // (the shared ones are looked up here, not in the default arguments: those are not main-actor code)
        if name == more {
            navigator.open(.agents)
        } else if name.hasPrefix(bubblePrefix) {
            agents.focusID = String(name.dropFirst(bubblePrefix.count))
            navigator.open(.agents)
        } else if name == "capsule.companion", let radio = center.activities.first(where: { $0.kind == .radio }), let onTap = radio.onTap {
            onTap()
        } else if name.hasPrefix(capsulePrefix), let onTap = center.primary?.onTap {
            onTap()
        } else {
            navigator.open()
        }
        return true
    }
}
