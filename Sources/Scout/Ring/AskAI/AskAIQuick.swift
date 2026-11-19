import SwiftUI

// The dashboard's quick answer.
// A question typed in the dashboard's Ask AI field goes into the one
// "Fast Ask AI" conversation (`AIChatStore.sendQuick`), and the answer stays in the Ask AI panel's own history while the
// dashboard keeps its height; nothing opens below the panels.

/// Whether the dashboard's Ask AI panel is on screen right now (it draws its own history): `AskAIDropDown` then keeps the card under the
/// closed notch away. The panel reports it when it appears and disappears.
@MainActor
final class AskAIQuick {
    static let shared = AskAIQuick()

    private(set) var isOnScreen = false

    func onScreen(_ on: Bool) { isOnScreen = on }
}
