import AppKit

/// `scout://island.selftest.geometry?out=<file>` (headless): how each display's cutout is found from what the system reports (the table of cases).
/// Every row builds the facts of a display by hand (`DisplayFacts`: nothing is read from this Mac) and checks the kind and the numbers
/// `NotchGeometry.make(facts:…)` gives, and where it matters the notes the report prints. The 16 and 14 inch numbers are made up to fit the stated
/// sizes (a screen 1,728 or 1,512 pt wide with a 185 pt housing): the real ones of the new Mac are exactly what the display report will collect.
@MainActor
enum IslandGeometrySelfTest {
    static func register() {
        SuiteCheck.register("island.selftest.geometry", suite: "island geometry") { check in
            rows(check)
            samples(check)
            constants(check)
        }
    }

    // MARK: Building a display

    /// A display `width` by `height` pt. `housing` makes both areas beside the housing (so the housing between them is that wide); `safe` is the
    /// hidden top; `bar` the menu bar height the frames show (0 = hidden).
    private static func display(_ width: CGFloat, _ height: CGFloat, safe: CGFloat = 0, housing: CGFloat? = nil, bar: CGFloat = 0, thickness: CGFloat = 24,
                                builtIn: Bool = true, model: String? = nil, touch: Bool = false) -> DisplayFacts {
        var f = DisplayFacts(frame: CGRect(x: 0, y: 0, width: width, height: height))
        f.visibleFrame = CGRect(x: 0, y: 0, width: width, height: height - bar)
        f.safeInsets = DisplayInsets(top: safe)
        if let housing {
            let aux = (width - housing) / 2
            let tall = max(safe, 32)
            f.auxLeft = CGRect(x: 0, y: height - tall, width: aux, height: tall)
            f.auxRight = CGRect(x: width - aux, y: height - tall, width: aux, height: tall)
        }
        f.menuBar = bar
        f.barThickness = thickness
        f.isBuiltIn = builtIn
        f.modelID = model
        f.isTouch = touch
        f.pixelSize = CGSize(width: width * 2, height: height * 2)
        return f
    }

    /// What a row expects: the kind, and any of the numbers (nil = not checked).
    private struct Want {
        var kind: CutoutKind
        var width: CGFloat?
        var height: CGFloat?
        var inset: CGFloat?
        var strip: CGFloat?
        var shape: NoneShape?
        var touch: Bool?
        var note: String?
        var noNote: String?
        init(_ kind: CutoutKind, _ width: CGFloat? = nil, _ height: CGFloat? = nil, inset: CGFloat? = nil, strip: CGFloat? = nil, shape: NoneShape? = nil,
             touch: Bool? = nil, note: String? = nil, noNote: String? = nil) {
            self.kind = kind; self.width = width; self.height = height; self.inset = inset; self.strip = strip
            self.shape = shape; self.touch = touch; self.note = note; self.noNote = noNote
        }
    }

    private static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }

    private static func verify(_ check: SuiteCheck, _ name: String, _ facts: DisplayFacts, override: CutoutOverride = .automatic, shape: NoneShape = .tab,
                               style: AgentWingStyle = .faces, _ want: Want) {
        let decision = NotchGeometry.make(facts: facts, override: override, noneShape: shape, agentStyle: style)
        let g = decision.geometry
        var problems: [String] = []
        if g.kind != want.kind { problems.append("kind \(g.kind), wanted \(want.kind)") }
        if let w = want.width, !near(g.size.width, w) { problems.append("width \(g.size.width), wanted \(w)") }
        if let h = want.height, !near(g.size.height, h) { problems.append("height \(g.size.height), wanted \(h)") }
        if let i = want.inset, !near(g.topInset, i) { problems.append("inset \(g.topInset), wanted \(i)") }
        if let s = want.strip, !near(g.stripHeight, s) { problems.append("strip \(g.stripHeight), wanted \(s)") }
        if let s = want.shape, g.noneShape != s { problems.append("shape \(g.noneShape), wanted \(s)") }
        if let t = want.touch, g.isTouch != t { problems.append("touch \(g.isTouch), wanted \(t)") }
        if let n = want.note, !decision.notes.contains(where: { $0.contains(n) }) { problems.append("no note with \"\(n)\" in \(decision.notes)") }
        if let n = want.noNote, decision.notes.contains(where: { $0.contains(n) }) { problems.append("a note with \"\(n)\" in \(decision.notes)") }
        check(name, problems.isEmpty, problems.joined(separator: "; "))
    }

    // MARK: The table

    private static func rows(_ check: SuiteCheck) {
        let classic16 = display(1728, 1117, safe: 32, housing: 185, model: "MacBookPro18,2")
        // The classic notch, as before.
        verify(check, "classic 16 inch: a notch 185 by 32, flush, as sample16", classic16, Want(.notch, 185, 32, inset: 0, strip: 32, touch: false))
        check("classic 16 inch is exactly the old sample16", NotchGeometry.make(facts: classic16).geometry == .sample16)
        verify(check, "classic 16 inch with the real menu bar (37 pt): the same notch, the strip stays the housing's floor (32), whatever the bar says",
               display(1728, 1117, safe: 32, housing: 185, bar: 37, model: "MacBookPro18,2"), Want(.notch, 185, 32, inset: 0, strip: 32))
        // The geometry detected on a real classic Mac is the sample, under any realistic bar, so the pictures made on the samples match the owner's screen.
        for bar in [CGFloat(0), 24, 37, 38, 44] {
            let real = display(1728, 1117, safe: 32, housing: 185, bar: bar, model: "MacBookPro18,2")
            check("classic 16 inch under a \(bar) pt bar equals sample16 (every field, the strip included)", NotchGeometry.make(facts: real).geometry == .sample16)
            check("classic 16 inch under a \(bar) pt bar with round bubbles equals sampleNotchBubbles", NotchGeometry.make(facts: real, agentStyle: .bubbles).geometry == .sampleNotchBubbles)
        }
        verify(check, "classic 14 inch: a notch 185 by 32", display(1512, 982, safe: 32, housing: 185, model: "MacBookPro18,3"), Want(.notch, 185, 32, inset: 0))
        verify(check, "classic at a scaled width (1800 pt, housing 220): the measured width", display(1800, 1169, safe: 32, housing: 220), Want(.notch, 220, 32))
        verify(check, "classic at a smaller scaled width (1352 pt, housing 165): the measured width", display(1352, 878, safe: 32, housing: 165), Want(.notch, 165, 32))
        verify(check, "a housing over 420 pt is not believed: the notch is 185 wide, as tall as the inset", display(2056, 1329, safe: 34, housing: 450),
               Want(.notch, 185, 34, note: "over 420"))
        verify(check, "a classic notch with a taller inset (38): measured width, as tall as the inset", display(1728, 1117, safe: 38, housing: 185), Want(.notch, 185, 38))

        // The pill from the areas beside it.
        let pill16 = display(1736, 1117, safe: 48, housing: 59, bar: 48, model: "Mac17,10", touch: true)
        verify(check, "pill from the areas, with an inset: 58 by 31 at 8.5 pt, strip 48", pill16, Want(.pill, 58, 31, inset: 8.5, strip: 48, touch: true))
        check("the 16 inch pill detected is exactly the sample samplePill16", NotchGeometry.make(facts: pill16).geometry == .samplePill16)
        verify(check, "pill from the areas, inset zero: the same pill", display(1736, 1117, safe: 0, housing: 59, bar: 48), Want(.pill, 58, 31, inset: 8.5, strip: 48))
        verify(check, "pill at a scaled width, k inside its range (housing 50 pt: k 0.847)", display(1470, 960, safe: 0, housing: 50),
               Want(.pill, 58 * 50 / 59, 31 * 50 / 59, inset: 8.5 * 50 / 59, note: "k = 0.847"))
        verify(check, "pill at a scaled width, k inside its range (housing 75 pt: k 1.271)", display(2200, 1400, safe: 0, housing: 75),
               Want(.pill, 58 * 75 / 59, 31 * 75 / 59, inset: 8.5 * 75 / 59, note: "k = 1.271"))
        verify(check, "pill at a scaled width, k above its range (housing 90 pt): k is 1", display(2640, 1650, safe: 0, housing: 90),
               Want(.pill, 58, 31, inset: 8.5, note: "so k = 1"))
        verify(check, "pill at a scaled width, k below its range (housing 40 pt): k is 1", display(1200, 780, safe: 0, housing: 40),
               Want(.pill, 58, 31, inset: 8.5, note: "so k = 1"))

        // The model list and touch.
        verify(check, "a pill by model id only (Mac17,10), no areas, an inset", display(1736, 1117, safe: 48, bar: 48, model: "Mac17,10"), Want(.pill, 58, 31, inset: 8.5, strip: 48))
        verify(check, "a listed model with inset zero and no areas: still a pill", display(1512, 982, safe: 0, model: "Mac17,11"), Want(.pill, 58, 31, inset: 8.5, strip: 48))
        verify(check, "the 14 inch model Mac17,13 is a pill", display(1512, 982, safe: 0, model: "Mac17,13"), Want(.pill, 58, 31))
        verify(check, "the 16 inch model Mac17,12 is a pill", display(1728, 1117, safe: 0, model: "Mac17,12"), Want(.pill, 58, 31))
        verify(check, "a listed model id on an external display: no cutout", display(2560, 1440, builtIn: false, model: "Mac17,10"), Want(.none))
        verify(check, "a touch display not on the list (Mac99,1): a pill", display(1736, 1117, safe: 0, housing: 59, model: "Mac99,1", touch: true), Want(.pill, 58, 31, note: "takes touches"))
        verify(check, "a touch display not on the list, no areas, inset zero: a pill", display(1736, 1117, safe: 0, model: "Mac99,1", touch: true), Want(.pill, 58, 31, inset: 8.5))
        verify(check, "a touch display that is not built in: no cutout, never a pill", display(1920, 1080, builtIn: false, touch: true), Want(.none, touch: true))

        // Unknown models.
        verify(check, "an unknown model with inset zero and no areas: no cutout", display(1440, 900, model: "MacBookAir10,1"), Want(.none, shape: .tab))
        verify(check, "an unreadable model id with inset zero: no cutout", display(1440, 900, model: nil), Want(.none))
        verify(check, "an unknown model with an inset (32) and no areas: a notch 185 by 32", display(1728, 1117, safe: 32, model: "Mac99,2"), Want(.notch, 185, 32))
        verify(check, "an unknown model with an inset (38) and no areas: a notch 185 by 38", display(1728, 1117, safe: 38, model: nil), Want(.notch, 185, 38))
        verify(check, "an unknown model whose areas leave a pill-sized housing: a pill", display(1736, 1117, safe: 0, housing: 59, model: "Mac99,3"), Want(.pill, 58, 31, note: "of the width"))
        verify(check, "areas that overlap (no housing width): read as no areas, the inset rule", display(1000, 700, safe: 32, housing: -20), Want(.notch, 185, 32))

        // External displays.
        verify(check, "an external display without a cutout: the drawn tab, 190 by 32, flush", display(2560, 1440, builtIn: false), Want(.none, 190, 32, inset: 0, shape: .tab))
        verify(check, "an external display under the override Pill: no cutout, never a pill", display(2560, 1440, builtIn: false), override: .pill,
               Want(.none, note: "not built in"))
        verify(check, "an external display under the override Notch: no cutout", display(2560, 1440, builtIn: false), override: .notch, Want(.none))
        verify(check, "an external display with a pill-sized housing: a notch, never a pill", display(2560, 1440, safe: 30, housing: 80, builtIn: false), Want(.notch, 80, 30))

        // The override on matching and mismatched hardware.
        verify(check, "override Pill on a pill Mac with areas: the measured pill", display(1736, 1117, safe: 0, housing: 59, model: "Mac17,10"), override: .pill,
               Want(.pill, 58, 31, note: "fits a pill"))
        verify(check, "override Notch on a classic notch with areas: the measured notch", classic16, override: .notch, Want(.notch, 185, 32, note: "fits a notch"))
        verify(check, "override None on a classic notch: no cutout", classic16, override: .none, Want(.none, shape: .tab))
        verify(check, "override Pill on a notch Mac with areas: the default pill, under the physical notch", classic16, override: .pill,
               Want(.pill, 58, 31, inset: 8.5, strip: 48, note: "default pill"))
        verify(check, "override Pill on a notch Mac without areas (inset 32): the default pill", display(1728, 1117, safe: 32), override: .pill, Want(.pill, 58, 31, inset: 8.5))
        verify(check, "override Notch on a pill Mac with areas: the default notch 185 by 32", display(1736, 1117, safe: 0, housing: 59, model: "Mac17,10"), override: .notch,
               Want(.notch, 185, 32, note: "default notch"))
        verify(check, "override Notch on a pill Mac without areas, inset zero: the default notch", display(1736, 1117, safe: 0, model: "Mac17,10"), override: .notch, Want(.notch, 185, 32))
        verify(check, "override Notch on a pill Mac without areas, inset 8.5: still 185 by 32 (the default, not the inset)", display(1736, 1117, safe: 8.5, model: "Mac17,10"),
               override: .notch, Want(.notch, 185, 32))
        verify(check, "override None on a pill Mac: no cutout", display(1736, 1117, safe: 0, housing: 59, model: "Mac17,10"), override: .none, Want(.none))
        // The same without areas beside the housing (a Mac that reports only an inset, or nothing).
        verify(check, "override Pill on a pill Mac without areas (inset 48): the default pill, nothing measured", display(1736, 1117, safe: 48, bar: 48, model: "Mac17,10"),
               override: .pill, Want(.pill, 58, 31, inset: 8.5, strip: 48, note: "default pill"))
        verify(check, "override Pill on a pill Mac without areas, inset zero: the default pill", display(1736, 1117, safe: 0, model: "Mac17,10"), override: .pill,
               Want(.pill, 58, 31, inset: 8.5, strip: 48))
        verify(check, "override Notch on a classic notch without areas (inset 32): the default notch 185 by 32, flush", display(1728, 1117, safe: 32, model: "MacBookPro18,2"),
               override: .notch, Want(.notch, 185, 32, inset: 0, strip: 32, note: "default notch"))
        verify(check, "override Notch on a classic notch without areas, inset 38: 185 by 32, not 185 by 38 (the default, not the inset)",
               display(1728, 1117, safe: 38, model: "MacBookPro18,2"), override: .notch, Want(.notch, 185, 32))
        verify(check, "override None on a classic notch without areas (inset 32): no cutout, the tab", display(1728, 1117, safe: 32, model: "MacBookPro18,2"), override: .none,
               Want(.none, 190, 32, inset: 0, shape: .tab))
        verify(check, "override None on a pill Mac without areas: no cutout", display(1736, 1117, safe: 48, bar: 48, model: "Mac17,10"), override: .none, Want(.none))
        verify(check, "override Pill with nothing reported (inset zero, no areas, unknown model): the default pill", display(1440, 900), override: .pill, Want(.pill, 58, 31, inset: 8.5))

        // Contradictions.
        verify(check, "a listed model whose areas read like a classic notch: a pill, the notes say CONTRADICTION",
               display(1728, 1117, safe: 32, housing: 185, model: "Mac17,10"), Want(.pill, 58, 31, inset: 8.5, note: "CONTRADICTION"))
        verify(check, "a touch display whose areas read like a classic notch: a NOTCH (what the display measures wins over the touch flag), the notes say CONTRADICTION",
               display(1728, 1117, safe: 32, housing: 185, model: "Mac99,1", touch: true), Want(.notch, 185, 32, inset: 0, note: "CONTRADICTION"))
        verify(check, "this very Mac if it ever said it takes touches (Mac16,7, areas 771.5 each): still its notch, 185 by 32",
               display(1728, 1117, safe: 32, housing: 185, bar: 33, model: "Mac16,7", touch: true), Want(.notch, 185, 32, inset: 0, strip: 32, note: "CONTRADICTION"))
        verify(check, "a consistent listed pill has no CONTRADICTION", pill16, Want(.pill, noNote: "CONTRADICTION"))

        // The drawn island.
        verify(check, "the drawn island in a 22 pt bar: 61.2 by 18 at 2 pt", display(1920, 1080, bar: 22, thickness: 22, builtIn: false), shape: .island,
               Want(.none, 61.2, 18, inset: 2, strip: 22, shape: .island))
        let bar24 = display(1920, 1080, bar: 24, builtIn: false)
        verify(check, "the drawn island in a 24 pt bar: 68 by 20 at 2 pt", bar24, shape: .island, Want(.none, 68, 20, inset: 2, strip: 24, shape: .island))
        check("the drawn island of a 24 pt bar is exactly sampleNone", NotchGeometry.make(facts: bar24, noneShape: .island).geometry == .sampleNone)
        verify(check, "the drawn island in a 37 pt bar: 108.8 by 32 at 2.5 pt", display(1920, 1080, bar: 37, builtIn: false), shape: .island, Want(.none, 108.8, 32, inset: 2.5, strip: 37))
        verify(check, "the drawn island with a hidden bar: the status bar's thickness (24) decides", display(1920, 1080, bar: 0, thickness: 24, builtIn: false), shape: .island,
               Want(.none, 68, 20, inset: 2, strip: 24))
        verify(check, "the drawn island with no bar and no thickness: the fallback bar of 24", display(1920, 1080, bar: 0, thickness: 0, builtIn: false), shape: .island, Want(.none, 68, 20, inset: 2))
        verify(check, "the drawn island in a 80 pt bar is never taller than 32", display(1920, 1080, bar: 80, builtIn: false), shape: .island, Want(.none, 108.8, 32, inset: 24))
        verify(check, "the drawn island in a 12 pt bar is never lower than 18 and never above the edge", display(1920, 1080, bar: 12, thickness: 0, builtIn: false), shape: .island,
               Want(.none, 61.2, 18, inset: 0))
        verify(check, "the drawn island on a built-in display without a cutout (an older MacBook)", display(1440, 900, bar: 24, model: "MacBookAir10,1"), shape: .island,
               Want(.none, 68, 20, shape: .island))

        // The tab, as before.
        let external = display(2560, 1440, builtIn: false)
        check("an unset notch.shape (the default) gives the tab exactly as before: equal to the old two-argument geometry",
              NotchGeometry.make(facts: external).geometry == NotchGeometry(size: NotchGeometry.virtualSize, isHardware: false))
        check("the old two-argument geometry without hardware is still the tab: no cutout, 190 by 32, flush, equal to sampleNoneTab",
              NotchGeometry(size: NotchGeometry.virtualSize, isHardware: false) == .sampleNoneTab && NotchGeometry.sampleNoneTab.kind == .none
              && NotchGeometry.sampleNoneTab.noneShape == .tab && NotchGeometry.sampleNoneTab.topInset == 0)
        verify(check, "the shape Nothing: no cutout, the shape is kept", external, shape: .nothing, Want(.none, shape: .nothing))

        // Agent style.
        check("round bubbles on a classic notch give exactly sampleNotchBubbles", NotchGeometry.make(facts: classic16, agentStyle: .bubbles).geometry == .sampleNotchBubbles)
        verify(check, "the agent style does not travel to a pill or to a display without a cutout",
               display(1736, 1117, safe: 0, housing: 59), style: .bubbles, Want(.pill))
        check("the agent style on a pill or a drawn island stays faces (it matters for a notch only)",
              NotchGeometry.make(facts: pill16, agentStyle: .bubbles).geometry.agentStyle == .faces
              && NotchGeometry.make(facts: bar24, noneShape: .island, agentStyle: .bubbles).geometry.agentStyle == .faces)

        // The strip.
        verify(check, "a pill with a hidden bar: the strip falls back to 48", display(1736, 1117, safe: 0, housing: 59, bar: 0), Want(.pill, strip: 48))
        verify(check, "a pill with a 52 pt bar: the strip is the bar", display(1736, 1117, safe: 0, housing: 59, bar: 52), Want(.pill, strip: 52))
        verify(check, "a pill with a 30 pt bar (under the housing's floor of 39.5): the strip is the floor, so the pill never sits below its strip",
               display(1736, 1117, safe: 0, housing: 59, bar: 30), Want(.pill, 58, 31, inset: 8.5, strip: 39.5))
        verify(check, "a pill with a bar exactly at the floor (39.5): the strip is the bar", display(1736, 1117, safe: 0, housing: 59, bar: 39.5), Want(.pill, strip: 39.5))
    }

    // MARK: The samples are what the detection gives

    private static func samples(_ check: SuiteCheck) {
        let s = NotchGeometry.sample16
        check("sample16 is unchanged: a hardware notch, 185 by 32, flush, faces, strip 32, no touch",
              s.kind == .notch && s.isHardware && s.size == CGSize(width: 185, height: 32) && s.topInset == 0 && s.agentStyle == .faces && s.stripHeight == 32 && !s.isTouch)
        check("a notch is a hardware kind, a pill too, and a pill with inset zero counts: the screen's hardware notch goes through the geometry",
              NotchGeometry.make(facts: display(1728, 1117, safe: 32, housing: 185)).geometry.isHardware
              && NotchGeometry.make(facts: display(1512, 982, safe: 0, model: "Mac17,11")).geometry.isHardware
              && !NotchGeometry.make(facts: display(1920, 1080, builtIn: false)).geometry.isHardware)
    }

    // MARK: The constants

    private static func constants(_ check: SuiteCheck) {
        let n = CutoutNumbers.self
        check("the hardware numbers: the pill 58 by 31 at 8.5, the slot 59, the notch 185 by 32, the 420 limit, the strip 48",
              n.pillSize == CGSize(width: 58, height: 31) && n.pillTopInset == 8.5 && n.pillSlotWidth == 59 && n.notchDefaultSize == CGSize(width: 185, height: 32)
              && n.notchWidthLimit == 420 && n.pillStripFallback == 48)
        check("the scale k is believed only between 0.75 and 1.35 times 59 pt", abs(n.scaleRange.lowerBound - 44.25) < 0.001 && abs(n.scaleRange.upperBound - 79.65) < 0.001)
        check("the models on the list are Mac17,10 to Mac17,13 and nothing else", n.pillModels == ["Mac17,10", "Mac17,11", "Mac17,12", "Mac17,13"])
        check("the share limit between pill and notch is 0.07 (pill 0.034, notches 0.107 and 0.122 on either side)",
              n.pillShareLimit == 0.07 && 59.0 / 1736 < n.pillShareLimit && 185.0 / 1728 > n.pillShareLimit && 185.0 / 1512 > n.pillShareLimit)
    }
}
