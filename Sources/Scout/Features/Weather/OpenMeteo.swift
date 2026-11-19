import Foundation

/// Open-Meteo (no key): forecast and city search. Never called in scripted runs.
enum OpenMeteo {
    enum Failure: Error { case badResponse, offline }

    private static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Scout/\(ScoutRuntime.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.badResponse }
        return data
    }

    static func forecastURL(latitude: Double, longitude: Double) -> URL? {
        URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)"
            + "&current=temperature_2m,weather_code,is_day,wind_speed_10m"
            + "&hourly=temperature_2m,weather_code,is_day"
            + "&daily=temperature_2m_max,temperature_2m_min,sunrise,sunset&forecast_days=2&timezone=auto")
    }

    static func forecast(for place: WeatherPlace) async throws -> WeatherSnapshot {
        guard let url = forecastURL(latitude: place.latitude, longitude: place.longitude) else { throw Failure.badResponse }
        return try parse(try await get(url), placeName: place.name)
    }

    static func parse(_ data: Data, placeName: String) throws -> WeatherSnapshot {
        struct Response: Decodable {
            struct Current: Decodable { var temperature_2m: Double; var weather_code: Int; var is_day: Int; var wind_speed_10m: Double }
            struct Hourly: Decodable { var time: [String]; var temperature_2m: [Double?]; var weather_code: [Int?]; var is_day: [Int?]? }
            struct Daily: Decodable { var temperature_2m_max: [Double?]; var temperature_2m_min: [Double?]; var sunrise: [String]; var sunset: [String] }
            var utc_offset_seconds: Int
            var current: Current
            var hourly: Hourly
            var daily: Daily
        }
        let r = try JSONDecoder().decode(Response.self, from: data)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: r.utc_offset_seconds)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        var hours: [WeatherHour] = []
        for (i, text) in r.hourly.time.enumerated() {
            guard let date = formatter.date(from: text), i < r.hourly.temperature_2m.count, i < r.hourly.weather_code.count,
                  let t = r.hourly.temperature_2m[i], let c = r.hourly.weather_code[i] else { continue }
            let day = r.hourly.is_day.flatMap { i < $0.count ? $0[i] : nil } ?? 1
            hours.append(WeatherHour(time: date, temperature: t, code: c, isDay: day == 1))
        }
        return WeatherSnapshot(place: placeName, temperature: r.current.temperature_2m, code: r.current.weather_code,
                               isDay: r.current.is_day == 1, windKmh: r.current.wind_speed_10m,
                               high: r.daily.temperature_2m_max.first.flatMap { $0 } ?? r.current.temperature_2m,
                               low: r.daily.temperature_2m_min.first.flatMap { $0 } ?? r.current.temperature_2m,
                               sunrise: r.daily.sunrise.first.flatMap(formatter.date(from:)),
                               sunset: r.daily.sunset.first.flatMap(formatter.date(from:)),
                               hours: hours, fetchedAt: Date())
    }

    static func search(_ name: String) async throws -> [WeatherPlace] {
        var comps = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        comps.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "count", value: "5")]
        guard let url = comps.url else { return [] }
        struct Response: Decodable {
            struct Item: Decodable { var name: String; var latitude: Double; var longitude: Double; var country: String?; var admin1: String? }
            var results: [Item]?
        }
        let r = try JSONDecoder().decode(Response.self, from: try await get(url))
        return (r.results ?? []).map { WeatherPlace(name: $0.name, region: $0.admin1, country: $0.country, latitude: $0.latitude, longitude: $0.longitude) }
    }
}
