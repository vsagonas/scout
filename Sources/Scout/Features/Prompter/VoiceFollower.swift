@preconcurrency import AVFoundation
import NaturalLanguage
import Speech

/// Listens on the Mac and reports two things: how loud the reader is (always, from the microphone) and,
/// when on-device speech recognition can run for the script's language, the words it hears.
/// When words can't be recognised (no on-device model for the language, Dictation off, Speech Recognition
/// not allowed, recognition keeps failing) the level keeps coming, so the Prompter follows the SOUND of the
/// voice instead: it moves while you speak and waits when you stop. Nothing leaves the Mac.
@MainActor
final class VoiceFollower {
    enum Failure: Error, Equatable {
        case micDenied, noMicrophone, speechDenied, dictationOff
        case unavailable(String), onDeviceMissing(String)
        case recognitionFailed(String)

        /// True when there is nothing to listen to at all (the Prompter then scrolls at a steady speed).
        var stopsListening: Bool { self == .micDenied || self == .noMicrophone }

        var message: String {
            switch self {
            case .micDenied: String(localized: "Microphone access is off for Scout")
            case .noMicrophone: String(localized: "Scout can't use this microphone")
            case .speechDenied: String(localized: "Speech Recognition is off for Scout")
            case .dictationOff: String(localized: "Turn on Dictation to follow word by word")
            case .unavailable(let l): String(localized: "\(l) can't be recognised on this Mac")
            case .onDeviceMissing(let l): String(localized: "\(l) can't be recognised on this Mac")
            case .recognitionFailed(let reason): reason.isEmpty ? String(localized: "Speech recognition stopped") : reason
            }
        }

        /// Where the reader can change it.
        var link: PrompterController.Notice.Link? {
            switch self {
            case .micDenied: .pane(.microphone)
            case .speechDenied: .pane(.speech)
            case .dictationOff: .keyboard
            default: nil
            }
        }
    }

    /// Called with the words of the CURRENT request so far (cumulative) and whether it ended.
    var onTranscript: (([String], Bool) -> Void)?
    var onNewRequest: (() -> Void)?
    var onLevel: ((Float) -> Void)?
    /// Words can't be followed (the level keeps coming), or with `stopsListening` nothing can be heard.
    var onFailure: ((Failure) -> Void)?

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private let box = RequestBox()
    private var listening = false
    private var recognizing = false
    private var stopped = false
    private var contextWords: [String] = []
    private var requestStarted = Date()
    private var requestHeardWords = false
    private var quickFailures = 0

    /// Thread-safe holder of the request the audio tap appends to.
    final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var request: SFSpeechAudioBufferRecognitionRequest?
        func set(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request = r; lock.unlock() }
        func append(_ buffer: AVAudioPCMBuffer) { lock.lock(); request?.append(buffer); lock.unlock() }
    }

    static func languageName(_ id: String) -> String {
        Locale.current.localizedLanguageName(for: id)
    }

    // MARK: Start / stop

    /// `words`: also try to recognise the words (false = follow the sound only, e.g. after a pause).
    func start(localeID: String, script: String, words: Bool) async {
        // The microphone first: both ways of following need it.
        var mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic == .notDetermined {
            let granted: Bool = await withCheckedContinuation { c in AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) } }
            mic = granted ? .authorized : .denied
        }
        guard !stopped else { return }
        guard mic == .authorized else { onFailure?(.micDenied); return }
        guard startEngine() else { onFailure?(.noMicrophone); return }
        guard words else { return }

        var speech = SFSpeechRecognizer.authorizationStatus()
        if speech == .notDetermined {
            speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        }
        guard !stopped else { return }
        guard speech == .authorized else { onFailure?(.speechDenied); return }

        let locale = Self.recognitionLocale(preferred: localeID, script: script)
        let name = Self.languageName(locale.identifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { onFailure?(.unavailable(name)); return }
        guard recognizer.supportsOnDeviceRecognition else { onFailure?(.onDeviceMissing(name)); return }
        self.recognizer = recognizer
        contextWords = Self.contextWords(in: script)
        recognizing = true
        beginRequest()
    }

    func stop() {
        stopped = true
        stopRecognising()
        listening = false
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    /// Stop recognising words; the microphone level keeps coming.
    func stopRecognising() {
        recognizing = false
        task?.cancel()
        task = nil
        box.set(nil)
    }

    private func startEngine() -> Bool {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return false }
        let box = self.box
        let levelHandler = onLevel
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            box.append(buffer)
            if let data = buffer.floatChannelData?[0] {
                var sum: Float = 0
                let n = Int(buffer.frameLength)
                for i in 0..<n { sum += data[i] * data[i] }
                let rms = n > 0 ? sqrt(sum / Float(n)) : 0
                DispatchQueue.main.async { levelHandler?(min(1, rms * 8)) }
            }
        }
        engine.prepare()
        do { try engine.start() } catch { return false }
        listening = true
        return true
    }

    // MARK: Requests (the system ends a request after about a minute, or after silence: start another one)

    private func beginRequest() {
        guard recognizing, let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = false
        request.contextualStrings = contextWords
        box.set(request)
        onNewRequest?()
        requestStarted = Date()
        requestHeardWords = false
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let words = result?.bestTranscription.formattedString.split(whereSeparator: \.isWhitespace).map(String.init)
            let final = result?.isFinal ?? false
            let failure = (error as NSError?).map { (code: $0.code, domain: $0.domain, text: $0.localizedDescription) }
            Task { @MainActor in
                guard let self, self.recognizing else { return }
                if let words, !words.isEmpty { self.requestHeardWords = true; self.quickFailures = 0 }
                if let words { self.onTranscript?(words, final || failure != nil) }
                guard final || failure != nil else { return }
                if let failure, !self.requestHeardWords {
                    if Self.meansDictationOff(failure.domain, failure.code, failure.text) { self.giveUpWords(.dictationOff); return }
                    // Ending after silence is normal. Failing again and again at once is not.
                    if !Self.isBenign(failure.code, failure.text), Date().timeIntervalSince(self.requestStarted) < 4 {
                        self.quickFailures += 1
                        if self.quickFailures >= 3 { self.giveUpWords(.recognitionFailed(failure.text)); return }
                    }
                }
                try? await Task.sleep(nanoseconds: 150_000_000 * UInt64(1 + self.quickFailures))
                self.beginRequest()
            }
        }
    }

    private func giveUpWords(_ failure: Failure) {
        stopRecognising()
        onFailure?(failure)
    }

    /// "No speech detected" (1110), "retry" (203), cancelled (216, 301) and the 1101 macOS logs after a normal end.
    private static func isBenign(_ code: Int, _ text: String) -> Bool {
        [203, 216, 301, 1101, 1110].contains(code) || text.localizedCaseInsensitiveContains("no speech")
    }

    /// "Siri and Dictation are disabled" is `kLSRErrorDomain` 201; the words of the message (in English only) are a second hint, because the
    /// message itself comes in the Mac's language.
    private static func meansDictationOff(_ domain: String, _ code: Int, _ text: String) -> Bool {
        (domain == "kLSRErrorDomain" && code == 201) || text.localizedCaseInsensitiveContains("dictation") || text.localizedCaseInsensitiveContains("siri")
    }

    // MARK: Language

    /// The language to listen for: the one chosen in Settings, otherwise the script's own language in the
    /// variant this Mac can recognise (an English script on a Mac set to "English (Greece)" → en-US), and
    /// this Mac's language when the script is too short to tell.
    static func recognitionLocale(preferred: String, script: String) -> Locale {
        if !preferred.isEmpty { return Locale(identifier: preferred) }
        let supported = SFSpeechRecognizer.supportedLocales()
        let detector = NLLanguageRecognizer()
        detector.processString(String(script.prefix(4000)))
        var language = Locale.current.language.languageCode?.identifier ?? "en"
        if let (guess, confidence) = detector.languageHypotheses(withMaximum: 1).first, confidence >= 0.5 {
            language = guess.rawValue
        }
        let matches = supported.filter { $0.language.languageCode?.identifier == language }
        guard !matches.isEmpty else { return Locale.current }
        if let region = Locale.current.region?.identifier, let m = matches.first(where: { $0.region?.identifier == region }) { return m }
        for wanted in Locale.preferredLanguages {
            if let m = matches.first(where: { $0.identifier.replacingOccurrences(of: "_", with: "-") == wanted }) { return m }
        }
        let usual = ["en": "US", "es": "ES", "pt": "BR", "fr": "FR", "de": "DE", "it": "IT", "nl": "NL", "zh": "CN", "ar": "SA"]
        if let region = usual[language], let m = matches.first(where: { $0.region?.identifier == region }) { return m }
        return matches.min { $0.identifier < $1.identifier } ?? Locale.current
    }

    /// Up to 100 of the script's longer words, so names and rare words are heard right.
    static func contextWords(in script: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in script.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }) {
            let word = String(raw)
            guard word.count >= 5, seen.insert(word.lowercased()).inserted else { continue }
            out.append(word)
            if out.count == 100 { break }
        }
        return out
    }
}

private extension Locale {
    /// "Greek", "English (United States)"…
    func localizedLanguageName(for id: String) -> String {
        localizedString(forIdentifier: id) ?? id
    }
}
