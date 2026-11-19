import CoreLocation
import SwiftUI

struct WeatherSettingsPane: View {
    @ObservedObject private var service = WeatherService.shared
    @AppStorage(WeatherService.Key.mode) private var mode = "auto"
    @AppStorage(WeatherService.Key.unit) private var unit = TemperatureUnit.automatic.rawValue
    @AppStorage(WeatherService.Key.refreshMinutes) private var refreshMinutes = 30
    @State private var query = ""
    @State private var results: [WeatherPlace] = []
    @State private var searching = false
    @State private var searchError: String?

    var body: some View {
        FeaturePane {
            Section {
                Picker("Location", selection: $mode) {
                    Text("Automatic (this Mac)").tag("auto")
                    Text("A city I choose").tag("city")
                }
                .pickerStyle(.radioGroup)
                .onChange(of: mode) { service.refresh() }

                if mode == "auto" {
                    StatusRow(title: Text("Location access"), status: Text(verbatim: locationStatus.text), level: locationStatus.level)
                    if locationStatus.canAsk {
                        Button("Use my location") { service.askForLocation() }
                    } else if locationStatus.level == .bad {
                        Button("Open System Settings…") { Permissions.openSettings(.location) }
                    }
                } else {
                    LabeledContent("City") { (service.chosenCity.map { Text(verbatim: [$0.name, $0.subtitle].filter { !$0.isEmpty }.joined(separator: " · ")) } ?? Text("None yet")).foregroundStyle(.secondary) }
                    HStack {
                        TextField("Search for a city", text: $query).onSubmit(search)
                        Button("Search", action: search).disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                    }
                    if let searchError { Text(searchError).font(.caption).foregroundStyle(.secondary) }
                    ForEach(results, id: \.self) { place in
                        Button { service.choose(place); results = []; query = "" } label: {
                            HStack {
                                Text(place.name).fontWeight(.medium)
                                Text(place.subtitle).foregroundStyle(.secondary)
                                Spacer()
                                Image(systemName: "plus.circle").foregroundStyle(Theme.accent)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } footer: {
                SettingsNote("Automatic uses an approximate location (never your exact position) and asks macOS only when you press the button. A chosen city needs no permission.")
            }

            Section("Display") {
                Picker("Temperature", selection: $unit) {
                    ForEach(TemperatureUnit.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Refresh", selection: $refreshMinutes) {
                    ForEach([15, 30, 60, 120], id: \.self) { Text(Self.refreshLabel($0)).tag($0) }
                }
            }

            Section {
                Button("Open the Weather app") { service.openWeatherApp() }
            } footer: {
                SettingsNote("Forecasts come from Open-Meteo.com. Clicking the widget opens the Weather app.")
            }
        }
    }

    /// One whole phrase for each choice (no plural built from pieces).
    private static func refreshLabel(_ minutes: Int) -> LocalizedStringKey {
        switch minutes {
        case 15: "Every 15 minutes"
        case 30: "Every 30 minutes"
        case 60: "Every hour"
        default: "Every 2 hours"
        }
    }

    private var locationStatus: (text: String, level: StatusRow.Level, canAsk: Bool) {
        if ScoutRuntime.isScripted { return ("Sample weather (scripted run)", .good, false) }
        switch CLLocationManager().authorizationStatus {
        case .notDetermined: return (String(localized: "Not asked yet"), .warn, true)
        case .denied, .restricted: return (String(localized: "Blocked in System Settings"), .bad, false)
        default: return (String(localized: "Allowed"), .good, false)
        }
    }

    private func search() {
        let name = query.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        searching = true
        searchError = nil
        if ScoutRuntime.isScripted { results = WeatherSamples.cities; searching = false; return }
        Task {
            do {
                results = try await OpenMeteo.search(name)
                if results.isEmpty { searchError = String(localized: "No city found") }
            } catch {
                searchError = String(localized: "Couldn't search (offline?)")
            }
            searching = false
        }
    }
}
