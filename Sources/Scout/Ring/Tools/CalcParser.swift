import Foundation

// B2 Calculator: a small recursive-descent parser (never NSExpression on typed input).
//   + − × ÷ ^ % ( ) sqrt sin cos tan log ln abs round, pi e, implicit multiplication ("2pi", "3(4+1)").
// No dependencies on the rest of the app, so it can be tested on its own.

struct CalcParser {
    enum CalcError: Error, Equatable {
        case syntax
        case divideByZero
        case domain
        case unknownName(String)
    }

    var degrees = false

    private enum Token: Equatable {
        case number(Double)
        case name(String)
        case op(Character)   // + - * / ^ % ! ( ) ,
    }

    private var tokens: [Token] = []
    private var position = 0

    static func evaluate(_ text: String, degrees: Bool = false) throws -> Double {
        var parser = CalcParser()
        parser.degrees = degrees
        return try parser.run(text)
    }

    private mutating func run(_ text: String) throws -> Double {
        tokens = try Self.tokenize(text)
        position = 0
        guard !tokens.isEmpty else { throw CalcError.syntax }
        let (value, _) = try expression()
        guard position == tokens.count else { throw CalcError.syntax }
        guard value.isFinite else { throw CalcError.domain }
        return value
    }

    // MARK: Tokens

    private static func tokenize(_ text: String) throws -> [Token] {
        var out: [Token] = []
        let chars = Array(text.replacingOccurrences(of: "\u{00A0}", with: " "))
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" { i += 1; continue }
            if c.isNumber && c.isASCII || c == "." {
                var s = ""
                var seenDot = false
                while i < chars.count, chars[i].isASCII, chars[i].isNumber || chars[i] == "." || chars[i] == "_" {
                    if chars[i] == "." { if seenDot { throw CalcError.syntax }; seenDot = true }
                    if chars[i] != "_" { s.append(chars[i]) }
                    i += 1
                }
                // Scientific notation: 1e5, 2.5e-3 (only when digits follow, so "2e" stays 2 × e).
                if i < chars.count, chars[i] == "e" || chars[i] == "E" {
                    var j = i + 1
                    var exp = "e"
                    if j < chars.count, chars[j] == "-" || chars[j] == "+" { exp.append(chars[j]); j += 1 }
                    if j < chars.count, chars[j].isASCII, chars[j].isNumber {
                        while j < chars.count, chars[j].isASCII, chars[j].isNumber { exp.append(chars[j]); j += 1 }
                        s += exp
                        i = j
                    }
                }
                guard let v = Double(s) else { throw CalcError.syntax }
                out.append(.number(v))
                continue
            }
            if c.isLetter || c == "π" || c == "√" {
                if c == "π" { out.append(.name("pi")); i += 1; continue }
                if c == "√" { out.append(.name("sqrt")); i += 1; continue }
                var s = ""
                while i < chars.count, chars[i].isLetter { s.append(chars[i]); i += 1 }
                out.append(.name(s.lowercased()))
                continue
            }
            switch c {
            case "+", "-", "*", "/", "^", "%", "!", "(", ")", ",": out.append(.op(c))
            case "×", "·": out.append(.op("*"))
            case "÷", ":": out.append(.op("/"))
            case "−", "–": out.append(.op("-"))
            case "[": out.append(.op("("))
            case "]": out.append(.op(")"))
            default: throw CalcError.syntax
            }
            i += 1
        }
        return out
    }

    // MARK: Grammar

    private var peek: Token? { position < tokens.count ? tokens[position] : nil }

    private mutating func advance() { position += 1 }

    /// expr := term (('+' | '-') term)*     — a bare "10%" on the right of + or − means "10 % of the left".
    private mutating func expression() throws -> (Double, Bool) {
        var (value, _) = try term()
        while case .op(let o)? = peek, o == "+" || o == "-" {
            advance()
            let (rhs, isPercent) = try term()
            let amount = isPercent ? value * rhs : rhs
            value = o == "+" ? value + amount : value - amount
        }
        return (value, false)
    }

    private mutating func term() throws -> (Double, Bool) {
        var (value, percent) = try unary()
        while let t = peek {
            if case .op(let o) = t, o == "*" || o == "/" {
                advance()
                let (rhs, _) = try unary()
                if o == "/" {
                    guard rhs != 0 else { throw CalcError.divideByZero }
                    value /= rhs
                } else { value *= rhs }
                percent = false
            } else if startsPrimary(t) {
                let (rhs, _) = try unary()   // implicit multiplication
                value *= rhs
                percent = false
            } else { break }
        }
        return (value, percent)
    }

    private func startsPrimary(_ t: Token) -> Bool {
        switch t {
        case .number, .name: true
        case .op(let c): c == "("
        }
    }

    private mutating func unary() throws -> (Double, Bool) {
        if case .op(let o)? = peek, o == "-" || o == "+" {
            advance()
            let (v, p) = try unary()
            return (o == "-" ? -v : v, p)
        }
        return try power()
    }

    /// power := postfix ('^' unary)?   (right associative; "-2^2" = -4 because unary wraps power)
    private mutating func power() throws -> (Double, Bool) {
        let (base, percent) = try postfix()
        if case .op("^")? = peek {
            advance()
            let (exp, _) = try unary()
            let r = pow(base, exp)
            guard !r.isNaN else { throw CalcError.domain }
            return (r, false)
        }
        return (base, percent)
    }

    private mutating func postfix() throws -> (Double, Bool) {
        var (value, percent) = try primary()
        while case .op(let o)? = peek, o == "%" || o == "!" {
            // "%" followed by something that starts an operand is a modulo-free percent; we only support percent.
            advance()
            if o == "%" { value /= 100; percent = true } else {
                guard value >= 0, value == value.rounded(), value <= 170 else { throw CalcError.domain }
                value = value < 2 ? 1 : (2...Int(value)).reduce(1.0) { $0 * Double($1) }
                percent = false
            }
        }
        return (value, percent)
    }

    private mutating func primary() throws -> (Double, Bool) {
        guard let t = peek else { throw CalcError.syntax }
        switch t {
        case .number(let v):
            advance()
            return (v, false)
        case .op("("):
            advance()
            let (v, _) = try expression()
            guard case .op(")")? = peek else { throw CalcError.syntax }
            advance()
            return (v, false)
        case .name(let name):
            advance()
            switch name {
            case "pi": return (.pi, false)
            case "e": return (M_E, false)
            case "tau": return (2 * .pi, false)
            default:
                guard case .op("(")? = peek else {
                    // "sqrt 9", "sin 30": a function name followed directly by an operand.
                    if Self.functions.contains(name), let n = peek, startsPrimary(n) {
                        let (arg, _) = try power()
                        return (try apply(name, [arg]), false)
                    }
                    throw Self.functions.contains(name) ? CalcError.syntax : CalcError.unknownName(name)
                }
                guard Self.functions.contains(name) else { throw CalcError.unknownName(name) }
                advance()
                var args: [Double] = []
                if case .op(")")? = peek {} else {
                    args.append(try expression().0)
                    while case .op(",")? = peek {
                        advance()
                        args.append(try expression().0)
                    }
                }
                guard case .op(")")? = peek else { throw CalcError.syntax }
                advance()
                return (try apply(name, args), false)
            }
        default:
            throw CalcError.syntax
        }
    }

    static let functions: Set<String> = ["sqrt", "sin", "cos", "tan", "asin", "acos", "atan", "log", "ln", "abs", "round",
                                         "floor", "ceil", "exp", "root"]

    private func apply(_ name: String, _ args: [Double]) throws -> Double {
        guard let x = args.first else { throw CalcError.syntax }
        let toRad: (Double) -> Double = { degrees ? $0 * .pi / 180 : $0 }
        let fromRad: (Double) -> Double = { degrees ? $0 * 180 / .pi : $0 }
        let r: Double
        switch name {
        case "sqrt":
            guard x >= 0 else { throw CalcError.domain }
            r = x.squareRoot()
        case "sin": r = sin(toRad(x))
        case "cos": r = cos(toRad(x))
        case "tan": r = tan(toRad(x))
        case "asin":
            guard abs(x) <= 1 else { throw CalcError.domain }
            r = fromRad(asin(x))
        case "acos":
            guard abs(x) <= 1 else { throw CalcError.domain }
            r = fromRad(acos(x))
        case "atan": r = fromRad(atan(x))
        case "log":
            guard x > 0 else { throw CalcError.domain }
            r = log10(x)
        case "ln":
            guard x > 0 else { throw CalcError.domain }
            r = log(x)
        case "abs": r = abs(x)
        case "exp": r = exp(x)
        case "floor": r = floor(x)
        case "ceil": r = ceil(x)
        case "round":
            if args.count > 1 {
                let p = pow(10, args[1].rounded())
                r = (x * p).rounded() / p
            } else { r = x.rounded() }
        case "root":
            guard args.count == 2, args[1] != 0 else { throw CalcError.syntax }
            r = pow(x, 1 / args[1])
        default: throw CalcError.unknownName(name)
        }
        // Trig of exact multiples (sin(pi) = 1.2e-16) should read as zero.
        if abs(r) < 1e-12 { return 0 }
        return r
    }

    // MARK: Output

    /// "3.14159265359", "1,234.5" is not used: plain digits copy cleanly into other apps.
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(format: "%.0f", value) }
        let magnitude = abs(value)
        if magnitude >= 1e15 || magnitude < 1e-6 {
            let s = String(format: "%.9e", value)
            // 1.234500000e+20 -> 1.2345e+20
            let parts = s.split(separator: "e")
            var mantissa = String(parts[0])
            while mantissa.hasSuffix("0") { mantissa.removeLast() }
            if mantissa.hasSuffix(".") { mantissa.removeLast() }
            return mantissa + "e" + parts[1]
        }
        var s = String(format: "%.10g", value)
        if s.contains("e") { s = String(format: "%.10f", value) }
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    static func message(for error: CalcError) -> String {
        switch error {
        case .syntax: String(localized: "Incomplete")
        case .divideByZero: String(localized: "Can't divide by zero")
        case .domain: String(localized: "Not a number")
        case .unknownName(let n): String(localized: "Unknown “\(n)”")
        }
    }
}
