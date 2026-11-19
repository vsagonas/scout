import SwiftUI

// How a message plays on the board. Everything here is a pure function of the message and the time since it began,
// so a self-test drives it with a fake clock and the board simply asks "what is lit at t seconds?".
//   Step mode: the letters light up in place, column by column, like a sign switching on. A long message pages:
//              it lights up, holds, goes dark for a breath, and the next part lights up. Nothing slides.
//   Scroll mode: a classic marquee, right to left, one column at a time.

enum LEDMode: String, Equatable {
    case step, scroll

    /// Step when Reduce Motion is on, Scroll otherwise; the Settings switch forces Scroll.
    static func resolve(reduceMotion: Bool, forceScroll: Bool) -> LEDMode {
        forceScroll ? .scroll : (reduceMotion ? .step : .scroll)
    }
}

/// What the board shows at one moment: exactly `columns.count` columns of the window.
struct LEDFrame: Equatable {
    var columns: [LEDColumn]
    /// The column that lit up this very instant (drawn white-hot), Step mode only.
    var hot: Int?
    /// True once the message has played to its end.
    var finished = false

    var litCount: Int { columns.reduce(0) { $0 + $1.bits.nonzeroBitCount } }
}

enum LEDSettings {
    /// Settings › Live Activities: "Scroll the letters like a marquee".
    static let scrollKey = "announce.scroll"
    static var forceScroll: Bool { Pref.bool(scrollKey, false) }
}

/// Everything a message needs to be drawn at any time since it began.
struct LEDSchedule: Equatable {
    /// Characters that fit the board at once (7 → 41 columns).
    static let pageCharacters = 7
    static let maxWindow = pageCharacters * LEDFont.advance - LEDFont.gap

    // Step mode timing.
    static let lightColumnsPerSecond = 46.0   // a full page lights up in a bit under a second
    static let darkSeconds = 0.18
    static let minimumHold = 0.4

    /// How long a part stays lit once it is complete: a short part (a lone heart) is read at a glance, a full one needs more.
    static func holdSeconds(characters: Int) -> Double { min(1.5, max(0.8, 0.55 + 0.14 * Double(characters))) }

    // Scroll mode timing.
    static let scrollColumnsPerSecond = 26.0

    let mode: LEDMode
    let text: String
    /// How many columns the board is wide.
    let window: Int
    /// Step mode: the parts of the text, each as columns already centred in the window. Scroll mode: one entry, the whole text.
    let pages: [[LEDColumn]]
    let pageTexts: [String]
    /// Seconds from the first lit dot to the end.
    let duration: Double
    /// The caller asked for this many seconds (nil: the natural time).
    let requested: Double?

    // Derived timing (Step).
    private let holds: [Double]
    private let pageStarts: [Double]
    private let scrollSpeed: Double

    init(text: String, mode: LEDMode, seconds: Double? = nil) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mode = mode
        self.text = clean
        self.requested = seconds
        switch mode {
        case .step:
            let parts = LEDPaging.pages(clean, capacity: Self.pageCharacters)
            let widest = parts.map { LEDFont.width($0) }.max() ?? 0
            let window = max(11, min(Self.maxWindow, widest))
            self.window = window
            pageTexts = parts
            pages = parts.map { part in
                let cols = LEDFont.columns(part)
                let left = max(0, (window - cols.count) / 2)
                return Array(repeating: .blank, count: left) + cols + Array(repeating: .blank, count: max(0, window - left - cols.count))
            }
            let lights = parts.map { Double(LEDFont.width($0)) / Self.lightColumnsPerSecond }
            var holdTimes = parts.map { Self.holdSeconds(characters: $0.count) }
            if let seconds {
                // The caller's time is the whole message: the holds take what the lighting and the dark breaths leave.
                let fixed = lights.reduce(0, +) + Self.darkSeconds * Double(max(0, parts.count - 1))
                let scale = max(0, seconds - fixed) / max(0.1, holdTimes.reduce(0, +))
                holdTimes = holdTimes.map { max(Self.minimumHold, $0 * scale) }
            }
            holds = holdTimes
            var starts: [Double] = []
            var t = 0.0
            for (light, hold) in zip(lights, holdTimes) {
                starts.append(t)
                t += light + hold + Self.darkSeconds
            }
            pageStarts = starts
            duration = max(0.1, t - Self.darkSeconds)
            scrollSpeed = Self.scrollColumnsPerSecond
        case .scroll:
            let cols = LEDFont.columns(clean)
            window = Self.maxWindow
            pageTexts = [clean]
            pages = [cols]
            let steps = Double(Self.maxWindow + cols.count)
            scrollSpeed = seconds.map { steps / max(0.5, $0) } ?? Self.scrollColumnsPerSecond
            duration = steps / scrollSpeed
            holds = []
            pageStarts = [0]
        }
    }

    /// Board width for this message (a short Step message does not take the whole wing).
    var columnsWide: Int { window }

    /// What is lit `t` seconds after the message began.
    func frame(at t: Double) -> LEDFrame {
        let blank = Array(repeating: LEDColumn.blank, count: window)
        guard t >= 0 else { return LEDFrame(columns: blank) }
        if t >= duration { return LEDFrame(columns: blank, hot: nil, finished: true) }
        switch mode {
        case .scroll:
            let offset = Int((t * scrollSpeed).rounded(.down))
            let text = pages[0]
            var cols = blank
            for i in 0..<window {
                let k = offset - window + i
                if k >= 0, k < text.count { cols[i] = text[k] }
            }
            return LEDFrame(columns: cols)
        case .step:
            guard let index = pageStarts.lastIndex(where: { $0 <= t }) else { return LEDFrame(columns: blank) }
            let local = t - pageStarts[index]
            let page = pages[index]
            let light = Double(LEDFont.width(pageTexts[index])) / Self.lightColumnsPerSecond
            if local >= light + holds[index] { return LEDFrame(columns: blank) }   // the dark breath before the next part
            // The text starts `left` columns into the window; its columns light from the left, one after the other.
            let left = max(0, (window - LEDFont.width(pageTexts[index])) / 2)
            let textLit = local >= light ? Int.max : Int((local * Self.lightColumnsPerSecond).rounded(.down)) + 1
            var cols = blank
            var hotIndex: Int?
            for i in 0..<page.count {
                let c = i - left
                if c >= 0, c < textLit {
                    cols[i] = page[i]
                    if local < light, c == textLit - 1, page[i].bits != 0 { hotIndex = i }
                }
            }
            return LEDFrame(columns: cols, hot: hotIndex)
        }
    }

    /// The moments a test looks at: the start of each part (Step), and when it is fully lit.
    func pageStart(_ index: Int) -> Double { pageStarts.indices.contains(index) ? pageStarts[index] : duration }
    func lightDuration(page index: Int) -> Double { Double(LEDFont.width(pageTexts[index])) / Self.lightColumnsPerSecond }
}

enum LEDPaging {
    /// Splits a text into parts of at most `capacity` characters: whole words together where they fit, a word with a hyphen cut after
    /// the hyphen ("SCOUT-" then "DASHBOARD"), and a piece that is still too long split into even parts (14 letters → 7 + 7, not 7 + 6 + 1).
    static func pages(_ text: String, capacity: Int) -> [String] {
        let words = text.split(whereSeparator: { $0 == " " }).map(String.init)
        guard !words.isEmpty else { return [""] }
        // Pieces; `glued` = continues the piece before it inside one word (no space between them when they share a part).
        var pieces: [(text: String, glued: Bool)] = []
        for word in words {
            var segments: [String] = []
            var segment = ""
            for ch in word {
                segment.append(ch)
                if ch == "-" { segments.append(segment); segment = "" }
            }
            if !segment.isEmpty { segments.append(segment) }
            var first = true
            for seg in segments {
                let chars = Array(seg)
                if chars.count <= capacity { pieces.append((seg, !first)); first = false; continue }
                let parts = Int((Double(chars.count) / Double(capacity)).rounded(.up))
                let size = Int((Double(chars.count) / Double(parts)).rounded(.up))
                var i = 0
                while i < chars.count {
                    pieces.append((String(chars[i..<min(chars.count, i + size)]), !first))
                    first = false
                    i += size
                }
            }
        }
        var pages: [String] = []
        var current = ""
        for piece in pieces {
            if current.isEmpty { current = piece.text; continue }
            let joined = current + (piece.glued ? "" : " ") + piece.text
            if joined.count <= capacity { current = joined } else { pages.append(current); current = piece.text }
        }
        if !current.isEmpty { pages.append(current) }
        return pages
    }
}
