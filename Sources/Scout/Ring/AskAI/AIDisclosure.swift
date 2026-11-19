import Foundation

// Plain words about where Ask AI sends things (App Store guideline 5.1.2): the question, and the picture of the screen while
// Screen is on, go to the provider the user chose (Anthropic or OpenAI), with the user's own key. One place for the words, so the
// Settings page, the Screen chip's tooltip and the empty Ask AI views always say the same thing and name the same company.

enum AIDisclosure {
    /// The company behind a provider, as the user reads it (the provider's own title is the model family: "Claude").
    static func company(_ provider: AIProvider) -> String { provider == .anthropic ? "Anthropic" : "OpenAI" }

    /// The provider the next question goes to: the open chat's, else the one chosen in Settings › Ask AI.
    static func current(_ provider: AIProvider? = nil) -> AIProvider { provider ?? AIModels.defaultProvider }

    /// The Screen chip's and button's tooltip.
    static func screenHelp(_ provider: AIProvider? = nil) -> String {
        String(localized: "Screen: each question takes a picture of your screen and sends it to \(company(current(provider))) with the question")
    }

    /// A few words for the small dashboard views.
    static func goesTo(_ provider: AIProvider? = nil) -> String { String(localized: "Questions go to \(company(current(provider))).") }

    /// The dashboard widget's empty line: where the questions go, and that the answers stay in the widget.
    static func goesToAnswersStayHere(_ provider: AIProvider? = nil) -> String {
        String(localized: "Questions go to \(company(current(provider))). The answers stay here.")
    }

    /// The Fast Ask AI strip's empty line.
    static func askAboveAnswerShowsHere(_ provider: AIProvider? = nil) -> String {
        String(localized: "Ask anything above. Questions go to \(company(current(provider))). The answer shows here.")
    }

    /// The Ask AI panel's empty view (the hint and the disclosure, as two short paragraphs).
    static func panelEmptyText(_ provider: AIProvider? = nil) -> String {
        String(localized: "Ask anything.\nReturn sends, ⌥Return adds a line.\n\nYour questions go to \(company(current(provider))). With Screen on, a picture of your screen goes with them.")
    }

    /// A line for the empty Ask AI views.
    static func emptyLine(_ provider: AIProvider? = nil) -> String {
        String(localized: "Your questions go to \(company(current(provider))). With Screen on, a picture of your screen goes with them.")
    }

    /// The Screen setting's row (Settings › Ask AI).
    static func screenRow(_ provider: AIProvider) -> String {
        String(localized: "Off by default: it starts off and goes back off when the notch closes. While on, each question takes a fresh picture of the screen you are working on and sends it, with the question, to \(company(provider)); Scout's own windows are left out. Also the Screen chip next to the input.")
    }

    /// The footer under the Screen setting.
    static func screenFooter(_ provider: AIProvider) -> String {
        String(localized: "Your question, and the picture when Screen is on, go to \(company(provider)) with your own key. \(company(provider))'s privacy policy applies. Scout's developer receives nothing.")
    }
}
