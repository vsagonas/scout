import SwiftUI

// Gallery scenes `dash90-gpu-*`: the CPU and memory panel with the GPU as its third reading (2026-11-22), at the widths it really has (a panel is
// `span` cells wide, no gaps inside it), with a GPU reading and without one, and the whole dashboard around it. Synthetic data only.
// Render with `scripts/gallery.sh dash90-gpu`; the look, the preset and the size come from SCOUT_8BIT, SCOUT_PRESET and SCOUT_SCALE.

@MainActor
enum Dash90GPUGallery {
    /// The reading of a Mac that reports no GPU load, and of one at its limit (100 % everywhere: the widest digits the panel draws).
    private static let noGPU = PulseSampler.sample(gpu: nil)
    private static let allFull = PulseSampler.sample(cpu: 1, memory: 1, gpu: 1)

    /// The Pulse panel alone at `span` cells (as the dashboard draws it: `span` times a cell wide, 140 pt tall), at 2.4 times its size on black.
    private static func panel(_ name: String, span: Int, sample: PulseSample? = nil, metrics: [PulseMetric] = [.cpu, .memory, .gpu]) {
        let scale: CGFloat = 2.4
        let w = CGFloat(span) * NookMetrics.cell
        let h = NookMetrics.widgetHeight
        let battery = BatteryState(level: 82, isCharging: false, isPluggedIn: false, isCharged: false, minutesRemaining: 250)
        Gallery.register("dash90-gpu-\(name)", size: CGSize(width: w * scale + 40, height: h * scale + 40), backdrop: .window) {
            PulseWidgetView(style: .cards, metrics: metrics, battery: battery)
                .environment(\.pulseSampleOverride, sample)
                .frame(width: w, height: h)
                .nookPanelFace()
                .environment(\.colorScheme, Look.contentScheme)
                .scaleEffect(scale)
                .frame(width: w * scale, height: h * scale)
                .padding(20)
                .background(Color.black)
        }
    }

    /// The whole dashboard (wide enough for the biggest Size setting).
    private static func row(_ name: String, height: CGFloat = 340, width: CGFloat = 1600, agents: Int = 3, playing: Bool = false, widthCap: CGFloat? = nil,
                            editing: Bool = false, sample: PulseSample? = nil) {
        Gallery.register("dash90-gpu-\(name)", size: CGSize(width: width, height: height)) {
            let _ = DashGallery.seed(agents: agents, playing: playing)
            NotchScene(size: CGSize(width: width, height: height), open: true, editing: editing,
                       live: NookLive(playing: playing, openTodos: 0, agents: agents), widthCap: widthCap, showNotchRect: true)
                .environment(\.pulseSampleOverride, sample)
        }
    }

    static func register() {
        let wide = WidgetKind.pulse.defaultSpan   // 5 cells in the 8-bit look, 6 in the minimal one
        panel("panel", span: wide)                                 // the panel when its row has room: CPU, memory, GPU
        panel("panel-full", span: wide, sample: allFull)           // all three at 100 %: the widest digits
        panel("panel-none", span: wide, sample: noGPU)             // a Mac that reports no GPU load: two readings, no empty slot
        panel("panel-tight", span: 4)                              // a busy row took the extra cells back: CPU and memory as they were
        panel("panel-tight-none", span: 4, sample: noGPU)          // no GPU load at the old width: the panel exactly as it was
        panel("panel-net", span: wide, metrics: [.cpu, .network, .gpu])   // a reading with a line of its own keeps its two columns
        row("row-quiet")                                           // the default dashboard: Agents, Ask AI, CPU and memory, Today
        row("row-music", playing: true)                            // music playing: the row is tight, the panel keeps its four cells
        row("row-none", sample: noGPU)                             // the default dashboard on a Mac with no GPU reading
        row("row-narrow", width: 760, widthCap: 680)               // the narrowest notch setting (the row wraps as it always did)
        row("row-edit", height: 440, editing: true)                // Edit Nook: the panel keeps clear of the remove key
    }
}
