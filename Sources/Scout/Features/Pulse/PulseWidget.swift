import SwiftUI

enum PulseStyle: String, CaseIterable, Identifiable {
    case cards, rings, list
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cards: String(localized: "Cards")
        case .rings: String(localized: "Rings")
        case .list: String(localized: "List")
        }
    }
}

enum PulsePrefs {
    static let styleKey = "pulse.style"
    static let metricsKey = "pulse.metrics"
    static let defaultMetrics: [PulseMetric] = [.cpu, .memory, .gpu, .network, .disk]

    static func raw(_ metrics: [PulseMetric]) -> String { metrics.map(\.rawValue).joined(separator: ",") }

    /// The metrics the panel shows by the saved choice (the default list when nothing is saved).
    static var selected: [PulseMetric] {
        let saved = Pref.string(metricsKey, raw(defaultMetrics)).split(separator: ",").compactMap { PulseMetric(rawValue: String($0)) }
        return saved.isEmpty ? defaultMetrics : saved
    }

    /// True when the Cards style draws the GPU as a third reading: it is among the metrics after the first two, and the first two are
    /// the quiet readings (CPU and memory; a reading with a line of its own, like the network's, keeps its two columns). The dashboard
    /// gives the panel its extra cells exactly then (`WidgetKind.defaultSpan`).
    static func cardsShowGPU(_ metrics: [PulseMetric]) -> Bool {
        let first = metrics.prefix(2)
        return first.count == 2 && first.allSatisfy { PulseWidgetView.quietDetail.contains($0) } && !first.contains(.gpu) && metrics.dropFirst(2).contains(.gpu)
    }
}

private func speed(_ bytesPerSecond: Double) -> String {
    if bytesPerSecond < 1024 { return "0 KB/s" }
    let units = ["KB/s", "MB/s", "GB/s"]
    var v = bytesPerSecond / 1024
    var i = 0
    while v >= 1000 && i < units.count - 1 { v /= 1024; i += 1 }
    return v >= 100 || i == 0 ? "\(Int(v.rounded())) \(units[i])" : "\(v.formatted(.number.precision(.fractionLength(1)))) \(units[i])"
}

extension PulseSample {
    /// 0...1 for rings and bars; nil when the Mac has no such sensor.
    func fraction(_ m: PulseMetric, peakNet: Double) -> Double? {
        switch m {
        case .cpu: cpu
        case .memory: memory
        case .gpu: gpu
        case .disk: disk
        case .battery: battery
        case .network: min(1, netDown / max(1024, peakNet))
        }
    }

    func headline(_ m: PulseMetric) -> String {
        switch m {
        case .cpu: "\(Int((cpu * 100).rounded()))%"
        case .memory: "\(Int((memory * 100).rounded()))%"
        case .gpu: gpu.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        case .disk: "\(Int((disk * 100).rounded()))%"
        case .battery: battery.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        case .network: speed(netDown)
        }
    }

    /// The speed as the panel writes it ("0 KB/s", "310 KB/s", "1.4 MB/s").
    static func speedText(_ bytesPerSecond: Double) -> String { speed(bytesPerSecond) }

    func detail(_ m: PulseMetric) -> String {
        switch m {
        case .cpu: String(localized: "in use")
        case .memory: String(localized: "\(FeatureFormat.bytes(memoryUsedBytes)) used")
        case .gpu: gpu == nil ? String(localized: "not reported") : String(localized: "in use")
        case .disk: String(localized: "\(FeatureFormat.bytes(diskFreeBytes)) free")
        case .battery: battery == nil ? String(localized: "no battery") : (charging ? String(localized: "charging") : String(localized: "on battery"))
        case .network: "↑ " + speed(netUp)
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color
    var filled = true

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                if filled, pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.38), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                }
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let step = size.width / CGFloat(PulseSampler.historyLength - 1)
        let offset = size.width - step * CGFloat(values.count - 1)
        return values.enumerated().map { i, v in
            CGPoint(x: offset + CGFloat(i) * step, y: size.height - 2 - CGFloat(min(1, max(0, v))) * (size.height - 4))
        }
    }
}

struct PulseRing: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat = 5

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0.015, fraction)).stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

private struct PulseSampleOverrideKey: EnvironmentKey { static let defaultValue: PulseSample? = nil }

extension EnvironmentValues {
    /// Pictures and tests: the Pulse panel shows this reading instead of the sampler's (a fixed one, one with no GPU, a full one).
    var pulseSampleOverride: PulseSample? {
        get { self[PulseSampleOverrideKey.self] }
        set { self[PulseSampleOverrideKey.self] = newValue }
    }
}

/// One reading in row 1 of the cards: its name at the left, the digits and the unit at the right, all on the digits' baseline.
struct PulseReadout: View {
    let metric: PulseMetric
    /// The reading as the panel writes it ("37%", "100%", "—").
    let headline: String
    /// A reading of 100 % uses the smallest digits the panel has (15 pt) instead of 20 pt, so three readings still fit side by side.
    var smallestDigits = false
    /// In Edit Nook the first piece keeps clear of the remove key (two readings); three readings need the room and stand clear anyway.
    var clearsRemoveKey = true

    var body: some View {
        let reading = Dash90.segmentReading(headline)
        let n = reading.digits.count
        DashReadout(clearsRemoveKey: clearsRemoveKey) {
            DashLabel(metric.title)
            Spacer(minLength: 2)
            // The grid's digit height; a longer number ("100", "2.3") uses a smaller one on the same baseline so the pair still fits.
            DashDigits(text: reading.digits, height: n <= 2 ? DashGrid.digitHeight : (n == 3 && !smallestDigits ? 20 : 15), color: Dash90.pulseColor(metric))
            if !reading.unit.isEmpty { DashLabel(reading.unit, color: Dash90.pulseColor(metric).opacity(0.85)) }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Nook widget: CPU, memory, GPU, disk, battery and network, as cards, rings or a list. Click = Activity Monitor.
struct PulseWidgetView: View {
    @ObservedObject private var sampler = PulseSampler.shared
    @ObservedObject private var nav = NotchNavigator.shared
    @ObservedObject private var battery = BatteryService.shared
    @AppStorage(PulsePrefs.styleKey) private var styleRaw = PulseStyle.cards.rawValue
    @AppStorage(PulsePrefs.metricsKey) private var metricsRaw = PulsePrefs.raw(PulsePrefs.defaultMetrics)
    @Environment(\.pulseSampleOverride) private var sampleOverride
    @State private var appeared = false
    @State private var holding = false

    /// Gallery only: show this style / these metrics instead of the saved settings.
    private var styleOverride: PulseStyle?
    private var metricsOverride: [PulseMetric]?
    /// Gallery and tests: a fixed battery instead of the Mac's.
    private var fixedBattery: BatteryState?

    init() {}
    init(style: PulseStyle, metrics: [PulseMetric], battery: BatteryState? = nil) { styleOverride = style; metricsOverride = metrics; fixedBattery = battery }

    private var style: PulseStyle { styleOverride ?? PulseStyle(rawValue: styleRaw) ?? .cards }
    private var metrics: [PulseMetric] {
        if let metricsOverride { return metricsOverride }
        let m = metricsRaw.split(separator: ",").compactMap { PulseMetric(rawValue: String($0)) }.filter { !sampler.unavailable.contains($0) }
        return m.isEmpty ? PulsePrefs.defaultMetrics.filter { !sampler.unavailable.contains($0) } : m
    }

    /// The reading on show: the sampler's, or the fixed one a picture or a test gives.
    private var latest: PulseSample { sampleOverride ?? sampler.latest }

    private var peakNet: Double { max(1024, (sampler.netDownHistory + sampler.netUpHistory).max() ?? 1) }

    var body: some View {
        // No title: the readings start at the top.
        VStack(alignment: .leading, spacing: 5) {
            Group {
                switch style {
                case .cards: cards
                case .rings: rings
                case .list: list
                }
            }
            // At the top of the panel like its neighbours, not in its middle.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(DashGrid.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .notchContent()
        .contentShape(Rectangle())
        .onTapGesture { Self.openActivityMonitor() }
        .onAppear { appeared = true; sync(); battery.start() }
        .onDisappear { appeared = false; sync() }
        .onChange(of: nav.isOpen) { sync() }
    }

    /// Samples only while the widget is on screen AND the notch is open.
    private func sync() {
        let want = appeared && (nav.isOpen || ScoutRuntime.isGallery)
        if want && !holding { holding = true; sampler.acquire() }
        if !want && holding { holding = false; sampler.release() }
    }

    static func openActivityMonitor() {
        guard !ScoutRuntime.isScripted else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    // MARK: The three styles, as a 90s hi-fi readout: seven-segment numbers, LED bars, a scope on a small glass.

    /// The readings of row 1: the first two, and the GPU as a third when it is one of the selected metrics, this Mac reports its load, and the
    /// two before it are CPU and memory (a reading with a line of its own, like the network's, keeps its two columns). A Mac that reports no GPU
    /// load shows the two readings alone: no empty slot, no dash.
    private var cardMetrics: [PulseMetric] {
        let first = Array(metrics.prefix(2))
        guard PulsePrefs.cardsShowGPU(metrics), latest.gpu != nil else { return first }
        return first + [.gpu]
    }

    /// The dashboard's grid (`DashGrid`), top to bottom:
    /// row 1 the two readings, each reading's own graph right under it
    /// (same two columns, the graphs take all the free height), then the SSD and battery line, then the internet's speeds as the last line.
    private var cards: some View {
        let shown = cardMetrics
        // A reading that keeps a small line under its graph (disk free, upload speed) leaves the same room in all columns, so the graphs
        // stay equally tall; the default readings (CPU, memory, GPU) keep no such line.
        let detailRoom = shown.contains { !Self.quietDetail.contains($0) }
        let showsStatus = !shown.contains(.disk) || (fixedBattery ?? battery.state) != nil   // else the line would be empty
        return VStack(alignment: .leading, spacing: 0) {
            // One column per reading, 8 pt apart: each reading with its own graph right under it, so a graph can never drift from its reading (a wide
            // reading, like the network's, makes its column a little wider and the graph follows). The graphs are what stretches: they take
            // all the room the two lines below leave.
            readings(shown, detailRoom: detailRoom)
                .frame(maxHeight: .infinity)
            // The startup SSD's free space and the battery,
            // on one line, in the font of Today's date line.
            // The longest that fits: "SSD 210 GB free  78% full in 54 min", then without the battery's time, then the bare numbers.
            if showsStatus {
                Color.clear.frame(height: Self.beforeLinesGap)
                ViewThatFits(in: .horizontal) {
                    statusRow(full: true, batteryTime: true)
                    statusRow(full: true, batteryTime: false)
                    statusRow(full: false, batteryTime: false)
                }
                .reportDashRow("pulse.status")
            }
            // The last line of the panel, on the bottom inset like its neighbours' last lines: the internet's speeds, down and up.
            // Not twice when Network is one of the readings.
            if !shown.contains(.network) {
                Color.clear.frame(height: showsStatus ? Self.betweenLinesGap : Self.beforeLinesGap)
                networkLine.reportDashRow("pulse.network")
            }
        }
    }

    /// The readings of row 1 and the graphs under them. The GPU as a third column
    /// needs more room than two columns: the first that fits is drawn, the normal digits, then the smallest digits the panel has (15 pt)
    /// for a reading of 100 %, then the first two readings alone, the panel as it was (a busy dashboard row takes the panel's fifth cell back).
    @ViewBuilder private func readings(_ shown: [PulseMetric], detailRoom: Bool) -> some View {
        if shown.count > 2 {
            ViewThatFits(in: .horizontal) {
                columns(shown, detailRoom: false, gap: Self.threeColumnsGap, smallestDigits: false)
                columns(shown, detailRoom: false, gap: Self.threeColumnsGap, smallestDigits: true)
                columns(Array(shown.prefix(2)), detailRoom: false, gap: Self.twoColumnsGap, smallestDigits: false)
            }
        } else {
            columns(shown, detailRoom: detailRoom, gap: Self.twoColumnsGap, smallestDigits: false)
        }
    }

    private func columns(_ shown: [PulseMetric], detailRoom: Bool, gap: CGFloat, smallestDigits: Bool) -> some View {
        HStack(alignment: .top, spacing: gap) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, m in
                VStack(alignment: .leading, spacing: 0) {
                    PulseReadout(metric: m, headline: latest.headline(m), smallestDigits: smallestDigits, clearsRemoveKey: shown.count < 3).reportDashRow("pulse.readout.\(i)")
                    Color.clear.frame(height: DashGrid.readoutGap)
                    // Half the free height: the
                    // graph and an equal room under it share what is left, so the graph stays right under its reading.
                    Dash90Scope(values: sampler.history[m] ?? [], color: Dash90.traceGreen, historyLength: PulseSampler.historyLength)
                        .frame(maxHeight: .infinity)
                        .reportDashRow("pulse.scope.\(i)")
                    Color.clear.frame(maxHeight: .infinity)
                    // No "in use" under the CPU and no "29.9 GB used" under the memory:
                    // the big number says it. Readings whose line adds something (disk free, upload speed) keep it.
                    if !Self.quietDetail.contains(m) {
                        Text(latest.detail(m)).font(DashGrid.infoFont()).foregroundStyle(NotchInk.tertiary).lineLimit(1)
                            .padding(.top, 3)
                    } else if detailRoom {
                        Color.clear.frame(height: 3 + DashGrid.infoHeight)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    /// The room between the columns: 8 pt for two readings, 6 pt for three.
    private static let twoColumnsGap: CGFloat = 8
    private static let threeColumnsGap: CGFloat = 6

    /// The room above the first of the two lines at the panel's bottom (under the graphs), and between the two lines.
    private static let beforeLinesGap: CGFloat = 4
    private static let betweenLinesGap: CGFloat = 2

    /// "↓ 1.4 MB/s   ↑ 310 KB/s": what the Mac takes in and sends out right now, in the info line's font.
    private var networkLine: some View {
        DashInfoLine(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "arrow.down").font(.system(size: DashGrid.infoSymbolSize, weight: .bold)).foregroundStyle(Dash90.pulseColor(.network))
                Text(PulseSample.speedText(latest.netDown)).font(DashGrid.infoFont(.semibold)).foregroundStyle(NotchInk.primary).fixedSize()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Download \(PulseSample.speedText(latest.netDown))")
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "arrow.up").font(.system(size: DashGrid.infoSymbolSize, weight: .bold)).foregroundStyle(Dash90.pulseColor(.network))
                Text(PulseSample.speedText(latest.netUp)).font(DashGrid.infoFont(.semibold)).foregroundStyle(NotchInk.primary).fixedSize()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Upload \(PulseSample.speedText(latest.netUp))")
            Spacer(minLength: 0)
        }
        .help("Internet speed right now: down (received) and up (sent)")
    }

    private func statusRow(full: Bool, batteryTime: Bool) -> some View {
        DashInfoLine(spacing: 12) {
            if !metrics.prefix(2).contains(.disk) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "internaldrive").font(.system(size: DashGrid.infoSymbolSize, weight: .semibold)).foregroundStyle(NotchInk.tertiary)
                    if full { Text(verbatim: "SSD").font(DashGrid.infoFont(.semibold)).foregroundStyle(NotchInk.primary).fixedSize() }
                    Text(full ? latest.detail(.disk) : FeatureFormat.bytes(latest.diskFreeBytes)).fixedSize()
                }
                .accessibilityElement(children: .combine)
            }
            if let b = fixedBattery ?? battery.state { batteryItem(b, time: batteryTime) }
            Spacer(minLength: 0)
        }
    }

    /// "82% · 4 h 10 min left", "64% · full in 54 min", "100% · charged": a battery symbol (a bolt while charging), the percent, the time.
    private func batteryItem(_ b: BatteryState, time: Bool = true) -> some View {
        let low = !b.isPluggedIn && b.level <= 20
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: b.isCharging ? "battery.100.bolt" : (b.level <= 20 ? "battery.25" : "battery.75"))
                .font(.system(size: DashGrid.infoSymbolSize, weight: .semibold)).foregroundStyle(low ? Retro.Ink.ledRed : NotchInk.tertiary)
            Text(verbatim: "\(b.level)%").font(DashGrid.infoFont(.semibold)).foregroundStyle(low ? Retro.Ink.ledRed : NotchInk.primary)
            if time, let detail = TodayPlan.batteryDetail(b) { Text(detail).fixedSize() }
        }
        .accessibilityElement(children: .combine)
    }

    /// Readings shown on the dashboard without the small line under them (their number says it all: "in use", "29.9 GB used").
    static let quietDetail: Set<PulseMetric> = [.cpu, .memory, .gpu]

    private var rings: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(metrics.prefix(4))) { m in
                let reading = Dash90.segmentReading(latest.headline(m))
                VStack(spacing: 3) {
                    SevenSegmentText(reading.digits, height: 15, color: Dash90.pulseColor(m))
                    verticalBar(m, size: CGSize(width: 16, height: 46))
                    Dash90Text(m.title, pixel: 1, color: Look.osd.opacity(0.8))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)   // at the top like every panel (the grid), not sunk to the bottom
    }

    private var list: some View {
        VStack(spacing: 3) {
            ForEach(Array(metrics.prefix(6))) { m in
                let reading = Dash90.segmentReading(latest.headline(m))
                HStack(spacing: 5) {
                    Dash90Text(m.title, pixel: 1, color: Look.osd.opacity(0.85)).frame(width: 44, alignment: .leading)
                    Spacer(minLength: 0)
                    SevenSegmentText(reading.digits, height: 11, color: Dash90.pulseColor(m), ghost: false)
                    if !reading.unit.isEmpty { RetroPixelText(reading.unit, pixel: 1, color: Dash90.pulseColor(m).opacity(0.85)) }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The level as LED segments: the kit's meter (green, yellow, red as it fills); the battery is good when it is full, so it lights green.
    @ViewBuilder private func levelBar(_ m: PulseMetric, height: CGFloat) -> some View {
        let f = latest.fraction(m, peakNet: peakNet) ?? 0
        if m == .battery {
            GeometryReader { geo in
                Dash90LEDBar(value: f, segments: 10, size: CGSize(width: geo.size.width, height: height), color: { _, _ in Dash90.goodWhenHigh(Int((f * 100).rounded())) })
            }
            .frame(height: height)
        } else {
            Dash90FlexBar(value: f, segments: 10, height: height)
        }
    }

    private func verticalBar(_ m: PulseMetric, size: CGSize) -> some View {
        RetroLEDBar(value: latest.fraction(m, peakNet: peakNet) ?? 0, segments: 8, axis: .vertical, size: size)
    }
}
