import SwiftUI

/// The Mac's own load, "CPU 37%  Mem 64%", from the same sampler the Pulse panel uses (`PulseSampler.shared`: no second
/// sampler). It sits in the Agents panel's header and the expanded Agents view, so the panel reads as one agentic + machine
/// monitor, and as one text line in the closed notch's hover detail. It samples only while it is on screen and the notch is
/// open (the hover line: while it shows), about every 1.5 s, and its numbers have a fixed width, so nothing jumps.
struct MachineLoadLine: View {
    enum Style {
        /// "CPU 37% ▁▂▃  Mem 64% ▃▃▄": labels and tiny sparklines.
        case full
        /// "CPU 37%  Mem 64%".
        case labeled
        /// "CPU 37%  Mem 64%" with small labels, the numbers colour-coded like the Pulse panel (a narrow panel). Bare numbers
        /// alone did not say what they were.
        case compact
        /// "CPU 37%" over "Mem 64%" in two tiny lines, within the 18 pt header: the narrowest panels (the dashboard's Agents
        /// panel), where "Agents" and an inline readout do not fit side by side.
        case stacked
        /// "Mac · CPU 37% · Mem 64%" as one line of text (the closed notch's hover detail).
        case text
    }

    var style: Style = .full
    @ObservedObject private var sampler = PulseSampler.shared
    @Environment(\.notchNavigator) private var navigator
    @State private var appeared = false
    @State private var holding = false

    /// The style that fits a panel of this width.
    /// `w` is the whole panel's width, its 10 pt padding included.
    static func style(forWidth w: CGFloat) -> Style { w >= 420 ? .full : (w >= 250 ? .labeled : (w >= 190 ? .compact : .stacked)) }

    private var ready: Bool { (sampler.history[.cpu]?.count ?? 0) >= 2 }   // the first CPU reading has nothing to compare with

    private func percent(_ metric: PulseMetric) -> String {
        guard ready else { return "–" }
        return "\(Int(((metric == .cpu ? sampler.latest.cpu : sampler.latest.memory) * 100).rounded()))%"
    }

    var body: some View {
        Group {
            switch style {
            case .text: textLine
            case .compact:
                HStack(spacing: 6) {
                    value(.cpu, label: "CPU", coloured: true)
                    value(.memory, label: String(localized: "Mem"), coloured: true)
                }
            case .stacked:
                VStack(alignment: .trailing, spacing: -1) {
                    tiny(.cpu, label: "CPU")
                    tiny(.memory, label: String(localized: "Mem"))
                }
            case .labeled:
                HStack(spacing: 9) {
                    value(.cpu, label: "CPU")
                    value(.memory, label: String(localized: "Mem"))
                }
            case .full:
                HStack(spacing: 11) {
                    value(.cpu, label: "CPU", spark: true)
                    value(.memory, label: String(localized: "Mem"), spark: true)
                }
            }
        }
        .help("Your Mac right now: processor and memory in use")
        .onAppear { appeared = true; sync(navigator.isOpen) }
        .onDisappear { appeared = false; sync(false) }
        .onReceive(navigator.$isOpen) { sync($0) }
    }

    private var textLine: some View {
        HStack(spacing: 5) {
            Image(systemName: "cpu").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.accent)
            Text("Mac · CPU \(percent(.cpu)) · Mem \(percent(.memory))")
                .font(.system(size: 10.5, weight: .medium)).monospacedDigit().foregroundStyle(Look.secondary).lineLimit(1)
        }
    }

    /// `coloured`: the narrow styles colour the number like the Pulse panel and use a smaller label.
    private func value(_ metric: PulseMetric, label: String?, spark: Bool = false, coloured: Bool = false) -> some View {
        HStack(spacing: coloured ? 2 : 3) {
            if let label { Text(label).font(.system(size: coloured ? 8.5 : 9.5, weight: .medium)).foregroundStyle(NotchInk.tertiary) }
            Text(percent(metric)).font(.system(size: coloured ? 10 : 10.5, weight: .semibold)).monospacedDigit()
                .foregroundStyle(coloured ? metric.color : NotchInk.secondary)
                .frame(minWidth: coloured ? 22 : 25, alignment: .trailing)
            if spark {
                Sparkline(values: ready ? (sampler.history[metric] ?? []) : [], color: metric.color, filled: false)
                    .frame(width: 26, height: 10)
            }
        }
    }

    private func tiny(_ metric: PulseMetric, label: String) -> some View {
        HStack(spacing: 2) {
            Text(label).font(.system(size: 7.5, weight: .medium)).foregroundStyle(NotchInk.tertiary).fixedSize()
            Text(percent(metric)).font(.system(size: 8.5, weight: .semibold)).monospacedDigit().foregroundStyle(metric.color)
                .fixedSize().frame(minWidth: 22, alignment: .trailing)
        }
    }

    /// Samples only while this is on screen and the notch is open (the one-line text style: while it shows, in the closed notch).
    private func sync(_ open: Bool) {
        let want = appeared && (style == .text || open || ScoutRuntime.isGallery)
        if want && !holding { holding = true; sampler.acquire() }
        if !want && holding { holding = false; sampler.release() }
    }
}
