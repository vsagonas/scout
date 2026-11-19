import SwiftUI

// The Radio's player as a 90s boombox, drawn in code with the kit in Core/Retro (our own design, no real brand): a cassette window with
// two reels, an LCD with the station's name and the song, a tuner scale whose needle sits by the station's place in the list, chunky
// keys, a volume fader and a speaker grille at each end. It shows only true things: LIVE while a station plays, the codec and the
// bitrate the directory knows. Reduce Motion: nothing turns; a small lamp fades instead. Nothing ticks while the notch is closed.

/// What the boombox does, as plain functions (the drawing and the self-test read the same ones).
enum RadioBoom {
    /// One slow turn of the reels, in seconds.
    static let reelPeriod: Double = 7

    /// The reels turn only while a station really plays, and never with Reduce Motion.
    static func reelsTurn(state: RadioPlayState, reduceMotion: Bool) -> Bool { state == .playing && !reduceMotion }

    /// With Reduce Motion the tape lamp fades softly while a station plays (instead of the reels turning).
    static func lampFades(state: RadioPlayState, reduceMotion: Bool) -> Bool { state == .playing && reduceMotion }

    /// True when a timeline may run for the reels or the lamp: something moves in this state, the notch is open (a closed notch shows
    /// nothing, so nothing ticks) and this is not a scripted run.
    static func isDriven(state: RadioPlayState, reduceMotion: Bool, notchOpen: Bool, scripted: Bool) -> Bool {
        (reelsTurn(state: state, reduceMotion: reduceMotion) || lampFades(state: state, reduceMotion: reduceMotion)) && notchOpen && !scripted
    }

    /// "LIVE" is true only while a station plays.
    static func isLive(_ state: RadioPlayState) -> Bool { state == .playing }

    /// The reels' angle in degrees at `time` seconds.
    static func reelAngle(at time: TimeInterval) -> Double {
        time.truncatingRemainder(dividingBy: reelPeriod) / reelPeriod * 360
    }

    /// The tape lamp's brightness while it fades (0.35 to 1, one breath in 2.4 s).
    static func lampLevel(at time: TimeInterval) -> Double { 0.675 + 0.325 * sin(time * 2 * .pi / 2.4) }

    /// The marks on the LCD: only true things. LIVE while it plays; what the stream is (codec and bitrate) when the directory says.
    static func marks(station: RadioStation, state: RadioPlayState) -> [String] {
        var out: [String] = []
        if isLive(state) { out.append("LIVE") }
        let quality = station.quality.uppercased()
        if !quality.isEmpty { out.append(quality) }
        return out
    }

    /// The tape lamp: green while playing, yellow while connecting, off otherwise.
    enum Lamp: Equatable { case off, connecting, playing }

    static func lamp(for state: RadioPlayState) -> Lamp {
        switch state {
        case .playing: .playing
        case .loading: .connecting
        case .idle, .paused, .failed: .off
        }
    }

    /// What the player says out loud: the name, then what is happening (the song, the place, or the state).
    static func speech(station: RadioStation, state: RadioPlayState, song: String?) -> String {
        var parts = [station.name]
        switch state {
        case .failed(let line): parts.append(line)
        case .loading: parts.append(String(localized: "Connecting"))
        case .paused: parts.append(String(localized: "Paused"))
        case .idle: parts.append(String(localized: "Ready"))
        case .playing: parts.append(song ?? (station.place.isEmpty ? String(localized: "Live") : station.place))
        }
        return parts.joined(separator: ", ")
    }

    /// The plastic of the boombox's body (the Mirror's toolbar wears it too: it stays charcoal in every preset).
    static let body = Retro.shade(Retro.Ink.plasticMid, -0.52)
    /// The plastic of the Radio's own deck (the Radio tab's boombox and the dashboard deck): charcoal in the dark preset, a light warm plastic
    /// in the light one.
    static var deckBody: Color { Look.isLight ? Color(red: 0.855, green: 0.835, blue: 0.79) : body }
    /// The LCD's glass: dark in the dark preset, the light well (`Look.well`) in the light one.
    static var lcdFace: Color { Look.well(dark: Color(red: 0.025, green: 0.06, blue: 0.045)) }
    /// The LCD's inks: the phosphor colours themselves on dark glass, their deeper shade (`Look.accent`) on the light well.
    static var green: Color { Look.accent(Retro.Ink.phosphorGreen) }
    static var amber: Color { Look.accent(Retro.Ink.phosphorAmber) }
    static var yellow: Color { Look.accent(Retro.Ink.ledYellow) }
    static var orange: Color { Look.accent(Retro.Ink.orange) }
}

/// The tuner scale as numbers: the needle sits at the current station's place among the stations shown in the list.
enum RadioTuner {
    /// Most ticks drawn (a long list shares them).
    static let maxTicks = 24

    /// The needle, 0 (first station of the list) to 1 (last); nil when the station is not in the list. One station sits in the middle.
    static func position(of id: String?, in ids: [String]) -> Double? {
        guard let id, let index = ids.firstIndex(of: id) else { return nil }
        return ids.count == 1 ? 0.5 : Double(index) / Double(ids.count - 1)
    }

    /// How many ticks the scale draws for a list of `count` stations (one per station, up to `maxTicks`).
    static func tickCount(_ count: Int) -> Int { max(0, min(count, maxTicks)) }

    /// The needle's x in a scale `width` wide with `inset` blank at each end.
    static func needleX(_ position: Double, width: CGFloat, inset: CGFloat) -> CGFloat {
        inset + CGFloat(min(1, max(0, position))) * max(0, width - 2 * inset)
    }

    /// "3/8": the station's place, or nil when it is not in the list.
    static func placeText(of id: String?, in ids: [String]) -> String? {
        guard let id, let index = ids.firstIndex(of: id) else { return nil }
        return "\(index + 1)/\(ids.count)"
    }
}

// MARK: - The cassette window

/// A cassette window with two reels and a tape lamp. The reels turn slowly while a station plays; with Reduce Motion they stay still and
/// the lamp fades instead. In scripted runs and while the notch is closed nothing is driven (no timeline runs).
struct RadioCassette: View {
    let state: RadioPlayState
    @ObservedObject private var nav = NotchNavigator.shared

    private var turning: Bool { RadioBoom.reelsTurn(state: state, reduceMotion: ScoutRuntime.reduceMotion) }
    private var fading: Bool { RadioBoom.lampFades(state: state, reduceMotion: ScoutRuntime.reduceMotion) }
    private var driven: Bool { RadioBoom.isDriven(state: state, reduceMotion: ScoutRuntime.reduceMotion, notchOpen: nav.isOpen, scripted: ScoutRuntime.isScripted) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !driven)) { timeline in
            let t = driven ? timeline.date.timeIntervalSinceReferenceDate : 0
            Canvas { ctx, size in
                RadioCassetteDrawing.draw(&ctx, size: size, angle: driven && turning ? RadioBoom.reelAngle(at: t) : 12,
                                          lamp: RadioBoom.lamp(for: state), lampLevel: driven && fading ? RadioBoom.lampLevel(at: t) : 1)
            }
        }
        .lookWell()
        .retroBevel(.sunken, cornerRadius: 3, depth: 1, face: Look.well(dark: Color(red: 0.07, green: 0.06, blue: 0.06)))   // the cassette window: dark in the dark preset, the light well in the light one
        .accessibilityHidden(true)
    }
}

enum RadioCassetteDrawing {
    static func draw(_ ctx: inout GraphicsContext, size: CGSize, angle: Double, lamp: RadioBoom.Lamp, lampLevel: Double) {
        guard size.width > 20, size.height > 10 else { return }
        let r = min(size.height * 0.31, size.width * 0.19)
        let left = CGPoint(x: size.width * 0.28, y: size.height * 0.47), right = CGPoint(x: size.width * 0.72, y: size.height * 0.47)
        // The tape runs along the bottom between the two packs.
        var tape = Path()
        tape.move(to: CGPoint(x: left.x, y: left.y + r * 1.04))
        tape.addLine(to: CGPoint(x: right.x, y: right.y + r * 0.88))
        ctx.stroke(tape, with: .color(Color(red: 0.34, green: 0.22, blue: 0.14)), lineWidth: max(1, r * 0.1))
        for (i, c) in [left, right].enumerated() {
            let pack = r * (i == 0 ? 1.06 : 0.9)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - pack, y: c.y - pack, width: pack * 2, height: pack * 2)), with: .color(Color(red: 0.22, green: 0.14, blue: 0.10)))
            let hub = r * 0.62
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - hub, y: c.y - hub, width: hub * 2, height: hub * 2)), with: .color(Color(red: 0.84, green: 0.84, blue: 0.80)))
            var teeth = Path()
            for k in 0..<6 {
                let a = (angle + Double(k) * 60) * .pi / 180
                teeth.move(to: CGPoint(x: c.x + cos(a) * hub * 0.30, y: c.y + sin(a) * hub * 0.30))
                teeth.addLine(to: CGPoint(x: c.x + cos(a) * hub * 0.86, y: c.y + sin(a) * hub * 0.86))
            }
            ctx.stroke(teeth, with: .color(Color(red: 0.16, green: 0.15, blue: 0.14)), style: StrokeStyle(lineWidth: max(1, r * 0.17), lineCap: .butt))
            let hole = hub * 0.30
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - hole, y: c.y - hole, width: hole * 2, height: hole * 2)), with: .color(Retro.Ink.screenBlack))
        }
        // The label strip between the reels' tops.
        ctx.fill(Path(roundedRect: CGRect(x: size.width * 0.38, y: 3, width: size.width * 0.24, height: 3), cornerRadius: 1), with: .color(Color.white.opacity(0.14)))
        // The tape lamp, top right.
        let lampCentre = CGPoint(x: size.width - 6, y: 6)
        switch lamp {
        case .off:
            ctx.fill(Path(ellipseIn: CGRect(x: lampCentre.x - 2.2, y: lampCentre.y - 2.2, width: 4.4, height: 4.4)), with: .color(Retro.Ink.ledGreen.opacity(0.16)))
        case .connecting:
            ctx.fill(Path(ellipseIn: CGRect(x: lampCentre.x - 2.2, y: lampCentre.y - 2.2, width: 4.4, height: 4.4)), with: .color(Retro.Ink.ledYellow.opacity(0.85)))
        case .playing:
            ctx.fill(Path(ellipseIn: CGRect(x: lampCentre.x - 5, y: lampCentre.y - 5, width: 10, height: 10)), with: .radialGradient(
                Gradient(colors: [Retro.Ink.ledGreen.opacity(0.45 * lampLevel), Retro.Ink.ledGreen.opacity(0)]), center: lampCentre, startRadius: 0, endRadius: 5))
            ctx.fill(Path(ellipseIn: CGRect(x: lampCentre.x - 2.2, y: lampCentre.y - 2.2, width: 4.4, height: 4.4)), with: .color(Retro.Ink.ledGreen.opacity(lampLevel)))
        }
        // A glint on the window's top edge.
        ctx.fill(Path(CGRect(x: 2, y: 1, width: size.width - 4, height: 1)), with: .color(Color.white.opacity(0.10)))
    }
}

// MARK: - The tuner scale

/// A tuner scale: one tick per station of the list shown (up to 24) and a red needle at the current station's place. A station that is
/// not in the list parks the needle at the left end, dim.
struct RadioTunerScale: View {
    let position: Double?
    let count: Int
    var label = ""

    var body: some View {
        Canvas { ctx, size in
            guard size.width > 24, size.height > 12 else { return }
            let amber = RadioBoom.amber
            let inset: CGFloat = 8
            let baseY = size.height - 11
            ctx.fill(Path(CGRect(x: inset - 2, y: baseY, width: size.width - 2 * inset + 4, height: 1)), with: .color(amber.opacity(0.55)))
            let n = RadioTuner.tickCount(count)
            var ticks = Path()
            for i in 0..<n {
                let p = n == 1 ? 0.5 : Double(i) / Double(n - 1)
                let x = ctx.snapped(RadioTuner.needleX(p, width: size.width, inset: inset))
                ticks.addRect(CGRect(x: x - 0.5, y: baseY - (i % 4 == 0 ? 9 : 6), width: 1, height: i % 4 == 0 ? 9 : 6))
            }
            ctx.fill(ticks, with: .color(amber.opacity(0.78)))
            // The needle (parked and dim when the station is not in this list).
            let x = ctx.snapped(RadioTuner.needleX(position ?? 0, width: size.width, inset: inset))
            let live = position != nil
            var needle = Path()
            needle.addRect(CGRect(x: x - 0.75, y: 2, width: 1.5, height: baseY + 3))
            ctx.fill(needle, with: .color(Retro.Ink.ledRed.opacity(live ? 1 : 0.35)))
            var cap = Path()
            cap.move(to: CGPoint(x: x - 3, y: 2)); cap.addLine(to: CGPoint(x: x + 3, y: 2)); cap.addLine(to: CGPoint(x: x, y: 5.5)); cap.closeSubpath()
            ctx.fill(cap, with: .color(Retro.Ink.ledRed.opacity(live ? 1 : 0.35)))
            // The place as numbers under the scale: "3/8" in the middle.
            let text = live ? label : ""
            if !text.isEmpty {
                let w = RetroPixelLayout.width(text, pixel: 1)
                ctx.translateBy(x: ctx.snapped((size.width - w) / 2), y: ctx.snapped(size.height - 9))
                var pixels = Path()
                for (c, r) in RetroPixelLayout.litPixels(RetroPixelLayout.columns(text)) { pixels.addRect(CGRect(x: CGFloat(c), y: CGFloat(r), width: 1, height: 1)) }
                ctx.fill(pixels, with: .color(amber))
            }
        }
        .lookWell()
        .retroBevel(.sunken, cornerRadius: 3, depth: 1, face: Look.well(dark: Color(red: 0.075, green: 0.055, blue: 0.03)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(position == nil ? Text("Tuner") : Text("Tuner, station \(label)"))
    }
}

// MARK: - The LCD

/// The boombox's LCD: the station's name in pixel letters (the system font for letters the dot font lacks), and under it the song, or what
/// is happening, with the true marks at the right (LIVE, codec and bitrate).
struct RadioLCD: View {
    let station: RadioStation
    let state: RadioPlayState
    let song: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            RadioLCDLine(text: station.name, height: 14)
            HStack(spacing: 6) {
                detail.frame(maxWidth: .infinity, alignment: .leading)
                marks
            }
            .frame(height: 12)
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lookWell()
        .retroBevel(.sunken, cornerRadius: 4, depth: 1.5, face: RadioBoom.lcdFace)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var marks: some View {
        HStack(spacing: 6) {
            ForEach(RadioBoom.marks(station: station, state: state), id: \.self) { mark in
                if mark == "LIVE" { RadioLiveLamp() } else { RetroPixelText(mark, pixel: 1.25, color: RadioBoom.amber) }
            }
        }
        .fixedSize()
    }

    @ViewBuilder private var detail: some View {
        switch state {
        case .failed(let line):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(RadioBoom.orange)
                Text(line).font(.system(size: 10.5)).foregroundStyle(RadioBoom.orange).lineLimit(1)
            }
        case .loading:
            RetroPixelText(pixelLabel("CONNECTING"), pixel: 1.25, color: RadioBoom.yellow)
        case .paused:
            RetroPixelText(pixelLabel("PAUSED"), pixel: 1.25, color: RadioBoom.yellow)
        case .idle:
            RetroPixelText(pixelLabel("READY"), pixel: 1.25, color: RadioBoom.green.opacity(0.75))
        case .playing:
            if let song {
                HStack(spacing: 4) {
                    Image(systemName: "music.note").font(.system(size: 9, weight: .bold)).foregroundStyle(Retro.Ink.magenta)
                    Text(song).font(.system(size: 10.5)).foregroundStyle(RadioBoom.green).lineLimit(1)
                }
            } else {
                (station.place.isEmpty ? Text("Live") : Text(verbatim: station.place)).font(.system(size: 10.5)).foregroundStyle(RadioBoom.green.opacity(0.85)).lineLimit(1)
            }
        }
    }

    private var accessibilityText: String { RadioBoom.speech(station: station, state: state, song: song) }
}

// MARK: - The boombox

/// The boombox's face: speaker grille, cassette window, LCD, tuner scale, keys (play or pause, stop), volume fader, speaker grille.
/// A plain view of values and closures, so a gallery picture and the live bar are the same drawing.
struct RadioBoomboxFace: View {
    let station: RadioStation
    let state: RadioPlayState
    let song: String?
    @Binding var volume: Double
    /// Muted (the small speaker key at the volume's left end toggles it).
    var muted = false
    var onMute: () -> Void = {}
    /// The stations shown in the list now; the needle sits at this station's place among them.
    var stationIDs: [String] = []
    var onToggle: () -> Void
    var onStop: () -> Void

    static let height: CGFloat = 56

    private var running: Bool { state == .playing || state == .loading }
    private var isActive: Bool { state.isActive }

    var body: some View {
        if Retro.is8bit { boombox } else { minimalBar }
    }

    /// The small speaker at the volume's left end is the mute key: crossed out (red) while muted.
    private func muteKey(size: CGFloat) -> some View {
        Button(action: onMute) {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.fill").font(.system(size: size, weight: .semibold))
                .foregroundStyle(muted ? Color(red: 1.0, green: 0.38, blue: 0.32) : (Retro.is8bit ? Look.osd.opacity(0.62) : NotchInk.secondary))
                .frame(width: size + 6, height: size + 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(muted ? String(localized: "Unmute") : String(localized: "Mute"))
        .radioRect("mute")
    }

    /// The minimal look: a clean player. The station and what is happening as two lines of text, play or pause and stop as plain buttons, and a
    /// plain volume slider (no cassette, no LCD, no tuner scale).
    private var minimalBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(station.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    ForEach(RadioBoom.marks(station: station, state: state), id: \.self) { mark in
                        if mark == "LIVE" { MiniLamp(text: String(localized: "Live"), color: Color(red: 1.0, green: 0.35, blue: 0.30)) } else {
                            Text(mark).font(.system(size: 10, design: .monospaced)).foregroundStyle(NotchInk.tertiary).lineLimit(1).fixedSize()
                        }
                    }
                }
                miniDetail.frame(height: 14, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(RadioBoom.speech(station: station, state: state, song: song))
            HStack(spacing: 6) {
                DeckKey(symbol: running ? "pause.fill" : "play.fill", latched: state == .playing || state == .loading, help: playHelp, action: onToggle)
                    .radioRect("play")
                DeckKey(symbol: "stop.fill", help: String(localized: "Stop"), action: onStop)
                    .disabled(!isActive).radioRect("stop")
            }
            HStack(spacing: 5) {
                muteKey(size: 9)
                MiniSlider(value: $volume, label: "Volume").radioRect("volume")
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 9))
            }
            .foregroundStyle(NotchInk.secondary)
            .frame(width: 128)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(height: Self.height)
        .miniCard(radius: 10, fill: Look.pair(dark: Color(white: 0.115), light: Color.black.opacity(0.06)))
    }

    @ViewBuilder private var miniDetail: some View {
        switch state {
        case .failed(let line):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(Retro.Ink.orange)
                Text(line).font(.system(size: 11)).foregroundStyle(Retro.Ink.orange).lineLimit(1)
            }
        case .loading: Text("Connecting…").font(.system(size: 11)).foregroundStyle(NotchInk.secondary).lineLimit(1)
        case .paused: Text("Paused").font(.system(size: 11)).foregroundStyle(NotchInk.secondary).lineLimit(1)
        case .idle: Text("Ready").font(.system(size: 11)).foregroundStyle(NotchInk.secondary).lineLimit(1)
        case .playing:
            if let song {
                HStack(spacing: 4) {
                    Image(systemName: "music.note").font(.system(size: 9, weight: .semibold)).foregroundStyle(NotchInk.secondary)
                    Text(song).font(.system(size: 11)).foregroundStyle(NotchInk.secondary).lineLimit(1)
                }
            } else {
                (station.place.isEmpty ? Text("Live") : Text(verbatim: station.place)).font(.system(size: 11)).foregroundStyle(NotchInk.secondary).lineLimit(1)
            }
        }
    }

    private var boombox: some View {
        // The tuner scale gives way first when the view is narrow; the name's LCD never gets squeezed for it.
        ViewThatFits(in: .horizontal) {
            row(tuner: true)
            row(tuner: false)
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .frame(height: Self.height)
        .lookWell()   // the deck's plastic follows the preset (charcoal with light inks, or light with dark inks), whatever scheme the window is in
        .retroBevel(.raised, cornerRadius: 8, depth: 1.5, face: RadioBoom.deckBody)
    }

    private func row(tuner: Bool) -> some View {
        HStack(spacing: 8) {
            CRTGrille(slits: 9, plastic: RadioBoom.deckBody).frame(width: 14)
            RadioCassette(state: state).frame(width: 78, height: 36)
            RadioLCD(station: station, state: state, song: song)
                .frame(minWidth: 200, idealWidth: 250)
                .layoutPriority(2)
            if tuner {
                RadioTunerScale(position: RadioTuner.position(of: station.id, in: stationIDs), count: stationIDs.count,
                                label: RadioTuner.placeText(of: station.id, in: stationIDs) ?? "")
                    .frame(minWidth: 110, idealWidth: 150, maxWidth: 180).frame(height: 36)
            }
            HStack(spacing: 5) {
                DeckKey(symbol: running ? "pause.fill" : "play.fill", latched: state == .playing || state == .loading,
                        size: CGSize(width: 16, height: 14), help: playHelp, action: onToggle)
                    .radioRect("play")
                DeckKey(symbol: "stop.fill", size: CGSize(width: 16, height: 14), help: String(localized: "Stop"), action: onStop)
                    .disabled(!isActive).radioRect("stop")
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    muteKey(size: 8)
                    Spacer(minLength: 0)
                    RetroPixelText("VOL", pixel: 1, color: Look.osd.opacity(0.8))
                    Spacer(minLength: 0)
                    Image(systemName: "speaker.wave.3.fill").font(.system(size: 8))
                }
                .foregroundStyle(Look.osd.opacity(0.62))
                RetroFader(value: $volume, tint: Retro.Ink.teal, label: String(localized: "Volume"), light: Look.isLight)
                    .radioRect("volume")
            }
            .frame(width: 96)
            CRTGrille(slits: 9, plastic: RadioBoom.deckBody).frame(width: 14)
        }
    }

    private var playHelp: String {
        switch state {
        case .playing, .loading: String(localized: "Pause")
        case .paused: String(localized: "Resume")
        case .idle: String(localized: "Play")
        case .failed: String(localized: "Try again")
        }
    }
}

/// The Radio tab's player bar: the boombox, shown while a station is loaded (playing, paused, ready or failed).
struct RadioPlayerBar: View {
    @ObservedObject var service: RadioService
    @ObservedObject var store: RadioStore
    /// The stations shown in the list now (the tuner's needle sits at the current station's place among them).
    var stations: [RadioStation] = []

    var body: some View {
        if let station = service.station {
            RadioBoomboxFace(station: station, state: service.state, song: service.songTitle,
                             volume: Binding(get: { service.muted ? 0 : service.volume }, set: { service.setVolume($0) }),
                             muted: service.muted, onMute: { service.toggleMute() },
                             stationIDs: stations.map(\.id),
                             onToggle: { service.togglePause() }, onStop: { service.stop() })
        }
    }
}

// MARK: - Where the controls are

/// Where the boombox's controls are, in the Radio view's own coordinates (the self-test clicks them by name).
struct RadioRectsKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

extension View {
    func radioRect(_ name: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: RadioRectsKey.self, value: [name: proxy.frame(in: .named("radioView"))])
        })
    }
}
