import AppKit
import SwiftUI

/// Runs the Prompter: the panel under the camera, Steady scrolling, Voice following, keys and timers.
@MainActor
final class PrompterController: ObservableObject {
    static let shared = PrompterController(isShared: true)

    enum Phase: Equatable { case idle, countdown(Int), playing, paused, finished }
    enum Mode: String, CaseIterable, Identifiable {
        case steady, voice
        var id: String { rawValue }
        var title: String { self == .steady ? String(localized: "Steady") : String(localized: "Voice") }
    }

    /// How Voice mode follows the reader: by the words it recognises, or by the sound of the voice (moves
    /// while you speak, waits when you stop) when words can't be recognised.
    enum Follow: Equatable { case words, sound }

    /// A short message on the panel (it goes away by itself); `link` opens where the reader can change it.
    struct Notice: Equatable {
        enum Link: Equatable { case pane(Permissions.Pane), keyboard }
        var text: String
        var detail: String
        var link: Link?

        @MainActor func open() {
            switch link {
            case .pane(let pane): Permissions.openSettings(pane)
            case .keyboard:
                if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
            case nil: break
            }
        }
    }

    static let panelID = "prompter"
    static let panelSize = CGSize(width: 520, height: 170)
    static let readingLine: CGFloat = 62

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var mode: Mode = .steady
    @Published private(set) var wpm = 150
    @Published private(set) var heard = ""
    @Published private(set) var level: Float = 0
    @Published private(set) var notice: Notice?
    @Published private(set) var progress: Double = 0
    @Published private(set) var follow: Follow = .words
    /// Voice mode hears the reader right now (with a short hold over the gaps between words).
    @Published private(set) var speaking = false

    let layout = PrompterLayout()
    weak var canvas: PrompterCanvasView?
    private(set) var offset: CGFloat = 0 { didSet { canvas?.offset = offset } }
    var mirror = false
    private let isShared: Bool

    private var matcher: ScriptMatcher?
    private var timer: Timer?
    private var lastTick = Date()
    private var voice: VoiceFollower?
    private var simulation: Timer?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var closeObserver: NSObjectProtocol?
    private var countdownTask: Task<Void, Never>?
    private var scrollRemainder: CGFloat = 0
    private var firstMid: CGFloat = 0
    private var lastMid: CGFloat = 0
    private var wordCount = 1
    private var scriptText = ""
    private var noticeTask: Task<Void, Never>?
    // Voice: the room's own noise level, when the voice was last heard, and how long the reader has spoken
    // without one word of the script matching.
    private var noiseFloor: Float = 0.03
    private var lastVoiceAt = Date.distantPast
    private var unmatchedSpeech: Double = 0

    init(isShared: Bool = false) { self.isShared = isShared }

    // MARK: Start

    var isOpen: Bool { Panels.isShown(Self.panelID) }

    func start(_ script: PrompterScript, mode: Mode) {
        stopEngines()
        configure(script: script, mode: mode)
        phase = .countdown(3)
        showPanel()
        countdownTask = Task { @MainActor [weak self] in
            for n in [3, 2, 1] {
                self?.phase = .countdown(n)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            self?.begin()
        }
    }

    /// Lays out the script (also used by the gallery, without a panel).
    func configure(script: PrompterScript, mode: Mode) {
        self.mode = mode
        wpm = max(60, min(300, Pref.int(PrompterPrefs.wpm, 150)))
        mirror = Pref.bool(PrompterPrefs.mirror, false)
        let size = CGFloat(max(18, min(48, Pref.int(PrompterPrefs.fontSize, 28))))
        layout.configure(text: script.text, fontSize: size, width: Self.panelSize.width - 64)
        matcher = ScriptMatcher(text: script.text)
        wordCount = max(1, matcher?.words.count ?? 1)
        firstMid = layout.firstLineMid
        lastMid = layout.lastLineMid
        offset = firstMid
        heard = ""
        notice = nil
        noticeTask?.cancel()
        progress = 0
        scriptText = script.text
        follow = .words
        speaking = false
        noiseFloor = 0.03
        lastVoiceAt = .distantPast
        unmatchedSpeech = 0
        if mode == .voice { layout.highlight(cursor: 0, accent: NSColor(Theme.accent)) } else { layout.clearHighlight() }
        canvas?.mirror = mirror
    }

    private func begin() {
        phase = .playing
        lastTick = Date()
        startTimer()
        if mode == .voice { startVoice() }
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Ticks

    /// Points per second for the chosen words-per-minute (average line height per word of THIS script).
    private var pointsPerSecond: CGFloat {
        let perWord = (lastMid - firstMid) / CGFloat(wordCount)
        return CGFloat(wpm) / 60 * max(1, perWord)
    }

    private func tick() {
        let now = Date()
        let dt = min(0.1, now.timeIntervalSince(lastTick))
        lastTick = now
        guard phase == .playing else { return }
        switch mode {
        case .steady:
            offset = min(lastMid, offset + pointsPerSecond * CGFloat(dt))
            if offset >= lastMid - 0.5 { finish() }
        case .voice:
            let nowSpeaking = now.timeIntervalSince(lastVoiceAt) < 0.9
            if speaking != nowSpeaking { speaking = nowSpeaking }
            switch follow {
            case .sound:
                if nowSpeaking { offset = min(lastMid, offset + pointsPerSecond * CGFloat(dt)) }
                if offset >= lastMid - 0.5 { finish() }
            case .words:
                guard let matcher else { break }
                let cursor = matcher.cursor
                let target = cursor < layout.wordRanges.count ? layout.lineMid(forCharacter: layout.wordRanges[cursor].location) : lastMid
                offset += (target - offset) * CGFloat(1 - exp(-dt * 5))
                if matcher.isFinished && abs(target - offset) < 1 { finish() }
                // Speaking for a while and not one word of the script matched: another language, or a noisy room.
                if nowSpeaking, cursor == 0 { unmatchedSpeech += dt }
                if unmatchedSpeech > 8, !ScoutRuntime.isScripted {
                    voice?.stopRecognising()
                    followSound(Notice(text: String(localized: "Scout can't match what it hears to the script"),
                                       detail: String(localized: "It follows the sound of your voice now. Pick the language in Settings › Prompter.")))
                }
            }
        }
        progress = lastMid > firstMid ? Double((offset - firstMid) / (lastMid - firstMid)) : 0
    }

    private func finish() {
        phase = .finished
        timer?.invalidate()
        timer = nil
        voice?.stop()
        simulation?.invalidate()
        level = 0
    }

    // MARK: Controls

    func togglePause() {
        switch phase {
        case .playing:
            phase = .paused
            if mode == .voice { voice?.stop(); voice = nil; simulation?.invalidate(); level = 0; speaking = false }
        case .paused:
            phase = .playing
            lastTick = Date()
            if mode == .voice { startVoice() }
        case .finished:
            restart()
        default: break
        }
    }

    func adjustSpeed(by delta: Int) {
        wpm = max(60, min(300, wpm + delta))
        Pref.set(wpm, PrompterPrefs.wpm)
    }

    func restart() {
        guard let script = ScriptStore.shared.selected else { return }
        start(script, mode: mode)
    }

    /// While paused, scrolling moves the text by hand.
    func nudge(by points: CGFloat) {
        offset = max(firstMid, min(lastMid, offset + points))
    }

    func close() { Panels.close(Self.panelID) }

    // MARK: Voice

    private func startVoice() {
        guard let matcher else { return }
        voice?.stop()
        if ScoutRuntime.isScripted { simulateVoice(matcher); return }
        let follower = VoiceFollower()
        follower.onNewRequest = { [weak matcher] in matcher?.newRequest() }
        follower.onTranscript = { [weak self] words, final in
            guard let self, let matcher = self.matcher, self.phase == .playing else { return }
            let cursor = matcher.update(transcript: words, isFinal: final)
            self.heard = words.suffix(7).joined(separator: " ")
            self.layout.highlight(cursor: cursor, accent: NSColor(Theme.accent))
            self.canvas?.needsDisplay = true
        }
        follower.onLevel = { [weak self] level in self?.noteLevel(level) }
        follower.onFailure = { [weak self, weak follower] failure in
            guard let self, let follower, self.voice === follower else { return }
            self.voiceFailed(failure)
        }
        voice = follower
        let language = Pref.string(PrompterPrefs.language, "")
        let words = follow == .words
        let script = scriptText
        Task { await follower.start(localeID: language, script: script, words: words) }
    }

    /// Words can't be followed: follow the sound of the voice. Nothing to listen to: keep a steady speed.
    /// Either way the reading goes on.
    private func voiceFailed(_ failure: VoiceFollower.Failure) {
        if failure.stopsListening {
            voice?.stop()
            voice = nil
            mode = .steady
            level = 0
            speaking = false
            layout.clearHighlight()
            canvas?.needsDisplay = true
            lastTick = Date()
            show(Notice(text: failure.message, detail: String(localized: "Scrolling at a steady speed instead (↑ ↓ change it)."), link: failure.link))
        } else {
            followSound(Notice(text: failure.message, detail: String(localized: "Following the sound of your voice: it moves while you speak."), link: failure.link))
        }
    }

    private func followSound(_ notice: Notice) {
        follow = .sound
        unmatchedSpeech = 0
        heard = ""
        layout.clearHighlight()
        canvas?.needsDisplay = true
        show(notice)
    }

    private func show(_ notice: Notice) {
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            guard !Task.isCancelled, let self, self.notice == notice else { return }
            self.notice = nil
        }
    }

    /// The microphone level (0…1, about 23 times a second). Speech is clearly above the room's noise floor,
    /// which follows quiet moments at once and rises only slowly.
    private func noteLevel(_ value: Float) {
        level = value
        noiseFloor = value < noiseFloor ? value : noiseFloor + (value - noiseFloor) * 0.01
        if value > max(0.07, noiseFloor * 2.2 + 0.035) { lastVoiceAt = Date() }
    }

    /// Scripted runs: pretend someone reads the script aloud (no microphone, no permission prompts).
    private func simulateVoice(_ matcher: ScriptMatcher) {
        simulation?.invalidate()
        let spoken = matcher.words.map { String($0.norm) }
        var count = 0
        matcher.newRequest()
        simulation = Timer.scheduledTimer(withTimeInterval: 0.32, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.phase == .playing else { return }
                count += 1
                if count > spoken.count { timer.invalidate(); return }
                let words = Array(spoken.prefix(count))
                let cursor = matcher.update(transcript: words, isFinal: false)
                self.heard = words.suffix(7).joined(separator: " ")
                self.noteLevel(Float.random(in: 0.2...0.8))
                self.layout.highlight(cursor: cursor, accent: NSColor(Theme.accent))
                self.canvas?.needsDisplay = true
            }
        }
    }

    // MARK: Panel

    private func panelOrigin() -> CGPoint {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let bar = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : NSStatusBar.system.thickness
        return CGPoint(x: screen.frame.midX - Self.panelSize.width / 2, y: screen.frame.maxY - bar - Self.panelSize.height)
    }

    private func showPanel() {
        let controller = self
        let panel = Panels.show(id: Self.panelID, options: Panels.Options(size: Self.panelSize, resizable: false, position: .at(panelOrigin()),
                                                                          level: .statusBar, hiddenFromScreenSharing: !ScoutRuntime.isScripted)) {
            PrompterPanelView(controller: controller)
        }
        panel.dropTitleBar(size: Self.panelSize)
        panel.setFrame(CGRect(origin: panelOrigin(), size: Self.panelSize), display: true)
        // Hidden from screen sharing and recordings (scripted checks stay capturable so a picture can be taken).
        panel.sharingType = ScoutRuntime.isScripted ? .readOnly : .none
        if closeObserver == nil {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.panelClosed() }
            }
        }
        installMonitors(panel)
    }

    private func panelClosed() {
        stopEngines()
        phase = .idle
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }

    private func stopEngines() {
        countdownTask?.cancel()
        countdownTask = nil
        timer?.invalidate()
        timer = nil
        voice?.stop()
        voice = nil
        simulation?.invalidate()
        simulation = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        keyMonitor = nil
        scrollMonitor = nil
        level = 0
    }

    private func installMonitors(_ panel: NSPanel) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard let self, let panel, event.window === panel else { return event }
            let code = event.keyCode
            return MainActor.assumeIsolated { self.handleKey(code) } ? nil : event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak panel] event in
            guard let self, let panel, event.window === panel else { return event }
            let dy = event.scrollingDeltaY
            let inverted = event.isDirectionInvertedFromDevice
            MainActor.assumeIsolated { self.handleScroll(dy, inverted: inverted) }
            return nil
        }
    }

    private func handleKey(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 49: togglePause(); return true                      // space
        case 53: close(); return true                            // escape
        case 126: adjustSpeed(by: 10); return true               // up
        case 125: adjustSpeed(by: -10); return true              // down
        case 36, 76: restart(); return true                      // return
        default: return false
        }
    }

    private func handleScroll(_ deltaY: CGFloat, inverted: Bool) {
        let delta = inverted ? -deltaY : deltaY
        if phase == .paused {
            nudge(by: -deltaY)
        } else if mode == .steady || follow == .sound {
            scrollRemainder += delta
            let steps = Int(scrollRemainder / 8)
            if steps != 0 { scrollRemainder -= CGFloat(steps) * 8; adjustSpeed(by: steps * 5) }
        }
    }

    // MARK: Gallery

    /// Sets up a still frame for the gallery.
    func previewState(script: PrompterScript, mode: Mode, phase: Phase, progress: Double, heard: String = "", level: Float = 0,
                      follow: Follow = .words, notice: Notice? = nil) {
        configure(script: script, mode: mode)
        self.phase = phase
        self.heard = heard
        self.level = level
        self.progress = progress
        self.follow = follow
        self.speaking = level > 0.1
        self.notice = notice
        let target = firstMid + (lastMid - firstMid) * CGFloat(progress)
        offset = target
        if mode == .voice, follow == .words, let matcher {
            // Put the cursor on the word nearest the reading line.
            var best = 0
            for (i, r) in layout.wordRanges.enumerated() where layout.lineMid(forCharacter: r.location) <= target + 1 { best = i }
            _ = matcher.update(transcript: matcher.words.prefix(best).map(\.norm), isFinal: true)
            layout.highlight(cursor: best, accent: NSColor(Theme.accent))
        }
    }
}
