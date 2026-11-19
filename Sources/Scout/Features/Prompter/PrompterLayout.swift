import AppKit
import SwiftUI

/// TextKit layout of the script: one stack used both to draw the text and to know where each line is.
final class PrompterLayout {
    let storage = NSTextStorage()
    let manager = NSLayoutManager()
    let container = NSTextContainer()
    private(set) var fontSize: CGFloat = 28
    private(set) var wordRanges: [NSRange] = []

    init() {
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        container.lineFragmentPadding = 0
    }

    static let dim = NSColor(white: 1, alpha: 0.30)
    static let bright = NSColor.white

    func configure(text: String, fontSize: CGFloat, width: CGFloat) {
        self.fontSize = fontSize
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineSpacing = fontSize * 0.28
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: Self.bright,
            .paragraphStyle: style,
        ]
        storage.setAttributedString(NSAttributedString(string: text.isEmpty ? " " : text, attributes: attributes))
        manager.ensureLayout(for: container)
        wordRanges = ScriptText.words(in: text).map(\.range)
    }

    var contentHeight: CGFloat {
        manager.ensureLayout(for: container)
        return manager.usedRect(for: container).height
    }

    /// Vertical middle of the line that holds this character.
    func lineMid(forCharacter index: Int) -> CGFloat {
        guard storage.length > 0 else { return 0 }
        let i = min(max(0, index), storage.length - 1)
        let glyph = manager.glyphIndexForCharacter(at: i)
        let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return rect.midY
    }

    var firstLineMid: CGFloat { lineMid(forCharacter: 0) }
    var lastLineMid: CGFloat { lineMid(forCharacter: storage.length - 1) }

    /// Words before `cursor` are dimmed (already read); the word at `cursor` is the accent color.
    func highlight(cursor: Int, accent: NSColor) {
        guard storage.length > 0 else { return }
        storage.beginEditing()
        let full = NSRange(location: 0, length: storage.length)
        storage.addAttribute(.foregroundColor, value: Self.bright, range: full)
        if cursor > 0, cursor <= wordRanges.count {
            let end = wordRanges[cursor - 1]
            storage.addAttribute(.foregroundColor, value: Self.dim, range: NSRange(location: 0, length: end.location + end.length))
        } else if cursor > wordRanges.count, let last = wordRanges.last {
            storage.addAttribute(.foregroundColor, value: Self.dim, range: NSRange(location: 0, length: last.location + last.length))
        }
        if cursor >= 0, cursor < wordRanges.count { storage.addAttribute(.foregroundColor, value: accent, range: wordRanges[cursor]) }
        storage.endEditing()
    }

    func clearHighlight() {
        guard storage.length > 0 else { return }
        storage.addAttribute(.foregroundColor, value: Self.bright, range: NSRange(location: 0, length: storage.length))
    }
}

/// Draws the script at a scroll offset: the text at content-y == offset sits on the reading line.
final class PrompterCanvasView: NSView {
    var layout: PrompterLayout?
    var offset: CGFloat = 0 { didSet { if offset != oldValue { needsDisplay = true } } }
    var readingLineY: CGFloat = 62 { didSet { needsDisplay = true } }
    var mirror = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true   // macOS 14+ no longer clips to the view's bounds by default
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if mirror {
            ctx.translateBy(x: bounds.width, y: 0)
            ctx.scaleBy(x: -1, y: 1)
        }
        let originX = (bounds.width - layout.container.size.width) / 2
        let origin = NSPoint(x: originX, y: readingLineY - offset)
        let visible = NSRect(x: 0, y: offset - readingLineY - 8, width: layout.container.size.width, height: bounds.height + 16)
        let glyphs = layout.manager.glyphRange(forBoundingRect: visible, in: layout.container)
        layout.manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }
}

struct PrompterCanvas: NSViewRepresentable {
    let controller: PrompterController

    func makeNSView(context: Context) -> PrompterCanvasView {
        let v = PrompterCanvasView()
        v.layout = controller.layout
        v.offset = controller.offset
        v.mirror = controller.mirror
        controller.canvas = v
        return v
    }

    func updateNSView(_ view: PrompterCanvasView, context: Context) {
        view.layout = controller.layout
        view.mirror = controller.mirror
        controller.canvas = view
    }
}
