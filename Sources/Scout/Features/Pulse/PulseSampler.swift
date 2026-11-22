import AppKit
import Darwin
import IOKit
import IOKit.ps
import SwiftUI

enum PulseMetric: String, CaseIterable, Identifiable {
    case cpu, memory, gpu, disk, battery, network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: String(localized: "Memory")
        case .gpu: "GPU"
        case .disk: String(localized: "Disk")
        case .battery: String(localized: "Battery")
        case .network: String(localized: "Network")
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .gpu: "display"
        case .disk: "internaldrive"
        case .battery: "battery.75percent"
        case .network: "arrow.up.arrow.down"
        }
    }

    var color: Color {
        switch self {
        case .cpu: Color(red: 0.38, green: 0.67, blue: 1.0)
        case .memory: Color(red: 0.72, green: 0.52, blue: 1.0)
        case .gpu: Color(red: 0.35, green: 0.85, blue: 0.62)
        case .disk: Color(red: 1.0, green: 0.72, blue: 0.30)
        case .battery: Color(red: 0.55, green: 0.90, blue: 0.40)
        case .network: Color(red: 0.30, green: 0.85, blue: 0.95)
        }
    }
}

/// One reading of everything (all optional: a Mac without a battery has none, GPU may not report).
struct PulseSample {
    var cpu: Double = 0          // 0...1
    var memory: Double = 0       // 0...1
    var memoryUsedBytes: Int64 = 0
    var gpu: Double?             // 0...1
    var disk: Double = 0         // 0...1 used
    var diskFreeBytes: Int64 = 0
    var battery: Double?         // 0...1
    var charging = false
    var netDown: Double = 0      // bytes per second
    var netUp: Double = 0
}

/// Samples the Mac every 1.5 s, only while a Pulse widget is on screen.
@MainActor
final class PulseSampler: ObservableObject {
    static let shared = PulseSampler()

    static let historyLength = 40

    @Published private(set) var latest = PulseSample()
    /// Normalized 0...1 history per metric (network: relative to the largest recent value).
    @Published private(set) var history: [PulseMetric: [Double]] = [:]
    @Published private(set) var netDownHistory: [Double] = []
    @Published private(set) var netUpHistory: [Double] = []
    /// Metrics this Mac (or the sandbox) doesn't give us: the GPU read can be blocked, a desktop has no battery.
    @Published private(set) var unavailable: Set<PulseMetric> = []
    private var gpuMisses = 0

    private var timer: Timer?
    private var holders = 0
    private var previousCPU: [UInt32]?
    private var previousNet: (counters: [String: (down: UInt32, up: UInt32)], at: Date)?

    // MARK: Lifecycle (visible widgets)

    /// One quick look at what can be read, so settings and widgets can hide the rest.
    func probe() {
        if ScoutRuntime.isGallery { return }
        var missing: Set<PulseMetric> = []
        if readGPU() == nil { missing.insert(.gpu) }
        if readBattery().0 == nil { missing.insert(.battery) }
        if missing != unavailable { unavailable = missing }
    }

    func acquire() {
        holders += 1
        guard timer == nil else { return }
        if ScoutRuntime.isGallery { loadSamples(); return }
        probe()
        sampleNow()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleNow() }
        }
    }

    func release() {
        holders = max(0, holders - 1)
        if holders == 0 { timer?.invalidate(); timer = nil; previousCPU = nil; previousNet = nil }
    }

    // MARK: Sampling

    func sampleNow() {
        var s = PulseSample()
        s.cpu = readCPU()
        (s.memory, s.memoryUsedBytes) = readMemory()
        s.gpu = readGPU()
        (s.disk, s.diskFreeBytes) = readDisk()
        (s.battery, s.charging) = readBattery()
        (s.netDown, s.netUp) = readNetwork()
        latest = s
        push(.cpu, s.cpu)
        push(.memory, s.memory)
        if let g = s.gpu { push(.gpu, g); gpuMisses = 0; unavailable.remove(.gpu) }
        else { gpuMisses += 1; if gpuMisses >= 2 { unavailable.insert(.gpu) } }
        push(.disk, s.disk)
        if let b = s.battery { push(.battery, b) }
        netDownHistory = Self.appended(netDownHistory, s.netDown)
        netUpHistory = Self.appended(netUpHistory, s.netUp)
        let peak = max(1024, (netDownHistory + netUpHistory).max() ?? 1)
        history[.network] = netDownHistory.map { min(1, $0 / peak) }
    }

    private func push(_ metric: PulseMetric, _ value: Double) {
        history[metric] = Self.appended(history[metric] ?? [], min(1, max(0, value)))
    }

    private static func appended(_ array: [Double], _ value: Double) -> [Double] {
        var a = array
        a.append(value)
        if a.count > historyLength { a.removeFirst(a.count - historyLength) }
        return a
    }

    private func readCPU() -> Double {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS, let info else { return 0 }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)) }
        var ticks: [UInt32] = []
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            ticks += [UInt32(info[base + Int(CPU_STATE_USER)]), UInt32(info[base + Int(CPU_STATE_SYSTEM)]),
                      UInt32(info[base + Int(CPU_STATE_IDLE)]), UInt32(info[base + Int(CPU_STATE_NICE)])]
        }
        defer { previousCPU = ticks }
        guard let previous = previousCPU, previous.count == ticks.count else { return 0 }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for i in stride(from: 0, to: ticks.count, by: 4) {
            let user = UInt64(ticks[i] &- previous[i])
            let system = UInt64(ticks[i + 1] &- previous[i + 1])
            let idle = UInt64(ticks[i + 2] &- previous[i + 2])
            let nice = UInt64(ticks[i + 3] &- previous[i + 3])
            busy += user + system + nice
            total += user + system + nice + idle
        }
        return total == 0 ? 0 : Double(busy) / Double(total)
    }

    private func readMemory() -> (Double, Int64) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let page = Int64(vm_kernel_page_size)
        let used = (Int64(stats.active_count) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        return (min(1, Double(used) / Double(max(1, total))), used)
    }

    /// Can this process read the GPU counters? (The sandbox may say no.)
    func gpuReadable() -> Bool { readGPU() != nil }

    private func readGPU() -> Double? {
        guard let matching = IOServiceMatching("IOAccelerator") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let perf = dict["PerformanceStatistics"] as? [String: Any] else { continue }
            if let n = perf["Device Utilization %"] as? NSNumber { best = max(best ?? 0, n.doubleValue / 100) }
        }
        return best
    }

    private func readDisk() -> (Double, Int64) {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity, total > 0 else { return (0, 0) }
        let free = v.volumeAvailableCapacityForImportantUsage ?? 0
        return (min(1, max(0, 1 - Double(free) / Double(total))), free)
    }

    private func readBattery() -> (Double?, Bool) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false) }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let current = desc[kIOPSCurrentCapacityKey] as? Int, let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = (desc[kIOPSIsChargingKey] as? Bool) ?? ((desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
            return (Double(current) / Double(max), charging)
        }
        return (nil, false)
    }

    /// Byte counters per interface (32-bit in `if_data`, so deltas use wrapping subtraction).
    /// Only the Mac's own ports (Wi-Fi and Ethernet are "en…"): a VPN's tunnel ("utun…", "ipsec…") carries the same bytes again, and the
    /// AirDrop and bridge links ("awdl…", "llw…", "bridge…", "ap…", "anpi…") are not the internet.
    static func countsTowardInternet(_ name: String) -> Bool { name.hasPrefix("en") }

    private func readNetwork() -> (Double, Double) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (0, 0) }
        defer { freeifaddrs(head) }
        var counters: [String: (down: UInt32, up: UInt32)] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let c = cursor {
            defer { cursor = c.pointee.ifa_next }
            guard let addr = c.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  (c.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0, (c.pointee.ifa_flags & UInt32(IFF_UP)) != 0,
                  Self.countsTowardInternet(String(cString: c.pointee.ifa_name)),
                  let data = c.pointee.ifa_data else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            counters[String(cString: c.pointee.ifa_name)] = (d.ifi_ibytes, d.ifi_obytes)
        }
        let now = Date()
        defer { previousNet = (counters, now) }
        guard let p = previousNet, now.timeIntervalSince(p.at) > 0.2 else { return (0, 0) }
        var down: UInt64 = 0
        var up: UInt64 = 0
        for (name, now) in counters {
            guard let before = p.counters[name] else { continue }
            down += UInt64(now.down &- before.down)
            up += UInt64(now.up &- before.up)
        }
        let dt = Date().timeIntervalSince(p.at)
        return (Double(down) / dt, Double(up) / dt)
    }

    // MARK: Sample data (gallery)

    func loadSamples() {
        func wave(_ base: Double, _ amp: Double, _ phase: Double) -> [Double] {
            (0..<Self.historyLength).map { i in
                let x = Double(i) / 5 + phase
                return min(1, max(0.02, base + amp * sin(x) * 0.6 + amp * sin(x * 2.3 + 1) * 0.4))
            }
        }
        history = [.cpu: wave(0.34, 0.26, 0), .memory: wave(0.62, 0.05, 1), .gpu: wave(0.18, 0.15, 2),
                   .disk: wave(0.55, 0.002, 0), .battery: wave(0.78, 0.01, 0), .network: wave(0.30, 0.28, 3)]
        netDownHistory = history[.network]!.map { $0 * 3_200_000 }
        netUpHistory = history[.network]!.map { $0 * 420_000 }
        latest = Self.sample()
    }

    /// Tests: forget the sample data again (the readings and the graphs' history), as before `loadSamples()`.
    func clearSamples() {
        latest = PulseSample()
        history = [:]
        netDownHistory = []
        netUpHistory = []
    }

    /// The reading the pictures and tests show (CPU 37 %, memory 64 %, GPU 21 %); a Mac that reports no GPU load is `gpu: nil`.
    static func sample(cpu: Double = 0.37, memory: Double = 0.64, gpu: Double? = 0.21) -> PulseSample {
        PulseSample(cpu: cpu, memory: memory, memoryUsedBytes: 16_400_000_000, gpu: gpu, disk: 0.55, diskFreeBytes: 210_000_000_000,
                    battery: 0.78, charging: false, netDown: 1_450_000, netUp: 310_000)
    }
}
