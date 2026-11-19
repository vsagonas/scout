import AVFoundation
import Combine
import Foundation

// Playing. `RadioService` is the one place that knows what is playing (one station at a time, kept going when the notch
// closes); the sound itself is behind the small `RadioEngine` protocol so tests and galleries use a fake and the real
// AVPlayer never starts in a scripted run. A stream that fails says so and stops: nothing retries by itself.

enum RadioPlayState: Equatable {
    case idle                   // nothing playing (a station may still be shown ready)
    case loading                // connecting or buffering
    case playing
    case paused
    case failed(String)         // the line to show

    /// Playing, connecting or paused: the live panel is on the dashboard.
    var isActive: Bool {
        switch self {
        case .loading, .playing, .paused: true
        case .idle, .failed: false
        }
    }
}

enum RadioEngineEvent: Equatable {
    case buffering
    case playing
    case paused
    case failed(String)
    case ended
    case title(String?)
}

@MainActor
protocol RadioEngine: AnyObject {
    var events: AnyPublisher<RadioEngineEvent, Never> { get }
    func play(_ url: URL)
    func pause()
    func resume()
    func stop()
    func setVolume(_ volume: Float)
}

// MARK: - The service

@MainActor
final class RadioService: ObservableObject {
    /// The real one: AVPlayer, the saved store. In a scripted run the engine is a fake and the store keeps nothing on disk.
    static let shared: RadioService = {
        let engine: RadioEngine = ScoutRuntime.isScripted ? RadioFakeEngine() : RadioAVEngine()
        return RadioService(engine: engine, store: .shared, report: { RadioBrowserDirectory.shared.reportPlay($0) })
    }()

    static let volumeKey = "radio.volume"
    static let resumeKey = "radio.resume"
    /// True while a station plays; a pause or a stop by the person (or a failure) clears it. Scout quitting leaves it as it was, so the next
    /// launch knows the radio was still on.
    static let wasPlayingKey = "radio.wasPlaying"
    /// Settings › Radio › "Stop the radio after": minutes, 0 = never (the default).
    static let sleepKey = "radio.sleepMinutes"
    static let sleepChoices = [0, 15, 30, 60, 120]

    /// The station shown in the Radio tab's bar: the one playing, or the last one (ready, not playing).
    @Published private(set) var station: RadioStation?
    @Published private(set) var state: RadioPlayState = .idle
    @Published private(set) var songTitle: String?
    @Published private(set) var volume: Double
    /// Muted from the small speaker key: the stream keeps
    /// playing silently; moving the volume unmutes.
    @Published private(set) var muted = false

    let store: RadioStore
    private let engine: RadioEngine
    private let report: (RadioStation) -> Void
    private let startTimeout: TimeInterval
    private var bag = Set<AnyCancellable>()
    private var timeout: Task<Void, Never>?
    private var reported = false   // the directory hears of a listen once per start
    private var sleepTask: Task<Void, Never>?
    /// Seconds in one minute of the sleep timer (the self-test makes it short).
    var sleepUnit: TimeInterval = 60

    init(engine: RadioEngine, store: RadioStore, report: @escaping (RadioStation) -> Void = { _ in }, startTimeout: TimeInterval = 25) {
        self.engine = engine
        self.store = store
        self.report = report
        self.startTimeout = startTimeout
        let saved = UserDefaults.standard.object(forKey: Self.volumeKey) as? Double ?? 0.7
        volume = min(1, max(0, saved))
        station = store.last
        engine.setVolume(Float(volume))
        engine.events.receive(on: DispatchQueue.main).sink { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }.store(in: &bag)
    }

    var isPlaying: Bool { state == .playing }
    var isActive: Bool { state.isActive }

    /// "Play the last station again when Scout opens",
    /// and only when the radio was still playing as Scout quit: a radio the person stopped stays stopped.
    static var resumeOnLaunch: Bool { Pref.bool(resumeKey, true) && UserDefaults.standard.bool(forKey: wasPlayingKey) }
    static var sleepMinutes: Int { max(0, Pref.int(sleepKey, 0)) }

    // MARK: Controls

    /// Starts a station (or, if it is the paused one, goes on). Only one plays at a time.
    func play(_ station: RadioStation) {
        guard let url = station.streamURL else {
            fail(String(localized: "This station has no address to play."))
            return
        }
        if self.station?.id == station.id, state == .paused {
            resume()
            return
        }
        cancelTimeout()
        self.station = station
        songTitle = nil
        reported = false
        state = .loading
        store.recordPlayed(station)
        engine.play(url)
        armTimeout()
        armSleep()
    }

    func pause() {
        guard state == .playing || state == .loading else { return }
        cancelTimeout()
        cancelSleep()
        engine.pause()
        state = .paused
        UserDefaults.standard.set(false, forKey: Self.wasPlayingKey)
    }

    func resume() {
        guard state == .paused else { return }
        state = .loading
        engine.resume()
        armTimeout()
        armSleep()
    }

    func togglePause() {
        switch state {
        case .playing, .loading: pause()
        case .paused: resume()
        case .idle, .failed: if let station { play(station) }   // the person asked: a new start, once
        }
    }

    /// Stops. The station stays shown, ready.
    func stop() {
        cancelTimeout()
        cancelSleep()
        engine.stop()
        songTitle = nil
        if state != .idle { state = .idle }
        UserDefaults.standard.set(false, forKey: Self.wasPlayingKey)
    }

    /// "Stop the radio after": counts from the moment a station starts (or goes on after a pause); a pause or a stop cancels it.
    func armSleep() {
        cancelSleep()
        let minutes = Self.sleepMinutes
        guard minutes > 0 else { return }
        let seconds = Double(minutes) * sleepUnit
        sleepTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.state.isActive else { return }
            self.stop()
        }
    }

    private func cancelSleep() {
        sleepTask?.cancel()
        sleepTask = nil
    }

    /// True while the sleep timer runs (the self-test reads it).
    var sleepArmed: Bool { sleepTask != nil }

    func setVolume(_ value: Double) {
        let v = min(1, max(0, value))
        if muted { muted = false }
        guard v != volume else { engine.setVolume(Float(v)); return }
        volume = v
        engine.setVolume(Float(v))
        UserDefaults.standard.set(v, forKey: Self.volumeKey)
    }

    func toggleMute() {
        muted.toggle()
        engine.setVolume(muted ? 0 : Float(volume))
    }

    /// At launch: the last station again when "Play the last station again when Scout opens" is on and it was playing as Scout quit.
    func resumeIfWanted(scripted: Bool = ScoutRuntime.isScripted) {
        guard Self.resumeOnLaunch, !scripted, state == .idle, let station else { return }
        play(station)
    }

    /// True when no real sound can start (scripted runs).
    var usesFakeEngine: Bool { engine is RadioFakeEngine }

    // MARK: What the engine says

    private func handle(_ event: RadioEngineEvent) {
        switch event {
        case .buffering:
            guard state == .playing else { return }   // already loading, paused or stopped: nothing changes
            state = .loading
            armTimeout()
        case .playing:
            guard state == .loading || state == .playing else { return }
            cancelTimeout()
            state = .playing
            UserDefaults.standard.set(true, forKey: Self.wasPlayingKey)
            if !reported, let station {
                reported = true
                report(station)
            }
        case .paused:
            // Our own pause or stop already set the state. Anything else that pauses the sound (the system) shows as paused.
            guard state == .playing else { return }
            cancelTimeout()
            state = .paused
        case .failed(let line):
            guard state != .idle else { return }
            fail(line)
        case .ended:
            guard state.isActive else { return }
            fail(String(localized: "The station stopped broadcasting."))
        case .title(let text):
            guard state.isActive else { return }
            let clean = Self.cleanTitle(text, stationName: station?.name)
            if songTitle != clean { songTitle = clean }
        }
    }

    /// Says so and stops. Never plays again by itself.
    private func fail(_ line: String) {
        cancelTimeout()
        cancelSleep()
        UserDefaults.standard.set(false, forKey: Self.wasPlayingKey)
        engine.stop()
        songTitle = nil
        state = .failed(line)
    }

    private func armTimeout() {
        cancelTimeout()
        let seconds = startTimeout
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.timeoutFired()
        }
    }

    private func cancelTimeout() {
        timeout?.cancel()
        timeout = nil
    }

    private func timeoutFired() {
        guard state == .loading else { return }
        fail(String(localized: "This station isn't answering."))
    }

    /// The song line the stream sent: one line, no empty or station-name-only titles.
    static func cleanTitle(_ raw: String?, stationName: String?) -> String? {
        guard let raw else { return nil }
        let line = raw.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, line.count > 1 else { return nil }
        if let stationName, RadioText.fold(line) == RadioText.fold(stationName) { return nil }
        return String(line.prefix(140))
    }

    // MARK: Gallery and tests

    /// Shows a state without any engine (galleries only).
    func showSample(station: RadioStation?, state: RadioPlayState, title: String? = nil) {
        self.station = station
        self.state = state
        songTitle = title
    }
}

// MARK: - The real engine

/// AVPlayer. Never created or started in a scripted run (the service gets a fake there, and `play` refuses anyway).
@MainActor
final class RadioAVEngine: NSObject, RadioEngine, AVPlayerItemMetadataOutputPushDelegate {
    private let subject = PassthroughSubject<RadioEngineEvent, Never>()
    private var player: AVPlayer?
    private var observers: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var volume: Float = 0.7
    private var generation = 0   // a late callback of a stream that was replaced is ignored

    var events: AnyPublisher<RadioEngineEvent, Never> { subject.eraseToAnyPublisher() }

    /// False until a stream was really started (a scripted run never gets one).
    var hasPlayer: Bool { player != nil }

    func play(_ url: URL) {
        guard !ScoutRuntime.isScripted else { subject.send(.failed("Playing is off in scripted runs.")); return }
        teardown()
        generation += 1
        let mine = generation
        let item = AVPlayerItem(url: url)
        let metadata = AVPlayerItemMetadataOutput(identifiers: nil)
        metadata.setDelegate(self, queue: .main)
        item.add(metadata)
        let player = AVPlayer(playerItem: item)
        player.volume = volume
        player.automaticallyWaitsToMinimizeStalling = true
        self.player = player

        observers.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status, error = item.error
            Task { @MainActor in
                guard let self, self.generation == mine, status == .failed else { return }
                self.subject.send(.failed(Self.line(for: error)))
            }
        })
        observers.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                guard let self, self.generation == mine else { return }
                switch status {
                case .playing: self.subject.send(.playing)
                case .waitingToPlayAtSpecifiedRate: self.subject.send(.buffering)
                case .paused: self.subject.send(.paused)
                @unknown default: break
                }
            }
        })
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            MainActor.assumeIsolated {
                guard let self, self.generation == mine else { return }
                self.subject.send(.failed(Self.line(for: error)))
            }
        })
        notifications.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == mine else { return }
                self.subject.send(.ended)
            }
        })
        player.play()
    }

    func pause() { player?.pause() }

    func resume() { player?.play() }

    func stop() {
        generation += 1
        teardown()
    }

    func setVolume(_ volume: Float) {
        self.volume = volume
        player?.volume = volume
    }

    private func teardown() {
        observers.forEach { $0.invalidate() }
        observers = []
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications = []
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private static func line(for error: Error?) -> String {
        if let e = error as? URLError, e.code == .notConnectedToInternet || e.code == .networkConnectionLost { return String(localized: "You seem to be offline.") }
        return String(localized: "This station can't be played right now.")
    }

    // MARK: Song titles (ICY / ID3 timed metadata)

    nonisolated func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                                    from track: AVPlayerItemTrack?) {
        let titles: Set<AVMetadataIdentifier> = [.icyMetadataStreamTitle, .commonIdentifierTitle, .id3MetadataTitleDescription]
        guard let item = groups.flatMap(\.items).first(where: { $0.identifier.map(titles.contains) == true }) else { return }
        Task { @MainActor [weak self] in
            let text = try? await item.load(.stringValue)
            self?.subject.send(.title(text))
        }
    }
}
