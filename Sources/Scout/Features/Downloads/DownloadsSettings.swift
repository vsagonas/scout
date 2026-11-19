import SwiftUI

struct DownloadsSettingsPane: View {
    @AppStorage(DownloadsWatcher.Key.enabled) private var enabled = false
    @AppStorage(DownloadsWatcher.Key.style) private var style = DownloadStyle.ring.rawValue
    @AppStorage(DownloadsWatcher.Key.finishedCard) private var finishedCard = true
    @AppStorage(DownloadsWatcher.Key.cardSeconds) private var cardSeconds = 3

    var body: some View {
        FeaturePane {
            Section {
                Toggle("Show downloads next to the notch", isOn: $enabled)
                Picker("Progress style", selection: $style) {
                    ForEach(DownloadStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Toggle("Show a card when a download finishes", isOn: $finishedCard)
                Picker("Keep the card for", selection: $cardSeconds) {
                    ForEach([2, 3, 5, 8], id: \.self) { Text(verbatim: FeatureFormat.seconds($0)).tag($0) }
                }
                .disabled(!finishedCard)
                Button("Preview") { DownloadsWatcher.shared.demo() }
            } header: {
                Text("Downloads")
            } footer: {
                SettingsNote("Works with Safari, Chrome, Arc, Edge, Brave, Opera and Firefox. macOS asks once for access to your Downloads folder when you turn this on. Scout reads only file names and sizes. Chrome and Firefox don't tell how big a file will be, so those show a moving indicator.")
            }

            VideoSettingsSection()
        }
    }
}
