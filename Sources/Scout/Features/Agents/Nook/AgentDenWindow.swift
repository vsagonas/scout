import SwiftUI

/// The window that opens beside the den when you click an agent: a 90s window with a title bar, a CRT glass that says what the agent
/// is doing (its latest message in the system font so it reads easily, the step it is on, its to-do progress as an LED bar, the last
/// steps), a pager for the automatic opening's banner, and below the glass a plastic deck with the answer controls as chunky keys.
/// The den stays on screen beside it.
struct AgentDenWindow: View {
    let session: AgentSession
    @ObservedObject var store: AgentsStore
    var banner: AgentAnnouncement?
    /// Under the den, across its width: what the agent does and the answer keys at the left, its whole workflow (every step) at the right.
    var below = false
    var onClose: () -> Void
    @State private var contentHeight: CGFloat = 400

    private var requests: [AgentPending] { store.pending.filter { $0.sessionID == session.id } }
    private var look: AgentNookLook { Self.look(session, pending: store.pending) }

    /// What the window says the agent is: the same one rule as the den and the set.
    static func look(_ session: AgentSession, pending: [AgentPending]) -> AgentNookLook { AgentNookLook.of(session, pending: pending) }

    /// Which clock the window shows: a running one while the agent works or asks, the fixed duration of a finished or stopped task, none asleep.
    enum ClockMode { case running, fixed, none }

    static func clockMode(_ look: AgentNookLook) -> ClockMode {
        switch look {
        case .working, .needsYou: .running
        case .finished, .stopped: .fixed
        case .idle: .none
        }
    }

    /// The word and colour of the state, in the pixel font.
    static func stateWord(_ look: AgentNookLook) -> (word: String, color: Color) {
        switch look {
        case .working: (pixelLabel("WORKING"), Retro.Ink.ledGreen)
        case .needsYou: (pixelLabel("NEEDS YOU"), Retro.Ink.phosphorAmber)
        case .finished: (pixelLabel("DONE"), Retro.Ink.teal)
        case .stopped: (pixelLabel("STOPPED"), Retro.Ink.ledRed)
        case .idle: (pixelLabel("ASLEEP"), Color(white: 0.62))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
                .padding(.horizontal, below ? Self.wallInset + 5 : 5).padding(.top, 5)
            if below {
                belowBody
            } else {
                // The window is as tall as what it shows; when that is more than the den, it scrolls.
                ScrollView(.vertical, showsIndicators: false) {
                    content.background(GeometryReader { proxy in Color.clear.preference(key: AgentDenContentHeightKey.self, value: proxy.size.height) })
                }
                .frame(maxHeight: contentHeight)
                .onPreferenceChange(AgentDenContentHeightKey.self) { contentHeight = $0 }
            }
        }
        .background(Color.clear.retroBevel(.raised, cornerRadius: 6, depth: 1.5, face: Color(red: 0.50, green: 0.50, blue: 0.50)))
        .compositingGroup()   // the window casts ONE silhouette; without the group every inner view cast its own shadow
        .shadow(color: Color.black.opacity(0.45), radius: 0, x: 3, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(session.project), \(look.title)")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let banner {
                AgentBanner(announcement: banner, session: session).denFrame("banner")
            }
            glass(recentSteps: true)
            if !requests.isEmpty { deck }
        }
        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 8)
    }

    /// Under the den: the agent and the answer keys at the left, the workflow at the right (both scroll on their own).
    private var belowBody: some View {
        GeometryReader { geo in
            let left = min(460, max(260, geo.size.width * 0.44))
            HStack(alignment: .top, spacing: 8) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !requests.isEmpty { deck }   // the answer keys first: always in view
                        if let banner { AgentBanner(announcement: banner, session: session).denFrame("banner") }
                        glass(recentSteps: false)
                    }
                }
                .frame(width: left)
                workflow
            }
            .padding(.horizontal, 8 + Self.wallInset).padding(.top, 8).padding(.bottom, 12)
        }
    }

    /// Under the den the window's grey runs to the island's edges (no strip of black under it), but the island's visible walls stand
    /// 12 pt inside that (its top shoulders) and its bottom corners are round (26 pt): the title bar and both panels keep inside them
    static let wallInset: CGFloat = AgentNookPanelView.islandShoulder

    // MARK: The workflow

    /// Every step the agent took, in order and newest at the bottom (it opens there): the time, a tick, a warning for a failed step or a
    /// spinner for the running one, the tool and what it did; each prompt of yours stands between them as a quiet line.
    private var workflow: some View {
        let steps = Array(session.steps.enumerated())
        let tools = session.steps.filter { $0.tool != "Prompt" }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RetroPixelText(pixelLabel("WORKFLOW"), pixel: 1.5, color: Retro.Ink.osdWhite.opacity(0.75))
                Spacer(minLength: 4)
                Text("Steps: \(tools)").font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Retro.Ink.osdWhite.opacity(0.5))
            }
            if steps.isEmpty {
                Text("No steps yet.").font(.system(size: 11.5)).foregroundStyle(Retro.Ink.osdWhite.opacity(0.6))
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(steps, id: \.offset) { index, step in workflowRow(step).id(index) }
                        }
                        .padding(.trailing, 6)
                    }
                    .onAppear { proxy.scrollTo(steps.count - 1, anchor: .bottom) }
                    .onChange(of: steps.count) { proxy.scrollTo(steps.count - 1, anchor: .bottom) }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
        .crtScreen(cornerRadius: Self.screenRadius, scanlines: 0.05, tint: nil, vignette: 0.12)
        .denFrame("workflow")
    }

    @ViewBuilder private func workflowRow(_ step: AgentStep) -> some View {
        if step.tool == "Prompt" {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble").font(.system(size: 9, weight: .semibold)).foregroundStyle(Retro.Ink.phosphorAmber).frame(width: 12)
                (step.summary.isEmpty ? Text("Your message") : Text(verbatim: step.summary)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Retro.Ink.phosphorAmber).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(step.at, format: .dateTime.hour().minute().second()).font(.system(size: 10, design: .monospaced)).foregroundStyle(Retro.Ink.osdWhite.opacity(0.4))
                Group {
                    if !step.done {
                        AgentSpinner(size: 8, color: Retro.Ink.ledGreen)
                    } else if step.failed {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(Retro.Ink.orange)
                    } else {
                        Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Retro.Ink.ledGreen.opacity(0.85))
                    }
                }
                .frame(width: 12)
                Image(systemName: toolSymbol(step.tool)).font(.system(size: 9, weight: .semibold)).foregroundStyle(Retro.Ink.osdWhite.opacity(0.55)).frame(width: 12)
                Text(step.tool).font(.system(size: 11, weight: .semibold)).foregroundStyle(Retro.Ink.osdWhite.opacity(step.done ? 0.75 : 0.95)).frame(width: 64, alignment: .leading).lineLimit(1)
                Text(step.summary).font(.system(size: 11, design: step.tool == "Bash" ? .monospaced : .default))
                    .foregroundStyle(Retro.Ink.osdWhite.opacity(step.done ? 0.6 : 0.9)).lineLimit(2)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Title bar

    private var titleBar: some View {
        RetroTitleBar(AgentNookRoom.fit(session.project, pixel: 1.5, width: 190), tint: session.agent.tint) {
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 6.5, weight: .black)).foregroundStyle(Color.black.opacity(0.85))
                    .frame(width: 14, height: 13)
                    .retroBevel(.raised, cornerRadius: 2, depth: 1, face: Retro.Ink.plasticMid)
            }
            .buttonStyle(.plain)
            .help("Back to the den")
            .accessibilityLabel("Close the window")
            .denFrame("close")
        }
    }

    // MARK: The glass

    private var message: String {
        if !session.lastMessage.isEmpty { return session.lastMessage }
        if !session.title.isEmpty { return session.title }
        return String(localized: "No message yet.")
    }

    private func glass(recentSteps: Bool) -> some View {
        let state = Self.stateWord(look)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Rectangle().fill(state.color).frame(width: 7, height: 7)
                RetroPixelText(state.word, pixel: 1.5, color: state.color)
                switch Self.clockMode(look) {
                case .running:
                    AgentElapsed(start: session.turnStartedAt).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Retro.Ink.osdWhite.opacity(0.8))
                case .fixed:
                    // a finished or stopped task shows how long it took, a fixed time, not a running clock
                    AgentElapsed(start: session.turnStartedAt, end: session.finishedAt ?? session.lastEventAt).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Retro.Ink.osdWhite.opacity(0.8))
                case .none:
                    EmptyView()
                }
                Spacer(minLength: 4)
                if session.subagents > 0 {
                    Text("Helpers: \(session.subagents)").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Retro.Ink.osdWhite.opacity(0.6))
                }
                Text(session.agent.title).font(.system(size: 10.5)).foregroundStyle(Retro.Ink.osdWhite.opacity(0.45))
            }
            // The pager already says the latest message when the notch opened by itself.
            if banner == nil || session.lastMessage.isEmpty {
                Text(message)
                    .font(.system(size: 12.5)).lineSpacing(2).foregroundStyle(Retro.Ink.osdWhite)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if look == .working || look == .needsYou, let step = session.currentStep { currentStep(step) }
            if !session.todos.isEmpty { todos }
            if recentSteps { recent }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black)
        .crtScreen(cornerRadius: Self.screenRadius, scanlines: 0.05, tint: nil, vignette: 0.12)
    }

    /// The tool running right now: its little pixel icon, its name and its short input.
    private func currentStep(_ step: AgentStep) -> some View {
        HStack(spacing: 7) {
            if let prop = AgentNookProp.of(tool: step.tool) {
                PixelPictureView(picture: PixelPicture(w: 8, h: 8, placements: [PixelPlacement(sprite: AgentPixelSprites.prop(prop), x: 0, y: 0)]), kind: session.agent, px: 1.5)
            }
            Text(step.tool).font(.system(size: 11, weight: .semibold)).foregroundStyle(Retro.Ink.osdWhite)
            Text(step.summary).font(.system(size: 11, design: step.tool == "Bash" ? .monospaced : .default)).foregroundStyle(Retro.Ink.osdWhite.opacity(0.7)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Rectangle().fill(Retro.Ink.phosphorGreen.opacity(0.12)))
    }

    /// The agent's own to-do list as LED segments and "2 of 5 · the item".
    private var todos: some View {
        let total = session.todos.count, done = session.todosDone
        return HStack(spacing: 8) {
            AgentDenProgress(value: Double(done) / Double(max(1, total)), segments: min(10, max(2, total)), size: CGSize(width: 96, height: 11), color: look == .stopped ? Retro.Ink.ledYellow : Retro.Ink.ledGreen)
            Text("\(done) of \(total)").font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(Retro.Ink.osdWhite)
            (session.currentTodo.map { Text(verbatim: $0) } ?? (done == total ? Text("All done") : Text(verbatim: ""))).font(.system(size: 11)).foregroundStyle(Retro.Ink.osdWhite.opacity(0.65)).lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    /// The last few finished steps, small.
    @ViewBuilder private var recent: some View {
        let steps = Array(session.steps.filter { $0.done && $0.tool != "Prompt" }.suffix(5).reversed())
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(steps) { step in
                    HStack(spacing: 6) {
                        Image(systemName: step.failed ? "exclamationmark.triangle.fill" : toolSymbol(step.tool)).font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(step.failed ? Retro.Ink.orange : Retro.Ink.osdWhite.opacity(0.5)).frame(width: 12)
                        Text(step.tool).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Retro.Ink.osdWhite.opacity(0.65)).frame(width: 50, alignment: .leading)
                        Text(step.summary).font(.system(size: 10.5, design: step.tool == "Bash" ? .monospaced : .default)).foregroundStyle(Retro.Ink.osdWhite.opacity(0.5)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    // MARK: The deck

    /// The answer controls on dark plastic, as chunky keys.
    private var deck: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(requests) { request in PendingView(request: request, store: store, retro: true) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.clear.retroBevel(.raised, cornerRadius: Self.screenRadius, depth: 1.5, face: Retro.Ink.plasticDark))
    }

    /// Every screen in the window (the agent's glass, the workflow, the answer deck, the pager) has the Agent TV's glass corner, which is
    /// the open notch's own curve, so they all look alike
    static let screenRadius: CGFloat = CRTSetLayout.glassRadius(compact: false)
}

private struct AgentDenContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Progress as LED segments in ONE colour (the state's: green, yellow after a stop), unlit ones dark. The kit's `RetroLEDBar` is a level
/// meter (green, yellow, red), and a finished list that ends in red reads as an error.
struct AgentDenProgress: View {
    let value: Double
    let segments: Int
    let size: CGSize
    let color: Color

    /// How many segments light: the nearest whole one, never more than there are.
    static func lit(value: Double, segments: Int) -> Int { RetroLEDBar.litCount(value: value, segments: segments) }

    var body: some View {
        let lit = Self.lit(value: value, segments: segments)
        Canvas { ctx, canvas in
            guard segments > 0 else { return }
            let inset: CGFloat = 2, gap: CGFloat = 1.5
            let length = canvas.width - 2 * inset, thick = canvas.height - 2 * inset
            let seg = (length - gap * CGFloat(segments - 1)) / CGFloat(segments)
            guard seg > 0.5, thick > 0.5 else { return }
            for i in 0..<segments {
                let rect = CGRect(x: inset + CGFloat(i) * (seg + gap), y: inset, width: seg, height: thick)
                ctx.fill(Path(rect), with: .color(i < lit ? color : color.opacity(0.15)))
                if i < lit { ctx.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(1, thick / 4))), with: .color(Color.white.opacity(0.35))) }
            }
        }
        .frame(width: size.width, height: size.height)
        .retroBevel(.sunken, cornerRadius: 2, depth: 1, face: Color(red: 0.045, green: 0.05, blue: 0.05))
        .accessibilityLabel("Progress \(Int((min(1, max(0, value)) * 100).rounded())) percent")
    }
}
