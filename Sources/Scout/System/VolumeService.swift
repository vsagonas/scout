import AppKit
import CoreAudio
import SwiftUI

// Other parts of the app use this API: keep these names stable; add, don't rename.

struct AudioOutput: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
}

@MainActor
final class VolumeService: ObservableObject {
    static let shared = VolumeService()

    /// System output volume, 0…1.
    @Published private(set) var volume: Float = 0.5
    @Published private(set) var isMuted = false
    #if !APPSTORE
    /// Built-in display brightness, 0…1 (private DisplayServices: the App Store edition has no brightness).
    @Published private(set) var brightness: Float = 0.5
    #endif
    @Published private(set) var outputName = ""
    @Published private(set) var outputs: [AudioOutput] = []
    @Published private(set) var currentOutput: AudioDeviceID = 0
    #if !APPSTORE
    /// False on Macs without a controllable built-in display (and in scripted runs).
    @Published private(set) var hasBrightness = false
    #endif
    /// False when the current output has no volume control (some HDMI / DisplayPort outputs).
    @Published private(set) var canSetVolume = true

    /// Fired when volume, mute or brightness changed (by anyone). The HUD listens.
    let changes = PassthroughSubjectBox()

    private var device: AudioDeviceID = 0
    private var listenerBlocks: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var started = false
    #if !APPSTORE
    private var brightnessTimer: Timer?
    private var display: CGDirectDisplayID = 0
    #endif

    // MARK: Start

    func start() {
        guard !started else { return }
        started = true
        if ScoutRuntime.isScripted {
            volume = 0.6
            outputName = "MacBook Pro Speakers"
            outputs = [AudioOutput(id: 1, name: "MacBook Pro Speakers"), AudioOutput(id: 2, name: "AirPods Pro")]
            currentOutput = 1
            #if !APPSTORE
            hasBrightness = true
            brightness = 0.7
            #endif
            return
        }
        refreshOutputs()
        attachToDefaultDevice()
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.attachToDefaultDevice()
                self?.refreshOutputs()
                self?.changes.send()
            }
        }
        systemListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        var devices = Self.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshOutputs() }
        }
        #if !APPSTORE
        display = Brightness.builtInDisplay()
        if display != 0, let value = Brightness.get(display) {
            hasBrightness = true
            brightness = value
            brightnessTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollBrightness() }
            }
        }
        #endif
    }

    // MARK: Volume

    func setVolume(_ value: Float) {
        let clamped = max(0, min(1, value))
        volume = clamped
        if clamped > 0, isMuted { setMute(false) }
        guard !ScoutRuntime.isScripted, device != 0 else { return }
        var v = clamped
        var address = Self.address(Self.virtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        if AudioObjectHasProperty(device, &address) {
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &v)
        }
    }

    func toggleMute() { setMute(!isMuted) }

    func setMute(_ muted: Bool) {
        isMuted = muted
        guard !ScoutRuntime.isScripted, device != 0 else { return }
        var value: UInt32 = muted ? 1 : 0
        var address = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        if AudioObjectHasProperty(device, &address) {
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        } else {
            // No mute switch on this output: pretend with zero volume.
            if muted { preMuteVolume = volume; setVolume(0) } else { setVolume(max(0.05, preMuteVolume)) }
        }
    }

    private var preMuteVolume: Float = 0.4

    func setOutput(_ id: AudioDeviceID) {
        guard !ScoutRuntime.isScripted else { currentOutput = id; outputName = outputs.first { $0.id == id }?.name ?? ""; return }
        var target = id
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &target)
    }

    // MARK: Brightness

    #if !APPSTORE
    func setBrightness(_ value: Float) {
        let clamped = max(0, min(1, value))
        brightness = clamped
        guard !ScoutRuntime.isScripted, display != 0 else { return }
        Brightness.set(display, clamped)
    }

    private func pollBrightness() {
        guard let value = Brightness.get(display), abs(value - brightness) > 0.004 else { return }
        brightness = value
        changes.send()
    }
    #endif

    // MARK: CoreAudio plumbing

    private static var virtualMainVolume: AudioObjectPropertySelector { AudioObjectPropertySelector(0x766D7663) } // 'vmvc'

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func attachToDefaultDevice() {
        detachListeners()
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return }
        device = id
        currentOutput = id
        outputName = Self.name(of: id)
        readState()
        for selector in [Self.virtualMainVolume, kAudioDevicePropertyMute] {
            var addr = Self.address(selector, scope: kAudioDevicePropertyScopeOutput)
            guard AudioObjectHasProperty(id, &addr) else { continue }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.readState()
                    self?.changes.send()
                }
            }
            AudioObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main, block)
            listenerBlocks.append((addr, block))
        }
    }

    private func detachListeners() {
        for (var addr, block) in listenerBlocks where device != 0 {
            AudioObjectRemovePropertyListenerBlock(device, &addr, DispatchQueue.main, block)
        }
        listenerBlocks.removeAll()
    }

    private func readState() {
        guard device != 0 else { return }
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = Self.address(Self.virtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        canSetVolume = AudioObjectHasProperty(device, &address)
        if canSetVolume, AudioObjectGetPropertyData(device, &address, 0, nil, &size, &v) == noErr, abs(v - volume) > 0.0005 { volume = v }
        var m = UInt32(0)
        var msize = UInt32(MemoryLayout<UInt32>.size)
        var maddr = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        if AudioObjectHasProperty(device, &maddr), AudioObjectGetPropertyData(device, &maddr, 0, nil, &msize, &m) == noErr {
            let muted = m != 0
            if muted != isMuted { isMuted = muted }
        }
    }

    private func refreshOutputs() {
        var size = UInt32(0)
        var address = Self.address(kAudioHardwarePropertyDevices)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return }
        let list = ids.compactMap { id -> AudioOutput? in
            var streams = Self.address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            var s = UInt32(0)
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &s) == noErr, s > 0 else { return nil }
            return AudioOutput(id: id, name: Self.name(of: id))
        }
        if list != outputs { outputs = list }
    }

    private static func name(of id: AudioDeviceID) -> String {
        var address = Self.address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return String(localized: "Output") }
        return name.takeRetainedValue() as String
    }
}

/// A tiny "something changed" signal (kept free of Combine so views can ignore it).
@MainActor
final class PassthroughSubjectBox {
    private var handlers: [UUID: () -> Void] = [:]

    @discardableResult
    func sink(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    func cancel(_ id: UUID) { handlers[id] = nil }
    func send() { handlers.values.forEach { $0() } }
}

// MARK: - Brightness (DisplayServices is a private framework: loaded at runtime, every call optional; not in the App Store edition)

#if !APPSTORE
enum Brightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle: UnsafeMutableRawPointer? = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getFn: GetFn? = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn: SetFn? = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetFn.self) }

    static func builtInDisplay() -> CGDirectDisplayID {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        guard CGGetActiveDisplayList(8, &ids, &count) == .success else { return 0 }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 } ?? 0
    }

    static func get(_ display: CGDirectDisplayID) -> Float? {
        guard let getFn else { return nil }
        var value: Float = 0
        return getFn(display, &value) == 0 ? value : nil
    }

    static func set(_ display: CGDirectDisplayID, _ value: Float) {
        _ = setFn?(display, value)
    }
}
#endif
