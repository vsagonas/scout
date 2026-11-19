import Combine
import Foundation

// Stand-ins for the sound, the directory and the geocoder: scripted runs (galleries, self-tests) use these and never open a
// stream or reach the network. The stations and places are invented (no real brands).

// MARK: - Sound

/// Remembers what it was asked and lets a test say what the "stream" does.
@MainActor
final class RadioFakeEngine: RadioEngine {
    private let subject = PassthroughSubject<RadioEngineEvent, Never>()
    var events: AnyPublisher<RadioEngineEvent, Never> { subject.eraseToAnyPublisher() }

    private(set) var played: [URL] = []
    private(set) var pauses = 0
    private(set) var resumes = 0
    private(set) var stops = 0
    private(set) var volume: Float = -1

    func play(_ url: URL) { played.append(url) }
    func pause() { pauses += 1 }
    func resume() { resumes += 1 }
    func stop() { stops += 1 }
    func setVolume(_ volume: Float) { self.volume = volume }

    /// What the stream does next.
    func emit(_ event: RadioEngineEvent) { subject.send(event) }
}

// MARK: - Directory

/// Answers from the fixture the way the directory would (name, state, country and geo filters), most listened first.
@MainActor
final class RadioFakeDirectory: RadioDirectory {
    var stations: [RadioStation]
    var countryList: [RadioCountry]
    var failure: RadioSearchError?
    private(set) var queries: [RadioQuery] = []
    private(set) var reported: [String] = []

    init(stations: [RadioStation] = RadioFixtures.stations, countries: [RadioCountry] = RadioFixtures.countries) {
        self.stations = stations
        self.countryList = countries
    }

    func search(_ query: RadioQuery) async throws -> [RadioStation] {
        queries.append(query)
        if let failure { throw failure }
        let found = stations.filter { s in
            if let code = query.countryCode, s.countryCode.uppercased() != code.uppercased() { return false }
            if let name = query.name, !RadioText.fold(s.name).contains(RadioText.fold(name)) { return false }
            if let state = query.state, !RadioText.fold(s.state).contains(RadioText.fold(state)) { return false }
            if let tag = query.tag, !s.tags.contains(RadioText.fold(tag)) { return false }
            if let geo = query.geo {
                guard let lat = s.latitude, let lon = s.longitude else { return false }
                if RadioFakeDirectory.metres(lat, lon, geo.latitude, geo.longitude) > geo.distance { return false }
            }
            return true
        }
        return Array(found.sorted { $0.clickCount > $1.clickCount }.prefix(query.limit))
    }

    func countries() async throws -> [RadioCountry] {
        if let failure { throw failure }
        return countryList
    }

    func reportPlay(_ station: RadioStation) { reported.append(station.id) }

    static func metres(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0, p = Double.pi / 180
        let a = pow(sin((lat2 - lat1) * p / 2), 2) + cos(lat1 * p) * cos(lat2 * p) * pow(sin((lon2 - lon1) * p / 2), 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }
}

/// Knows a few invented-station towns by name.
@MainActor
final class RadioFakeGeocoder: RadioGeocoding {
    var places: [String: RadioGeoPlace]
    private(set) var asked: [String] = []

    init(places: [String: RadioGeoPlace] = RadioFixtures.places) { self.places = places }

    func locate(_ text: String) async -> RadioGeoPlace? {
        asked.append(text)
        return places[RadioText.fold(text)]
    }
}

// MARK: - Fixtures

/// The directory's JSON shape (every field the real `/json/stations/search` sends), with invented stations. Captured
/// from one real answer (`countrycode=IS&limit=3`) and then filled with made-up names; no logos, no real brands.
enum RadioFixtures {
    private static func row(_ id: Int, _ name: String, url: String? = nil, country: String, code: String, state: String, tags: String,
                            codec: String = "MP3", bitrate: Int = 128, clicks: Int, votes: Int = 10, lat: Double? = nil, lon: Double? = nil,
                            ok: Int = 1, hls: Int = 0, resolved: String? = nil) -> [String: Any] {
        let uuid = String(format: "00000000-0000-4000-8000-%012d", id)
        let address = url ?? "https://stream.example.test/radio/\(id)"
        return ["changeuuid": uuid, "stationuuid": uuid, "serveruuid": NSNull(), "name": name, "url": address,
                "url_resolved": resolved ?? address, "homepage": "https://example.test/\(id)", "favicon": "", "tags": tags,
                "country": country, "countrycode": code, "iso_3166_2": "", "state": state, "language": "", "languagecodes": "",
                "votes": votes, "lastchangetime": "2026-01-14 23:46:56", "lastchangetime_iso8601": "2026-01-14T23:46:56Z",
                "codec": codec, "bitrate": bitrate, "hls": hls, "lastcheckok": ok, "lastchecktime": "2026-11-12 06:05:54",
                "lastchecktime_iso8601": "2026-11-12T06:05:54Z", "lastcheckoktime": "2026-11-12 06:05:54",
                "lastcheckoktime_iso8601": "2026-11-12T06:05:54Z", "lastlocalchecktime": "2026-11-12 06:05:54",
                "lastlocalchecktime_iso8601": "2026-11-12T06:05:54Z", "clicktimestamp": "2026-11-15 16:08:03",
                "clicktimestamp_iso8601": "2026-11-15T16:08:03Z", "clickcount": clicks, "clicktrend": 3, "ssl_error": 0,
                "geo_lat": lat.map { $0 as Any } ?? NSNull(), "geo_long": lon.map { $0 as Any } ?? NSNull(), "geo_distance": NSNull(), "has_extended_info": false]
    }

    private static let good: [[String: Any]] = [
        row(1, "Aurora FM", country: "Iceland", code: "IS", state: "Capital Region", tags: "pop,hits,news", clicks: 480, lat: 64.1466, lon: -21.9426),
        row(2, "Harbour Jazz", country: "Iceland", code: "IS", state: "Capital Region", tags: "jazz,smooth jazz", codec: "AAC", bitrate: 96, clicks: 210, lat: 64.15, lon: -21.95),
        row(3, "Geyser Talk", country: "Iceland", code: "IS", state: "Southern Region", tags: "talk,news", bitrate: 64, clicks: 90, lat: 64.31, lon: -20.30),
        row(4, "Northern Lights Classical", country: "Iceland", code: "IS", state: "Northeastern Region", tags: "classical", bitrate: 192, clicks: 140, lat: 65.68, lon: -18.11),
        row(5, "Aegean Breeze", country: "Greece", code: "GR", state: "Attica", tags: "pop,greek,hits", clicks: 900, lat: 37.9838, lon: 23.7275),
        row(6, "Plaka Sunset", country: "Greece", code: "GR", state: "Attica", tags: "chillout,lounge", codec: "AAC", bitrate: 128, clicks: 320, lat: 37.9715, lon: 23.7257),
        row(7, "Olive Grove Radio", country: "Greece", code: "GR", state: "Crete", tags: "folk,world", bitrate: 96, clicks: 120, lat: 35.3387, lon: 25.1442),
        row(8, "Acropolis Classics", country: "Greece", code: "GR", state: "Attica", tags: "classical,opera", bitrate: 192, clicks: 260, lat: 37.9715, lon: 23.7267),
        row(9, "Old Port Radio", country: "France", code: "FR", state: "Provence", tags: "chanson,pop", clicks: 540, lat: 43.2965, lon: 5.3698),
        row(10, "Canal du Midi FM", country: "France", code: "FR", state: "Occitanie", tags: "rock,indie", codec: "AAC+", bitrate: 64, clicks: 175, lat: 43.6045, lon: 1.4442),
        row(11, "Tagus Late Nights", country: "Portugal", code: "PT", state: "Lisbon", tags: "fado,lounge", clicks: 410, lat: 38.7223, lon: -9.1393),
        row(12, "Lisbon Morning Show", country: "Portugal", code: "PT", state: "Lisbon", tags: "news,talk,pop", bitrate: 96, clicks: 650, lat: 38.7169, lon: -9.1399),
        row(13, "Atlantic Surf Radio", country: "Portugal", code: "PT", state: "Algarve", tags: "surf rock,reggae", clicks: 85, lat: 37.0194, lon: -7.9304),
        row(14, "Highland Folk", country: "United Kingdom", code: "GB", state: "Scotland", tags: "folk,celtic", clicks: 300, lat: 57.4778, lon: -4.2247),
        row(15, "Thames Beat", country: "United Kingdom", code: "GB", state: "England", tags: "dance,electronic", clicks: 780, lat: 51.5072, lon: -0.1276),
        row(16, "Quiet Hours", country: "Iceland", code: "IS", state: "Capital Region", tags: "ambient,sleep", codec: "", bitrate: 0, clicks: 40, lat: 64.14, lon: -21.90),
    ]

    /// Made-up directory answer: sixteen good stations.
    static var stationsData: Data { (try? JSONSerialization.data(withJSONObject: good)) ?? Data() }

    static var stations: [RadioStation] { (try? RadioParser.stations(from: stationsData))?.stations ?? [] }

    /// Eight bad rows around one good one: nothing to play, not http(s), checked broken, Ogg, an empty name, a repeated id,
    /// a repeated address, a repeated name; and one row that is not even an object.
    static var dirtyData: Data {
        var rows: [Any] = [
            row(101, "Good One", country: "Iceland", code: "IS", state: "Capital Region", tags: "pop", clicks: 50),
            row(102, "No Address", country: "Iceland", code: "IS", state: "", tags: "pop", clicks: 5, resolved: ""),
            row(103, "Wrong Scheme", country: "Iceland", code: "IS", state: "", tags: "pop", clicks: 5, resolved: "ftp://stream.example.test/x"),
            row(104, "Checked Broken", country: "Iceland", code: "IS", state: "", tags: "pop", clicks: 5, ok: 0),
            row(105, "Ogg Only", country: "Iceland", code: "IS", state: "", tags: "pop", codec: "OGG", clicks: 5),
            row(106, "   ", country: "Iceland", code: "IS", state: "", tags: "pop", clicks: 5),
            row(101, "Good One Again", country: "Iceland", code: "IS", state: "", tags: "pop", clicks: 4),
            row(108, "Same Address", url: "https://stream.example.test/radio/101/", country: "Iceland", code: "IS", state: "", tags: "pop", clicks: 3),
            row(109, "good  one", country: "Iceland", code: "IS", state: "Capital Region", tags: "pop", clicks: 2),
        ]
        rows.append("not a station")
        return (try? JSONSerialization.data(withJSONObject: rows)) ?? Data()
    }

    static var countriesData: Data {
        let rows: [[String: Any]] = [
            ["name": "Iceland", "iso_3166_1": "IS", "stationcount": 16], ["name": "Greece", "iso_3166_1": "GR", "stationcount": 180],
            ["name": "France", "iso_3166_1": "FR", "stationcount": 900], ["name": "Portugal", "iso_3166_1": "PT", "stationcount": 140],
            ["name": "The United Kingdom Of Great Britain And Northern Ireland", "iso_3166_1": "GB", "stationcount": 2100],
            ["name": "The Netherlands", "iso_3166_1": "NL", "stationcount": 420],
        ]
        return (try? JSONSerialization.data(withJSONObject: rows)) ?? Data()
    }

    static var countries: [RadioCountry] { (try? RadioParser.countries(from: countriesData)) ?? [] }

    /// Where the fake geocoder puts a few typed places (folded names).
    static let places: [String: RadioGeoPlace] = [
        "reykjavik": RadioGeoPlace(name: "Reykjavik", latitude: 64.1466, longitude: -21.9426, radius: 30_000, countryCode: "IS"),
        "athens": RadioGeoPlace(name: "Athens", latitude: 37.9838, longitude: 23.7275, radius: 25_000, countryCode: "GR"),
        "athens, attica": RadioGeoPlace(name: "Athens", latitude: 37.9838, longitude: 23.7275, radius: 25_000, countryCode: "GR"),
        "lisbon": RadioGeoPlace(name: "Lisbon", latitude: 38.7223, longitude: -9.1393, radius: 20_000, countryCode: "PT"),
        "scotland": RadioGeoPlace(name: "Scotland", latitude: 56.49, longitude: -4.2, radius: 150_000, countryCode: "GB"),
    ]

    // MARK: Sample states for pictures

    static var aurora: RadioStation { stations.first { $0.name == "Aurora FM" }! }
    static var jazz: RadioStation { stations.first { $0.name == "Harbour Jazz" }! }
    static var aegean: RadioStation { stations.first { $0.name == "Aegean Breeze" }! }

    /// A store with some history, favourites and two lists, for galleries and tests (nothing on disk).
    @MainActor static func sampleStore() -> RadioStore {
        let all = stations
        func s(_ name: String) -> RadioStation { all.first { $0.name == name }! }
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let saved = RadioSaved(
            latest: ["Harbour Jazz", "Aegean Breeze", "Tagus Late Nights", "Thames Beat", "Old Port Radio", "Aurora FM"].map(s),
            places: [RadioPlace(text: "Reykjavik", countryCode: nil, date: day), RadioPlace(text: "Lisbon", countryCode: nil, date: day),
                     RadioPlace(text: "Greece", countryCode: "GR", date: day), RadioPlace(text: "Athens, Attica", countryCode: nil, date: day)],
            favourites: ["Aurora FM", "Aegean Breeze", "Tagus Late Nights"].map(s),
            lists: [RadioList(name: "Morning", stations: ["Lisbon Morning Show", "Aurora FM", "Thames Beat"].map(s)),
                    RadioList(name: "Focus", stations: ["Quiet Hours", "Acropolis Classics"].map(s)),
                    RadioList(name: "Road trip", stations: [])],
            last: s("Harbour Jazz"))
        return RadioStore(storage: RadioStorage(url: nil), saved: saved)
    }
}
