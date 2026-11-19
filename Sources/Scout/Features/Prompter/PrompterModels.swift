import AppKit
import SwiftUI

// MARK: - Scripts

struct PrompterScript: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var text: String
    var updated = Date()

    var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
}

enum PrompterPrefs {
    static let fontSize = "prompter.fontSize"      // 18...48, default 28
    static let wpm = "prompter.wpm"                // words per minute for Steady, default 150
    static let mirror = "prompter.mirror"          // flip the text (for a glass prompter)
    static let language = "prompter.language"      // "" = system language
    static let showWords = "prompter.showWords"    // show the words Scout hears (Voice)
    static let mode = "prompter.mode"              // "steady" | "voice"
    static let script = "prompter.script"          // id of the chosen script
}

@MainActor
final class ScriptStore: ObservableObject {
    static let shared = ScriptStore()

    @Published var scripts: [PrompterScript] = []
    private let file = JSONFile<[PrompterScript]>("prompter-scripts.json")
    private let saver = Debouncer(delay: 0.6)
    private var loaded = false

    func load() {
        guard !loaded else { return }
        loaded = true
        scripts = file.load() ?? []
        if scripts.isEmpty { scripts = [Self.sample] ; file.save(scripts) }
    }

    var selectedID: UUID? {
        get { UUID(uuidString: Pref.string(PrompterPrefs.script, "")) }
        set { Pref.set(newValue?.uuidString, PrompterPrefs.script); objectWillChange.send() }
    }

    var selected: PrompterScript? {
        scripts.first { $0.id == selectedID } ?? scripts.first
    }

    func update(_ script: PrompterScript) {
        guard let i = scripts.firstIndex(where: { $0.id == script.id }) else { return }
        var s = script
        s.updated = Date()
        scripts[i] = s
        saver.call { [weak self] in
            guard let self else { return }
            self.file.save(self.scripts)
        }
    }

    @discardableResult
    func add() -> PrompterScript {
        let s = PrompterScript(title: String(localized: "Untitled script"), text: "")
        scripts.insert(s, at: 0)
        selectedID = s.id
        file.save(scripts)
        return s
    }

    func delete(_ id: UUID) {
        scripts.removeAll { $0.id == id }
        if scripts.isEmpty { scripts = [Self.sample] }
        if selectedID == id { selectedID = scripts.first?.id }
        file.save(scripts)
    }

    static let sample = PrompterScript(
        title: String(localized: "Welcome to the Prompter"),
        text: String(localized: """
        Hello, and thanks for joining. I'm reading this from the notch, right under the camera, so my eyes stay where they should.

        The words move at a steady pace, and I can speed them up or slow them down with the arrow keys. Space pauses, and Escape closes the Prompter.

        This window is hidden from screen sharing and recordings, so only I can see it. Everyone else just sees me looking at them.

        In Voice mode the script follows me instead. I read at my own speed, Scout listens on this Mac, and the text keeps up with what I say. If I skip a line, it finds my place again.

        That's all there is to it. Write your own script, press Start, and look into the lens.
        """))
}

// MARK: - Words and matching

struct ScriptWord {
    let norm: String
    let range: NSRange
    var speakable: Bool { !norm.isEmpty }
}

enum ScriptText {
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func words(in text: String) -> [ScriptWord] {
        var result: [ScriptWord] = []
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: #"\S+"#) else { return [] }
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let r = match?.range else { return }
            result.append(ScriptWord(norm: normalize(ns.substring(with: r)), range: r))
        }
        return result
    }

    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// Are a spoken word and a script word the same word (allowing small recognition slips)?
    static func similar(_ spoken: String, _ script: String, partial: Bool) -> Bool {
        if spoken == script { return true }
        let a = Array(spoken), b = Array(script)
        if partial, a.count >= 3, script.hasPrefix(spoken) { return true }
        let longest = max(a.count, b.count)
        if longest <= 3 { return false }
        let d = distance(a, b)
        if longest <= 5 { return d <= 1 }
        return Double(d) / Double(longest) <= 0.28
    }
}

/// Follows a reader through a script: feed it what the recognizer heard, it moves the cursor.
final class ScriptMatcher: @unchecked Sendable {
    let words: [ScriptWord]
    /// Words before this index have been read.
    private(set) var cursor = 0
    private var consumed = 0
    private var unmatched: [String] = []
    private let lookahead = 8

    init(text: String) { words = ScriptText.words(in: text) }

    var isFinished: Bool { cursor >= words.count }

    func reset() { cursor = 0; consumed = 0; unmatched = [] }

    /// A new recognition request starts counting its transcript from zero.
    func newRequest() { consumed = 0 }

    /// `transcript` is everything one request has heard so far (words); `isFinal` when that request ended.
    @discardableResult
    func update(transcript: [String], isFinal: Bool) -> Int {
        while consumed < transcript.count {
            let word = ScriptText.normalize(transcript[consumed])
            let lastPartial = !isFinal && consumed == transcript.count - 1
            consumed += 1
            guard !word.isEmpty else { continue }
            if let j = find(word, partial: lastPartial) {
                cursor = next(after: j)
                unmatched = []
            } else if !lastPartial {
                unmatched.append(word)
                if unmatched.count >= 3 { resync() }
            }
        }
        return cursor
    }

    private func next(after index: Int) -> Int {
        var i = index + 1
        while i < words.count, !words[i].speakable { i += 1 }
        return i
    }

    private func find(_ spoken: String, partial: Bool) -> Int? {
        var j = cursor
        while j < words.count, j <= cursor + lookahead {
            if words[j].speakable, ScriptText.similar(spoken, words[j].norm, partial: partial) { return j }
            j += 1
        }
        return nil
    }

    /// The reader skipped ahead (or back): look for the last few words anywhere near the cursor.
    private func resync() {
        let tail = Array(unmatched.suffix(3))
        defer { unmatched = Array(unmatched.suffix(5)) }
        guard tail.count >= 2 else { return }
        var best: (index: Int, distance: Int)?
        let lower = max(0, cursor - 60), upper = min(words.count - tail.count, cursor + 120)
        guard lower <= upper else { return }
        for i in lower...upper {
            var ok = true
            for (k, w) in tail.enumerated() where !(words[i + k].speakable && ScriptText.similar(w, words[i + k].norm, partial: false)) { ok = false; break }
            if ok {
                let d = abs(i - cursor)
                if best == nil || d < best!.distance { best = (i, d) }
            }
        }
        if let best {
            cursor = next(after: best.index + tail.count - 1)
            unmatched = []
        }
    }
}
