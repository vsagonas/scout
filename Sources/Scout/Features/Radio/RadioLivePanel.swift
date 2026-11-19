import Combine
import SwiftUI

// live.radio: the dashboard panel that shows while a station plays (or is paused, so it can be resumed): the station's name,
// the song when the stream sends one, a small live mark, pause and stop. A click anywhere else opens the Radio tab.
// Not live after Stop, after a failed stream, or after a relaunch (the last station is shown ready in the tab, not here).

struct RadioLiveSnapshot: Equatable {
    var station = ""
    var place = ""
    var quality = ""
    var song: String?
    var state: RadioPlayState = .idle
    var volume: Double = 0.7
    var muted = false

    @MainActor static func of(_ service: RadioService) -> RadioLiveSnapshot {
        guard let s = service.station else { return RadioLiveSnapshot() }
        return RadioLiveSnapshot(station: s.name, place: s.place, quality: s.quality, song: service.songTitle, state: service.state,
                                 volume: service.volume, muted: service.muted)
    }
}

/// What the buttons do; the real ones drive `RadioService`.
struct RadioLiveActions {
    var togglePause: () -> Void
    var stop: () -> Void
    var setVolume: (Double) -> Void = { _ in }
    var toggleMute: () -> Void = {}
}

@MainActor
final class RadioLivePanel: LiveDriven {
    let id = "live.radio"
    let title = String(localized: "Radio")
    let symbol = "radio"
    let priority = 40
    let span = 4
    let expandTo: WorkspaceKind? = .radio

    let feed: LiveFeed<RadioLiveSnapshot>
    let actions: RadioLiveActions

    var changes: AnyPublisher<Void, Never> { feed.changes }
    var isLive: Bool { feed.value.state.isActive }

    init(feed: LiveFeed<RadioLiveSnapshot>, actions: RadioLiveActions) {
        self.feed = feed
        self.actions = actions
    }

    /// The panel that follows a service (the shared one by default).
    static func live(service: RadioService? = nil) -> RadioLivePanel {
        let service = service ?? RadioService.shared
        let feed = LiveFeed<RadioLiveSnapshot>(read: { RadioLiveSnapshot.of(service) }, triggers: [service.liveTrigger])
        return RadioLivePanel(feed: feed, actions: RadioLiveActions(togglePause: { service.togglePause() }, stop: { service.stop() },
                                                                    setVolume: { service.setVolume($0) }, toggleMute: { service.toggleMute() }))
    }

    func makeView() -> AnyView { AnyView(RadioLiveView(feed: feed, actions: actions)) }
}

// MARK: - View

/// The dashboard panel as a small cassette deck (our own drawing): the station on a mini LCD, the two reels, play or pause and stop
/// as small keys, a LIVE light while it plays. It paints its whole cell and keeps its content well away from the rounded corners.
struct RadioLiveView: View {
    @ObservedObject var feed: LiveFeed<RadioLiveSnapshot>
    var actions: RadioLiveActions
    @Environment(\.notchContentSize) private var contentSize

    /// When the deck is the last panel on the right, its body reaches right until it stands as far from the island's right wall as from the
    /// island's bottom edge: the same border right and down, the Agent TV's rule mirrored.
    /// Measured in the content's own space.
    static func reach(panel me: CGRect, content: CGSize) -> CGFloat {
        let right = content.width - AgentNookPanelView.islandShoulder - me.maxX, bottom = content.height - (me.maxY - bodyInset.bottom)
        guard content.width > 0, right >= 0, right < 80, bottom > 0 else { return 0 }
        return max(0, right - bodyInset.trailing - bottom)
    }

    /// The deck's top stays in line with the panels beside it;
    /// its bottom edge stands where the Agent TV's does, 8 pt over the island's bottom edge, and the reach above
    /// gives it the same 8 pt on the right, so both corners have the TV's border.
    /// Measured at the real 180 pt notch: the TV's body ends at 171.5 of 179.5 pt.
    static let bodyInset = EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0)

    /// Self-tests: what the deck measured last (its frame in the content's space, the content's size, the reach).
    nonisolated(unsafe) static var lastMeasure: (panel: CGRect, content: CGSize, reach: CGFloat)?

    var body: some View {
        if Retro.is8bit { deck } else { nowPlayingRow }
    }

    /// The minimal look: a compact now-playing row. The station's name and what is happening (the song, the place, the state) on the left,
    /// pause or resume and stop as plain buttons on the right, over a quiet "Radio" title with a short fact (Live, Paused, the codec).
    private var nowPlayingRow: some View {
        let s = feed.value
        let running = s.state == .playing || s.state == .loading
        // The station on top, the "Radio" title with its Live lamp at the bottom (as the 8-bit deck, the owner 2026-11-18).
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.station).font(.system(size: 13, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    miniLine(s)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                DeckKey(symbol: running ? "pause.fill" : "play.fill", latched: s.state == .playing || s.state == .loading, compact: true,
                        size: CGSize(width: 13, height: 14), help: running ? String(localized: "Pause") : String(localized: "Resume"), action: actions.togglePause)
                    .liveControl()
                DeckKey(symbol: "stop.fill", compact: true, size: CGSize(width: 13, height: 14), help: String(localized: "Stop"), action: actions.stop)
                    .liveControl()
            }
            volumeControl(s).frame(maxWidth: .infinity, alignment: .trailing)
            Spacer(minLength: 0)
            Dash90Title("Radio", symbol: "radio", tint: Retro.Ink.magenta) {
                if s.state == .playing { MiniLamp(text: String(localized: "Live"), color: Color(red: 1.0, green: 0.35, blue: 0.30)) }
                else if s.state == .paused { LiveRetroFact(text: String(localized: "Paused")) }
                else if !s.quality.isEmpty { LiveRetroFact(text: s.quality) }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A very small mute key and volume bar (the owner, 2026-11-18): the speaker crossed out while muted; the bar unmutes when moved.
    private func volumeControl(_ s: RadioLiveSnapshot) -> some View {
        HStack(spacing: 4) {
            Button(action: actions.toggleMute) {
                Image(systemName: s.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(s.muted ? Color(red: 1.0, green: 0.38, blue: 0.32) : NotchInk.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(s.muted ? String(localized: "Unmute") : String(localized: "Mute"))
            .liveControl()
            MiniSlider(value: Binding(get: { s.muted ? 0 : s.volume }, set: { actions.setVolume($0) }), label: "Volume")
                .frame(width: 48)
                .liveControl()
        }
    }

    @ViewBuilder private func miniLine(_ s: RadioLiveSnapshot) -> some View {
        if let song = s.song, s.state != .loading {
            HStack(spacing: 3) {
                Image(systemName: "music.note").font(.system(size: 9, weight: .semibold))
                Text(song).font(.system(size: 11)).lineLimit(1)
            }
            .foregroundStyle(NotchInk.secondary)
        } else if s.state == .loading {
            Text("Connecting…").font(.system(size: 11)).foregroundStyle(NotchInk.secondary)
        } else {
            (s.place.isEmpty ? Text("On air") : Text(verbatim: s.place)).font(.system(size: 11)).foregroundStyle(NotchInk.secondary).lineLimit(1)
        }
    }

    private var deck: some View {
        GeometryReader { geo in
            let me = geo.frame(in: .named("notchContent"))
            let reach = contentSize.map { Self.reach(panel: me, content: $0) } ?? 0
            let _ = { if let c = contentSize { Self.lastMeasure = (me, c, reach) } }()
            deckBody.frame(width: geo.size.width + reach, height: geo.size.height - Self.bodyInset.top - Self.bodyInset.bottom, alignment: .topLeading)
                .offset(y: Self.bodyInset.top)
        }
    }

    private var deckBody: some View {
        let s = feed.value
        let running = s.state == .playing || s.state == .loading
        // What plays on top, the RADIO · codec · LIVE labels at the bottom
        return VStack(alignment: .leading, spacing: 0) {
            RadioMiniLCD(snapshot: s)
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                RadioCassette(state: s.state).frame(minWidth: 46, idealWidth: 62, maxWidth: 70).frame(height: 32)
                Spacer(minLength: 0)
                volumeControl(s)
                DeckKey(symbol: running ? "pause.fill" : "play.fill", latched: s.state == .playing || s.state == .loading, compact: true,
                        size: CGSize(width: 13, height: 14), help: running ? String(localized: "Pause") : String(localized: "Resume"), action: actions.togglePause)
                    .liveControl()
                DeckKey(symbol: "stop.fill", compact: true, size: CGSize(width: 13, height: 14), help: String(localized: "Stop"), action: actions.stop)
                    .liveControl()
            }
            Spacer(minLength: 4)
            ViewThatFits(in: .horizontal) {
                header(s, quality: true)
                header(s, quality: false)
            }
            .frame(height: 12)
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .lookWell()   // colours only: the deck's plastic follows the preset, so its inks do too
        .background(RadioDeckBody())
    }

    /// The bottom line: the name of the thing, the stream's codec and bitrate (when there is room), and the LIVE light while it plays.
    private func header(_ s: RadioLiveSnapshot, quality: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "radio").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Retro.Ink.magenta)
            RetroPixelText(pixelLabel("RADIO"), pixel: 1.25, color: Look.osd.opacity(0.85))
            Spacer(minLength: 4)
            if quality, !s.quality.isEmpty { RetroPixelText(s.quality.uppercased(), pixel: 1, color: RadioBoom.amber.opacity(0.9)) }
            if s.state == .playing { RadioLiveLamp() } else if s.state == .paused { RetroPixelText(pixelLabel("PAUSED"), pixel: 1.25, color: RadioBoom.yellow) }
        }
    }
}

/// The mini LCD: the station's name, and the song when the stream sends one (else what is happening, or where the station is).
struct RadioMiniLCD: View {
    let snapshot: RadioLiveSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            RadioLCDLine(text: snapshot.station, sizes: [2.5, 2, 1.5], height: 18)
            Group {
                if let song = snapshot.song, snapshot.state != .loading {
                    HStack(spacing: 3) {
                        Image(systemName: "music.note").font(.system(size: 8, weight: .bold)).foregroundStyle(Retro.Ink.magenta)
                        Text(song).font(.system(size: 10)).foregroundStyle(RadioBoom.green).lineLimit(1)
                    }
                } else if snapshot.state == .loading {
                    RetroPixelText(pixelLabel("CONNECTING"), pixel: 1.25, color: RadioBoom.yellow)
                } else {
                    (snapshot.place.isEmpty ? Text("On air") : Text(verbatim: snapshot.place)).font(.system(size: 10)).foregroundStyle(RadioBoom.green.opacity(0.85)).lineLimit(1)
                }
            }
            .frame(height: 11, alignment: .leading)
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lookWell()
        .retroBevel(.sunken, cornerRadius: 4, depth: 1.25, face: RadioBoom.lcdFace)
    }
}

/// The deck's body: one piece of dark plastic with the Agent TV's big round corners on all four sides, so it sits in the island's
/// corner as if made for it,
/// with a raised inner panel set a few points in.
struct RadioDeckBody: View {
    static let radius = CRTSetLayout.glassRadius(compact: false)

    var body: some View {
        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .fill(LinearGradient(colors: Look.isLight ? [Retro.shade(RadioBoom.deckBody, 0.04), Retro.shade(RadioBoom.deckBody, -0.07)]
                                                     : [Retro.shade(RadioBoom.body, -0.25), Retro.shade(RadioBoom.body, -0.55)], startPoint: .top, endPoint: .bottom))
            .overlay(Color.clear.retroBevel(.raised, cornerRadius: Self.radius - 4, depth: 1.25, face: RadioBoom.deckBody).padding(4))
    }
}
