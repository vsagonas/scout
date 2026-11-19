import AppKit
import SwiftUI
#if DEBUG
import Vision
#endif

/// `scout://l10n.selftest?out=<file>` (headless runs): the translations and the pseudo language.
///   build/Scout.app/Contents/MacOS/Scout --automation --headless --run "scout://l10n.selftest?out=<file>" & PID=$!
/// then wait for the file and `kill $PID`. With a build made by `SCOUT_PSEUDO=1 scripts/build-app.sh debug` and `SCOUT_LANG=pseudo`, it also
/// draws sample gallery views in the pseudo language and reads them with the Vision text recognizer: a line that holds one of the app's English
/// sentences (the keys of l10n/en/Localizable.strings) with no `[!` `!]` marker and no accented letter around it is a string that skips
/// localization. A one-word key alone on a line counts too, unless the word is in l10n/pseudo-allow-words.txt (a brand or an app name that is data).
/// Debug builds only (it reads the repository's l10n folder); a release build reports "skipped".
@MainActor
enum L10nSelfTest {
    static func register() {
        DebugCommands.register("l10n.selftest") { params in
            guard ScoutRuntime.isAutomation else { return }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("l10n-selftest.txt")
            Task { @MainActor in await run(out: out) }
        }
    }

    /// Six words every language must have translated (a language may keep one or two of them when its word is the English one).
    static let sampleKeys = ["Cancel", "Settings", "Search", "Delete", "Dashboard", "Close"]

    /// Gallery views the pseudo-language check draws: the dashboard widgets, Settings panes, Agents, Ask AI, Calendar, Clipboard, Prompter,
    /// Radio, Mirror and the closed notch. Names that do not exist in this build are skipped.
    static let sampleViews = [
        "dash-agents", "dash-expanded", "dash-header", "dash-live", "dash90-today", "dash90-pulse", "dash90-media", "widget-clipboard",
        "settings-general", "settings-appearance", "settings-notch", "settings-nook", "settings-permissions", "settings-shortcuts", "agents-settings",
        "settings-askai", "settings-calendar", "settings-clipboard", "settings-prompter", "settings-radio", "settings-about",
        "agents-workspace", "agents-grid", "agents-widget", "askai-notch", "calendar-merged", "prompter-panel", "radio-boombox", "mirror-widget",
        "mirror-view", "notch-closed", "live-meeting", "live-timer", "live-downloads", "weather-widget", "tray-workspace", "tv-dash",
    ]

    #if DEBUG
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()   // Core, Scout, Sources, the repository
    }

    private static func strings(at url: URL) -> [String: String]? { NSDictionary(contentsOf: url) as? [String: String] }

    private static let placeholderRegex = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?[-+ 0#]*(?:\\d+|\\*)?(?:\\.(?:\\d+|\\*))?(?:hh|h|ll|l|q|z|t|L)?[@dDuUxXoOfeEgGcCsSpaA%]")

    private static func placeholders(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return placeholderRegex.matches(in: text, range: range).map { m in
            let raw = (text as NSString).substring(with: m.range)
            return raw.replacingOccurrences(of: "\\d+\\$", with: "", options: .regularExpression)
        }.sorted()
    }

    private static func words(_ text: String) -> [String] {
        text.split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 && $0.allSatisfy(\.isASCII) && $0.lowercased().contains(where: { "aeiouy".contains($0) }) }
    }

    private static let accents = Set("àéîöüÀÉÎÖÜýÝ")

    /// The English app phrases (three words, or two long ones, or one word of 5 letters) with their placeholders cut out, lower case, for the leak check.
    private static func phrases(of keys: some Sequence<String>) -> (many: [String], single: Set<String>) {
        var many: [String] = [], single = Set<String>()
        for key in keys {
            let plain = placeholderRegex.stringByReplacingMatches(in: key, range: NSRange(key.startIndex..., in: key), withTemplate: "\u{1}")
            for part in plain.split(separator: "\u{1}") {
                let text = part.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ").trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
                let wordCount = text.split(separator: " ").count
                if (wordCount >= 3 && text.count >= 12) || (wordCount == 2 && text.count >= 16) { many.append(text) } else if wordCount == 1 && text.count >= 5 && text.allSatisfy(\.isASCII) { single.insert(text) }
            }
        }
        return (many, single)
    }

    /// OCR lines of a drawn view that show an English app sentence with no pseudo-language marker around it: a sentence that skipped localization.
    /// (Sample data such as agent names, chats and events is not in the key list, so it is never flagged.)
    private static func leaks(in rep: NSBitmapImageRep, phrases: (many: [String], single: Set<String>), allowed: Set<String>) -> [String] {
        guard let cg = rep.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        var found: [String] = []
        for observation in request.results ?? [] {
            guard let line = observation.topCandidates(1).first?.string else { continue }
            if line.contains("[!") || line.contains("!]") || line.contains(where: { accents.contains($0) }) { continue }
            let trimmed = line.drop { !$0.isLetter && !$0.isNumber && $0 != "!" }
            if let first = trimmed.first, "!Il|1".contains(first), trimmed.dropFirst().allSatisfy({ !$0.isLowercase }) { continue }   // a pixel-font word: !WORKING!
            let text = line.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let bare = text.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces).union(CharacterSet(charactersIn: "•·")))
            if phrases.many.contains(where: { text.contains($0) }) || (phrases.single.contains(bare) && !allowed.contains(bare)) { found.append(line) }
        }
        return found
    }
    #endif

    static func run(out: URL) async {
        var lines: [String] = []
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failed += 1 }
            lines.append("l10n selftest \(ok ? "ok  " : "FAIL") \(name)\(ok || detail.isEmpty ? "" : "  (\(detail))")")
        }
        func note(_ text: String) { lines.append("l10n selftest note \(text)") }

        #if DEBUG
        let root = repoRoot
        let fm = FileManager.default
        let l10n = root.appendingPathComponent("l10n")
        guard let en = strings(at: l10n.appendingPathComponent("en/Localizable.strings")),
              let enInfo = strings(at: l10n.appendingPathComponent("en/InfoPlist.strings")) else {
            check("l10n/en/Localizable.strings and InfoPlist.strings exist and parse", false, root.path)
            finish(lines, failed, out); return
        }
        check("the English files parse (\(en.count) keys, \(enInfo.count) permission texts)", en.count > 100 && enInfo.count >= 10)
        check("every English value is its key (the sentence is the key)", en.allSatisfy { $0.key == $0.value })
        check("the key '%@' (finished text shown as it is) is in the English file", en["%@"] != nil)

        // The two Info.plists declare the same languages, with en as the development region, and never the pseudo language.
        var declared: [String: Set<String>] = [:]
        for name in ["Info.plist", "Info-AppStore.plist"] {
            let plist = NSDictionary(contentsOf: root.appendingPathComponent("Support/\(name)")) as? [String: Any] ?? [:]
            declared[name] = Set(plist["CFBundleLocalizations"] as? [String] ?? [])
            check("\(name): development region is en", (plist["CFBundleDevelopmentRegion"] as? String) == "en")
            check("\(name): CFBundleLocalizations has en and not the pseudo language", declared[name]?.contains("en") == true && declared[name]?.contains("pseudo") == false, "\(declared[name] ?? [])")
        }
        check("Info.plist and Info-AppStore.plist declare the same languages", declared["Info.plist"] == declared["Info-AppStore.plist"])

        // Every .lproj in this bundle.
        let resources = Bundle.main.resourceURL
        let folders = ((try? fm.contentsOfDirectory(atPath: resources?.path ?? "")) ?? []).filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(6)) }.sorted()
        // `ar` is the pseudo text too (a marker file) in a pseudo build with no real Arabic yet: it tests the right-to-left layout.
        let pseudoRTL = resources.map { fm.fileExists(atPath: $0.appendingPathComponent("ar.lproj/.pseudo-rtl").path) } ?? false
        let real = folders.filter { $0 != "pseudo" && $0 != "Base" && !($0 == "ar" && pseudoRTL) }
        let infoLocalizations = Set(Bundle.main.infoDictionary?["CFBundleLocalizations"] as? [String] ?? [])
        if folders.isEmpty {
            note("skipped: this bundle has no .lproj folder yet (no translations, no pseudo language)")
        } else {
            // Every shipped folder is declared; the declared languages whose folder is still missing are listed (a failure once SCOUT_L10N_COMPLETE=1).
            let shipped = Set(real + (folders.contains("pseudo") ? ["pseudo"] : []) + (pseudoRTL ? ["ar"] : []))
            check("every .lproj folder of the bundle is in CFBundleLocalizations", infoLocalizations.isSuperset(of: shipped), "declared \(infoLocalizations.sorted()), folders \(shipped.sorted())")
            let notShipped = infoLocalizations.subtracting(shipped).subtracting(["en"]).sorted()
            if ProcessInfo.processInfo.environment["SCOUT_L10N_COMPLETE"] == "1" {
                check("CFBundleLocalizations equals the .lproj folders plus en", notShipped.isEmpty, "declared but not shipped: \(notShipped)")
            } else if !notShipped.isEmpty {
                note("declared in CFBundleLocalizations but no .lproj yet: \(notShipped.count) languages (\(notShipped.joined(separator: " ")))")
            }
        }
        for code in folders {
            let folder = resources!.appendingPathComponent("\(code).lproj")
            guard let tr = strings(at: folder.appendingPathComponent("Localizable.strings")) else {
                check("\(code): Localizable.strings parses", false); continue
            }
            let missing = Set(en.keys).subtracting(tr.keys), extra = Set(tr.keys).subtracting(en.keys)
            check("\(code): same keys as English", missing.isEmpty && extra.isEmpty, "missing \(Array(missing.sorted().prefix(3))), extra \(Array(extra.sorted().prefix(3)))")
            let badPlaceholders = en.keys.filter { key in tr[key].map { placeholders($0) != placeholders(key) } ?? false }
            check("\(code): placeholders match English in every value", badPlaceholders.isEmpty, "\(Array(badPlaceholders.sorted().prefix(3)))")
            if let info = strings(at: folder.appendingPathComponent("InfoPlist.strings")) {
                check("\(code): InfoPlist.strings keys are permission texts of this edition", Set(info.keys).isSubset(of: Set(enInfo.keys)) && !info.keys.contains { $0.hasSuffix("~appstore") })
            } else {
                check("\(code): InfoPlist.strings parses", false)
            }
            // A runtime lookup through that language's own table returns the translation.
            let bundle = Bundle(path: folder.path)
            let translated = sampleKeys.filter { key in (bundle?.localizedString(forKey: key, value: nil, table: nil) ?? key) != key }
            if code == "pseudo" || (code == "ar" && pseudoRTL) {
                check("\(code): \(sampleKeys.count) sample keys come back wrapped as [! ... !]", sampleKeys.allSatisfy { (bundle?.localizedString(forKey: $0, value: nil, table: nil) ?? "").hasPrefix("[!") })
            } else {
                check("\(code): at least 4 of the 6 sample keys come back translated", translated.count >= 4, "\(translated)")
                if let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3"].first(where: { fm.isExecutableFile(atPath: $0) }) {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: python)
                    process.arguments = [root.appendingPathComponent("scripts/l10n/check.py").path, code]
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    try? process.run()
                    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    process.waitUntilExit()
                    check("\(code): scripts/l10n/check.py finds no error", process.terminationStatus == 0, text.split(separator: "\n").filter { $0.hasPrefix("ERROR") }.prefix(3).joined(separator: " | "))
                }
            }
        }

        note("running language: preferred \(Bundle.main.preferredLocalizations), locale \(Locale.current.identifier), app layout direction \(NSApp.userInterfaceLayoutDirection == .rightToLeft ? "right to left" : "left to right"), character direction of ar \(NSLocale.characterDirection(forLanguage: "ar").rawValue), of the locale \(Locale.current.language.characterDirection), a new view \(NSView().userInterfaceLayoutDirection == .rightToLeft ? "right to left" : "left to right"), AppleLanguages \(UserDefaults.standard.array(forKey: "AppleLanguages") ?? []), NSForceRightToLeft \(UserDefaults.standard.bool(forKey: "NSForceRightToLeftWritingDirection"))")
        // The language this run was started in (SCOUT_LANG, or English).
        let language = ProcessInfo.processInfo.environment["SCOUT_LANG"] ?? "en"
        if folders.contains(language) {
            let folder = resources!.appendingPathComponent("\(language).lproj")
            let table = strings(at: folder.appendingPathComponent("Localizable.strings")) ?? [:]
            let sample = sampleKeys.compactMap { key in table[key].map { (key, $0) } }
            let live = sample.filter { Bundle.main.localizedString(forKey: $0.0, value: nil, table: nil) == $0.1 }
            check("a lookup in the running app (language \(language)) gives the translation for \(sample.count) sample keys", live.count == sample.count && !sample.isEmpty, "\(live.count) of \(sample.count)")
        } else if language == "en" {
            note("skipped: the running language is English (the keys are the English text); run with SCOUT_LANG=<code> for a runtime lookup")
        } else {
            check("the language \(language) of this run has a .lproj in the bundle", false, "folders \(folders)")
        }

        // The pseudo language: no sampled view shows an unwrapped English string.
        if (language == "pseudo" || (language == "ar" && pseudoRTL)) && folders.contains(language) {
            var allowed = Set<String>()
            if let text = try? String(contentsOf: l10n.appendingPathComponent("pseudo-allow-words.txt"), encoding: .utf8) {
                allowed = Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty && !$0.hasPrefix("#") })
            }
            if Gallery.items.isEmpty { Modules.registerGalleryAll() }
            // SCOUT_L10N_VIEWS=all (or a comma list of name prefixes) draws more views and only lists what it found (for hunting leaks).
            let wide = ProcessInfo.processInfo.environment["SCOUT_L10N_VIEWS"]
            var chosen: [Gallery.Item] = []
            if let wide {
                let prefixes = wide.split(separator: ",").map(String.init)
                chosen = Gallery.items.filter { item in wide == "all" || prefixes.contains { item.name.hasPrefix($0) } }
            } else {
                for name in sampleViews { chosen += Gallery.items.filter { $0.name == name || $0.name.hasPrefix(name + "-") }.prefix(3) }
            }
            let phrasesOfEnglish = phrases(of: en.keys)
            var drawn = 0
            var counts: [String: Int] = [:]
            for item in chosen {
                guard let rep = await Gallery.renderImage(item, scheme: .light) else { continue }
                drawn += 1
                let found = leaks(in: rep, phrases: phrasesOfEnglish, allowed: allowed)
                for line in found { for w in words(line) where !allowed.contains(w.lowercased()) { counts[w.lowercased(), default: 0] += 1 } }
                if wide == nil {
                    check("pseudo: \(item.name) shows no unwrapped English", found.isEmpty, found.prefix(4).joined(separator: " | "))
                } else if !found.isEmpty {
                    note("leak \(item.name): \(found.prefix(6).joined(separator: " | "))")
                }
            }
            if wide != nil { note("words not in the allow list: " + counts.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")) }
            check("pseudo: sample views were drawn (\(drawn))", drawn >= 20, "\(drawn)")
        } else {
            note("skipped: the pseudo-language view check needs SCOUT_PSEUDO=1 scripts/build-app.sh debug and SCOUT_LANG=pseudo")
        }
        #else
        note("skipped: release build (this test reads the repository's l10n folder)")
        #endif
        finish(lines, failed, out)
    }

    private static func finish(_ lines: [String], _ failed: Int, _ out: URL) {
        var all = lines
        all.append("l10n selftest done: \(failed == 0 ? "all passed" : "\(failed) FAILED")")
        for line in all { print(line) }
        fflush(stdout)
        try? all.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
    }
}
