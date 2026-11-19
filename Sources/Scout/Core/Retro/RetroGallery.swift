import SwiftUI

// Gallery scenes `retro-*`: the 90s kit on black (the island is dark, so every sample sits on black in both appearances).
// Synthetic words only. Render with `scripts/gallery.sh retro`.

/// A colour test card: colour bars, a grey ramp and a small black-and-white checker; a typical "colour picture" for the glass.
struct RetroTestCard: View {
    var body: some View {
        Canvas { ctx, size in
            let bars: [Color] = [Color(white: 0.92), Color(red: 0.9, green: 0.9, blue: 0.1), Color(red: 0.1, green: 0.85, blue: 0.9),
                                 Color(red: 0.1, green: 0.8, blue: 0.2), Color(red: 0.9, green: 0.15, blue: 0.85), Color(red: 0.9, green: 0.1, blue: 0.1),
                                 Color(red: 0.12, green: 0.15, blue: 0.9)]
            let top = size.height * 0.68
            let bw = size.width / CGFloat(bars.count)
            for (i, c) in bars.enumerated() { ctx.fill(Path(CGRect(x: CGFloat(i) * bw, y: 0, width: bw + 0.5, height: top)), with: .color(c)) }
            let mid = size.height * 0.80
            let rev: [Color] = [bars[6], .black, bars[4], .black, bars[2], .black, bars[0]]
            for (i, c) in rev.enumerated() { ctx.fill(Path(CGRect(x: CGFloat(i) * bw, y: top, width: bw + 0.5, height: mid - top)), with: .color(c)) }
            let steps = 12
            let sw = size.width / CGFloat(steps)
            for i in 0..<steps {
                let g = Double(i) / Double(steps - 1)
                ctx.fill(Path(CGRect(x: CGFloat(i) * sw, y: mid, width: sw + 0.5, height: size.height - mid)), with: .color(Color(white: g)))
            }
        }
    }
}

/// A small mock "agents on a channel" listing in the system font, the way a panel would put short words on the glass.
struct RetroSampleList: View {
    var color: Color = Retro.Ink.osdWhite
    var size: CGFloat = 9.5

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.32) {
            row("01", "NOTES", "WORKING", Retro.Ink.phosphorGreen)
            row("02", "SCOUT", "NEEDS YOU", Retro.Ink.yellow)
            row("03", "SITE", "DONE 12 MIN", Retro.Ink.teal)
            row("04", "API", "ERROR", Retro.Ink.red)
            row("05", "DOCS", "ASLEEP", Retro.Ink.plasticMid)
        }
        .padding(size * 0.85)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ ch: String, _ name: String, _ state: String, _ dot: Color) -> some View {
        HStack(spacing: 6) {
            Text(ch).foregroundStyle(color.opacity(0.55))
            Text(name).foregroundStyle(color)
            Spacer(minLength: 4)
            Circle().fill(dot).frame(width: 5, height: 5)
            Text(state).foregroundStyle(dot)
        }
        .font(.system(size: size, weight: .medium, design: .monospaced))
        .lineLimit(1)
    }
}

/// A screen picture for the gallery: the test card with an on-screen display on top.
private struct RetroSampleScreen: View {
    enum Kind { case card, list, noSignal }
    let kind: Kind
    var pixel: CGFloat = 1.5

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch kind {
            case .card:
                RetroTestCard()
                RetroOSD("CH 03", pixel: pixel).padding(6)
            case .list:
                RetroSampleList()
                RetroOSD("CH 01", pixel: pixel, color: Retro.Ink.phosphorAmber).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(6)
            case .noSignal:
                CRTNoise(seed: 4, strength: 0.6)
                RetroOSD("NO SIGNAL", pixel: pixel * 1.3, color: Retro.Ink.osdWhite)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// The gallery's offscreen capture cannot draw blends and colour filters (the phosphor tint), so tinted samples are drawn with
/// `ImageRenderer` (the renderer the real screen uses) and shown as a picture.
private struct RetroSnapshot<Content: View>: View {
    let size: CGSize
    @ViewBuilder var content: () -> Content
    var body: some View { picture() }

    private func picture() -> AnyView {
        let renderer = ImageRenderer(content: content().frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let image = renderer.nsImage else { return AnyView(Color.red.frame(width: size.width, height: size.height)) }
        return AnyView(Image(nsImage: image).resizable().frame(width: size.width, height: size.height))
    }
}

private struct RetroBoard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            content().padding(14)
        }
    }
}

private func caption(_ text: String) -> some View {
    RetroPixelText(text, pixel: 1, color: Retro.Ink.osdWhite.opacity(0.62))
}

@MainActor
enum RetroGallery {
    static func register() {
        Gallery.register("retro-palette", size: CGSize(width: 620, height: 270), backdrop: .window) { palette }
        Gallery.register("retro-bevels", size: CGSize(width: 620, height: 400), backdrop: .window) { bevels }
        Gallery.register("retro-crt-panel", size: CGSize(width: 700, height: 190), backdrop: .window) { crtPanel }
        Gallery.register("retro-crt-large-text", size: CGSize(width: 660, height: 380), backdrop: .window) { crtLarge(.list) }
        Gallery.register("retro-crt-large-picture", size: CGSize(width: 660, height: 380), backdrop: .window) { crtLarge(.card) }
        Gallery.register("retro-noise", size: CGSize(width: 700, height: 240), backdrop: .window) { noise }
        Gallery.register("retro-set", size: CGSize(width: 880, height: 400), backdrop: .window) { sets }
        Gallery.register("retro-set-large", size: CGSize(width: 660, height: 400), backdrop: .window) { setLarge }
        Gallery.register("retro-pixeltext", size: CGSize(width: 620, height: 360), backdrop: .window) { pixelText }
        Gallery.register("retro-segments", size: CGSize(width: 560, height: 280), backdrop: .window) { segments }
        Gallery.register("retro-ledbar", size: CGSize(width: 620, height: 250), backdrop: .window) { ledBars }
        Gallery.register("retro-chrome", size: CGSize(width: 620, height: 400), backdrop: .window) { chrome }
        Gallery.register("retro-board", size: CGSize(width: 740, height: 190), backdrop: .window) { board }
    }

    // MARK: Palette

    private static func swatches(_ title: String, _ items: [(String, Color)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            caption(title)
            HStack(spacing: 8) {
                ForEach(0..<items.count, id: \.self) { i in
                    VStack(spacing: 4) {
                        Color.clear.frame(width: 58, height: 30)
                            .retroBevel(.sunken, cornerRadius: 3, depth: 1.5, face: items[i].1)
                        caption(items[i].0)
                    }
                }
            }
        }
    }

    private static var palette: some View {
        typealias I = Retro.Ink
        return RetroBoard {
            VStack(alignment: .leading, spacing: 12) {
                swatches("ACCENTS", [("TEAL", I.teal), ("MAGENTA", I.magenta), ("PURPLE", I.purple), ("YELLOW", I.yellow), ("LIME", I.lime), ("ORANGE", I.orange), ("RED", I.red)])
                swatches("PLASTIC", [("PLASTIC", I.plastic), ("MID", I.plasticMid), ("DARK", I.plasticDark)])
                swatches("SCREEN", [("BLACK", I.screenBlack), ("GREEN", I.phosphorGreen), ("AMBER", I.phosphorAmber), ("OSD WHITE", I.osdWhite)])
                swatches("LEDS", [("GREEN", I.ledGreen), ("YELLOW", I.ledYellow), ("RED", I.ledRed)])
            }
        }
    }

    // MARK: Bevels and keys

    private static func tile(_ style: RetroBevelStyle, face: Color, depth: CGFloat = 1.5, label: String) -> some View {
        VStack(spacing: 4) {
            Color.clear.frame(width: 76, height: 38).retroBevel(style, cornerRadius: 4, depth: depth, face: face)
            caption(label)
        }
    }

    private static var bevels: some View {
        typealias I = Retro.Ink
        return RetroBoard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            tile(.raised, face: I.plasticDark, label: "RAISED")
                            tile(.sunken, face: I.plasticDark, label: "SUNKEN")
                            tile(.groove, face: I.plasticDark, label: "GROOVE")
                        }
                        HStack(spacing: 8) {
                            tile(.raised, face: I.plasticMid, label: "RAISED")
                            tile(.sunken, face: I.plasticMid, label: "SUNKEN")
                            tile(.groove, face: I.plasticMid, label: "GROOVE")
                        }
                        HStack(spacing: 8) {
                            tile(.raised, face: I.plastic, label: "RAISED")
                            tile(.sunken, face: I.plastic, label: "SUNKEN")
                            tile(.groove, face: I.plastic, label: "GROOVE")
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            tile(.raised, face: I.teal, label: "TEAL")
                            tile(.sunken, face: I.magenta, label: "MAGENTA")
                            tile(.groove, face: I.purple, label: "PURPLE")
                        }
                        HStack(spacing: 8) {
                            tile(.raised, face: I.plasticDark, depth: 1, label: "DEPTH 1")
                            tile(.raised, face: I.plasticDark, depth: 2, label: "DEPTH 2")
                            tile(.raised, face: I.plasticDark, depth: 3, label: "DEPTH 3")
                        }
                        HStack(spacing: 8) {
                            tile(.sunken, face: I.plasticDark, depth: 1, label: "DEPTH 1")
                            tile(.sunken, face: I.plasticDark, depth: 2, label: "DEPTH 2")
                            tile(.sunken, face: I.plasticDark, depth: 3, label: "DEPTH 3")
                        }
                    }
                }
                caption("KEYS: NORMAL, PRESSED, DISABLED, TINTS")
                HStack(spacing: 8) {
                    RetroKeyFace { Text("PLAY") }
                    RetroKeyFace(pressed: true) { Text("PLAY") }
                    Button("PLAY") {}.buttonStyle(.retro).disabled(true)
                    Button("ALLOW") {}.buttonStyle(.retro(tint: Retro.Ink.teal))
                    Button("DENY") {}.buttonStyle(.retro(tint: Retro.Ink.magenta))
                    Button("OK") {}.buttonStyle(.retro(tint: Retro.Ink.yellow))
                    Button("MENU") {}.buttonStyle(.retro(tint: Retro.Ink.purple))
                    Button("REC") {}.buttonStyle(.retro(tint: Retro.Ink.red))
                }
                HStack(spacing: 6) {
                    RetroKeyFace(compact: true) { Text("STOP") }
                    RetroKeyFace(pressed: true, compact: true) { Text("STOP") }
                    Button("EJECT") {}.buttonStyle(.retro(tint: Retro.Ink.plasticDark, compact: true))
                    Button("VOL +") {}.buttonStyle(.retro(tint: Retro.Ink.teal, compact: true))
                    Button("VOL -") {}.buttonStyle(.retro(tint: Retro.Ink.orange, compact: true))
                    Button("▶") {}.buttonStyle(.retro(tint: Retro.Ink.lime, compact: true))
                    Button("■") {}.buttonStyle(.retro(tint: Retro.Ink.plastic, compact: true))
                    Image(systemName: "gearshape.fill").frame(width: 12).modifier(KeyFaceModifier())
                }
            }
        }
    }

    private struct KeyFaceModifier: ViewModifier {
        func body(content: Content) -> some View { RetroKeyFace(compact: true) { content } }
    }

    // MARK: Glass

    private static func glass<C: View>(_ w: CGFloat, _ h: CGFloat, scan: Double = 0.10, tint: Color? = nil, vignette: Double = 0.35, radius: CGFloat = 12, label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content().frame(width: w, height: h).clipped().crtScreen(cornerRadius: radius, scanlines: scan, tint: tint, vignette: vignette)
            caption(label)
        }
    }

    private static var crtPanel: some View {
        RetroBoard {
            HStack(alignment: .top, spacing: 12) {
                glass(224, 140, label: "LIST 224 X 140") { RetroSampleScreen(kind: .list) }
                glass(224, 140, label: "CARD 224 X 140") { RetroSampleScreen(kind: .card) }
                VStack(spacing: 6) {
                    RetroSnapshot(size: CGSize(width: 150, height: 66)) { RetroSampleList(size: 8).clipped().crtScreen(cornerRadius: 8, tint: Retro.Ink.phosphorGreen) }
                    caption("GREEN PHOSPHOR")
                    RetroSnapshot(size: CGSize(width: 150, height: 66)) { RetroSampleList(size: 8).clipped().crtScreen(cornerRadius: 8, scanlines: 0.24, tint: Retro.Ink.phosphorAmber) }
                    caption("AMBER, SCANLINES .24")
                }
            }
        }
    }

    private static func crtLarge(_ kind: RetroSampleScreen.Kind) -> some View {
        RetroBoard {
            VStack(alignment: .leading, spacing: 6) {
                Group { if kind == .list { RetroSampleList(size: 20) } else { RetroSampleScreen(kind: kind, pixel: 3) } }
                    .frame(width: 620, height: 320).clipped()
                    .crtScreen(cornerRadius: 26, scanlines: 0.10, vignette: 0.40)
                caption("620 X 320, SCANLINES .10, VIGNETTE .40")
            }
        }
    }

    // MARK: Noise

    private static var noise: some View {
        RetroBoard {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    RetroSampleScreen(kind: .noSignal).frame(width: 224, height: 140).crtScreen()
                    caption("SEED 4, .60")
                }
                VStack(alignment: .leading, spacing: 4) {
                    CRTNoise(seed: 9, strength: 0.25).frame(width: 150, height: 140).crtScreen(cornerRadius: 10)
                    caption("SEED 9, .25")
                }
                VStack(alignment: .leading, spacing: 4) {
                    RetroSnapshot(size: CGSize(width: 260, height: 140)) { CRTNoise(seed: 2, strength: 1).crtScreen(cornerRadius: 12, scanlines: 0.14, tint: Retro.Ink.phosphorGreen) }
                    caption("SEED 2, 1.0, GREEN")
                }
            }
        }
    }

    // MARK: TV sets

    private static var sets: some View {
        RetroBoard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        CRTSet(badge: "AGENT TV", compact: true) { RetroSampleScreen(kind: .card, pixel: 1) }.frame(width: 150, height: 140)
                        caption("COMPACT 150 X 140")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        CRTSet(badge: "AGENT TV") { RetroSampleScreen(kind: .list, pixel: 1) }.frame(width: 150, height: 140)
                        caption("REGULAR 150 X 140")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        CRTSet(badge: "AGENT TV", onAir: true) { RetroSampleScreen(kind: .list, pixel: 1.25) }.frame(width: 224, height: 140)
                        caption("ON AIR 224 X 140")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        CRTSet(compact: true, onAir: true) { RetroSampleScreen(kind: .card, pixel: 1) }.frame(width: 224, height: 140)
                        caption("COMPACT, ON AIR")
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        CRTSet(badge: "AGENT TV", powerOn: false) { Color.clear }.frame(width: 150, height: 140)
                        caption("OFF")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        CRTSet(badge: "AGENT TV", compact: true, powerOn: false, onAir: true) { Color.clear }.frame(width: 150, height: 140)
                        caption("COMPACT, OFF")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        CRTSet(badge: "AGENT TV") { RetroSampleScreen(kind: .noSignal, pixel: 1) }.frame(width: 150, height: 140)
                        caption("NO SIGNAL")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        RetroSnapshot(size: CGSize(width: 224, height: 140)) { CRTSet(badge: "SCOUT TV", plastic: Retro.Ink.plastic, tint: Retro.Ink.phosphorGreen) { RetroSampleList(size: 8.5) } }
                        caption("BEIGE, GREEN PHOSPHOR")
                    }
                }
            }
        }
    }

    private static var setLarge: some View {
        RetroBoard {
            VStack(alignment: .leading, spacing: 6) {
                CRTSet(badge: "AGENT TV", onAir: true) { RetroSampleScreen(kind: .card, pixel: 3) }.frame(width: 620, height: 340)
                caption("620 X 340, ON AIR")
            }
        }
    }

    // MARK: Pixel text

    private static var pixelText: some View {
        RetroBoard {
            VStack(alignment: .leading, spacing: 8) {
                ForEach([1.0, 1.5, 2.0, 3.0], id: \.self) { p in
                    VStack(alignment: .leading, spacing: 4) {
                        caption("PIXEL \(p == p.rounded() ? String(Int(p)) : String(p))")
                        RetroPixelText("AGENT TV 12:45 NEEDS YOU ♥ ✓", pixel: p)
                        RetroOSD("CH 03 WORKING 12 MIN", pixel: p)
                    }
                }
                caption("OSD OVER A PICTURE")
                RetroTestCard().frame(width: 330, height: 52)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 3) {
                            RetroOSD("PLAY", pixel: 1.5, color: Retro.Ink.phosphorGreen)
                            RetroOSD("CH 03 NOTES", pixel: 1.5, color: Retro.Ink.osdWhite)
                        }.padding(5)
                    }
                    .crtScreen(cornerRadius: 8)
            }
        }
    }

    // MARK: Seven segments

    private static var segments: some View {
        RetroBoard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 22) {
                    VStack(alignment: .leading, spacing: 4) { caption("14 PT"); SevenSegmentText("12:45", height: 14) }
                    VStack(alignment: .leading, spacing: 4) { caption("22 PT"); SevenSegmentText("12:45", height: 22, color: Retro.Ink.phosphorAmber) }
                    VStack(alignment: .leading, spacing: 4) { caption("40 PT"); SevenSegmentText("12:45", height: 40) }
                }
                HStack(alignment: .bottom, spacing: 22) {
                    VStack(alignment: .leading, spacing: 4) { caption("COUNTER"); SevenSegmentText("0087", height: 22, color: Retro.Ink.ledRed) }
                    VStack(alignment: .leading, spacing: 4) { caption("PM"); SevenSegmentText("8:07 P", height: 22, color: Retro.Ink.teal) }
                    VStack(alignment: .leading, spacing: 4) { caption("NEGATIVE, DOT"); SevenSegmentText("-18.5", height: 22, color: Retro.Ink.ledYellow) }
                }
                HStack(alignment: .bottom, spacing: 22) {
                    VStack(alignment: .leading, spacing: 4) { caption("NO GHOST"); SevenSegmentText("12:45", height: 22, ghost: false) }
                    VStack(alignment: .leading, spacing: 4) { caption("ALL 0-9"); SevenSegmentText("0123456789", height: 22, color: Retro.Ink.osdWhite) }
                }
                caption("OVER A CRT")
                SevenSegmentText("12:45", height: 40, color: Retro.Ink.phosphorGreen)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .frame(width: 200)
                    .crtScreen(cornerRadius: 10)
            }
        }
    }

    // MARK: LED bars

    private static var ledBars: some View {
        RetroBoard {
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach([0.0, 0.25, 0.5, 0.75, 0.85, 1.0], id: \.self) { v in
                        HStack(spacing: 8) {
                            RetroLEDBar(value: v, size: CGSize(width: 160, height: 12))
                            caption("\(Int(v * 100)) PCT")
                        }
                    }
                    HStack(spacing: 8) {
                        RetroLEDBar(value: 0.6, segments: 20, size: CGSize(width: 160, height: 9))
                        caption("20 SEGMENTS")
                    }
                    HStack(spacing: 8) {
                        RetroLEDBar(value: 0.4, segments: 5, size: CGSize(width: 90, height: 10))
                        caption("5 SEGMENTS")
                    }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach([0.1, 0.35, 0.6, 0.8, 0.95, 1.0], id: \.self) { v in
                        VStack(spacing: 4) {
                            RetroLEDBar(value: v, axis: .vertical, size: CGSize(width: 12, height: 100))
                            caption("\(Int(v * 100))")
                        }
                    }
                    VStack(spacing: 4) {
                        RetroLEDBar(value: 0.7, segments: 8, axis: .vertical, size: CGSize(width: 8, height: 60))
                        caption("8")
                    }
                }
            }
        }
    }

    // MARK: Chrome

    private static var chrome: some View {
        RetroBoard {
            VStack(alignment: .leading, spacing: 10) {
                RetroTitleBar("AGENT TV", symbol: "tv", tint: Retro.Ink.teal).frame(width: 224)
                RetroTitleBar("CPU AND MEMORY", symbol: "cpu", tint: Retro.Ink.magenta).frame(width: 224)
                RetroTitleBar("RADIO", symbol: "radio", tint: Retro.Ink.purple) {
                    Button("X") {}.buttonStyle(.retro(tint: Retro.Ink.plasticMid, compact: true))
                }.frame(width: 224)
                RetroTitleBar("SETTINGS", tint: Retro.Ink.yellow) {
                    HStack(spacing: 3) {
                        Button("?") {}.buttonStyle(.retro(tint: Retro.Ink.plastic, compact: true))
                        Button("X") {}.buttonStyle(.retro(tint: Retro.Ink.plastic, compact: true))
                    }
                }.frame(width: 340)
                RetroTitleBar("A WIDE WINDOW WITH A LONG TITLE", symbol: "sparkles", tint: Retro.Ink.orange).frame(width: 590)
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        MemphisPattern(seed: 1, opacity: 0.12).frame(width: 190, height: 110).retroBevel(.sunken, cornerRadius: 4, depth: 1, face: .black)
                        caption("OPACITY .12 (BACKGROUND)")
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        MemphisPattern(seed: 5, opacity: 0.30).frame(width: 190, height: 110).retroBevel(.sunken, cornerRadius: 4, depth: 1, face: .black)
                        caption("OPACITY .30, SEED 5")
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        MemphisPattern(seed: 2, opacity: 0.12).frame(width: 190, height: 110)
                            .overlay { RetroPixelText("HELLO", pixel: 3, color: Retro.Ink.osdWhite) }
                            .retroBevel(.sunken, cornerRadius: 4, depth: 1, face: .black)
                        caption("BEHIND CONTENT")
                    }
                }
            }
        }
    }

    // MARK: Everything together

    private static var board: some View {
        RetroBoard {
            HStack(alignment: .top, spacing: 8) {
                // Panel 1: the TV set, 4 cells wide.
                CRTSet(badge: "AGENT TV", onAir: true) {
                    ZStack(alignment: .topLeading) {
                        RetroSampleList(size: 9)
                        RetroOSD("CH 02", pixel: 1.25, color: Retro.Ink.phosphorAmber).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(5)
                    }
                }
                .frame(width: 224, height: 140)
                // Panel 2: meters, 3 cells wide.
                VStack(alignment: .leading, spacing: 5) {
                    RetroTitleBar("CPU", symbol: "cpu", tint: Retro.Ink.teal)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        SevenSegmentText("42", height: 26, color: Retro.Ink.phosphorGreen)
                        RetroPixelText("PCT", pixel: 1, color: Retro.Ink.osdWhite.opacity(0.7))
                    }
                    RetroLEDBar(value: 0.42, size: CGSize(width: 144, height: 11))
                    HStack(spacing: 4) {
                        RetroPixelText("MEM", pixel: 1.25, color: Retro.Ink.osdWhite.opacity(0.8))
                        RetroLEDBar(value: 0.78, size: CGSize(width: 116, height: 11))
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .frame(width: 166, height: 140, alignment: .topLeading)
                .retroPanel(tint: Retro.Ink.teal)
                // Panel 3: a clock with keys on confetti, 4 cells wide.
                VStack(alignment: .leading, spacing: 6) {
                    RetroTitleBar("TODAY", symbol: "clock", tint: Retro.Ink.magenta)
                    SevenSegmentText("12:45", height: 36, color: Retro.Ink.phosphorAmber).padding(.leading, 6)
                    RetroPixelText("SUN 15 NOV  NEXT 13:30", pixel: 1.25, color: Retro.Ink.osdWhite.opacity(0.85)).padding(.leading, 6)
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        Button("SNOOZE") {}.buttonStyle(.retro(tint: Retro.Ink.plasticMid, compact: true))
                        Button("OK") {}.buttonStyle(.retro(tint: Retro.Ink.magenta, compact: true))
                    }
                }
                .padding(8)
                .frame(width: 224, height: 140, alignment: .topLeading)
                .background(MemphisPattern(seed: 3, opacity: 0.12))
                .retroPanel(tint: Retro.Ink.magenta)
            }
        }
    }
}
