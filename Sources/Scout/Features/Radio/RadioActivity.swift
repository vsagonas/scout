import AppKit
import Combine
import SwiftUI

// The radio in the CLOSED notch while it plays.
// Left wing: the station's own tile. Right wing: for a few seconds after a station starts or the
// song changes, the station's name and (when the station sends it and Settings allow it) the song, exactly as wide as those words; then the
// small sound bars, so the notch shrinks back. A click opens the Radio tab. Settings › Radio › "Show the radio in the notch while it plays"
// is the same switch as Settings › Live Activities › Radio (`LiveActivityKind.radio.enabledKey`, on by default).

enum RadioPrefs {
    /// Settings › Radio › "Show the song title when the station sends it" (on by default).
    static let showSongKey = "radio.showSong"
    static var showSong: Bool { Pref.bool(showSongKey, true) }
}

@MainActor
final class RadioNotchPresenter {
    static let shared = RadioNotchPresenter()
    static let activityID = "radio"

    private var bag = Set<AnyCancellable>()
    private weak var service: RadioService?

    /// Watches the radio (never in scripted runs: galleries and self-tests post their own).
    func start(service given: RadioService? = nil) {
        guard self.service == nil, !ScoutRuntime.isScripted else { return }
        let service = given ?? RadioService.shared
        self.service = service
        service.$state.combineLatest(service.$station).receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }.store(in: &bag)
    }

    /// Shows or takes away the activity, also right after the switch changes in Settings.
    func refresh() {
        guard let service else { return }
        Self.apply(service: service, center: .shared)
    }

    /// Shown while a station plays or connects, with the switch on.
    static func shouldShow(state: RadioPlayState, hasStation: Bool, enabled: Bool) -> Bool {
        enabled && hasStation && (state == .playing || state == .loading)
    }

    static func apply(service: RadioService, center: LiveActivityCenter) {
        if shouldShow(state: service.state, hasStation: service.station != nil, enabled: center.isEnabled(.radio)) {
            if !center.activities.contains(where: { $0.id == activityID }) { center.show(make(service: service)) }   // the views follow the service by themselves
        } else {
            center.dismiss(id: activityID)
        }
    }

    static func make(service: RadioService, alwaysShown: Bool = false) -> LiveActivity {
        LiveActivity(id: activityID, kind: .radio, onTap: { NotchNavigator.shared.open(.radio) }) {
            RadioWingLeading(service: service)
        } trailing: {
            RadioWingTrailing(service: service, alwaysShown: alwaysShown)
        }
        .withDetail { RadioWingDetail(service: service) }
    }

    /// A playing sample (galleries and the `activity.demo` command): never a real station or sound.
    static func sample() -> LiveActivity {
        let service = RadioService(engine: RadioFakeEngine(), store: RadioFixtures.sampleStore())
        service.showSample(station: RadioFixtures.jazz, state: .playing, title: "Nils Frahm · Says")
        return make(service: service, alwaysShown: true)
    }
}

/// The station's tile, as in the Radio tab's lists.
struct RadioWingLeading: View {
    @ObservedObject var service: RadioService

    var body: some View {
        RadioMonogram(name: service.station?.name ?? "", size: 20)
    }
}

/// The station and the song for a few seconds, then the sound bars.
struct RadioWingTrailing: View {
    @ObservedObject var service: RadioService
    /// Pictures and tests: keep the words on.
    var alwaysShown = false
    @AppStorage(RadioPrefs.showSongKey) private var showSong = true
    @State private var showing: Bool
    @State private var shownKey = ""

    /// The station and song this wing last revealed: the wing is built anew each time the notch closes, and only something new shows again
    /// (as the agents' readout, the owner 2026-11-18).
    static var lastRevealed = ""

    init(service: RadioService, alwaysShown: Bool = false) {
        self.service = service
        self.alwaysShown = alwaysShown
        let key = (service.station?.name ?? "") + "|" + ((RadioPrefs.showSong ? service.songTitle : nil) ?? "")
        _showing = State(initialValue: ScoutRuntime.isGallery || key != Self.lastRevealed)
    }

    static let showSeconds: Double = 8
    static let maxWidth: CGFloat = 300
    static let nameFont = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
    static let songFont = NSFont.systemFont(ofSize: 9.5, weight: .regular)

    /// Exactly as wide as the longer of the two lines (no empty space), `maxWidth` at most (past it a line ends with "…").
    static func width(station: String, song: String?) -> CGFloat {
        func measure(_ text: String, _ font: NSFont) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1 }
        return min(maxWidth, max(measure(station, nameFont), song.map { measure($0, songFont) } ?? 0))
    }

    var body: some View {
        let name = service.station?.name ?? ""
        let song = showSong ? service.songTitle : nil
        let key = name + "|" + (song ?? "")
        ZStack {
            if showing || alwaysShown {
                Self.readout(name: name, song: song)
            } else {
                MediaBars(isPlaying: service.state == .playing, height: 14).frame(width: 22)
            }
        }
        .onAppear { reveal(key) }
        .onChange(of: key) { _, new in reveal(new) }
    }

    /// The two lines (one when there is no song).
    static func readout(name: String, song: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: name).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1).truncationMode(.tail)
            if let song {
                Text(verbatim: song).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.75)).lineLimit(1).truncationMode(.tail)
            }
        }
        .frame(width: width(station: name, song: song), alignment: .leading)
    }

    /// A new station or song shows for `showSeconds`, then steps aside (the island's spring; a fade under Reduce Motion).
    private func reveal(_ key: String) {
        shownKey = key
        if key == Self.lastRevealed, !ScoutRuntime.isGallery { showing = false; return }   // already said: a closed-again notch stays quiet
        Self.lastRevealed = key
        withAnimation(ScoutRuntime.reduceMotion ? nil : Theme.quick) { showing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showSeconds) {
            guard shownKey == key else { return }
            withAnimation(ScoutRuntime.reduceMotion ? .easeOut(duration: 0.25) : Theme.spring) { showing = false }
        }
    }
}

/// What the pointer resting on the closed notch shows: the station and the song.
struct RadioWingDetail: View {
    @ObservedObject var service: RadioService

    var body: some View {
        VStack(spacing: 1) {
            Text(verbatim: service.station?.name ?? "").font(.system(size: 12, weight: .semibold)).lineLimit(1)
            if let song = service.songTitle {
                Text(verbatim: song).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: 250)
    }
}
