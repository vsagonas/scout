import SwiftUI

struct MirrorSettingsSection: View {
    @ObservedObject private var model = MirrorModel.shared
    @AppStorage(MirrorModel.Key.shape) private var shape = MirrorShape.rounded.rawValue
    @AppStorage(MirrorModel.Key.flip) private var flip = true
    @AppStorage(MirrorScene.fillKey) private var fill = true
    @AppStorage(MirrorModel.Key.camera) private var camera = ""
    @AppStorage(MirrorModel.Key.autostart) private var autostart = false

    var body: some View {
        Section {
            Picker("Widget shape", selection: $shape) {
                ForEach(MirrorShape.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            Toggle("Mirror the picture (flip left and right)", isOn: $flip)
            Toggle("Fill the Mirror tab with the picture", isOn: $fill)
            Picker("Camera", selection: $camera) {
                Text("Automatic").tag("")
                ForEach(model.devices) { Text($0.name).tag($0.id) }
            }
            Toggle("Start the camera when the Mirror widget appears", isOn: $autostart)
        } header: {
            Text("Mirror")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                SettingsNote("Nothing is recorded or saved unless you snap or share a picture yourself.")
                SettingsNote("The camera runs only while the Mirror tab or widget is on screen. The camera key under the picture copies a picture of it to the clipboard; Share makes a polaroid with your agents and shows it before anything is shared. macOS asks for camera access the first time you press the button to turn it on. External and iPhone cameras show up in the list.")
            }
        }
        .onAppear { model.refreshDevices() }
    }
}
