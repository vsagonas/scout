import AppKit
import SwiftUI

// A7 — the HUD (volume and brightness next to the notch), the Volume widget, and the key-tap replacement.
// The App Store edition has the volume HUD only: brightness (private DisplayServices) and the key tap are compiled out.

enum HUDKind {
    case volume
    #if !APPSTORE
    case brightness
    #endif
}

extension HUDKind {
    @MainActor
    func value(_ service: VolumeService) -> Float {
        #if !APPSTORE
        if self == .brightness { return service.brightness }
        #endif
        return service.volume
    }

    /// The icon for this level (volume has its own speaker symbols).
    func symbol(value: Float, muted: Bool) -> String {
        #if !APPSTORE
        if self == .brightness { return value < 0.3 ? "sun.min.fill" : "sun.max.fill" }
        #endif
        return volumeSymbol(volume: value, muted: muted)
    }
}

func volumeSymbol(volume: Float, muted: Bool) -> String {
    if muted || volume <= 0.001 { return "speaker.slash.fill" }
    if volume < 0.34 { return "speaker.wave.1.fill" }
    if volume < 0.67 { return "speaker.wave.2.fill" }
    return "speaker.wave.3.fill"
}

enum HUDActivity {
    /// `fixed` is only for the gallery (a still picture); live HUDs read the service as it changes.
    @MainActor
    static func make(kind: HUDKind, value: Float, muted: Bool, service: VolumeService? = nil, expiresAfter: TimeInterval? = 1.5) -> LiveActivity {
        let service = service ?? VolumeService.shared
        let fixed: (Float, Bool)? = service === VolumeService.shared ? nil : (value, muted)
        return LiveActivity(id: "hud", kind: .hud, expiresAfter: expiresAfter) {
            HUDIcon(kind: kind, service: service, fixed: fixed)
        } trailing: {
            HUDBar(kind: kind, service: service, fixed: fixed)
        }
    }
}

private struct HUDIcon: View {
    let kind: HUDKind
    @ObservedObject var service: VolumeService
    var fixed: (Float, Bool)?

    var body: some View {
        let value = fixed?.0 ?? kind.value(service)
        let muted = fixed?.1 ?? service.isMuted
        Image(systemName: kind.symbol(value: value, muted: muted))
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
    }
}

private struct HUDBar: View {
    let kind: HUDKind
    @ObservedObject var service: VolumeService
    var fixed: (Float, Bool)?

    var body: some View {
        let value = fixed?.0 ?? kind.value(service)
        let muted = (fixed?.1 ?? service.isMuted) && kind == .volume
        SegmentBar(value: muted ? 0 : Double(value), segments: 14, tint: .white, height: 5)
            .frame(width: 70)
    }
}

/// Shows the HUD whenever volume, mute or brightness change.
@MainActor
final class HUDController {
    static let shared = HUDController()
    private var lastVolume: Float?
    private var lastMuted = false
    #if !APPSTORE
    private var lastBrightness: Float?
    #endif
    private var armed = false

    func start() {
        let service = VolumeService.shared
        lastVolume = service.volume
        lastMuted = service.isMuted
        #if !APPSTORE
        lastBrightness = service.brightness
        #endif
        // Ignore the settling at launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.armed = true }
        service.changes.sink { [weak self] in self?.changed() }
    }

    private func changed() {
        guard armed else { return }
        let service = VolumeService.shared
        let volumeChanged = lastVolume.map { abs($0 - service.volume) > 0.0005 } ?? true || lastMuted != service.isMuted
        lastVolume = service.volume
        lastMuted = service.isMuted
        #if !APPSTORE
        let brightnessChanged = lastBrightness.map { abs($0 - service.brightness) > 0.004 } ?? false
        lastBrightness = service.brightness
        #endif
        if volumeChanged {
            LiveActivityCenter.shared.show(HUDActivity.make(kind: .volume, value: service.volume, muted: service.isMuted))
            return
        }
        #if !APPSTORE
        if brightnessChanged, Pref.bool("hud.brightness", true) {
            LiveActivityCenter.shared.show(HUDActivity.make(kind: .brightness, value: service.brightness, muted: false))
        }
        #endif
    }
}

// MARK: - Key tap (replaces the system pop-up; needs Accessibility; not in the App Store edition)

#if !APPSTORE
@MainActor
final class MediaKeyTap {
    static let shared = MediaKeyTap()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var started = false

    var isRunning: Bool { tap != nil }
    static var wanted: Bool { Pref.bool("hud.replaceSystem", false) }

    func start() {
        guard !started else { return }
        started = true
        refresh()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Starts or stops the tap to match the setting and the Accessibility permission.
    func refresh() {
        let shouldRun = Self.wanted && !ScoutRuntime.isScripted && Permissions.accessibilityGranted
        if shouldRun, tap == nil { install() } else if !shouldRun, tap != nil { remove() }
    }

    private func install() {
        let mask = CGEventMask(1 << 14)   // NX_SYSDEFINED
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: { _, type, event, _ in
            MediaKeyTap.handle(type: type, event: event)
        }, userInfo: nil) else { return }
        tap = port
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func remove() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func reenable() { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }

    nonisolated static func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated { MediaKeyTap.shared.reenable() }
            return passThrough
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return passThrough }
        let data = ns.data1
        let code = (data & 0xFFFF_0000) >> 16
        let flags = data & 0x0000_FFFF
        let isDown = ((flags & 0xFF00) >> 8) == 0xA
        let isRepeat = (flags & 0x1) != 0
        guard [0, 1, 2, 3, 7].contains(code) else { return passThrough }
        let fine = ns.modifierFlags.contains([.option, .shift])
        let handled = MainActor.assumeIsolated { MediaKeyTap.shared.press(code: code, down: isDown, isRepeat: isRepeat, fine: fine) }
        return handled ? nil : passThrough
    }

    /// Returns true when the key was ours (swallow it).
    private func press(code: Int, down: Bool, isRepeat: Bool, fine: Bool) -> Bool {
        let service = VolumeService.shared
        if (code == 2 || code == 3), !service.hasBrightness { return false }
        guard down else { return true }
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16
        switch code {
        case 0: service.setVolume(((service.volume / step).rounded() + 1) * step)
        case 1: service.setVolume(((service.volume / step).rounded() - 1) * step)
        case 7: if !isRepeat { service.toggleMute() }
        case 2: service.setBrightness(((service.brightness / step).rounded() + 1) * step)
        case 3: service.setBrightness(((service.brightness / step).rounded() - 1) * step)
        default: break
        }
        // The listeners fire for volume; brightness has no listener, so announce it here.
        if code == 2 || code == 3 { service.changes.send() }
        return true
    }
}
#endif

// MARK: - Volume widget

struct VolumeSlider: View {
    @ObservedObject var service: VolumeService
    var height: CGFloat = 34

    var body: some View {
        GeometryReader { geo in
            let value = service.isMuted ? 0 : CGFloat(service.volume)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.14))
                Capsule().fill(Color.primary.opacity(0.9)).frame(width: max(height, geo.size.width * value))
                Image(systemName: volumeSymbol(volume: service.volume, muted: service.isMuted))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(value > 0.12 ? Color(nsColor: .windowBackgroundColor).opacity(0.9) : Color.primary.opacity(0.85))
                    .frame(width: height)
                    .allowsHitTesting(false)
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                service.setVolume(Float(max(0, min(1, drag.location.x / max(1, geo.size.width)))))
            })
        }
        .frame(height: height)
    }
}

struct VolumeWidgetView: View {
    @ObservedObject private var service = VolumeService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text("Volume").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(service.isMuted ? "Muted" : "\(Int((service.volume * 100).rounded())) %")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
            }
            VolumeSlider(service: service)
            HStack(spacing: 6) {
                Menu {
                    ForEach(service.outputs) { output in
                        Button {
                            service.setOutput(output.id)
                        } label: {
                            if output.id == service.currentOutput { Label(output.name, systemImage: "checkmark") } else { Text(output.name) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "hifispeaker").font(.system(size: 10))
                        Text(service.outputName.isEmpty ? String(localized: "Output") : service.outputName).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { service.toggleMute() } label: {
                    Image(systemName: service.isMuted ? "speaker.slash.fill" : "speaker.fill").font(.system(size: 11))
                        .foregroundStyle(service.isMuted ? Theme.accent : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(service.isMuted ? "Unmute" : "Mute")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Settings page

struct HUDSettingsPane: View {
    @ObservedObject private var service = VolumeService.shared
    @AppStorage("activity.hud.enabled") private var hudOn = true
    #if !APPSTORE
    @AppStorage("hud.brightness") private var brightnessHUD = true
    @AppStorage("hud.replaceSystem") private var replaceSystem = false
    @State private var accessibility = Permissions.accessibilityGranted
    #endif

    var body: some View {
        Form {
            popUpSection
            #if !APPSTORE
            replaceSection
            #endif
            Section("Volume now") {
                LabeledContent("Output") {
                    Picker("", selection: Binding(get: { service.currentOutput }, set: { service.setOutput($0) })) {
                        ForEach(service.outputs) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().frame(maxWidth: 240)
                }
                VolumeSlider(service: service).padding(.vertical, 4)
                #if !APPSTORE
                if service.hasBrightness {
                    LabeledContent("Brightness") {
                        Slider(value: Binding(get: { Double(service.brightness) }, set: { service.setBrightness(Float($0)) }), in: 0...1)
                            .frame(width: 200)
                    }
                }
                #endif
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        #if !APPSTORE
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibility = Permissions.accessibilityGranted
        }
        #endif
    }

    private var popUpSection: some View {
        Section {
            #if APPSTORE
            Toggle("Show the volume next to the notch", isOn: $hudOn).toggleStyle(.switch)
            #else
            Toggle("Show volume and brightness next to the notch", isOn: $hudOn).toggleStyle(.switch)
            Toggle("Include brightness", isOn: $brightnessHUD).toggleStyle(.switch)
                .disabled(!hudOn || !service.hasBrightness)
            if !service.hasBrightness {
                Text("This Mac has no display Scout can dim.").font(.caption).foregroundStyle(.secondary)
            }
            #endif
        } header: {
            Text("Pop-up")
        } footer: {
            #if APPSTORE
            SettingsFootnote("When you change the volume with the keys, the menu bar or another app, the level also shows next to the notch.")
            #endif
        }
    }

    #if !APPSTORE
    private var replaceSection: some View {
        Section {
            Toggle("Use Scout's pop-up instead of macOS's", isOn: $replaceSystem).toggleStyle(.switch)
            if replaceSystem, !accessibility {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Needs Accessibility")
                        Text("Without it nothing changes: macOS keeps its own pop-up.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Allow…") { Permissions.requestAccessibility() }
                    Button("Open Settings") { Permissions.openSettings(.accessibility) }
                }
            } else if replaceSystem {
                StatusPill("Working: the volume and brightness keys are Scout's", tone: .good)
            }
        } header: {
            Text("Replace the system pop-up")
        } footer: {
            SettingsFootnote("Hold ⌥⇧ with a volume or brightness key for quarter steps.")
        }
    }
    #endif
}
