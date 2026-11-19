import SwiftUI

/// The Mac's CPU and memory as two small labelled LED bars (the kit's `RetroLEDBar`), on the Agent TV's glass and on the den's wall.
/// The numbers come from `PulseSampler.shared`, the sampler the Pulse panel uses (no second one), and it holds the sampler only while
/// it is on screen and the notch is open (a gallery picture takes one reading too).
struct AgentTVLoadBars: View {
    enum Labels { case full, letters }

    var labels: Labels = .full
    var bar = CGSize(width: 30, height: 8)
    var segments = 6
    var pixel: CGFloat = 1
    var spacing: CGFloat = 5
    var vertical = false
    /// A fixed reading for pictures (cpu, memory), 0 to 1; nil reads the sampler.
    var fixed: (cpu: Double, memory: Double)?

    @ObservedObject private var sampler = PulseSampler.shared
    @Environment(\.notchNavigator) private var navigator
    @State private var appeared = false
    @State private var holding = false

    private var ready: Bool { (sampler.history[.cpu]?.count ?? 0) >= 2 }   // the first CPU reading has nothing to compare with

    private func value(_ metric: PulseMetric) -> Double {
        if let fixed { return metric == .cpu ? fixed.cpu : fixed.memory }
        guard ready else { return 0 }
        return min(1, max(0, metric == .cpu ? sampler.latest.cpu : sampler.latest.memory))
    }

    private func percent(_ metric: PulseMetric) -> String {
        guard fixed != nil || ready else { return "–" }
        return "\(Int((value(metric) * 100).rounded()))"
    }

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing)) : AnyLayout(HStackLayout(spacing: spacing))
        layout {
            meter(.cpu, labels == .full ? "CPU" : "C")
            meter(.memory, labels == .full ? "MEM" : "M")
        }
        .help("Your Mac right now: processor \(percent(.cpu))%, memory \(percent(.memory))%")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mac load: processor \(percent(.cpu)) percent, memory \(percent(.memory)) percent")
        .onAppear { appeared = true; sync(navigator.isOpen) }
        .onDisappear { appeared = false; sync(false) }
        .onReceive(navigator.$isOpen) { sync($0) }
    }

    private func meter(_ metric: PulseMetric, _ label: String) -> some View {
        HStack(spacing: 2) {
            RetroPixelText(label, pixel: pixel, color: Retro.Ink.osdWhite.opacity(0.85))
            RetroLEDBar(value: value(metric), segments: segments, axis: .horizontal, size: bar)
        }
        .fixedSize()
    }

    /// The sampler is held while this is on screen with the notch open (a picture counts as open).
    static func wantsSampler(appeared: Bool, open: Bool, gallery: Bool) -> Bool { appeared && (open || gallery) }

    private func sync(_ open: Bool) {
        guard fixed == nil else { return }
        let want = Self.wantsSampler(appeared: appeared, open: open, gallery: ScoutRuntime.isGallery)
        if want && !holding { holding = true; sampler.acquire() }
        if !want && holding { holding = false; sampler.release() }
    }
}
