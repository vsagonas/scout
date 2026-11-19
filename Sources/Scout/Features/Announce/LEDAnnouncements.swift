import Combine
import SwiftUI

/// The announcement centre. Anything may post a short text; the closed notch's LEFT wing shows it on the LED board for a few seconds,
/// one message at a time, and then goes back to what it showed.
///
///   LEDAnnouncements.shared.post("WELCOME NOTES ♥", tint: .orange, symbol: "sparkles")
///
/// Calm, by rule:
///   - a queue, one message at a time, a short gap between two messages;
///   - the same text is not repeated within 10 s (a message already waiting counts too);
///   - nothing in scripted runs (galleries, self-tests, automation) unless a test or a gallery asks;
///   - nothing at all when "Announcements" is switched off in Settings › Live Activities;
///   - nothing while the notch is OPEN (the wings are not there to see): messages wait and play when it closes, unless they went stale;
///   - no timers while idle: a message schedules its own end, the gap schedules the next one, and nothing else exists.
@MainActor
final class LEDAnnouncements {
    static let shared = LEDAnnouncements()

    // MARK: Timing

    static let gap: TimeInterval = 0.8
    static let repeatWindow: TimeInterval = 10
    static let queueLimit = 8
    /// A message that waited this long (the notch stayed open) is dropped instead of announcing old news.
    static let staleAfter: TimeInterval = 30
    /// The id of the one activity the board uses in the center.
    static let activityID = "led.announce"

    /// Everything the centre asks of the outside world, so a self-test can run it with a fake clock and its own centre.
    struct Env {
        var now: () -> Date = { Date() }
        /// Runs `work` after `seconds`; returns a closure that cancels it.
        var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void = { seconds, work in
            let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
            return { item.cancel() }
        }
        var reduceMotion: () -> Bool = { ScoutRuntime.reduceMotion }
        var forceScroll: () -> Bool = { LEDSettings.forceScroll }
        var isScripted = ScoutRuntime.isScripted
        /// The open notch shows no wings: nothing starts while it is open.
        var isNotchOpen: @MainActor () -> Bool = { NotchNavigator.shared.isOpen }
    }

    /// One message in the queue.
    struct Message: Equatable {
        var text: String
        var tint: Color
        var symbol: String?
        var seconds: Double?
        var mode: LEDMode?
        var postedAt = Date()
    }

    /// What happened, for tests and the debug command: `shown` and `skipped` in order.
    struct LogEntry: Equatable {
        enum Kind: Equatable { case shown, skipped(String) }
        var kind: Kind
        var text: String
        var at: Date
    }

    let center: LiveActivityCenter
    var env: Env
    /// A test or a gallery that wants messages in a scripted run sets this (the `led.post` command does too).
    var allowInScriptedRuns = false

    private(set) var queue: [Message] = []
    private(set) var current: Message?
    private(set) var currentPlayback: LEDPlayback?
    private(set) var log: [LogEntry] = []
    private var recent: [String: Date] = [:]
    private var cancelEnd: (() -> Void)?
    private var cancelGap: (() -> Void)?
    private var bag = Set<AnyCancellable>()

    init(center: LiveActivityCenter? = nil, env: Env = Env()) {
        self.center = center ?? LiveActivityCenter.shared
        self.env = env
    }

    /// True while a message is on the board or waiting for its turn.
    var isBusy: Bool { current != nil || !queue.isEmpty || cancelGap != nil }

    // MARK: Posting

    /// A message with words of ours in it, for the board: the translation when the 5x7 font can draw all of it (Latin letters, accents,
    /// a few Greek capitals), else the English sentence (the font has no Cyrillic, Arabic, Chinese, Japanese or Korean letters).
    /// Project names are the person's own and go in as they are.
    static func boardText(_ localized: String, english: String) -> String {
        Dash90.pixelSafe(localized.uppercased()) ? localized : english
    }

    /// Puts a message in the queue. `seconds` is how long it shows (nil: as long as its letters need). `repeating` lets the same text
    /// come again within 10 s (the Settings "Test" button).
    func post(_ text: String, tint: Color, symbol: String? = nil, seconds: Double? = nil, repeating: Bool = false, mode: LEDMode? = nil) {
        let now = env.now()
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func skip(_ why: String) { record(.skipped(why), clean, now) }
        guard !clean.isEmpty else { return }
        guard allowInScriptedRuns || !env.isScripted else { return skip("scripted") }
        guard center.isEnabled(.announcement) else { return skip("off") }
        if !repeating {
            if let last = recent[clean], now.timeIntervalSince(last) < Self.repeatWindow { return skip("repeat") }
            if queue.contains(where: { $0.text == clean }) || current?.text == clean { return skip("repeat") }
        }
        recent[clean] = now
        recent = recent.filter { now.timeIntervalSince($0.value) < Self.repeatWindow }
        if queue.count >= Self.queueLimit { queue.removeFirst() }
        queue.append(Message(text: clean, tint: tint, symbol: symbol, seconds: seconds, mode: mode, postedAt: now))
        if current == nil, cancelGap == nil { startNext() }
    }

    /// Plays what waited while the notch was open (the notch just closed).
    func resume() {
        if current == nil, cancelGap == nil { startNext() }
    }

    /// Real runs: when the notch closes, what waited for it plays. (No timer: it reacts to the notch's own change.)
    func watchNotch(_ navigator: NotchNavigator? = nil) {
        let navigator = navigator ?? NotchNavigator.shared
        navigator.$isOpen
            .removeDuplicates()
            .filter { !$0 }
            .receive(on: DispatchQueue.main)   // `$isOpen` fires before the change: look once it has settled
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.resume() } }
            .store(in: &bag)
    }

    /// Drops everything: the message on the board, the queue, the gap.
    func clear() {
        cancelEnd?(); cancelEnd = nil
        cancelGap?(); cancelGap = nil
        queue.removeAll()
        if current != nil { center.dismiss(id: Self.activityID) }
        current = nil
        currentPlayback = nil
    }

    // MARK: Playing

    private func startNext() {
        cancelGap = nil
        guard center.isEnabled(.announcement) else { queue.removeAll(); return }   // switched off while it waited
        let now = env.now()
        while let first = queue.first, now.timeIntervalSince(first.postedAt) > Self.staleAfter {   // old news is not announced
            queue.removeFirst()
            record(.skipped("stale"), first.text, now)
        }
        guard !queue.isEmpty, !env.isNotchOpen() else { return }   // an open notch shows no wings: wait for it to close
        let message = queue.removeFirst()
        let mode = message.mode ?? LEDMode.resolve(reduceMotion: env.reduceMotion(), forceScroll: env.forceScroll())
        let schedule = LEDSchedule(text: message.text, mode: mode, seconds: message.seconds)
        let playback = LEDPlayback(schedule: schedule, start: now, tint: message.tint, frozenAt: nil)
        current = message
        currentPlayback = playback
        record(.shown, message.text, now)
        center.show(Self.activity(playback, symbol: message.symbol, expiresAfter: schedule.duration + 1.0))
        cancelEnd = env.schedule(schedule.duration) { [weak self] in self?.finishCurrent() }
    }

    private func finishCurrent() {
        cancelEnd = nil
        guard current != nil else { return }
        center.dismiss(id: Self.activityID)   // the wing goes back to what it showed
        current = nil
        currentPlayback = nil
        guard !queue.isEmpty else { return }
        cancelGap = env.schedule(Self.gap) { [weak self] in self?.startNext() }
    }

    private func record(_ kind: LogEntry.Kind, _ text: String, _ at: Date) {
        log.append(LogEntry(kind: kind, text: text, at: at))
        if log.count > 60 { log.removeFirst(log.count - 60) }
    }

    // MARK: The activity

    /// The `announcement` activity: only the board, in the left wing, above the agents' wings. No glyph in the right wing any more,
    /// so the notch is the board and the camera.
    static func activity(_ playback: LEDPlayback, symbol: String?, expiresAfter: TimeInterval) -> LiveActivity {
        LiveActivity(id: activityID, kind: .announcement, expiresAfter: expiresAfter, leading: {
            LEDWingLeft(playback: playback)
        }, trailing: {
            EmptyView()
        })
    }

    /// A still board for the sample list (`scout://activity.demo`, the closed-notch kinds picture).
    static func sampleActivity(expiresAfter: TimeInterval? = nil) -> LiveActivity {
        var playback = LEDPlayback(schedule: LEDSchedule(text: "HELLO ♥", mode: .step), start: Date(), tint: Retro.Ink.yellow, frozenAt: nil)
        playback.frozenAt = playback.schedule.duration * 0.5
        return LiveActivity(id: "demo.announcement", kind: .announcement, expiresAfter: expiresAfter, leading: {
            LEDWingLeft(playback: playback)
        }, trailing: {
            EmptyView()   // the board only, as the real announcements
        })
    }
}
