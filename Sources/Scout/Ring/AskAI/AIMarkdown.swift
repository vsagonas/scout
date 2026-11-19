import AppKit
import SwiftUI

// B2 Ask AI — a small Markdown renderer: inline styles (bold, italic, code, links), code blocks, headings,
// lists, quotes, rules. Our own; no dependencies.

enum MDBlock: Identifiable, Equatable {
    case paragraph(String)
    case heading(Int, String)
    case bullet(String, indent: Int)
    case numbered(String, number: String, indent: Int)
    case quote(String)
    case code(language: String, text: String)
    case rule

    var id: String {
        switch self {
        case .paragraph(let s): "p\(s.hashValue)"
        case .heading(let l, let s): "h\(l)\(s.hashValue)"
        case .bullet(let s, let i): "b\(i)\(s.hashValue)"
        case .numbered(let s, let n, let i): "n\(n)\(i)\(s.hashValue)"
        case .quote(let s): "q\(s.hashValue)"
        case .code(let l, let t): "c\(l)\(t.hashValue)"
        case .rule: "r"
        }
    }
}

enum MDParser {
    static func parse(_ text: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var inCode = false
        var codeLang = ""
        var codeLines: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(language: codeLang, text: codeLines.joined(separator: "\n")))
                    inCode = false
                    codeLines = []
                } else {
                    flushParagraph(); flushQuote()
                    inCode = true
                    codeLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if inCode { codeLines.append(line); continue }
            if trimmed.isEmpty { flushParagraph(); flushQuote(); continue }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            flushQuote()
            if trimmed.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
                flushParagraph(); blocks.append(.rule); continue
            }
            if let m = trimmed.range(of: #"^#{1,4}\s+"#, options: .regularExpression) {
                flushParagraph()
                let level = trimmed[m].filter { $0 == "#" }.count
                blocks.append(.heading(level, String(trimmed[m.upperBound...])))
                continue
            }
            let indent = (line.prefix { $0 == " " }.count) / 2
            if let m = trimmed.range(of: #"^[-*•]\s+"#, options: .regularExpression) {
                flushParagraph()
                blocks.append(.bullet(String(trimmed[m.upperBound...]), indent: min(indent, 3)))
                continue
            }
            if let m = trimmed.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
                flushParagraph()
                let number = trimmed[..<m.upperBound].trimmingCharacters(in: .whitespaces)
                blocks.append(.numbered(String(trimmed[m.upperBound...]), number: number, indent: min(indent, 3)))
                continue
            }
            paragraph.append(trimmed)
        }
        if inCode { blocks.append(.code(language: codeLang, text: codeLines.joined(separator: "\n"))) }
        flushParagraph(); flushQuote()
        return blocks
    }
}

struct AIMarkdownView: View {
    let text: String
    var font: CGFloat = 13.5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MDParser.parse(text)) { block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: MDBlock) -> some View {
        switch block {
        case .paragraph(let s):
            Text(Self.inline(s, size: font)).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let s):
            Text(Self.inline(s, size: font + CGFloat(max(0, 4 - level)) * 1.5 + 1, weight: .semibold))
                .padding(.top, 4).fixedSize(horizontal: false, vertical: true)
        case .bullet(let s, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(verbatim: indent == 0 ? "•" : "◦").foregroundStyle(.secondary).font(.system(size: font))
                Text(Self.inline(s, size: font)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .numbered(let s, let number, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(number).foregroundStyle(.secondary).font(.system(size: font)).monospacedDigit()
                Text(Self.inline(s, size: font)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .quote(let s):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.accent.opacity(0.7)).frame(width: 3)
                Text(Self.inline(s, size: font)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .code(let lang, let code):
            AICodeBlock(language: lang, code: code)
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    /// Inline Markdown → styled text (bold, italic, `code`, links).
    static func inline(_ s: String, size: CGFloat, weight: Font.Weight = .regular) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        guard var out = try? AttributedString(markdown: s, options: options) else { return AttributedString(s) }
        out.font = .system(size: size, weight: weight)
        for run in out.runs {
            guard let intent = run.inlinePresentationIntent else {
                if run.link != nil { out[run.range].foregroundColor = Theme.accent; out[run.range].underlineStyle = .single }
                continue
            }
            if intent.contains(.code) {
                out[run.range].font = .system(size: size - 1, weight: .regular, design: .monospaced)
                out[run.range].backgroundColor = Color.primary.opacity(0.1)
            }
            if intent.contains(.stronglyEmphasized) { out[run.range].font = .system(size: size, weight: .semibold) }
            if intent.contains(.emphasized) { out[run.range].font = .system(size: size, weight: weight).italic() }
            if run.link != nil { out[run.range].foregroundColor = Theme.accent; out[run.range].underlineStyle = .single }
        }
        return out
    }
}

struct AICodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                (language.isEmpty ? Text("code") : Text(verbatim: language)).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    if !ScoutRuntime.isScripted { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string) }
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10.5))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(size: 12, design: .monospaced)).padding(.horizontal, 10).padding(.bottom, 9).fixedSize(horizontal: true, vertical: true)
            }
        }
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}
