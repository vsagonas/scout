import SwiftUI

/// WMO weather codes (what Open-Meteo returns) mapped to words, SF Symbols and a sky gradient.
enum WeatherKind: String, Codable {
    case clear, partly, cloudy, fog, drizzle, rain, heavyRain, sleet, snow, thunder

    init(code: Int) {
        switch code {
        case 0: self = .clear
        case 1, 2: self = .partly
        case 3: self = .cloudy
        case 45, 48: self = .fog
        case 51, 53, 55: self = .drizzle
        case 56, 57, 66, 67: self = .sleet
        case 61, 63, 80, 81: self = .rain
        case 65, 82: self = .heavyRain
        case 71, 73, 75, 77, 85, 86: self = .snow
        case 95, 96, 99: self = .thunder
        default: self = .cloudy
        }
    }

    func symbol(day: Bool) -> String {
        switch self {
        case .clear: day ? "sun.max.fill" : "moon.stars.fill"
        case .partly: day ? "cloud.sun.fill" : "cloud.moon.fill"
        case .cloudy: "cloud.fill"
        case .fog: "cloud.fog.fill"
        case .drizzle: "cloud.drizzle.fill"
        case .rain: "cloud.rain.fill"
        case .heavyRain: "cloud.heavyrain.fill"
        case .sleet: "cloud.sleet.fill"
        case .snow: "cloud.snow.fill"
        case .thunder: "cloud.bolt.rain.fill"
        }
    }

    func label(code: Int) -> String {
        switch code {
        case 0: return String(localized: "Clear")
        case 1: return String(localized: "Mostly clear")
        case 2: return String(localized: "Partly cloudy")
        case 3: return String(localized: "Overcast")
        case 45, 48: return String(localized: "Fog")
        case 51, 53, 55: return String(localized: "Drizzle")
        case 56, 57: return String(localized: "Freezing drizzle")
        case 61: return String(localized: "Light rain")
        case 63: return String(localized: "Rain")
        case 65: return String(localized: "Heavy rain")
        case 66, 67: return String(localized: "Freezing rain")
        case 71: return String(localized: "Light snow")
        case 73: return String(localized: "Snow")
        case 75: return String(localized: "Heavy snow")
        case 77: return String(localized: "Snow grains")
        case 80, 81: return String(localized: "Showers")
        case 82: return String(localized: "Heavy showers")
        case 85, 86: return String(localized: "Snow showers")
        case 95: return String(localized: "Thunderstorm")
        case 96, 99: return String(localized: "Thunder and hail")
        default: return String(localized: "Cloudy")
        }
    }

    /// Sky colors (top, bottom), tuned so white text stays readable.
    func gradient(day: Bool) -> [Color] {
        func c(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
        if !day {
            switch self {
            case .clear, .partly: return [c(0.05, 0.08, 0.24), c(0.20, 0.14, 0.42)]
            case .thunder: return [c(0.08, 0.07, 0.16), c(0.22, 0.17, 0.32)]
            default: return [c(0.09, 0.11, 0.20), c(0.19, 0.22, 0.32)]
            }
        }
        switch self {
        case .clear: return [c(0.16, 0.46, 0.90), c(0.42, 0.72, 0.98)]
        case .partly: return [c(0.27, 0.52, 0.86), c(0.55, 0.72, 0.92)]
        case .cloudy: return [c(0.42, 0.50, 0.62), c(0.62, 0.69, 0.78)]
        case .fog: return [c(0.52, 0.57, 0.63), c(0.70, 0.74, 0.78)]
        case .drizzle, .rain: return [c(0.28, 0.36, 0.50), c(0.48, 0.57, 0.70)]
        case .heavyRain, .sleet: return [c(0.20, 0.27, 0.40), c(0.38, 0.47, 0.60)]
        case .snow: return [c(0.50, 0.62, 0.78), c(0.78, 0.86, 0.94)]
        case .thunder: return [c(0.18, 0.18, 0.34), c(0.38, 0.34, 0.52)]
        }
    }
}

struct WeatherPlace: Codable, Equatable, Hashable {
    var name: String
    var region: String?
    var country: String?
    var latitude: Double
    var longitude: Double

    var subtitle: String { [region, country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ") }
}

struct WeatherHour: Codable, Hashable {
    var time: Date
    var temperature: Double   // °C
    var code: Int
    var isDay: Bool
}

struct WeatherSnapshot: Codable {
    var place: String
    var temperature: Double    // °C
    var code: Int
    var isDay: Bool
    var windKmh: Double
    var high: Double
    var low: Double
    var sunrise: Date?
    var sunset: Date?
    var hours: [WeatherHour]
    var fetchedAt: Date

    var kind: WeatherKind { WeatherKind(code: code) }
    var symbol: String { kind.symbol(day: isDay) }
    var label: String { kind.label(code: code) }
}

enum TemperatureUnit: String, CaseIterable, Identifiable {
    case automatic, celsius, fahrenheit
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .celsius: String(localized: "Celsius (°C)")
        case .fahrenheit: String(localized: "Fahrenheit (°F)")
        }
    }

    static var current: TemperatureUnit {
        TemperatureUnit(rawValue: Pref.string("weather.unit", "automatic")) ?? .automatic
    }

    var usesFahrenheit: Bool {
        switch self {
        case .celsius: false
        case .fahrenheit: true
        case .automatic: Locale.current.measurementSystem == .us
        }
    }

    /// "21°" (no unit letter, the way weather widgets show it).
    func format(_ celsius: Double) -> String {
        let v = usesFahrenheit ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(v.rounded()))°"
    }

    func speed(_ kmh: Double) -> String {
        usesFahrenheit ? "\(Int((kmh * 0.621371).rounded())) mph" : "\(Int(kmh.rounded())) km/h"
    }
}

enum WeatherSamples {
    static func snapshot(kind: WeatherKind = .partly, day: Bool = true, place: String = "Athens") -> WeatherSnapshot {
        let cal = Calendar.current
        let startOfHour = cal.dateInterval(of: .hour, for: Date())?.start ?? Date()
        let temps: [Double] = [21, 22, 22, 21, 19, 17, 16, 15]
        let codes: [Int] = [2, 2, 1, 0, 0, 1, 3, 3]
        let hours = (0..<8).map { i in
            let t = startOfHour.addingTimeInterval(Double(i) * 3600)
            let h = cal.component(.hour, from: t)
            return WeatherHour(time: t, temperature: temps[i], code: kind == .partly ? codes[i] : codeFor(kind), isDay: h >= 7 && h < 19)
        }
        let code = kind == .partly ? 2 : codeFor(kind)
        return WeatherSnapshot(place: place, temperature: 21, code: code, isDay: day, windKmh: 14, high: 23, low: 14,
                               sunrise: cal.date(bySettingHour: 7, minute: 12, second: 0, of: Date()),
                               sunset: cal.date(bySettingHour: 17, minute: 41, second: 0, of: Date()),
                               hours: hours, fetchedAt: Date())
    }

    static func codeFor(_ kind: WeatherKind) -> Int {
        switch kind {
        case .clear: 0
        case .partly: 2
        case .cloudy: 3
        case .fog: 45
        case .drizzle: 53
        case .rain: 63
        case .heavyRain: 65
        case .sleet: 67
        case .snow: 73
        case .thunder: 95
        }
    }

    static let cities: [WeatherPlace] = [
        WeatherPlace(name: "Athens", region: "Attica", country: "Greece", latitude: 37.98, longitude: 23.73),
        WeatherPlace(name: "Athens", region: "Georgia", country: "United States", latitude: 33.96, longitude: -83.38),
        WeatherPlace(name: "Athína", region: "Western Greece", country: "Greece", latitude: 37.9, longitude: 21.5),
    ]
}
