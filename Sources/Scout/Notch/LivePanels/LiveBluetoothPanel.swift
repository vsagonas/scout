import Combine
import SwiftUI

// live.bluetooth: for a minute after a headset connects, and while a connected device's battery is under 20 %.
// Name and battery (left / right / case when the system reports them). Reads BluetoothService's connected devices.

@MainActor
final class LiveBluetoothPanel: LiveDriven {
    static let window: TimeInterval = 60
    static let lowBattery = 20

    let id = "live.bluetooth"
    let title = String(localized: "AirPods & Bluetooth")
    let symbol = "airpodspro"
    let priority = 40
    let span = 4
    let expandTo: WorkspaceKind? = nil

    let feed: LiveFeed<[BluetoothConnection]>
    private let clock: () -> Date

    var changes: AnyPublisher<Void, Never> { feed.changes }

    init(feed: LiveFeed<[BluetoothConnection]>, clock: @escaping () -> Date = Date.init) {
        self.feed = feed
        self.clock = clock
    }

    static func live() -> LiveBluetoothPanel {
        let service = BluetoothService.shared
        let feed = LiveFeed<[BluetoothConnection]>(read: { service.connections }, triggers: [service.liveTrigger])
        return LiveBluetoothPanel(feed: feed)
    }

    // MARK: Choosing

    struct Candidate: Equatable {
        enum Reason: Equatable { case justConnected, lowBattery }
        var info: BluetoothInfo
        var reason: Reason
    }

    static func isHeadset(_ kind: BluetoothInfo.Kind) -> Bool {
        switch kind {
        case .airPods, .airPodsPro, .airPodsMax, .beats, .headphones: true
        default: false
        }
    }

    /// The lowest battery of the parts you wear or hold (the case is not counted: a flat case is not an alarm).
    static func lowest(_ info: BluetoothInfo) -> Int? { [info.left, info.right, info.single].compactMap { $0 }.min() }

    /// Headsets that connected in the last minute (newest first), then devices with a low battery (lowest first).
    static func candidates(_ connections: [BluetoothConnection], now: Date) -> [Candidate] {
        let fresh = connections
            .filter { isHeadset($0.info.kind) && $0.since != .distantPast && now.timeIntervalSince($0.since) < window }
            .sorted { $0.since > $1.since }
        let low = connections
            .filter { c in (lowest(c.info) ?? 100) < lowBattery && !fresh.contains { $0.info.name == c.info.name } }
            .sorted { (lowest($0.info) ?? 100) < (lowest($1.info) ?? 100) }
        return fresh.map { Candidate(info: $0.info, reason: .justConnected) } + low.map { Candidate(info: $0.info, reason: .lowBattery) }
    }

    var isLive: Bool { !Self.candidates(feed.value, now: clock()).isEmpty }

    func nextWake(after now: Date) -> Date? {
        feed.value.filter { Self.isHeadset($0.info.kind) && $0.since != .distantPast }
            .map { $0.since.addingTimeInterval(Self.window) }.filter { $0 > now }.min()
    }

    func makeView() -> AnyView { AnyView(LiveBluetoothView(feed: feed, clock: clock)) }
}

// MARK: - View

struct LiveBluetoothView: View {
    @ObservedObject var feed: LiveFeed<[BluetoothConnection]>
    var clock: () -> Date = Date.init

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            let list = LiveBluetoothPanel.candidates(feed.value, now: clock())
            if let first = list.first {
                if Retro.is8bit { panel(first, more: list.count - 1) } else { minimalPanel(first, more: list.count - 1) }
            } else {
                Color.clear
            }
        }
    }

    /// The minimal look: the device's symbol, name and state, and each battery as a number over a slim bar (red only when low).
    private func minimalPanel(_ c: LiveBluetoothPanel.Candidate, more: Int) -> some View {
        let info = c.info
        let low = (LiveBluetoothPanel.lowest(info) ?? 100) < LiveBluetoothPanel.lowBattery
        let red = Color(red: 1.0, green: 0.35, blue: 0.30)
        return LiveRetroFrame(symbol: info.symbol, title: "Bluetooth", tint: Retro.Ink.purple, trailing: {
            if more > 0 { LiveRetroFact(text: String(localized: "+\(more) more")) }
        }) {
            HStack(spacing: 9) {
                Image(systemName: info.symbol).font(.system(size: 20)).foregroundStyle(Retro.quietInk).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    HStack(spacing: 4) {
                        Circle().fill(low ? red : Color(red: 0.30, green: 0.80, blue: 0.45)).frame(width: 5, height: 5)
                        Text(low ? "Battery low" : "Connected").font(.system(size: 10.5)).foregroundStyle(low ? red : NotchInk.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            if info.hasBattery {
                HStack(alignment: .top, spacing: 10) {
                    if info.left != nil || info.right != nil || info.caseLevel != nil {
                        if let l = info.left { miniLevel(String(localized: "Left"), l) }
                        if let r = info.right { miniLevel(String(localized: "Right"), r) }
                        if let k = info.caseLevel { miniLevel(String(localized: "Case"), k) }
                    } else if let s = info.single {
                        miniLevel(String(localized: "Battery"), s)
                    }
                }
            } else {
                Text("No battery report").font(.system(size: 10.5)).foregroundStyle(NotchInk.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private func miniLevel(_ label: String, _ percent: Int) -> some View {
        let low = percent < LiveBluetoothPanel.lowBattery
        return VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: "\(percent)%").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(NotchInk.primary).lineLimit(1)
            MiniBar(fraction: Double(percent) / 100, tint: low ? Color(red: 1.0, green: 0.35, blue: 0.30) : Look.ink(0.78))
            Text(label).font(.system(size: 10)).foregroundStyle(NotchInk.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func panel(_ c: LiveBluetoothPanel.Candidate, more: Int) -> some View {
        let info = c.info
        let low = (LiveBluetoothPanel.lowest(info) ?? 100) < LiveBluetoothPanel.lowBattery
        return LiveRetroFrame(symbol: info.symbol, title: "Bluetooth", tint: Retro.Ink.purple, trailing: {
            if more > 0 { LiveRetroFact(text: String(localized: "+\(more) more")) }
        }) {
            HStack(spacing: 9) {
                Image(systemName: info.symbol).font(.system(size: 22)).foregroundStyle(Retro.Ink.teal).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    HStack(spacing: 4) {
                        Circle().fill(low ? Retro.Ink.ledRed : Retro.Ink.ledGreen).frame(width: 6, height: 6)
                            .shadow(color: (low ? Retro.Ink.ledRed : Retro.Ink.ledGreen).opacity(0.8), radius: 2)
                        Text(low ? "Battery low" : "Connected").font(.system(size: 10.5)).foregroundStyle(low ? Retro.Ink.ledRed : Color.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            if info.hasBattery {
                HStack(alignment: .top, spacing: 8) {
                    if info.left != nil || info.right != nil || info.caseLevel != nil {
                        if let l = info.left { level(String(localized: "Left"), l) }
                        if let r = info.right { level(String(localized: "Right"), r) }
                        if let k = info.caseLevel { level(String(localized: "Case"), k) }
                    } else if let s = info.single {
                        level(String(localized: "Battery"), s)
                    }
                }
            } else {
                Text("No battery report").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    /// One battery as little LED bars: the number in segments, the level as a row of LEDs (green, yellow under 40, red under 20).
    private func level(_ label: String, _ percent: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SevenSegmentText("\(percent)", height: 13, color: Self.ink(percent), ghost: false)
            GeometryReader { geo in
                Dash90LEDBar(value: Double(percent) / 100, segments: 8, size: CGSize(width: min(54, geo.size.width), height: 11), color: { _, _ in Self.ink(percent) })
            }
            .frame(height: 11)
            Dash90Text(label, pixel: 1, color: Look.osd.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func tint(_ level: Int) -> Color { level < LiveBluetoothPanel.lowBattery ? .red : (level <= 40 ? .orange : .green) }

    /// The LED colour of a battery level.
    static func ink(_ level: Int) -> Color { Dash90.goodWhenHigh(level < LiveBluetoothPanel.lowBattery ? 20 : level) }
}
