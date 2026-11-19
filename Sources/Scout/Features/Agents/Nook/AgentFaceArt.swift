import SwiftUI

// The face of an agent as a small square icon for the closed notch's wings.
// 12 x 12 cells of 1.5 pt: an 18 pt square that lands on whole device pixels at 2x. The same palette letters as the agents in the
// den (`PixelPalette.world`), so a face wears its agent's colour: Claude Code sand-orange, Codex green. Our own drawing, no image files.

/// How a face looks: what its agent is doing.
enum AgentFaceMood: CaseIterable, Equatable {
    case working     // looks about, blinks and talks (typing away)
    case asking      // wide eyes, a calling mouth and an amber ring: it needs you
    case finished    // happy arches and a smile: your move
    case stopped     // dizzy eyes and a wobbly mouth: it ended on an error
    case idle        // eyes shut, a tiny mouth, a little dimmer

    init(_ look: AgentNookLook) {
        switch look {
        case .working: self = .working
        case .needsYou: self = .asking
        case .finished: self = .finished
        case .stopped: self = .stopped
        case .idle: self = .idle
        }
    }
}

enum AgentFaceArt {
    static let cells = 12
    /// 1.5 pt a cell: a multiple of 0.5 pt, so every cell is three whole device pixels at 2x.
    static let px: CGFloat = 1.5
    static var side: CGFloat { CGFloat(cells) * px }

    /// One step of a face's life lasts this long (seconds): the mouth moves a step at a time. Reduce Motion slows it down.
    static func beat(calm: Bool) -> Double { calm ? 0.4 : 0.2 }

    /// The step a face is on at time `t` (seconds; `phase` keeps faces side by side from moving in step).
    static func tick(at t: Double, phase: Double = 0, calm: Bool = false) -> Int {
        Int(((t + phase) / beat(calm: calm) + 1e-6).rounded(.down))
    }

    typealias Cells = [(Int, Int, Character)]

    /// The bare face: the kind's colour, a highlight at the top left, a shaded side, cheeks. No eyes and no mouth yet.
    static let base = PixelSprite([
        "..oooooooo..",
        ".ohhhhbbbbo.",
        "ohhbbbbbbbbo",
        "ohbbbbbbbbbo",
        "obbbbbbbbbbo",
        "obbbbbbbbbbo",
        "obbbbbbbbbbo",
        "obrbbbbbbrbo",
        "obbbbbbbbbso",
        "obbbbbbbbsso",
        ".osssssssso.",
        "..oooooooo..",
    ])

    // MARK: Eyes (the face's middle is between columns 5 and 6; both eyes are mirror images)

    /// Two eyes looking a cell to the left (-1), ahead (0) or to the right (1): a 2 x 3 block with a white spark at the top left.
    private static func looking(_ shift: Int) -> Cells {
        var out: Cells = []
        for x in [3 + shift, 7 + shift] {
            out += [(x, 4, "w"), (x + 1, 4, "k"), (x, 5, "k"), (x + 1, 5, "k"), (x, 6, "k"), (x + 1, 6, "k")]
        }
        return out
    }

    /// Wide open: white eyes with dark pupils that look at you.
    private static let wide: Cells = [
        (2, 3, "w"), (3, 3, "w"), (4, 3, "w"), (2, 4, "w"), (3, 4, "k"), (4, 4, "k"), (2, 5, "w"), (3, 5, "k"), (4, 5, "k"), (2, 6, "w"), (3, 6, "w"), (4, 6, "w"),
        (7, 3, "w"), (8, 3, "w"), (9, 3, "w"), (7, 4, "k"), (8, 4, "k"), (9, 4, "w"), (7, 5, "k"), (8, 5, "k"), (9, 5, "w"), (7, 6, "w"), (8, 6, "w"), (9, 6, "w"),
    ]

    /// A blink: two short lines.
    private static let blink: Cells = [(3, 5, "k"), (4, 5, "k"), (7, 5, "k"), (8, 5, "k")]

    /// Asleep: two longer lines.
    private static let shut: Cells = [(2, 5, "k"), (3, 5, "k"), (4, 5, "k"), (7, 5, "k"), (8, 5, "k"), (9, 5, "k")]

    /// Happy: two little arches.
    private static let happy: Cells = [(2, 5, "k"), (3, 4, "k"), (4, 5, "k"), (7, 5, "k"), (8, 4, "k"), (9, 5, "k")]

    /// Dizzy: crosses that swap between an X and a plus.
    private static let dizzy: [Cells] = [
        [(2, 4, "k"), (4, 4, "k"), (3, 5, "k"), (2, 6, "k"), (4, 6, "k"), (7, 4, "k"), (9, 4, "k"), (8, 5, "k"), (7, 6, "k"), (9, 6, "k")],
        [(3, 4, "k"), (2, 5, "k"), (3, 5, "k"), (4, 5, "k"), (3, 6, "k"), (8, 4, "k"), (7, 5, "k"), (8, 5, "k"), (9, 5, "k"), (8, 6, "k")],
    ]

    // MARK: Mouths (rows 8 and 9, under the cheeks)

    private static let small: Cells = [(5, 8, "k"), (6, 8, "k")]
    private static let line: Cells = [(4, 8, "k"), (5, 8, "k"), (6, 8, "k"), (7, 8, "k")]
    private static let open: Cells = [(4, 8, "k"), (5, 8, "k"), (6, 8, "k"), (7, 8, "k"), (4, 9, "k"), (5, 9, "R"), (6, 9, "R"), (7, 9, "k")]
    private static let oh: Cells = [(5, 8, "k"), (6, 8, "k"), (5, 9, "k"), (6, 9, "k")]
    private static let smile: Cells = [(3, 8, "k"), (4, 9, "k"), (5, 9, "k"), (6, 9, "k"), (7, 9, "k"), (8, 8, "k")]
    private static let wobble: Cells = [(3, 9, "k"), (4, 8, "k"), (5, 9, "k"), (6, 8, "k"), (7, 9, "k"), (8, 8, "k")]

    // MARK: Frames

    /// How long a face moves its mouth when something happens (it starts to need you, it just finished, it just stopped): a couple of
    /// seconds, then it is still
    static let burstSeconds: Double = 2.5

    // MARK: Every agent its own face, drawn at random

    /// A face is three features: what it wears on its head, that thing's colour, and its skin. 6 × 8 × 8 = 384 faces.
    static let styleCount = 6, colourCount = 8, skinCount = 8
    static let variantCount = styleCount * colourCount * skinCount
    /// The colours a head can wear (palette letters): brown, black, blond, red, blue, green, purple, magenta.
    static let colours: [Character] = ["m", "k", "Y", "R", "B", "G", "P", "M"]

    private static func norm(_ v: Int) -> Int { ((v % variantCount) + variantCount) % variantCount }
    /// Nothing, hair, a cap, a beanie, headphones, a bow.
    static func style(_ v: Int) -> Int { norm(v) % styleCount }
    static func colour(_ v: Int) -> Int { (norm(v) / styleCount) % colourCount }
    static func skin(_ v: Int) -> Int { (norm(v) / (styleCount * colourCount)) % skinCount }
    static func variant(style: Int, colour: Int, skin: Int) -> Int {
        (((style % styleCount) + styleCount) % styleCount) + styleCount * (((colour % colourCount) + colourCount) % colourCount)
            + styleCount * colourCount * (((skin % skinCount) + skinCount) % skinCount)
    }

    /// How many features two faces do not share (0 to 3; a bare head's colour does not count).
    static func difference(_ a: Int, _ b: Int) -> Int {
        let colourMatters = style(a) != 0 || style(b) != 0
        return (style(a) != style(b) ? 1 : 0) + (colourMatters && colour(a) != colour(b) ? 1 : 0) + (skin(a) != skin(b) ? 1 : 0)
    }

    /// The face each agent wears, the same everywhere (the wing, the header, the den, the TV). A new agent draws a random face, as unlike
    /// the faces already shown as it can be, and keeps it for as long as it lives (`AgentFaceBook`).
    static func variants(for ids: [String]) -> [String: Int] {
        var out: [String: Int] = [:]
        let unique = Array(Set(ids)).sorted()
        for id in unique { if let v = AgentFaceBook.known(id) { out[id] = v } }
        for id in unique where out[id] == nil { out[id] = AgentFaceBook.draw(id, unlike: Array(out.values)) }
        return out
    }

    /// Where an agent's animation starts: a random moment of its own (fixed for the agent, so it never jumps), anywhere in the faces' longest
    /// cycle (glances every 8 steps, blinks every 17th), so no two agents glance or blink in turn
    static func phase(for id: String) -> Double { Double(stableHash(id + ".phase") % 1088) / 10 }

    /// FNV-1a: the same number for the same text in every run (Swift's own hash changes from run to run).
    static func stableHash(_ text: String) -> Int {
        var h: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 { h = (h ^ UInt64(byte)) &* 1_099_511_628_211 }
        return Int(h % 1_000_003)
    }

    /// How much lighter (+) or darker (-) a face's skin is than its kind's colour.
    static func shade(_ variant: Int) -> Double { [0, 0.20, -0.16, 0.34, -0.26, 0.10, -0.08, 0.27][skin(variant)] }

    /// What a face wears, in its colour: nothing, hair, a cap (a white button), a beanie (a white band), headphones (a dark band), a bow.
    static func accessory(_ variant: Int) -> Cells {
        let c = colours[colour(variant)]
        func hair(_ c: Character) -> Cells {
            (2...9).map { ($0, 0, c) } + (1...10).map { ($0, 1, c) } + [(0, 2, c), (1, 2, c), (2, 2, c), (9, 2, c), (10, 2, c), (11, 2, c)]
        }
        switch style(variant) {
        case 1: return hair(c)
        case 2: return (2...9).map { ($0, 0, c) } + (1...10).map { ($0, 1, c) } + (6...11).map { ($0, 2, c) } + [(4, 0, "w")]
        case 3: return (2...9).map { ($0, 0, c) } + (1...10).map { ($0, 1, c) } + (1...10).map { ($0, 2, "w") }
        case 4: return (3...8).map { ($0, 0, "d") } + [(2, 1, "d"), (9, 1, "d")] + (4...6).flatMap { y in [(0, y, c), (1, y, c), (10, y, c), (11, y, c)] }
        case 5: return [(7, 0, c), (8, 0, c), (9, 0, "w"), (10, 0, c), (11, 0, c), (7, 1, c), (8, 1, c), (10, 1, c), (11, 1, c)]
        default: return []
        }
    }

    /// The face at step `tick`; `burst` is true during the couple of seconds after something happened.
    /// - working: the mouth stays still; the eyes glance now and then (a step every 8) and blink (every 17th).
    /// - asking: wide eyes and an amber ring; during the burst the mouth calls (an "o" and an open one) and the ring swaps to orange,
    ///   then it waits with a still "o".
    /// - finished: happy arches; a short laugh during the burst, then a still smile.
    /// - stopped: a wobbly mouth; the dizzy crosses swap during the burst, then stay crosses.
    /// - idle: eyes shut, a tiny mouth.
    static func frame(_ mood: AgentFaceMood, tick: Int, burst: Bool = false, variant: Int = 0) -> PixelSprite {
        let face = bareFrame(mood, tick: tick, burst: burst)
        let extra = accessory(variant)
        return extra.isEmpty ? face : face.patched(extra)
    }

    /// The head of a BIG figure (the agent at its desk in the den and in the TV's rooms) is THIS face: the same 12 x 12 cells, the same outline,
    /// highlight and cheeks, the same eyes and mouths, and the same headwear of `variant`.
    /// With a `tick` (the clock's step, `AgentFaceArt.tick`: the same beat and the same rules as the
    /// wing's faces) it IS the wing's frame of that step, `burst` for the couple of seconds after something happened: a working head glances and
    /// blinks, an asking one calls, a finished one laughs, a stopped one's crosses swap. Without a tick (a still picture) it is the face at rest:
    /// a working head looks to the right, at its computer; `eyesShut` is the blink of a working or an asking head.
    static func figureHead(_ look: AgentNookLook, tick: Int? = nil, burst: Bool = false, eyesShut: Bool = false, variant: Int = 0) -> PixelSprite {
        let mood = AgentFaceMood(look)
        if let tick { return frame(mood, tick: tick, burst: burst, variant: variant) }
        if eyesShut, look == .working || look == .needsYou {
            let face = look == .working ? base.patched(blink + small) : base.patched(blink + oh).mapped(["o": "A"])
            let extra = accessory(variant)
            return extra.isEmpty ? face : face.patched(extra)
        }
        return frame(mood, tick: look == .working ? restTick : 0, burst: false, variant: variant)
    }

    /// The step a working head rests on: looking to the right (the glance of step 8), not blinking.
    static let restTick = 8

    private static func bareFrame(_ mood: AgentFaceMood, tick: Int, burst: Bool) -> PixelSprite {
        let t = max(0, tick)
        switch mood {
        case .working:
            let glance = [0, 1, 0, -1][(t / 8) % 4]
            return base.patched((t % 17 == 0 ? blink : looking(glance)) + small)
        case .asking:
            guard burst else { return base.patched(wide + oh).mapped(["o": "A"]) }
            let calling = (t / 2) % 2 == 0
            return base.patched(wide + (calling ? oh : open)).mapped(["o": calling ? "A" : "O"])
        case .finished:
            guard burst else { return base.patched(happy + smile) }
            return base.patched(happy + ((t / 2) % 2 == 0 ? open : smile))
        case .stopped:
            return base.patched(dizzy[burst ? (t / 2) % 2 : 0] + wobble)
        case .idle:
            return base.patched(shut + small)
        }
    }

    /// The colours of `agent`'s face in `variant` (its skin a little lighter or darker; a sleeping one dimmer).
    static func palette(_ agent: AgentKind, _ mood: AgentFaceMood, variant: Int = 0) -> PixelPalette {
        let p = PixelPalette.face(agent, variant: variant)
        return mood == .idle ? p.dimmed(0.3) : p
    }
}

/// The face as a view: an 18 pt square. A working face only moves its eyes (a step every 0.2 s, 0.4 s with Reduce Motion); the others move
/// for `AgentFaceArt.burstSeconds` after their mood begins (the face appears or changes) and are then still pictures, so nothing ticks.
/// `frozenAt` draws one still moment (pictures and tests), `frozenBurst` says whether that moment is inside the burst.
/// It only exists in the closed notch's wing, so nothing runs while the notch is open.
struct AgentFaceIcon: View {
    var agent: AgentKind
    var mood: AgentFaceMood
    /// Keeps faces next to each other from blinking in step.
    var phase: Double = 0
    /// One still moment (seconds); nil = alive.
    var frozenAt: Double?
    var frozenBurst = false
    /// Which of the faces this agent wears (`AgentFaceArt.variants`).
    var variant = 0
    var px: CGFloat = AgentFaceArt.px
    /// True for the couple of seconds after the mood began.
    @State private var burst = true

    var body: some View {
        let calm = ScoutRuntime.reduceMotion
        Group {
            if let frozenAt {
                canvas(tick: AgentFaceArt.tick(at: frozenAt, phase: phase, calm: calm), burst: frozenBurst)
            } else if mood == .working || (burst && mood != .idle) {
                // Sampled twice a step. (A `.periodic(from:)` schedule that starts in 2001 would count its way up to today: seconds of CPU.)
                TimelineView(.animation(minimumInterval: AgentFaceArt.beat(calm: calm) / 2)) { ctx in
                    canvas(tick: AgentFaceArt.tick(at: ctx.date.timeIntervalSinceReferenceDate, phase: phase, calm: calm), burst: burst)
                }
            } else {
                canvas(tick: 0, burst: false)
            }
        }
        .frame(width: CGFloat(AgentFaceArt.cells) * px, height: CGFloat(AgentFaceArt.cells) * px)
        .task(id: mood) {
            burst = true
            try? await Task.sleep(nanoseconds: UInt64(AgentFaceArt.burstSeconds * 1_000_000_000))
            if !Task.isCancelled { burst = false }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: agent.title))
    }

    private func canvas(tick: Int, burst: Bool) -> some View {
        let sprite = AgentFaceArt.frame(mood, tick: tick, burst: burst, variant: variant)
        let palette = AgentFaceArt.palette(agent, mood, variant: variant)
        return Canvas { ctx, _ in
            var c = ctx
            AgentPixel.draw(sprite, in: &c, at: .zero, px: px, palette: palette)
        }
    }
}

extension PixelPalette {
    /// The kind's palette with the skin of `variant` (lighter or darker), cached: the faces and the den's agents draw with it.
    static func face(_ kind: AgentKind, variant: Int) -> PixelPalette {
        let key = "\(kind.rawValue)-\(AgentFaceArt.skin(variant))"   // the palette only follows the skin
        if let cached = faceCache[key] { return cached }
        var p = PixelPalette.world(kind)
        let skin = Retro.shade(kind.tint, AgentFaceArt.shade(variant))
        p.colors["b"] = skin
        p.colors["o"] = Retro.shade(skin, -0.78)
        p.colors["s"] = Retro.shade(skin, -0.26)
        p.colors["h"] = Retro.shade(skin, 0.30)
        faceCache[key] = p
        return p
    }

    private static var faceCache: [String: PixelPalette] = [:]   // drawn on the main thread only
}

// MARK: - Pictures

/// Gallery: the faces on a sheet (every mood, the steps of its life, both kinds) and the closed notch's wings with them.
@MainActor
enum AgentFaceGallery {
    static func register() {
        Gallery.register("agents-face-sheet", size: CGSize(width: 1120, height: 560)) {
            let beat = AgentFaceArt.beat(calm: ScoutRuntime.reduceMotion)
            let burst = [0, 2, 4, 6], still = [0, 8, 16, 17]
            VStack(alignment: .leading, spacing: 10) {
                ForEach(AgentFaceMood.allCases, id: \.self) { mood in
                    HStack(spacing: 10) {
                        Text(verbatim: "\(String(describing: mood))").font(.system(size: 13, weight: .semibold, design: .monospaced)).frame(width: 80, alignment: .leading)
                        ForEach(burst, id: \.self) { step in
                            AgentFaceIcon(agent: .claude, mood: mood, frozenAt: Double(step) * beat + 0.01, frozenBurst: true, px: 6)
                        }
                        Color.clear.frame(width: 14)
                        ForEach(still, id: \.self) { step in
                            AgentFaceIcon(agent: .codex, mood: mood, frozenAt: Double(step) * beat + 0.01, frozenBurst: false, px: 6)
                        }
                    }
                }
                Text(verbatim: "left: the couple of seconds after something happens (steps 0 2 4 6, Claude Code); right: afterwards (steps 0 8 16 17, Codex)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.colorScheme, .dark)
            .background(Color(red: 0.07, green: 0.07, blue: 0.09))
        }
    }
}

/// The faces agents were given: drawn at random the first time an agent shows, then kept, also across a restart of Scout (the last 80).
/// Pictures and tests draw the same "random" face for the same id every run and keep nothing.
enum AgentFaceBook {
    private static let key = "agents.faces"
    private static var book: [String: Int] = load()
    private static var order: [String] = []

    static func known(_ id: String) -> Int? { book[id] }

    /// A random face for a new agent, as unlike `taken` as it can find (all three features different when there is one).
    static func draw(_ id: String, unlike taken: [Int]) -> Int {
        var rng = SplitMix64(seed: ScoutRuntime.isScripted ? UInt64(AgentFaceArt.stableHash(id)) : UInt64.random(in: 1...UInt64.max))
        var best = 0, bestScore = -1
        for _ in 0..<48 {
            let v = Int(rng.next() % UInt64(AgentFaceArt.variantCount))
            let score = taken.map { AgentFaceArt.difference(v, $0) }.min() ?? 3
            if score > bestScore { best = v; bestScore = score }
            if score == 3 { break }
        }
        book[id] = best
        order.append(id)
        save()
        return best
    }

    private static func load() -> [String: Int] {
        guard !ScoutRuntime.isScripted, let list = UserDefaults.standard.array(forKey: key) as? [String] else { return [:] }
        var out: [String: Int] = [:]
        for entry in list {
            let parts = entry.split(separator: "=", maxSplits: 1)
            if parts.count == 2, let v = Int(parts[1]) { out[String(parts[0])] = v; order.append(String(parts[0])) }
        }
        return out
    }

    private static func save() {
        guard !ScoutRuntime.isScripted else { return }
        if order.count > 80 { for id in order.prefix(order.count - 80) { book[id] = nil }; order = Array(order.suffix(80)) }
        UserDefaults.standard.set(order.compactMap { id in book[id].map { "\(id)=\($0)" } }, forKey: key)
    }
}

/// A small, fast random number generator that can be seeded (SplitMix64).
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
