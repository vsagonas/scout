import Foundation

/// A download in progress, seen as a partial file in the Downloads folder.
struct PartialDownload: Equatable {
    enum Source { case chromium, safari, firefox }

    var path: String
    var displayName: String      // the final name (the partial's extension removed)
    var bytes: Int64
    var total: Int64?            // only Safari knows it
    var source: Source

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(bytes) / Double(total))
    }
}

/// Reads partial downloads: `.crdownload` (Chrome, Arc, Edge, Brave), `.download` bundles (Safari),
/// `.part` (Firefox) and `.opdownload` (Opera). Only file names and sizes are read.
enum DownloadProbe {
    static let partialExtensions = ["crdownload", "download", "part", "opdownload"]

    static func isPartial(_ url: URL) -> Bool { partialExtensions.contains(url.pathExtension.lowercased()) }

    static func scan(_ directory: URL) -> [PartialDownload] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var found: [PartialDownload] = []
        for url in urls where isPartial(url) {
            let ext = url.pathExtension.lowercased()
            let name = url.deletingPathExtension().lastPathComponent
            if ext == "download" {
                // Safari: a bundle whose Info.plist holds the progress.
                let plistURL = url.appendingPathComponent("Info.plist")
                guard let data = try? Data(contentsOf: plistURL),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    found.append(PartialDownload(path: url.path, displayName: name, bytes: 0, total: nil, source: .safari))
                    continue
                }
                let so = (plist["DownloadEntryProgressBytesSoFar"] as? NSNumber)?.int64Value ?? 0
                let total = (plist["DownloadEntryProgressTotalToLoad"] as? NSNumber)?.int64Value
                found.append(PartialDownload(path: url.path, displayName: name, bytes: so, total: (total ?? 0) > 0 ? total : nil, source: .safari))
            } else {
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                found.append(PartialDownload(path: url.path, displayName: name, bytes: size, total: nil, source: ext == "part" ? .firefox : .chromium))
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// The finished file for a partial that just vanished: the same name without the extension, or (Chrome
    /// renames "Unconfirmed 123.crdownload" to the real name) the newest fresh file of about the same size.
    static func finishedFile(for partial: PartialDownload, in directory: URL, now: Date = Date()) -> URL? {
        let fm = FileManager.default
        let exact = directory.appendingPathComponent(partial.displayName)
        if fm.fileExists(atPath: exact.path) { return exact }
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        let candidates = urls.filter { !isPartial($0) }.compactMap { url -> (URL, Date, Int64)? in
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), let date = v.contentModificationDate else { return nil }
            return (url, date, Int64(v.fileSize ?? 0))
        }.filter { now.timeIntervalSince($0.1) < 20 && ($0.2 >= Int64(Double(partial.bytes) * 0.9)) }
        return candidates.max { $0.1 < $1.1 }?.0
    }
}
