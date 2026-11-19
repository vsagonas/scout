import Combine
import Foundation

// What Scout remembers for the Radio tab, in one small file in Scout's own folder (`radio.json`): the stations played last,
// the places searched last, favourites, the person's own lists, and the last station (shown ready after a relaunch, never
// playing). Nothing leaves the Mac. Writes are small and synchronous, so a quit never loses the last click.

/// Where the saved things live: a file, or nowhere (galleries and the shared store of scripted runs).
struct RadioStorage {
    var url: URL?

    func load() -> RadioSaved {
        guard let url, let data = try? Data(contentsOf: url) else { return RadioSaved() }
        return (try? JSONDecoder.scout.decode(RadioSaved.self, from: data)) ?? RadioSaved()
    }

    func save(_ saved: RadioSaved) {
        guard let url, let data = try? JSONEncoder.scout.encode(saved) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static var standard: RadioStorage { RadioStorage(url: ScoutRuntime.isScripted ? nil : AppPaths.file("radio.json")) }
}

enum RadioLimits {
    static let latest = 20
    static let places = 10
}

@MainActor
final class RadioStore: ObservableObject {
    static let shared = RadioStore(storage: .standard)

    @Published private(set) var saved: RadioSaved
    private let storage: RadioStorage

    init(storage: RadioStorage, saved: RadioSaved? = nil) {
        self.storage = storage
        self.saved = saved ?? storage.load()
    }

    var latest: [RadioStation] { saved.latest }
    var places: [RadioPlace] { saved.places }
    var favourites: [RadioStation] { saved.favourites }
    var lists: [RadioList] { saved.lists }
    var last: RadioStation? { saved.last }

    private func change(_ edit: (inout RadioSaved) -> Void) {
        var next = saved
        edit(&next)
        guard next != saved else { return }
        saved = next
        storage.save(next)
    }

    /// Puts everything back as it was (a self-test that borrowed the shared store in a scripted run, where nothing is written to disk).
    func restore(_ previous: RadioSaved) { change { $0 = previous } }

    // MARK: Latest and last

    /// A station was played: first in "Latest" (once), and the one shown ready next time.
    func recordPlayed(_ station: RadioStation) {
        change {
            $0.latest.removeAll { $0.id == station.id }
            $0.latest.insert(station, at: 0)
            if $0.latest.count > RadioLimits.latest { $0.latest = Array($0.latest.prefix(RadioLimits.latest)) }
            $0.last = station
        }
    }

    func removeFromLatest(_ id: String) { change { $0.latest.removeAll { $0.id == id } } }

    // MARK: Places

    /// A place was searched: first in "Places" (once).
    func recordPlace(text: String, countryCode: String? = nil, date: Date = Date()) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let place = RadioPlace(text: t, countryCode: countryCode, date: date)
        change {
            $0.places.removeAll { $0.id == place.id }
            $0.places.insert(place, at: 0)
            if $0.places.count > RadioLimits.places { $0.places = Array($0.places.prefix(RadioLimits.places)) }
        }
    }

    func removePlace(_ id: String) { change { $0.places.removeAll { $0.id == id } } }

    /// "Clear latest stations and places": favourites, lists and the last station stay.
    func clearHistory() {
        change {
            $0.latest = []
            $0.places = []
        }
    }

    var hasHistory: Bool { !saved.latest.isEmpty || !saved.places.isEmpty }

    // MARK: Favourites

    func isFavourite(_ id: String) -> Bool { saved.favourites.contains { $0.id == id } }

    func toggleFavourite(_ station: RadioStation) {
        change {
            if $0.favourites.contains(where: { $0.id == station.id }) {
                $0.favourites.removeAll { $0.id == station.id }
            } else {
                $0.favourites.insert(station, at: 0)
            }
        }
    }

    // MARK: Lists

    @discardableResult
    func createList(named name: String? = nil) -> RadioList {
        let clean = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let list = RadioList(name: RadioText.unusedName(clean.isEmpty ? String(localized: "New list") : clean, among: saved.lists.map(\.name)))
        change { $0.lists.append(list) }
        return list
    }

    /// An empty or already used name keeps the old one.
    func renameList(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let list = saved.lists.first(where: { $0.id == id }), list.name != clean else { return }
        guard !saved.lists.contains(where: { $0.id != id && RadioText.fold($0.name) == RadioText.fold(clean) }) else { return }
        change { if let i = $0.lists.firstIndex(where: { $0.id == id }) { $0.lists[i].name = clean } }
    }

    func deleteList(_ id: UUID) { change { $0.lists.removeAll { $0.id == id } } }

    func list(_ id: UUID) -> RadioList? { saved.lists.first { $0.id == id } }

    func moveList(_ id: UUID, by offset: Int) {
        change {
            guard let i = $0.lists.firstIndex(where: { $0.id == id }) else { return }
            let j = min(max(0, i + offset), $0.lists.count - 1)
            guard j != i else { return }
            $0.lists.insert($0.lists.remove(at: i), at: j)
        }
    }

    /// Adds to the end; a station is in a list once.
    func add(_ station: RadioStation, toList id: UUID) {
        change {
            guard let i = $0.lists.firstIndex(where: { $0.id == id }), !$0.lists[i].stations.contains(where: { $0.id == station.id }) else { return }
            $0.lists[i].stations.append(station)
        }
    }

    func remove(_ stationID: String, fromList id: UUID) {
        change { if let i = $0.lists.firstIndex(where: { $0.id == id }) { $0.lists[i].stations.removeAll { $0.id == stationID } } }
    }

    func move(_ stationID: String, inList id: UUID, by offset: Int) {
        change {
            guard let i = $0.lists.firstIndex(where: { $0.id == id }), let from = $0.lists[i].stations.firstIndex(where: { $0.id == stationID }) else { return }
            let to = min(max(0, from + offset), $0.lists[i].stations.count - 1)
            guard to != from else { return }
            $0.lists[i].stations.insert($0.lists[i].stations.remove(at: from), at: to)
        }
    }

    func listsContaining(_ stationID: String) -> Set<UUID> {
        Set(saved.lists.filter { $0.stations.contains { $0.id == stationID } }.map(\.id))
    }
}
