import Combine
import SwiftUI

// live.recording: while the screen recorder runs. Red dot, elapsed time, whether the microphone is on, and Stop.

struct LiveRecordingSnapshot: Equatable {
    var isRecording = false
    var startDate: Date?
    var withMic = false
}

@MainActor
final class LiveRecordingPanel: LiveDriven {
    let id = "live.recording"
    let title = String(localized: "Recording")
    let symbol = "record.circle.fill"
    let priority = 100
    let span = 4
    let expandTo: WorkspaceKind? = nil

    let feed: LiveFeed<LiveRecordingSnapshot>
    private let clock: () -> Date
    private let stop: () -> Void

    var changes: AnyPublisher<Void, Never> { feed.changes }
    var isLive: Bool { feed.value.isRecording }

    init(feed: LiveFeed<LiveRecordingSnapshot>, clock: @escaping () -> Date = Date.init, stop: @escaping () -> Void) {
        self.feed = feed
        self.clock = clock
        self.stop = stop
    }

    static func live() -> LiveRecordingPanel {
        let recorder = ScreenRecorder.shared
        let feed = LiveFeed<LiveRecordingSnapshot>(read: {
            LiveRecordingSnapshot(isRecording: recorder.isRecording, startDate: recorder.startDate, withMic: recorder.withMic)
        }, triggers: [recorder.liveTrigger])
        return LiveRecordingPanel(feed: feed) { ScreenRecorder.shared.stop() }
    }

    func makeView() -> AnyView { AnyView(LiveRecordingView(feed: feed, clock: clock, stop: stop)) }
}

// MARK: - View

/// A VHS camcorder's readout: "● REC" with the elapsed time in segments. Here REC is true: the screen recorder runs.
struct LiveRecordingView: View {
    @ObservedObject var feed: LiveFeed<LiveRecordingSnapshot>
    var clock: () -> Date = Date.init
    var stop: () -> Void
    @State private var dim = false

    var body: some View {
        if Retro.is8bit { retroBody } else { minimalBody }
    }

    /// The minimal look: a plain red dot and the elapsed time in the system font, Stop as a plain button.
    private var minimalBody: some View {
        let s = feed.value
        return LiveRetroFrame(symbol: "record.circle.fill", title: "Recording", short: "Rec", tint: Retro.Ink.red, trailing: {
            HStack(spacing: 3) {
                Image(systemName: s.withMic ? "mic.fill" : "mic.slash.fill").font(.system(size: 9))
                LiveRetroFact(text: s.withMic ? String(localized: "Mic on") : String(localized: "No mic"))
            }
            .foregroundStyle(Retro.quietInk)
        }) {
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Circle().fill(Color(red: 1.0, green: 0.27, blue: 0.23)).frame(width: 8, height: 8)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    MiniDigits(text: ProdFormat.clock(s.startDate.map { clock().timeIntervalSince($0) } ?? 0), size: 30)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            Button { stop() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill").font(.system(size: 9)).foregroundStyle(Color(red: 1.0, green: 0.27, blue: 0.23))
                    Text("Stop")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.notchPill).liveControl()
        }
    }

    private var retroBody: some View {
        let s = feed.value
        return LiveRetroFrame(symbol: "record.circle.fill", title: "Recording", short: "Rec", tint: Retro.Ink.red, trailing: {
            HStack(spacing: 3) {
                Image(systemName: s.withMic ? "mic.fill" : "mic.slash.fill").font(.system(size: 8))
                LiveRetroFact(text: s.withMic ? String(localized: "Mic on") : String(localized: "No mic"), color: s.withMic ? Look.osd : Look.osd.opacity(0.6))
            }
            .foregroundStyle(s.withMic ? Look.ink(1) : Look.ink(0.6))
        }) {
            Spacer(minLength: 0)
            Dash90LCD(padding: 6) {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Circle().fill(Retro.Ink.ledRed).frame(width: 10, height: 10)
                            .shadow(color: Retro.Ink.ledRed.opacity(0.8), radius: 3)
                            .opacity(dim ? 0.3 : 1)
                            .animation(pulses ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : nil, value: dim)
                        if Look.isLight { RetroPixelText("REC", pixel: 2, color: Retro.Ink.ledRed) } else { RetroOSD("REC", pixel: 2, color: Retro.Ink.ledRed) }   // the OSD's black outline reads as a black chip on the light well
                    }
                    Spacer(minLength: 0)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Dash90Digits(text: ProdFormat.clock(s.startDate.map { clock().timeIntervalSince($0) } ?? 0), big: 26)
                    }
                }
            }
            Spacer(minLength: 0)
            Button { stop() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill").font(.system(size: 9))
                    Text("Stop")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.retro(tint: Retro.Ink.red)).liveControl()
        }
        .onAppear { if pulses { dim = true } }
    }

    /// The dot breathes, unless Reduce Motion is on or this is a still render.
    private var pulses: Bool { !ScoutRuntime.reduceMotion && !ScoutRuntime.isScripted }
}
