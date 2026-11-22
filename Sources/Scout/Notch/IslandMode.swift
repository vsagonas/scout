import AppKit

/// What the closed notch draws at a given moment, by the display's geometry and what there is to show.
enum ClosedDrawing: Equatable {
    /// One black shape with the wings inside it (the classic notch and the drawn tab), as before 1.0.20.
    case classic
    /// Separate round shapes beside the housing: the agents as bubbles, everything else in capsules.
    case rows
    /// Nothing of Scout's.
    case nothing
}

/// The rules of the first island build. Later builds replace each fallback.
enum IslandMode {
    /// - A pill: only the agents show (round bubbles and the news); anything else draws nothing until it has its own capsule and filter.
    /// - The drawn island: everything shows in rows; while a card is up it falls back to the tab's classic drawing (card and island are
    ///   one black shape there).
    /// - A classic notch set to round bubbles: the agents show in rows; another activity, a card, or the hover list ("show what's
    ///   happening", `detailUp`) keeps the classic drawing.
    static func closed(geometry: NotchGeometry, primary: LiveActivityKind?, cardsUp: Bool, detailUp: Bool = false) -> ClosedDrawing {
        guard geometry.hasRows else { return .classic }
        switch geometry.kind {
        case .pill: return (primary == nil || primary == .agent) ? .rows : .nothing
        case .none: return cardsUp ? .classic : .rows
        case .notch: return (primary == .agent && !cardsUp && !detailUp) ? .rows : .classic
        }
    }

    /// Cards on a pill wait for the build that hangs them below the housing.
    static func drawsCards(geometry: NotchGeometry) -> Bool { geometry.kind != .pill }

    /// The dashboard on a pill waits for the build that hangs it below the housing.
    static func opens(geometry: NotchGeometry) -> Bool { geometry.kind != .pill }
}
