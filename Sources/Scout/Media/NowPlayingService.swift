import AppKit
import SwiftUI

// Other parts of the app use this API: keep these names stable;
// add, don't rename.

enum MediaSourcePreference: String, CaseIterable, Codable, Identifiable {
    case auto, spotify, music
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: String(localized: "Automatic")
        case .spotify: "Spotify"
        case .music: "Apple Music"
        }
    }
}

struct NowPlayingTrack: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    /// Position at `positionDate`; use `NowPlayingService.elapsed()` for "now".
    var position: TimeInterval
    var positionDate: Date
    var isPlaying: Bool
    var artwork: NSImage?
    /// Bundle id of the playing app (e.g. "com.spotify.client", "com.apple.Music").
    var appBundleID: String
    var isFavorite: Bool?
    var isShuffling: Bool?

    /// Same song (ignores position and state).
    var key: String { "\(title)|\(artist)|\(album)" }
}

/// What Scout may do with one player app.
enum PlayerAccess: Equatable {
    case off          // the user has not turned control on: only passive "now playing" notifications
    case waiting      // on, but the app is not running (AppleScript would launch it)
    case allowed
    case denied       // macOS automation permission refused
}

@MainActor
final class NowPlayingService: ObservableObject {
    static let shared = NowPlayingService()

    static let spotifyID = "com.spotify.client"
    static let musicID = "com.apple.Music"

    @Published private(set) var track: NowPlayingTrack?
    /// Bundle ids whose automation permission macOS refused.
    @Published private(set) var denied: Set<String> = []

    var isPlaying: Bool { track?.isPlaying ?? false }

    private var spotify: NowPlayingTrack?
    private var music: NowPlayingTrack?
    private var lastPlayedID: String?
    private var started = false
    private var pollTimer: Timer?
    private var polling: Set<String> = []
    private var artworkRequested: Set<String> = []
    private var artworkCache = NSCache<NSString, NSImage>()
    private var sampleIndex = 0
    private var observers: [NSObjectProtocol] = []

    // MARK: Start

    func start() {
        guard !started else { return }
        started = true
        if ScoutRuntime.isScripted {
            applySample(Self.sampleTracks[0])
            return
        }
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo
            MainActor.assumeIsolated { self?.spotifyNotification(info) }
        })
        observers.append(dnc.addObserver(forName: NSNotification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo
            MainActor.assumeIsolated { self?.musicNotification(info) }
        })
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { if let id { self?.appQuit(id) } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        })
        schedulePoll()
        poll()
    }

    // MARK: Settings

    var preference: MediaSourcePreference { MediaSourcePreference(rawValue: Pref.string("media.source", "auto")) ?? .auto }

    /// The user's switch for this player (Settings → Media, onboarding).
    func controlSetting(_ bundleID: String) -> Bool {
        Pref.bool(bundleID == Self.spotifyID ? "media.spotify.control" : "media.music.control", false)
    }

    /// Scripted runs act as if control is on (with sample data and no AppleScript).
    func controlEnabled(_ bundleID: String) -> Bool { ScoutRuntime.isScripted || controlSetting(bundleID) }

    func isRunning(_ bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    func access(for bundleID: String) -> PlayerAccess {
        guard controlSetting(bundleID) else { return .off }
        if ScoutRuntime.isScripted { return .allowed }
        if denied.contains(bundleID) { return .denied }
        return isRunning(bundleID) ? .allowed : .waiting
    }

    private var lastControlSignature = ""

    private func settingsChanged() {
        let sig = "\(preference.rawValue)|\(controlEnabled(Self.spotifyID))|\(controlEnabled(Self.musicID))"
        guard sig != lastControlSignature else { return }
        lastControlSignature = sig
        recompute()
        poll()
    }

    /// Triggers the macOS automation prompt for one app (call only when the user turns the source on).
    func requestAccess(for bundleID: String) {
        guard !ScoutRuntime.isScripted else { return }
        denied.remove(bundleID)
        guard isRunning(bundleID) else { return }
        ScriptQueue.shared.run("tell application id \"\(bundleID)\" to return player state as string") { [weak self] result, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error, Self.isRefusal(error) { self.denied.insert(bundleID) }
                _ = result
                self.poll()
            }
        }
    }

    // MARK: Controls

    func playPause() { send(.playPause) }
    func next() { send(.next) }
    func previous() { send(.previous) }

    func seek(to seconds: TimeInterval) {
        guard var t = track else { return }
        let target = max(0, min(seconds, t.duration))
        t.position = target
        t.positionDate = Date()
        update(bundleID: t.appBundleID, t)
        if ScoutRuntime.isScripted { return }
        guard let script = scriptTarget(t.appBundleID) else { return }
        ScriptQueue.shared.run("tell application id \"\(script)\" to set player position to \(String(format: "%.2f", target).replacingOccurrences(of: ",", with: "."))") { _, _ in }
    }

    func toggleShuffle() {
        guard var t = track else { return }
        let new = !(t.isShuffling ?? false)
        t.isShuffling = new
        update(bundleID: t.appBundleID, t)
        if ScoutRuntime.isScripted { return }
        guard let id = scriptTarget(t.appBundleID) else { return }
        let prop = id == Self.spotifyID ? "shuffling" : "shuffle enabled"
        ScriptQueue.shared.run("tell application id \"\(id)\" to set \(prop) to \(new)") { _, _ in }
    }

    /// Music only (Spotify's scripting has no "favorite"). The App Store edition has no favorite: changing it needs
    /// Music's `library.read-write` scripting group, which the sandbox entitlements do not (and should not) grant.
    func toggleFavorite() {
        #if !APPSTORE
        guard var t = track, t.appBundleID == Self.musicID, t.isFavorite != nil || ScoutRuntime.isScripted else { return }
        let new = !(t.isFavorite ?? false)
        t.isFavorite = new
        update(bundleID: t.appBundleID, t)
        if ScoutRuntime.isScripted { return }
        guard scriptTarget(Self.musicID) != nil else { return }
        ScriptQueue.shared.run("tell application id \"\(Self.musicID)\" to set favorited of current track to \(new)") { _, _ in }
        #endif
    }

    var canFavorite: Bool {
        #if APPSTORE
        return false
        #else
        return track?.appBundleID == Self.musicID
        #endif
    }

    /// Brings the playing app to the front.
    func openPlayer() {
        guard let id = track?.appBundleID, !ScoutRuntime.isScripted else { return }
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id }?.activate()
    }

    private enum Command { case playPause, next, previous }

    private func send(_ command: Command) {
        guard let t = track else { return }
        if ScoutRuntime.isScripted {
            switch command {
            case .playPause:
                var copy = t
                copy.position = elapsed()
                copy.positionDate = Date()
                copy.isPlaying.toggle()
                update(bundleID: t.appBundleID, copy)
            case .next: sampleIndex = (sampleIndex + 1) % Self.sampleTracks.count; applySample(Self.sampleTracks[sampleIndex])
            case .previous: sampleIndex = (sampleIndex + Self.sampleTracks.count - 1) % Self.sampleTracks.count; applySample(Self.sampleTracks[sampleIndex])
            }
            return
        }
        guard let id = scriptTarget(t.appBundleID) else {
            #if !APPSTORE
            // Without AppleScript control: the system media keys reach whatever app is playing (needs Accessibility).
            if Permissions.accessibilityGranted {
                Self.postMediaKey(command == .playPause ? 16 : (command == .next ? 17 : 18))
                return
            }
            #endif
            Toast.show("Turn on control for this player in Settings → Media", symbol: "music.note", style: .info, duration: 3)
            return
        }
        if command == .playPause {
            var copy = t
            copy.position = elapsed()
            copy.positionDate = Date()
            copy.isPlaying.toggle()
            update(bundleID: t.appBundleID, copy)
        }
        let verb: String
        switch command {
        case .playPause: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        ScriptQueue.shared.run("tell application id \"\(id)\" to \(verb)") { [weak self] _, error in
            MainActor.assumeIsolated { if let error, Self.isRefusal(error) { self?.denied.insert(id) } else { self?.pollSoon() } }
        }
    }

    #if !APPSTORE
    /// NX_KEYTYPE_PLAY 16, NEXT 17, PREVIOUS 18.
    static func postMediaKey(_ key: Int) {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                           modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                           timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                           data1: (key << 16) | (state << 8), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
    #endif

    /// AppleScript error numbers for "not allowed": -1743 (automation permission refused) and -10004 (the sandbox refused
    /// the Apple event). Either way Scout stops scripting that app and says nothing more (the Media page shows the state).
    nonisolated static func isRefusal(_ code: Int) -> Bool { code == -1743 || code == -10004 }

    /// The bundle id to script, only when the user allowed it and the app is running.
    private func scriptTarget(_ bundleID: String) -> String? {
        guard controlEnabled(bundleID), isRunning(bundleID), !denied.contains(bundleID) else { return nil }
        return bundleID
    }

    func elapsed(at date: Date = Date()) -> TimeInterval {
        guard let track else { return 0 }
        guard track.isPlaying else { return track.position }
        return min(track.duration, track.position + date.timeIntervalSince(track.positionDate))
    }

    // MARK: State per source

    private func update(bundleID: String, _ new: NowPlayingTrack?) {
        if bundleID == Self.spotifyID { spotify = new } else { music = new }
        if new?.isPlaying == true { lastPlayedID = bundleID }
        recompute()
    }

    private func recompute() {
        let candidate: NowPlayingTrack?
        switch preference {
        case .spotify: candidate = spotify
        case .music: candidate = music
        case .auto:
            let playing = [spotify, music].compactMap { $0 }.filter(\.isPlaying)
            if playing.count == 1 {
                candidate = playing[0]
            } else if playing.count > 1 {
                candidate = playing.first { $0.appBundleID == lastPlayedID } ?? playing[0]
            } else if lastPlayedID == Self.spotifyID {
                candidate = spotify ?? music
            } else {
                candidate = music ?? spotify
            }
        }
        guard candidate != track else { return }
        let wasPlaying = track?.isPlaying ?? false
        track = candidate
        if wasPlaying != (candidate?.isPlaying ?? false) { schedulePoll() }
    }

    private func appQuit(_ id: String) {
        guard id == Self.spotifyID || id == Self.musicID else { return }
        update(bundleID: id, nil)
        denied.remove(id)
    }

    // MARK: Passive notifications (no permission needed)

    private func spotifyNotification(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let state = (info["Player State"] as? String ?? "").lowercased()
        guard state != "stopped" else { update(bundleID: Self.spotifyID, nil); return }
        let title = info["Name"] as? String ?? ""
        guard !title.isEmpty else { return }
        let durationMs = (info["Duration"] as? NSNumber)?.doubleValue ?? 0
        let position = (info["Playback Position"] as? NSNumber)?.doubleValue ?? 0
        var t = NowPlayingTrack(title: title, artist: info["Artist"] as? String ?? "", album: info["Album"] as? String ?? "",
                                duration: durationMs / 1000, position: position, positionDate: Date(),
                                isPlaying: state == "playing", artwork: nil, appBundleID: Self.spotifyID,
                                isFavorite: nil, isShuffling: spotify?.isShuffling)
        t.artwork = spotify?.key == t.key ? spotify?.artwork : artworkCache.object(forKey: t.key as NSString)
        update(bundleID: Self.spotifyID, t)
        if t.artwork == nil, controlEnabled(Self.spotifyID) { pollSoon() }
    }

    private func musicNotification(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let state = (info["Player State"] as? String ?? "").lowercased()
        guard state != "stopped" else { update(bundleID: Self.musicID, nil); return }
        let title = info["Name"] as? String ?? ""
        guard !title.isEmpty else { return }
        let durationMs = (info["Total Time"] as? NSNumber)?.doubleValue ?? 0
        var t = NowPlayingTrack(title: title, artist: info["Artist"] as? String ?? "", album: info["Album"] as? String ?? "",
                                duration: durationMs / 1000, position: 0, positionDate: Date(),
                                isPlaying: state == "playing", artwork: nil, appBundleID: Self.musicID,
                                isFavorite: music?.isFavorite, isShuffling: music?.isShuffling)
        if let old = music, old.key == t.key {
            // Music sends no position: keep counting from what we knew.
            t.artwork = old.artwork
            t.position = old.isPlaying ? min(old.duration, old.position + Date().timeIntervalSince(old.positionDate)) : old.position
        } else {
            t.artwork = artworkCache.object(forKey: t.key as NSString)
            t.isFavorite = nil
        }
        update(bundleID: Self.musicID, t)
        if controlEnabled(Self.musicID) { pollSoon() }
    }

    // MARK: Polling through AppleScript (only when the user turned the source on, only when the app runs)

    private func schedulePoll() {
        pollTimer?.invalidate()
        guard !ScoutRuntime.isScripted else { return }
        let interval: TimeInterval = isPlaying ? 1 : 5
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func pollSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.poll() }
    }

    func poll() {
        guard !ScoutRuntime.isScripted else { return }
        for id in [Self.spotifyID, Self.musicID] {
            guard scriptTarget(id) != nil, !polling.contains(id) else { continue }
            polling.insert(id)
            let source = id == Self.spotifyID ? Self.spotifyScript : Self.musicScript
            ScriptQueue.shared.run(source) { [weak self] result, error in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.polling.remove(id)
                    if let error, Self.isRefusal(error) { self.denied.insert(id); return }
                    guard let result else { return }
                    self.apply(script: result, bundleID: id)
                }
            }
        }
    }

    private static let spotifyScript = """
    tell application id "com.spotify.client"
        if player state is stopped then return {"stopped"}
        set t to current track
        return {(player state as string), (name of t), (artist of t), (album of t), (duration of t), (round (player position * 100)) as integer, (artwork url of t), (id of t), (shuffling as string)}
    end tell
    """

    // Everything below sits in Music's `playback` and `library.read` scripting groups (checked against `sdef Music.app`):
    // player state / player position / shuffle enabled / current track = playback; name, artist, album, duration,
    // persistent ID of a track and artwork = playback or library.read. `favorited` is read only in the full edition.
    private static let musicScript = """
    tell application id "com.apple.Music"
        if player state is stopped then return {"stopped"}
        set t to current track
        set fav to ""
        \(musicFavoriteLookup)
        return {(player state as string), (name of t), (artist of t), (album of t), (round ((duration of t) * 1000)) as integer, (round (player position * 100)) as integer, fav, (shuffle enabled as string), (persistent ID of t)}
    end tell
    """

    #if APPSTORE
    private static let musicFavoriteLookup = ""
    #else
    private static let musicFavoriteLookup = "try\n            set fav to (favorited of t) as string\n        end try"
    #endif

    private func apply(script list: NSAppleEventDescriptor, bundleID: String) {
        var items: [String] = []
        if list.numberOfItems > 0 { for i in 1...list.numberOfItems { items.append(list.atIndex(i)?.stringValue ?? "") } }
        guard let state = items.first?.lowercased(), state != "stopped", items.count >= 6 else {
            update(bundleID: bundleID, nil)
            return
        }
        let existing = bundleID == Self.spotifyID ? spotify : music
        let isSpotify = bundleID == Self.spotifyID
        let duration = (Double(items[4]) ?? 0) / 1000
        let position = (Double(items[5]) ?? 0) / 100
        var t = NowPlayingTrack(title: items[1], artist: items[2], album: items[3], duration: duration,
                                position: position, positionDate: Date(), isPlaying: state == "playing", artwork: nil,
                                appBundleID: bundleID, isFavorite: nil, isShuffling: nil)
        if items.count > 7 { t.isShuffling = items[7] == "true" }
        if !isSpotify, items.count > 6, !items[6].isEmpty { t.isFavorite = items[6] == "true" }
        t.artwork = existing?.key == t.key ? existing?.artwork : artworkCache.object(forKey: t.key as NSString)
        // Keep the published value steady while the position drifts less than a second.
        if let old = existing, old.key == t.key, old.isPlaying == t.isPlaying, old.isFavorite == t.isFavorite,
           old.isShuffling == t.isShuffling, old.artwork === t.artwork {
            let drift = abs(elapsedOf(old) - position)
            if drift < 1.2 { return }
        }
        update(bundleID: bundleID, t)
        if t.artwork == nil, !artworkRequested.contains(t.key) {
            artworkRequested.insert(t.key)
            if isSpotify, items.count > 6 { fetchSpotifyArtwork(urlString: items[6], key: t.key) } else if !isSpotify { fetchMusicArtwork(key: t.key) }
        }
    }

    private func elapsedOf(_ t: NowPlayingTrack) -> TimeInterval {
        t.isPlaying ? min(t.duration, t.position + Date().timeIntervalSince(t.positionDate)) : t.position
    }

    // MARK: Artwork

    private func setArtwork(_ image: NSImage, key: String, bundleID: String) {
        artworkCache.setObject(image, forKey: key as NSString)
        let current = bundleID == Self.spotifyID ? spotify : music
        guard var t = current, t.key == key else { return }
        t.artwork = image
        update(bundleID: bundleID, t)
    }

    private func fetchSpotifyArtwork(urlString: String, key: String) {
        guard let url = URL(string: urlString), url.scheme == "https" else { return }
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else { return }
            await MainActor.run { self?.setArtwork(image, key: key, bundleID: Self.spotifyID) }
        }
    }

    private func fetchMusicArtwork(key: String) {
        ScriptQueue.shared.run("tell application id \"com.apple.Music\" to return data of artwork 1 of current track") { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let data = result?.data, !data.isEmpty, let image = NSImage(data: data) else { return }
                self?.setArtwork(image, key: key, bundleID: Self.musicID)
            }
        }
    }

    // MARK: Sample data (scripted runs and the gallery)

    static let sampleTracks: [NowPlayingTrack] = [
        NowPlayingTrack(title: "Midnight Cartography", artist: "The Scouts", album: "Field Notes", duration: 221, position: 83,
                        positionDate: Date(), isPlaying: true, artwork: ArtworkFactory.image(seed: "Midnight Cartography"),
                        appBundleID: musicID, isFavorite: false, isShuffling: false),
        NowPlayingTrack(title: "Paper Lanterns", artist: "Ada Marlow", album: "Slow Hours", duration: 198, position: 12,
                        positionDate: Date(), isPlaying: true, artwork: ArtworkFactory.image(seed: "Paper Lanterns"),
                        appBundleID: spotifyID, isFavorite: nil, isShuffling: true),
        NowPlayingTrack(title: "Northbound", artist: "Low Tide Club", album: "Harbour Lights", duration: 254, position: 40,
                        positionDate: Date(), isPlaying: true, artwork: ArtworkFactory.image(seed: "Northbound"),
                        appBundleID: musicID, isFavorite: true, isShuffling: false),
    ]

    static var sampleTrack: NowPlayingTrack { sampleTracks[0] }

    private func applySample(_ sample: NowPlayingTrack) {
        var t = sample
        t.positionDate = Date()
        update(bundleID: t.appBundleID, t)
        let other = t.appBundleID == Self.musicID ? Self.spotifyID : Self.musicID
        update(bundleID: other, nil)
    }

    /// For the gallery: show a given track without any service running.
    func showSample(_ sample: NowPlayingTrack?) {
        started = true
        spotify = nil
        music = nil
        track = sample
        if let sample { if sample.appBundleID == Self.spotifyID { spotify = sample } else { music = sample } }
    }
}

// MARK: - AppleScript on a background queue (a stuck player must never freeze the notch)

final class ScriptQueue: @unchecked Sendable {
    static let shared = ScriptQueue()
    private let queue = DispatchQueue(label: "scout.applescript", qos: .userInitiated)
    private var cache: [String: NSAppleScript] = [:]

    /// `error` is the AppleScript error number (-1743 = not allowed, -600 = app not running).
    func run(_ source: String, completion: @escaping @Sendable (NSAppleEventDescriptor?, Int?) -> Void) {
        queue.async { [self] in
            let script: NSAppleScript?
            if let cached = cache[source] { script = cached } else {
                script = NSAppleScript(source: source)
                cache[source] = script
            }
            var errorInfo: NSDictionary?
            let result = script?.executeAndReturnError(&errorInfo)
            let code = (errorInfo?[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            let box = DescriptorBox(result)
            DispatchQueue.main.async { completion(code == nil ? box.value : nil, code) }
        }
    }
}

private struct DescriptorBox: @unchecked Sendable {
    let value: NSAppleEventDescriptor?
    init(_ value: NSAppleEventDescriptor?) { self.value = value }
}

// MARK: - Generated artwork (sample tracks, and the placeholder for songs with no artwork)

enum ArtworkFactory {
    @MainActor
    static func image(seed: String, size: CGFloat = 256) -> NSImage {
        let hash = seed.unicodeScalars.reduce(UInt64(5381)) { ($0 << 5) &+ $0 &+ UInt64($1.value) }
        func unit(_ shift: UInt64) -> CGFloat { CGFloat((hash >> shift) & 0xFF) / 255 }
        let hueA = unit(0), hueB = fmod(hueA + 0.12 + unit(8) * 0.25, 1)
        let a = NSColor(hue: hueA, saturation: 0.55, brightness: 0.55, alpha: 1)
        let b = NSColor(hue: hueB, saturation: 0.7, brightness: 0.95, alpha: 1)
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSGradient(colors: [a, b])?.draw(in: rect, angle: 35 + unit(16) * 90)
            let c = NSColor.white.withAlphaComponent(0.16)
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.width * (0.15 + unit(24) * 0.3), y: rect.height * 0.1, width: rect.width * 0.8, height: rect.width * 0.8)).fill()
            NSColor.white.withAlphaComponent(0.3).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: rect.width * 0.28, dy: rect.height * 0.28))
            ring.lineWidth = rect.width * 0.02
            ring.stroke()
            return true
        }
    }
}
