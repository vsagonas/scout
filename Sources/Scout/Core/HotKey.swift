import AppKit
import Carbon.HIToolbox
import SwiftUI

// Global hotkeys through Carbon's RegisterEventHotKey: no Accessibility permission needed,
// and we get BOTH press and release (the ring opens on press and runs the pointed tool on release).

/// A keyboard shortcut: virtual key code + Cocoa modifier flags (⌘ ⌥ ⌃ ⇧ only).
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.relevantModifiers).rawValue
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: event.modifierFlags)
    }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        let f = modifierFlags
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    /// e.g. "⌥Space", "⌃⌘V".
    var display: String {
        let f = modifierFlags
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return s + KeyNames.name(for: keyCode)
    }

    /// e.g. "Option-Space", "Control-Command-V": for sentences, where the symbols alone are easy to misread.
    var spelled: String {
        let f = modifierFlags
        var parts: [String] = []
        if f.contains(.control) { parts.append(String(localized: "Control")) }
        if f.contains(.option) { parts.append(String(localized: "Option")) }
        if f.contains(.shift) { parts.append(String(localized: "Shift")) }
        if f.contains(.command) { parts.append(String(localized: "Command")) }
        return (parts + [KeyNames.name(for: keyCode)]).joined(separator: "-")
    }

    /// Function keys may stand alone; everything else needs at least one modifier.
    var isValidGlobalShortcut: Bool {
        !modifierFlags.isEmpty || KeyNames.isFunctionKey(keyCode)
    }

    /// Compact storage for @AppStorage: "keyCode:modifiers".
    var stringValue: String { "\(keyCode):\(modifiers)" }

    init?(string: String) {
        let parts = string.split(separator: ":")
        guard parts.count == 2, let k = UInt32(parts[0]), let m = UInt(parts[1]) else { return nil }
        keyCode = k
        modifiers = m
    }

    static let optionSpace = KeyCombo(keyCode: UInt32(kVK_Space), modifiers: .option)
}

enum KeyNames {
    private static let special: [UInt32: String] = [
        UInt32(kVK_Space): String(localized: "Space"), UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Escape): "⎋",
        UInt32(kVK_Delete): "⌫", UInt32(kVK_ForwardDelete): "⌦", UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓", UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5",
        UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10",
        UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12", UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14",
        UInt32(kVK_F15): "F15", UInt32(kVK_F16): "F16", UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20",
    ]

    private static let functionKeys: Set<UInt32> = [
        UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4), UInt32(kVK_F5), UInt32(kVK_F6),
        UInt32(kVK_F7), UInt32(kVK_F8), UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
        UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16), UInt32(kVK_F17), UInt32(kVK_F18),
        UInt32(kVK_F19), UInt32(kVK_F20),
    ]

    static func isFunctionKey(_ code: UInt32) -> Bool { functionKeys.contains(code) }

    /// Names keys from the ASCII-capable layout (so a Greek layout still shows "V", not "ω").
    static func name(for code: UInt32) -> String {
        if let s = special[code] { return s }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    /// The `NSMenuItem.keyEquivalent` that shows this key in a menu (Space, letters, digits), or nil.
    static func menuKeyEquivalent(for code: UInt32) -> String? {
        if code == UInt32(kVK_Space) { return " " }
        let n = name(for: code)
        return n.count == 1 && !n.hasPrefix("#") ? n.lowercased() : nil
    }
}

/// One registered global hotkey. Keep a strong reference; it unregisters on deinit.
final class HotKey {
    let combo: KeyCombo
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    fileprivate var ref: EventHotKeyRef?
    fileprivate let id: UInt32

    /// Returns nil when macOS refuses the combo (taken by the system or another app).
    init?(_ combo: KeyCombo, onPress: (() -> Void)? = nil, onRelease: (() -> Void)? = nil) {
        self.combo = combo
        self.onPress = onPress
        self.onRelease = onRelease
        HotKeyCenter.installIfNeeded()
        id = HotKeyCenter.nextID()
        guard register() else { return nil }
        HotKeyCenter.track(self)
    }

    fileprivate func register() -> Bool {
        let hotKeyID = EventHotKeyID(signature: HotKeyCenter.signature, id: id)
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let newRef else { return false }
        ref = newRef
        return true
    }

    fileprivate func unregisterRef() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    func unregister() {
        unregisterRef()
        HotKeyCenter.untrack(id)
    }

    deinit { unregister() }
}

enum HotKeyCenter {
    static let signature: OSType = {
        "SCOT".utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }()

    private final class WeakBox { weak var hotKey: HotKey?; init(_ h: HotKey) { hotKey = h } }
    private static var boxes: [UInt32: WeakBox] = [:]
    private static var counter: UInt32 = 0
    private static var installed = false
    private static var suspended = false

    static func nextID() -> UInt32 { counter += 1; return counter }
    fileprivate static func track(_ h: HotKey) { boxes[h.id] = WeakBox(h) }
    fileprivate static func untrack(_ id: UInt32) { boxes[id] = nil }

    /// While recording a new shortcut, every hotkey lets keys through.
    static func suspendAll() {
        guard !suspended else { return }
        suspended = true
        boxes.values.forEach { $0.hotKey?.unregisterRef() }
    }

    static func resumeAll() {
        guard suspended else { return }
        suspended = false
        boxes.values.forEach { _ = $0.hotKey?.register() }
    }

    static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard err == noErr, hotKeyID.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            HotKeyCenter.dispatch(id: hotKeyID.id, pressed: pressed)
            return noErr
        }, types.count, &types, nil, nil)
    }

    private static func dispatch(id: UInt32, pressed: Bool) {
        guard let hotKey = boxes[id]?.hotKey else { return }
        if pressed { hotKey.onPress?() } else { hotKey.onRelease?() }
    }
}

// MARK: - Shortcut recorder (used by every settings page that sets a shortcut)

struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    var placeholder: LocalizedStringKey = "Record Shortcut"

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var warning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: toggleRecording) {
                    (isRecording ? Text("Press a shortcut…") : (combo.map { Text(verbatim: $0.display) } ?? Text(placeholder)))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .frame(minWidth: 120)
                }
                .buttonStyle(.bordered)
                .tint(isRecording ? Theme.accent : nil)
                if combo != nil, !isRecording {
                    Button { combo = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear shortcut")
                }
            }
            if let warning {
                Text(verbatim: warning).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggleRecording() { isRecording ? stop() : start() }

    private func start() {
        warning = nil
        isRecording = true
        HotKeyCenter.suspendAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            if event.keyCode == UInt16(kVK_Delete), event.modifierFlags.intersection(KeyCombo.relevantModifiers).isEmpty {
                combo = nil; stop(); return nil
            }
            guard let newCombo = KeyCombo(event: event) else { return nil }
            guard newCombo.isValidGlobalShortcut else {
                warning = String(localized: "Add at least one modifier key, like ⌥ or ⌘.")
                return nil
            }
            combo = newCombo
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        HotKeyCenter.resumeAll()
    }
}
