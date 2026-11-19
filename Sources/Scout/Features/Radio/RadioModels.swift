import Foundation

// The Radio tab's data: a station as the Radio Browser directory describes it (kept as a plain value so favourites,
// lists and "latest" are playable even when the directory cannot be reached), the countries, the places searched, the
// person's lists, and what Scout saves. The parser drops broken and duplicate stations.

struct RadioStation: Codable, Equatable, Identifiable, Hashable {
    var id: String                 // the directory's stationuuid
    var name: String
    var url: String                // url_resolved: the address that is played
    var homepage = ""
    var country = ""
    var countryCode = ""
    var state = ""
    var tags: [String] = []
    var codec = ""
    var bitrate = 0
    var isHLS = false
    var clickCount = 0
    var votes = 0
    var latitude: Double?
    var longitude: Double?

    init(id: String, name: String, url: String, homepage: String = "", country: String = "", countryCode: String = "", state: String = "",
         tags: [String] = [], codec: String = "", bitrate: Int = 0, isHLS: Bool = false, clickCount: Int = 0, votes: Int = 0,
         latitude: Double? = nil, longitude: Double? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.homepage = homepage
        self.country = country
        self.countryCode = countryCode
        self.state = state
        self.tags = tags
        self.codec = codec
        self.bitrate = bitrate
        self.isHLS = isHLS
        self.clickCount = clickCount
        self.votes = votes
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Tolerant: a file written by an older build (fewer fields) still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        homepage = try c.decodeIfPresent(String.self, forKey: .homepage) ?? ""
        country = try c.decodeIfPresent(String.self, forKey: .country) ?? ""
        countryCode = try c.decodeIfPresent(String.self, forKey: .countryCode) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        codec = try c.decodeIfPresent(String.self, forKey: .codec) ?? ""
        bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate) ?? 0
        isHLS = try c.decodeIfPresent(Bool.self, forKey: .isHLS) ?? false
        clickCount = try c.decodeIfPresent(Int.self, forKey: .clickCount) ?? 0
        votes = try c.decodeIfPresent(Int.self, forKey: .votes) ?? 0
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
    }

    var streamURL: URL? { URL(string: url) }

    /// "Reykjavik, Iceland", "Iceland", or "" when the directory knows nothing.
    var place: String {
        let parts = [state, country].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.joined(separator: ", ")
    }

    /// "MP3 128k", "AAC 64k", "HLS": what the stream is.
    var quality: String {
        if isHLS { return "HLS" }
        let c = codec.trimmingCharacters(in: .whitespaces).uppercased()
        var parts: [String] = []
        if !c.isEmpty, c != "UNKNOWN" { parts.append(c) }
        if bitrate > 0 { parts.append("\(bitrate)k") }
        return parts.joined(separator: " ")
    }

    /// Up to three genre tags, "News talk · Jazz".
    var genreLine: String {
        tags.prefix(3).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " · ")
    }
}

struct RadioCountry: Codable, Equatable, Identifiable, Hashable {
    var name: String
    var code: String
    var stationCount = 0
    var id: String { code }

    /// "The Netherlands" matches "netherlands" and "Netherlands".
    var foldedName: String { RadioText.fold(name.hasPrefix("The ") ? String(name.dropFirst(4)) : name) }

    /// The name a person reads: the country in the user's language (the system knows it from the code), else the directory's English name.
    var displayName: String { Locale.current.localizedString(forRegionCode: code) ?? name }
}

/// A place that was searched, for the "Places" shortcuts.
struct RadioPlace: Codable, Equatable, Identifiable, Hashable {
    var text: String                // what was typed, or the country's name
    var countryCode: String?        // set when it was a country (browse or picked)
    var date: Date
    var id: String { (countryCode ?? "") + "|" + RadioText.fold(text) }

    /// What a chip shows: a country in the user's language, a typed place as it was typed.
    var displayText: String { countryCode.flatMap { Locale.current.localizedString(forRegionCode: $0) } ?? text }
}

struct RadioList: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var stations: [RadioStation] = []
}

/// Everything Scout saves for the Radio tab, in one file (`radio.json` in Scout's own folder).
struct RadioSaved: Codable, Equatable {
    var latest: [RadioStation] = []
    var places: [RadioPlace] = []
    var favourites: [RadioStation] = []
    var lists: [RadioList] = []
    var last: RadioStation?
}

enum RadioText {
    /// Lower case, no accents: "Reykjavík" equals "reykjavik".
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The name of a list when the person makes another: "New list", "New list 2"...
    static func unusedName(_ base: String, among names: [String]) -> String {
        let taken = Set(names.map(fold))
        if !taken.contains(fold(base)) { return base }
        var n = 2
        while taken.contains(fold("\(base) \(n)")) { n += 1 }
        return "\(base) \(n)"
    }
}

// MARK: - Parsing

enum RadioParser {
    struct Parsed: Equatable {
        var stations: [RadioStation]
        var dropped: Int
    }

    /// The directory's JSON array of stations. Broken entries, entries the Mac cannot play and duplicates are dropped.
    static func stations(from data: Data) throws -> Parsed {
        let rows = try JSONDecoder().decode([Lossy<Row>].self, from: data)
        var mapped: [RadioStation] = []
        var dropped = 0
        for row in rows {
            if let station = row.value.flatMap(station(from:)) { mapped.append(station) } else { dropped += 1 }
        }
        let kept = dedupe(mapped)
        return Parsed(stations: kept, dropped: dropped + mapped.count - kept.count)
    }

    static func countries(from data: Data) throws -> [RadioCountry] {
        struct Item: Decodable { var name: String?; var iso_3166_1: String?; var stationcount: Int? }
        let rows = try JSONDecoder().decode([Lossy<Item>].self, from: data)
        var seen = Set<String>()
        return rows.compactMap { row -> RadioCountry? in
            guard let item = row.value, let name = item.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let code = item.iso_3166_1?.trimmingCharacters(in: .whitespaces).uppercased(), code.count == 2,
                  seen.insert(code).inserted else { return nil }
            return RadioCountry(name: name, code: code, stationCount: item.stationcount ?? 0)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Several answers (state, name and geo searches) into one list: duplicates out, most listened first.
    static func merge(_ lists: [[RadioStation]], limit: Int) -> [RadioStation] {
        let all = lists.flatMap { $0 }.sorted { $0.clickCount > $1.clickCount }
        return Array(dedupe(all).prefix(limit))
    }

    /// The first of two stations with the same id, the same address, or the same name in the same place wins (callers sort
    /// by listeners first, so that is the most listened).
    static func dedupe(_ stations: [RadioStation]) -> [RadioStation] {
        var ids = Set<String>(), urls = Set<String>(), names = Set<String>()
        var kept: [RadioStation] = []
        for s in stations {
            let url = normalized(s.url)
            let name = RadioText.fold(s.name) + "|" + s.countryCode.uppercased() + "|" + RadioText.fold(s.state)
            guard !ids.contains(s.id), !urls.contains(url), !names.contains(name) else { continue }
            ids.insert(s.id)
            urls.insert(url)
            names.insert(name)
            kept.append(s)
        }
        return kept
    }

    private static func normalized(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespaces).lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Codecs AVPlayer cannot play on the Mac (Ogg Vorbis and Ogg Opus): offering them would only fail.
    static func isPlayableOnMac(codec: String, url: String) -> Bool {
        let c = codec.trimmingCharacters(in: .whitespaces).uppercased()
        if ["OGG", "VORBIS", "OPUS", "THEORA"].contains(c) { return false }
        let path = (URL(string: url)?.path ?? url).lowercased()
        return !(path.hasSuffix(".ogg") || path.hasSuffix(".oga") || path.hasSuffix(".opus"))
    }

    private static func station(from row: Row) -> RadioStation? {
        guard let id = row.stationuuid?.trimmingCharacters(in: .whitespaces), !id.isEmpty,
              let name = row.name.map(cleanName), !name.isEmpty,
              let url = row.url_resolved?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty,
              let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https",
              parsed.host?.isEmpty == false else { return nil }
        if row.lastcheckok == 0 { return nil }   // the directory's own checker found it broken
        let codec = row.codec ?? ""
        guard isPlayableOnMac(codec: codec, url: url) else { return nil }
        var seen = Set<String>()
        let tags = (row.tags ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && $0.count <= 28 && seen.insert($0).inserted }
        return RadioStation(id: id, name: name, url: url, homepage: row.homepage ?? "", country: row.country ?? "",
                            countryCode: (row.countrycode ?? "").uppercased(), state: (row.state ?? "").trimmingCharacters(in: .whitespaces),
                            tags: tags, codec: codec, bitrate: max(0, row.bitrate ?? 0), isHLS: (row.hls ?? 0) == 1,
                            clickCount: max(0, row.clickcount ?? 0), votes: max(0, row.votes ?? 0),
                            latitude: validated(row.geo_lat, 90), longitude: validated(row.geo_long, 180))
    }

    private static func validated(_ value: Double?, _ limit: Double) -> Double? {
        guard let value, value.isFinite, abs(value) <= limit, value != 0 else { return nil }
        return value
    }

    /// One line, single spaces.
    private static func cleanName(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The directory's field names (only the ones used).
    private struct Row: Decodable {
        var stationuuid: String?
        var name: String?
        var url_resolved: String?
        var homepage: String?
        var tags: String?
        var country: String?
        var countrycode: String?
        var state: String?
        var codec: String?
        var bitrate: Int?
        var hls: Int?
        var votes: Int?
        var clickcount: Int?
        var lastcheckok: Int?
        var geo_lat: Double?
        var geo_long: Double?
    }

    /// An array element that may fail to decode without failing the whole array.
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }
}
