import Combine
import Foundation

// What the Radio tab is doing: the page (Search, Latest, Favourites, a list), the typed place and picked country, the
// answer of the last search and its calm state line. Playing is `RadioService`'s; saved things are `RadioStore`'s.

@MainActor
final class RadioModel: ObservableObject {
    enum Page: Hashable {
        case search, latest, favourites
        case list(UUID)
    }

    /// Where the last search stands.
    enum Phase: Equatable {
        case idle           // nothing typed or picked yet
        case searching
        case results
        case empty          // asked, nobody there
        case offline
        case failed         // the directory did not answer
    }

    /// The real one (scripted runs get the fixture directory and geocoder, so nothing reaches the network).
    static let shared: RadioModel = {
        let scripted = ScoutRuntime.isScripted
        let searcher = RadioSearcher(directory: scripted ? RadioFakeDirectory() : RadioBrowserDirectory.shared,
                                     geocoder: scripted ? RadioFakeGeocoder() : RadioCLGeocoder())
        return RadioModel(service: .shared, searcher: searcher)
    }()

    @Published var page: Page = .search
    @Published var query = ""
    @Published private(set) var country: RadioCountry?
    @Published private(set) var countries: [RadioCountry] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var results: [RadioStation] = []
    @Published private(set) var placeName: String?
    /// The list whose name is being typed in the sidebar.
    @Published var renaming: UUID?
    /// True once a gallery or test put a fixed state on the model with `showSample`: opening the tab then leaves that state alone.
    private(set) var isSample = false
    /// Where the boombox's controls are in the Radio view (not published: nothing redraws for it; the self-test clicks them by name).
    var controlRects: [String: CGRect] = [:]

    let service: RadioService
    private let searcher: RadioSearcher
    private let debounce: TimeInterval
    private var searchTask: Task<Void, Never>?
    private var typingTask: Task<Void, Never>?
    private var generation = 0
    private var lastSearched = ""

    var store: RadioStore { service.store }

    init(service: RadioService, searcher: RadioSearcher, debounce: TimeInterval = 0.6) {
        self.service = service
        self.searcher = searcher
        self.debounce = debounce
    }

    // MARK: Search

    private var key: String { RadioText.fold(query) + "|" + (country?.code ?? "") }

    /// The person typed: search after a short quiet (Return searches at once).
    func queryChanged() {
        typingTask?.cancel()
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, country == nil {
            reset()
            return
        }
        guard key != lastSearched else { return }
        let wait = debounce
        typingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.search()
        }
    }

    func submit() {
        typingTask?.cancel()
        search()
    }

    func pickCountry(_ picked: RadioCountry?) {
        country = picked
        typingTask?.cancel()
        if picked == nil, query.trimmingCharacters(in: .whitespaces).isEmpty { reset() } else { search() }
    }

    /// One click on a saved place: search it again.
    func searchPlace(_ place: RadioPlace) {
        page = .search
        typingTask?.cancel()
        if let code = place.countryCode {
            query = ""
            country = countries.first { $0.code == code } ?? RadioCountry(name: place.text, code: code)
        } else {
            country = nil
            query = place.text
        }
        search()
    }

    private func reset() {
        searchTask?.cancel()
        generation += 1
        lastSearched = ""
        results = []
        placeName = nil
        phase = .idle
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || country != nil else { reset(); return }
        searchTask?.cancel()
        generation += 1
        let mine = generation
        let picked = country
        lastSearched = key
        phase = .searching
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let found = try await self.searcher.search(text: text, country: picked, countries: self.countries)
                guard mine == self.generation else { return }
                self.results = found.stations
                self.placeName = found.placeName
                self.phase = found.stations.isEmpty ? .empty : .results
                if !found.stations.isEmpty {
                    self.store.recordPlace(text: text.isEmpty ? (picked?.name ?? "") : text, countryCode: text.isEmpty ? picked?.code : nil)
                }
            } catch is CancellationError {
                return
            } catch {
                guard mine == self.generation else { return }
                self.results = []
                self.phase = RadioSearchError.from(error) == .offline ? .offline : .failed
                self.lastSearched = ""   // asking again later must search again
            }
        }
    }

    /// Asks the directory for its countries once (the picker and "Greece"-style texts use them).
    func loadCountries() {
        guard countries.isEmpty else { return }
        Task { [weak self] in
            guard let self, let list = try? await self.searcher.directory.countries() else { return }
            self.countries = list
        }
    }

    /// Shows a state without searching (galleries).
    func showSample(page: Page, query: String, country: RadioCountry?, phase: Phase, results: [RadioStation], countries: [RadioCountry]) {
        isSample = true
        self.page = page
        self.query = query
        self.country = country
        self.phase = phase
        self.results = results
        self.countries = countries
    }

    /// Waits for the search that is running (tests).
    func settle() async {
        await typingTask?.value
        await searchTask?.value
    }

    // MARK: Opening

    /// The section the Radio tab opens on:
    /// Favourites when any station is saved, else Latest when something was played, else Search.
    var openingPage: Page {
        if !store.favourites.isEmpty { return .favourites }
        if !store.latest.isEmpty { return .latest }
        return .search
    }

    /// The Radio tab was opened (its view appeared: a tap on its key, the hotkey, a link into it): it shows the opening section. The person's own
    /// pick (a click on another section) stays for as long as the view stays open, because this runs only when the view appears.
    func tabOpened() {
        guard !isSample else { return }
        let opening = openingPage
        if page != opening { page = opening }
    }

    // MARK: What a page shows

    func stations(on page: Page) -> [RadioStation] {
        switch page {
        case .search: results
        case .latest: store.latest
        case .favourites: store.favourites
        case .list(let id): store.list(id)?.stations ?? []
        }
    }

    // MARK: Actions

    /// A click on a station: play it; on the one that is playing, pause or go on.
    func tap(_ station: RadioStation) {
        if service.station?.id == station.id, service.isActive { service.togglePause() } else { service.play(station) }
    }

    func newList(adding station: RadioStation? = nil) {
        let list = store.createList()
        if let station { store.add(station, toList: list.id) }
        page = .list(list.id)
        renaming = list.id
    }

    func commitRename(_ id: UUID, name: String) {
        store.renameList(id, to: name)
        if renaming == id { renaming = nil }
    }

    func deleteList(_ id: UUID) {
        store.deleteList(id)
        if page == .list(id) { page = .search }
        if renaming == id { renaming = nil }
    }

    /// The page to draw: a list that was deleted falls back to Search.
    var shownPage: Page {
        if case .list(let id) = page, store.list(id) == nil { return .search }
        return page
    }
}
