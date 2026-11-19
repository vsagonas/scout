import AppKit
import SwiftUI

/// `scout://retro.selftest?out=<file>` (headless runs): the 90s kit. It runs as its own build, offscreen:
///   build/Scout.app/Contents/MacOS/Scout --automation --headless --run "scout://retro.selftest?out=<file>" & PID=$!
/// then wait for the file and `kill $PID`. Nothing is shown, nothing is written outside `out`.
@MainActor
enum RetroSelfTest {
    static func register() {
        DebugCommands.register("retro.selftest") { params in
            guard ScoutRuntime.isAutomation else { return }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("retro-selftest.txt")
            Task { @MainActor in run(out: out) }
        }
    }

    @MainActor private final class Checker {
        var lines: [String] = []
        var failed = 0

        func callAsFunction(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failed += 1 }
            lines.append("retro selftest \(ok ? "ok  " : "FAIL") \(name)\(ok || detail.isEmpty ? "" : "  (\(detail))")")
        }
    }

    static func run(out: URL) {
        let check = Checker()
        paletteChecks(check)
        segmentChecks(check)
        pixelChecks(check)
        ledBarChecks(check)
        bevelChecks(check)
        layoutChecks(check)
        renderChecks(check)
        styleChecks(check)
        check.lines.append("retro selftest done: \(check.failed == 0 ? "all passed" : "\(check.failed) FAILED")")
        for line in check.lines { print(line) }
        fflush(stdout)
        try? check.lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
    }

    // MARK: Palette

    private static func paletteChecks(_ check: Checker) {
        typealias I = Retro.Ink
        let all: [Color] = [I.teal, I.magenta, I.purple, I.yellow, I.lime, I.orange, I.red, I.plastic, I.plasticMid, I.plasticDark,
                            I.screenBlack, I.phosphorGreen, I.phosphorAmber, I.osdWhite, I.ledGreen, I.ledYellow, I.ledRed]
        check("the palette has 17 colours, all opaque", all.count == 17 && all.allSatisfy { Retro.rgb($0).a > 0.999 })
        check("the plastics go from light to dark (beige, grey, charcoal)", Retro.luminance(I.plastic) > Retro.luminance(I.plasticMid) && Retro.luminance(I.plasticMid) > Retro.luminance(I.plasticDark))
        check("the screen is nearly black, the phosphors and the OSD are bright", Retro.luminance(I.screenBlack) < 0.05 && Retro.luminance(I.phosphorGreen) > 0.6 && Retro.luminance(I.osdWhite) > 0.85)
        let leds = [Retro.rgb(I.ledGreen), Retro.rgb(I.ledYellow), Retro.rgb(I.ledRed)]
        check("the LEDs are green, yellow, red", leds[0].g > leds[0].r && leds[1].r > 0.9 && leds[1].g > 0.7 && leds[2].r > leds[2].g + 0.5)
        check("shade lightens and darkens", Retro.luminance(Retro.shade(I.teal, 0.3)) > Retro.luminance(I.teal) && Retro.luminance(Retro.shade(I.teal, -0.3)) < Retro.luminance(I.teal))
        check("light plastic wants dark ink, dark plastic light ink", Retro.isLight(I.plastic) && Retro.isLight(I.yellow) && !Retro.isLight(I.plasticDark) && !Retro.isLight(I.purple))
        var a = Retro.Dice(seed: 7), b = Retro.Dice(seed: 7), c = Retro.Dice(seed: 8)
        let sa = (0..<8).map { _ in a.next() }, sb = (0..<8).map { _ in b.next() }, sc = (0..<8).map { _ in c.next() }
        check("the dice are deterministic per seed, differ across seeds and stay in 0 to 1", sa == sb && sa != sc && sa.allSatisfy { $0 >= 0 && $0 < 1 })
    }

    // MARK: Seven segments

    private static func mask(_ s: String) -> SevenSegment.Segments {
        var m: SevenSegment.Segments = []
        for ch in s {
            switch ch {
            case "a": m.insert(.a)
            case "b": m.insert(.b)
            case "c": m.insert(.c)
            case "d": m.insert(.d)
            case "e": m.insert(.e)
            case "f": m.insert(.f)
            case "g": m.insert(.g)
            default: break
            }
        }
        return m
    }

    private static func segmentChecks(_ check: Checker) {
        let table: [(Character, String)] = [("0", "abcdef"), ("1", "bc"), ("2", "abdeg"), ("3", "abcdg"), ("4", "bcfg"), ("5", "acdfg"),
                                            ("6", "acdefg"), ("7", "abc"), ("8", "abcdefg"), ("9", "abcdfg"), ("-", "g"), ("A", "abcefg"), ("P", "abefg")]
        for (ch, segs) in table {
            check("seven-segment \(ch) lights \(segs)", SevenSegment.cell(for: ch) == .digit(mask(segs)), "\(SevenSegment.cell(for: ch))")
        }
        check("lowercase a and p draw A and P", SevenSegment.cell(for: "a") == SevenSegment.cell(for: "A") && SevenSegment.cell(for: "p") == SevenSegment.cell(for: "P"))
        check("the colon and the dot are their own cells", SevenSegment.cell(for: ":") == .colon && SevenSegment.cell(for: ".") == .dot)
        let unknown: [Character] = [" ", "X", "Z", "q", "?", "/", "é", "♥", "😀", "\u{1}"]
        check("the space and unknown characters are blank", unknown.allSatisfy { SevenSegment.cell(for: $0) == .digit([]) })
        let digits = Array("0123456789")
        let digitMasks = digits.compactMap { ch -> UInt8? in if case .digit(let m) = SevenSegment.cell(for: ch) { return m.rawValue } else { return nil } }
        check("the ten digits light ten different segment sets", digitMasks.count == 10 && Set(digitMasks).count == 10)
        check("every supported character lights something", SevenSegment.supported.allSatisfy { SevenSegment.cell(for: $0) != .digit([]) })
        check("the 8 lights all seven", SevenSegment.cell(for: "8") == .digit(.all) && SevenSegment.Segments.all.rawValue == 0x7F)
        // Layout.
        let h: CGFloat = 28
        check("width: an empty text is 0, a digit is 0.56 of the height plus the slant", SevenSegment.width("", height: h) == 0 && abs(SevenSegment.width("8", height: h) - (h * 0.56 + h * SevenSegment.slant)) < 0.001)
        check("width grows with every character and the colon is narrower than a digit",
              SevenSegment.width("12:45", height: h) > SevenSegment.width("1245", height: h) && SevenSegment.cellWidth(.colon, height: h) < SevenSegment.cellWidth(.digit([]), height: h))
        var inside = true, sixPoints = true
        for height in [14.0, 22.0, 40.0] {
            let w = SevenSegment.cellWidth(.digit([]), height: height)
            for seg in SevenSegment.order {
                let pts = SevenSegment.polygon(seg, width: w, height: height)
                if pts.count != 6 { sixPoints = false }
                if pts.contains(where: { $0.x < -0.001 || $0.x > w + 0.001 || $0.y < -0.001 || $0.y > height + 0.001 }) { inside = false }
            }
        }
        check("each segment is a hexagon inside its digit cell at 14, 22 and 40 pt", inside && sixPoints)
    }

    // MARK: Pixel text

    private static func pixelChecks(_ check: Checker) {
        let sample = "AGENT TV 12:45 ♥"
        let cols = RetroPixelLayout.columns(sample)
        check("pixel text columns match LEDFont's (\(sample))", cols == LEDFont.columns(sample).map(\.bits) && cols.count == LEDFont.width(sample))
        check("pixel text lowercase draws the capital", RetroPixelLayout.columns("agent tv") == RetroPixelLayout.columns("AGENT TV"))
        check("pixel text: an unknown character is a blank cell of the same size", RetroPixelLayout.columns("A§B").count == 17 && RetroPixelLayout.columns("A§B")[6..<11].allSatisfy { $0 == 0 })
        check("pixel text: an empty text has no columns and no width", RetroPixelLayout.columns("").isEmpty && RetroPixelLayout.width("", pixel: 2) == 0)
        check("pixel text size: 7 pixels tall, 6 columns per character less one", RetroPixelLayout.height(pixel: 1.5) == 10.5 && RetroPixelLayout.width("AB", pixel: 2) == 22)
        let lit = RetroPixelLayout.litPixels(cols)
        check("the lit pixels are the bits of the columns", lit.count == cols.reduce(0) { $0 + $1.nonzeroBitCount } && lit.allSatisfy { $0.col < cols.count && $0.row < 7 })
        let a = RetroPixelLayout.litPixels(RetroPixelLayout.columns("A"))
        check("the letter A is the font's A (apex row has three pixels, base row five)", a.filter { $0.row == 0 }.count == 3 && a.filter { $0.row == 3 }.count == 5 && a.count == 18, "\(a.count)")
        // The OSD outline.
        let minus = RetroPixelLayout.columns("-")
        let ring = RetroPixelLayout.outlinePixels(minus)
        check("the OSD outline of a dash is the 7 x 3 block around it less the dash (16 pixels)", ring.count == 16, "\(ring.count)")
        let litShifted = Set(RetroPixelLayout.litPixels(cols).map { ($0.col + 1) * 100 + $0.row + 1 })
        let ringSet = RetroPixelLayout.outlinePixels(cols)
        check("the outline never covers a lit pixel and stays on the larger grid",
              ringSet.allSatisfy { !litShifted.contains($0.col * 100 + $0.row) && $0.col >= 0 && $0.col < cols.count + 2 && $0.row >= 0 && $0.row < 9 })
        check("every outline pixel touches a lit pixel", ringSet.allSatisfy { p in
            (-1...1).contains { dr in (-1...1).contains { dc in litShifted.contains((p.col + dc) * 100 + p.row + dr) } }
        })
    }

    // MARK: LED bars

    private static func ledBarChecks(_ check: Checker) {
        let n = 10
        check("LED bar lights 0 segments at 0, 5 at 0.5, 9 at 0.85, 10 at 1", [0.0, 0.5, 0.85, 1.0].map { RetroLEDBar.litCount(value: $0, segments: n) } == [0, 5, 9, 10],
              "\([0.0, 0.5, 0.85, 1.0].map { RetroLEDBar.litCount(value: $0, segments: n) })")
        check("LED bar clamps (-1 → 0, 7 → all, NaN → 0) and handles no segments", RetroLEDBar.litCount(value: -1, segments: n) == 0 && RetroLEDBar.litCount(value: 7, segments: n) == n
              && RetroLEDBar.litCount(value: .nan, segments: n) == 0 && RetroLEDBar.litCount(value: 0.5, segments: 0) == 0)
        func zones(_ count: Int, _ total: Int) -> [RetroLEDBar.Zone] { (0..<count).map { RetroLEDBar.zone(index: $0, segments: total) } }
        func tally(_ z: [RetroLEDBar.Zone]) -> [Int] { [z.filter { $0 == .green }.count, z.filter { $0 == .yellow }.count, z.filter { $0 == .red }.count] }
        check("10 segments are 6 green, 2 yellow, 2 red", tally(zones(10, 10)) == [6, 2, 2], "\(tally(zones(10, 10)))")
        check("at 0 nothing is lit; at 0.5 all lit segments are green", tally(zones(RetroLEDBar.litCount(value: 0, segments: n), n)) == [0, 0, 0] && tally(zones(RetroLEDBar.litCount(value: 0.5, segments: n), n)) == [5, 0, 0])
        check("at 0.85 the lit ones are 6 green, 2 yellow, 1 red", tally(zones(RetroLEDBar.litCount(value: 0.85, segments: n), n)) == [6, 2, 1], "\(tally(zones(9, n)))")
        check("at 1 all ten are lit, red at the end", tally(zones(RetroLEDBar.litCount(value: 1, segments: n), n)) == [6, 2, 2])
        check("zones run green, then yellow, then red, never back", zones(20, 20).enumerated().allSatisfy { i, z in i == 0 || rank(zones(20, 20)[i - 1]) <= rank(z) })
        check("20 segments are 12 green, 5 yellow, 3 red; 5 segments are 3, 1, 1", tally(zones(20, 20)) == [12, 5, 3] && tally(zones(5, 5)) == [3, 1, 1])
        check("the zone colours are the LED inks", RetroLEDBar.color(.green) == Retro.Ink.ledGreen && RetroLEDBar.color(.yellow) == Retro.Ink.ledYellow && RetroLEDBar.color(.red) == Retro.Ink.ledRed)
    }

    private static func rank(_ z: RetroLEDBar.Zone) -> Int { z == .green ? 0 : (z == .yellow ? 1 : 2) }

    // MARK: Bevels

    private static func bevelChecks(_ check: Checker) {
        let faces: [(String, Color)] = [("charcoal", Retro.Ink.plasticDark), ("grey", Retro.Ink.plasticMid), ("beige", Retro.Ink.plastic), ("teal", Retro.Ink.teal), ("purple", Retro.Ink.purple)]
        var raisedOK = true, sunkenOK = true, swapOK = true, grooveOK = true
        for (_, face) in faces {
            let raised = RetroBevelStyle.raised.edges(face: face), sunken = RetroBevelStyle.sunken.edges(face: face), groove = RetroBevelStyle.groove.edges(face: face)
            if raised.count != 1 || sunken.count != 1 || groove.count != 2 { raisedOK = false; continue }
            if Retro.luminance(raised[0].topLeft) <= Retro.luminance(raised[0].bottomRight) { raisedOK = false }   // raised: light top-left
            if Retro.luminance(sunken[0].topLeft) >= Retro.luminance(sunken[0].bottomRight) { sunkenOK = false }   // sunken: dark top-left
            if sunken[0].topLeft != raised[0].bottomRight || sunken[0].bottomRight != raised[0].topLeft { swapOK = false }
            if Retro.luminance(groove[0].topLeft) >= Retro.luminance(groove[0].bottomRight) || Retro.luminance(groove[1].topLeft) <= Retro.luminance(groove[1].bottomRight) { grooveOK = false }
            if Retro.luminance(raised[0].topLeft) <= Retro.luminance(face) || Retro.luminance(raised[0].bottomRight) >= Retro.luminance(face) { raisedOK = false }
        }
        check("raised bevel: light edge top-left, dark edge bottom-right, for charcoal, grey, beige, teal and purple", raisedOK)
        check("sunken bevel: dark edge top-left, light edge bottom-right", sunkenOK)
        check("a sunken bevel's edges are a raised one's swapped (same two colours)", swapOK)
        check("a groove is a sunken ring with a raised ring inside", grooveOK)
        check("bevel styles list their rings (raised 1, sunken 1, groove 2)", RetroBevelStyle.raised.rings == [true] && RetroBevelStyle.sunken.rings == [false] && RetroBevelStyle.groove.rings == [false, true])
    }

    // MARK: Layout

    private static func layoutChecks(_ check: Checker) {
        let frame = CGRect(x: 0, y: 0, width: 150, height: 140)
        var ok = true
        var detail = ""
        for (w, h, compact) in [(150.0, 140.0, true), (150.0, 140.0, false), (224.0, 140.0, true), (224.0, 140.0, false), (166.0, 140.0, false), (620.0, 340.0, false), (300.0, 220.0, true)] {
            let layout = CRTSetLayout(size: CGSize(width: w, height: h), compact: compact)
            let inside = CGRect(x: 0, y: 0, width: w, height: h).contains(layout.well) && layout.well.contains(layout.screen) && CGRect(x: 0, y: 0, width: w, height: h).contains(layout.stripRect)
            let apart = !layout.well.intersects(layout.stripRect)
            if !inside || !apart || layout.screen.width < 90 || layout.screen.height < 60 { ok = false; detail += " \(Int(w))x\(Int(h))\(compact ? "c" : "")" }
        }
        _ = frame
        check("TV set layouts keep the glass inside its mask inside the body, apart from the strip, and big enough (150 x 140 and up)", ok, detail)
        check("the knobs stay at the side from a square set up (150 x 140 and 224 x 140); only a set narrower than tall puts them underneath",
              CRTSetLayout(size: CGSize(width: 150, height: 140), compact: false).strip == .side && CRTSetLayout(size: CGSize(width: 224, height: 140), compact: false).strip == .side
                && CRTSetLayout(size: CGSize(width: 100, height: 140), compact: false).strip == .bottom)
        let regular = CRTSetLayout(size: CGSize(width: 150, height: 140), compact: false), compact = CRTSetLayout(size: CGSize(width: 150, height: 140), compact: true)
        check("the compact set gives the glass more room than the regular one", compact.screen.width * compact.screen.height > regular.screen.width * regular.screen.height)
        let shape = CRTGlassShape(cornerRadius: 12).path(in: CGRect(x: 0, y: 0, width: 150, height: 100)).boundingRect
        check("the glass touches its frame at the middle of every edge and never leaves it", abs(shape.minX) < 0.5 && abs(shape.minY) < 0.5 && abs(shape.maxX - 150) < 0.5 && abs(shape.maxY - 100) < 0.5, "\(shape)")
    }

    // MARK: Render smoke

    private static func image<V: View>(_ view: V, _ size: CGSize) -> [UInt8]? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return data
    }

    private static func distinct(_ px: [UInt8]) -> Int {
        var seen = Set<UInt32>()
        var i = 0
        while i + 3 < px.count { seen.insert(UInt32(px[i]) << 16 | UInt32(px[i + 1]) << 8 | UInt32(px[i + 2])); i += 4 }
        return seen.count
    }

    private static func mean(_ px: [UInt8], width w: Int, rect: CGRect) -> Double {
        var sum = 0.0, n = 0.0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let i = (y * w + x) * 4
                sum += 0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])
                n += 1
            }
        }
        return n > 0 ? sum / n : 0
    }

    // MARK: The two looks (the owner, 2026-11-16: an 8-bit switch; minimal, normal graphics when it is off)

    private static func styleChecks(_ check: Checker) {
        let saved = UserDefaults.standard.object(forKey: Retro.styleKey)
        defer { UserDefaults.standard.set(saved, forKey: Retro.styleKey) }
        UserDefaults.standard.removeObject(forKey: Retro.styleKey)
        check("the 8-bit style is on unless the person switched it off", Retro.is8bit)
        Pref.set(false, Retro.styleKey)
        check("  switched off it reads as off, and on again as on", !Retro.is8bit && { Pref.set(true, Retro.styleKey); return Retro.is8bit }())
        func twice<V: View>(_ view: () -> V, _ size: CGSize) -> (eight: [UInt8], minimal: [UInt8])? {
            Pref.set(true, Retro.styleKey)
            guard let a = image(view(), size) else { return nil }
            Pref.set(false, Retro.styleKey)
            guard let b = image(view(), size) else { return nil }
            return (a, b)
        }
        func coloured(_ px: [UInt8]) -> Int {   // pixels that are not grey (a coloured bar, a tinted stripe)
            var n = 0, i = 0
            while i + 3 < px.count {
                if px[i + 3] > 200, Int(max(px[i], px[i + 1], px[i + 2])) - Int(min(px[i], px[i + 1], px[i + 2])) > 14 { n += 1 }
                i += 4
            }
            return n
        }
        func opaque(_ px: [UInt8]) -> Int { stride(from: 3, to: px.count, by: 4).filter { px[$0] > 8 }.count }
        // A key: sheen and bevel in 8-bit, one flat face when minimal.
        if let key = twice({ Button("PLAY") {}.buttonStyle(.retro(tint: Retro.Ink.plasticDark)) }, CGSize(width: 70, height: 28)) {
            let top = CGRect(x: 14, y: 9, width: 12, height: 4), bottom = CGRect(x: 14, y: 43, width: 12, height: 4)
            let eight = abs(mean(key.eight, width: 140, rect: top) - mean(key.eight, width: 140, rect: bottom))
            let flat = abs(mean(key.minimal, width: 140, rect: top) - mean(key.minimal, width: 140, rect: bottom))
            check("a key is shaded top to bottom in the 8-bit look and one flat face in the minimal look", eight > 2.5 && flat < 1.0, "8-bit \(eight), minimal \(flat)")
        } else { check("a key renders in both looks", false) }
        // The panel face: a coloured stripe in 8-bit, none when minimal.
        if let panel = twice({ Color.clear.retroPanel(tint: Retro.Ink.teal) }, CGSize(width: 224, height: 140)) {
            check("a panel face wears a coloured stripe in the 8-bit look and a plain face in the minimal look", coloured(panel.eight) > 400 && coloured(panel.minimal) == 0,
                  "8-bit \(coloured(panel.eight)), minimal \(coloured(panel.minimal))")
        } else { check("a panel face renders in both looks", false) }
        // The header: only text and no colour, in both looks.
        if let head = twice({ Dash90Title("Ask AI", symbol: "sparkles", tint: Retro.Ink.lime) { Text("MON 16").font(.system(size: 9)) }.frame(width: 200) }, CGSize(width: 200, height: 20)) {
            check("a panel header is only text with no colour and no bar, in both looks", coloured(head.eight) == 0 && coloured(head.minimal) == 0 && opaque(head.eight) > 50 && opaque(head.minimal) > 50,
                  "coloured \(coloured(head.eight)) / \(coloured(head.minimal)), drawn \(opaque(head.eight)) / \(opaque(head.minimal))")
        } else { check("a panel header renders in both looks", false) }
        // The kit's other pieces differ between the looks (and the minimal ones draw something).
        let pieces: [(String, AnyView, CGSize)] = [
            ("pixel text", AnyView(RetroPixelText("AGENT TV 12:45").background(Color.black)), CGSize(width: 110, height: 14)),
            ("seven segments", AnyView(SevenSegmentText("12:45", height: 28)), CGSize(width: 100, height: 40)),
            ("LED bar", AnyView(RetroLEDBar(value: 0.6, size: CGSize(width: 120, height: 12))), CGSize(width: 130, height: 20)),
            ("crtScreen", AnyView(RetroSampleList().crtScreen()), CGSize(width: 150, height: 140)),
            ("CRTSet", AnyView(CRTSet(badge: "AGENT TV") { RetroSampleList() }), CGSize(width: 150, height: 140)),
            ("title bar", AnyView(RetroTitleBar("AGENT TV", symbol: "tv")), CGSize(width: 220, height: 20)),
        ]
        for (name, view, size) in pieces {
            if let both = twice({ view }, size) {
                check("\(name) draws differently in the minimal look, and still draws", both.eight != both.minimal && opaque(both.minimal) > 20, "minimal drew \(opaque(both.minimal))")
            } else { check("\(name) renders in both looks", false) }
        }
        if let bar = twice({ RetroLEDBar(value: 0.6, size: CGSize(width: 120, height: 12)) }, CGSize(width: 120, height: 12)) {
            // Along the middle row of the lit part: segments leave dark gaps, a slim bar does not.
            func gaps(_ px: [UInt8]) -> Int {
                let y = 12, w = 240
                var peak = 0.0, row: [Double] = []
                for x in 16..<(Int(0.55 * 240)) { let i = (y * w + x) * 4; let v = 0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2]); row.append(v); peak = max(peak, v) }
                return row.filter { $0 < peak * 0.45 }.count
            }
            check("the LED bar is made of segments in the 8-bit look and one slim rounded bar in the minimal look", gaps(bar.eight) > 3 && gaps(bar.minimal) == 0, "gaps \(gaps(bar.eight)) / \(gaps(bar.minimal))")
        } else { check("the LED bar renders", false) }
    }

    private static func renderChecks(_ check: Checker) {
        let panel = CGSize(width: 150, height: 140)
        let samples: [(String, AnyView, CGSize)] = [
            ("crtScreen over text", AnyView(RetroSampleList().crtScreen()), panel),
            ("crtScreen over the colour card", AnyView(RetroTestCard().crtScreen(tint: Retro.Ink.phosphorAmber)), panel),
            ("CRTNoise", AnyView(CRTNoise(seed: 3, strength: 0.7)), panel),
            ("CRTSet regular", AnyView(CRTSet(badge: "AGENT TV", onAir: true) { RetroSampleList() }), panel),
            ("CRTSet compact", AnyView(CRTSet(compact: true) { RetroTestCard() }), panel),
            ("CRTSet off", AnyView(CRTSet(badge: "AGENT TV", powerOn: false) { Color.clear }), panel),
            ("CRTSet side strip", AnyView(CRTSet(badge: "AGENT TV") { RetroSampleList() }), CGSize(width: 224, height: 140)),
            ("pixel text", AnyView(RetroPixelText("AGENT TV 12:45").background(Color.black)), CGSize(width: 100, height: 14)),
            ("OSD", AnyView(RetroOSD("CH 03").background(Color.gray)), CGSize(width: 50, height: 14)),
            ("seven segments", AnyView(SevenSegmentText("12:45", height: 28)), CGSize(width: 100, height: 28)),
            ("LED bars", AnyView(VStack { RetroLEDBar(value: 0.85, size: CGSize(width: 120, height: 12)); RetroLEDBar(value: 0.5, axis: .vertical, size: CGSize(width: 12, height: 60)) }), CGSize(width: 130, height: 90)),
            ("title bar", AnyView(RetroTitleBar("AGENT TV", symbol: "tv")), CGSize(width: 220, height: 18)),
            ("Memphis pattern", AnyView(MemphisPattern(seed: 1, opacity: 0.3)), CGSize(width: 200, height: 120)),
            ("panel face", AnyView(Color.clear.retroPanel(tint: Retro.Ink.teal)), CGSize(width: 224, height: 140)),
            ("key", AnyView(Button("PLAY") {}.buttonStyle(.retro(tint: Retro.Ink.teal))), CGSize(width: 70, height: 28)),
        ]
        var rendered: [String: [UInt8]] = [:]
        for (name, view, size) in samples {
            let px = image(view, size)
            rendered[name] = px
            check("renders: \(name)", px != nil && distinct(px ?? []) > 1, "\(distinct(px ?? []))")
        }
        // The drawing is the layout: an "A" at 2 pt pixels on a 2x screen is 18 lit pixels of 4 x 4 device pixels each.
        if let a = image(RetroPixelText("A", pixel: 2).background(Color.black), CGSize(width: 10, height: 14)) {
            var bright = 0
            var i = 0
            while i + 3 < a.count { if a[i] > 200 && a[i + 1] > 200 && a[i + 2] > 200 { bright += 1 }; i += 4 }
            check("pixel text draws exactly the lit pixels (an A at 2 pt: 18 pixels of 16 device pixels)", bright == 18 * 16, "\(bright)")
        } else {
            check("pixel text render", false, "no image")
        }
        let n1 = image(CRTNoise(seed: 3, strength: 0.7), panel), n2 = image(CRTNoise(seed: 3, strength: 0.7), panel), n3 = image(CRTNoise(seed: 4, strength: 0.7), panel)
        check("CRTNoise is a still texture: the same seed draws the same picture, another seed another one", n1 != nil && n1 == n2 && n1 != n3)
        let m1 = image(MemphisPattern(seed: 1), CGSize(width: 200, height: 120)), m2 = image(MemphisPattern(seed: 1), CGSize(width: 200, height: 120)), m3 = image(MemphisPattern(seed: 2), CGSize(width: 200, height: 120))
        check("the Memphis pattern is the same for one seed and differs between seeds", m1 != nil && m1 == m2 && m1 != m3)
        // Scanlines are subtle: they darken the middle of a text screen by a few percent, not more.
        let size = CGSize(width: 150, height: 100)
        let plain = image(RetroSampleList(size: 9).crtScreen(scanlines: 0, vignette: 0), size), lined = image(RetroSampleList(size: 9).crtScreen(scanlines: 0.10, vignette: 0), size)
        if let plain, let lined {
            let rect = CGRect(x: 60, y: 40, width: 180, height: 120)
            let a = mean(plain, width: 300, rect: rect), b = mean(lined, width: 300, rect: rect)
            let drop = a > 0 ? (a - b) / a : 0
            check("scanlines at 0.10 darken the middle of the screen by 2 to 8 percent (text stays crisp)", drop > 0.02 && drop < 0.08, String(format: "%.1f%%", drop * 100))
        } else {
            check("scanline render", false, "no image")
        }
        // Every pixel colour of the off tube is dark.
        if let off = rendered["CRTSet off"] {
            check("a switched-off set has a dark glass (not a lit picture)", distinct(off) > 4)
        }
    }
}
