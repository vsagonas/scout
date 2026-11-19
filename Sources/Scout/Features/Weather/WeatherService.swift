import AppKit
import CoreLocation
import SwiftUI

/// Weather for the widget. Refreshes only while a weather widget is on screen (and the data is older than
/// the refresh interval). Scripted runs show sample weather and never touch the network or location.
@MainActor
final class WeatherService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WeatherService()

    enum Key {
        static let mode = "weather.mode"             // "auto" | "city"
        static let city = "weather.city"             // JSON of WeatherPlace
        static let unit = "weather.unit"
        static let refreshMinutes = "weather.refreshMinutes"
    }

    enum State: Equatable {
        case idle
        case loading
        case ready
        case needsLocation       // automatic mode, macOS has not been asked yet
        case locationDenied
        case needsCity           // city mode without a city
        case failed(String)
    }

    @Published private(set) var snapshot: WeatherSnapshot?
    @Published private(set) var state: State = .idle

    private let cache = JSONFile<WeatherSnapshot>("weather.json")
    private var manager: CLLocationManager?
    private var visible = 0
    private var timer: Timer?
    private var fetching = false
    private var lastLocationName: String?

    var isAutomatic: Bool { Pref.string(Key.mode, "auto") == "auto" }

    var chosenCity: WeatherPlace? {
        get {
            guard let text = UserDefaults.standard.string(forKey: Key.city), let data = text.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(WeatherPlace.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) { Pref.set(String(decoding: data, as: UTF8.self), Key.city) }
            else { Pref.set(nil, Key.city) }
        }
    }

    // MARK: Visibility (the widget tells us when it is on screen)

    func widgetAppeared() {
        visible += 1
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshIfStale() }
            }
        }
        if snapshot == nil, let cached = cache.load(), !ScoutRuntime.isScripted { snapshot = cached; state = .ready }
        refreshIfStale()
    }

    func widgetDisappeared() {
        visible = max(0, visible - 1)
        if visible == 0 { timer?.invalidate(); timer = nil }
    }

    private var interval: TimeInterval { Double(max(5, Pref.int(Key.refreshMinutes, 30))) * 60 }

    func refreshIfStale() {
        guard visible > 0 else { return }
        if let s = snapshot, Date().timeIntervalSince(s.fetchedAt) < interval, !ScoutRuntime.isScripted { return }
        refresh()
    }

    // MARK: Refresh

    func refresh() {
        if ScoutRuntime.isScripted {
            snapshot = WeatherSamples.snapshot(place: chosenCity?.name ?? "Athens")
            state = .ready
            return
        }
        if isAutomatic {
            switch CLLocationManager().authorizationStatus {
            case .notDetermined: state = .needsLocation
            case .denied, .restricted: state = .locationDenied
            default: requestLocation()
            }
        } else if let city = chosenCity {
            fetch(city)
        } else {
            state = .needsCity
        }
    }

    /// The user pressed "Use my location": the only place the macOS location prompt appears.
    func askForLocation() {
        guard !ScoutRuntime.isScripted else { return }
        Pref.set("auto", Key.mode)
        let m = manager ?? CLLocationManager()
        manager = m
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyReduced
        if m.authorizationStatus == .notDetermined { m.requestWhenInUseAuthorization() } else { refresh() }
    }

    private func requestLocation() {
        let m = manager ?? CLLocationManager()
        manager = m
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyReduced
        state = snapshot == nil ? .loading : state
        m.requestLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .denied, .restricted: self.state = .locationDenied
            case .notDetermined: break
            default: self.refresh()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            let name = await self.placeName(for: location)
            self.fetch(WeatherPlace(name: name, region: nil, country: nil,
                                    latitude: location.coordinate.latitude, longitude: location.coordinate.longitude))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if self.snapshot == nil { self.state = .failed(String(localized: "Couldn't find your location")) }
        }
    }

    private func placeName(for location: CLLocation) async -> String {
        if let name = lastLocationName { Task { _ = await Self.reverse(location) }; return name }
        let name = await Self.reverse(location)
        lastLocationName = name
        return name
    }

    nonisolated private static func reverse(_ location: CLLocation) async -> String {
        let marks = try? await CLGeocoder().reverseGeocodeLocation(location)
        return marks?.first?.locality ?? marks?.first?.name ?? String(localized: "Here")
    }

    private func fetch(_ place: WeatherPlace) {
        guard !fetching else { return }
        fetching = true
        if snapshot == nil { state = .loading }
        Task {
            defer { fetching = false }
            do {
                let s = try await OpenMeteo.forecast(for: place)
                snapshot = s
                cache.save(s)
                state = .ready
            } catch {
                if snapshot == nil { state = .failed(String(localized: "Weather is offline")) }
            }
        }
    }

    // MARK: Actions

    func openWeatherApp() {
        guard !ScoutRuntime.isScripted else { return }
        let url = URL(fileURLWithPath: "/System/Applications/Weather.app")
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
    }

    func choose(_ place: WeatherPlace) {
        chosenCity = place
        Pref.set("city", Key.mode)
        snapshot = nil
        refresh()
    }
}
