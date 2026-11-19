import Foundation

// B2 Units: tables of units (linear factors, temperature formulas, live currency) and a free-text parser
// for "5 km to mi", "72 f to c", "100 usd to eur".

enum UnitCategory: String, CaseIterable, Identifiable {
    case length, weight, temperature, volume, speed, area, data, time, currency
    var id: String { rawValue }
    var title: String {
        switch self {
        case .length: String(localized: "Length")
        case .weight: String(localized: "Weight")
        case .temperature: String(localized: "Temp")
        case .volume: String(localized: "Volume")
        case .speed: String(localized: "Speed")
        case .area: String(localized: "Area")
        case .data: String(localized: "Data")
        case .time: String(localized: "Time")
        case .currency: String(localized: "Currency")
        }
    }
    var symbol: String {
        switch self {
        case .length: "ruler"
        case .weight: "scalemass"
        case .temperature: "thermometer.medium"
        case .volume: "drop"
        case .speed: "speedometer"
        case .area: "square.dashed"
        case .data: "internaldrive"
        case .time: "clock"
        case .currency: "eurosign.circle"
        }
    }
}

struct UnitDef: Identifiable, Equatable {
    let id: String
    let name: String
    let symbol: String
    let category: UnitCategory
    let aliases: [String]
    /// value in this unit -> value in the category's base unit
    let toBase: (Double) -> Double
    let fromBase: (Double) -> Double
    /// The name a person reads, in the user's language. `name` stays English: it is one of the words typed text is matched against.
    var title: String?

    /// What the pickers show: the localized title, or `name` (currencies already carry the system's localized name).
    var displayName: String { title ?? name }

    static func == (a: UnitDef, b: UnitDef) -> Bool { a.id == b.id }

    static func linear(_ id: String, _ name: String, _ symbol: String, _ cat: UnitCategory, _ factor: Double, _ aliases: [String] = [],
                       title: String) -> UnitDef {
        UnitDef(id: id, name: name, symbol: symbol, category: cat, aliases: aliases + [id, symbol, name],
                toBase: { $0 * factor }, fromBase: { $0 / factor }, title: title)
    }
}

@MainActor
enum UnitCatalog {
    static let all: [UnitDef] = length + weight + temperature + volume + speed + area + data + time

    static func units(in category: UnitCategory) -> [UnitDef] {
        category == .currency ? CurrencyRates.shared.units : all.filter { $0.category == category }
    }

    static let length: [UnitDef] = [
        .linear("m", "meter", "m", .length, 1, ["meters", "metre", "metres"], title: String(localized: "meter")),
        .linear("km", "kilometer", "km", .length, 1000, ["kilometers", "kilometre", "kilometres", "kms"], title: String(localized: "kilometer")),
        .linear("cm", "centimeter", "cm", .length, 0.01, ["centimeters", "centimetre", "centimetres"], title: String(localized: "centimeter")),
        .linear("mm", "millimeter", "mm", .length, 0.001, ["millimeters", "millimetre", "millimetres"], title: String(localized: "millimeter")),
        .linear("mi", "mile", "mi", .length, 1609.344, ["miles"], title: String(localized: "mile")),
        .linear("yd", "yard", "yd", .length, 0.9144, ["yards", "yds"], title: String(localized: "yard")),
        .linear("ft", "foot", "ft", .length, 0.3048, ["feet", "foot", "'"], title: String(localized: "foot")),
        .linear("in", "inch", "in", .length, 0.0254, ["inches", "\""], title: String(localized: "inch")),
        .linear("nmi", "nautical mile", "nmi", .length, 1852, ["nautical miles"], title: String(localized: "nautical mile")),
    ]

    static let weight: [UnitDef] = [
        .linear("kg", "kilogram", "kg", .weight, 1, ["kilograms", "kilo", "kilos"], title: String(localized: "kilogram")),
        .linear("g", "gram", "g", .weight, 0.001, ["grams", "gr"], title: String(localized: "gram")),
        .linear("mg", "milligram", "mg", .weight, 0.000_001, ["milligrams"], title: String(localized: "milligram")),
        .linear("t", "tonne", "t", .weight, 1000, ["tonnes", "metric ton", "metric tons"], title: String(localized: "tonne")),
        .linear("lb", "pound", "lb", .weight, 0.453_592_37, ["pounds", "lbs"], title: String(localized: "pound")),
        .linear("oz", "ounce", "oz", .weight, 0.028_349_523_125, ["ounces"], title: String(localized: "ounce")),
        .linear("st", "stone", "st", .weight, 6.350_293_18, ["stones"], title: String(localized: "stone")),
    ]

    static let temperature: [UnitDef] = [
        UnitDef(id: "c", name: "Celsius", symbol: "°C", category: .temperature, aliases: ["c", "celsius", "centigrade", "°c", "degc", "deg c"],
                toBase: { $0 }, fromBase: { $0 }, title: String(localized: "Celsius")),
        UnitDef(id: "f", name: "Fahrenheit", symbol: "°F", category: .temperature, aliases: ["f", "fahrenheit", "°f", "degf", "deg f"],
                toBase: { ($0 - 32) * 5 / 9 }, fromBase: { $0 * 9 / 5 + 32 }, title: String(localized: "Fahrenheit")),
        UnitDef(id: "k", name: "Kelvin", symbol: "K", category: .temperature, aliases: ["k", "kelvin", "kelvins"],
                toBase: { $0 - 273.15 }, fromBase: { $0 + 273.15 }, title: String(localized: "Kelvin")),
    ]

    static let volume: [UnitDef] = [
        .linear("l", "liter", "L", .volume, 1, ["liters", "litre", "litres", "ltr"], title: String(localized: "liter")),
        .linear("ml", "milliliter", "mL", .volume, 0.001, ["milliliters", "millilitre", "millilitres"], title: String(localized: "milliliter")),
        .linear("cl", "centiliter", "cL", .volume, 0.01, ["centiliters"], title: String(localized: "centiliter")),
        .linear("m3", "cubic meter", "m³", .volume, 1000, ["m³", "cubic meters"], title: String(localized: "cubic meter")),
        .linear("gal", "US gallon", "gal", .volume, 3.785_411_784, ["gallon", "gallons", "us gallon", "us gallons"], title: String(localized: "US gallon")),
        .linear("qt", "quart", "qt", .volume, 0.946_352_946, ["quarts"], title: String(localized: "quart")),
        .linear("pt", "pint", "pt", .volume, 0.473_176_473, ["pints"], title: String(localized: "pint")),
        .linear("cup", "cup", "cup", .volume, 0.236_588_236_5, ["cups"], title: String(localized: "cup")),
        .linear("floz", "fluid ounce", "fl oz", .volume, 0.029_573_529_562_5, ["fl oz", "fluid ounces", "floz"], title: String(localized: "fluid ounce")),
        .linear("tbsp", "tablespoon", "tbsp", .volume, 0.014_786_764_781_25, ["tablespoons"], title: String(localized: "tablespoon")),
        .linear("tsp", "teaspoon", "tsp", .volume, 0.004_928_921_593_75, ["teaspoons"], title: String(localized: "teaspoon")),
    ]

    static let speed: [UnitDef] = [
        .linear("m/s", "meters per second", "m/s", .speed, 1, ["mps", "meters per second"], title: String(localized: "meters per second")),
        .linear("km/h", "kilometers per hour", "km/h", .speed, 1 / 3.6, ["kph", "kmh", "kmph", "kilometers per hour"], title: String(localized: "kilometers per hour")),
        .linear("mph", "miles per hour", "mph", .speed, 0.447_04, ["miles per hour", "mi/h"], title: String(localized: "miles per hour")),
        .linear("kn", "knot", "kn", .speed, 0.514_444_444, ["knots", "kt", "kts"], title: String(localized: "knot")),
        .linear("ft/s", "feet per second", "ft/s", .speed, 0.3048, ["fps", "feet per second"], title: String(localized: "feet per second")),
    ]

    static let area: [UnitDef] = [
        .linear("m2", "square meter", "m²", .area, 1, ["m²", "sqm", "sq m", "square meters", "square metres"], title: String(localized: "square meter")),
        .linear("km2", "square kilometer", "km²", .area, 1_000_000, ["km²", "sq km", "square kilometers"], title: String(localized: "square kilometer")),
        .linear("ha", "hectare", "ha", .area, 10_000, ["hectares"], title: String(localized: "hectare")),
        .linear("cm2", "square centimeter", "cm²", .area, 0.0001, ["cm²", "square centimeters"], title: String(localized: "square centimeter")),
        .linear("ft2", "square foot", "ft²", .area, 0.092_903_04, ["ft²", "sqft", "sq ft", "square feet", "square foot"], title: String(localized: "square foot")),
        .linear("in2", "square inch", "in²", .area, 0.000_645_16, ["in²", "sq in", "square inches"], title: String(localized: "square inch")),
        .linear("yd2", "square yard", "yd²", .area, 0.836_127_36, ["yd²", "square yards"], title: String(localized: "square yard")),
        .linear("ac", "acre", "ac", .area, 4046.856_422_4, ["acres"], title: String(localized: "acre")),
        .linear("mi2", "square mile", "mi²", .area, 2_589_988.110_336, ["mi²", "sq mi", "square miles"], title: String(localized: "square mile")),
    ]

    static let data: [UnitDef] = [
        .linear("b", "byte", "B", .data, 1, ["bytes"], title: String(localized: "byte")),
        .linear("kb", "kilobyte", "KB", .data, 1000, ["kilobytes"], title: String(localized: "kilobyte")),
        .linear("mb", "megabyte", "MB", .data, 1_000_000, ["megabytes"], title: String(localized: "megabyte")),
        .linear("gb", "gigabyte", "GB", .data, 1_000_000_000, ["gigabytes", "gig", "gigs"], title: String(localized: "gigabyte")),
        .linear("tb", "terabyte", "TB", .data, 1_000_000_000_000, ["terabytes"], title: String(localized: "terabyte")),
        .linear("pb", "petabyte", "PB", .data, 1_000_000_000_000_000, ["petabytes"], title: String(localized: "petabyte")),
        .linear("kib", "kibibyte", "KiB", .data, 1024, ["kibibytes"], title: String(localized: "kibibyte")),
        .linear("mib", "mebibyte", "MiB", .data, 1_048_576, ["mebibytes"], title: String(localized: "mebibyte")),
        .linear("gib", "gibibyte", "GiB", .data, 1_073_741_824, ["gibibytes"], title: String(localized: "gibibyte")),
        .linear("bit", "bit", "bit", .data, 0.125, ["bits"], title: String(localized: "bit")),
        .linear("mbit", "megabit", "Mbit", .data, 125_000, ["megabits", "mbps"], title: String(localized: "megabit")),
    ]

    static let time: [UnitDef] = [
        .linear("s", "second", "s", .time, 1, ["sec", "secs", "seconds"], title: String(localized: "second")),
        .linear("ms", "millisecond", "ms", .time, 0.001, ["milliseconds"], title: String(localized: "millisecond")),
        .linear("min", "minute", "min", .time, 60, ["mins", "minutes"], title: String(localized: "minute")),
        .linear("h", "hour", "h", .time, 3600, ["hr", "hrs", "hours"], title: String(localized: "hour")),
        .linear("d", "day", "d", .time, 86_400, ["days"], title: String(localized: "day")),
        .linear("wk", "week", "wk", .time, 604_800, ["weeks", "w"], title: String(localized: "week")),
        .linear("mo", "month", "mo", .time, 2_629_746, ["months"], title: String(localized: "month")),
        .linear("yr", "year", "yr", .time, 31_556_952, ["years", "y", "yrs"], title: String(localized: "year")),
    ]

    /// Finds a unit by what the user typed ("Miles", "°F", "km/h", "eur"). Optionally within one category.
    static func find(_ raw: String, in category: UnitCategory? = nil) -> UnitDef? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !key.isEmpty else { return nil }
        let pool = (category.map { units(in: $0) } ?? (all + CurrencyRates.shared.units))
        // Exact id/symbol/name/alias first, then a plural "s" stripped.
        for candidate in [key, key.hasSuffix("s") ? String(key.dropLast()) : key] {
            if let hit = pool.first(where: { $0.id.lowercased() == candidate || $0.symbol.lowercased() == candidate
                                            || $0.name.lowercased() == candidate || $0.aliases.contains { $0.lowercased() == candidate } }) {
                return hit
            }
        }
        return nil
    }

    static func convert(_ value: Double, from: UnitDef, to: UnitDef) -> Double {
        to.fromBase(from.toBase(value))
    }

    /// Reads "5 km to mi" style text.
    static func parse(_ text: String) -> (value: Double, from: UnitDef, to: UnitDef)? {
        let pattern = #"^\s*(-?\d[\d_]*(?:[.,]\d+)?)\s*(.+?)\s+(?:to|in|into|as|->|→|=)\s+(.+?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges == 4,
              let r1 = Range(m.range(at: 1), in: text), let r2 = Range(m.range(at: 2), in: text), let r3 = Range(m.range(at: 3), in: text)
        else { return nil }
        let number = text[r1].replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "_", with: "")
        guard let value = Double(number), let from = find(String(text[r2])) else { return nil }
        guard let to = find(String(text[r3]), in: from.category) else { return nil }
        return (value, from, to)
    }

    static func format(_ v: Double) -> String {
        if v == 0 { return "0" }
        let a = abs(v)
        if a >= 1e12 || a < 1e-4 { return String(format: "%.4e", v) }
        let digits = a >= 1000 ? 2 : (a >= 1 ? 4 : 6)
        var s = String(format: "%.\(digits)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        // Plain digits (no thousands separators): they copy cleanly into other apps in any locale.
        return s == "-0" ? "0" : s
    }
}

// MARK: - Currency

@MainActor
final class CurrencyRates: ObservableObject {
    static let shared = CurrencyRates()

    private struct Cache: Codable { var date: Date; var rates: [String: Double] }

    /// Units of currency per 1 USD.
    @Published private(set) var rates: [String: Double] = ["USD": 1]
    @Published private(set) var updated: Date?
    @Published private(set) var isOffline = false

    private let file = JSONFile<Cache>("currency-rates.json")
    private var loading = false

    init() {
        if ScoutRuntime.isScripted {
            rates = ["USD": 1, "EUR": 0.92, "GBP": 0.79, "JPY": 156.4, "CHF": 0.88, "CAD": 1.37, "AUD": 1.52, "SEK": 10.6, "NOK": 10.8, "CNY": 7.24, "INR": 83.4]
            updated = Date().addingTimeInterval(-3 * 3600)
        } else if let cache = file.load() {
            rates = cache.rates.merging(["USD": 1]) { a, _ in a }
            updated = cache.date
        }
    }

    var units: [UnitDef] {
        rates.keys.sorted().map { code in
            let name = Locale.current.localizedString(forCurrencyCode: code) ?? code
            let rate = rates[code] ?? 1
            return UnitDef(id: code, name: name, symbol: code, category: .currency, aliases: [code.lowercased(), name.lowercased()],
                           toBase: { $0 / rate }, fromBase: { $0 * rate })
        }
    }

    /// Refreshes when the cache is older than 12 hours. Offline keeps the cache.
    func refreshIfNeeded() {
        guard !ScoutRuntime.isScripted, !loading else { return }
        if let updated, Date().timeIntervalSince(updated) < 12 * 3600, rates.count > 1 { return }
        loading = true
        guard let url = URL(string: "https://api.frankfurter.dev/v1/latest?base=USD") else { return }
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 10)) { data, _, _ in
            var fresh: [String: Double]?
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let r = obj["rates"] as? [String: Double] {
                fresh = r
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let me = CurrencyRates.shared
                    me.loading = false
                    if let fresh {
                        me.rates = fresh.merging(["USD": 1]) { a, _ in a }
                        me.updated = Date()
                        me.isOffline = false
                        me.file.save(Cache(date: Date(), rates: me.rates))
                    } else {
                        me.isOffline = true
                    }
                }
            }
        }.resume()
    }
}
