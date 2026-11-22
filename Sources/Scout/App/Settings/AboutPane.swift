import AppKit
import SwiftUI

/// Everything bundled or used that needs a credit. add a line when you add a dependency.
enum AboutCredits {
    struct Entry: Identifiable {
        let id: String
        let name: String
        let license: String
        let use: String
        let url: String
    }

    static let entries: [Entry] = {
        let shared = [
            Entry(id: "openmeteo", name: "Open-Meteo", license: "CC BY 4.0", use: String(localized: "Weather forecasts and city search"), url: "https://open-meteo.com"),
            Entry(id: "radiobrowser", name: "Radio Browser", license: String(localized: "Free service, no key"), use: String(localized: "Radio stations in the Radio tab"), url: "https://www.radio-browser.info"),
            Entry(id: "frankfurter", name: "Frankfurter", license: String(localized: "Free service, no key"), use: String(localized: "Currency rates in the Units tool"), url: "https://frankfurter.dev"),
        ]
        #if APPSTORE
        // Nothing about the left-out features: no lyrics, terminal or video downloads (and no ffmpeg, cwebp or Homebrew) here.
        return shared
        #else
        return [Entry(id: "lrclib", name: "LRCLIB", license: String(localized: "Free service, no key"), use: String(localized: "Synced lyrics in the Music workspace"), url: "https://lrclib.net"),
                Entry(id: "swiftterm", name: "SwiftTerm", license: "MIT License", use: String(localized: "The terminal in the notch"), url: "https://github.com/migueldeicaza/SwiftTerm")]
            + shared
            + [Entry(id: "ytdlp", name: "yt-dlp", license: String(localized: "Unlicense (only if you install it)"), use: String(localized: "Video downloads from the Tray"), url: "https://github.com/yt-dlp/yt-dlp")]
        #endif
    }()
}

/// The pages the store listing points to (the support page, the privacy policy, and the terms line of the description).
enum AboutLinks {
    static let privacy = "https://apps.v-sag.com/scout/privacy.html"
    static let terms = "https://apps.v-sag.com/scout/terms.html"
    static let support = "https://apps.v-sag.com/scout/support/"   // apps.v-sag.com/scout itself is the short link to the full page (2026-11-18)
}

struct AboutSettingsPane: View {
    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 96, height: 96)
                Text(verbatim: "Scout").font(.system(size: 26, weight: .semibold))
                Text("Version \(ScoutRuntime.version) (\(ScoutRuntime.build))")
                    .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                Text("Your agents, live in the notch.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)

            Form {
                Section {
                    aboutLink("Privacy Policy", symbol: "hand.raised", url: AboutLinks.privacy)
                    aboutLink("Terms of Use", symbol: "doc.text", url: AboutLinks.terms)
                    aboutLink("Support", symbol: "questionmark.circle", url: AboutLinks.support)
                }
                Section {
                    ForEach(AboutCredits.entries) { entry in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                Text(entry.use).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(entry.license).font(.caption).foregroundStyle(.secondary)
                                if let url = URL(string: entry.url) { Link("Website", destination: url).font(.caption) }
                            }
                        }
                    }
                } header: {
                    Text("Credits and licenses")
                } footer: {
                    SettingsFootnote("Scout's own code, words and icon are original. Everything else here is used under its own license.")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
    }

    /// One row that opens a page in the browser.
    @ViewBuilder private func aboutLink(_ title: LocalizedStringKey, symbol: String, url: String) -> some View {
        if let destination = URL(string: url) {
            Link(destination: destination) {
                HStack {
                    Label(title, systemImage: symbol)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
