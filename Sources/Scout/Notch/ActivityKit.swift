import SwiftUI

// Small building blocks for the wings of the closed notch, and sample activities for every kind
// (used by `scout://activity.demo` and the gallery; the real posters live in each module).

struct WingIcon: View {
    let symbol: String
    var tint: Color = .white
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 22, height: 22)
    }
}

struct WingText: View {
    let text: Text
    /// `WingText(text: "Soon")` localizes a literal; `WingText(verbatim: "12:30")` shows a string as it is (numbers, names, text already made).
    init(text: LocalizedStringKey, tint: Color = .white, rounded: Bool = true) { self.text = Text(text); self.tint = tint; self.rounded = rounded }
    init(verbatim: String, tint: Color = .white, rounded: Bool = true) { self.text = Text(verbatim: verbatim); self.tint = tint; self.rounded = rounded }
    var tint: Color = .white
    var rounded = true

    var body: some View {
        text
            .font(.system(size: 12, weight: .semibold, design: rounded ? .rounded : .default))
            .monospacedDigit()
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}

struct WingRing: View {
    var progress: Double?
    var tint: Color = Theme.accent
    var symbol: String?
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 2.2)
            if let progress {
                Circle().trim(from: 0, to: max(0.02, min(1, progress)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if let symbol {
                Image(systemName: symbol).font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

/// A row of segments, like the volume HUD bar.
struct SegmentBar: View {
    var value: Double
    var segments = 12
    var tint: Color = .white
    var height: CGFloat = 5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                Capsule()
                    .fill(Double(i) < value * Double(segments) - 0.01 ? tint : Color.white.opacity(0.22))
                    .frame(height: height)
            }
        }
    }
}

/// Sample activities for the gallery and the `activity.demo` debug command: never shown to a person, so their words are verbatim (no keys).
enum SampleActivities {
    @MainActor
    static func make(_ kind: LiveActivityKind, expiresAfter: TimeInterval? = nil) -> LiveActivity {
        switch kind {
        case .media:
            return MediaActivity.make(track: NowPlayingService.sampleTrack, expiresAfter: expiresAfter)
        case .radio:
            return RadioNotchPresenter.sample()
        case .hud:
            return HUDActivity.make(kind: .volume, value: 0.6, muted: false, service: VolumeService(), expiresAfter: expiresAfter)
        case .battery:
            return BatteryActivity.make(state: .sample, expiresAfter: expiresAfter)
        case .bluetooth:
            return BluetoothActivity.make(info: .airPodsPro, expiresAfter: expiresAfter)
        case .announcement:
            return LEDAnnouncements.sampleActivity(expiresAfter: expiresAfter)
        case .ai:
            return LiveActivity(id: "demo.ai", kind: kind, expiresAfter: expiresAfter) {
                WingIcon(symbol: "sparkles", tint: Theme.accent)
            } trailing: {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 20, height: 20)
            }.withDetail { DemoDetail(title: Text(verbatim: "Ask AI is answering"), subtitle: Text(verbatim: "What's the capital of Peru?")) }
        #if !APPSTORE
        case .agent:
            return LiveActivity(id: "demo.agent", kind: kind, expiresAfter: expiresAfter) {
                WingIcon(symbol: "sparkles", tint: Theme.accent)
            } trailing: {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 20, height: 20)
            }.withDetail { DemoDetail(title: Text(verbatim: "Claude Code is working"), subtitle: Text(verbatim: "scout · Editing NotchView.swift")) }
        case .message:
            return LiveActivity(id: "demo.message", kind: kind, expiresAfter: expiresAfter) {
                WingIcon(symbol: "message.fill", tint: .green)
            } trailing: {
                WingText(verbatim: "2")
            }.withDetail { DemoDetail(title: Text(verbatim: "Maya"), subtitle: Text(verbatim: "Are we still on for lunch?")) }
        #endif
        case .calendar:
            return LiveActivity(id: "demo.calendar", kind: kind, expiresAfter: expiresAfter) {
                WingIcon(symbol: "calendar", tint: .red)
            } trailing: {
                WingText(verbatim: "in 10 min")
            }.withDetail { DemoDetail(title: Text(verbatim: "Design review"), subtitle: Text(verbatim: "11:00 – 11:45 · Zoom")) }
        case .timer:
            return LiveActivity(id: "demo.timer", kind: kind, expiresAfter: expiresAfter) {
                WingIcon(symbol: "timer", tint: Theme.accent)
            } trailing: {
                WingText(verbatim: "04:32")
            }.withDetail { DemoDetail(title: Text(verbatim: "Tea"), subtitle: Text(verbatim: "5 min timer")) }
        case .pomodoro:
            return LiveActivity(id: "demo.pomodoro", kind: kind, expiresAfter: expiresAfter) {
                WingIcon(symbol: "leaf.fill", tint: .green)
            } trailing: {
                WingText(verbatim: "18:20")
            }.withDetail { DemoDetail(title: Text(verbatim: "Focus"), subtitle: Text(verbatim: "Session 2 of 4")) }
        case .recording:
            return LiveActivity(id: "demo.recording", kind: kind, expiresAfter: expiresAfter) {
                Circle().fill(Color.red).frame(width: 9, height: 9).frame(width: 22, height: 22)
            } trailing: {
                WingText(verbatim: "0:42")
            }.withDetail { DemoDetail(title: Text(verbatim: "Recording the screen"), subtitle: Text(verbatim: "Click to stop")) }
        case .download:
            return LiveActivity(id: "demo.download", kind: kind, expiresAfter: expiresAfter) {
                WingIcon(symbol: "doc.zipper", tint: .white.opacity(0.9))
            } trailing: {
                WingRing(progress: 0.64)
            }.withDetail { DemoDetail(title: Text(verbatim: "Scout-0.1.0.zip"), subtitle: Text(verbatim: "64 % · 48 MB of 75 MB")) }
        #if !APPSTORE
        case .video:
            return LiveActivity(id: "demo.video", kind: kind, expiresAfter: expiresAfter) {
                WingIcon(symbol: "play.rectangle.fill", tint: .white.opacity(0.9))
            } trailing: {
                WingRing(progress: 0.3)
            }.withDetail { DemoDetail(title: Text(verbatim: "Downloading video"), subtitle: Text(verbatim: "30 % · 1080p")) }
        #endif
        case .conversion:
            return LiveActivity(id: "demo.conversion", kind: kind, expiresAfter: expiresAfter) {
                WingIcon(symbol: "arrow.triangle.2.circlepath", tint: .cyan)
            } trailing: {
                WingText(verbatim: "HEIC → PNG", rounded: false)
            }.withDetail { DemoDetail(title: Text(verbatim: "Converting 3 images"), subtitle: Text(verbatim: "Almost done")) }
        case .tray:
            return LiveActivity(id: "demo.tray", kind: kind, expiresAfter: expiresAfter) {
                WingIcon(symbol: "tray.full.fill", tint: Theme.accent)
            } trailing: {
                WingText(verbatim: "3")
            }.withDetail { DemoDetail(title: Text(verbatim: "Tray"), subtitle: Text(verbatim: "3 files waiting")) }
        #if !APPSTORE
        case .update:
            return LiveActivity(id: "demo.update", kind: kind, expiresAfter: expiresAfter) {
                WingIcon(symbol: "arrow.down.app.fill", tint: .blue)
            } trailing: {
                WingText(verbatim: "New", rounded: false)
            }.withDetail { DemoDetail(title: Text(verbatim: "Scout 0.2.0 is ready"), subtitle: Text(verbatim: "Click to read what's new")) }
        #endif
        #if APPSTORE
        case .agent, .message, .video, .update:
            // Left out of the App Store edition (the lists never offer them); a plain placeholder keeps the switch complete.
            return LiveActivity(id: "demo.unavailable", kind: kind, expiresAfter: expiresAfter) {
                WingIcon(symbol: "questionmark", tint: .white)
            } trailing: {
                WingText(verbatim: "–")
            }
        #endif
        }
    }
}

struct DemoDetail: View {
    let title: Text
    let subtitle: Text

    /// `DemoDetail(title: "Converting")` localizes a literal; `DemoDetail(title: Text(verbatim: name), subtitle: Text(verbatim: line))` shows made strings.
    init(title: Text, subtitle: Text) { self.title = title; self.subtitle = subtitle }
    init(title: LocalizedStringKey, subtitle: LocalizedStringKey) { self.title = Text(title); self.subtitle = Text(subtitle) }

    var body: some View {
        VStack(spacing: 1) {
            title.font(.system(size: 12, weight: .semibold)).lineLimit(1)
            subtitle.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .foregroundStyle(.white)
    }
}
