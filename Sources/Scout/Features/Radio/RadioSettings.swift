import SwiftUI

/// Settings › Radio:
/// the radio in the closed
/// notch and its song line, starting again with Scout, a stop timer, clearing what was played and searched, and where stations come from.
struct RadioSettingsPane: View {
    @AppStorage(LiveActivityKind.radio.enabledKey) private var showInNotch = true
    @AppStorage(RadioPrefs.showSongKey) private var showSong = true
    @AppStorage(RadioService.resumeKey) private var resume = true
    @AppStorage(RadioService.sleepKey) private var sleepMinutes = 0
    @ObservedObject private var store: RadioStore

    @MainActor init(store: RadioStore? = nil) { _store = ObservedObject(wrappedValue: store ?? RadioStore.shared) }

    var body: some View {
        FeaturePane {
            Section("In the notch") {
                Toggle("Show the radio in the notch while it plays", isOn: $showInNotch)
                    .onChange(of: showInNotch) { _, _ in RadioNotchPresenter.shared.refresh() }
                Toggle("Show the song title when the station sends it", isOn: $showSong)
                    .disabled(!showInNotch)
            }
            Section {
                Toggle("Play the last station again when Scout opens", isOn: $resume)
                Picker("Stop the radio after", selection: $sleepMinutes) {
                    ForEach(RadioService.sleepChoices, id: \.self) { minutes in
                        Text(verbatim: Self.sleepTitle(minutes)).tag(minutes)
                    }
                }
                .onChange(of: sleepMinutes) { _, _ in if RadioService.shared.isActive { RadioService.shared.armSleep() } }
            } footer: {
                SettingsNote("Only when it was still playing as Scout quit. Scout always remembers the last station and the volume.")
            }
            Section {
                Button("Clear latest stations and places", role: .destructive) { store.clearHistory() }
                    .disabled(!store.hasHistory)
            } footer: {
                SettingsNote(verbatim: historyLine)
            }
            Section {
                Text(RadioSettingsPane.sourceLine).font(.callout).fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Where stations come from")
            }
        }
    }

    /// "Never", or the time in the Mac's own words ("15 minutes", "1 hour", "2 Stunden"…).
    static func sleepTitle(_ minutes: Int) -> String {
        guard minutes > 0 else { return String(localized: "Never") }
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.allowedUnits = minutes % 60 == 0 ? [.hour] : [.minute]
        return f.string(from: TimeInterval(minutes * 60)) ?? "\(minutes)"
    }

    private var historyLine: String {
        let s = store.latest.count, p = store.places.count
        if s == 0, p == 0 { return String(localized: "Nothing to clear. Favourites and your lists stay.") }
        return String(localized: "Latest stations saved on this Mac: \(s). Places: \(p). Favourites and your lists stay.")
    }

    static let sourceLine = String(localized: "Stations come from the free Radio Browser directory (radio-browser.info). A place you type goes to it, and to Apple Maps to find the spot; the station you play sees your connection like any website.")
}
