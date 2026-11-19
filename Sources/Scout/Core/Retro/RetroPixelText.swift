import SwiftUI

// Pixel capitals: the announcement board's own 5x7 dot font (`LEDFont`) drawn as crisp square pixels, no glow, no motion.
// Lowercase draws the capital; a character the font does not know is a blank cell (it keeps its place).

/// The layout of pixel text, as plain numbers (the drawing and the self-test read the same table).
enum RetroPixelLayout {
    /// Columns of a text, each a bit row (bit 0 is the top row); `LEDFont`'s columns with one dark column between characters.
    static func columns(_ text: String) -> [UInt8] { LEDFont.columns(text).map(\.bits) }

    /// The width of a text in points.
    static func width(_ text: String, pixel: CGFloat) -> CGFloat { CGFloat(LEDFont.width(text)) * pixel }

    /// The height of pixel text: seven pixels.
    static func height(pixel: CGFloat) -> CGFloat { CGFloat(LEDFont.rows) * pixel }

    /// The lit pixels as (column, row).
    static func litPixels(_ columns: [UInt8]) -> [(col: Int, row: Int)] {
        var out: [(col: Int, row: Int)] = []
        for (c, bits) in columns.enumerated() {
            for r in 0..<LEDFont.rows where bits & (1 << UInt8(r)) != 0 { out.append((c, r)) }
        }
        return out
    }

    /// The pixels of a one-pixel outline around the lit ones, on a grid that is one pixel larger on every side
    /// (so a pixel (c, r) of the text is (c + 1, r + 1) here). Lit pixels themselves are not in the outline.
    static func outlinePixels(_ columns: [UInt8]) -> [(col: Int, row: Int)] {
        let w = columns.count + 2
        let h = LEDFont.rows + 2
        var lit = Set<Int>()
        for p in litPixels(columns) { lit.insert((p.row + 1) * w + p.col + 1) }
        var ring = Set<Int>()
        for index in lit {
            let c = index % w, r = index / w
            for dr in -1...1 {
                for dc in -1...1 where dr != 0 || dc != 0 {
                    let nc = c + dc, nr = r + dr
                    if nc >= 0, nc < w, nr >= 0, nr < h, !lit.contains(nr * w + nc) { ring.insert(nr * w + nc) }
                }
            }
        }
        return ring.map { (col: $0 % w, row: $0 / w) }.sorted { ($0.row, $0.col) < ($1.row, $1.col) }
    }
}

/// Pixel capitals in one colour. `pixel` is the size of one dot in points (1 to 3 look right; the text is 7 pixels tall).
struct RetroPixelText: View {
    let text: String
    let pixel: CGFloat
    let color: Color

    init(_ text: String, pixel: CGFloat = 1.5, color: Color = Look.osd) {
        self.text = text
        self.pixel = pixel
        self.color = color
    }

    var body: some View {
        if Retro.is8bit { pixels } else {
            // The minimal look: the same words in the system font, about the size the pixel capitals were.
            Text(text).font(.system(size: max(9, RetroPixelLayout.height(pixel: pixel) * 1.35), weight: .semibold)).foregroundStyle(color)
                .lineLimit(1).fixedSize()
        }
    }

    private var pixels: some View {
        let cols = RetroPixelLayout.columns(text)
        return Canvas { ctx, _ in
            let p = pixel
            var path = Path()
            for (c, r) in RetroPixelLayout.litPixels(cols) {
                let x = ctx.snapped(CGFloat(c) * p), y = ctx.snapped(CGFloat(r) * p)
                path.addRect(CGRect(x: x, y: y, width: ctx.snapped(CGFloat(c + 1) * p) - x, height: ctx.snapped(CGFloat(r + 1) * p) - y))
            }
            ctx.fill(path, with: .color(color))
        }
        .frame(width: RetroPixelLayout.width(text, pixel: pixel), height: RetroPixelLayout.height(pixel: pixel))
        .accessibilityLabel(text)
    }
}

/// A VCR's on-screen display: pixel text with a dark one-pixel outline, so it reads over any picture. Sized like pixel text plus the
/// outline (a pixel more on every side).
struct RetroOSD: View {
    let text: String
    let pixel: CGFloat
    let color: Color

    init(_ text: String, pixel: CGFloat = 1.5, color: Color = Retro.Ink.phosphorGreen) {
        self.text = text
        self.pixel = pixel
        self.color = color
    }

    var body: some View {
        if Retro.is8bit { pixels } else {
            Text(text).font(.system(size: max(9, RetroPixelLayout.height(pixel: pixel) * 1.35), weight: .bold, design: .monospaced)).foregroundStyle(color)
                .shadow(color: .black.opacity(0.85), radius: 1.2).lineLimit(1).fixedSize()
        }
    }

    private var pixels: some View {
        let cols = RetroPixelLayout.columns(text)
        return Canvas { ctx, _ in
            let p = pixel
            func rects(_ pixels: [(col: Int, row: Int)], shift: Int) -> Path {
                var path = Path()
                for (c, r) in pixels {
                    let cc = c + shift, rr = r + shift
                    let x = ctx.snapped(CGFloat(cc) * p), y = ctx.snapped(CGFloat(rr) * p)
                    path.addRect(CGRect(x: x, y: y, width: ctx.snapped(CGFloat(cc + 1) * p) - x, height: ctx.snapped(CGFloat(rr + 1) * p) - y))
                }
                return path
            }
            if !cols.isEmpty {
                ctx.fill(rects(RetroPixelLayout.outlinePixels(cols), shift: 0), with: .color(Color.black.opacity(0.92)))
                ctx.fill(rects(RetroPixelLayout.litPixels(cols), shift: 1), with: .color(color))
            }
        }
        .frame(width: text.isEmpty ? 0 : RetroPixelLayout.width(text, pixel: pixel) + 2 * pixel, height: RetroPixelLayout.height(pixel: pixel) + 2 * pixel)
        .accessibilityLabel(text)
    }
}
