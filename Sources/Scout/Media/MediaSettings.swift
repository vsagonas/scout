import SwiftUI

// A6 — the Media settings page.

struct MediaSettingsPane: View {
    @ObservedObject private var service = NowPlayingService.shared
    @AppStorage("media.source") private var source = MediaSourcePreference.auto.rawValue
    @AppStorage("media.spotify.control") private var spotifyControl = false
    @AppStorage("media.music.control") private var musicControl = false
    @AppStorage("media.quickPeek") private var quickPeek = true
    @AppStorage("media.visualizer") private var visualizer = true
    #if !APPSTORE
    @AppStorage("media.lyrics") private var lyrics = true
    #endif
    @AppStorage("media.artworkRadius") private var radius = 6.0
    @AppStorage("media.widgetLayout") private var layout = "compact"
    @AppStorage("activity.media.enabled") private var activityOn = true

    var body: some View {
        Form {
            Section {
                Picker("Show music from", selection: $source) {
                    ForEach(MediaSourcePreference.allCases) { Text($0.title).tag($0.rawValue) }
                }
                playerRow("Spotify", id: NowPlayingService.spotifyID, isOn: $spotifyControl)
                playerRow("Apple Music", id: NowPlayingService.musicID, isOn: $musicControl)
            } header: {
                Text("Players")
            } footer: {
                SettingsFootnote("Song names show up without any permission. Turning a player on also lets Scout show its cover, jump around in a song and press play for you; macOS asks once.")
            }

            Section("In the notch") {
                Toggle("Show music next to the notch while it plays", isOn: $activityOn)
                Toggle("Peek at the song when it changes", isOn: $quickPeek)
                Toggle("Dancing bars", isOn: $visualizer)
                #if !APPSTORE
                Toggle("Synced lyrics in the Music workspace", isOn: $lyrics)
                #endif
            }

            Section("Look") {
                Picker("Media widget", selection: $layout) {
                    Text("Compact").tag("compact")
                    Text("Expanded").tag("expanded")
                }
                .pickerStyle(.segmented)
                LabeledContent("Cover corners") {
                    HStack(spacing: 12) {
                        Slider(value: $radius, in: 0...11, step: 1).frame(width: 160)
                        ArtworkView(track: service.track ?? NowPlayingService.sampleTrack, size: 30, radius: CGFloat(radius) * 30 / 22)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private func playerRow(_ name: String, id: String, isOn: Binding<Bool>) -> some View {
        let binding = Binding<Bool>(get: { isOn.wrappedValue }, set: { new in
            isOn.wrappedValue = new
            if new { service.requestAccess(for: id) }
        })
        return LabeledContent {
            Toggle("", isOn: binding).labelsHidden().toggleStyle(.switch)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Control \(name)")
                statusLine(for: id)
            }
        }
    }

    @ViewBuilder
    private func statusLine(for id: String) -> some View {
        switch service.access(for: id) {
        case .off:
            EmptyView()
        case .waiting:
            Text("Open \(id == NowPlayingService.spotifyID ? "Spotify" : String(localized: "Music")) to finish").font(.caption).foregroundStyle(.secondary)
        case .allowed:
            Text("On").font(.caption).foregroundStyle(.green)
        case .denied:
            HStack(spacing: 6) {
                Text("macOS says no.").font(.caption).foregroundStyle(.orange)
                Button("Open Privacy Settings") { Permissions.openSettings(.automation) }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }
}
