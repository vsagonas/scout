import AVFoundation
import EventKit
import CoreLocation
import os
import Speech
import SwiftUI

/// `scout://sandbox.report`: tries, one by one, the things the features' features need from the system and shows what
/// worked. It never asks for a permission and never uses the network. Meant for checking the sandboxed edition
/// (a sandboxed app's container is hidden from other processes, so a window is the way to see the results).
@MainActor
enum SandboxReport {
    struct Row: Identifiable {
        let id = UUID()
        let name: String
        let ok: Bool
        let detail: String
    }

    static func run() -> [Row] {
        var rows: [Row] = []
        func add(_ name: String, _ ok: Bool, _ detail: String) { rows.append(Row(name: name, ok: ok, detail: detail)) }
        let fm = FileManager.default

        // Where are we?
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        add("Edition", true, "\(Edition.name), \(sandboxed ? "sandboxed" : "not sandboxed")")

        // Own folder (the container).
        let probe = AppPaths.file("sandbox-probe.txt")
        let wrote = (try? "ok".write(to: probe, atomically: true, encoding: .utf8)) != nil
        add("Write in Scout's own folder", wrote, AppPaths.support.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))

        // Security-scoped bookmark round trip (Tray and Pockets rely on it).
        if wrote {
            let bookmark = try? probe.bookmarkData(options: FileScope.creation, includingResourceValuesForKeys: nil, relativeTo: nil)
            var stale = false
            let resolved = bookmark.flatMap { try? URL(resolvingBookmarkData: $0, options: FileScope.resolution, relativeTo: nil, bookmarkDataIsStale: &stale) }
            if let resolved { FileScope.begin(resolved) }
            let readBack = resolved.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            if let resolved { FileScope.end(resolved) }
            add("Security-scoped bookmark (Tray, Pockets)", readBack == "ok", bookmark == nil ? "couldn't make a bookmark" : (readBack == "ok" ? "made, resolved and read back" : "resolved but unreadable"))
        }

        // Downloads (progress watcher, conversion results). Only the sandboxed edition has this entitlement; the
        // full edition would raise a macOS folder prompt, so it skips the check.
        if sandboxed {
            let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            do {
                let names = try fm.contentsOfDirectory(atPath: downloads.path)
                add("Read the Downloads folder", true, "\(names.count) items")
                let test = downloads.appendingPathComponent("Scout sandbox check.txt")
                let wroteDownloads = (try? "x".write(to: test, atomically: true, encoding: .utf8)) != nil
                if wroteDownloads { try? fm.removeItem(at: test) }
                add("Write in Downloads (conversion results)", wroteDownloads, wroteDownloads ? "wrote and removed a test file" : "not allowed")
                // The download watcher: a folder watch plus the partial-file scan.
                let fd = open(downloads.path, O_EVTONLY)
                if fd >= 0 {
                    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
                    source.setEventHandler {}
                    source.resume()
                    source.cancel()
                    close(fd)
                }
                add("Download watcher (folder watch + partial scan)", fd >= 0, "watch \(fd >= 0 ? "opened" : "refused"), \(DownloadProbe.scan(downloads).count) downloads in progress")
            } catch {
                add("Read the Downloads folder", false, error.localizedDescription)
            }
        } else {
            add("Downloads folder", true, "skipped (not sandboxed: macOS would ask)")
        }

        // Pulse
        let pulse = PulseSampler()
        pulse.sampleNow()
        Thread.sleep(forTimeInterval: 0.3)
        pulse.sampleNow()
        let p = pulse.latest
        add("Pulse: CPU, memory, disk", p.memory > 0 && p.disk > 0, "memory \(Int(p.memory * 100))%, disk \(Int(p.disk * 100))%")
        add("Pulse: GPU counters", pulse.gpuReadable(), pulse.gpuReadable() ? "readable" : "blocked, the widget hides GPU")
        add("Pulse: battery", p.battery != nil, p.battery.map { "\(Int($0 * 100))%" } ?? "none on this Mac")
        add("Pulse: network counters", true, "↓ \(Int(p.netDown)) B/s")

        // Permissions and devices (status only, no prompts).
        let cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
        add("Mirror: cameras found", !cameras.isEmpty, "\(cameras.count) (access: \(statusName(AVCaptureDevice.authorizationStatus(for: .video).rawValue)))")
        add("Prompter: microphone", true, "access: \(statusName(AVCaptureDevice.authorizationStatus(for: .audio).rawValue))")
        add("Prompter: speech models", !SFSpeechRecognizer.supportedLocales().isEmpty, "\(SFSpeechRecognizer.supportedLocales().count) languages, access: \(statusName(SFSpeechRecognizer.authorizationStatus().rawValue))")
        add("Calendar", true, "access: \(statusName(EKEventStore.authorizationStatus(for: .event).rawValue))")
        add("Weather: location", CLLocationManager.locationServicesEnabled(), "services on: \(CLLocationManager.locationServicesEnabled()), access: \(statusName(Int(CLLocationManager().authorizationStatus.rawValue)))")

        // Conversions (ImageIO, PDFKit, AVFoundation and the built-in ZIP writer), into Scout's own folder.
        let work = AppPaths.folder("SandboxCheck")
        try? fm.removeItem(at: work)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let samples = TraySamples.makeFiles()
        for (title, format) in [("JPEG", ConvertFormat.jpeg), ("HEIC", .heic), ("TIFF", .tiff), ("PDF", .pdf), ("ZIP", .zip)] {
            let sources = format.id == "zip" ? [samples[3], samples[4]] : (format.id == "pdf" ? [samples[0], samples[1]] : [samples[0]])
            switch FeaturesSelfTest.block({ try await Converter.convert(sources, to: format) { _ in work } }) {
            case .success(let out):
                let size = (try? fm.attributesOfItem(atPath: out[0].path)[.size] as? Int) ?? 0
                var ok = size > 100
                var extra = "\(size) bytes"
                if format.id == "zip" { let names = ZipWriter.verify(out[0]); ok = ok && names?.count == 2; extra += ", entries: \(names?.joined(separator: ", ") ?? "invalid")" }
                add("Convert to \(title)", ok, extra)
            case .failure(let error):
                add("Convert to \(title)", false, error.localizedDescription)
            }
        }

        // Shortcuts link
        add("Shortcuts link", ShortcutsService.runURL(for: "Morning routine")?.absoluteString == "shortcuts://run-shortcut?name=Morning%20routine",
            ShortcutsService.runURL(for: "Morning routine")?.absoluteString ?? "nil")
        return rows
    }

    private static func statusName(_ raw: Int) -> String {
        switch raw {
        case 0: "not asked"
        case 1: "restricted"
        case 2: "denied"
        case 3: "allowed"
        case 4: "allowed"
        default: "\(raw)"
        }
    }

    static func show() {
        let rows = run()
        let text = rows.map { "\($0.ok ? "ok  " : "FAIL") \($0.name): \($0.detail)" }.joined(separator: "\n")
        try? text.write(to: AppPaths.file("sandbox-report.txt"), atomically: true, encoding: .utf8)
        // The container of a sandboxed app is hidden from other processes: the unified log is how a check reads it.
        let logger = Logger(subsystem: "com.vsag.Scout", category: "sandbox-report")
        for row in rows { logger.notice("\(row.ok ? "ok" : "FAIL", privacy: .public) \(row.name, privacy: .public): \(row.detail, privacy: .public)") }
        Panels.show(id: "sandbox.report", options: Panels.Options(size: CGSize(width: 560, height: CGFloat(80 + rows.count * 26)), resizable: false, position: .center)) {
            SandboxReportView(rows: rows).background(GlassBackground(cornerRadius: 16))
        }
    }
}

struct SandboxReportView: View {
    let rows: [SandboxReport.Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(verbatim: "Sandbox check (\(Edition.name) edition)", symbol: "checkmark.shield")
            VStack(alignment: .leading, spacing: 5) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: row.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(row.ok ? Color.green : Color.red).frame(width: 16)
                        Text(row.name).font(.system(size: 12, weight: .semibold))
                        Text(row.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 12)
            Spacer(minLength: 0)
        }
    }
}
