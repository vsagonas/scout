import SwiftUI

// AgentNook: the Agents panel as a little house with one room per agent.
// This file is the logic only (what each state looks like, which prop, how many helpers and blocks, which rooms fit), so the
// self-test can check it without drawing anything. The drawing is in AgentNookCritter / AgentNookRoom / AgentNookPanelView.

/// The five looks a room can have: what the agent is doing, in the words the owner reads at a glance.
enum AgentNookLook: CaseIterable, Equatable {
    case working, needsYou, finished, stopped, idle

    /// How the room is lit.
    enum Light: Equatable { case lampOn, amber, daylight, dim, dark }
    /// The little flag on the room's corner.
    enum Flag: Equatable { case amber, green, red }
    /// Which drawing of the scout.
    enum Pose: Equatable { case typing, doorWave, holdingCheck, dizzy, asleep }

    var light: Light {
        switch self {
        case .working: .lampOn
        case .needsYou: .amber
        case .finished: .daylight
        case .stopped: .dim
        case .idle: .dark
        }
    }

    var flag: Flag? {
        switch self {
        case .working, .idle: nil
        case .needsYou: .amber
        case .finished: .green
        case .stopped: .red
        }
    }

    var pose: Pose {
        switch self {
        case .working: .typing
        case .needsYou: .doorWave
        case .finished: .holdingCheck
        case .stopped: .dizzy
        case .idle: .asleep
        }
    }

    /// A moon in the window (the room is dark).
    var hasMoon: Bool { self == .idle }

    var title: String {
        switch self {
        case .working: String(localized: "Working")
        case .needsYou: String(localized: "Needs you")
        case .finished: String(localized: "Done")
        case .stopped: String(localized: "Stopped")
        case .idle: String(localized: "Asleep")
        }
    }

    /// "Needs you" is the app's one rule, `AgentWingSummary.asks`: a held request, or a session that waits with its turn not finished (a
    /// question, a permission). A turn that simply ended also waits (for the next prompt) but it FINISHED: the ✓ pose, or stopped when
    /// its last step failed.
    static func of(_ s: AgentSession, needsYou: Bool) -> AgentNookLook {
        if needsYou { return .needsYou }
        switch s.state {
        case .waiting: return s.finishedAt == nil ? .needsYou : (endedBadly(s) ? .stopped : .finished)
        case .working: return .working
        case .done: return endedBadly(s) ? .stopped : .finished
        case .idle: return endedBadly(s) ? .stopped : .idle
        }
    }

    /// The look of a session with the held requests of the store (the one rule, everywhere: the set, the den and the window).
    static func of(_ s: AgentSession, pending: [AgentPending]) -> AgentNookLook {
        of(s, needsYou: AgentWingSummary.asks(s, pending: pending))
    }

    /// The last thing the agent did went wrong and nothing is running now.
    static func endedBadly(_ s: AgentSession) -> Bool {
        guard let last = s.steps.last(where: { $0.tool != "Prompt" }) else { return false }
        return last.done && last.failed
    }
}

/// The tiny object the scout works with, for the kind of step it is on.
enum AgentNookProp: CaseIterable, Equatable {
    case wrench, pencil, magnifier, globe

    /// Commands (and anything unknown) take the wrench, edits the pencil, reading and searching the magnifier, the web the globe.
    static func of(tool: String) -> AgentNookProp? {
        switch tool {
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "TodoWrite": return .pencil
        case "Read", "Grep", "Glob", "LS", "View": return .magnifier
        case "WebFetch", "WebSearch": return .globe
        case "Task", "Agent", "Prompt": return nil
        default: return .wrench
        }
    }

    /// The step running now; nothing while the agent is only thinking.
    static func of(_ s: AgentSession) -> AgentNookProp? {
        guard s.state == .working, let step = s.currentStep else { return nil }
        return of(tool: step.tool)
    }
}

/// One to-do block on a shelf.
enum AgentNookBlock: Equatable { case done, current, todo }

/// What one room shows, worked out from one session (a plain value, so it can be compared and tested).
struct AgentNookRoomModel: Equatable, Identifiable {
    var id: String
    var kind: AgentKind
    var project: String
    var look: AgentNookLook
    var prop: AgentNookProp?
    var helpers: Int
    var todoTotal: Int
    var todoDone: Int
    var sentence: String

    init(_ s: AgentSession, needsYou: Bool) {
        id = s.id
        kind = s.agent
        project = s.project
        look = AgentNookLook.of(s, needsYou: needsYou)
        prop = AgentNookProp.of(s)
        helpers = max(0, s.subagents)
        todoTotal = s.todos.count
        todoDone = s.todosDone
        sentence = AgentNookText.sentence(s)
    }

    /// Helpers sit awake while their agent works.
    var helpersAwake: Bool { look == .working }

    // MARK: Helpers on the bunk

    /// How many helpers are drawn at most; the rest become "+N".
    static let helpersDrawnMax = 4

    var helpersDrawn: Int { min(helpers, Self.helpersDrawnMax) }
    var helpersMore: Int { max(0, helpers - Self.helpersDrawnMax) }

    /// How many helpers fit in `available` points (each `mini` wide, `spacing` apart, "+N" taking `label`): four when they do, fewer
    /// in a narrow compact room, so the "+N" never gets cut off. The rest of the helpers are the "+N".
    func helperSlots(available: CGFloat, mini: CGFloat, spacing: CGFloat, label: CGFloat = 13) -> (drawn: Int, more: Int) {
        guard helpers > 0 else { return (0, 0) }
        var n = helpersDrawn
        while n > 1 {
            let more = helpers - n
            let need = CGFloat(n) * mini + CGFloat(n - 1) * spacing + (more > 0 ? spacing + label : 0)
            if need <= available { break }
            n -= 1
        }
        return (n, helpers - n)
    }

    // MARK: To-do blocks on the shelf

    /// One block per to-do, at most `cap` of them (a longer list keeps its proportions).
    func blocks(cap: Int) -> [AgentNookBlock] {
        guard todoTotal > 0 else { return [] }
        let n = min(todoTotal, max(1, cap))
        let filled = n == todoTotal ? todoDone : Int((Double(todoDone) / Double(todoTotal) * Double(n)).rounded(.down))
        return (0..<n).map { i in
            if i < filled { return .done }
            if i == filled && look == .working { return .current }
            return .todo
        }
    }

    var progressText: String? { todoTotal > 0 ? "\(todoDone)/\(todoTotal)" : nil }

    var accessibilityText: String {
        var parts = [project, look.title]
        if helpers > 0 { parts.append(String(localized: "Helpers: \(helpers)")) }
        if progressText != nil { parts.append(String(localized: "To-dos: \(todoDone) of \(todoTotal)")) }
        return parts.joined(separator: ", ")
    }
}

enum AgentNookText {
    /// The first sentence of the agent's latest message; the step it is on, its to-do, its prompt or its state while there is none.
    static func sentence(_ s: AgentSession) -> String {
        firstSentence(AgentsWidgetView.sentence(s))
    }

    /// Up to the first full stop, question or exclamation mark that ends a sentence (not the dot in "notes/summary.md").
    static func firstSentence(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let chars = Array(flat)
        for i in chars.indices where ".!?".contains(chars[i]) {
            let next = i + 1 < chars.count ? chars[i + 1] : " "
            if next == " " && i > 0 { return String(chars[...i]) }
        }
        return flat
    }
}

/// Which rooms fit in the panel, and how big they are (pure arithmetic, tested at 3, 4, 6, 10 and 16 cells).
enum AgentNookLayout {
    enum Style: Equatable { case roomy, compact }

    struct Plan: Equatable {
        var style: Style
        /// Rooms drawn, and agents left behind the "+N" door (0 = no door).
        var shown: Int
        var more: Int
        /// Each room's width.
        var roomWidth: CGFloat
        /// CPU and memory as a meter on the right wall (wide panels) instead of two small gauges on the roof.
        var wallMeter: Bool
    }

    static let padding: CGFloat = 8
    static let gap: CGFloat = 6
    static let doorWidth: CGFloat = 30
    static let meterWidth: CGFloat = 44
    static let roomyMin: CGFloat = 100
    static let roomyMax: CGFloat = 280
    static let compactMin: CGFloat = 54
    static let compactMax: CGFloat = 92
    /// From this panel width on, the Mac's load is a meter on the wall.
    static let wallMeterFrom: CGFloat = 300

    /// The panel's width for a number of dashboard cells.
    static func width(cells: Int) -> CGFloat { CGFloat(cells) * NookMetrics.cell }

    static func rowWidth(panel width: CGFloat) -> CGFloat {
        let meter = width >= wallMeterFrom ? meterWidth + gap : 0
        return max(0, width - 2 * padding - meter)
    }

    /// The most rooms (at least one) whose minimum width fits, with the door when some are left out.
    static func capacity(rowWidth: CGFloat, count: Int, minWidth: CGFloat) -> Int {
        guard count > 0 else { return 0 }
        var n = count
        while n > 1 {
            let door = n < count ? gap + doorWidth : 0
            if CGFloat(n) * minWidth + CGFloat(n - 1) * gap + door <= rowWidth { return n }
            n -= 1
        }
        return 1
    }

    static func plan(panelWidth: CGFloat, count: Int) -> Plan {
        plan(rowWidth: rowWidth(panel: panelWidth), count: count, wallMeter: panelWidth >= wallMeterFrom)
    }

    /// The same rooms for a row of this width (the set's glass: its rooms stand on the screen, the Mac's load is on the set itself).
    static func plan(rowWidth row: CGFloat, count: Int, wallMeter wall: Bool = false) -> Plan {
        guard count > 0 else { return Plan(style: .roomy, shown: 0, more: 0, roomWidth: row, wallMeter: wall) }
        // One to three agents get roomy rooms, four to six compact ones, as long as that shows as many as the other would.
        let preferred: Style = count <= 3 ? .roomy : .compact
        func fit(_ style: Style) -> Int { capacity(rowWidth: row, count: count, minWidth: style == .roomy ? roomyMin : compactMin) }
        var style = preferred
        if preferred == .roomy, fit(.compact) > fit(.roomy) { style = .compact }
        let n = fit(style)
        let more = count - n
        let door = more > 0 ? gap + doorWidth : 0
        let lo = style == .roomy ? roomyMin : compactMin
        let hi = style == .roomy ? roomyMax : compactMax
        let free = row - door - CGFloat(n - 1) * gap
        let w = min(hi, max(min(lo, free), free / CGFloat(n)))
        return Plan(style: style, shown: n, more: more, roomWidth: w, wallMeter: wall)
    }
}
