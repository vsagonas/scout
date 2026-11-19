import AppKit
import Foundation

// B2 Ask AI — one shared entry point for every AI use in Scout (notes cleanup, summaries, Ask AI itself…).
// Same key, same routing, same error messages as the chat panel.
//
//     let text = try await AIService.shared.complete(prompt: "Fix the grammar: …")
//     let answer = try await AIService.shared.complete(prompt: "What is in this picture?", images: [image], hard: true)

@MainActor
final class AIService {
    static let shared = AIService()

    /// True when some provider has a key (always true in scripted runs, which answer with a sample).
    var isAvailable: Bool { AIKeys.hasKey(.anthropic) || AIKeys.hasKey(.openai) }

    /// Asks once and returns the full answer. `hard` sends it to Sonnet (medium effort); otherwise Haiku (low).
    /// Images are downscaled like in the chat. Throws `AIError` with a plain-English message.
    func complete(prompt: String, images: [NSImage] = [], hard: Bool = false, system: String? = nil) async throws -> String {
        if ScoutRuntime.isScripted { return "Sample answer from a scripted run — no network is used." }
        let provider: AIProvider
        if AIKeys.key(for: .anthropic) != nil { provider = .anthropic }
        else if AIKeys.key(for: .openai) != nil { provider = .openai }
        else { throw AIError(message: String(localized: "Add your Claude API key in Settings › Ask AI first."), opensSettings: true) }
        guard let key = AIKeys.key(for: provider) else { throw AIError(message: String(localized: "Add your API key in Settings › Ask AI first."), opensSettings: true) }

        let files = images.compactMap { AIImages.store($0) }
        defer { for f in files { try? FileManager.default.removeItem(at: AIImages.url(f)) } }
        let route: AIRouter.Route
        if provider == .anthropic {
            let isHard = hard || !images.isEmpty
            route = AIRouter.Route(model: isHard ? AIModels.sonnet : AIModels.haiku, effort: isHard ? "medium" : "low")
        } else {
            route = AIRouter.Route(model: AIModels.defaultModel(for: .openai), effort: "low")
        }
        let request = AIClient.Request(provider: provider, model: route.model, history: [AIChatMessage(role: .user, text: prompt, imageFiles: files)],
                                       webSearch: false, effort: route.effort, apiKey: key, system: system)
        let result = try await AIClient.stream(request) { _ in }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw AIError(message: String(localized: "The model didn't send an answer. Try again.")) }
        return text
    }
}

/// Imports an API key that was dropped at `import/anthropic.key` in Scout's support folder:
/// saves it to the Keychain, then deletes the file. The key is never logged or printed.
/// Not in the App Store edition: there the folder is inside the sandbox container, which nobody else can reach, so
/// the user pastes the key in Settings › Ask AI.
#if !APPSTORE
enum AIKeyImport {
    static func run() {
        guard !ScoutRuntime.isScripted else { return }
        let folder = AppPaths.support.appendingPathComponent("import", isDirectory: true)
        let file = folder.appendingPathComponent("anthropic.key")
        guard FileManager.default.fileExists(atPath: file.path),
              let raw = try? String(contentsOf: file, encoding: .utf8) else { return }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { try? FileManager.default.removeItem(at: file); return }
        do {
            try Keychain.set(key, account: AIProvider.anthropic.keychainAccount)
        } catch {
            return   // leave the file for the next launch
        }
        try? FileManager.default.removeItem(at: file)
        if let rest = try? FileManager.default.contentsOfDirectory(atPath: folder.path), rest.allSatisfy({ $0 == ".DS_Store" }) {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
#endif
