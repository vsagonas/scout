import SwiftUI

// Gallery `tv-*`: Agent TV (the dashboard's Agents panel) at every width, the den (the full Agents view) with 1 to 9 agents by day and
// by night, empty, with an agent's window open in each state, and the three automatic openings. Synthetic agents only.

@MainActor
enum AgentTVGallery {
    /// The moment pictures show: a day (14:20) and a night (23:05), so the clock and the window are the same every time.
    nonisolated static let day = AgentTVGallery.moment(hour: 14, minute: 20)
    nonisolated static let night = AgentTVGallery.moment(hour: 23, minute: 5)

    nonisolated static func moment(hour: Int, minute: Int) -> Date {
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.hour = hour
        c.minute = minute
        return Calendar.current.date(from: c) ?? Date()
    }

    static func register() {
        AgentPixelGallery.register()
        sets()
        specials()
        dashboard()
        AgentDenGallery.register()
        AgentHelpersGallery.register()
    }

    private static func sheet<V: View>(_ name: String, _ width: CGFloat, _ height: CGFloat, @ViewBuilder _ content: @escaping () -> V) {
        Gallery.register("tv-\(name)", size: CGSize(width: width, height: height), backdrop: .window) { AgentNookSheet(content: content) }
    }

    // MARK: Agent TV at every width

    private static func sets() {
        let counts = [0, 1, 3, 6, 9]
        for cells in [3, 4, 6, 10, 16] {
            let stores = counts.map { n in AgentNookSamples.store("tv\(cells)-\(n)", AgentNookSamples.sessions(n), asking: n >= 6 ? "nk-6" : nil) }
            let width = AgentTVLayout.width(cells: cells) + 28
            sheet(String(format: "set-c%02d", cells), width, CGFloat(counts.count) * (NookMetrics.widgetHeight + 24) + 28) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(counts.enumerated()), id: \.offset) { i, n in
                        VStack(alignment: .leading, spacing: 3) {
                            AgentNookCaption("\(cells) cells · \(n) agent\(n == 1 ? "" : "s")" + (n >= 6 ? " · one needs you" : ""))
                            AgentTVCell(cells: cells) { AgentNookPanelView(store: stores[i]).load(cpu: 0.42, memory: 0.66) }
                        }
                    }
                }
            }
        }
    }

    /// ON AIR (an agent needs you) next to a quiet set, and the empty set (faded snow) at each width.
    private static func specials() {
        let quiet = AgentNookSamples.store("tv-quiet", Array(AgentNookSamples.sessions(9).filter { $0.state != .waiting }.prefix(3)))
        let asking = AgentNookSamples.store("tv-asking", Array(AgentNookSamples.sessions(3)), asking: "nk-2")
        let empty = AgentNookSamples.store("tv-empty", [])
        sheet("onair-nosignal", 6 * 50 + 8 * 50 + 28 + 14, 2 * (NookMetrics.widgetHeight + 24) + 28) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        AgentNookCaption("ON AIR is dark: nobody needs you")
                        AgentTVCell(cells: 6) { AgentNookPanelView(store: quiet).load(cpu: 0.3, memory: 0.5) }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        AgentNookCaption("ON AIR is lit: an agent needs you")
                        AgentTVCell(cells: 8) { AgentNookPanelView(store: asking).load(cpu: 0.88, memory: 0.74) }
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    ForEach([3, 4, 6, 8], id: \.self) { cells in
                        VStack(alignment: .leading, spacing: 3) {
                            AgentNookCaption("EMPTY · \(cells) cells")
                            AgentTVCell(cells: cells) { AgentNookPanelView(store: empty).load(cpu: 0.2, memory: 0.4) }
                        }
                    }
                }
            }
        }
        sheet("nosignal-wide", 16 * 50 + 28, NookMetrics.widgetHeight + 50) {
            VStack(alignment: .leading, spacing: 3) {
                AgentNookCaption("EMPTY · 16 cells")
                AgentTVCell(cells: 16) { AgentNookPanelView(store: empty).load(cpu: 0.2, memory: 0.4) }
            }
        }
        // The glow of a highlighted room.
        let glow = AgentNookSamples.store("tv-glow", AgentNookSamples.sessions(4))
        sheet("highlighted", AgentTVLayout.width(cells: 8) + 28, NookMetrics.widgetHeight + 50) {
            VStack(alignment: .leading, spacing: 3) {
                AgentNookCaption("The first room glows for a moment (a highlighted agent)")
                AgentTVCell(cells: 8) { AgentNookPanelView(store: glow, highlighted: "nk-3").load(cpu: 0.42, memory: 0.66) }
            }
        }
        // Long project names: the hanging lamp gives way to the name plate, and the moon moves under it.
        let all = AgentNookSamples.sessions(9)
        func named(_ project: String, _ pick: (AgentSession) -> Bool) -> AgentSession {
            var s = all.first(where: pick) ?? all[0]
            s.cwd = "/Users/you/Dev/\(project)"
            return s
        }
        let working = named("game-unity") { $0.state == .working }
        let asleep = named("sandbox-experiments") { $0.state == .idle }
        let askingLong = named("game-unity") { $0.state == .waiting && $0.finishedAt == nil }
        let longOne = AgentNookSamples.store("tv-long1", [working])
        let longAsleep = AgentNookSamples.store("tv-long2", [asleep])
        let longThree = AgentNookSamples.store("tv-long3", [askingLong, named("my-site") { $0.state == .working }, asleep])
        let widths = AgentTVLayout.width(cells: 3) + AgentTVLayout.width(cells: 4) + AgentTVLayout.width(cells: 6) + 2 * 14 + 28
        sheet("longnames", widths, 2 * (NookMetrics.widgetHeight + 24) + 28) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach([3, 4, 6], id: \.self) { cells in
                        VStack(alignment: .leading, spacing: 3) {
                            AgentNookCaption("a long name · \(cells) cells")
                            AgentTVCell(cells: cells) { AgentNookPanelView(store: longOne).load(cpu: 0.42, memory: 0.66) }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        AgentNookCaption("asleep · 3 cells")
                        AgentTVCell(cells: 3) { AgentNookPanelView(store: longAsleep).load(cpu: 0.2, memory: 0.4) }
                    }
                    ForEach([4, 6], id: \.self) { cells in
                        VStack(alignment: .leading, spacing: 3) {
                            AgentNookCaption("three long names · \(cells) cells")
                            AgentTVCell(cells: cells) { AgentNookPanelView(store: longThree).load(cpu: 0.2, memory: 0.4) }
                        }
                    }
                }
            }
        }
    }

    // MARK: The set inside the real dashboard row

    private static func dashboard() {
        func scene(_ name: String, agents: Int, asking: Bool = false, layout: [WidgetKind], cap: CGFloat? = nil) {
            let store = AgentNookSamples.store("tvdash-\(name)", AgentNookSamples.sessions(agents), asking: asking ? "nk-6" : nil)
            let size = CGSize(width: DashGallery.wide, height: 290)
            Gallery.register("tv-dash-\(name)", size: size) {
                let _ = DashPreview.seed(store)
                NotchScene(size: size, open: true, workspace: .nook, layout: layout, live: NookLive(playing: false, openTodos: 0, agents: agents),
                           prepare: { nook in
                    nook.viewOverride = { item in item == .panel(.agents) ? AnyView(AgentNookPanelView(store: store).load(cpu: 0.42, memory: 0.66)) : nil }
                }, widthCap: cap, showNotchRect: false)
            }
        }
        scene("1agent", agents: 1, layout: [.agents, .askAI, .pulse, .today])
        scene("3agents", agents: 3, layout: [.agents, .askAI, .pulse, .today])
        scene("6agents-asking", agents: 6, asking: true, layout: [.agents, .askAI, .pulse, .today])
        scene("narrow", agents: 4, layout: [.agents, .askAI, .pulse, .today], cap: 640)
        scene("empty", agents: 0, layout: [.agents, .askAI, .pulse, .today])
        scene("wide-9agents", agents: 9, asking: true, layout: [.agents, .pulse, .today])
    }
}

/// The black notch behind a picture, and the set as the dashboard's cell holds it (the set paints its whole bounds).
struct AgentTVCell<Content: View>: View {
    var cells: Int
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(width: AgentTVLayout.width(cells: cells), height: NookMetrics.widgetHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - The sprite sheets

/// The 8-bit sprites of the scouts, large and at real size.
@MainActor
enum AgentPixelGallery {
    static func register() {
        func sheet<V: View>(_ name: String, _ w: CGFloat, _ h: CGFloat, @ViewBuilder _ content: @escaping () -> V) {
            Gallery.register("tv-\(name)", size: CGSize(width: w, height: h), backdrop: .window) { AgentNookSheet(content: content) }
        }
        let looks = AgentNookLook.allCases
        // Every pose of both kinds, large (6 pt per pixel), both frames.
        sheet("sprites-large", 5 * 214 + 28, 4 * 160 + 80) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach([AgentKind.claude, .codex], id: \.self) { kind in
                    ForEach([0, 1], id: \.self) { frame in
                        HStack(alignment: .bottom, spacing: 8) {
                            ForEach(looks) { look in
                                PixelPictureView(picture: AgentPixelWorld.picture(look: look, prop: .pencil, frame: frame, blink: false), kind: kind, px: 6)
                                    .frame(width: 206, height: 150, alignment: .bottom)
                                    .background(Color(white: 0.09))
                            }
                        }
                    }
                }
                AgentNookCaption("claude then codex, frame A then B: working, needs you, done, stopped, asleep (6 pt per pixel)")
            }
        }
        // The same at real size, as the rooms draw them (2 pt per pixel).
        sheet("sprites-real", 5 * 100 + 28, 4 * 56 + 50) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach([AgentKind.claude, .codex], id: \.self) { kind in
                    ForEach([0, 1], id: \.self) { frame in
                        HStack(alignment: .bottom, spacing: 6) {
                            ForEach(looks) { look in
                                PixelPictureView(picture: AgentPixelWorld.picture(look: look, prop: .wrench, frame: frame, blink: false), kind: kind, px: 2)
                                    .frame(width: 94, height: 50, alignment: .bottom)
                                    .background(Color(white: 0.09))
                            }
                        }
                    }
                }
                AgentNookCaption("real size, 2 pt per pixel")
            }
        }
        // Props, helpers, bubbles and small things, 10 pt per pixel.
        sheet("sprites-parts", 1100, 330) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 14) {
                    ForEach(AgentNookProp.allCases, id: \.self) { p in
                        PixelPictureView(picture: PixelPicture(w: 8, h: 8, placements: [PixelPlacement(sprite: AgentPixelSprites.prop(p), x: 0, y: 0)]), kind: .claude, px: 10)
                            .padding(6).background(Color(white: 0.04))
                    }
                    PixelPictureView(picture: PixelPicture(w: 8, h: 8, placements: [PixelPlacement(sprite: AgentPixelSprites.textLines, x: 0, y: 0)]), kind: .claude, px: 10)
                        .padding(6).background(Color(white: 0.04))
                    PixelPictureView(picture: PixelPicture(w: 8, h: 8, placements: [PixelPlacement(sprite: AgentPixelSprites.miniAwake, x: 0, y: 0)]), kind: .claude, px: 10)
                    PixelPictureView(picture: PixelPicture(w: 8, h: 8, placements: [PixelPlacement(sprite: AgentPixelSprites.miniAsleep, x: 0, y: 0)]), kind: .claude, px: 10)
                    PixelPictureView(picture: PixelPicture(w: 8, h: 8, placements: [PixelPlacement(sprite: AgentPixelSprites.miniAwake, x: 0, y: 0)]), kind: .codex, px: 10)
                    PixelPictureView(picture: PixelPicture(w: 8, h: 8, placements: [PixelPlacement(sprite: AgentPixelSprites.miniAsleep, x: 0, y: 0)]), kind: .codex, px: 10)
                }
                HStack(alignment: .bottom, spacing: 14) {
                    ForEach(Array([AgentPixelSprites.askBubble, AgentPixelSprites.checkBadge, AgentPixelSprites.star, AgentPixelSprites.zSmall,
                                   AgentPixelSprites.zMedium, AgentPixelSprites.zLarge, AgentPixelSprites.moon, AgentPixelSprites.armUp, AgentPixelSprites.computer,
                                   AgentPixelWorld.beanbag].enumerated()), id: \.offset) { _, sprite in
                        PixelPictureView(picture: PixelPicture(w: sprite.width, h: sprite.height, placements: [PixelPlacement(sprite: sprite, x: 0, y: 0)]), kind: .claude, px: 6)
                    }
                }
                AgentNookCaption("props, helpers (awake, asleep, both kinds), bubbles, badge, star, Z's, moon, arm, computer, beanbag")
            }
        }
        // The sprites of the scout itself in every face, 10 pt per pixel.
        sheet("sprites-faces", 1000, 240) {
            HStack(alignment: .bottom, spacing: 12) {
                ForEach(Array([AgentPixelSprites.scout, AgentPixelSprites.scoutBlink, AgentPixelSprites.scoutHappy, AgentPixelSprites.scoutDizzy, AgentPixelSprites.scoutAsleep].enumerated()), id: \.offset) { _, sprite in
                    PixelPictureView(picture: PixelPicture(w: sprite.width, h: sprite.height, placements: [PixelPlacement(sprite: sprite, x: 0, y: 0)]), kind: .claude, px: 9)
                        .padding(8).background(Color(white: 0.06))
                }
            }
        }
    }
}

/// A pixel picture drawn at an exact pixel size (the gallery and the tests).
struct PixelPictureView: View {
    var picture: PixelPicture
    var kind: AgentKind = .claude
    var px: CGFloat

    var body: some View {
        Canvas { ctx, size in
            var c = ctx
            picture.draw(&c, origin: .zero, px: px, palette: .world(kind))
        }
        .frame(width: CGFloat(picture.w) * px, height: CGFloat(picture.h) * px)
        .accessibilityHidden(true)
    }
}

// MARK: - The den

/// The den at its real size (960 x 360 as the notch gives it), by day and by night, with 1 to 9 agents, empty, and with an agent's window
/// open in each state. A store of its own for every picture.
@MainActor
enum AgentDenGallery {
    static let size = CGSize(width: 960, height: AgentDenLayout.baseHeight)

    private static func store(_ name: String, _ sessions: [AgentSession], pending: [AgentPending] = []) -> AgentsStore {
        let store = AgentsStore(directory: AppPaths.folder("agentden-\(name)"))
        store.loadSessions(sessions, pending: pending)
        store.previewDoneToday(sessions.isEmpty ? 0 : 5)
        return store
    }

    private static func den(_ name: String, _ store: AgentsStore, time: Date = AgentTVGallery.day, detail: String? = nil, banner: AgentAnnouncement? = nil,
                            height: CGFloat = AgentDenLayout.baseHeight, clock: AgentNookClock = .still, width: CGFloat? = nil) {
        let wide = width ?? size.width
        Gallery.register("tv-den-\(name)", size: CGSize(width: wide, height: height), backdrop: .window) {
            AgentDenView(store: store, detailID: detail, banner: banner, empty: AgentsWorkspaceView.emptyNote(store: store), fixedClock: clock, fixedLoad: (0.42, 0.66))
                .environment(\.agentDenTime, time)
                .frame(width: wide, height: height)
                .background(Color.black)
        }
    }

    static func held(_ id: String) -> AgentPending {
        AgentPending(sessionID: id, kind: .permission, tool: "Bash", summary: "terraform apply -auto-approve", detail: "terraform apply -auto-approve",
                     questions: [], rawToolInput: nil, agent: .codex)
    }

    static func question(_ id: String) -> AgentPending {
        AgentPending(sessionID: id, kind: .question, tool: "AskUserQuestion", summary: "Which region?", detail: "",
                     questions: [AgentQuestion(question: "Which region should the bucket move to?", header: "Region",
                                               options: [.init(label: "eu-west-1", detail: ""), .init(label: "us-east-1", detail: ""), .init(label: "Neither", detail: "")], multiSelect: false)],
                     rawToolInput: nil, agent: .codex)
    }

    static func register() {
        for n in [1, 3, 6, 9] {
            den("\(n)", store("n\(n)", AgentNookSamples.sessions(n), pending: n >= 3 ? [held("nk-6")].filter { p in AgentNookSamples.sessions(n).contains { $0.id == p.sessionID } } : []))
        }
        den("night-3", store("night3", AgentNookSamples.sessions(3)), time: AgentTVGallery.night)
        den("night-9", store("night9", AgentNookSamples.sessions(9)), time: AgentTVGallery.night)
        den("1-motion", store("m1", AgentNookSamples.sessions(1)), clock: AgentNookClock(t: 0.6, motion: true))
        den("6-motion", store("m6", AgentNookSamples.sessions(6)), clock: AgentNookClock(t: 0.6, motion: true))
        den("empty", store("empty", []))
        den("empty-night", store("emptynight", []), time: AgentTVGallery.night)
        // The same note the workspace builds: the denied case says the folders cannot be read yet and has the key to allow them.
        let denied = store("emptydenied", [])
        denied.previewScan(AgentScanner.Status(access: [.claude: .denied, .codex: .denied]))
        den("empty-denied", denied)
        den("empty-denied-narrow", denied, width: 640)   // a narrow notch: the line wraps and still stands on the rug with its key
        den("empty-narrow", store("emptynarrow", []), width: 640)
        // Helpers in numbers: 5, 7 and 12 behind the "+N", at the biggest pixels (3 agents) and at the smallest (9).
        func crowded(_ id: String, _ kind: AgentKind, _ project: String, _ state: AgentState, helpers: Int) -> AgentSession {
            var s = AgentNookSamples.sessions(9)[0]
            s.id = id; s.agent = kind; s.cwd = "/Users/you/Dev/\(project)"; s.state = state; s.subagents = helpers
            return s
        }
        den("helpers-3", store("h3", [crowded("h-a", .claude, "alpha", .working, helpers: 5), crowded("h-b", .codex, "beta", .working, helpers: 7), crowded("h-c", .claude, "gamma", .working, helpers: 12)]))
        den("helpers-3-states", store("h3s", Array(AgentNookSamples.sessions(9).prefix(0)) + [
            crowded("h-a", .claude, "alpha", .waiting, helpers: 5), crowded("h-b", .codex, "beta", .idle, helpers: 7), crowded("h-c", .claude, "gamma", .working, helpers: 12)]))
        den("helpers-9", store("h9", (0..<9).map { crowded("h-\($0)", $0 % 2 == 0 ? .claude : .codex, ["alpha", "beta", "gamma", "delta", "eps", "zeta", "eta", "theta", "iota"][$0], .working, helpers: [5, 7, 12, 2, 6, 9, 3, 8, 13][$0]) }))
        // A window open beside the den, in each state: a permission, a question, a finished task, a task that stopped.
        let sessions = AgentNookSamples.sessions(9)
        let window = AgentDenLayout.baseHeight + AgentDenLayout.extraHeight(pending: [held("nk-6")], banner: false)
        den("window-permission", store("wp", Array(sessions.prefix(6)), pending: [held("nk-6")]), detail: "nk-6", height: window)
        den("window-question", store("wq", Array(sessions.prefix(6)), pending: [question("nk-6")]), detail: "nk-6", height: window)
        den("window-working", store("ww", Array(sessions.prefix(6))), detail: "nk-1")
        den("window-finished", store("wf", Array(sessions.prefix(6))), detail: "nk-5")
        den("window-error", store("we", Array(sessions.prefix(7))), detail: "nk-7")
        den("window-9", store("w9", sessions), detail: "nk-2")
        den("window-night", store("wn", Array(sessions.prefix(6)), pending: [held("nk-6")]), time: AgentTVGallery.night, detail: "nk-6", height: window)
        // The banner of an automatic opening, on the same window.
        let withBanner = AgentDenLayout.baseHeight + AgentDenLayout.extraHeight(pending: [held("nk-6")], banner: true)
        den("auto-needsyou", store("an", Array(sessions.prefix(6)), pending: [held("nk-6")]), detail: "nk-6",
            banner: AgentAnnouncement(sessionID: "nk-6", kind: .needsYou, at: Date()), height: withBanner)
        den("auto-finished", store("af", Array(sessions.prefix(6))), detail: "nk-5",
            banner: AgentAnnouncement(sessionID: "nk-5", kind: .finished(minutes: 12), at: Date()), height: AgentDenLayout.baseHeight + 36)
        den("auto-error", store("ae", Array(sessions.prefix(7))), detail: "nk-7",
            banner: AgentAnnouncement(sessionID: "nk-7", kind: .error, at: Date()), height: AgentDenLayout.baseHeight + 36)
    }
}
