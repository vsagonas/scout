import SwiftUI

// Localization helpers (the English sentence is the key; Foundation looks it up in Bundle.main, never Bundle.module).
// - SwiftUI literals (Text, Button, Label, Toggle, .help, .accessibilityLabel, kit parameters typed LocalizedStringKey) localize themselves.
// - Everywhere else: String(localized: "English sentence"). Never build a sentence from pieces; use one sentence with placeholders.
// - User data (agent, project, file and station names, chat text, clipboard) is never localized: Text(verbatim:), or .verbatim(_:) below.

extension LocalizedStringKey {
    /// Words that are already final (a user's own text, or text built with `String(localized:)`) for a kit parameter that takes a
    /// `LocalizedStringKey`: shown exactly as they are, never looked up and never read as Markdown (the string is an interpolation argument).
    static func verbatim(_ text: String) -> LocalizedStringKey { "\(text)" }
}

// MARK: - Words drawn in the pixel font

/// A fixed word drawn in the 5x7 pixel font (WORKING, NEEDS YOU, AGENT TV, NO AGENTS…). The key is the English word in capitals, written as a plain
/// string literal. In the 8-bit look the translation is used when the pixel font can draw all of it (an accent folds to its plain letter); a
/// translation with a letter the font lacks (Greek, Cyrillic, Arabic, Chinese, Japanese, Korean…) falls back to the English word, because the font
/// draws a blank cell for it. The minimal look uses the system font, so it always shows the translation.
/// `scripts/l10n/extract.py` reads these literals (the compiler only sees literals typed as LocalizedStringKey or String(localized:)).
func pixelLabel(_ english: StaticString) -> String {
    let key = english.description
    let local = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    if local == key || !Retro.is8bit { return local }
    return local.allSatisfy { LEDFont.hasGlyph($0) } ? local : key
}

// MARK: - Language of scripted runs

enum L10nRuntime {
    /// True when a scripted run was asked for a right-to-left language (`SCOUT_LANG=ar`): galleries then draw with a right-to-left layout, like a
    /// real window on a Mac set to Arabic (AppKit would not flip a scripted run by itself).
    static var scriptedLanguageIsRightToLeft: Bool {
        guard ScoutRuntime.isScripted, let code = ProcessInfo.processInfo.environment["SCOUT_LANG"], !code.isEmpty else { return false }
        return Locale.Language(identifier: code).characterDirection == .rightToLeft
    }

    /// Scripted runs (galleries, self-tests, automation) show English unless `SCOUT_LANG=<code>` says otherwise (`pt-BR`, `ar`, `pseudo`…), so the
    /// self-tests, which read English words, pass on a Mac whose language is Greek. The same as the launch arguments
    /// `-AppleLanguages (<code>) -AppleLocale <code>` (scripts/gallery.sh passes those too); `pseudo` is the generated test language (debug builds
    /// made with SCOUT_PSEUDO=1) and formats numbers and dates like en_US. A normal launch is never touched: the system's languages decide.
    static func applyScriptedLanguage() {
        guard ScoutRuntime.isScripted else { return }
        let code = ProcessInfo.processInfo.environment["SCOUT_LANG"].flatMap { $0.isEmpty ? nil : $0 } ?? "en"
        let locale = code == "pseudo" ? "en_US" : code.replacingOccurrences(of: "-", with: "_")
        var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        domain["AppleLanguages"] = [code]
        domain["AppleLocale"] = locale
        UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }
}
