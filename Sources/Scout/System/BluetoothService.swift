import AppKit
import IOBluetooth
import SwiftUI

// A9 — AirPods & Bluetooth: when a device connects, show it with its battery for a few seconds.

struct BluetoothInfo: Equatable {
    enum Kind { case airPods, airPodsPro, airPodsMax, beats, headphones, speaker, keyboard, mouse, trackpad, other }

    var name: String
    var kind: Kind
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var single: Int?

    var symbol: String {
        switch kind {
        case .airPods: "airpods"
        case .airPodsPro: "airpodspro"
        case .airPodsMax: "airpodsmax"
        case .beats: "beats.headphones"
        case .headphones: "headphones"
        case .speaker: "hifispeaker.fill"
        case .keyboard: "keyboard"
        case .mouse: "computermouse.fill"
        case .trackpad: "rectangle.and.hand.point.up.left.filled"
        case .other: "dot.radiowaves.left.and.right"
        }
    }

    var hasBattery: Bool { left != nil || right != nil || caseLevel != nil || single != nil }

    var summary: String {
        var parts: [String] = []
        if let left { parts.append(String(localized: "L \(left) %")) }
        if let right { parts.append(String(localized: "R \(right) %")) }
        if let caseLevel { parts.append(String(localized: "Case \(caseLevel) %")) }
        if let single, parts.isEmpty { parts.append(String(localized: "\(single) %")) }
        return parts.isEmpty ? String(localized: "Connected") : parts.joined(separator: " · ")
    }

    #if APPSTORE
    /// The App Store edition reads no battery levels (macOS has no public API for them), so its sample has none either.
    static let airPodsPro = BluetoothInfo(name: "AirPods Pro", kind: .airPodsPro)
    #else
    static let airPodsPro = BluetoothInfo(name: "AirPods Pro", kind: .airPodsPro, left: 92, right: 88, caseLevel: 64, single: nil)
    #endif

    static func kind(forName name: String, major: UInt32 = 0, minor: UInt32 = 0) -> Kind {
        let n = name.lowercased()
        if n.contains("airpods max") { return .airPodsMax }
        if n.contains("airpods pro") { return .airPodsPro }
        if n.contains("airpods") { return .airPods }
        if n.contains("beats") { return .beats }
        if n.contains("keyboard") { return .keyboard }
        if n.contains("trackpad") { return .trackpad }
        if n.contains("mouse") { return .mouse }
        if n.contains("speaker") || n.contains("homepod") { return .speaker }
        if n.contains("headphone") || n.contains("buds") || n.contains("headset") { return .headphones }
        return .other
    }
}

/// A device that is connected right now and when it connected (`.distantPast` = it was already connected when Scout looked).
struct BluetoothConnection: Equatable {
    var info: BluetoothInfo
    var since: Date
}

@MainActor
final class BluetoothService: NSObject, ObservableObject {
    static let shared = BluetoothService()
    private var notification: IOBluetoothUserNotification?
    private var started = false
    /// Devices connected right now (the dashboard's AirPods / Bluetooth panel reads this).
    @Published private(set) var connections: [BluetoothConnection] = []
    private var disconnects: [String: IOBluetoothUserNotification] = [:]
    private var batteryTimer: Timer?

    static var wanted: Bool { Pref.bool("bluetooth.monitor", false) }

    func start() {
        guard !started else { return }
        started = true
        refresh()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Watches for connections only after the user allowed it (this is what triggers macOS's Bluetooth prompt).
    private func refresh() {
        guard !ScoutRuntime.isScripted else { return }
        if Self.wanted, notification == nil {
            notification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
            startBatteryWatch()
        } else if !Self.wanted, let n = notification {
            n.unregister()
            notification = nil
            stopBatteryWatch()
        }
    }

    // MARK: Connected devices (for the live panel)

    private func track(_ info: BluetoothInfo) {
        if let i = connections.firstIndex(where: { $0.info.name == info.name }) {
            if connections[i].info != info { connections[i].info = info }
        } else {
            connections.append(BluetoothConnection(info: info, since: Date()))
        }
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let name = device.name ?? String(localized: "Bluetooth device")
        note.unregister()
        disconnects[name] = nil
        connections.removeAll { $0.info.name == name }
    }

    private func startBatteryWatch() {
        #if !APPSTORE
        pollConnected()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollConnected() }
        }
        #endif
    }

    private func stopBatteryWatch() {
        batteryTimer?.invalidate()
        batteryTimer = nil
        disconnects.values.forEach { $0.unregister() }
        disconnects = [:]
        connections = []
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let name = device.name ?? String(localized: "Bluetooth device")
        let kind = BluetoothInfo.kind(forName: name, major: device.deviceClassMajor, minor: device.deviceClassMinor)
        let base = BluetoothInfo(name: name, kind: kind)
        track(base)
        disconnects[name]?.unregister()
        disconnects[name] = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        show(base)
        #if !APPSTORE
        // The battery numbers come from the system's own report; it takes a moment after connecting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            Task.detached {
                let levels = Self.batteryLevels(named: name)
                await MainActor.run {
                    guard let levels else { return }
                    var info = base
                    info.left = levels.left; info.right = levels.right; info.caseLevel = levels.caseLevel; info.single = levels.single
                    if info.hasBattery { self?.track(info); self?.show(info) }
                }
            }
        }
        #endif
    }

    private func show(_ info: BluetoothInfo) {
        LiveActivityCenter.shared.show(BluetoothActivity.make(info: info, expiresAfter: 4.5))
    }

    #if !APPSTORE
    /// Reads every connected device and its battery (now, and every 5 minutes while Bluetooth is watched).
    private func pollConnected() {
        Task.detached {
            let devices = Self.connectedDevices()
            if let devices { await self.apply(scan: devices) }
        }
    }

    private func apply(scan: [BluetoothInfo]) {
        var next = scan.map { info in
            BluetoothConnection(info: info, since: connections.first { $0.info.name == info.name }?.since ?? .distantPast)
        }
        // A device that just connected may not be in the system's report yet: keep it for a little while.
        for c in connections where Date().timeIntervalSince(c.since) < 30 && !scan.contains(where: { $0.name == c.info.name }) { next.append(c) }
        if next != connections { connections = next }
    }

    nonisolated private static func connectedDevices() -> [BluetoothInfo]? {
        guard let out = Shell.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"]),
              let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let top = (json["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = top["device_connected"] as? [[String: Any]] else { return nil }
        func percent(_ any: Any?) -> Int? {
            guard let s = any as? String else { return nil }
            return Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
        }
        var found: [BluetoothInfo] = []
        for entry in connected {
            for (name, value) in entry {
                guard let props = value as? [String: Any] else { continue }
                found.append(BluetoothInfo(name: name, kind: BluetoothInfo.kind(forName: name),
                                           left: percent(props["device_batteryLevelLeft"]), right: percent(props["device_batteryLevelRight"]),
                                           caseLevel: percent(props["device_batteryLevelCase"]), single: percent(props["device_batteryLevelMain"])))
            }
        }
        return found
    }

    /// `system_profiler SPBluetoothDataType -json` lists connected devices with their battery levels.
    nonisolated private static func batteryLevels(named name: String) -> (left: Int?, right: Int?, caseLevel: Int?, single: Int?)? {
        guard let out = Shell.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"]),
              let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let top = (json["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = top["device_connected"] as? [[String: Any]] else { return nil }
        func percent(_ any: Any?) -> Int? {
            guard let s = any as? String else { return nil }
            return Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
        }
        for entry in connected {
            guard let props = entry[name] as? [String: Any] else { continue }
            return (percent(props["device_batteryLevelLeft"]), percent(props["device_batteryLevelRight"]),
                    percent(props["device_batteryLevelCase"]), percent(props["device_batteryLevelMain"]))
        }
        return nil
    }
    #endif
}

enum BluetoothActivity {
    @MainActor
    static func make(info: BluetoothInfo, expiresAfter: TimeInterval? = 4.5) -> LiveActivity {
        LiveActivity(id: "bluetooth", kind: .bluetooth, expiresAfter: expiresAfter) {
            WingIcon(symbol: info.symbol, tint: .white, size: 15)
        } trailing: {
            if info.hasBattery {
                HStack(spacing: 4) {
                    if let l = info.left { WingRing(progress: Double(l) / 100, tint: ringTint(l), size: 15) }
                    if let r = info.right { WingRing(progress: Double(r) / 100, tint: ringTint(r), size: 15) }
                    if let c = info.caseLevel { WingRing(progress: Double(c) / 100, tint: ringTint(c), symbol: "battery.100percent", size: 15).opacity(0.85) }
                    if let s = info.single, info.left == nil, info.right == nil { WingText(verbatim: "\(s)%") }
                }
            } else {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(.green).frame(width: 22, height: 22)
            }
        }
        .withDetail { DemoDetail(title: Text(verbatim: info.name), subtitle: Text(verbatim: info.summary)) }
    }

    private static func ringTint(_ level: Int) -> Color { level <= 20 ? .red : (level <= 40 ? .orange : .green) }
}
