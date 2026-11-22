import AppKit
import SwiftUI

struct AgentGlyph: View {
    let agent: AgentKind
    var size: CGFloat = 16

    var body: some View {
        Image(systemName: agent.symbol).font(.system(size: size, weight: .semibold)).foregroundStyle(agent.tint)
    }
}

/// What the closed notch's wings say, worked out from the sessions: the fast readout of every agent running.
struct AgentWingSummary: Equatable {
    enum Right: Equatable {
        /// The latest message of an agent that waits:
        /// one that needs you first (a pulsing amber dot), else one whose turn ended (a green tick).
        case message(String, asks: Bool)
        case progress(done: Int, total: Int) // the busiest session's to-do list, while nobody waits
        case allDone
        case none
    }

    /// One little face in the left wing: an agent and what it is doing.
    struct Face: Identifiable, Equatable {
        var id: String
        var agent: AgentKind
        var mood: AgentFaceMood
        /// Its own face of `AgentFaceArt.variantCount`: no two agents look the same.
        var variant = 0
    }

    struct Line: Identifiable, Equatable {
        var id: String
        var project: String
        var agent: AgentKind
        var text: String
        var progress: String?
        var attention: Bool
        var finished: Bool
    }

    var working = 0
    var needs = 0
    var right: Right = .none
    var lines: [Line] = []
    var more = 0
    /// The faces of the left wing: every agent, those that need you first, then those at work, then those whose turn ended, then the done
    /// and sleeping ones; four at most, `moreFaces` are left out.
    var faces: [Face] = []
    var moreFaces = 0
    /// True when an agent that has no face of its own (the "+N") needs you: the round "+N" carries the amber ring then.
    var moreNeeds = false
    /// The agent whose question the right side shows (the latest to ask): the amber bubble of the minimal look focuses it.
    var firstAsking: String?
    static let maxFaces = 4

    static func shortName(_ s: String) -> String { s.count > 9 ? String(s.prefix(8)) + "…" : s }

    /// A session wants an answer when it stopped on a question or on a plan waiting for approval (it waits and its turn is not finished).
    static func asks(_ s: AgentSession) -> Bool {
        s.state == .waiting && s.finishedAt == nil
    }

    /// What the right wing says about a session that waits: the question it asks, else its latest message (the first sentence of it),
    /// else what it waits for.
    static func waitingLine(_ s: AgentSession) -> String {
        if let question = AgentNote.question(s.note) { return AgentText.firstSentence(question, limit: 100) }
        if !s.lastMessage.isEmpty { return s.lastMessage }
        return asks(s) ? (s.note.isEmpty ? shortName(s.project) : AgentNote.text(s.note)) : String(localized: "Finished: your move")
    }

    static func make(sessions: [AgentSession]) -> AgentWingSummary {
        var out = AgentWingSummary()
        let asking = sessions.filter { asks($0) }.sorted { $0.lastEventAt > $1.lastEventAt }
        let busy = sessions.filter { $0.state == .working && !asks($0) }.sorted { $0.lastEventAt > $1.lastEventAt }
        let yourTurn = sessions.filter { $0.state == .waiting && !asks($0) }
            .sorted { ($0.finishedAt ?? $0.lastEventAt) > ($1.finishedAt ?? $1.lastEventAt) }
        out.working = busy.count
        out.needs = asking.count
        out.firstAsking = asking.first?.id
        if let first = asking.first {
            out.right = .message(waitingLine(first), asks: true)
        } else if let turn = yourTurn.first {
            out.right = .message(waitingLine(turn), asks: false)
        } else if let lead = busy.first, !lead.todos.isEmpty {
            out.right = .progress(done: lead.todosDone, total: lead.todos.count)
        } else if busy.isEmpty, !sessions.isEmpty, !sessions.contains(where: { $0.state == .idle }) {   // an interrupted (idle) agent is not "done"
            out.right = .allDone
        }
        // Every agent the TV and the den show has its face here too,
        // in the same fixed order as the TV and the den (the first started on the left); with more than fit, the ones that need you show.
        let ordered = AgentTileMetrics.ordered(sessions)
        let faced = AgentTileMetrics.keepOrder(ordered, limit: maxFaces) { AgentTileMetrics.urgency($0) }
        let variants = AgentFaceArt.variants(for: sessions.map(\.id))
        out.faces = faced.map { Face(id: $0.id, agent: $0.agent, mood: AgentFaceMood(AgentNookLook.of($0)), variant: variants[$0.id] ?? 0) }
        out.moreFaces = max(0, sessions.count - faced.count)
        let shown = Set(out.faces.map(\.id))
        out.moreNeeds = sessions.contains { !shown.contains($0.id) && asks($0) }
        func text(_ s: AgentSession) -> String {
            if asks(s) { return s.note.isEmpty ? String(localized: "Needs you") : AgentNote.text(s.note) }
            if s.state == .waiting { return String(localized: "Finished: your move") }
            if s.state == .working { return s.currentStep.map { "\($0.tool) \($0.summary)" } ?? s.currentTodo ?? String(localized: "Thinking…") }
            return s.state.title
        }
        let all = asking + busy + yourTurn
        out.lines = all.prefix(4).map { s in
            Line(id: s.id, project: s.project, agent: s.agent, text: text(s), progress: s.todos.isEmpty ? nil : "\(s.todosDone)/\(s.todos.count)",
                 attention: asks(s), finished: s.state == .waiting && !asks(s))
        }
        out.more = max(0, all.count - 4)
        return out
    }
}

/// Left wing of the closed notch. 8-bit style: one little pixel face per agent (the agents' faces from the den: their colour, their eyes and mouth
/// moving), those that need you first (the owner, 2026-11-16). Minimal style (the style switch off): the wing it had before, a small cpu symbol
/// in the accent colour, the number of agents at work and a small orange capsule with the number that need you.
struct AgentWingLeft: View {
    @ObservedObject var store: AgentsStore
    /// Gallery and tests: draw one still moment of the faces (seconds).
    var frozenAt: Double?
    /// Where the closed island is drawn as separate round shapes (`rows`), the agents are round bubbles; everywhere else this view is what it was.
    @Environment(\.cutout) private var cutout
    @Environment(\.notchNavigator) private var navigator

    var body: some View {
        let summary = AgentWingSummary.make(sessions: store.sessions)
        if cutout.rows { bubbles(summary) } else if Retro.is8bit { faces(summary) } else { plain(summary) }
    }

    // MARK: Round bubbles (the island's rows)

    /// The first agent started is outermost, the newest next to the housing, "+N" at the housing's end (the row is right-aligned to it by
    /// `IslandClosedView`); the minimal look shows a bubble with the number at work and, when some need you, a second amber one.
    private func bubbles(_ summary: AgentWingSummary) -> some View {
        let d = cutout.rowHeight
        let hovered = cutout.hovered
        let grow: AnyTransition = ScoutRuntime.reduceMotion ? .opacity : .scale(scale: IslandTuning.growStart).combined(with: .opacity)
        return HStack(spacing: IslandTuning.gap) {
            if Retro.is8bit {
                ForEach(summary.faces) { face in
                    let name = IslandHit.bubblePrefix + face.id
                    AgentBubble(face: face, label: NotchHeader.faceHelp(face, sessions: store.sessions), diameter: d, displayScale: cutout.displayScale,
                                hovered: hovered == name, frozenAt: frozenAt)
                        .reportRect(name)
                        .onTapGesture { tap(name) }
                        .transition(grow)
                }
                if summary.moreFaces > 0 {
                    AgentMoreBubble(count: summary.moreFaces, needs: summary.moreNeeds, diameter: d, hovered: hovered == IslandHit.more)
                        .reportRect(IslandHit.more)
                        .onTapGesture { tap(IslandHit.more) }
                        .transition(grow)
                }
            } else {
                AgentCountBubble(count: (summary.working > 0 || summary.needs > 0) ? summary.working : nil, diameter: d, hovered: hovered == IslandHit.more)
                    .reportRect(IslandHit.more)
                    .onTapGesture { tap(IslandHit.more) }
                if summary.needs > 0, let asking = summary.firstAsking {
                    // The amber bubble stands for the agent whose question the news shows: its name is that agent's, so a click focuses it.
                    let name = IslandHit.bubblePrefix + asking
                    AgentCountBubble(count: summary.needs, needs: true, diameter: d, hovered: hovered == name)
                        .reportRect(name)
                        .onTapGesture { tap(name) }
                        .transition(grow)
                }
            }
        }
        .animation(Theme.spring, value: summary.faces.map(\.id) + ["+\(summary.moreFaces)", "w\(summary.working)", "n\(summary.needs)"])
    }

    /// A click on a bubble: the island's one click function (it does nothing where the dashboard does not open yet, nor while Settings says
    /// that clicking the notch does not open it).
    private func tap(_ name: String) {
        guard NotchPrefs.clickToOpen else { return }
        IslandHit.perform(name, geometry: cutout.geometry ?? NotchGeometry(kind: cutout.kind, size: .zero), navigator: navigator, agents: store)
    }

    private func faces(_ summary: AgentWingSummary) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(summary.faces.enumerated()), id: \.element.id) { index, face in
                // A tap on a face opens the Agents view with that agent's window open (the owner, 2026-11-16).
                Button {
                    store.focusID = face.id
                    NotchNavigator.shared.open(.agents)
                } label: {
                    AgentFaceIcon(agent: face.agent, mood: face.mood, phase: AgentFaceArt.phase(for: face.id), frozenAt: frozenAt, variant: face.variant)
                }
                .buttonStyle(StillButtonStyle())
            }
            if summary.moreFaces > 0 {
                Text("+\(summary.moreFaces)").font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(.white.opacity(0.75))
            }
        }
        .animation(ScoutRuntime.reduceMotion ? nil : Theme.quick, value: summary.faces)
    }

    /// The glyph and how many work right now; a second small number in the attention colour when some need an answer; the glyph alone when
    /// nothing works. Numbers change with a soft transition (none under Reduce Motion).
    private func plain(_ summary: AgentWingSummary) -> some View {
        AgentWingCount(summary: summary)
    }
}

/// The minimal look's agents readout: the cpu glyph, how many work, and an orange count of those that need you. The closed notch's left
/// wing and the open notch's header beside the camera show the same one
struct AgentWingCount: View {
    let summary: AgentWingSummary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "cpu").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
            if summary.working > 0 || summary.needs > 0 {
                Text("\(summary.working)").font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(Look.primary)
                    .contentTransition(.numericText())
                if summary.needs > 0 {
                    Text("\(summary.needs)").font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(Color.black.opacity(0.85))
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.orange)).contentTransition(.numericText())
                }
            }
        }
        .animation(ScoutRuntime.reduceMotion ? nil : Theme.quick, value: summary.working)
        .animation(ScoutRuntime.reduceMotion ? nil : Theme.quick, value: summary.needs)
    }
}

/// Right wing: the latest message of an agent that waits for you; while nobody waits, the busiest session's to-do progress.
struct AgentWingRight: View {
    @ObservedObject var store: AgentsStore
    /// The message keeps to two lines, and its box is as wide as the WHOLE sentence needs on two lines.
    /// a short one stays one narrow line, a long one widens the wing up to `maxTextWidth`, past which it ends with "…".
    static let minTextWidth: CGFloat = 96
    static let maxTextWidth: CGFloat = 400
    /// The widest the message with its dot may be (the dot or the tick and the gap before the text take 16 pt).
    static let messageWidth: CGFloat = maxTextWidth + 16
    static let font = NSFont.systemFont(ofSize: 9.5, weight: .medium)

    /// The width of the message's text box, EXACTLY what the words take:
    /// a short text is its one line; a longer one is wrapped at the narrowest width (found by
    /// halving, from `minTextWidth` up to `maxTextWidth`) at which all of it fits on two lines, and the box is the longer of those two lines.
    /// Measured here because a `.frame(maxWidth:)` would give the one-line height to a text that is later squeezed to the width.
    static func textWidth(_ text: String) -> CGFloat {
        let one = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1
        if one <= minTextWidth { return max(8, one) }
        var low = max(minTextWidth, floor(one / 2)), high = maxTextWidth
        if lines(text, width: high) > 2 { return high }   // longer than two full lines: it ends with "…"
        while high - low > 0.5 {
            let mid = (low + high) / 2
            if lines(text, width: mid) <= 2 { high = mid } else { low = mid }
        }
        return min(maxTextWidth, ceil(usedWidth(text, width: high)) + 1)   // the longer line itself, not the room it was wrapped in
    }

    /// The width of the longest line when `text` wraps at `width`.
    static func usedWidth(_ text: String, width: CGFloat) -> CGFloat {
        (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin],
                                        attributes: [.font: font]).width
    }

    /// The message as the wing draws it (the self-test measures the same view).
    static func messageText(_ text: String, asks: Bool, oneLine: Bool = false) -> some View {
        Text(verbatim: text).font(.system(size: 9.5, weight: .medium)).foregroundStyle(asks ? Color.orange : Color.white.opacity(0.9))
            .lineLimit(oneLine ? 1 : 2).truncationMode(.tail).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            .frame(width: oneLine ? oneLineWidth(text) : textWidth(text), alignment: .leading)
    }

    /// The width of the message on ONE line (a capsule lower than `IslandTuning.oneLineBelow`), at most `maxTextWidth`: what the words take.
    static func oneLineWidth(_ text: String) -> CGFloat {
        min(maxTextWidth, max(8, ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1))
    }

    static func messageProbe(_ text: String) -> some View { messageText(text, asks: false) }

    /// How many lines `text` takes at `width` in the wing's font.
    static func lines(_ text: String, width: CGFloat) -> Int {
        let box = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin],
                                                  attributes: [.font: font])
        let line = NSLayoutManager().defaultLineHeight(for: font)
        return max(1, Int((box.height / line).rounded()))
    }

    /// How long something new stays in the right wing before the notch goes back to its compact width (the notch and the faces).
    static let showSeconds: Double = 8
    /// How long a finished agent's message waits before it widens a quiet wing (see `reveal`).
    static let settle: Double = 1.2
    /// Pictures and tests: keep the readout on.
    var alwaysShown = false
    @State private var showing: Bool
    @State private var shownKey = ""
    /// Where the closed island is drawn as separate round shapes (`rows`), the readout is one capsule; everywhere else this view is what it was.
    @Environment(\.cutout) private var cutout

    /// The readout this wing last revealed. The wing is built anew each time the notch closes, so without this a message that had come and
    /// gone came back after every open and close:
    /// only a NEW readout shows again.
    static var lastRevealed = ""

    init(store: AgentsStore, alwaysShown: Bool = false) {
        self.store = store
        self.alwaysShown = alwaysShown
        let key = Self.key(AgentWingSummary.make(sessions: store.sessions).right)
        _showing = State(initialValue: ScoutRuntime.isGallery || key != Self.lastRevealed || key.hasPrefix("ask:"))
    }

    /// What the readout says, as a key: a new key brings it back for `showSeconds`.
    static func key(_ right: AgentWingSummary.Right) -> String {
        switch right {
        case .message(let text, let asks): return (asks ? "ask:" : "msg:") + text
        case .progress(let done, let total): return "progress:\(done)/\(total)"
        case .allDone: return "done"
        case .none: return ""
        }
    }

    var body: some View {
        let summary = AgentWingSummary.make(sessions: store.sessions)
        let key = Self.key(summary.right)
        // Always one view: modifiers on an empty Group reach nothing, so after the first hide `onChange` never fired again and a new
        // question never came back to the wing.
        ZStack {
            Color.clear.frame(width: 0, height: 0)
            if showing || alwaysShown {
                if cutout.rows { capsule(summary.right) } else { readout(summary.right) }
            }
        }
        .onAppear { reveal(key) }
        .onChange(of: key) { _, new in reveal(new) }
    }

    /// Shows a new readout for a few seconds, then steps aside so the closed notch shrinks back around the faces (with the island's own
    /// spring; a fade under Reduce Motion).
    private func reveal(_ key: String) {
        shownKey = key
        guard !key.isEmpty else { showing = false; return }
        // A question (or a plan waiting for approval) that still waits stays on the right until it is answered, whatever opens and closes.
        // Only finished messages step aside.
        if key.hasPrefix("ask:") {
            Self.lastRevealed = key
            withAnimation(ScoutRuntime.reduceMotion ? nil : Theme.quick) { showing = true }
            return
        }
        if key == Self.lastRevealed, !ScoutRuntime.isGallery { showing = false; return }   // already said: a closed-again notch stays quiet
        Self.lastRevealed = key
        // A turn that ends and a new prompt a moment later (pressing Enter while the agent works interrupts it, then starts the next turn)
        // must not make the notch grow and shrink at once:
        // a message that would widen a quiet wing waits `settle` seconds and shows only if it is still the news.
        let wait = (!showing && key.hasPrefix("msg:")) ? Self.settle : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            guard shownKey == key else { return }
            withAnimation(ScoutRuntime.reduceMotion ? nil : Theme.quick) { showing = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.showSeconds) {
                guard shownKey == key else { return }
                withAnimation(ScoutRuntime.reduceMotion ? .easeOut(duration: 0.25) : Theme.spring) { showing = false }
            }
        }
    }

    /// The readout in a capsule as tall as a bubble and exactly as wide as the readout plus its padding; two lines of news, one when the
    /// capsule is lower than `IslandTuning.oneLineBelow`.
    private func capsule(_ right: AgentWingSummary.Right) -> some View {
        IslandCapsule(height: cutout.rowHeight, scale: cutout.contentScale, hovered: cutout.hovered == "capsule.news") {
            readout(right, oneLine: cutout.rowHeight < IslandTuning.oneLineBelow)
        }
        .transition(ScoutRuntime.reduceMotion ? .opacity : .scale(scale: IslandTuning.growStart, anchor: .leading).combined(with: .opacity))
    }

    @ViewBuilder private func readout(_ right: AgentWingSummary.Right, oneLine: Bool = false) -> some View {
        Group {
            switch right {
            case .message(let text, let asks):
                HStack(spacing: 4) {
                    if asks {
                        PulsingDot(color: .orange)
                    } else {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.green)
                    }
                    Self.messageText(text, asks: asks, oneLine: oneLine)
                }
            case .progress(let done, let total):
                HStack(spacing: 4) {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.22))
                        GeometryReader { g in Capsule().fill(Theme.accent).frame(width: g.size.width * CGFloat(done) / CGFloat(max(1, total))) }
                    }
                    .frame(width: 24, height: 3.5)
                    Text("\(done)/\(total)").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.white).contentTransition(.numericText())
                }
            case .allDone:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Color.green)
                    Text("done").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                }
            case .none:
                EmptyView()
            }
        }
        .animation(ScoutRuntime.reduceMotion ? nil : Theme.quick, value: right)
    }
}

/// A dot that breathes (still under Reduce Motion).
struct PulsingDot: View {
    var color: Color
    var size: CGFloat = 7

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15)) { ctx in
            let pulse = ScoutRuntime.reduceMotion ? 1 : 0.6 + 0.4 * sin(ctx.date.timeIntervalSinceReferenceDate * 4.5)
            Circle().fill(color).frame(width: size, height: size).opacity(pulse)
        }
    }
}

/// What the pointer resting on the closed notch shows: one line per running agent (project, what it does, progress).
struct AgentWingDetail: View {
    @ObservedObject var store: AgentsStore

    var body: some View {
        let summary = AgentWingSummary.make(sessions: store.sessions)
        VStack(alignment: .leading, spacing: 3) {
            ForEach(summary.lines) { line in
                HStack(spacing: 6) {
                    Circle().fill(line.attention ? Color.orange : (line.finished ? Color.green : Theme.accent)).frame(width: 6, height: 6)
                    Text(line.project).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(line.text).font(.system(size: 10.5)).foregroundStyle(line.attention ? Color.orange : .white.opacity(0.62)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let progress = line.progress { Text(progress).font(.system(size: 10.5, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.white.opacity(0.8)) }
                }
            }
            if summary.more > 0 { Text("+\(summary.more) more").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)) }
            if summary.lines.isEmpty { Text("All agents are done").font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)) }
            MachineLoadLine(style: .text).padding(.top, 2)
        }
        .frame(maxWidth: 330, alignment: .leading)
        .foregroundStyle(.white)
    }
}

/// A spinner for the step that is running now (still while Reduce Motion is on).
struct AgentSpinner: View {
    var size: CGFloat = 10
    var color: Color = Theme.accent

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let angle = ScoutRuntime.reduceMotion ? 0 : (ctx.date.timeIntervalSinceReferenceDate * 360 / 1.0).truncatingRemainder(dividingBy: 360)
            Circle().trim(from: 0, to: 0.72).stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(angle)).frame(width: size, height: size)
        }
    }
}

/// "4:12": counts up from `start` while `end` is nil, otherwise the fixed time between them.
struct AgentElapsed: View {
    let start: Date
    var end: Date?

    var body: some View {
        if let end {
            Text(FeatureFormat.duration(end.timeIntervalSince(start))).monospacedDigit()
        } else {
            Text(start, style: .timer).monospacedDigit()
        }
    }
}

func toolSymbol(_ tool: String) -> String {
    switch tool {
    case "Bash": "terminal"
    case "Read": "doc.text"
    case "Edit", "MultiEdit": "pencil"
    case "Write": "square.and.pencil"
    case "Grep": "magnifyingglass"
    case "Glob": "folder"
    case "WebFetch", "WebSearch": "globe"
    case "Task", "Agent": "person.2"
    case "Prompt": "text.bubble"
    case "TodoWrite": "checklist"
    default: "wrench.and.screwdriver"
    }
}

/// A button that does not fade while it is held: an agent (its face, its room, its station) stays solid under a press
struct StillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
