import AppKit
import Foundation

// B2 Ask AI — data types: JSON values (so assistant content blocks replay unchanged), providers, models, chats.

enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    /// From `JSONSerialization` output.
    static func from(_ any: Any?) -> JSONValue {
        switch any {
        case nil, is NSNull: return .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map { from($0) })
        case let o as [String: Any]: return .object(o.mapValues { from($0) })
        default: return .null
        }
    }

    /// For `JSONSerialization`.
    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }

    static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return from(obj)
    }
}

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case anthropic, openai
    var id: String { rawValue }
    var title: String { self == .anthropic ? "Claude" : "OpenAI" }
    var keychainAccount: String { "ai.\(rawValue)" }
    var keyURL: URL { URL(string: self == .anthropic ? "https://console.anthropic.com/settings/keys" : "https://platform.openai.com/api-keys")! }
    var keyPlaceholder: String { self == .anthropic ? "sk-ant-…" : "sk-…" }
}

struct AIModelInfo: Identifiable, Equatable {
    let id: String
    let title: String
    let provider: AIProvider
}

enum AIModels {
    /// "Auto": Haiku for quick questions, Sonnet for hard ones (see `AIRouter`).
    static let autoID = "auto"
    static let sonnet = "claude-sonnet-5-5"
    static let haiku = "claude-haiku-5-5"
    static let opus = "claude-opus-5-5"

    static let anthropic: [AIModelInfo] = [
        AIModelInfo(id: autoID, title: String(localized: "Auto"), provider: .anthropic),
        AIModelInfo(id: sonnet, title: "Claude Sonnet 5.5", provider: .anthropic),
        AIModelInfo(id: haiku, title: "Claude Haiku 5.5", provider: .anthropic),
        AIModelInfo(id: opus, title: "Claude Opus 5.5", provider: .anthropic),
    ]

    /// One line for the model menu.
    static func blurb(of model: String) -> String? {
        switch model {
        case autoID: String(localized: "Haiku for quick questions, Sonnet for hard ones")
        case sonnet: String(localized: "Strong all-rounder")
        case haiku: String(localized: "Fastest, for short questions")
        case opus: String(localized: "Most capable, slowest")
        default: nil
        }
    }

    static let openaiDefaults = ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-luna"]

    /// The editable OpenAI model list (setting `ai.openai.models`) with the defaults when nothing is saved.
    static var openai: [AIModelInfo] {
        let list = StoredList.strings("ai.openai.models", default: openaiDefaults)
        return list.map { AIModelInfo(id: $0, title: $0, provider: .openai) }
    }

    static func models(for provider: AIProvider) -> [AIModelInfo] { provider == .anthropic ? anthropic : openai }

    static func title(of model: String) -> String {
        (anthropic + openai).first { $0.id == model }?.title ?? model
    }

    /// "Sonnet 5.5", "Haiku 5.5", "Auto", or the OpenAI model name.
    static func shortTitle(of model: String) -> String {
        title(of: model).replacingOccurrences(of: "Claude ", with: "")
    }

    static var defaultProvider: AIProvider { AIProvider(rawValue: UserDefaults.standard.string("ai.provider", default: "anthropic")) ?? .anthropic }

    static func defaultModel(for provider: AIProvider) -> String {
        let saved = UserDefaults.standard.string(forKey: "ai.model.\(provider.rawValue)")
        if let saved, !saved.isEmpty { return saved }
        return provider == .anthropic ? autoID : openaiDefaults[0]
    }

    /// Models whose API supports the server-side refusal fallback (Haiku has none).
    static func usesRefusalFallback(_ model: String) -> Bool { model == opus || model == sonnet }
}

/// Which model answers, and how hard it thinks. Manual picks follow the Quick / Thorough setting.
enum AIRouter {
    struct Route: Equatable {
        var model: String
        /// "low", "medium" or "high".
        var effort: String
    }

    static var manualEffort: String { UserDefaults.standard.string("ai.effort", default: "quick") == "thorough" ? "high" : "low" }

    /// `chatModel` is what the chat's picker says; `history` includes the new user message last.
    static func route(chatModel: String, history: [AIChatMessage]) -> Route {
        guard chatModel == AIModels.autoID else { return Route(model: chatModel, effort: manualEffort) }
        let latest = history.last { $0.role == .user }
        let usedSonnet = history.contains { $0.role == .assistant && $0.model == AIModels.sonnet && !$0.isError }
        let hard = usedSonnet || isHard(text: latest?.text ?? "", hasImage: !(latest?.imageFiles.isEmpty ?? true))
        return hard ? Route(model: AIModels.sonnet, effort: "medium") : Route(model: AIModels.haiku, effort: "low")
    }

    static func isHard(text: String, hasImage: Bool) -> Bool {
        if hasImage { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 280 { return true }
        if trimmed.split(whereSeparator: \.isNewline).count >= 3 { return true }
        if looksLikeCode(trimmed) { return true }
        let words = #"\b(write|draft|explain|analy[sz]e|analysis|compare|debug|fix|plan|review|summari[sz]e|summary|translate)\b"#
        return trimmed.range(of: words, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func looksLikeCode(_ text: String) -> Bool {
        if text.contains("```") { return true }
        let markers = ["func ", "def ", "class ", "=> ", "();", ") {", "</", "#include", "SELECT ", "console.log", "import ", "return ", " != ", " == ", "->"]
        let hits = markers.filter { text.contains($0) }.count
        return hits >= 2 || (text.contains("{") && text.contains("}") && text.contains(";"))
    }
}

struct AISource: Codable, Equatable, Identifiable, Sendable {
    var title: String
    var url: String
    var id: String { url }
    var host: String { URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url }
}

struct AIChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant }

    var id = UUID()
    var role: Role
    /// The user's text, or the assistant's visible answer.
    var text: String
    /// File names in `AppPaths.folder("AIImages")` (user attachments, already downscaled).
    var imageFiles: [String] = []
    /// Assistant only: the FULL content blocks from the API (thinking blocks included), replayed unchanged.
    var blocks: [JSONValue] = []
    var sources: [AISource] = []
    var isError = false
    /// An error whose fix is in Settings › Ask AI: the chat offers a button there. Nil in chats saved before this flag existed.
    var opensSettings: Bool?
    var model: String?
    var date = Date()
}

struct AIChat: Identifiable, Codable, Equatable {
    var id = UUID()
    /// The stored name of a chat with no question yet. It stays English in the file (a language change must not orphan it); `displayTitle` is what a person reads.
    static let untitled = "New chat"
    var title = AIChat.untitled
    var created = Date()
    var updated = Date()
    var provider: AIProvider
    var model: String
    var messages: [AIChatMessage] = []

    /// The chat's name as a person reads it: the two stored placeholder names in the user's language, any other title as it is.
    var displayTitle: String {
        if title == Self.untitled { return String(localized: "New chat") }
        if title == AIChatStore.quickTitle { return String(localized: "Fast Ask AI") }
        return title
    }
}

enum AIKeys {
    /// Scripted runs never read the Keychain and behave as if a key were saved (the canned chat needs none).
    static func key(for provider: AIProvider) -> String? {
        guard !ScoutRuntime.isScripted else { return nil }
        let k = Keychain.get(account: provider.keychainAccount)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (k?.isEmpty ?? true) ? nil : k
    }

    static func hasKey(_ provider: AIProvider) -> Bool { ScoutRuntime.isScripted || key(for: provider) != nil }

    static func save(_ key: String, for provider: AIProvider) {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ScoutRuntime.isScripted else { return }
        if clean.isEmpty { Keychain.delete(account: provider.keychainAccount) } else { try? Keychain.set(clean, account: provider.keychainAccount) }
    }
}

/// Image attachments: downscaled to ≤1568 px on the long edge, saved as PNG in the AIImages folder.
enum AIImages {
    static var folder: URL { AppPaths.folder("AIImages") }

    static func url(_ file: String) -> URL { folder.appendingPathComponent(file) }

    /// Returns the saved file name.
    static func store(_ image: NSImage) -> String? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return store(cgImage: cg)
    }

    /// Monitor's pictures of the screen carry this prefix, so the message can show them as a screen and not a square.
    static let screenPrefix = "screen-"

    static func isScreen(_ file: String) -> Bool { file.hasPrefix(screenPrefix) }

    /// Downscales to the long-edge limit and saves a PNG. Safe off the main thread. `prefix` goes in front of the file name.
    static func store(cgImage cg: CGImage, prefix: String = "") -> String? {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, 1568 / max(w, h))
        let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(origin: .zero, size: size))
        guard let scaled = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: scaled)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let name = "\(prefix)\(UUID().uuidString).png"
        guard (try? png.write(to: url(name))) != nil else { return nil }
        return name
    }

    static func base64(_ file: String) -> String? {
        (try? Data(contentsOf: url(file)))?.base64EncodedString()
    }
}
