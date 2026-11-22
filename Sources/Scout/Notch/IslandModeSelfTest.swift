import AppKit

/// `scout://island.selftest.mode?out=<file>` (headless): what the closed notch draws for each geometry and each thing to show
/// (`IslandMode`), the geometry's own facts for the sample displays, and the Reduce Motion rule of scripted runs.
@MainActor
enum IslandModeSelfTest {
    static func register() {
        SuiteCheck.register("island.selftest.mode", suite: "island mode") { check in
            modeChecks(check)
            geometryChecks(check)
            motionChecks(check)
        }
    }

    private static func modeChecks(_ check: SuiteCheck) {
        typealias Row = (name: String, geometry: NotchGeometry, primary: LiveActivityKind?, cards: Bool, expected: ClosedDrawing)
        let rows: [Row] = [
            ("classic notch, agents", .sample16, .agent, false, .classic),
            ("classic notch, nothing", .sample16, nil, false, .classic),
            ("classic notch, a card", .sample16, .agent, true, .classic),
            ("drawn tab, agents", .sampleNoneTab, .agent, false, .classic),
            ("pill, agents", .samplePill16, .agent, false, .rows),
            ("pill, nothing to show", .samplePill16, nil, false, .rows),
            ("pill, music (waits for its capsule and filter)", .samplePill16, .media, false, .nothing),
            ("pill, agents and a card (the card is not drawn, the agents stay)", .samplePill16, .agent, true, .rows),
            ("drawn island, nothing to show", .sampleNone, nil, false, .rows),
            ("drawn island, agents", .sampleNone, .agent, false, .rows),
            ("drawn island, music", .sampleNone, .media, false, .rows),
            ("drawn island, a card (falls back to the tab)", .sampleNone, .agent, true, .classic),
            ("notch with round bubbles, agents", .sampleNotchBubbles, .agent, false, .rows),
            ("notch with round bubbles, nothing to show", .sampleNotchBubbles, nil, false, .classic),
            ("notch with round bubbles, music", .sampleNotchBubbles, .media, false, .classic),
            ("notch with round bubbles, agents and a card", .sampleNotchBubbles, .agent, true, .classic),
        ]
        for row in rows {
            let got = IslandMode.closed(geometry: row.geometry, primary: row.primary, cardsUp: row.cards)
            check("closed: \(row.name) draws \(row.expected)", got == row.expected, "\(got)")
        }
        check("the hover list: a notch with round bubbles shows it in the classic drawing; a pill and the drawn island do not change for it",
              IslandMode.closed(geometry: .sampleNotchBubbles, primary: .agent, cardsUp: false, detailUp: true) == .classic
              && IslandMode.closed(geometry: .samplePill16, primary: .agent, cardsUp: false, detailUp: true) == .rows
              && IslandMode.closed(geometry: .sampleNone, primary: .agent, cardsUp: false, detailUp: true) == .rows
              && IslandMode.closed(geometry: .sample16, primary: .agent, cardsUp: false, detailUp: true) == .classic)
        check("cards are drawn everywhere but on a pill", IslandMode.drawsCards(geometry: .sample16) && IslandMode.drawsCards(geometry: .sampleNone)
              && IslandMode.drawsCards(geometry: .sampleNotchBubbles) && !IslandMode.drawsCards(geometry: .samplePill16))
        check("the dashboard opens everywhere but on a pill", IslandMode.opens(geometry: .sample16) && IslandMode.opens(geometry: .sampleNone)
              && IslandMode.opens(geometry: .sampleNoneTab) && IslandMode.opens(geometry: .sampleNotchBubbles) && !IslandMode.opens(geometry: .samplePill16))
    }

    private static func geometryChecks(_ check: SuiteCheck) {
        let classic = NotchGeometry.sample16
        check("the classic sample is what it was: a hardware notch, 185 by 32, flush, faces, no rows",
              classic.kind == .notch && classic.isHardware && classic.size == CGSize(width: 185, height: 32) && classic.topInset == 0
              && classic.agentStyle == .faces && !classic.hasRows && classic.claimsHousing && classic.classicSize == classic.size, "\(classic)")
        let tab = NotchGeometry(size: NotchGeometry.virtualSize, isHardware: false)
        check("the old two-argument geometry without hardware is the drawn tab: no cutout, 190 by 32, flush, no rows",
              tab.kind == .none && !tab.isHardware && tab.noneShape == .tab && tab.size == CGSize(width: 190, height: 32) && tab.topInset == 0
              && !tab.hasRows && tab == .sampleNoneTab, "\(tab)")
        let pill = NotchGeometry.samplePill16
        check("the pill sample: 58 by 31, 8.5 pt below the edge, floor 39.5, rows, never claimed",
              pill.kind == .pill && pill.isHardware && pill.floor == 39.5 && pill.hasRows && !pill.claimsHousing, "\(pill)")
        let rect = pill.housingRect(panelWidth: 1400)
        check("the housing is centred in the panel", rect == CGRect(x: 671, y: 8.5, width: 58, height: 31), "\(rect)")
        let island = NotchGeometry.sampleNone
        check("the drawn island sample: 68 by 20 at 2 pt in a 24 pt bar, rows, claimed, the classic fallback is the tab's size",
              island.kind == .none && !island.isHardware && island.noneShape == .island && island.floor == 22 && island.stripHeight == 24
              && island.hasRows && island.claimsHousing && island.classicSize == NotchGeometry.virtualSize, "\(island)")
        let bubbles = NotchGeometry.sampleNotchBubbles
        check("a classic notch set to round bubbles has rows and keeps its housing", bubbles.kind == .notch && bubbles.hasRows
              && bubbles.claimsHousing && bubbles.size == classic.size && bubbles.stripHeight == 32, "\(bubbles)")
        check("the stored words of the three choices", NoneShape.tab.rawValue == "notch" && NoneShape.island.rawValue == "island"
              && NoneShape.nothing.rawValue == "nothing" && AgentWingStyle.faces.rawValue == "faces" && AgentWingStyle.bubbles.rawValue == "bubbles")
        check("the shapes that take the pointer are named", IslandHit.isHitName("bubble.abc") && IslandHit.isHitName(IslandHit.more)
              && IslandHit.isHitName("capsule.news") && IslandHit.isHitName(IslandHit.drawn) && !IslandHit.isHitName("island")
              && !IslandHit.isHitName("card.1") && !IslandHit.isHitName("panel.agents"))
    }

    private static func motionChecks(_ check: SuiteCheck) {
        typealias Row = (override: Bool?, environment: String?, scripted: Bool, system: Bool, expected: Bool)
        let rows: [Row] = [
            (nil, nil, false, true, true), (nil, nil, false, false, false),
            (nil, "0", false, true, true), (nil, "1", false, false, false), (true, "1", false, false, false),   // the real app follows the Mac only
            (nil, nil, true, true, true), (nil, nil, true, false, false),
            (nil, "1", true, false, true), (nil, "0", true, true, false), (nil, "yes", true, true, true),
            (true, "0", true, false, true), (false, "1", true, true, false),   // a test's own choice wins over the environment
        ]
        var wrong: [String] = []
        for row in rows where ScoutRuntime.reduceMotion(override: row.override, environment: row.environment, scripted: row.scripted, system: row.system) != row.expected {
            wrong.append("\(row)")
        }
        check("Reduce Motion: the real app follows the Mac; a scripted run follows a test's choice, then SCOUT_REDUCE_MOTION, then the Mac (\(rows.count) rows)",
              wrong.isEmpty, wrong.joined(separator: "; "))
        let before = ScoutRuntime.reduceMotionOverride
        ScoutRuntime.reduceMotionOverride = true
        let calm = ScoutRuntime.reduceMotion
        ScoutRuntime.reduceMotionOverride = false
        let moving = ScoutRuntime.reduceMotion
        ScoutRuntime.reduceMotionOverride = before
        check("one run can measure both versions: the choice flips what the app reads", calm && !moving)
    }
}
