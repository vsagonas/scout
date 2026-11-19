import AppKit
import Combine
import SwiftUI

// `radio.selftest?out=<file>`: Radio's scenarios on the fixture directory, the fake geocoder and the fake player. Nothing is
// played, nothing reaches the network, nothing shows on the screen. Run it headless, your own binary, stopped by pid:
//   build/Scout.app/Contents/MacOS/Scout --automation --headless --run "scout://radio.selftest?out=/path/radio.json" & PID=$!

private final class RadioBox<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

/// A model, a service, a store and a fake player wired together the way the app wires the real ones.
@MainActor
private final class RadioWorld {
    let engine = RadioFakeEngine()
    let directory = RadioFakeDirectory()
    let geocoder = RadioFakeGeocoder()
    let store: RadioStore
    let service: RadioService
    let model: RadioModel
    let searcher: RadioSearcher
    private let heard = RadioBox<[String]>([])
    var reported: [String] { heard.value }

    init(storage: RadioStorage = RadioStorage(url: nil), startTimeout: TimeInterval = 25) {
        store = RadioStore(storage: storage)
        let box = heard
        service = RadioService(engine: engine, store: store, report: { box.value.append($0.id) }, startTimeout: startTimeout)
        searcher = RadioSearcher(directory: directory, geocoder: geocoder)
        model = RadioModel(service: service, searcher: searcher, debounce: 0.02)
    }
}

/// The Radio view in an offscreen panel, clicked with real mouse events (the same way the dashboard tests click).
@MainActor
private final class RadioViewRig {
    let size = CGSize(width: 900, height: 262)
    let panel: NotchPanel
    let hosting: NSHostingView<RadioWorkspaceView>

    init(model: RadioModel) {
        panel = NotchPanel(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.navigatorOverride = NotchNavigator()
        hosting = NSHostingView(rootView: RadioWorkspaceView(model: model))
        hosting.frame = CGRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.orderFrontRegardless()
    }

    private func post(_ type: NSEvent.EventType, _ p: CGPoint) {
        let location = CGPoint(x: p.x, y: size.height - p.y)
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                             pressure: type == .leftMouseUp ? 0 : 1) else { return }
        panel.sendEvent(event)
    }

    func click(_ p: CGPoint) async {
        post(.leftMouseDown, p)
        post(.leftMouseUp, p)
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    /// The middle of a boombox control by name ("play", "stop", "volume"), in the view's top-left coordinates; nil when it is not there.
    func button(_ name: String, in model: RadioModel) -> CGPoint? {
        guard let r = model.controlRects[name] else { return nil }
        return CGPoint(x: r.midX, y: r.midY)
    }

    func snapshot(to url: URL) {
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    func close() {
        panel.contentView = nil
        panel.orderOut(nil)
    }
}

@MainActor
enum RadioSelfTest {
    static func register() {
        DebugCommands.register("radio.selftest") { params in
            guard ScoutRuntime.isAutomation else { return }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("radio-selftest.json")
            Task { @MainActor in
                let json = await SelfTestGate.shared.exclusive { await run() }   // alone: it flips the look and writes the volume, so no other test may run beside it
                try? json.write(to: out, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func wait(_ ms: Double = 40) async { try? await Task.sleep(nanoseconds: UInt64(ms * 1_000_000)) }

    static func run() async -> String {
        // What the scenarios write into the settings domain (the look, the volume, the start-again switch): cleared so the app's own defaults
        // apply whatever an earlier run left, and put back exactly as they were when this one is done.
        let borrowed = SelfTestSettings(clearing: [Retro.styleKey, RadioService.volumeKey, RadioService.resumeKey, RadioService.wasPlayingKey, RadioService.sleepKey, RadioPrefs.showSongKey, LiveActivityKind.radio.enabledKey])
        defer { borrowed.restore() }
        var results: [[String: Any]] = []
        func note(_ name: String, _ checks: [(String, Bool)]) {
            let problems = checks.filter { !$0.1 }.map { "failed: \($0.0)" }
            results.append(["scenario": name, "pass": problems.isEmpty, "problems": problems])
        }
        let all = RadioFixtures.stations
        let aurora = RadioFixtures.aurora, jazz = RadioFixtures.jazz
        let countries = RadioFixtures.countries

        // 1. Parsing: what the directory sends.
        let good = try? RadioParser.stations(from: RadioFixtures.stationsData)
        let quiet = good?.stations.first { $0.name == "Quiet Hours" }
        note("parsing: the directory's answer", [
            ("sixteen good stations, none dropped", good?.stations.count == 16 && good?.dropped == 0),
            ("place, quality and genres", aurora.place == "Capital Region, Iceland" && aurora.quality == "MP3 128k" && aurora.genreLine == "Pop · Hits · News"),
            ("the resolved address is the one played", aurora.url == "https://stream.example.test/radio/1" && aurora.streamURL != nil),
            ("coordinates and listeners read", aurora.latitude == 64.1466 && aurora.longitude == -21.9426 && aurora.clickCount == 480),
            ("no codec and no bitrate: no quality line", quiet?.quality == ""),
            ("an empty array is fine, an object is not", (try? RadioParser.stations(from: Data("[]".utf8)))?.stations.isEmpty == true
                && (try? RadioParser.stations(from: Data("{}".utf8))) == nil),
        ])
        let dirty = try? RadioParser.stations(from: RadioFixtures.dirtyData)
        note("parsing: broken and duplicate stations are dropped", [
            ("only the good one stays (no address, ftp, checked broken, Ogg, empty name, repeated id, address and name all gone)", dirty?.stations.map(\.name) == ["Good One"]),
            ("nine rows dropped (one was not even an object)", dirty?.dropped == 9),
            ("Ogg and Opus cannot be played on the Mac", !RadioParser.isPlayableOnMac(codec: "OGG", url: "https://a.test/s") && !RadioParser.isPlayableOnMac(codec: "", url: "https://a.test/s.opus")
                && RadioParser.isPlayableOnMac(codec: "AAC+", url: "https://a.test/s")),
        ])
        let merged = RadioParser.merge([[all[3], all[0]], [all[0], all[1]]], limit: 10)
        note("parsing: several answers merge once, most listened first", [
            ("no repeats", merged.map(\.id).count == Set(merged.map(\.id)).count && merged.count == 3),
            ("most listened first", merged.map(\.clickCount) == merged.map(\.clickCount).sorted(by: >)),
            ("limit", RadioParser.merge([all], limit: 5).count == 5),
        ])
        note("parsing: countries", [
            ("six, by name", countries.count == 6 && countries.first?.name == "France"),
            ("a name, a code and 'The' all match", RadioPlan.country(named: "iceland ", in: countries)?.code == "IS" && RadioPlan.country(named: "IS", in: countries)?.code == "IS"
                && RadioPlan.country(named: "Netherlands", in: countries)?.code == "NL"),
            ("a town is not a country", RadioPlan.country(named: "Athens", in: countries) == nil && RadioPlan.country(named: "", in: countries) == nil),
        ])

        // 2. The requests, checked as URLs and never sent.
        let host = "de1.api.radio-browser.info"
        let base = "https://\(host)/json/stations/search?"
        let tail = "hidebroken=true&order=clickcount&reverse=true"
        note("requests: URLs for the directory (never sent)", [
            ("hosts and fallbacks", RadioEndpoints.hosts == [host, "nl1.api.radio-browser.info", "at1.api.radio-browser.info"]),
            ("a country", RadioEndpoints.searchURL(RadioQuery(countryCode: "is")).absoluteString == base + "countrycode=IS&\(tail)&limit=100"),
            ("a place around coordinates", RadioEndpoints.searchURL(RadioQuery(geo: RadioGeoFilter(latitude: 64.1466, longitude: -21.9426, distance: 30000), limit: 60)).absoluteString
                == base + "geo_lat=64.1466&geo_long=-21.9426&geo_distance=30000&\(tail)&limit=60"),
            ("a state and a name", RadioEndpoints.searchURL(RadioQuery(name: "Saint Louis", state: "Missouri")).absoluteString == base + "name=Saint%20Louis&state=Missouri&\(tail)&limit=100"),
            ("& + / = and accents stay inside the value", RadioEndpoints.searchURL(RadioQuery(name: "AC/DC & Co+x=1")).absoluteString.contains("name=AC%2FDC%20%26%20Co%2Bx%3D1&")
                && RadioEndpoints.searchURL(RadioQuery(state: "Tromsø")).absoluteString.contains("state=Troms%C3%B8&")),
            ("a fallback host", RadioEndpoints.searchURL(RadioQuery(countryCode: "GR"), host: "at1.api.radio-browser.info").absoluteString.hasPrefix("https://at1.api.radio-browser.info/json/stations/search?")),
            ("the countries", RadioEndpoints.countriesURL().absoluteString == "https://\(host)/json/countries?hidebroken=true&order=name"),
            ("one GET when a station starts", RadioEndpoints.playURL(stationID: aurora.id).absoluteString == "https://\(host)/json/url/\(aurora.id)"),
            ("a descriptive User-Agent", RadioEndpoints.userAgent.hasPrefix("Scout/") && RadioEndpoints.userAgent.count > 6),
        ])
        let reykjavik = RadioFixtures.places["reykjavik"]!
        let athensPlace = RadioFixtures.places["athens"]!
        let single = RadioPlan.queries(text: "Reykjavik", restriction: nil, matched: nil, geo: reykjavik)
        let cityRegion = RadioPlan.queries(text: "Athens, Attica", restriction: nil, matched: nil, geo: athensPlace)
        let noGeo = RadioPlan.queries(text: "Athens, Attica", restriction: nil, matched: nil, geo: nil)
        let byCountry = RadioPlan.queries(text: "Iceland", restriction: nil, matched: countries.first { $0.code == "IS" }, geo: nil)
        let restricted = RadioPlan.queries(text: "Athens", restriction: "GR", matched: nil, geo: athensPlace)
        let wholeCountry = RadioPlan.queries(text: "Portugal", restriction: nil, matched: nil,
                                             geo: RadioGeoPlace(name: "Portugal", latitude: 39.5, longitude: -8, radius: 400_000, countryCode: "PT", countryOnly: true))
        note("requests: a typed place becomes these searches", [
            ("one word with a geocode: around the place, by name, by state", single.count == 3 && single[0].geo?.distance == 30000 && single[1].name == "Reykjavik" && single[2].state == "Reykjavik"),
            ("city and region with a geocode: around the place and by the city, no state", cityRegion.count == 2 && cityRegion[0].geo != nil && cityRegion[1].name == "Athens"),
            ("no geocode: both states and the name", noGeo.count == 3 && noGeo[0].state == "Athens" && noGeo[1].state == "Attica" && noGeo[2].name == "Athens"),
            ("a country by name: that country, nothing else", byCountry.count == 1 && byCountry[0].countryCode == "IS" && byCountry[0].name == nil && byCountry[0].state == nil && byCountry[0].geo == nil),
            ("a picked country keeps every search inside it", restricted.count == 3 && restricted.allSatisfy { $0.countryCode == "GR" }),
            ("a geocode that is a whole country: that country", wholeCountry.count == 1 && wholeCountry[0].countryCode == "PT" && wholeCountry[0].geo == nil),
            ("the radius is the size of the place, between 20 and 100 km", RadioPlan.distance(for: RadioGeoPlace(name: "a", latitude: 0, longitude: 0, radius: 5_000)) == 20_000
                && RadioPlan.distance(for: RadioGeoPlace(name: "a", latitude: 0, longitude: 0, radius: 150_000)) == 100_000
                && RadioPlan.distance(for: RadioGeoPlace(name: "a", latitude: 0, longitude: 0, radius: 40_000)) == 40_000),
            ("nothing typed, nothing asked", RadioPlan.queries(text: "  , ", restriction: nil, matched: nil, geo: nil).isEmpty),
        ])

        // 3. The place search on the fixture directory.
        do {
            let w = RadioWorld()
            func ask(_ text: String, _ country: RadioCountry? = nil) async -> RadioSearchResult? {
                try? await w.searcher.search(text: text, country: country, countries: countries)
            }
            let athens = await ask("Athens")
            let before = w.directory.queries.count
            let reykjavikFound = await ask("Reykjavik")
            let iceland = await ask("Iceland")
            let asked = w.geocoder.asked
            let region = await ask("Capital Region")
            let nowhere = await ask("Nowhere")
            let lisbon = await ask("Lisbon")
            let greece = countries.first { $0.code == "GR" }
            let pickedOnly = await ask("", greece)
            let pickedAthens = await ask("Athens", greece)
            let none = await ask("   ")
            w.directory.failure = .offline
            var offlineError: RadioSearchError?
            do { _ = try await w.searcher.search(text: "Athens", country: nil, countries: countries) } catch { offlineError = error as? RadioSearchError }
            w.directory.failure = .unavailable
            var downError: RadioSearchError?
            do { _ = try await w.searcher.search(text: "Athens", country: nil, countries: countries) } catch { downError = error as? RadioSearchError }
            note("place search: a typed place gives the stations there, most listened first", [
                ("Athens: the three around it, by listeners", athens?.stations.map(\.name) == ["Aegean Breeze", "Plaka Sunset", "Acropolis Classics"]),
                ("Athens: three searches, place named by the geocoder", athens?.queries.count == 3 && athens?.placeName == "Athens" && before == 3),
                ("Reykjavik: the capital's stations", reykjavikFound?.stations.map(\.name) == ["Aurora FM", "Harbour Jazz", "Quiet Hours"]),
                ("a country by name needs one search and no geocoder", iceland?.stations.count == 5 && iceland?.queries.count == 1 && asked == ["Athens", "Reykjavik"]),
                ("a region the geocoder does not know still finds its stations by the directory's own state field", region?.stations.map(\.name) == ["Aurora FM", "Harbour Jazz", "Quiet Hours"]),
                ("a place with no stations is an empty list, not an error", nowhere?.stations.isEmpty == true),
                ("a station found by several searches is listed once", lisbon?.stations.map(\.name) == ["Lisbon Morning Show", "Tagus Late Nights"]),
                ("a picked country alone: its stations", pickedOnly?.stations.count == 4 && pickedOnly?.queries.first?.countryCode == "GR"),
                ("a picked country with a place: inside the country", pickedAthens?.stations.count == 3 && pickedAthens?.queries.allSatisfy { $0.countryCode == "GR" } == true),
                ("nothing typed and no country: nothing asked", none?.stations.isEmpty == true && none?.queries.isEmpty == true),
                ("offline is told as offline, a silent directory as unavailable", offlineError == .offline && downError == .unavailable),
                ("each calm line is one line", RadioSearchError.offline.message.count < 70 && !RadioSearchError.unavailable.message.contains("\n")),
            ])
        }

        // 4. The model: typing, Return, countries, saved places, the states.
        do {
            let w = RadioWorld()
            w.model.loadCountries()
            await wait(60)
            for text in ["L", "Li", "Lis", "Lisb", "Lisbon"] { w.model.query = text; w.model.queryChanged() }
            await w.model.settle()
            let queriesAfterTyping = w.directory.queries.count
            let typed = (w.model.phase, w.model.results.count, w.store.places.first?.text)

            w.model.query = "Nowhere"
            w.model.submit()
            await w.model.settle()
            let emptyPhase = w.model.phase, emptyPlaces = w.store.places.map(\.text)

            w.directory.failure = .offline
            w.model.query = "Athens"
            w.model.submit()
            await w.model.settle()
            let offlinePhase = (w.model.phase, w.model.results.count)
            w.directory.failure = .unavailable
            w.model.submit()
            await w.model.settle()
            let failedPhase = w.model.phase
            w.directory.failure = nil
            w.model.submit()
            await w.model.settle()
            let retried = (w.model.phase, w.model.results.count, w.store.places.map(\.text))

            w.model.query = ""
            w.model.pickCountry(w.model.countries.first { $0.code == "GR" })
            await w.model.settle()
            let picked = (w.model.phase, w.model.results.count, w.store.places.first)

            w.model.pickCountry(nil)
            w.model.searchPlace(RadioPlace(text: "Lisbon", countryCode: nil, date: Date()))
            await w.model.settle()
            let again = (w.model.page, w.model.query, w.model.country?.code, w.model.results.count)
            w.model.searchPlace(RadioPlace(text: "Greece", countryCode: "GR", date: Date()))
            await w.model.settle()
            let againCountry = (w.model.query, w.model.country?.code, w.model.results.count)

            w.model.query = ""
            w.model.pickCountry(nil)
            w.model.queryChanged()
            await w.model.settle()
            note("model: typing, Return, countries and places", [
                ("typing five letters quickly searches once (three requests)", queriesAfterTyping == 3 && typed.0 == .results && typed.1 == 2),
                ("a place that found stations is remembered", typed.2 == "Lisbon"),
                ("no stations: calm 'empty' state, place not remembered", emptyPhase == .empty && !emptyPlaces.contains("Nowhere")),
                ("offline and unreachable are different states, with no results shown", offlinePhase.0 == .offline && offlinePhase.1 == 0 && failedPhase == .failed),
                ("asking again after a failure searches again", retried.0 == .results && retried.1 == 3 && retried.2.first == "Athens"),
                ("a picked country browses it and is remembered as a country", picked.0 == .results && picked.1 == 4 && picked.2?.countryCode == "GR" && picked.2?.text == "Greece"),
                ("one click on a saved place searches it again", again.0 == .search && again.1 == "Lisbon" && again.2 == nil && again.3 == 2),
                ("one click on a saved country picks it", againCountry.0 == "" && againCountry.1 == "GR" && againCountry.2 == 4),
                ("clearing the field goes back to the start", w.model.phase == .idle && w.model.results.isEmpty),
                ("places are kept to ten, newest first, once each", w.store.places.count <= RadioLimits.places && Set(w.store.places.map(\.id)).count == w.store.places.count),
            ])
        }

        // 5. Playing: play, pause, resume, stop, switch.
        do {
            let w = RadioWorld()
            let a = aurora, b = jazz
            w.service.play(a)
            let started = (w.service.state, w.engine.played, w.store.latest.map(\.id), w.store.last?.id, w.service.station?.id, w.reported)
            w.engine.emit(.playing)
            await wait()
            let playing = (w.service.state, w.reported)
            w.engine.emit(.playing)
            w.engine.emit(.buffering)
            await wait()
            let buffering = w.service.state
            w.engine.emit(.playing)
            await wait()
            let afterBuffer = (w.service.state, w.reported)

            w.engine.emit(.title("Cold Harbour - Northern Hours"))
            await wait()
            let song = w.service.songTitle
            w.engine.emit(.title("Line one\nLine two"))
            await wait()
            let twoLines = w.service.songTitle
            w.engine.emit(.title(a.name))
            await wait()
            let sameAsName = w.service.songTitle
            w.engine.emit(.title("  "))
            await wait()
            let blank = w.service.songTitle

            w.service.pause()
            w.engine.emit(.paused)
            await wait()
            let paused = (w.service.state, w.engine.pauses)
            w.service.resume()
            let resumed = (w.service.state, w.engine.resumes)
            w.engine.emit(.playing)
            await wait()
            let resumedPlaying = (w.service.state, w.reported)

            w.service.play(b)
            let switched = (w.service.station?.id, w.service.state, w.engine.played.count, w.store.latest.map(\.id), w.service.songTitle, w.store.last?.id)
            w.engine.emit(.playing)
            await wait()
            let secondReported = w.reported

            w.model.tap(b)   // the playing one: pause
            let tapPause = w.service.state
            w.model.tap(b)   // the paused one: go on
            let tapResume = (w.service.state, w.engine.resumes, w.engine.played.count)
            w.engine.emit(.playing)
            await wait()
            w.model.tap(a)   // another one: it plays, the first stops being the station
            let tapOther = (w.service.station?.id, w.engine.played.count)

            let stopsBefore = w.engine.stops
            w.service.stop()
            let stopped = (w.service.state, w.service.station?.id, w.service.songTitle, w.engine.stops - stopsBefore)
            w.service.togglePause()   // the person asks again
            let again = (w.service.state, w.engine.played.count)

            UserDefaults.standard.removeObject(forKey: RadioService.volumeKey)
            w.service.setVolume(0.3)
            let volume = (w.engine.volume, UserDefaults.standard.double(forKey: RadioService.volumeKey))
            w.service.setVolume(1.7)
            let high = w.service.volume
            w.service.setVolume(-1)
            let low = w.service.volume
            UserDefaults.standard.removeObject(forKey: RadioService.volumeKey)

            note("playing: play, pause, resume, stop, switch station", [
                ("play: connecting, the address handed to the player once, latest and last saved", started.0 == .loading && started.1 == [a.streamURL!] && started.2 == [a.id] && started.3 == a.id && started.4 == a.id),
                ("the directory hears of a listen only when it starts, once", started.5.isEmpty && playing.0 == .playing && playing.1 == [a.id]),
                ("a stall shows connecting, then playing again, with no second listen", buffering == .loading && afterBuffer.0 == .playing && afterBuffer.1 == [a.id]),
                ("the song from the stream shows; two lines become one", song == "Cold Harbour - Northern Hours" && twoLines == "Line one Line two"),
                ("a title that is only the station's name, or blank, is not a song", sameAsName == nil && blank == nil),
                ("pause: the player pauses, state paused", paused.0 == .paused && paused.1 == 1),
                ("resume: connecting, then playing, no new listen", resumed.0 == .loading && resumed.1 == 1 && resumedPlaying.0 == .playing && resumedPlaying.1 == [a.id]),
                ("switch: one station at a time, the new one first in latest and last", switched.0 == b.id && switched.1 == .loading && switched.2 == 2 && switched.3 == [b.id, a.id] && switched.4 == nil && switched.5 == b.id),
                ("the second station is heard of once it plays", secondReported == [a.id, b.id]),
                ("a click on the playing station pauses, then resumes", tapPause == .paused && tapResume.0 == .loading && tapResume.1 == 2 && tapResume.2 == 2),
                ("a click on another station plays that one", tapOther.0 == a.id && tapOther.1 == 3),
                ("stop: the station stays shown, the song goes, the player stops once", stopped.0 == .idle && stopped.1 == a.id && stopped.2 == nil && stopped.3 == 1),
                ("play after stop is the person's own new start", again.0 == .loading && again.1 == 4),
                ("volume goes to the player and is remembered; it stays between 0 and 1", volume.0 == 0.3 && volume.1 == 0.3 && high == 1 && low == 0),
            ])
        }

        // 5b. The system pauses the sound (not the person): it shows as paused and can be resumed.
        do {
            let w = RadioWorld()
            w.service.play(jazz)
            w.engine.emit(.playing)
            await wait()
            w.engine.emit(.paused)
            await wait()
            let system = (w.service.state, w.engine.pauses)
            w.service.resume()
            w.engine.emit(.playing)
            await wait()
            note("playing: a pause that did not come from the person", [
                ("the state follows the sound: paused, and not a failure", system.0 == .paused && system.1 == 0),
                ("resume then plays again", w.service.state == .playing && w.engine.resumes == 1 && w.engine.played.count == 1),
            ])
        }

        // 6. A failing stream stops, says so, and never retries.
        do {
            let w = RadioWorld()
            w.service.play(aurora)
            w.engine.emit(.playing)
            await wait()
            w.engine.emit(.failed("This station can't be played right now."))
            await wait()
            let failed = (w.service.state, w.engine.stops, w.engine.played.count)
            await wait(300)
            let later = (w.service.state, w.engine.played.count)
            w.engine.emit(.playing)
            w.engine.emit(.title("Late song"))
            await wait()
            let lateEvents = (w.service.state, w.service.songTitle)
            w.service.togglePause()
            let retry = (w.service.state, w.engine.played.count)

            let e = RadioWorld()
            e.service.play(jazz)
            e.engine.emit(.playing)
            await wait()
            e.engine.emit(.ended)
            await wait()
            let ended = (e.service.state, e.engine.played.count)

            let t = RadioWorld(startTimeout: 0.06)
            t.service.play(jazz)
            await wait(300)
            let silent = (t.service.state, t.engine.played.count, t.engine.stops)

            let s = RadioWorld(startTimeout: 0.1)
            s.service.play(jazz)
            s.engine.emit(.playing)
            await wait(30)
            s.engine.emit(.buffering)
            await wait(300)
            let stalled = (s.service.state, s.engine.played.count)

            let k = RadioWorld(startTimeout: 0.12)
            k.service.play(jazz)
            k.engine.emit(.playing)
            await wait(300)
            let kept = k.service.state
            let c = RadioWorld(startTimeout: 0.06)
            c.service.play(jazz)
            c.service.stop()
            await wait(250)
            let cancelled = c.service.state
            note("a failing stream stops, says so, and does not retry", [
                ("failed: the line is kept, the player stopped, nothing played again", failed.0 == .failed("This station can't be played right now.") && failed.1 >= 1 && failed.2 == 1),
                ("a third of a second later still failed, still one start", later.0 == failed.0 && later.1 == 1),
                ("late events from the dead stream change nothing", lateEvents.0 == failed.0 && lateEvents.1 == nil),
                ("only the person's own play starts it again", retry.0 == .loading && retry.1 == 2),
                ("a stream that ends is a stop with a line, no replay", ended.0 == .failed("The station stopped broadcasting.") && ended.1 == 1),
                ("a station that never answers gives up once", silent.0 == .failed("This station isn't answering.") && silent.1 == 1 && silent.2 >= 1),
                ("a stream that stalls and never comes back gives up once", stalled.0 == .failed("This station isn't answering.") && stalled.1 == 1),
                ("a stream that did start is not timed out", kept == .playing),
                ("stopping cancels the wait", cancelled == .idle),
            ])
        }

        // 7. Saved things come back after a relaunch.
        let file = AppPaths.file("radio-selftest.json")
        try? FileManager.default.removeItem(at: file)
        let first = RadioStore(storage: RadioStorage(url: file))
        func synthetic(_ i: Int) -> RadioStation { RadioStation(id: "syn-\(i)", name: "Synthetic \(i)", url: "https://stream.example.test/syn/\(i)", country: "Testland", countryCode: "TL") }
        for i in 0..<25 { first.recordPlayed(synthetic(i)) }
        first.recordPlayed(synthetic(24))
        first.recordPlayed(aurora)
        first.recordPlayed(synthetic(10))
        for i in 0..<12 { first.recordPlace(text: "Place \(i)", countryCode: i == 11 ? "GR" : nil, date: Date(timeIntervalSince1970: 1_800_000_000 + Double(i))) }
        first.recordPlace(text: "place 5", date: Date(timeIntervalSince1970: 1_800_000_100))
        first.toggleFavourite(jazz)
        first.toggleFavourite(aurora)
        first.toggleFavourite(synthetic(3))
        first.toggleFavourite(synthetic(3))
        let morning = first.createList(named: "Morning")
        let focus = first.createList(named: "Focus")
        first.add(aurora, toList: morning.id)
        first.add(jazz, toList: morning.id)
        first.add(synthetic(1), toList: focus.id)
        first.move(jazz.id, inList: morning.id, by: -1)
        let again = RadioStore(storage: RadioStorage(url: file))
        note("saved things: latest, places, favourites and lists come back after a relaunch", [
            ("everything is equal after reading the file again", again.saved == first.saved),
            ("latest: at most 20, newest first, each once", again.latest.count == 20 && again.latest.first?.id == "syn-10" && again.latest.map(\.id).count == Set(again.latest.map(\.id)).count
                && again.latest[1].id == aurora.id && !again.latest.contains { $0.id == "syn-0" }),
            ("latest: the six oldest fell off", !again.latest.contains { $0.id == "syn-5" } && again.latest.contains { $0.id == "syn-6" }),
            ("places: at most ten, newest first, a place typed again moves up", again.places.count == 10 && again.places.first?.text == "place 5" && again.places[1].text == "Place 11" && again.places[1].countryCode == "GR"),
            ("favourites: newest first, the toggled-off one gone", again.favourites.map(\.id) == [aurora.id, jazz.id]),
            ("lists: names, stations and order", again.lists.map(\.name) == ["Morning", "Focus"] && again.lists[0].stations.map(\.id) == [jazz.id, aurora.id] && again.lists[1].stations.map(\.id) == ["syn-1"]),
            ("the last station is the last one played", again.last?.id == "syn-10"),
        ])
        again.clearHistory()
        let cleared = RadioStore(storage: RadioStorage(url: file))
        try? "not json".write(to: file, atomically: true, encoding: .utf8)
        let broken = RadioStore(storage: RadioStorage(url: file))
        let old = #"{"favourites":[{"id":"old-1","name":"Old Station","url":"https://stream.example.test/old"}],"lists":[],"latest":[],"places":[]}"#
        try? old.write(to: file, atomically: true, encoding: .utf8)
        let older = RadioStore(storage: RadioStorage(url: file))
        try? FileManager.default.removeItem(at: file)
        note("saved things: clearing, damaged and older files", [
            ("'Clear latest stations and places' keeps favourites, lists and the last station, and the file says so", cleared.latest.isEmpty && cleared.places.isEmpty && cleared.favourites.count == 2 && cleared.lists.count == 2 && cleared.last != nil && !cleared.hasHistory),
            ("a damaged file gives an empty start, not a crash", broken.saved == RadioSaved()),
            ("a station saved with fewer fields still loads", older.favourites.first?.name == "Old Station" && older.favourites.first?.tags == [] && older.favourites.first?.bitrate == 0),
        ])

        // 8. List edits.
        do {
            let w = RadioWorld()
            let s = w.store
            let a = all[0], b = all[1], c = all[2]
            let l1 = s.createList(), l2 = s.createList(), l3 = s.createList(named: " Focus "), l4 = s.createList(named: "focus")
            s.renameList(l1.id, to: "Morning")
            s.renameList(l2.id, to: "morning")
            s.renameList(l2.id, to: "   ")
            s.renameList(UUID(), to: "Ghost")
            let renamed = (s.list(l1.id)?.name, s.list(l2.id)?.name, s.lists.count)
            for st in [a, b, c, a] { s.add(st, toList: l1.id) }
            let added = s.list(l1.id)?.stations.map(\.id)
            s.move(b.id, inList: l1.id, by: -1)
            let up = s.list(l1.id)?.stations.map(\.id)
            s.move(b.id, inList: l1.id, by: -1)
            let top = s.list(l1.id)?.stations.map(\.id)
            s.move(a.id, inList: l1.id, by: 1)
            let down = s.list(l1.id)?.stations.map(\.id)
            s.move(b.id, inList: l1.id, by: 5)
            let clamped = s.list(l1.id)?.stations.map(\.id)
            s.remove(a.id, fromList: l1.id)
            s.remove("nothing", fromList: l1.id)
            let removed = s.list(l1.id)?.stations.map(\.id)
            s.add(b, toList: l2.id)
            let containing = s.listsContaining(b.id)
            s.moveList(l3.id, by: -2)
            let order1 = s.lists.map(\.name)
            s.moveList(l3.id, by: -5)
            let order2 = s.lists.map(\.name)
            s.moveList(l3.id, by: 1)
            let order3 = s.lists.map(\.id)
            let order3Names = s.lists.map(\.name)

            w.model.page = .list(l2.id)
            w.model.deleteList(l2.id)
            let afterDelete = (w.model.page, w.model.shownPage, s.list(l2.id) == nil)
            w.model.page = .list(l1.id)
            s.deleteList(l1.id)
            let shownAfterDirectDelete = w.model.shownPage
            w.model.newList(adding: a)
            let fresh = s.lists.last
            let freshState = (w.model.page == .list(fresh?.id ?? UUID()), w.model.renaming == fresh?.id, fresh?.stations.map(\.id) == [a.id])
            if let fresh { w.model.commitRename(fresh.id, name: "Road trip") }
            s.toggleFavourite(b)
            s.toggleFavourite(a)
            let favs = s.favourites.map(\.id)
            s.toggleFavourite(b)
            note("list edits: create, rename, add, remove, reorder, delete", [
                ("names stay unique ('New list', 'New list 2', 'Focus', 'focus 2')", [l1.name, l2.name, l3.name, l4.name] == ["New list", "New list 2", "Focus", "focus 2"]),
                ("rename works; a used name, a blank one and an unknown list are ignored", renamed.0 == "Morning" && renamed.1 == "New list 2" && renamed.2 == 4),
                ("adding puts it last, once", added == [a.id, b.id, c.id]),
                ("move up and down, and stop at the ends", up == [b.id, a.id, c.id] && top == up && down == [b.id, c.id, a.id] && clamped == [c.id, a.id, b.id]),
                ("remove; removing what is not there does nothing", removed == [c.id, b.id]),
                ("a station knows which lists hold it", containing == [l1.id, l2.id]),
                ("lists reorder and stop at the ends", order1.first == "Focus" && order2.first == "Focus" && order3[1] == l3.id && order3Names == ["Morning", "Focus", "New list 2", "focus 2"]),
                ("deleting a list that is shown falls back to Search", afterDelete.0 == .search && afterDelete.1 == .search && afterDelete.2 && shownAfterDirectDelete == .search),
                ("a new list made from a station opens, is named, and holds it", freshState.0 && freshState.1 && freshState.2 && s.lists.last?.name == "Road trip" && w.model.renaming == nil),
                ("favourites: newest first, a second tap removes", favs == [a.id, b.id] && !s.isFavourite(b.id)),
            ])
        }

        // 9. The live panel is live only while a station plays.
        do {
            let w = RadioWorld()
            let panel = RadioLivePanel.live(service: w.service)
            let panels = LivePanels(sources: [panel], heartbeat: false)
            func live() -> [String] { panels.live.map(\.id) }
            let idle = live()
            w.service.play(aurora)
            await wait()
            let connecting = live()
            w.engine.emit(.playing)
            await wait()
            let playing = (live(), panels.publishCount)
            w.engine.emit(.title("Cold Harbour - Northern Hours"))
            await wait()
            w.engine.emit(.title("Another Song - Someone"))
            await wait()
            let songs = (live(), panels.publishCount, panel.feed.value.song, panel.feed.value.station)
            panel.actions.togglePause()
            await wait()
            let paused = (live(), panel.feed.value.state)
            panel.actions.togglePause()
            await wait()
            w.engine.emit(.playing)
            await wait()
            let back = (live(), panel.feed.value.state)
            panel.actions.stop()
            await wait()
            let stopped = (live(), w.service.state, w.service.station?.id)
            w.service.play(jazz)
            await wait()
            w.engine.emit(.failed("This station can't be played right now."))
            await wait()
            let failed = live()
            note("live panel: live.radio shows only while a station plays", [
                ("nothing playing: not live", idle.isEmpty),
                ("connecting counts (the station was chosen)", connecting == ["live.radio"]),
                ("playing: live", playing.0 == ["live.radio"]),
                ("a new song updates the panel without republishing the dashboard", songs.0 == ["live.radio"] && songs.1 == playing.1 && songs.2 == "Another Song - Someone" && songs.3 == aurora.name),
                ("paused: still there, so it can be resumed", paused.0 == ["live.radio"] && paused.1 == .paused),
                ("resumed: playing again", back.0 == ["live.radio"] && back.1 == .playing),
                ("stop: gone from the dashboard, the station stays in the tab", stopped.0.isEmpty && stopped.1 == .idle && stopped.2 == aurora.id),
                ("a failed stream: gone", failed.isEmpty),
                ("a click opens the Radio tab; the panel sits among the others", panel.expandTo == .radio && panel.id == "live.radio" && panel.title == "Radio" && panel.span == 4),
            ])
            panels.stop()
        }

        // 10. After a relaunch: the last station and the volume are back. "Play the last station again when Scout opens" is ON by default
        //     (the owner, 2026-11-18) and plays it only when it was still playing as Scout quit; a radio the person stopped stays stopped.
        do {
            let file = AppPaths.file("radio-selftest-relaunch.json")
            try? FileManager.default.removeItem(at: file)
            for key in [RadioService.resumeKey, RadioService.volumeKey, RadioService.wasPlayingKey] { UserDefaults.standard.removeObject(forKey: key) }
            let w = RadioWorld(storage: RadioStorage(url: file))
            w.service.play(aurora)
            w.engine.emit(.playing)
            await wait()
            w.service.setVolume(0.35)
            // Scout quits while it plays (no stop).

            let engine2 = RadioFakeEngine()
            let service2 = RadioService(engine: engine2, store: RadioStore(storage: RadioStorage(url: file)))
            let panel2 = RadioLivePanel.live(service: service2)
            let panels2 = LivePanels(sources: [panel2], heartbeat: false)
            let ready = (service2.station?.id, service2.state, engine2.played.count, engine2.stops, panels2.live.map(\.id), engine2.volume)
            let defaultOn = RadioService.resumeOnLaunch
            service2.resumeIfWanted()   // this run is scripted: nothing starts
            let scripted = (service2.state, engine2.played.count)
            service2.resumeIfWanted(scripted: false)
            let resumed = (service2.state, engine2.played.map(\.absoluteString))
            // The person stops it, then Scout quits: next time nothing plays.
            service2.stop()
            let engine4 = RadioFakeEngine()
            let service4 = RadioService(engine: engine4, store: RadioStore(storage: RadioStorage(url: file)))
            service4.resumeIfWanted(scripted: false)
            let stoppedStays = (service4.state, engine4.played.count, RadioService.resumeOnLaunch)
            // The switch off: even a radio that was playing stays quiet.
            UserDefaults.standard.set(true, forKey: RadioService.wasPlayingKey)
            UserDefaults.standard.set(false, forKey: RadioService.resumeKey)
            let engine5 = RadioFakeEngine()
            let service5 = RadioService(engine: engine5, store: RadioStore(storage: RadioStorage(url: file)))
            service5.resumeIfWanted(scripted: false)
            let switchedOff = (service5.state, engine5.played.count)
            for key in [RadioService.resumeKey, RadioService.wasPlayingKey] { UserDefaults.standard.removeObject(forKey: key) }
            let engine3 = RadioFakeEngine()
            let service3 = RadioService(engine: engine3, store: RadioStore(storage: RadioStorage(url: nil)))
            UserDefaults.standard.set(true, forKey: RadioService.wasPlayingKey)
            service3.resumeIfWanted(scripted: false)
            let nothingToResume = (service3.station == nil, engine3.played.isEmpty)
            UserDefaults.standard.removeObject(forKey: RadioService.wasPlayingKey)
            panels2.stop()
            try? FileManager.default.removeItem(at: file)
            UserDefaults.standard.removeObject(forKey: RadioService.volumeKey)
            note("remembered: after a relaunch the radio plays again only if it was playing", [
                ("the last station and the volume are back, nothing plays by itself at creation, the dashboard has no panel", ready.0 == aurora.id && ready.1 == .idle && ready.2 == 0 && ready.3 == 0 && ready.4.isEmpty && ready.5 == 0.35),
                ("'Play the last station again when Scout opens' is ON by default, and it was playing as Scout quit", defaultOn),
                ("in a scripted run still nothing starts", scripted.0 == .idle && scripted.1 == 0),
                ("in a normal run the last station starts again", resumed.0 == .loading && resumed.1 == [aurora.url]),
                ("stopped by the person before quitting: it stays stopped", stoppedStays.0 == .idle && stoppedStays.1 == 0 && !stoppedStays.2),
                ("the switch off: nothing starts, even after a radio that was playing", switchedOff.0 == .idle && switchedOff.1 == 0),
                ("with no last station: nothing to start", nothingToResume.0 && nothingToResume.1),
            ])
        }

        // 10b. "Stop the radio after": the timer stops a playing station; a pause cancels it.
        do {
            UserDefaults.standard.set(15, forKey: RadioService.sleepKey)
            let w = RadioWorld(storage: RadioStorage(url: nil))
            w.service.sleepUnit = 0.01   // 15 "minutes" = 0.15 s
            w.service.play(aurora)
            w.engine.emit(.playing)
            await wait()
            let armed = w.service.sleepArmed
            await wait(400)
            let stopped = (w.service.state, UserDefaults.standard.bool(forKey: RadioService.wasPlayingKey))
            w.service.play(aurora)
            w.engine.emit(.playing)
            await wait()
            w.service.pause()
            let pausedArmed = w.service.sleepArmed
            await wait(300)
            let stillPaused = w.service.state
            UserDefaults.standard.removeObject(forKey: RadioService.sleepKey)
            let w2 = RadioWorld(storage: RadioStorage(url: nil))
            w2.service.play(aurora)
            let neverArmed = !w2.service.sleepArmed
            w2.service.stop()
            note("stop the radio after: a timer from the start, cancelled by a pause, off by default", [
                ("set to 15 min: armed when a station starts", armed),
                ("when it runs out the radio stops, and it will not play again at the next launch", stopped.0 == .idle && !stopped.1),
                ("a pause cancels it (the paused station is not stopped later)", !pausedArmed && stillPaused == .paused),
                ("off by default (Never): no timer", neverArmed && RadioService.sleepMinutes == 0),
                ("the choices are Never, 15 and 30 min, 1 and 2 hours", RadioService.sleepChoices == [0, 15, 30, 60, 120] && RadioSettingsPane.sleepTitle(0) == "Never"),
            ])
        }

        // 10c. The radio in the closed notch while it plays: shown while playing or connecting, gone when it pauses or stops or the switch is
        //      off; the right wing is exactly as wide as the longer of its two lines.
        do {
            let center = LiveActivityCenter()
            let w = RadioWorld(storage: RadioStorage(url: nil))
            w.service.play(aurora)
            RadioNotchPresenter.apply(service: w.service, center: center)
            let connecting = center.activities.map { "\($0.id):\($0.kind.rawValue)" }
            w.engine.emit(.playing)
            await wait()
            RadioNotchPresenter.apply(service: w.service, center: center)
            let playing = center.activities.count
            w.service.pause()
            RadioNotchPresenter.apply(service: w.service, center: center)
            let paused = center.activities.isEmpty
            w.service.resume()
            UserDefaults.standard.set(false, forKey: LiveActivityKind.radio.enabledKey)
            RadioNotchPresenter.apply(service: w.service, center: center)
            let switchedOff = center.activities.isEmpty
            UserDefaults.standard.removeObject(forKey: LiveActivityKind.radio.enabledKey)
            RadioNotchPresenter.apply(service: w.service, center: center)
            let backOn = center.activities.map(\.id)
            w.service.stop()
            RadioNotchPresenter.apply(service: w.service, center: center)
            let stopped = center.activities.isEmpty
            let name = "Harbour Jazz", song = "Nils Frahm · Says", longSong = String(repeating: "A very long song title ", count: 8)
            let snug = RadioWingTrailing.width(station: name, song: song)
            let measured = max((name as NSString).size(withAttributes: [.font: RadioWingTrailing.nameFont]).width,
                               (song as NSString).size(withAttributes: [.font: RadioWingTrailing.songFont]).width)
            let view = NSHostingView(rootView: RadioWingTrailing.readout(name: name, song: song).fixedSize())
            note("the radio in the closed notch while it plays", [
                ("connecting: the radio activity is in the wings", connecting == ["radio:radio"]),
                ("playing: still one", playing == 1),
                ("paused: gone", paused),
                ("the switch off (Settings › Radio, the same as Live Activities › Radio): gone", switchedOff),
                ("the switch on again: back", backOn == ["radio"]),
                ("stopped: gone", stopped),
                ("the readout is exactly as wide as its longer line (\(Int(snug)) pt for \(Int(measured)) pt of words)", snug - measured <= 2.5 && snug >= measured),
                ("a song too long is held at 300 pt (it ends with …)", RadioWingTrailing.width(station: name, song: longSong) == RadioWingTrailing.maxWidth),
                ("drawn, the two lines are under 30 pt high and as wide as measured", view.fittingSize.height <= 30 && abs(view.fittingSize.width - snug) <= 1),
                ("the switches are on by default", RadioPrefs.showSong && LiveActivityCenter().isEnabled(.radio)),
            ])
        }

        // 11. Nothing starts in a scripted run; the tab and the pane are wired in.
        do {
            let real = RadioAVEngine()
            var got: [RadioEngineEvent] = []
            let sub = real.events.sink { got.append($0) }
            real.play(URL(string: "https://stream.example.test/never")!)
            sub.cancel()
            var directoryError: RadioSearchError?
            do { _ = try await RadioBrowserDirectory.shared.search(RadioQuery(countryCode: "IS")) } catch { directoryError = error as? RadioSearchError }
            var countriesError: RadioSearchError?
            do { _ = try await RadioBrowserDirectory.shared.countries() } catch { countriesError = error as? RadioSearchError }
            let located = await RadioCLGeocoder().locate("Athens")
            let sharedPanel = RadioLivePanel.live()
            note("scripted run: nothing is played and nothing reaches the network", [
                ("this is a scripted run", ScoutRuntime.isScripted),
                ("the shared service holds a fake player", RadioService.shared.usesFakeEngine),
                ("the real player refuses to start and creates no AVPlayer", got == [.failed("Playing is off in scripted runs.")] && !real.hasPlayer),
                ("the real directory refuses before any request", directoryError == .unavailable && countriesError == .unavailable),
                ("the real geocoder refuses", located == nil),
                ("the shared store keeps nothing on disk in a scripted run", RadioStorage.standard.url == nil),
                ("the shared dashboard panel is not live", !sharedPanel.isLive),
            ])
            let tabs = NotchPrefs.parseTabs("nook,agents", edited: false)
            let edited = NotchPrefs.parseTabs("nook,agents", edited: true)
            note("wiring: the Radio tab, its height, the settings pane", [
                ("the tab: title, symbol, owner", WorkspaceKind.radio.title == "Radio" && WorkspaceKind.radio.symbol == "radio" && WorkspaceKind.radio.isAvailable),
                ("the tab is in the default order and joins an older saved list until it is edited", NotchPrefs.allTabsInOrder.contains(.radio) && tabs.contains(.radio) && !edited.contains(.radio)),
                ("the tab opens at 320 pt", NotchPrefs.minimumOpenHeight(for: .radio) == 320),
                ("the settings pane is in Features", SettingsPane.radio.isAvailable && SettingsPane.radio.group == .features && SettingsPane.radio.displayTitle == "Radio" && !SettingsPane.radio.blurb.isEmpty),
                ("the registry builds both views", { _ = Registry.workspaceView(.radio); _ = Registry.settingsView(.radio); return true }()),
                ("the pane says where stations come from and who sees the connection", RadioSettingsPane.sourceLine.contains("Radio Browser") && RadioSettingsPane.sourceLine.contains("sees your connection like any website")),
            ])
        }

        // 12. The view, with real clicks: a row plays, the star favourites, the sidebar switches, the bar pauses and stops.
        // Run once in the 8-bit look and once in the minimal look (the setting is put back as it was afterwards).
        let savedLook = UserDefaults.standard.object(forKey: Retro.styleKey)
        for eightBit in [true, false] {
        Pref.set(eightBit, Retro.styleKey)
        let look = eightBit ? "" : " (minimal look)"
        do {
            let w = RadioWorld()
            let athens = all.filter { $0.state == "Attica" }.sorted { $0.clickCount > $1.clickCount }
            w.model.showSample(page: .search, query: "Athens", country: nil, phase: .results, results: athens, countries: countries)
            let rig = RadioViewRig(model: w.model)
            await wait(300)
            if let path = ProcessInfo.processInfo.environment["SCOUT_RADIO_SNAPSHOT"] { rig.snapshot(to: URL(fileURLWithPath: path)) }
            let first = athens[0], second = athens[1]
            await rig.click(CGPoint(x: 420, y: 58))
            let played = (w.service.station?.id, w.service.state, w.engine.played.count, w.store.latest.first?.id)
            await rig.click(CGPoint(x: 420, y: 58))
            let again = (w.service.state, w.engine.pauses)
            let starSpot = rig.button("star.\(second.id)", in: w.model) ?? .zero   // the second row's star, found by name (a click at .zero would fail the check)
            await rig.click(starSpot)
            let starred = (w.store.isFavourite(second.id), w.service.station?.id)
            await rig.click(starSpot)
            let unstarred = !w.store.isFavourite(second.id)
            await rig.click(CGPoint(x: 80, y: 73))
            let toFavourites = w.model.page
            await rig.click(CGPoint(x: 80, y: 45))
            let toLatest = w.model.page
            await rig.click(CGPoint(x: 80, y: 17))
            let toSearch = w.model.page
            let playSpot = rig.button("play", in: w.model) ?? .zero   // found by name: the boombox's play key
            let stopSpot = rig.button("stop", in: w.model) ?? .zero
            await rig.click(playSpot)   // the boombox's play key: the paused station goes on
            let resumed = (w.service.state, w.engine.resumes)
            await rig.click(stopSpot)   // stop
            let stopped = (w.service.state, w.service.station?.id)
            await rig.click(playSpot)   // play again from the boombox
            let replayed = (w.service.state, w.engine.played.count)
            rig.close()
            note("the view, with real clicks" + look, [
                ("the view drew in the \(eightBit ? "8-bit" : "minimal") look", Retro.is8bit == eightBit),
                ("a click on a row plays that station and saves it as latest", played.0 == first.id && played.1 == .loading && played.2 == 1 && played.3 == first.id),
                ("a second click on the playing row pauses it", again.0 == .paused && again.1 == 1),
                ("the star favourites a station without playing it; a second tap takes it back", starred.0 && starred.1 == first.id && unstarred),
                ("the sidebar switches Favourites, Latest and Search", toFavourites == .favourites && toLatest == .latest && toSearch == .search),
                ("the bar's play button goes on, stop stops and keeps the station, play starts it again", resumed.0 == .loading && resumed.1 == 1 && stopped.0 == .idle && stopped.1 == first.id && replayed.0 == .loading && replayed.1 == 2),
            ])
        }
        }
        Pref.set(savedLook, Retro.styleKey)

        // 13. The boombox: what the reels, the lamp, the tuner needle and the LCD marks do, as plain rules; then real clicks on its keys and fader.
        do {
            let states: [(String, RadioPlayState)] = [("idle", .idle), ("loading", .loading), ("playing", .playing), ("paused", .paused), ("failed", .failed("x"))]
            let reelsRight = states.allSatisfy { name, state in
                RadioBoom.reelsTurn(state: state, reduceMotion: false) == (name == "playing") && !RadioBoom.reelsTurn(state: state, reduceMotion: true)
            }
            let lampRight = states.allSatisfy { name, state in
                RadioBoom.lampFades(state: state, reduceMotion: true) == (name == "playing") && !RadioBoom.lampFades(state: state, reduceMotion: false)
            }
            let reelsOrLamp = states.allSatisfy { _, state in
                // With Reduce Motion the reels never turn, and one of the two (reels or lamp) moves only while a station plays.
                !RadioBoom.reelsTurn(state: state, reduceMotion: true) && (RadioBoom.reelsTurn(state: state, reduceMotion: false) || RadioBoom.lampFades(state: state, reduceMotion: true)) == (state == .playing)
            }
            let drivenOnlyWhenOpenAndReal = states.allSatisfy { _, state in
                !RadioBoom.isDriven(state: state, reduceMotion: false, notchOpen: false, scripted: false)
                    && !RadioBoom.isDriven(state: state, reduceMotion: false, notchOpen: true, scripted: true)
                    && !RadioBoom.isDriven(state: state, reduceMotion: true, notchOpen: false, scripted: false)
            } && RadioBoom.isDriven(state: .playing, reduceMotion: false, notchOpen: true, scripted: false)
                && RadioBoom.isDriven(state: .playing, reduceMotion: true, notchOpen: true, scripted: false)
                && !RadioBoom.isDriven(state: .paused, reduceMotion: false, notchOpen: true, scripted: false)
                && !RadioBoom.isDriven(state: .loading, reduceMotion: true, notchOpen: true, scripted: false)
            note("boombox: the reels turn only while a station plays and never with Reduce Motion", [
                ("the reels turn only in .playing, and never with Reduce Motion", reelsRight),
                ("with Reduce Motion a lamp fades instead, only while it plays", lampRight && reelsOrLamp),
                ("no timeline runs when the notch is closed, in a scripted run, or when nothing moves (paused, connecting, stopped)", drivenOnlyWhenOpenAndReal),
                ("a slow turn: one revolution takes several seconds, and the angle wraps", RadioBoom.reelPeriod >= 5 && RadioBoom.reelAngle(at: 0) == 0
                    && abs(RadioBoom.reelAngle(at: RadioBoom.reelPeriod / 2) - 180) < 1e-9 && RadioBoom.reelAngle(at: RadioBoom.reelPeriod * 3) < 1e-6),
                ("the lamp stays between dim and full", (0...48).allSatisfy { let l = RadioBoom.lampLevel(at: Double($0) * 0.05); return l >= 0.34 && l <= 1.0001 }),
            ])

            let ids = ["a", "b", "c", "d", "e"]
            let needle = [RadioTuner.position(of: "a", in: ids), RadioTuner.position(of: "c", in: ids), RadioTuner.position(of: "e", in: ids)]
            note("boombox: the tuner needle sits at the station's place in the list", [
                ("first, middle and last stations: 0, 0.5, 1", needle == [0, 0.5, 1]),
                ("one station sits in the middle; a station that is not in the list, and an empty list, have no needle",
                 RadioTuner.position(of: "x", in: ["x"]) == 0.5 && RadioTuner.position(of: "z", in: ids) == nil && RadioTuner.position(of: "a", in: []) == nil && RadioTuner.position(of: nil, in: ids) == nil),
                ("the place is written as 3/5", RadioTuner.placeText(of: "c", in: ids) == "3/5" && RadioTuner.placeText(of: "q", in: ids) == nil),
                ("the needle's x runs from one end of the scale to the other, inside the margins",
                 RadioTuner.needleX(0, width: 150, inset: 8) == 8 && RadioTuner.needleX(1, width: 150, inset: 8) == 142 && RadioTuner.needleX(0.5, width: 150, inset: 8) == 75
                    && RadioTuner.needleX(7, width: 150, inset: 8) == 142 && RadioTuner.needleX(-1, width: 150, inset: 8) == 8),
                ("one tick per station, up to 24", RadioTuner.tickCount(0) == 0 && RadioTuner.tickCount(5) == 5 && RadioTuner.tickCount(80) == 24),
                ("the needle follows the shown list: Aegean Breeze is first of the Athens search, Acropolis Classics last",
                 { let athens = all.filter { $0.state == "Attica" }.sorted { $0.clickCount > $1.clickCount }.map(\.id)
                   return RadioTuner.position(of: athens.first, in: athens) == 0 && RadioTuner.position(of: athens.last, in: athens) == 1 }()),
            ])

            let aegean = RadioFixtures.aegean
            let noCodec = all.first { $0.name == "Quiet Hours" }!
            let liveMarks = RadioBoom.marks(station: aurora, state: .playing)
            let allMarks = states.flatMap { RadioBoom.marks(station: aurora, state: $0.1) } + states.flatMap { RadioBoom.marks(station: noCodec, state: $0.1) }
            let greek = "Ελληνικό Ραδιόφωνο"
            let fitLong = RadioLCDText.fit("Northern Lights Classical Music Hour", width: 160)
            note("boombox: the LCD says only true things, and the name always reads", [
                ("LIVE only while it plays; the codec and bitrate come from the station", liveMarks == ["LIVE", "MP3 128K"] && RadioBoom.marks(station: aegean, state: .paused) == ["MP3 128K"]
                    && RadioBoom.marks(station: aurora, state: .loading) == ["MP3 128K"] && RadioBoom.marks(station: aurora, state: .idle) == ["MP3 128K"]),
                ("a station with no codec shows no quality mark, and only LIVE while it plays", RadioBoom.marks(station: noCodec, state: .playing) == ["LIVE"] && RadioBoom.marks(station: noCodec, state: .paused).isEmpty),
                ("nothing claims FM, stereo, a frequency or a recording", !allMarks.contains { ["FM", "STEREO", "REC"].contains($0) } && allMarks.allSatisfy { $0 == "LIVE" || $0.hasPrefix("MP3") }),
                ("a name the dot font knows is drawn in pixel letters, at the biggest size that fits", RadioLCDText.fit("Aurora FM", width: 300) == RadioLCDText.Fit(text: "Aurora FM", pixel: 2)
                    && RadioLCDText.fit("Aurora FM", width: 60).pixel == 1.5),
                ("a name with letters the dot font lacks (Greek) uses the system font, whole", RadioLCDText.fit(greek, width: 100) == RadioLCDText.Fit(text: greek, pixel: nil)),
                ("a long name is cut with two dots and fits its room", fitLong.text.hasSuffix("..") && fitLong.pixel == 1.5 && RetroPixelLayout.width(fitLong.text, pixel: 1.5) <= 160),
            ])

            // Real clicks on the boombox: the volume fader sets the volume, the key does its job (found by name). Both looks.
            for eightBit in [true, false] {
            Pref.set(eightBit, Retro.styleKey)
            let look = eightBit ? "" : " (minimal look)"
            let w = RadioWorld()
            w.model.showSample(page: .favourites, query: "", country: nil, phase: .idle, results: [], countries: countries)
            w.service.showSample(station: aurora, state: .playing, title: "Song - Someone")
            let rig = RadioViewRig(model: w.model)
            await wait(300)
            let before = w.service.volume
            if let v = w.model.controlRects["volume"] {
                await rig.click(CGPoint(x: v.minX + v.width * 0.25, y: v.midY))
                let low = w.service.volume
                await rig.click(CGPoint(x: v.minX + v.width * 0.9, y: v.midY))
                let high = w.service.volume
                note("boombox: the volume fader sets the volume where it is pressed" + look, [
                    ("a press near the left gives a low volume, near the right a high one", low < 0.4 && high > 0.8 && low != before),
                    ("the fader reaches the engine (the fake player heard the last value)", abs(Double(w.engine.volume) - high) < 0.01),
                ])
            } else {
                note("boombox: the volume fader sets the volume where it is pressed" + look, [("the fader is on screen", false)])
            }
            let keys = (rig.button("play", in: w.model) != nil, rig.button("stop", in: w.model) != nil)
            await rig.click(rig.button("stop", in: w.model) ?? .zero)
            let afterStop = w.service.state
            rig.close()
            UserDefaults.standard.removeObject(forKey: RadioService.volumeKey)
            note("boombox: the keys are on screen and stop works" + look, [
                ("the player drew in the \(eightBit ? "8-bit" : "minimal") look", Retro.is8bit == eightBit),
                ("play and stop are found by name", keys.0 && keys.1),
                ("the stop key stops (and keeps the station)", afterStop == .idle && w.service.station?.id == aurora.id),
            ])
        
            }
            Pref.set(savedLook, Retro.styleKey)
        }

        // 13. The Radio tab opens on Favourites if any station is saved, else Latest if something was played, else Search (the owner, 2026-11-16).
        // The view appears on a model that was left on another page; a section picked by hand stays while the view stays open; a new visit starts again.
        do {
            func opened(_ prepare: (RadioWorld) -> Void) async -> (RadioModel.Page, RadioModel.Page) {
                let w = RadioWorld()
                prepare(w)
                w.model.page = .list(UUID())   // left on something else by an earlier visit
                let expected = w.model.openingPage
                let rig = RadioViewRig(model: w.model)
                await wait(250)
                let page = w.model.page
                rig.close()
                return (page, expected)
            }
            let nothing = await opened { _ in }
            let played = await opened { $0.store.recordPlayed(jazz) }
            let saved = await opened { $0.store.toggleFavourite(aurora) }
            let both = await opened { $0.store.recordPlayed(jazz); $0.store.toggleFavourite(aurora) }
            note("the Radio tab opens on Favourites, else Latest, else Search", [
                ("nothing saved or played: Search", nothing.0 == .search && nothing.1 == .search),
                ("only played stations: Latest", played.0 == .latest && played.1 == .latest),
                ("only favourites: Favourites", saved.0 == .favourites && saved.1 == .favourites),
                ("favourites and played stations: Favourites", both.0 == .favourites && both.1 == .favourites),
            ])

            let w = RadioWorld()
            w.store.recordPlayed(jazz)
            w.store.toggleFavourite(aurora)
            let rig = RadioViewRig(model: w.model)
            await wait(250)
            let first = w.model.page
            await rig.click(CGPoint(x: 80, y: 45))   // Latest, by hand
            w.store.toggleFavourite(jazz)
            w.store.recordPlayed(RadioFixtures.aegean)
            await wait(150)
            let pickedLatest = w.model.page
            await rig.click(CGPoint(x: 80, y: 17))   // Search, by hand
            w.store.toggleFavourite(jazz)
            await wait(150)
            let pickedSearch = w.model.page
            rig.close()
            let again = RadioViewRig(model: w.model)
            await wait(250)
            let nextVisit = w.model.page
            again.close()
            note("a section picked by hand stays while the view is open; the next visit starts on the opening section again", [
                ("the view opened on Favourites", first == .favourites),
                ("a click on Latest shows Latest, and saving or playing stations does not move it", pickedLatest == .latest),
                ("a click on Search shows Search and it stays", pickedSearch == .search),
                ("the next time the view opens it starts on Favourites again", nextVisit == .favourites),
            ])
            let sample = RadioWorld()
            sample.store.toggleFavourite(aurora)
            sample.model.showSample(page: .latest, query: "", country: nil, phase: .idle, results: [], countries: countries)
            let sampleRig = RadioViewRig(model: sample.model)
            await wait(250)
            let sampled = sample.model.page
            sampleRig.close()
            note("a gallery sample keeps the page it was given", [("the sample stays on Latest although a favourite is saved", sampled == .latest)])
        }

        let passed = results.filter { $0["pass"] as? Bool == true }.count
        let report: [String: Any] = ["ok": passed == results.count, "passed": passed, "failed": results.count - passed, "scenarios": results]
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
