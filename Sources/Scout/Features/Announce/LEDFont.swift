import SwiftUI

// The announcement board's own dot font: 5 columns by 7 rows, drawn here, no font files.
// A glyph is written as seven rows of five characters ("#" lit, "." dark). Lowercase letters use the capitals.
// The cute glyphs keep their own colour (a pink heart, a green check…) even when the message has another tint.

/// Which colour a cute glyph keeps. `none` = the message's own tint.
enum LEDAccent: UInt8, Equatable, CaseIterable {
    case none, heart, star, check, note, smile, creature

    var color: Color? {
        switch self {
        case .none: nil
        case .heart: Color(red: 1.0, green: 0.30, blue: 0.48)
        case .star: Color(red: 1.0, green: 0.82, blue: 0.25)
        case .check: Color(red: 0.36, green: 0.92, blue: 0.52)
        case .note: Color(red: 0.45, green: 0.85, blue: 1.0)
        case .smile: Color(red: 1.0, green: 0.82, blue: 0.25)
        case .creature: Color(red: 0.98, green: 0.62, blue: 0.40)
        }
    }
}

/// One column of the board: bit 0 is the top row, bit 6 the bottom one.
struct LEDColumn: Equatable {
    var bits: UInt8 = 0
    var accent: LEDAccent = .none

    static let blank = LEDColumn()

    func isLit(row: Int) -> Bool { row >= 0 && row < LEDFont.rows && bits & (1 << UInt8(row)) != 0 }
}

/// The glyph of one character: seven rows, five columns.
struct LEDGlyph: Equatable {
    /// `rows[r][c]` is true when the dot at row r, column c is lit.
    var rows: [[Bool]]
    var accent: LEDAccent = .none

    static let blank = LEDGlyph(rows: Array(repeating: Array(repeating: false, count: LEDFont.cols), count: LEDFont.rows))

    var isBlank: Bool { !rows.contains { $0.contains(true) } }

    /// The five columns, top row = bit 0.
    var columns: [LEDColumn] {
        (0..<LEDFont.cols).map { c in
            var bits: UInt8 = 0
            for r in 0..<LEDFont.rows where rows[r][c] { bits |= 1 << UInt8(r) }
            return LEDColumn(bits: bits, accent: bits == 0 ? .none : accent)
        }
    }
}

enum LEDFont {
    static let rows = 7
    static let cols = 5
    /// One dark column between two characters.
    static let gap = 1
    /// A character plus the dark column after it.
    static let advance = cols + gap

    /// The cute glyphs, as the characters a message can carry.
    static let heart: Character = "♥"
    static let star: Character = "★"
    static let smile: Character = "☺"
    static let arrow: Character = "→"
    static let check: Character = "✓"
    static let note: Character = "♪"
    static let creature: Character = "◕"

    /// Other characters that draw the same glyph (Greek capitals that look like a Latin letter draw that letter).
    private static let aliases: [Character: Character] = [
        "❤": heart, "♡": heart, "☆": star, "⭐": star, "🙂": smile, "😊": smile, "➜": arrow, "➡": arrow, "✔": check, "✅": check,
        "♫": note, "🎵": note, "‘": "'", "’": "'", "“": "\"", "”": "\"", "–": "-", "—": "-", "…": ".",
        "Α": "A", "Β": "B", "Ε": "E", "Ζ": "Z", "Η": "H", "Ι": "I", "Κ": "K", "Μ": "M", "Ν": "N", "Ο": "O", "Ρ": "P", "Τ": "T", "Υ": "Y", "Χ": "X",
    ]

    /// Every character with a glyph of its own (the letters are capitals; lowercase maps to them).
    static var supported: [Character] { source.compactMap { $0.first } + [" "] }

    /// The character whose glyph `ch` draws: itself, an alias, its capital, or itself again when the font has nothing for it.
    static func canonical(_ ch: Character) -> Character {
        if glyphs[ch] != nil { return ch }
        if let alias = aliases[ch] { return alias }
        if ch.unicodeScalars.count > 1, let first = ch.unicodeScalars.first {   // "❤️" is the heart plus a variation selector, "é" an e plus an accent
            let base = Character(first)
            if base != ch { return canonical(base) }
        }
        let folded = String(ch).folding(options: .diacriticInsensitive, locale: nil).uppercased()
        if folded.count == 1, let c = folded.first {
            if glyphs[c] != nil { return c }
            if let alias = aliases[c] { return alias }
        }
        return ch
    }

    /// The glyph for a character; an unknown character is a blank glyph (never a crash, never a box).
    static func glyph(_ ch: Character) -> LEDGlyph {
        glyphs[canonical(ch)] ?? .blank
    }

    static func hasGlyph(_ ch: Character) -> Bool { ch == " " || glyphs[canonical(ch)] != nil }

    /// True when the font draws `ch` as it is written: its own glyph, an alias, or its capital, but NOT by dropping an accent
    /// (ä drawn as A misspells a word: German LÄUFT, Finnish SÄÄ, Swedish VÄDER). Translated titles use this to choose the system font instead.
    static func drawsAsWritten(_ ch: Character) -> Bool {
        if ch == " " || glyphs[ch] != nil || aliases[ch] != nil { return true }
        let up = String(ch).uppercased()
        guard up.count == 1, let c = up.first else { return false }
        return glyphs[c] != nil || aliases[c] != nil
    }

    /// Text as columns: each character's five columns with one dark column between characters (none after the last).
    static func columns(_ text: String) -> [LEDColumn] {
        var out: [LEDColumn] = []
        for (i, ch) in text.enumerated() {
            if i > 0 { out.append(contentsOf: Array(repeating: .blank, count: gap)) }
            out.append(contentsOf: glyph(ch).columns)
        }
        return out
    }

    /// How many columns a text takes.
    static func width(_ text: String) -> Int {
        let n = text.count
        return n == 0 ? 0 : n * cols + (n - 1) * gap
    }

    // MARK: The table

    /// `<character>=<row>/<row>/…` (seven rows). The space is not listed: it is the blank glyph.
    private static let source: [String] = [
        "A=.###./#...#/#...#/#####/#...#/#...#/#...#",
        "B=####./#...#/#...#/####./#...#/#...#/####.",
        "C=.###./#...#/#..../#..../#..../#...#/.###.",
        "D=####./#...#/#...#/#...#/#...#/#...#/####.",
        "E=#####/#..../#..../####./#..../#..../#####",
        "F=#####/#..../#..../####./#..../#..../#....",
        "G=.###./#...#/#..../#.###/#...#/#...#/.###.",
        "H=#...#/#...#/#...#/#####/#...#/#...#/#...#",
        "I=.###./..#../..#../..#../..#../..#../.###.",
        "J=..###/...#./...#./...#./...#./#..#./.##..",
        "K=#...#/#..#./#.#../##.../#.#../#..#./#...#",
        "L=#..../#..../#..../#..../#..../#..../#####",
        "M=#...#/##.##/#.#.#/#.#.#/#...#/#...#/#...#",
        "N=#...#/#...#/##..#/#.#.#/#..##/#...#/#...#",
        "O=.###./#...#/#...#/#...#/#...#/#...#/.###.",
        "P=####./#...#/#...#/####./#..../#..../#....",
        "Q=.###./#...#/#...#/#...#/#.#.#/#..#./.##.#",
        "R=####./#...#/#...#/####./#.#../#..#./#...#",
        "S=.####/#..../#..../.###./....#/....#/####.",
        "T=#####/..#../..#../..#../..#../..#../..#..",
        "U=#...#/#...#/#...#/#...#/#...#/#...#/.###.",
        "V=#...#/#...#/#...#/#...#/#...#/.#.#./..#..",
        "W=#...#/#...#/#...#/#.#.#/#.#.#/##.##/#...#",
        "X=#...#/#...#/.#.#./..#../.#.#./#...#/#...#",
        "Y=#...#/#...#/.#.#./..#../..#../..#../..#..",
        "Z=#####/....#/...#./..#../.#.../#..../#####",
        "0=.###./#...#/#..##/#.#.#/##..#/#...#/.###.",
        "1=..#../.##../..#../..#../..#../..#../.###.",
        "2=.###./#...#/....#/...#./..#../.#.../#####",
        "3=#####/...#./..#../...#./....#/#...#/.###.",
        "4=...#./..##./.#.#./#..#./#####/...#./...#.",
        "5=#####/#..../####./....#/....#/#...#/.###.",
        "6=..##./.#.../#..../####./#...#/#...#/.###.",
        "7=#####/....#/...#./..#../.#.../.#.../.#...",
        "8=.###./#...#/#...#/.###./#...#/#...#/.###.",
        "9=.###./#...#/#...#/.####/....#/...#./.##..",
        ".=...../...../...../...../...../.##../.##..",
        ",=...../...../...../...../.##../..#../.#...",
        ":=...../.##../.##../...../.##../.##../.....",
        ";=...../.##../.##../...../.##../..#../.#...",
        "!=..#../..#../..#../..#../..#../...../..#..",
        "?=.###./#...#/....#/...#./..#../...../..#..",
        "-=...../...../...../#####/...../...../.....",
        "+=...../..#../..#../#####/..#../..#../.....",
        "/=....#/....#/...#./..#../.#.../#..../#....",
        "'=..#../..#../.#.../...../...../...../.....",
        "\"=.#.#./.#.#./...../...../...../...../.....",
        "(=...#./..#../.#.../.#.../.#.../..#../...#.",
        ")=.#.../..#../...#./...#./...#./..#../.#...",
        "%=##..#/##..#/...#./..#../.#.../#..##/#..##",
        "&=.##../#..#./#.#../.#.../#.#.#/#..#./.##.#",
        "#=.#.#./.#.#./#####/.#.#./#####/.#.#./.#.#.",
        "@=.###./#...#/#.###/#.#.#/#.###/#..../.####",
        "*=...../#.#.#/.###./#####/.###./#.#.#/.....",
        // The cute ones.
        "♥=...../.#.#./#####/#####/.###./..#../.....",
        "★=..#../..#../#####/.###./.###./#...#/.....",
        "☺=...../.#.#./.#.#./...../#...#/.###./.....",
        "→=...../..#../...#./#####/...#./..#../.....",
        "✓=...../....#/...#./#.#../.#.../...../.....",
        "♪=..###/..#../..#../..#../###../###../.....",
        "◕=#...#/.###./#.#.#/#####/##.##/.###./.....",
    ]

    private static let accents: [Character: LEDAccent] = [heart: .heart, star: .star, smile: .smile, check: .check, note: .note, creature: .creature]

    private static let glyphs: [Character: LEDGlyph] = {
        var table: [Character: LEDGlyph] = [:]
        for line in source {
            guard let key = line.first, line.count > 2 else { continue }
            let body = line.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false)
            let rows = body.map { $0.map { $0 == "#" } }
            guard rows.count == LEDFont.rows, rows.allSatisfy({ $0.count == LEDFont.cols }) else { continue }   // a malformed line is caught by the self-test
            table[key] = LEDGlyph(rows: rows, accent: accents[key] ?? .none)
        }
        return table
    }()

    /// Lines in the table that did not parse to seven rows of five (the self-test wants none).
    static var malformedCount: Int { source.count - (glyphs.count) }
}
