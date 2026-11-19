import CoreLocation
import Foundation

// Where stations come from: the free Radio Browser directory (https://api.radio-browser.info). This file builds the
// requests (as plain URLs the self-test can check without sending anything), talks to the directory with a descriptive
// User-Agent and host fallbacks, turns a typed place into coordinates with Apple's geocoder (no Location permission, the
// user's own location is never asked), and combines the answers. Scripted runs never reach the network: the real client
// refuses, and galleries and tests use `RadioFakeDirectory`.

// MARK: - Requests

struct RadioGeoFilter: Equatable {
    var latitude: Double
    var longitude: Double
    var distance: Double   // metres
}

/// One search of the directory.
struct RadioQuery: Equatable {
    var name: String?
    var countryCode: String?
    var state: String?
    var tag: String?
    var geo: RadioGeoFilter?
    var limit = 100

    /// The query items in a fixed order (the directory takes them in any order; tests compare URLs).
    var items: [(String, String)] {
        var list: [(String, String)] = []
        if let name { list.append(("name", name)) }
        if let countryCode { list.append(("countrycode", countryCode.uppercased())) }
        if let state { list.append(("state", state)) }
        if let tag { list.append(("tag", tag)) }
        if let geo {
            list.append(("geo_lat", String(format: "%.4f", geo.latitude)))
            list.append(("geo_long", String(format: "%.4f", geo.longitude)))
            list.append(("geo_distance", String(Int(geo.distance.rounded()))))
        }
        list += [("hidebroken", "true"), ("order", "clickcount"), ("reverse", "true"), ("limit", String(limit))]
        return list
    }

    static func == (a: RadioQuery, b: RadioQuery) -> Bool {
        a.items.map { "\($0.0)=\($0.1)" } == b.items.map { "\($0.0)=\($0.1)" }
    }
}

enum RadioEndpoints {
    /// The directory's own servers; the first that answers is used until it stops.
    static let hosts = ["de1.api.radio-browser.info", "nl1.api.radio-browser.info", "at1.api.radio-browser.info"]

    /// The directory asks every app for a descriptive User-Agent.
    static var userAgent: String { "Scout/\(ScoutRuntime.version)" }

    static func searchURL(_ query: RadioQuery, host: String = hosts[0]) -> URL {
        url(host, "/json/stations/search", query.items)
    }

    static func countriesURL(host: String = hosts[0]) -> URL {
        url(host, "/json/countries", [("hidebroken", "true"), ("order", "name")])
    }

    /// The directory counts a listen when one station starts playing: one GET of this address.
    static func playURL(stationID: String, host: String = hosts[0]) -> URL {
        url(host, "/json/url/" + encode(stationID), [])
    }

    private static func url(_ host: String, _ path: String, _ items: [(String, String)]) -> URL {
        var s = "https://\(host)\(path)"
        if !items.isEmpty { s += "?" + items.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&") }
        return URL(string: s) ?? URL(string: "https://\(host)")!
    }

    /// Percent-encodes everything but letters, digits and "-._~" (so "&", "+", "=" and spaces inside a name stay inside it).
    static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

// MARK: - Errors

enum RadioSearchError: Error, Equatable {
    case offline
    case unavailable

    /// One calm line.
    var message: String {
        switch self {
        case .offline: String(localized: "You seem to be offline. Radio needs the internet.")
        case .unavailable: String(localized: "The station directory isn't answering. Try again in a moment.")
        }
    }

    static func from(_ error: Error) -> RadioSearchError {
        if let e = error as? RadioSearchError { return e }
        let offline: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .cannotFindHost, .dnsLookupFailed]
        if let e = error as? URLError, offline.contains(e.code) { return .offline }
        return .unavailable
    }
}

// MARK: - The directory

@MainActor
protocol RadioDirectory: AnyObject {
    func search(_ query: RadioQuery) async throws -> [RadioStation]
    func countries() async throws -> [RadioCountry]
    /// A station started playing: the directory's listen count (one request, no answer needed).
    func reportPlay(_ station: RadioStation)
}

/// The real client. Nothing in a scripted run reaches it.
@MainActor
final class RadioBrowserDirectory: RadioDirectory {
    static let shared = RadioBrowserDirectory()

    private let session: URLSession
    private var preferred = 0   // the host that answered last

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": RadioEndpoints.userAgent, "Accept": "application/json"]
        session = URLSession(configuration: config)
    }

    func search(_ query: RadioQuery) async throws -> [RadioStation] {
        let data = try await get { RadioEndpoints.searchURL(query, host: $0) }
        guard let parsed = try? RadioParser.stations(from: data) else { throw RadioSearchError.unavailable }
        return parsed.stations
    }

    func countries() async throws -> [RadioCountry] {
        let data = try await get { RadioEndpoints.countriesURL(host: $0) }
        guard let list = try? RadioParser.countries(from: data) else { throw RadioSearchError.unavailable }
        return list
    }

    func reportPlay(_ station: RadioStation) {
        guard !ScoutRuntime.isScripted else { return }
        Task { _ = try? await get { RadioEndpoints.playURL(stationID: station.id, host: $0) } }
    }

    /// Tries the hosts in turn (the one that worked last first); a host that fails is skipped, never retried in a loop.
    private func get(_ make: (String) -> URL) async throws -> Data {
        guard !ScoutRuntime.isScripted else { throw RadioSearchError.unavailable }   // no network in scripted runs
        let hosts = RadioEndpoints.hosts
        var failure: Error = RadioSearchError.unavailable
        for step in 0..<hosts.count {
            let index = (preferred + step) % hosts.count
            var request = URLRequest(url: make(hosts[index]))
            request.setValue(RadioEndpoints.userAgent, forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { failure = RadioSearchError.unavailable; continue }
                preferred = index
                return data
            } catch {
                if Task.isCancelled { throw CancellationError() }
                failure = error
            }
        }
        throw RadioSearchError.from(failure)
    }
}

// MARK: - Geocoding

struct RadioGeoPlace: Equatable {
    var name: String
    var latitude: Double
    var longitude: Double
    var radius: Double         // metres, the size of the place
    var countryCode: String?
    var countryOnly = false    // the text named a whole country
}

@MainActor
protocol RadioGeocoding: AnyObject {
    /// Coordinates for a typed place name; nil when it cannot be found (or the network is out).
    func locate(_ text: String) async -> RadioGeoPlace?
}

/// Apple's geocoder: turns the typed name into coordinates. It needs no Location permission.
@MainActor
final class RadioCLGeocoder: RadioGeocoding {
    func locate(_ text: String) async -> RadioGeoPlace? {
        guard !ScoutRuntime.isScripted else { return nil }
        let geocoder = CLGeocoder()
        return await withTaskGroup(of: RadioGeoPlace?.self) { group in
            group.addTask { @MainActor in
                guard let mark = try? await geocoder.geocodeAddressString(text).first, let location = mark.location else { return nil }
                let radius = (mark.region as? CLCircularRegion)?.radius ?? 25_000
                let countryOnly = mark.country != nil && mark.locality == nil && mark.administrativeArea == nil && mark.subAdministrativeArea == nil
                return RadioGeoPlace(name: mark.locality ?? mark.administrativeArea ?? mark.country ?? text,
                                     latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                                     radius: radius, countryCode: mark.isoCountryCode, countryOnly: countryOnly)
            }
            group.addTask { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return nil }
                geocoder.cancelGeocode()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

// MARK: - From a typed place to stations

enum RadioPlan {
    /// How far from the place a geo search looks: the size of the place, between 20 and 100 km.
    static func distance(for place: RadioGeoPlace) -> Double { min(100_000, max(20_000, place.radius)) }

    /// The searches a typed place becomes. `restriction` is a picked country (every search stays inside it);
    /// `matched` is a country the text names itself; `geo` is where the geocoder put the text.
    static func queries(text: String, restriction: String?, matched: RadioCountry?, geo: RadioGeoPlace?, limit: Int = 100) -> [RadioQuery] {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = parts.first else { return [] }
        func q(name: String? = nil, state: String? = nil, geo: RadioGeoFilter? = nil, country: String? = nil) -> RadioQuery {
            RadioQuery(name: name, countryCode: country ?? restriction, state: state, geo: geo, limit: limit)
        }
        if let matched, restriction == nil { return [q(country: matched.code)] }
        if let geo, geo.countryOnly, restriction == nil, let code = geo.countryCode { return [q(country: code)] }
        var list: [RadioQuery] = []
        if let geo {
            list.append(q(geo: RadioGeoFilter(latitude: geo.latitude, longitude: geo.longitude, distance: distance(for: geo))))
            list.append(q(name: first))
            if parts.count == 1 { list.append(q(state: first)) }   // "Attica" is a state; "Athens, Attica" the geo search already covers
        } else {
            list.append(q(state: first))
            if parts.count > 1, let last = parts.last { list.append(q(state: last)) }
            list.append(q(name: first))
        }
        return list
    }

    /// The country a text names: its name ("Iceland", "Netherlands") or its two-letter code ("IS").
    static func country(named text: String, in countries: [RadioCountry]) -> RadioCountry? {
        let t = RadioText.fold(text)
        guard !t.isEmpty else { return nil }
        return countries.first { $0.foldedName == t || RadioText.fold($0.displayName) == t } ?? (t.count == 2 ? countries.first { $0.code.lowercased() == t } : nil)
    }
}

struct RadioSearchResult: Equatable {
    var stations: [RadioStation]
    var queries: [RadioQuery]
    var placeName: String?
}

@MainActor
struct RadioSearcher {
    let directory: RadioDirectory
    let geocoder: RadioGeocoding

    /// Stations for a typed place and/or a picked country. Throws `RadioSearchError` only when the directory itself failed.
    func search(text: String, country: RadioCountry?, countries: [RadioCountry], limit: Int = 100) async throws -> RadioSearchResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard let country else { return RadioSearchResult(stations: [], queries: [], placeName: nil) }
            let query = RadioQuery(countryCode: country.code, limit: limit)
            let found = try await directory.search(query)
            return RadioSearchResult(stations: RadioParser.merge([found], limit: limit), queries: [query], placeName: country.name)
        }
        let matched = country == nil ? RadioPlan.country(named: trimmed, in: countries) : nil
        let geo = matched == nil ? await geocoder.locate(trimmed) : nil
        let queries = RadioPlan.queries(text: trimmed, restriction: country?.code, matched: matched, geo: geo, limit: limit)
        var lists: [[RadioStation]] = []
        var failure: Error?
        for query in queries {   // one after the other: three small requests, and the order is the same every time
            do { lists.append(try await directory.search(query)) } catch {
                if error is CancellationError { throw error }
                failure = error
            }
        }
        if lists.isEmpty, let failure { throw RadioSearchError.from(failure) }
        return RadioSearchResult(stations: RadioParser.merge(lists, limit: limit), queries: queries, placeName: matched?.name ?? geo?.name)
    }
}
