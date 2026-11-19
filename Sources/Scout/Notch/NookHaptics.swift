import AppKit
import SwiftUI

// The trackpad tap that goes with every expand and collapse, and the marker on the buttons inside the panels.

// MARK: - Haptics

/// The tap on the trackpad when a panel expands or the island goes back to the dashboard. It honours the notch's own
/// haptics setting (and, through `Haptics`, the app-wide one), like the notch's open/close tick and the ring's slice tick.
@MainActor
enum NookHaptics {
    /// What a tap does. Self-tests replace it with a counter, so a check never taps the owner's trackpad.
    static var perform: @MainActor () -> Void = { if NotchPrefs.haptics { Haptics.tick() } }
    private static var last = Date.distantPast

    /// One tap per change: an expand that also clears an agent tab still taps once.
    static func tick(now: Date = Date()) {
        guard now.timeIntervalSince(last) > 0.15 else { return }
        last = now
        perform()
    }
}

// MARK: - The buttons inside the panels

/// Rects (in the "notchPanel" space) of the controls inside the dashboard's panels: play and skip, Join, a to-do's
/// checkbox, a clipboard row. The self-tests click them.
struct NookControlKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

extension View {
    /// Marks a button or control of a panel (the self-tests find and click it).
    func nookControl() -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: NookControlKey.self, value: [proxy.frame(in: .named("notchPanel"))])
        })
    }
}
