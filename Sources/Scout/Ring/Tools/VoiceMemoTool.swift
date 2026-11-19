import AVFoundation
import AppKit
import SwiftUI

// B2 Voice Memo (P2): run = start recording right away (m4a in ~/Music/Scout Voice Memos), a `.recording`
// live activity with level bars + elapsed time, and a panel that lists memos with playback.
// Scripted runs simulate the recording (no microphone, no files).

struct VoiceMemo: Identifiable, Equatable {
    var id: String { url.path }
    var url: URL
    var date: Date
    var duration: TimeInterval
    var name: String { url.deletingPathExtension().lastPathComponent }
}

@MainActor
final class VoiceMemoService: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    static let shared = VoiceMemoService()

    @Published private(set) var isRecording = false
    @Published private(set) var startDate: Date?
    /// 0…1 loudness for the level bars.
    @Published private(set) var level: Float = 0
    @Published private(set) var memos: [VoiceMemo] = []
    @Published private(set) var playingID: String?

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var meterTimer: Timer?

    /// ~/Music/Scout Voice Memos (the Music entitlement in the sandbox; the container as a fallback).
    static var folder: URL { UserFolders.saveFolder(.musicDirectory, named: "Scout Voice Memos") }

    override init() {
        super.init()
        if ScoutRuntime.isScripted {
            let now = Date()
            memos = [VoiceMemo(url: URL(fileURLWithPath: "/sample/Voice Memo 2026-11-14 18.20.05.m4a"), date: now.addingTimeInterval(-3600), duration: 62),
                     VoiceMemo(url: URL(fileURLWithPath: "/sample/Voice Memo 2026-11-13 09.02.41.m4a"), date: now.addingTimeInterval(-90_000), duration: 214),
                     VoiceMemo(url: URL(fileURLWithPath: "/sample/Voice Memo 2026-11-10 21.47.12.m4a"), date: now.addingTimeInterval(-350_000), duration: 18)]
        }
    }

    // MARK: Recording

    func toggle() { isRecording ? stop() : start() }

    func start() {
        guard !isRecording else { return }
        if ScoutRuntime.isScripted { begin(simulated: true); return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: begin(simulated: false)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { MainActor.assumeIsolated { if granted { self.begin(simulated: false) } else { self.denied() } } }
            }
        default: denied()
        }
    }

    private func denied() {
        Toast.show("Allow the microphone to record voice memos", symbol: "mic.slash", style: .warning, duration: 3)
        Permissions.openSettings(.microphone)
    }

    private func begin(simulated: Bool) {
        if !simulated {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let url = Self.folder.appendingPathComponent("Voice Memo \(f.string(from: Date())).m4a")
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                                           AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
            guard let r = try? AVAudioRecorder(url: url, settings: settings) else {
                Toast.show("Couldn't start recording", symbol: "exclamationmark.triangle.fill", style: .error)
                return
            }
            r.isMeteringEnabled = true
            r.delegate = self
            guard r.record() else { Toast.show("Couldn't start recording", symbol: "exclamationmark.triangle.fill", style: .error); return }
            recorder = r
        }
        startDate = Date()
        isRecording = true
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.meter(simulated: simulated) }
        }
        postActivity()
    }

    private func meter(simulated: Bool) {
        if simulated {
            level = Float(0.25 + 0.55 * abs(sin(Date().timeIntervalSinceReferenceDate * 3.1)) * Double.random(in: 0.6...1))
        } else if let r = recorder {
            r.updateMeters()
            let db = r.averagePower(forChannel: 0)   // -160…0
            level = max(0, min(1, (db + 55) / 55))
        }
    }

    func stop() {
        guard isRecording else { return }
        meterTimer?.invalidate()
        meterTimer = nil
        let started = startDate ?? Date()
        let url = recorder?.url
        recorder?.stop()
        recorder = nil
        isRecording = false
        startDate = nil
        level = 0
        LiveActivityCenter.shared.dismiss(id: "rec.voice")
        if let url {
            let memo = VoiceMemo(url: url, date: started, duration: Date().timeIntervalSince(started))
            memos.insert(memo, at: 0)
            Toast.show("Voice memo saved", symbol: "mic.fill")
        } else {
            Toast.show("Voice memo stopped (scripted run)", symbol: "mic.fill", style: .info)
        }
    }

    private func postActivity() {
        LiveActivityCenter.shared.show(LiveActivity(id: "rec.voice", kind: .recording, onTap: { VoiceMemoService.shared.stop() }) {
            Image(systemName: "mic.fill").font(.system(size: 12)).foregroundStyle(.red)
        } trailing: {
            RecordingTrailing(service: self)
        })
    }

    // MARK: Library and playback

    func reload() {
        guard !ScoutRuntime.isScripted else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        memos = files.filter { $0.pathExtension == "m4a" }.compactMap { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let duration = (try? AVAudioPlayer(contentsOf: url))?.duration ?? 0
            return VoiceMemo(url: url, date: date, duration: duration)
        }
        .sorted { $0.date > $1.date }
    }

    func togglePlay(_ memo: VoiceMemo) {
        if playingID == memo.id { player?.stop(); player = nil; playingID = nil; return }
        guard !ScoutRuntime.isScripted else { playingID = memo.id; return }
        player?.stop()
        guard let p = try? AVAudioPlayer(contentsOf: memo.url) else { return }
        p.delegate = self
        p.play()
        player = p
        playingID = memo.id
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { MainActor.assumeIsolated { VoiceMemoService.shared.playingID = nil } }
    }

    func trash(_ memo: VoiceMemo) {
        if playingID == memo.id { player?.stop(); playingID = nil }
        if !ScoutRuntime.isScripted { try? FileManager.default.trashItem(at: memo.url, resultingItemURL: nil) }
        memos.removeAll { $0.id == memo.id }
    }
}

struct RecordingTrailing: View {
    @ObservedObject var service: VoiceMemoService

    var body: some View {
        HStack(spacing: 5) {
            LevelBars(level: service.level, tint: .red).frame(width: 18, height: 14)
            if let start = service.startDate {
                Text(timerInterval: start...Date.distantFuture, countsDown: false, showsHours: false)
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.white).frame(width: 38, alignment: .trailing)
            }
        }
    }
}

struct LevelBars: View {
    var level: Float
    var tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                let factor = [0.55, 1.0, 0.8, 0.45][i]
                RoundedRectangle(cornerRadius: 1).fill(tint)
                    .frame(width: 2.5, height: max(3, 14 * CGFloat(level) * factor))
            }
        }
        .animation(ScoutRuntime.reduceMotion ? nil : .easeOut(duration: 0.08), value: level)
    }
}

@MainActor
enum VoiceMemoTool {
    /// From the ring: start right away; a second run stops.
    static func runFromRing() {
        let s = VoiceMemoService.shared
        if s.isRecording { s.stop() } else {
            s.start()
            Toast.show("Recording… click the notch to stop", symbol: "mic.fill", style: .info)
        }
    }

    static func showPanel() {
        VoiceMemoService.shared.reload()
        ToolPanels.show("voicememo", size: CGSize(width: 360, height: 400), minSize: CGSize(width: 320, height: 300), resizable: true) {
            VoiceMemoView()
        }
    }
}

struct VoiceMemoView: View {
    @ObservedObject var service: VoiceMemoService = .shared

    var body: some View {
        ToolPanelFrame("Voice Memos", symbol: "mic.fill") {
            VStack(spacing: 10) {
                Button { service.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: service.isRecording ? "stop.fill" : "mic.fill")
                        if service.isRecording, let start = service.startDate {
                            Text(timerInterval: start...Date.distantFuture, countsDown: false, showsHours: false).monospacedDigit()
                            LevelBars(level: service.level, tint: .white).frame(width: 24, height: 14)
                        } else { Text("Record") }
                    }
                    .frame(minWidth: 150)
                }
                .buttonStyle(.borderedProminent).tint(service.isRecording ? .red : Theme.accent).controlSize(.large)
                if service.memos.isEmpty {
                    ToolEmptyState(symbol: "waveform", message: String(localized: "No voice memos yet."))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(service.memos) { memo in
                                HStack(spacing: 10) {
                                    Button { service.togglePlay(memo) } label: {
                                        Image(systemName: service.playingID == memo.id ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 24))
                                            .foregroundStyle(Theme.accent)
                                    }
                                    .buttonStyle(.plain)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(memo.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 13))
                                        Text(ProdFormat.clock(memo.duration)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                                    }
                                    Spacer()
                                    Menu {
                                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([memo.url]) }
                                        Button("Move to Trash", role: .destructive) { service.trash(memo) }
                                    } label: { Image(systemName: "ellipsis.circle") }
                                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                }
            }
            .padding(.bottom, 10)
        }
    }
}
