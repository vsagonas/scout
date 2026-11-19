import AVFoundation
import AppKit
import ScreenCaptureKit
import SwiftUI

// B2 Screen Record (P2): ScreenCaptureKit + SCRecordingOutput (macOS 15+); macOS 14 falls back to
// `screencapture -v`. Saved to ~/Movies/Scout Recordings/. A `.recording` activity with elapsed time and stop.
// Scripted runs simulate it (no capture, no files).

@MainActor
final class ScreenRecorder: NSObject, ObservableObject {
    static let shared = ScreenRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var startDate: Date?
    @Published private(set) var withMic = false

    private var stream: AnyObject?          // SCStream (macOS 15 path)
    private var recordingOutput: AnyObject?
    private var outputDelegate: AnyObject?
    #if !APPSTORE
    private var fallbackProcess: Process?
    #endif
    private var outputURL: URL?

    /// ~/Movies/Scout Recordings (the Movies entitlement in the sandbox; the container as a fallback).
    static var folder: URL { UserFolders.saveFolder(.moviesDirectory, named: "Scout Recordings") }

    private func newURL() -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return Self.folder.appendingPathComponent("Scout Recording \(f.string(from: Date())).mov")
    }

    func toggle(_ mode: ScreenRecordTool.Mode) { isRecording ? stop() : start(mode) }

    func start(_ mode: ScreenRecordTool.Mode) {
        guard !isRecording else { return }
        if ScoutRuntime.isScripted {
            begin(mic: mode == .mic, url: nil)
            return
        }
        if #available(macOS 15.0, *) {
            Task { await startKit(mode: mode, url: newURL()) }
        } else {
            #if APPSTORE
            Toast.show("Screen recording needs macOS 15 or later", symbol: "record.circle", style: .info, duration: 3)
            #else
            startFallback(mic: mode == .mic, url: newURL())
            #endif
        }
    }

    private func begin(mic: Bool, url: URL?) {
        outputURL = url
        withMic = mic
        startDate = Date()
        isRecording = true
        LiveActivityCenter.shared.show(LiveActivity(id: "rec.screen", kind: .recording, onTap: { ScreenRecorder.shared.stop() }) {
            Image(systemName: "record.circle.fill").font(.system(size: 13)).foregroundStyle(.red)
        } trailing: {
            ScreenRecordingTrailing(recorder: self)
        })
    }

    func stop() {
        guard isRecording else { return }
        let url = outputURL
        isRecording = false
        startDate = nil
        LiveActivityCenter.shared.dismiss(id: "rec.screen")
        #if !APPSTORE
        if let p = fallbackProcess {
            p.interrupt()   // SIGINT: screencapture finishes the file
            fallbackProcess = nil
            finished(url)
            return
        }
        #endif
        if #available(macOS 15.0, *), let s = stream as? SCStream {
            Task {
                try? await s.stopCapture()
                if let out = recordingOutput as? SCRecordingOutput { try? s.removeRecordingOutput(out) }
                stream = nil
                recordingOutput = nil
                outputDelegate = nil
                finished(url)
            }
        } else {
            finished(url)
        }
    }

    private func finished(_ url: URL?) {
        guard let url else { Toast.show("Screen recording stopped (scripted run)", symbol: "record.circle", style: .info); return }
        LiveActivityCenter.shared.present(NotchCard(id: "toast", duration: 4, onTap: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) {
            HStack(spacing: 10) {
                Image(systemName: "record.circle").font(.system(size: 20)).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Recording saved").font(.system(size: 13, weight: .medium))
                    Text("Click to show in Finder").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
        })
    }

    // MARK: macOS 14 fallback (not in the App Store edition, which does not run /usr/sbin/screencapture)

    #if !APPSTORE
    private func startFallback(mic: Bool, url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = (mic ? ["-v", "-g", "-x"] : ["-v", "-x"]) + [url.path]
        do { try p.run() } catch {
            Toast.show("Couldn't start the screen recording", symbol: "exclamationmark.triangle.fill", style: .error)
            return
        }
        fallbackProcess = p
        begin(mic: mic, url: url)
    }
    #endif

    // MARK: ScreenCaptureKit (macOS 15+)

    @available(macOS 15.0, *)
    private func startKit(mode: ScreenRecordTool.Mode, url: URL) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let mainID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
                Toast.show("No display to record", symbol: "display", style: .error)
                return
            }
            var filter = SCContentFilter(display: display, excludingWindows: [])
            var width = display.width, height = display.height
            if mode == .window {
                let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let window = content.windows
                    .filter { $0.owningApplication?.processID == pid && $0.isOnScreen && $0.frame.width > 120 && $0.frame.height > 120 }
                    .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
                guard let window else { Toast.show("No window to record", symbol: "macwindow", style: .info); return }
                filter = SCContentFilter(desktopIndependentWindow: window)
                width = Int(window.frame.width); height = Int(window.frame.height)
            }
            let scale = Int(NSScreen.main?.backingScaleFactor ?? 2)
            let config = SCStreamConfiguration()
            config.width = width * scale
            config.height = height * scale
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.showsCursor = true
            if mode == .mic { config.captureMicrophone = true }
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            let outConfig = SCRecordingOutputConfiguration()
            outConfig.outputURL = url
            outConfig.outputFileType = .mov
            outConfig.videoCodecType = .h264
            let delegate = RecordingDelegate()
            let output = SCRecordingOutput(configuration: outConfig, delegate: delegate)
            outputDelegate = delegate
            try stream.addRecordingOutput(output)
            try await stream.startCapture()
            self.stream = stream
            self.recordingOutput = output
            begin(mic: mode == .mic, url: url)
        } catch {
            Toast.show("Allow Screen Recording in System Settings to record", symbol: "lock.shield", style: .warning, duration: 3)
            Permissions.openSettings(.screenRecording)
        }
    }
}

@available(macOS 15.0, *)
final class RecordingDelegate: NSObject, SCRecordingOutputDelegate {}

struct ScreenRecordingTrailing: View {
    @ObservedObject var recorder: ScreenRecorder

    var body: some View {
        HStack(spacing: 5) {
            if recorder.withMic { Image(systemName: "mic.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.8)) }
            if let start = recorder.startDate {
                Text(timerInterval: start...Date.distantFuture, countsDown: false, showsHours: false)
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.white).frame(width: 38, alignment: .trailing)
            }
        }
    }
}

@MainActor
enum ScreenRecordTool {
    enum Mode: String, CaseIterable {
        case screen, window, mic
    }

    /// Starts a recording, or stops the one that is running.
    static func start(_ mode: Mode) {
        ScreenRecorder.shared.toggle(mode)
        if ScreenRecorder.shared.isRecording == false, !ScoutRuntime.isScripted {
            // The recording starts asynchronously; the live activity shows the state.
        }
    }
}
