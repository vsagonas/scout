import Foundation

// Ask AI: talking to the APIs (raw HTTPS + SSE).

struct AIError: LocalizedError {
    var message: String
    /// The fix is in Settings › Ask AI: the chat shows a button there under the message.
    var opensSettings = false
    var errorDescription: String? { message }
}

/// What the UI sees while an answer streams in.
struct AIStreamState: Sendable {
    var text = ""
    var blocks: [JSONValue] = []
    var sources: [AISource] = []
    var searching = false
    var stopReason = ""
}

enum AIPrompts {
    static let system = """
    You are a short, direct helper living in a small floating panel on the user's Mac. Answer plainly and get to the point. \
    Markdown is fine (short lists, code blocks). You can't see the user's screen or files, only images they attach in this chat.
    """
}

// MARK: - Anthropic stream accumulator (pure; unit-testable with a canned transcript)

struct AnthropicAccumulator {
    /// Blocks of earlier passes (pause_turn continuations) come first.
    var finished: [JSONValue] = []
    private var current: [Int: [String: JSONValue]] = [:]
    private var partialInput: [Int: String] = [:]
    var sources: [AISource] = []
    var searching = false
    var stopReason = ""
    var errorMessage: String?

    var allBlocks: [JSONValue] {
        finished + current.keys.sorted().compactMap { current[$0] }.map { JSONValue.object($0) }
    }

    var text: String {
        allBlocks.compactMap { b -> String? in b["type"]?.string == "text" ? b["text"]?.string : nil }.joined()
    }

    /// Blocks safe to send back: no empty text blocks.
    static func replayable(_ blocks: [JSONValue]) -> [JSONValue] {
        blocks.filter { !($0["type"]?.string == "text" && ($0["text"]?.string ?? "").isEmpty) }
    }

    /// Moves this pass's blocks into `finished` (before a pause_turn continuation).
    mutating func endPass() {
        finished = allBlocks
        current = [:]
        partialInput = [:]
    }

    mutating func process(_ event: JSONValue) {
        guard let type = event["type"]?.string else { return }
        switch type {
        case "content_block_start":
            guard let index = event["index"].flatMap(Self.int), var block = event["content_block"]?.object else { return }
            switch block["type"]?.string {
            case "text": if block["text"] == nil { block["text"] = .string("") }
            case "thinking": if block["thinking"] == nil { block["thinking"] = .string("") }
            case "server_tool_use":
                partialInput[index] = ""
                if block["name"]?.string == "web_search" { searching = true }
            case "web_search_tool_result":
                searching = false
                if let results = block["content"]?.array {
                    for r in results {
                        if let url = r["url"]?.string, !sources.contains(where: { $0.url == url }) {
                            sources.append(AISource(title: r["title"]?.string ?? url, url: url))
                        }
                    }
                }   // an error comes back as an object instead of a list: no sources, the answer continues
            default: break
            }
            current[index] = block
        case "content_block_delta":
            guard let index = event["index"].flatMap(Self.int), let delta = event["delta"], var block = current[index] else { return }
            switch delta["type"]?.string {
            case "text_delta":
                block["text"] = .string((block["text"]?.string ?? "") + (delta["text"]?.string ?? ""))
            case "thinking_delta":
                block["thinking"] = .string((block["thinking"]?.string ?? "") + (delta["thinking"]?.string ?? ""))
            case "signature_delta":
                block["signature"] = .string((block["signature"]?.string ?? "") + (delta["signature"]?.string ?? ""))
            case "input_json_delta":
                partialInput[index, default: ""] += delta["partial_json"]?.string ?? ""
            case "citations_delta":
                if let citation = delta["citation"] {
                    var list = block["citations"]?.array ?? []
                    list.append(citation)
                    block["citations"] = .array(list)
                    if let url = citation["url"]?.string, !sources.contains(where: { $0.url == url }) {
                        sources.append(AISource(title: citation["title"]?.string ?? url, url: url))
                    }
                }
            default: break
            }
            current[index] = block
        case "content_block_stop":
            guard let index = event["index"].flatMap(Self.int) else { return }
            if let json = partialInput[index], var block = current[index] {
                block["input"] = json.isEmpty ? .object([:]) : (JSONValue.parse(json) ?? .object([:]))
                current[index] = block
                partialInput[index] = nil
            }
        case "message_delta":
            if let reason = event["delta"]?["stop_reason"]?.string { stopReason = reason }
        case "error":
            errorMessage = event["error"]?["message"]?.string ?? String(localized: "The service reported an error.")
        default: break   // message_start, ping, message_stop
        }
    }

    private static func int(_ v: JSONValue) -> Int? {
        if case .number(let n) = v { return Int(n) }
        return nil
    }
}

// MARK: - OpenAI accumulator

struct OpenAIAccumulator {
    var text = ""
    var sources: [AISource] = []
    var searching = false
    var errorMessage: String?
    var done = false

    mutating func process(_ event: JSONValue) {
        switch event["type"]?.string {
        case "response.output_text.delta":
            searching = false
            text += event["delta"]?.string ?? ""
        case "response.web_search_call.searching", "response.web_search_call.in_progress":
            searching = true
        case "response.output_text.annotation.added":
            if let a = event["annotation"], a["type"]?.string == "url_citation", let url = a["url"]?.string, !sources.contains(where: { $0.url == url }) {
                sources.append(AISource(title: a["title"]?.string ?? url, url: url))
            }
        case "response.completed":
            done = true
            // Annotations may only appear on the final response object.
            for item in event["response"]?["output"]?.array ?? [] {
                for part in item["content"]?.array ?? [] {
                    for a in part["annotations"]?.array ?? [] where a["type"]?.string == "url_citation" {
                        if let url = a["url"]?.string, !sources.contains(where: { $0.url == url }) {
                            sources.append(AISource(title: a["title"]?.string ?? url, url: url))
                        }
                    }
                }
            }
        case "response.failed":
            errorMessage = event["response"]?["error"]?["message"]?.string ?? String(localized: "The request failed.")
        case "error":
            errorMessage = event["message"]?.string ?? event["error"]?["message"]?.string ?? String(localized: "The service reported an error.")
        default: break
        }
    }
}

// MARK: - The client

enum AIClient {
    struct Request {
        var provider: AIProvider
        var model: String
        var history: [AIChatMessage]
        var webSearch: Bool
        var effort: String   // "low", "medium" or "high"
        var apiKey: String
        /// nil = the standard helper prompt.
        var system: String?
    }

    static let refusalText = String(localized: "Claude can't help with that one.")

    // MARK: Entry point

    static func stream(_ request: Request, onUpdate: @escaping @Sendable (AIStreamState) -> Void) async throws -> AIStreamState {
        switch request.provider {
        case .anthropic: return try await streamAnthropic(request, onUpdate: onUpdate)
        case .openai: return try await streamOpenAI(request, onUpdate: onUpdate)
        }
    }

    // MARK: Anthropic

    static func anthropicMessages(from history: [AIChatMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for m in history where !m.isError {
            switch m.role {
            case .user:
                var content: [[String: Any]] = []
                for file in m.imageFiles {
                    if let data = AIImages.base64(file) {
                        content.append(["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": data]])
                    }
                }
                if !m.text.isEmpty { content.append(["type": "text", "text": m.text]) }
                if content.isEmpty { continue }
                out.append(["role": "user", "content": content])
            case .assistant:
                let blocks = AnthropicAccumulator.replayable(m.blocks)
                if !blocks.isEmpty {
                    out.append(["role": "assistant", "content": blocks.map(\.any)])
                } else if !m.text.isEmpty {
                    out.append(["role": "assistant", "content": [["type": "text", "text": m.text]]])
                }
            }
        }
        return out
    }

    static func anthropicBody(_ r: Request, messages: [[String: Any]]) -> [String: Any] {
        var body: [String: Any] = [
            "model": r.model,
            "max_tokens": 32000,
            "stream": true,
            "system": r.system ?? AIPrompts.system,
            "messages": messages,
            "output_config": ["effort": r.effort],
        ]
        if r.webSearch {
            let type = r.model.contains("haiku") ? "web_search_20250305" : "web_search_20260209"
            body["tools"] = [["type": type, "name": "web_search", "max_uses": 5]]
        }
        if AIModels.usesRefusalFallback(r.model) { body["fallbacks"] = "default" }
        return body
    }

    private static func streamAnthropic(_ r: Request, onUpdate: @escaping @Sendable (AIStreamState) -> Void) async throws -> AIStreamState {
        let base = anthropicMessages(from: r.history)
        var acc = AnthropicAccumulator()
        var lastFlush = Date.distantPast

        func flush(force: Bool = false) {
            guard force || Date().timeIntervalSince(lastFlush) > 0.04 else { return }
            lastFlush = Date()
            onUpdate(AIStreamState(text: acc.text, blocks: acc.allBlocks, sources: acc.sources, searching: acc.searching, stopReason: acc.stopReason))
        }

        for _ in 0..<6 {
            var messages = base
            if !acc.finished.isEmpty { messages.append(["role": "assistant", "content": AnthropicAccumulator.replayable(acc.finished).map(\.any)]) }
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 300)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.setValue(r.apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            if AIModels.usesRefusalFallback(r.model) { req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
            req.httpBody = try JSONSerialization.data(withJSONObject: anthropicBody(r, messages: messages))

            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            try await checkStatus(response, bytes: bytes, provider: .anthropic)
            acc.stopReason = ""
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let event = JSONValue.parse(payload) else { continue }
                acc.process(event)
                if let message = acc.errorMessage { throw AIError(message: friendly(message: message, status: 0)) }
                flush()
            }
            flush(force: true)
            if acc.stopReason == "pause_turn" { acc.endPass(); continue }
            break
        }
        if acc.stopReason == "refusal" && acc.text.isEmpty {
            return AIStreamState(text: refusalText, blocks: [], sources: acc.sources, searching: false, stopReason: "refusal")
        }
        return AIStreamState(text: acc.text, blocks: AnthropicAccumulator.replayable(acc.allBlocks), sources: acc.sources, searching: false, stopReason: acc.stopReason)
    }

    // MARK: OpenAI

    static func openAIInput(from history: [AIChatMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for m in history where !m.isError {
            switch m.role {
            case .user:
                var content: [[String: Any]] = []
                for file in m.imageFiles {
                    if let data = AIImages.base64(file) { content.append(["type": "input_image", "image_url": "data:image/png;base64,\(data)"]) }
                }
                if !m.text.isEmpty { content.append(["type": "input_text", "text": m.text]) }
                if !content.isEmpty { out.append(["role": "user", "content": content]) }
            case .assistant:
                if !m.text.isEmpty { out.append(["role": "assistant", "content": [["type": "output_text", "text": m.text]]]) }
            }
        }
        return out
    }

    private static func streamOpenAI(_ r: Request, onUpdate: @escaping @Sendable (AIStreamState) -> Void) async throws -> AIStreamState {
        var body: [String: Any] = ["model": r.model, "input": openAIInput(from: r.history), "stream": true,
                                   "instructions": r.system ?? AIPrompts.system]
        if r.webSearch { body["tools"] = [["type": "web_search"]] }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!, timeoutInterval: 300)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(r.apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        try await checkStatus(response, bytes: bytes, provider: .openai)
        var acc = OpenAIAccumulator()
        var lastFlush = Date.distantPast
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let event = JSONValue.parse(payload) else { continue }
            acc.process(event)
            if let message = acc.errorMessage { throw AIError(message: friendly(message: message, status: 0)) }
            if Date().timeIntervalSince(lastFlush) > 0.04 {
                lastFlush = Date()
                onUpdate(AIStreamState(text: acc.text, blocks: [], sources: acc.sources, searching: acc.searching, stopReason: ""))
            }
        }
        return AIStreamState(text: acc.text, blocks: [], sources: acc.sources, searching: false, stopReason: acc.done ? "end_turn" : "")
    }

    // MARK: Errors

    private static func checkStatus(_ response: URLResponse, bytes: URLSession.AsyncBytes, provider: AIProvider) async throws {
        guard let http = response as? HTTPURLResponse else { throw AIError(message: String(localized: "No answer from the server.")) }
        guard http.statusCode != 200 else { return }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > 8192 { break }
        }
        let message = JSONValue.parse(String(decoding: data, as: UTF8.self)).flatMap { $0["error"]?["message"]?.string ?? $0["message"]?.string } ?? ""
        throw AIError(message: friendly(message: message, status: http.statusCode, provider: provider), opensSettings: http.statusCode == 401)
    }

    static func friendly(message: String, status: Int, provider: AIProvider = .anthropic) -> String {
        let lower = message.lowercased()
        if status == 400, lower.contains("credit balance") {
            return provider == .anthropic ? String(localized: "Your credit balance is too low. Add credit in the Claude Console.") : String(localized: "Your OpenAI credit is used up. Add credit in your OpenAI account.")
        }
        switch status {
        case 401: return String(localized: "That API key was rejected. Check it in Settings › Ask AI.")
        case 403: return String(localized: "This key doesn't have access to that model.")
        case 429: return String(localized: "\(provider.title) is busy. Try again in a moment.")
        case 529, 500...599: return String(localized: "\(provider.title) is overloaded right now. Try again shortly.")
        case 400: return message.isEmpty ? String(localized: "The request was refused (400).") : String(localized: "The request was refused: \(message)")
        default:
            if lower.contains("overloaded") { return String(localized: "\(provider.title) is overloaded right now. Try again shortly.") }
            return message.isEmpty ? String(localized: "Something went wrong (\(status)).") : message
        }
    }

    /// A transcript like the real stream, to check the accumulator without the network (`scout://ai.selftest`).
    static func selfTest() -> String {
        var acc = AnthropicAccumulator()
        let events = [
            #"{"type":"message_start","message":{"id":"m1"}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me think."}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"SIG=="}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"s1","name":"web_search","input":{}}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query\":"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"swift\"}"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"web_search_tool_result","tool_use_id":"s1","content":[{"type":"web_search_result","url":"https://swift.org","title":"Swift.org"}]}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"content_block_start","index":3,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"Hello "}}"#,
            #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"world"}}"#,
            #"{"type":"content_block_stop","index":3}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            #"{"type":"message_stop"}"#,
        ]
        for e in events { if let v = JSONValue.parse(e) { acc.process(v) } }
        let blocks = acc.allBlocks
        var report = "text=\(acc.text) | blocks=\(blocks.count) | stop=\(acc.stopReason) | sources=\(acc.sources.map(\.url))\n"
        report += "thinking sig kept: \(blocks.first?["signature"]?.string ?? "MISSING")\n"
        report += "tool input: \(blocks[1]["input"]?["query"]?.string ?? "MISSING")\n"
        for model in [AIModels.opus, AIModels.sonnet, AIModels.haiku] {
            let body = anthropicBody(Request(provider: .anthropic, model: model, history: [], webSearch: true, effort: "medium", apiKey: "x"), messages: [])
            let tools = (body["tools"] as? [[String: Any]])?.first?["type"] as? String ?? "none"
            report += "\(model): keys \(body.keys.sorted()) | fallbacks=\(body["fallbacks"] as? String ?? "none") | tool=\(tools) | thinking=\(body["thinking"] == nil ? "omitted" : "PRESENT") | sampling params=\(body["temperature"] == nil && body["top_p"] == nil && body["top_k"] == nil ? "none" : "PRESENT")\n"
        }
        func msg(_ t: String, images: [String] = [], model: String? = nil, role: AIChatMessage.Role = .user) -> AIChatMessage {
            var m = AIChatMessage(role: role, text: t, imageFiles: images)
            m.model = model
            return m
        }
        let routing: [(String, [AIChatMessage], String)] = [
            ("what's the capital of peru", [msg("what's the capital of peru")], AIModels.haiku),
            ("who wrote dune", [msg("who wrote dune")], AIModels.haiku),
            ("explain closures", [msg("explain closures")], AIModels.sonnet),
            ("please fix this", [msg("please fix this")], AIModels.sonnet),
            ("summarise: …", [msg("Summarize the news")], AIModels.sonnet),
            ("translate", [msg("translate hello to greek")], AIModels.sonnet),
            ("image", [msg("what is this?", images: ["a.png"])], AIModels.sonnet),
            ("code fence", [msg("```swift\nlet x = 1\n```")], AIModels.sonnet),
            ("3 lines", [msg("a\nb\nc")], AIModels.sonnet),
            ("long", [msg(String(repeating: "word ", count: 70))], AIModels.sonnet),
            ("sticky", [msg("hi", model: nil), msg("hello", model: AIModels.sonnet, role: .assistant), msg("thanks")], AIModels.sonnet),
            ("haiku stays", [msg("hi"), msg("hello", model: AIModels.haiku, role: .assistant), msg("thanks")], AIModels.haiku),
        ]
        for (name, history, want) in routing {
            let r = AIRouter.route(chatModel: AIModels.autoID, history: history)
            report += "route \(name): \(r.model) \(r.effort) \(r.model == want ? "ok" : "WRONG (want \(want))")\n"
        }
        report += "manual sonnet effort: \(AIRouter.route(chatModel: AIModels.sonnet, history: [msg("hi")]).effort)\n"
        return report
    }
}
