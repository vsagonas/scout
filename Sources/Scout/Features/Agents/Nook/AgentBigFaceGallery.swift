import SwiftUI

// Pictures for the big figures' faces:
// the same agent in the
// wing, in the TV's room and in the den, every headwear style in several colours, every pose. Names start with `agents-bigface-`.

@MainActor
enum AgentBigFaceGallery {
    /// The colours a head can wear, by name: brown, black, blond, red, blue, green, purple, magenta (`AgentFaceArt.colours`).
    private static let colourNames = ["brown", "black", "blond", "red", "blue", "green", "purple", "pink"]
    private static let styleNames = ["bare", "hair", "cap", "beanie", "headphones", "bow"]

    /// One face: the style, one of the eight colours, one of the eight skins.
    private static func face(_ style: Int, _ colour: Int, skin: Int = 0) -> Int { AgentFaceArt.variant(style: style, colour: colour, skin: skin) }

    private static let looks = AgentNookLook.allCases

    /// The mini face of an agent in the mood of a look, still, next to the big one.
    private static func mini(_ look: AgentNookLook, kind: AgentKind, variant: Int, px: CGFloat) -> some View {
        AgentFaceIcon(agent: kind, mood: AgentFaceMood(look), frozenAt: 0.01, frozenBurst: false, variant: variant, px: px)
    }

    static func register() {
        styles()
        motion()
        poses()
        zoom()
        den()
        tv()
    }

    private static func sheet<V: View>(_ name: String, _ width: CGFloat, _ height: CGFloat, @ViewBuilder _ content: @escaping () -> V) {
        Gallery.register("agents-bigface-\(name)", size: CGSize(width: width, height: height), backdrop: .window) { AgentNookSheet(content: content) }
    }

    // MARK: Every style and colour, big, next to its mini face

    private static func styles() {
        // Finished (happy) and working, three colours a style: the mini face on the left of each big figure, so the two can be compared.
        for (look, title) in [(AgentNookLook.finished, "finished"), (.working, "working")] {
            sheet("styles-\(title)", 1800, 1230) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<AgentFaceArt.styleCount, id: \.self) { style in
                        HStack(alignment: .bottom, spacing: 22) {
                            Text(styleNames[style]).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.6)).frame(width: 90, alignment: .leading)
                            ForEach([7, 5, 2, 1, 4, 3], id: \.self) { colour in
                                let v = face(style, colour, skin: (style + colour) % 3)
                                VStack(spacing: 4) {
                                    HStack(alignment: .bottom, spacing: 6) {
                                        mini(look, kind: .claude, variant: v, px: 3)
                                        AgentNookCritter(kind: .claude, variant: v, pose: look.pose, prop: .pencil, furniture: false, pixel: 7)
                                            .frame(width: 30 * 7, height: 24 * 7, alignment: .bottom)
                                    }
                                    AgentNookCaption(colourNames[colour])
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: The faces move like the wing's: steps of the beat, one row a mood

    private static func motion() {
        // Working: 24 steps, the glances (a step every 8) and the blinks (steps 0 and 17); the others: the burst (steps 0 2 4 6), then at rest.
        let rows: [(String, AgentNookLook, [(Int, Bool)])] = [
            ("working, steps 0 1 2 8 9 16 17 18 24 25 (blink at 0 and 17, glance right at 8, ahead at 16, left at 24)", .working,
             [0, 1, 2, 8, 9, 16, 17, 18, 24, 25].map { ($0, false) }),
            ("needs you: the burst calls (steps 0 2 4 6), then the still mouth (step 8)", .needsYou, [0, 2, 4, 6, 8].map { ($0, $0 < 8) }),
            ("finished: the burst laughs (steps 0 2 4 6), then the smile (step 8)", .finished, [0, 2, 4, 6, 8].map { ($0, $0 < 8) }),
            ("stopped: the burst swaps the crosses (steps 0 2 4 6), then still (step 8)", .stopped, [0, 2, 4, 6, 8].map { ($0, $0 < 8) }),
            ("asleep: no step changes it (steps 0 8 16)", .idle, [0, 8, 16].map { ($0, false) }),
        ]
        for (name, variant) in [("hair", face(1, 7, skin: 1)), ("headphones", face(4, 5, skin: 4))] {
            sheet("motion-\(name)", 1500, 520) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 2) {
                            AgentNookCaption(row.0)
                            HStack(alignment: .bottom, spacing: 6) {
                                ForEach(Array(row.2.enumerated()), id: \.offset) { _, step in
                                    PixelPictureView(picture: AgentPixelWorld.picture(look: row.1, prop: .globe, frame: 0, blink: false, furniture: false, variant: variant,
                                                                                    face: AgentFaceStep(tick: step.0, burst: step.1)), kind: .claude, px: 3)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Every pose of every style (a row of poses a colour), still and in motion (the second frame)

    private static func poses() {
        for style in 1..<AgentFaceArt.styleCount {
            sheet("poses-\(styleNames[style])", 1330, 700) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach([(7, 0), (5, 1), (1, 2), (4, 3)], id: \.0) { colour, skin in
                        let v = face(style, colour, skin: skin)
                        HStack(alignment: .bottom, spacing: 10) {
                            ForEach(looks, id: \.self) { look in
                                AgentNookCritter(kind: skin % 2 == 0 ? .claude : .codex, variant: v, pose: look.pose, prop: .pencil, clock: AgentNookClock(t: 0.6, motion: skin >= 2),
                                                 furniture: look == .working || look == .idle, pixel: 4.5)
                                    .frame(width: 30 * 4.5, height: 24 * 4.5, alignment: .bottom)
                            }
                        }
                        AgentNookCaption("\(styleNames[style]) · \(colourNames[colour]) · rows 1 and 2 still, rows 3 and 4 the second frame of the motion")
                    }
                }
            }
        }
    }

    // MARK: Close-ups of the head (every style, two skins), 16 pt cells

    private static func zoom() {
        sheet("zoom", 1560, 520) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach([0, 3], id: \.self) { skin in
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(0..<AgentFaceArt.styleCount, id: \.self) { style in
                            let v = face(style, [7, 5, 2, 3, 4, 6][style], skin: skin * 2)
                            VStack(spacing: 3) {
                                AgentNookCritter(kind: skin == 0 ? .claude : .codex, variant: v, pose: .holdingCheck, prop: .pencil, furniture: false, pixel: 8)
                                    .frame(width: 28 * 8, height: 24 * 8, alignment: .bottom)
                                AgentNookCaption("\(styleNames[style]) \(colourNames[[7, 5, 2, 3, 4, 6][style]])")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: The den: stations at the sizes the den draws (1.5 to 5 pt cells), one style a station

    private static func station(_ look: AgentNookLook, kind: AgentKind, helpers: Int = 2) -> AgentDenStation {
        AgentDenStation(AgentNookSamples.one(look, prop: [.pencil, .wrench, .magnifier, .globe][abs(look.hashValue) % 4], kind: kind, project: "site", helpers: helpers), needsYou: look == .needsYou)
    }

    private static func den() {
        for (name, px) in [("5", CGFloat(5)), ("3", 3), ("2", 2), ("1.5", 1.5)] {
            let across = Int(1500 / (44 * px + 6))
            sheet("den-px\(name)", 1500, CGFloat(2 * (36 * px + 28) + 40)) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(alignment: .top, spacing: 6) {
                            ForEach(0..<min(across, 10), id: \.self) { i in
                                let n = row * min(across, 10) + i
                                let look = looks[n % looks.count]
                                let style = 1 + (n / looks.count + n) % 5
                                let spot = AgentDenSpot(index: n, rect: .zero, px: px, row: 0)
                                AgentDenStationView(station: station(look, kind: n % 2 == 0 ? .claude : .codex), spot: spot, clock: .still, selected: false, glow: false,
                                                    variant: face(style, [7, 5, 2, 3, 4, 6, 1, 0][n % 8], skin: n % 8)) {}
                                    .frame(width: 44 * px, height: 36 * px + 22)
                            }
                        }
                    }
                }
                .background(Color(red: 0.2, green: 0.1, blue: 0.14))
            }
        }
        // The den as the notch shows it: nine agents, each its own face (the faces the book gives them), by day and night, and one agent's window open.
        sheet("den-five-looks", 1500, 330) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(looks.enumerated()), id: \.offset) { i, look in
                    let spot = AgentDenSpot(index: i, rect: .zero, px: 5, row: 0)
                    AgentDenStationView(station: station(look, kind: i % 2 == 0 ? .claude : .codex), spot: spot, clock: .still, selected: false, glow: false,
                                        variant: face(1 + i, [7, 5, 2, 3, 4][i], skin: i)) {}
                        .frame(width: 44 * 5, height: 36 * 5 + 22)
                }
            }
            .background(Color(red: 0.2, green: 0.1, blue: 0.14))
        }
    }

    // MARK: The TV's rooms, roomy and compact, real size and three times larger

    private static func tv() {
        func model(_ look: AgentNookLook, kind: AgentKind, helpers: Int = 0) -> AgentNookRoomModel {
            AgentNookRoomModel(AgentNookSamples.one(look, prop: .pencil, kind: kind, project: "site", helpers: helpers, todos: 0, done: 0), needsYou: look == .needsYou)
        }
        sheet("tv-roomy", 5 * 150 + 40, 4 * 112 + 40) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array([(1, 7), (2, 5), (3, 2), (4, 1)].enumerated()), id: \.offset) { r, pick in
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(looks, id: \.self) { look in
                            AgentNookRoom(model: model(look, kind: r % 2 == 0 ? .claude : .codex), style: .roomy, variant: face(pick.0, pick.1, skin: r)).frame(width: 140, height: 105)
                        }
                    }
                }
            }
        }
        sheet("tv-roomy-zoom", 5 * 336 + 40, 3 * 250 + 40) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array([(1, 7), (4, 5), (5, 2)].enumerated()), id: \.offset) { r, pick in
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(looks, id: \.self) { look in
                            AgentNookRoom(model: model(look, kind: r % 2 == 0 ? .claude : .codex), style: .roomy, variant: face(pick.0, pick.1, skin: r + 1))
                                .frame(width: 140, height: 105).scaleEffect(2.3, anchor: .topLeading).frame(width: 322, height: 242, alignment: .topLeading)
                        }
                    }
                }
            }
        }
        sheet("tv-compact", 5 * 90 + 40, 4 * 112 + 40) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array([(2, 3), (3, 5), (5, 7), (1, 4)].enumerated()), id: \.offset) { r, pick in
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(looks, id: \.self) { look in
                            AgentNookRoom(model: model(look, kind: r % 2 == 0 ? .claude : .codex), style: .compact, variant: face(pick.0, pick.1, skin: r + 2)).frame(width: 78, height: 105)
                        }
                    }
                }
            }
        }
        sheet("tv-compact-zoom", 5 * 210 + 40, 2 * 280 + 40) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array([(2, 3), (4, 7)].enumerated()), id: \.offset) { r, pick in
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(looks, id: \.self) { look in
                            AgentNookRoom(model: model(look, kind: r % 2 == 0 ? .claude : .codex), style: .compact, variant: face(pick.0, pick.1, skin: r + 3))
                                .frame(width: 78, height: 105).scaleEffect(2.6, anchor: .topLeading).frame(width: 203, height: 273, alignment: .topLeading)
                        }
                    }
                }
            }
        }
    }
}
