import CoreGraphics
import Foundation

/// Detects a "shake": quick back-and-forth sideways movement while dragging.
/// Gentle = 3 direction changes of at least 30 pt within 0.5 s. Firm = 4 changes of at least 55 pt.
struct ShakeDetector {
    enum Sensitivity: String, CaseIterable, Identifiable {
        case gentle, firm
        var id: String { rawValue }
        var title: String { self == .gentle ? String(localized: "Gentle") : String(localized: "Firm") }
        var changes: Int { self == .gentle ? 3 : 4 }
        var amplitude: CGFloat { self == .gentle ? 30 : 55 }
    }

    var sensitivity: Sensitivity = .gentle
    let window: TimeInterval = 0.5

    private var direction = 0           // -1 left, +1 right, 0 unknown
    private var extreme: CGFloat = 0     // the furthest x in the current direction
    private var lastX: CGFloat?
    private var changes: [TimeInterval] = []

    mutating func reset() { direction = 0; lastX = nil; changes = [] }

    /// Feed pointer positions in time order. Returns true when a shake just completed.
    mutating func feed(x: CGFloat, at time: TimeInterval) -> Bool {
        defer { lastX = x }
        guard let previous = lastX else { extreme = x; return false }
        let dx = x - previous
        if dx == 0 { return false }
        let moving = dx > 0 ? 1 : -1
        if direction == 0 { direction = moving; extreme = x; return false }
        if moving == direction {
            extreme = direction > 0 ? max(extreme, x) : min(extreme, x)
            return false
        }
        // Moving the other way: it counts once it has gone far enough back from the extreme.
        if abs(x - extreme) >= sensitivity.amplitude {
            direction = moving
            extreme = x
            changes.append(time)
            changes.removeAll { time - $0 > window }
            if changes.count >= sensitivity.changes {
                changes = []
                return true
            }
        }
        return false
    }
}
