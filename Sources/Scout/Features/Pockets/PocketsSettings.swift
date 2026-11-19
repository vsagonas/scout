import SwiftUI

struct PocketsSettingsSection: View {
    @AppStorage(PocketStore.Key.enabled) private var enabled = true
    @AppStorage(PocketStore.Key.sensitivity) private var sensitivity = ShakeDetector.Sensitivity.gentle.rawValue
    @AppStorage(PocketStore.Key.restore) private var restore = true
    @ObservedObject private var store = PocketStore.shared

    var body: some View {
        Section {
            Toggle("Shake while dragging files to open a Pocket", isOn: $enabled)
            Picker("Sensitivity", selection: $sensitivity) {
                ForEach(ShakeDetector.Sensitivity.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .disabled(!enabled)
            Toggle("Bring Pockets back when Scout starts", isOn: $restore)
            LabeledContent("Open Pockets") {
                HStack {
                    Text("\(store.pockets.count)").foregroundStyle(.secondary)
                    Button("Empty all") { for p in store.pockets { PocketsController.shared.close(p.id) } }.disabled(store.pockets.isEmpty)
                }
            }
        } header: {
            Text("Pockets")
        } footer: {
            SettingsNote("Grab files, then wiggle the pointer from side to side: a small Pocket appears under it. Drop files in, drag them all out together, convert them, AirDrop them or send them to the Tray. Minimize a Pocket and it waits in a small strip near the top right of the screen. Scout never moves your originals.")
        }
    }
}
