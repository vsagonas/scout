import AppKit
import IOKit.ps
import SwiftUI

// A8 — battery: an activity when you plug in or unplug, a low-battery warning, and "fully charged".

struct BatteryState: Equatable {
    var level: Int           // 0…100
    var isCharging: Bool
    var isPluggedIn: Bool
    var isCharged: Bool
    var minutesRemaining: Int?

    static let sample = BatteryState(level: 78, isCharging: true, isPluggedIn: true, isCharged: false, minutesRemaining: 54)
}

@MainActor
final class BatteryService: ObservableObject {
    static let shared = BatteryService()

    /// nil on Macs without a battery.
    @Published private(set) var state: BatteryState?

    private var source: CFRunLoopSource?
    private var started = false
    private var warnedLow = false

    var levelText: String { state.map { String(localized: "\($0.level) %") } ?? "—" }

    func start() {
        guard !started else { return }
        started = true
        if ScoutRuntime.isScripted {
            state = .sample
            return
        }
        state = Self.read()
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let service = Unmanaged<BatteryService>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { service.changed() }
        }, context)?.takeRetainedValue() {
            source = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
    }

    private func changed() {
        let new = Self.read()
        let old = state
        state = new
        guard let new, let old else { return }
        let center = LiveActivityCenter.shared
        if new.isPluggedIn != old.isPluggedIn {
            center.show(BatteryActivity.make(state: new, expiresAfter: 4))
            if new.isPluggedIn { warnedLow = false }
        } else if new.isCharged, !old.isCharged, new.isPluggedIn {
            center.show(BatteryActivity.make(state: new, expiresAfter: 5))
        }
        let threshold = Pref.double("battery.lowThreshold", 20)
        if Pref.bool("battery.lowWarning", true), !new.isPluggedIn, Double(new.level) <= threshold, !warnedLow {
            warnedLow = true
            center.show(BatteryActivity.make(state: new, expiresAfter: 8))
            center.present(NotchCard(id: "battery.low", kind: .battery, duration: 6, onTap: nil) {
                DemoCardContent(symbol: "battery.25percent", title: String(localized: "Battery is low"), subtitle: String(localized: "\(new.level) % left. Time to plug in."))
            })
        }
        if new.level > Int(threshold) + 5 { warnedLow = false }
    }

    nonisolated private static func read() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let level = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
            let plugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let charged = d[kIOPSIsChargedKey] as? Bool ?? (plugged && level >= 100)
            let remaining = (plugged ? d[kIOPSTimeToFullChargeKey] : d[kIOPSTimeToEmptyKey]) as? Int
            return BatteryState(level: level, isCharging: charging, isPluggedIn: plugged, isCharged: charged,
                                minutesRemaining: (remaining ?? -1) > 0 ? remaining : nil)
        }
        return nil
    }
}

func batterySymbol(level: Int) -> String {
    switch level {
    case ..<10: "battery.0percent"
    case ..<35: "battery.25percent"
    case ..<60: "battery.50percent"
    case ..<85: "battery.75percent"
    default: "battery.100percent"
    }
}

enum BatteryActivity {
    @MainActor
    static func make(state: BatteryState, expiresAfter: TimeInterval? = 4) -> LiveActivity {
        let low = !state.isPluggedIn && state.level <= Int(Pref.double("battery.lowThreshold", 20))
        let tint: Color = low ? .red : (state.isCharged ? .green : (state.isPluggedIn ? .green : .white))
        let symbol = state.isPluggedIn ? "bolt.fill" : batterySymbol(level: state.level)
        let text = state.isCharged ? String(localized: "Full") : "\(state.level)%"
        let detail: (String, String)
        if state.isCharged {
            detail = (String(localized: "Fully charged"), String(localized: "You can unplug"))
        } else if state.isPluggedIn {
            detail = (String(localized: "Charging"), state.minutesRemaining.map { String(localized: "\(Self.duration($0)) to full") } ?? String(localized: "\(state.level) %"))
        } else if low {
            detail = (String(localized: "Battery is low"), state.minutesRemaining.map { String(localized: "\(Self.duration($0)) left") } ?? String(localized: "\(state.level) % left"))
        } else {
            detail = (String(localized: "On battery"), state.minutesRemaining.map { String(localized: "\(Self.duration($0)) left") } ?? String(localized: "\(state.level) %"))
        }
        return LiveActivity(id: "battery", kind: .battery, expiresAfter: expiresAfter) {
            WingIcon(symbol: symbol, tint: tint, size: 14)
        } trailing: {
            WingText(verbatim: text, tint: low ? .red : .white)
        }
        .withDetail { DemoDetail(title: Text(verbatim: detail.0), subtitle: Text(verbatim: detail.1)) }
    }

    /// "1 hr, 5 min" in the person's language.
    static func duration(_ minutes: Int) -> String { LiveFormat.duration(minutes: minutes) }
}
