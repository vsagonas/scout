#if !APPSTORE
import AppKit
import SwiftUI

/// Runs `brew install yt-dlp deno` — ONLY when the user presses the button. Never started by Scout itself.
@MainActor
final class BrewInstaller: ObservableObject {
    static let shared = BrewInstaller()

    @Published private(set) var running = false
    @Published private(set) var log = ""
    @Published private(set) var finished: Bool?

    func install(packages: [String]) {
        guard !running, !ScoutRuntime.isScripted, VideoTools.hasBrew else { return }
        running = true
        finished = nil
        log = "brew install \(packages.joined(separator: " "))\n"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: VideoTools.brewPath)
        process.arguments = ["install"] + packages
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.log = String((self?.log ?? "").suffix(1800) + text) }
        }
        process.terminationHandler = { [weak self] p in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                self?.running = false
                self?.finished = p.terminationStatus == 0
            }
        }
        do { try process.run() } catch { running = false; finished = false; log += String(localized: "Couldn't start brew.") + "\n" }
    }
}

struct VideoSettingsSection: View {
    @ObservedObject private var manager = VideoManager.shared
    @ObservedObject private var brew = BrewInstaller.shared
    @AppStorage(VideoManager.Key.offer) private var offer = true
    @AppStorage(VideoManager.Key.quality) private var quality = VideoQuality.best.rawValue
    @AppStorage(VideoManager.Key.addToTray) private var addToTray = true
    @State private var confirmInstall = false

    private var missing: [String] {
        var m: [String] = []
        if VideoTools.ytdlp == nil { m.append("yt-dlp") }
        if VideoTools.deno == nil { m.append("deno") }
        if VideoTools.ffmpeg == nil { m.append("ffmpeg") }
        return m
    }

    var body: some View {
        Section {
            StatusRow(title: .verbatim("yt-dlp"), status: VideoTools.ytdlp.map { "Found · \($0.path)" } ?? "Not installed", level: VideoTools.ytdlp == nil ? .bad : .good)
            StatusRow(title: .verbatim("ffmpeg"), status: VideoTools.ffmpeg.map { "Found · \($0.path)" } ?? "Not installed", level: VideoTools.ffmpeg == nil ? .bad : .good)
            StatusRow(title: "deno (YouTube only)", status: VideoTools.deno.map { "Found · \($0.path)" } ?? "Not installed", level: VideoTools.deno == nil ? .warn : .good)
            if !missing.isEmpty {
                if VideoTools.hasBrew {
                    HStack {
                        Button(brew.running ? "Installing…" : "Install with Homebrew") { confirmInstall = true }
                            .disabled(brew.running || ScoutRuntime.isScripted)
                        if brew.running { ProgressView().controlSize(.small) }
                        if let ok = brew.finished { Label(ok ? "Done" : "That didn't work", systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(ok ? .green : .orange) }
                    }
                    .confirmationDialog("Install yt-dlp and deno with Homebrew?", isPresented: $confirmInstall) {
                        Button("Install") { brew.install(packages: ["yt-dlp", "deno"].filter(missing.contains)) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This runs “brew install \(["yt-dlp", "deno"].filter(missing.contains).joined(separator: " "))” on your Mac. It only happens because you pressed the button.")
                    }
                    if !brew.log.isEmpty {
                        Text(brew.log.suffix(500)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(6)
                    }
                } else {
                    Text("Homebrew isn't installed. Install yt-dlp, deno and ffmpeg yourself, then reopen this page.").foregroundStyle(.secondary)
                }
            }
            Picker("Default quality", selection: $quality) {
                ForEach(VideoQuality.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Toggle("Offer to download a copied video link when the Tray opens", isOn: $offer)
            Toggle("Put finished videos in the Tray", isOn: $addToTray)
            LabeledContent("Saved in") {
                Button("Movies › Scout Videos") { if !ScoutRuntime.isScripted { try? FileManager.default.createDirectory(at: VideoTools.videosFolder, withIntermediateDirectories: true); NSWorkspace.shared.open(VideoTools.videosFolder) } }
            }
        } header: {
            Text("Video downloads")
        } footer: {
            SettingsNote("Copy a link from YouTube, X, Instagram, TikTok, Vimeo or Reddit, open the Tray and Scout offers to download it, or drop a link on the Tray. Downloads use yt-dlp, which you install yourself; the button above only runs when you press it. Reading a copied link needs “Allow” for Scout under System Settings › Privacy & Security › Paste from Other Apps (macOS 15.4 and later).")
        }

        Section("Recent downloads") {
            if manager.history.isEmpty {
                Text("Nothing downloaded yet.").foregroundStyle(.secondary)
            } else {
                ForEach(manager.history) { h in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(h.title).lineLimit(1)
                            Text("\(h.service) · \(VideoQuality(stored: h.quality)?.title ?? h.quality) · \(h.date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Show") { if !ScoutRuntime.isScripted { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: h.path)]) } }.controlSize(.small)
                        Button { manager.removeHistory(h.id) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
#endif
