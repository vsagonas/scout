import SwiftUI

// LCD seven-segment digits for clocks and counters, and the LED level bar.

/// The seven-segment table and layout, as plain numbers (the drawing and the self-test read the same table).
enum SevenSegment {
    /// The seven segments: a top, b top-right, c bottom-right, d bottom, e bottom-left, f top-left, g middle.
    struct Segments: OptionSet, Hashable {
        let rawValue: UInt8
        static let a = Segments(rawValue: 1 << 0)
        static let b = Segments(rawValue: 1 << 1)
        static let c = Segments(rawValue: 1 << 2)
        static let d = Segments(rawValue: 1 << 3)
        static let e = Segments(rawValue: 1 << 4)
        static let f = Segments(rawValue: 1 << 5)
        static let g = Segments(rawValue: 1 << 6)
        static let all: Segments = [.a, .b, .c, .d, .e, .f, .g]
    }

    /// What a character draws: a digit cell (lit segments), the colon, the dot.
    enum Cell: Equatable {
        case digit(Segments)
        case colon
        case dot
    }

    /// 0-9, `-`, A and P (and a, p) light segments; `:` and `.` are the colon and the dot; the space and anything else is a blank cell.
    static func cell(for ch: Character) -> Cell {
        switch ch {
        case "0": .digit([.a, .b, .c, .d, .e, .f])
        case "1": .digit([.b, .c])
        case "2": .digit([.a, .b, .d, .e, .g])
        case "3": .digit([.a, .b, .c, .d, .g])
        case "4": .digit([.b, .c, .f, .g])
        case "5": .digit([.a, .c, .d, .f, .g])
        case "6": .digit([.a, .c, .d, .e, .f, .g])
        case "7": .digit([.a, .b, .c])
        case "8": .digit(.all)
        case "9": .digit([.a, .b, .c, .d, .f, .g])
        case "-": .digit([.g])
        case "A", "a": .digit([.a, .b, .c, .e, .f, .g])
        case "P", "p": .digit([.a, .b, .e, .f, .g])
        case ":": .colon
        case ".": .dot
        default: .digit([])
        }
    }

    /// The characters that light something.
    static let supported: [Character] = Array("0123456789-AP:.")

    /// The slant of the digits (the top leans right, like an LCD clock), as a fraction of the height.
    static let slant: CGFloat = 0.10

    static func cellWidth(_ cell: Cell, height: CGFloat) -> CGFloat {
        switch cell {
        case .digit: height * 0.56
        case .colon: height * 0.22
        case .dot: height * 0.18
        }
    }

    static func spacing(height: CGFloat) -> CGFloat { height * 0.15 }

    /// The width a text takes at a digit height (with the room the slant needs).
    static func width(_ text: String, height: CGFloat) -> CGFloat {
        let cells = text.map { cell(for: $0) }
        guard !cells.isEmpty else { return 0 }
        let sum = cells.reduce(0) { $0 + cellWidth($1, height: height) }
        return sum + spacing(height: height) * CGFloat(cells.count - 1) + height * slant
    }

    /// The segment's outline for a digit cell of width `w` and height `h`: a hexagon with pointed ends.
    static func polygon(_ segment: Segments, width w: CGFloat, height h: CGFloat) -> [CGPoint] {
        let t = max(1.4, h * 0.125)
        let gap = t * 0.16
        func horizontal(_ cy: CGFloat) -> [CGPoint] {
            let x0 = t / 2 + gap, x1 = w - t / 2 - gap
            return [CGPoint(x: x0, y: cy), CGPoint(x: x0 + t / 2, y: cy - t / 2), CGPoint(x: x1 - t / 2, y: cy - t / 2),
                    CGPoint(x: x1, y: cy), CGPoint(x: x1 - t / 2, y: cy + t / 2), CGPoint(x: x0 + t / 2, y: cy + t / 2)]
        }
        func vertical(_ cx: CGFloat, _ y0: CGFloat, _ y1: CGFloat) -> [CGPoint] {
            [CGPoint(x: cx, y: y0), CGPoint(x: cx + t / 2, y: y0 + t / 2), CGPoint(x: cx + t / 2, y: y1 - t / 2),
             CGPoint(x: cx, y: y1), CGPoint(x: cx - t / 2, y: y1 - t / 2), CGPoint(x: cx - t / 2, y: y0 + t / 2)]
        }
        let upper = (t / 2 + gap, h / 2 - gap), lower = (h / 2 + gap, h - t / 2 - gap)
        switch segment {
        case .a: return horizontal(t / 2)
        case .g: return horizontal(h / 2)
        case .d: return horizontal(h - t / 2)
        case .f: return vertical(t / 2, upper.0, upper.1)
        case .b: return vertical(w - t / 2, upper.0, upper.1)
        case .e: return vertical(t / 2, lower.0, lower.1)
        case .c: return vertical(w - t / 2, lower.0, lower.1)
        default: return []
        }
    }

    static let order: [Segments] = [.a, .b, .c, .d, .e, .f, .g]
}

/// LCD seven-segment text: 0-9 : - . space, A and P; anything else is a blank cell. `height` is the digit height (14 to 40 look right).
/// With `ghost`, the unlit segments stay faintly visible, like the real LCD.
struct SevenSegmentText: View {
    let text: String
    let height: CGFloat
    let color: Color
    let ghost: Bool

    init(_ text: String, height: CGFloat = 28, color: Color = Retro.Ink.phosphorGreen, ghost: Bool = true) {
        self.text = text
        self.height = height
        self.color = color
        self.ghost = ghost
    }

    var body: some View {
        if Retro.is8bit { segments } else {
            // The minimal look: the digits in the system font (rounded, one width for every digit), in the same box the LCD digits take, so a
            // number that changes never moves what stands beside it.
            Text(text).font(.system(size: height * 1.15, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(width: SevenSegment.width(text, height: height) + height * 0.2, height: height, alignment: .trailing)
        }
    }

    private var segments: some View {
        Canvas { ctx, _ in
            let h = height
            let k = SevenSegment.slant
            ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: -k, d: 1, tx: k * h, ty: 0))
            let dim = color.opacity(0.11)
            let t = max(1.4, h * 0.125)
            var x: CGFloat = 0
            for ch in text {
                let cell = SevenSegment.cell(for: ch)
                let w = SevenSegment.cellWidth(cell, height: h)
                switch cell {
                case .digit(let lit):
                    for seg in SevenSegment.order {
                        let on = lit.contains(seg)
                        guard on || ghost else { continue }
                        var path = Path()
                        let pts = SevenSegment.polygon(seg, width: w, height: h).map { CGPoint(x: $0.x + x, y: $0.y) }
                        guard let first = pts.first else { continue }
                        path.move(to: first)
                        pts.dropFirst().forEach { path.addLine(to: $0) }
                        path.closeSubpath()
                        if on, h >= 20 { ctx.stroke(path, with: .color(color.opacity(0.20)), style: StrokeStyle(lineWidth: t * 0.7, lineJoin: .round)) }
                        ctx.fill(path, with: .color(on ? color : dim))
                    }
                case .colon:
                    let d = t * 1.1
                    for cy in [h * 0.32, h * 0.70] {
                        ctx.fill(Path(CGRect(x: x + (w - d) / 2, y: cy - d / 2, width: d, height: d)), with: .color(color))
                    }
                case .dot:
                    let d = t * 1.1
                    ctx.fill(Path(CGRect(x: x + (w - d) / 2, y: h - d, width: d, height: d)), with: .color(color))
                }
                x += w + SevenSegment.spacing(height: h)
            }
        }
        .frame(width: SevenSegment.width(text, height: height), height: height)
        .accessibilityLabel(text)
    }
}

// MARK: - LED bar

/// A level meter of LED segments: green, then yellow, then red. Unlit segments stay faintly visible.
struct RetroLEDBar: View {
    let value: Double
    let segments: Int
    let axis: Axis
    let size: CGSize

    init(value: Double, segments: Int = 10, axis: Axis = .horizontal, size: CGSize) {
        self.value = value
        self.segments = segments
        self.axis = axis
        self.size = size
    }

    enum Zone: Equatable { case green, yellow, red }

    /// How many segments light for a value (0 to 1, clamped): the nearest whole segment.
    static func litCount(value: Double, segments: Int) -> Int {
        guard segments > 0 else { return 0 }
        let v = min(1, max(0, value.isNaN ? 0 : value))
        return min(segments, Int((v * Double(segments)).rounded(.toNearestOrAwayFromZero)))
    }

    /// The colour zone of segment `index` (0 = first): green up to 60 %, yellow up to 85 %, red above.
    static func zone(index: Int, segments: Int) -> Zone {
        let p = Double(index + 1) / Double(max(1, segments))
        if p <= 0.60 + 1e-9 { return .green }
        if p <= 0.85 + 1e-9 { return .yellow }
        return .red
    }

    static func color(_ zone: Zone) -> Color {
        switch zone {
        case .green: Retro.Ink.ledGreen
        case .yellow: Retro.Ink.ledYellow
        case .red: Retro.Ink.ledRed
        }
    }

    var body: some View {
        if Retro.is8bit { ledBody } else {
            // The minimal look: a slim rounded bar that fills to the value in the colour of its zone.
            let v = min(1, max(0, value.isNaN ? 0 : value))
            let tint = Self.color(Self.zone(index: max(0, Self.litCount(value: value, segments: segments) - 1), segments: segments))
            let thick = min(5, axis == .horizontal ? size.height : size.width)
            ZStack(alignment: axis == .horizontal ? .leading : .bottom) {
                Capsule().fill(Look.ink(0.12))
                Capsule().fill(tint)
                    .frame(width: axis == .horizontal ? max(thick, size.width * v) : thick, height: axis == .horizontal ? thick : max(thick, size.height * v))
                    .opacity(v > 0 ? 1 : 0)
            }
            .frame(width: axis == .horizontal ? size.width : thick, height: axis == .horizontal ? thick : size.height)
            .frame(width: size.width, height: size.height)
            .accessibilityLabel("Level \(Int((v * 100).rounded())) percent")
        }
    }

    private var ledBody: some View {
        let lit = Self.litCount(value: value, segments: segments)
        return Canvas { ctx, canvasSize in
            guard segments > 0 else { return }
            let inset: CGFloat = 2
            let gap: CGFloat = 1.5
            let horizontal = axis == .horizontal
            let length = (horizontal ? canvasSize.width : canvasSize.height) - 2 * inset
            let thick = (horizontal ? canvasSize.height : canvasSize.width) - 2 * inset
            let seg = (length - gap * CGFloat(segments - 1)) / CGFloat(segments)
            guard seg > 0.5, thick > 0.5 else { return }
            for i in 0..<segments {
                let along = inset + CGFloat(i) * (seg + gap)
                let rect = horizontal
                    ? CGRect(x: along, y: inset, width: seg, height: thick)
                    : CGRect(x: inset, y: canvasSize.height - along - seg, width: thick, height: seg)   // vertical bars grow upward
                let color = Self.color(Self.zone(index: i, segments: segments))
                let on = i < lit
                ctx.fill(Path(rect), with: .color(on ? color : color.opacity(0.15)))
                if on {
                    let edge: CGFloat = min(1, thick / 4)
                    let shine = horizontal ? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: edge)
                                           : CGRect(x: rect.minX, y: rect.minY, width: edge, height: rect.height)
                    ctx.fill(Path(shine), with: .color(Color.white.opacity(0.35)))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .retroBevel(.sunken, cornerRadius: 2, depth: 1, face: Look.well(dark: Color(red: 0.045, green: 0.05, blue: 0.05)))   // the track: dark in the dark preset, the light well in the light one
        .accessibilityLabel("Level \(Int((min(1, max(0, value)) * 100).rounded())) percent")
    }
}
