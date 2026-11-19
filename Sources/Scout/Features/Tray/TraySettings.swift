import SwiftUI

struct TraySettingsPane: View {
    @ObservedObject private var store = TrayStore.shared
    @AppStorage(TrayStore.Key.activity) private var activity = true
    @AppStorage(TrayStore.Key.convertDest) private var convertDest = Edition.isAppStore ? "downloads" : "alongside"
    @State private var folderRefresh = 0
    @AppStorage(TrayStore.Key.addResults) private var addResults = true

    var body: some View {
        FeaturePane {
            Section {
                Toggle("Show a count next to the notch while the Tray holds files", isOn: $activity)
                    .onChange(of: activity) { store.activitySettingChanged() }
                LabeledContent("In the Tray now") {
                    HStack {
                        Text("Items: \(store.items.count)").foregroundStyle(.secondary)
                        Button("Empty the Tray") { store.clear() }.disabled(store.items.isEmpty)
                    }
                }
            } header: {
                Text("Tray")
            } footer: {
                SettingsNote("Files in the Tray stay where they are: Scout keeps a pointer to each one and never moves or deletes your originals. Dropped text and links become small files in Scout's own folder.")
            }

            Section {
                #if APPSTORE
                Picker("Save converted files", selection: $convertDest) {
                    Text("In Downloads").tag("downloads")
                    Text("In a folder I choose").tag("folder")
                    Text("In Scout's own folder").tag("tray")
                }
                if convertDest == "folder" {
                    LabeledContent("Folder") {
                        HStack {
                            Text(pickedFolderName).foregroundStyle(.secondary)
                            Button("Choose…") { chooseFolder() }
                        }
                    }
                }
                #else
                Picker("Save converted files", selection: $convertDest) {
                    Text("Next to the original").tag("alongside")
                    Text("In Scout's own folder").tag("tray")
                }
                #endif
                Toggle("Put converted files in the Tray", isOn: $addResults)
                #if !APPSTORE
                StatusRow(title: Text("WebP and MP3"), status: Text(verbatim: toolStatus), level: Converter.hasCwebp && Converter.hasFFmpeg ? .good : .warn)
                #endif
            } header: {
                Text("Convert")
            } footer: {
                #if APPSTORE
                SettingsNote("Conversions always make new files and never change your originals. Images convert between PNG, JPEG, HEIC and TIFF, and combine into a PDF. Movies become MP4 or audio. ZIP works for anything.")
                #else
                SettingsNote("Conversions always make new files. Images convert between PNG, JPEG, HEIC and TIFF, and combine into a PDF. Movies become MP4 or audio. ZIP works for anything. WebP and MP3 use cwebp and ffmpeg when they are installed.")
                #endif
            }

            PocketsSettingsSection()
        }
    }

    #if APPSTORE
    private var pickedFolderName: String {
        _ = folderRefresh
        return FileScope.folder(key: TrayStore.convertFolderKey)?.lastPathComponent ?? String(localized: "None chosen yet")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Converted files will be saved in this folder.")
        if panel.runModal() == .OK, let url = panel.url { FileScope.saveFolder(url, key: TrayStore.convertFolderKey); folderRefresh += 1 }
    }
    #endif

    private var toolStatus: String {
        #if APPSTORE
        return ""
        #else
        switch (Converter.hasCwebp, Converter.hasFFmpeg) {
        case (true, true): String(localized: "cwebp and ffmpeg found")
        case (true, false): String(localized: "ffmpeg not found (no MP3)")
        case (false, true): String(localized: "cwebp not found (no WebP)")
        case (false, false): String(localized: "cwebp and ffmpeg not found")
        }
        #endif
    }
}
