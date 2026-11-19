import SwiftUI

// Radio: internet radio by place, in the notch. Start-up, quick checks for the features self-test, and the gallery.

@MainActor
enum RadioFeature {
    static func start() {
        DebugCommands.register("radio.open") { _ in NotchNavigator.shared.open(.radio) }
        RadioNotchPresenter.shared.start()   // the radio in the closed notch while it plays
        RadioService.shared.resumeIfWanted()   // "Play the last station again when Scout opens" (on), only if it was playing as Scout quit
    }

    // MARK: Quick checks (SCOUT_SELFTEST=1; the full scenarios are `radio.selftest`)

    static func registerSelfTests() {
        FeaturesSelfTest.add("radio: broken and duplicate stations are dropped, good ones are read") {
            guard let all = try? RadioParser.stations(from: RadioFixtures.stationsData), all.stations.count == 16, all.dropped == 0 else { return false }
            guard let dirty = try? RadioParser.stations(from: RadioFixtures.dirtyData) else { return false }
            return dirty.stations.map(\.name) == ["Good One"] && dirty.dropped == 9
        }
        FeaturesSelfTest.add("radio: a place search is built as URLs for the directory (never sent)") {
            let q = RadioQuery(countryCode: "is", limit: 20)
            let url = RadioEndpoints.searchURL(q, host: "nl1.api.radio-browser.info").absoluteString
            return url == "https://nl1.api.radio-browser.info/json/stations/search?countrycode=IS&hidebroken=true&order=clickcount&reverse=true&limit=20"
        }
        FeaturesSelfTest.add("radio: a station's tile colour is stable") {
            RadioMonogram.initials("Aurora FM") == "AF" && RadioMonogram.initials("  ") == "♪"
        }
    }

    // MARK: Gallery

    /// A model on fakes, showing one state (nothing is searched or played).
    static func sampleModel(page: RadioModel.Page = .search, listNamed: String? = nil, query: String = "", country: RadioCountry? = nil, phase: RadioModel.Phase = .idle,
                            results: [RadioStation] = [], store: RadioStore? = nil, station: RadioStation? = nil,
                            state: RadioPlayState = .idle, song: String? = nil) -> RadioModel {
        let store = store ?? RadioFixtures.sampleStore()
        let service = RadioService(engine: RadioFakeEngine(), store: store)
        service.showSample(station: station, state: state, title: song)
        let model = RadioModel(service: service, searcher: RadioSearcher(directory: RadioFakeDirectory(), geocoder: RadioFakeGeocoder()))
        let shown = listNamed.flatMap { name in store.lists.first { $0.name == name }.map { RadioModel.Page.list($0.id) } } ?? page
        model.showSample(page: shown, query: query, country: country, phase: phase, results: results, countries: RadioFixtures.countries)
        return model
    }

    static func registerGallery() {
        let all = RadioFixtures.stations
        let greek = all.filter { $0.countryCode == "GR" }.sorted { $0.clickCount > $1.clickCount }
        let iceland = all.filter { $0.countryCode == "IS" }.sorted { $0.clickCount > $1.clickCount }
        let athens = greek.filter { $0.state == "Attica" }
        let greece = RadioFixtures.countries.first { $0.code == "GR" }
        let aurora = RadioFixtures.aurora, jazz = RadioFixtures.jazz, aegean = RadioFixtures.aegean

        func view(_ name: String, width: CGFloat = 900, height: CGFloat = 262, _ model: @escaping @MainActor () -> RadioModel) {
            FeatureGallery.workspace("radio-\(name)", width: width, height: height) { RadioWorkspaceView(model: model()) }
        }

        // Search
        view("search-idle") { sampleModel(station: jazz) }
        view("search-results") { sampleModel(query: "Athens", phase: .results, results: athens, station: jazz) }
        view("search-country") { sampleModel(country: greece, phase: .results, results: greek, station: aegean, state: .playing, song: "Marina Kallos - Summer Fire") }
        view("search-searching") { sampleModel(query: "Reykjavik", phase: .searching, station: nil) }
        view("search-empty") { sampleModel(query: "Tromsø", phase: .empty) }
        view("search-offline") { sampleModel(query: "Lisbon", phase: .offline) }
        view("search-error") { sampleModel(query: "Lisbon", phase: .failed) }
        view("search-narrow", width: 628) { sampleModel(query: "Reykjavik", phase: .results, results: iceland, station: aurora, state: .playing, song: "Cold Harbour - Northern Hours") }

        // Saved things
        view("latest") { sampleModel(page: .latest, station: jazz) }
        view("favourites") { sampleModel(page: .favourites, station: aurora, state: .playing) }
        view("list") { sampleModel(listNamed: "Morning", station: aurora, state: .playing, song: "Morning Light - The Early Birds") }
        view("list-empty") { sampleModel(listNamed: "Road trip", station: jazz) }
        view("latest-empty") { sampleModel(page: .latest, store: RadioStore(storage: RadioStorage(url: nil))) }
        view("favourites-empty") { sampleModel(page: .favourites, store: RadioStore(storage: RadioStorage(url: nil))) }

        // The player bar
        view("playing-song") { sampleModel(page: .favourites, station: aurora, state: .playing, song: "Cold Harbour - Northern Hours") }
        view("playing-no-song") { sampleModel(page: .favourites, station: aegean, state: .playing) }
        view("connecting") { sampleModel(page: .latest, station: jazz, state: .loading) }
        view("paused") { sampleModel(page: .latest, station: jazz, state: .paused, song: "Blue Room - The Quiet Quartet") }
        view("failed") { sampleModel(page: .latest, station: jazz, state: .failed("This station can't be played right now.")) }
        view("ready-after-relaunch") { sampleModel(page: .latest, station: jazz, state: .idle) }

        // The boombox on its own (close-ups of the player): playing with and without a song, paused, connecting, stopped, failed, a long name,
        // a Greek name (the system font), and a narrow tab.
        let shown = all.filter { $0.countryCode == "IS" }.sorted { $0.clickCount > $1.clickCount }
        let greekName = RadioStation(id: "gr-sample", name: "Ράδιο Αιγαίο", url: "https://stream.example.test/radio/gr", state: "Αττική", codec: "MP3", bitrate: 128)
        let longName = RadioStation(id: "long-sample", name: "Northern Lights Classical Music Hour", url: "https://stream.example.test/radio/long", country: "Iceland", codec: "AAC", bitrate: 96)
        func boombox(_ name: String, width: CGFloat = 872, station: RadioStation, state: RadioPlayState, song: String? = nil, list: [RadioStation]? = nil) -> some View {
            RadioBoomboxFace(station: station, state: state, song: song, volume: .constant(0.7), stationIDs: (list ?? shown).map(\.id), onToggle: {}, onStop: {})
                .frame(width: width)
        }
        func bar(_ name: String, width: CGFloat = 872, station: RadioStation, state: RadioPlayState, song: String? = nil, list: [RadioStation]? = nil) {
            FeatureGallery.workspace("radio-boombox-\(name)", width: width, height: 56) {
                boombox(name, width: width, station: station, state: state, song: song, list: list)
            }
        }
        bar("playing-song", station: aurora, state: .playing, song: "Cold Harbour - Northern Hours")
        bar("playing-no-song", station: aegean, state: .playing, list: greek)
        bar("paused", station: jazz, state: .paused, song: "Blue Room - The Quiet Quartet")
        bar("connecting", station: jazz, state: .loading)
        bar("stopped", station: jazz, state: .idle)
        bar("failed", station: jazz, state: .failed("This station can't be played right now."))
        bar("long-name", station: longName, state: .playing, song: "Symphony for a Frozen Harbour at Midnight (Live)", list: shown + [longName])
        bar("greek-name", station: greekName, state: .playing, song: "Μαρίνα Κάλλος - Καλοκαίρι", list: greek + [greekName])
        bar("narrow", width: 600, station: aurora, state: .playing, song: "Cold Harbour - Northern Hours")
        Gallery.register("radio-boombox-states", size: CGSize(width: 912, height: 6 * 70 + 24), backdrop: .window) {
            VStack(spacing: 14) {
                boombox("a", station: aurora, state: .playing, song: "Cold Harbour - Northern Hours")
                boombox("b", station: aegean, state: .playing, list: greek)
                boombox("c", station: jazz, state: .paused, song: "Blue Room - The Quiet Quartet")
                boombox("d", station: jazz, state: .loading)
                boombox("e", station: jazz, state: .idle)
                boombox("f", station: jazz, state: .failed("This station can't be played right now."))
            }
            .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color.black)
        }

        // The island with the Radio tab, at the height the tab asks for
        Gallery.register("radio-island", size: CGSize(width: 1120, height: 380)) {
            let _ = seedShared(station: aurora, state: .playing, song: "Cold Harbour - Northern Hours")
            NotchScene(size: CGSize(width: 1120, height: 380), open: true, workspace: .radio, openHeight: CGFloat(NotchPrefs.minimumOpenHeight(for: .radio)))
        }

        // The dashboard's live panel
        func live(_ station: RadioStation, _ state: RadioPlayState, _ song: String?) -> RadioLivePanel {
            let service = RadioService(engine: RadioFakeEngine(), store: RadioStore(storage: RadioStorage(url: nil)))
            service.showSample(station: station, state: state, title: song)
            return RadioLivePanel.live(service: service)
        }
        func add(_ name: String, cells: Int = 4, _ panels: @escaping @MainActor () -> [any LivePanelSource]) {
            Gallery.register("radio-live-\(name)", size: CGSize(width: CGFloat(cells) * NookMetrics.cell + 40, height: NookMetrics.widgetHeight + 40)) {
                LiveStage(panels: panels())
            }
        }
        add("song") { [live(aurora, .playing, "Cold Harbour - Northern Hours")] }
        add("no-song") { [live(aegean, .playing, nil)] }
        add("long-song") { [live(aurora, .playing, "The Northern Lights Orchestra - Symphony for a Frozen Harbour at Midnight (Live)")] }
        add("connecting") { [live(jazz, .loading, nil)] }
        add("paused") { [live(jazz, .paused, "Blue Room - The Quiet Quartet")] }
        // The mini deck at the two widths the dashboard gives it (4 cells, or 3 when the row is full), a Greek name, and every state.
        func deck(_ name: String, cells: Int, _ station: RadioStation, _ state: RadioPlayState, _ song: String?) -> some View {
            let panel = live(station, state, song)
            let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            return RadioLiveView(feed: panel.feed, actions: panel.actions)
                .frame(width: CGFloat(cells) * NookMetrics.cell, height: NookMetrics.widgetHeight)
                .background(shape.fill(Color.primary.opacity(0.075)))
                .clipShape(shape)
        }
        Gallery.register("radio-deck-states", size: CGSize(width: 4 * 200 + 5 * 16, height: 2 * (NookMetrics.widgetHeight + 16) + 16)) {
            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    deck("a", cells: 4, aurora, .playing, "Cold Harbour - Northern Hours")
                    deck("b", cells: 4, aegean, .playing, nil)
                    deck("c", cells: 4, jazz, .paused, "Blue Room - The Quiet Quartet")
                    deck("d", cells: 4, jazz, .loading, nil)
                }
                HStack(spacing: 16) {
                    deck("e", cells: 3, aurora, .playing, "Cold Harbour - Northern Hours")
                    deck("f", cells: 3, jazz, .paused, nil)
                    deck("g", cells: 4, greekName, .playing, "Μαρίνα Κάλλος - Καλοκαίρι")
                    deck("h", cells: 4, longName, .playing, "Symphony for a Frozen Harbour at Midnight (Live)")
                }
            }
            .padding(16).background(Color.black)
        }
        let rowWidth = 12 * NookMetrics.cell + 2 * NookMetrics.spacing + 40
        Gallery.register("radio-live-row", size: CGSize(width: rowWidth, height: NookMetrics.widgetHeight + 40)) {
            LiveStage(panels: [
                LiveSamples.meeting([LiveSamples.event("Weekly planning", start: Date().addingTimeInterval(11 * 60 + 40), length: 1800, link: LiveSamples.zoom)]),
                live(aurora, .playing, "Cold Harbour - Northern Hours"),
                LiveSamples.downloads(LiveDownloadsSnapshot(downloads: [LiveSamples.transfer("Scout-1.0.zip", fraction: 0.43)])),
            ])
        }
        // At the real open height (the smallest, 180 pt): the deck in the island's bottom-right corner with the same border right and down,
        // as the Agent TV has left and down (the owner, 2026-11-18).
        Gallery.register("radio-live-dashboard-tight", size: CGSize(width: DashGallery.wide, height: 280)) {
            let _ = DashGallery.seed(agents: 3, playing: false, live: [live(aurora, .playing, "Cold Harbour - Northern Hours")])
            NotchScene(size: CGSize(width: DashGallery.wide, height: 280), open: true, workspace: .nook,
                       live: NookLive(playing: false, openTodos: 0, agents: 3), openHeight: 180)
        }
        Gallery.register("radio-live-dashboard", size: CGSize(width: DashGallery.wide, height: 290)) {
            let _ = DashGallery.seed(agents: 3, playing: false, live: [live(aurora, .playing, "Cold Harbour - Northern Hours")])
            NotchScene(size: CGSize(width: DashGallery.wide, height: 290), open: true, workspace: .nook,
                       live: NookLive(playing: false, openTodos: 0, agents: 3), showNotchRect: true)
        }

        // Settings
        Gallery.register("radio-settings", size: CGSize(width: 640, height: 720), backdrop: .window) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsPageHeader(pane: .radio)
                    RadioSettingsPane(store: RadioFixtures.sampleStore())
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        Gallery.register("radio-settings-empty", size: CGSize(width: 640, height: 720), backdrop: .window) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsPageHeader(pane: .radio)
                    RadioSettingsPane(store: RadioStore(storage: RadioStorage(url: nil)))
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    /// The shared service and store, set to a state the island picture shows (scripted runs only: the engine is a fake).
    @discardableResult
    private static func seedShared(station: RadioStation, state: RadioPlayState, song: String?) -> Bool {
        guard ScoutRuntime.isScripted else { return false }
        let store = RadioStore.shared
        for s in RadioFixtures.sampleStore().favourites { if !store.isFavourite(s.id) { store.toggleFavourite(s) } }
        RadioService.shared.showSample(station: station, state: state, title: song)
        RadioModel.shared.showSample(page: .favourites, query: "", country: nil, phase: .idle, results: [], countries: RadioFixtures.countries)
        return true
    }
}
