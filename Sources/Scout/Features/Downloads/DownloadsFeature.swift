import SwiftUI

@MainActor
enum DownloadsFeature {
    static func start() {
        DownloadsWatcher.shared.start()
        DebugCommands.register("download.demo") { params in
            if let style = params["style"] { Pref.set(style, DownloadsWatcher.Key.style) }
            DownloadsWatcher.shared.demo(seconds: Double(params["seconds"] ?? "") ?? 6, indeterminate: params["indeterminate"] == "1")
        }
    }

    static func registerSelfTests() {
        FeaturesSelfTest.add("downloads: chrome, safari and firefox partials are read") {
            let dir = AppPaths.folder("SelfTest").appendingPathComponent("Downloads", isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Data(count: 5000).write(to: dir.appendingPathComponent("Unconfirmed 1.crdownload"))
            try? Data(count: 1234).write(to: dir.appendingPathComponent("video.mp4.part"))
            let bundle = dir.appendingPathComponent("movie.mov.download", isDirectory: true)
            try? FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            let plist: [String: Any] = ["DownloadEntryProgressBytesSoFar": 2_000_000, "DownloadEntryProgressTotalToLoad": 8_000_000]
            try? (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))?.write(to: bundle.appendingPathComponent("Info.plist"))
            try? Data(count: 10).write(to: dir.appendingPathComponent("notes.txt"))
            let found = DownloadProbe.scan(dir)
            guard found.count == 3,
                  let safari = found.first(where: { $0.source == .safari }), safari.displayName == "movie.mov", safari.fraction == 0.25,
                  let chrome = found.first(where: { $0.source == .chromium }), chrome.bytes == 5000, chrome.fraction == nil,
                  let ff = found.first(where: { $0.source == .firefox }), ff.displayName == "video.mp4" else { return false }
            // Finished: the partial vanishes and the final file shows up.
            try? Data(count: 1300).write(to: dir.appendingPathComponent("video.mp4"))
            if DownloadProbe.finishedFile(for: ff, in: dir)?.lastPathComponent != "video.mp4" { return false }
            // Chrome renames "Unconfirmed 1.crdownload" to the real name.
            try? Data(count: 5200).write(to: dir.appendingPathComponent("Real name.zip"))
            return DownloadProbe.finishedFile(for: chrome, in: dir)?.lastPathComponent == "Real name.zip"
        }
    }

    static func registerGallery() {
        func wings(_ name: String, id: String, style: DownloadStyle, fraction: Double?) {
            Gallery.register(name, size: CGSize(width: 420, height: 90), backdrop: .screenTop) {
                let partial = PartialDownload(path: "/x", displayName: "Quarterly report.pdf", bytes: Int64((fraction ?? 0.3) * 48_000_000), total: fraction == nil ? nil : 48_000_000, source: .safari)
                let a = DownloadsWatcher.activity(for: DownloadsWatcher.Tracked(partial: partial), id: id, style: style)
                ZStack {
                    Capsule().fill(Color.black).frame(width: 330, height: 34)
                    HStack { a.leading; Spacer().frame(width: 190); a.trailing }
                }
            }
        }
        wings("download-wings-ring", id: "r", style: .ring, fraction: 0.62)
        wings("download-wings-file", id: "f", style: .file, fraction: 0.62)
        wings("download-wings-bar", id: "b", style: .bar, fraction: 0.62)
        wings("download-wings-indeterminate", id: "i", style: .ring, fraction: nil)
        FeatureGallery.settings("settings-downloads", height: Edition.isAppStore ? 640 : 1250) { DownloadsSettingsPane() }
        Gallery.register("download-card", size: CGSize(width: 400, height: 90)) {
            DownloadFinishedCard(name: "Quarterly report.pdf", size: 48_000_000).background(GlassBackground(cornerRadius: 22))
        }
    }
}
