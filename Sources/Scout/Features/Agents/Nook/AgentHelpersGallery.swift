import SwiftUI

// Gallery `tv-helpers-*`: where an agent's helpers stand. One agent per state (working, needs you, finished, stopped, asleep) with 1, 3, 7 and
// 12 helpers, in the den (the Agents view) and on the dashboard's Agent TV. The helpers must stand right under their agent, centred on it.
// Synthetic agents only.

@MainActor
enum AgentHelpersGallery {
    private static let looks: [AgentNookLook] = [.working, .needsYou, .finished, .stopped, .idle]
    private static let names = ["working", "asking", "done", "stopped", "asleep"]
    private static let props: [AgentNookProp] = [.pencil, .wrench, .magnifier, .globe, .pencil]

    /// One agent per state, each with `n` helpers (the first agent is Claude's, the next Codex's, and so on).
    private static func agents(helpers n: Int, prefix: String, only: [AgentNookLook]? = nil) -> [AgentSession] {
        looks.enumerated().compactMap { i, look in
            guard only?.contains(look) ?? true else { return nil }
            var s = AgentNookSamples.one(look, prop: props[i], kind: i % 2 == 0 ? .claude : .codex, project: names[i], helpers: n, todos: 0, done: 0)
            s.id = "\(prefix)-\(names[i])"
            s.startedAt = Date().addingTimeInterval(-Double(6 - i) * 900)   // a fixed order on the floor (the first started stands on the left)
            return s
        }
    }

    static func register() {
        for n in [1, 3, 7, 12] {
            let store = AgentNookSamples.store(agents(helpers: n, prefix: "d\(n)"))
            let size = CGSize(width: 960, height: AgentDenLayout.baseHeight)
            Gallery.register("tv-helpers-den-\(n)", size: size, backdrop: .window) {
                AgentDenView(store: store, detailID: nil, banner: nil, empty: AgentsWorkspaceView.emptyNote(store: store), fixedClock: .still, fixedLoad: (0.42, 0.66))
                    .environment(\.agentDenTime, AgentTVGallery.day)
                    .frame(width: size.width, height: size.height)
                    .background(Color.black)
            }
        }
        // The same with the figures moving (a hop on the helpers' feet, the agent's second frame).
        let moving = AgentNookSamples.store(agents(helpers: 3, prefix: "dm"))
        Gallery.register("tv-helpers-den-3-motion", size: CGSize(width: 960, height: AgentDenLayout.baseHeight), backdrop: .window) {
            AgentDenView(store: moving, detailID: nil, banner: nil, empty: AgentsWorkspaceView.emptyNote(store: moving), fixedClock: AgentNookClock(t: 0.6, motion: true), fixedLoad: (0.42, 0.66))
                .environment(\.agentDenTime, AgentTVGallery.day)
                .frame(width: 960, height: AgentDenLayout.baseHeight)
                .background(Color.black)
        }
        // A den at night, and a narrow one (the stations shrink to the smallest pixels).
        let night = AgentNookSamples.store(agents(helpers: 7, prefix: "dn"))
        Gallery.register("tv-helpers-den-7-night", size: CGSize(width: 960, height: AgentDenLayout.baseHeight), backdrop: .window) {
            AgentDenView(store: night, detailID: nil, banner: nil, empty: AgentsWorkspaceView.emptyNote(store: night), fixedClock: .still, fixedLoad: (0.42, 0.66))
                .environment(\.agentDenTime, AgentTVGallery.night)
                .frame(width: 960, height: AgentDenLayout.baseHeight)
                .background(Color.black)
        }
        // The dashboard's Agent TV: five rooms on a wide console (compact rooms), then the roomy ones.
        for n in [1, 3, 7, 12] {
            let five = AgentNookSamples.store(agents(helpers: n, prefix: "t\(n)"))
            let three = AgentNookSamples.store(agents(helpers: n, prefix: "u\(n)", only: [.working, .needsYou, .idle]))
            let two = AgentNookSamples.store(agents(helpers: n, prefix: "v\(n)", only: [.finished, .stopped]))
            let width = AgentTVLayout.width(cells: 16) + 28
            Gallery.register("tv-helpers-tv-\(n)", size: CGSize(width: width, height: 3 * (NookMetrics.widgetHeight + 24) + 28), backdrop: .window) {
                AgentNookSheet {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            AgentNookCaption("\(n) helper\(n == 1 ? "" : "s") each · 16 cells · working, asking, done, stopped, asleep")
                            AgentTVCell(cells: 16) { AgentNookPanelView(store: five).load(cpu: 0.42, memory: 0.66) }
                        }
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 3) {
                                AgentNookCaption("8 cells · working, asking, asleep")
                                AgentTVCell(cells: 8) { AgentNookPanelView(store: three).load(cpu: 0.42, memory: 0.66) }
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                AgentNookCaption("6 cells · done, stopped")
                                AgentTVCell(cells: 6) { AgentNookPanelView(store: two).load(cpu: 0.42, memory: 0.66) }
                            }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            AgentNookCaption("3 cells · one agent each")
                            HStack(spacing: 8) {
                                ForEach(Array(looks.enumerated()), id: \.offset) { i, look in
                                    AgentTVCell(cells: 3) {
                                        AgentNookPanelView(store: AgentNookSamples.store(agents(helpers: n, prefix: "w\(n)\(i)", only: [look]))).load(cpu: 0.42, memory: 0.66)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
