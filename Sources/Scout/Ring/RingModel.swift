import AppKit
import SwiftUI

// B1/B2 — what the ring is made of: the 15 tools, their push-past options, and the user's ring settings.

enum RingToolKind: String, CaseIterable, Identifiable, Codable {
    case clipboard, screenshot, askai, notes, calculator, todo, volume, clock
    case units, links, apps, reminders, voicememo, screenrecord, colorpicker

    var id: String { rawValue }

    /// Default order: ring 1 then ring 2.
    static let defaultOrder: [RingToolKind] = allCases

    var title: String {
        switch self {
        case .clipboard: String(localized: "Clipboard")
        case .screenshot: String(localized: "Screenshot")
        case .askai: String(localized: "Ask AI")
        case .notes: String(localized: "Notes")
        case .calculator: String(localized: "Calculator")
        case .todo: String(localized: "To-do")
        case .volume: String(localized: "Volume")
        case .clock: String(localized: "Clock")
        case .units: String(localized: "Units")
        case .links: String(localized: "Links")
        case .apps: String(localized: "Apps")
        case .reminders: String(localized: "Reminders")
        case .voicememo: String(localized: "Voice Memo")
        case .screenrecord: String(localized: "Screen Record")
        case .colorpicker: String(localized: "Color Picker")
        }
    }

    var symbol: String {
        switch self {
        case .clipboard: "doc.on.clipboard"
        case .screenshot: "camera.viewfinder"
        case .askai: "sparkles"
        case .notes: "note.text"
        case .calculator: "plus.forwardslash.minus"
        case .todo: "checklist"
        case .volume: "speaker.wave.2.fill"
        case .clock: "timer"
        case .units: "ruler"
        case .links: "link"
        case .apps: "square.grid.2x2"
        case .reminders: "bell"
        case .voicememo: "mic.fill"
        case .screenrecord: "record.circle"
        case .colorpicker: "eyedropper"
        }
    }

    /// A short line shown in the ring's hub while the tool is highlighted.
    var subtitle: String {
        switch self {
        case .clipboard: String(localized: "Recent copies")
        case .screenshot: String(localized: "Capture a region")
        case .askai: String(localized: "Ask Claude or GPT")
        case .notes: String(localized: "Quick scratchpad")
        case .calculator: String(localized: "Type a sum")
        case .todo: String(localized: "Your checklist")
        case .volume: String(localized: "Tap to mute")
        case .clock: String(localized: "Timers and alarms")
        case .units: String(localized: "Convert anything")
        case .links: String(localized: "Saved links")
        case .apps: String(localized: "Your pinned apps")
        case .reminders: String(localized: "Add or check off")
        case .voicememo: String(localized: "Record right away")
        case .screenrecord: String(localized: "Film the screen")
        case .colorpicker: String(localized: "Pick from the screen")
        }
    }

    /// Needs the Accessibility permission to do its job (none does since the Windows tool went, 2026-11-16).
    var needsAccessibility: Bool { false }
}

struct RingOption: Identifiable, Equatable {
    enum Kind: Equatable { case action, slider, mute }

    let id: String
    var title: String
    var symbol: String
    var kind: Kind = .action
    /// For pinned apps: the app's path (the hub and the ring draw its icon).
    var iconPath: String?
}

// MARK: - The user's ring settings

enum RingLook: String, CaseIterable, Identifiable {
    case native, studio, tinted
    var id: String { rawValue }
    var title: String {
        switch self {
        case .native: String(localized: "Native")
        case .studio: String(localized: "Studio")
        case .tinted: String(localized: "Tinted")
        }
    }
}

enum RingSize: String, CaseIterable, Identifiable {
    case compact, regular
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: String(localized: "Compact")
        case .regular: String(localized: "Regular")
        }
    }
    var outer: CGFloat { self == .compact ? 110 : 140 }
    var inner: CGFloat { self == .compact ? 42 : 52 }
}

#if !APPSTORE
enum MouseTrigger: String, CaseIterable, Identifiable {
    case off, middle, back, forward
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .middle: String(localized: "Middle button")
        case .back: String(localized: "Back button")
        case .forward: String(localized: "Forward button")
        }
    }
    /// `NSEvent.buttonNumber`
    var buttonNumber: Int? {
        switch self {
        case .off: nil
        case .middle: 2
        case .back: 3
        case .forward: 4
        }
    }
}
#endif

enum RingConfig {
    static var hotkey: KeyCombo? {
        let raw = UserDefaults.standard.string(forKey: "ring.hotkey") ?? KeyCombo.optionSpace.stringValue
        if raw.isEmpty { return nil }
        return KeyCombo(string: raw) ?? .optionSpace
    }

    static var look: RingLook { RingLook(rawValue: UserDefaults.standard.string("ring.look", default: "native")) ?? .native }
    static var size: RingSize { RingSize(rawValue: UserDefaults.standard.string("ring.size", default: "regular")) ?? .regular }
    static var showsNumbers: Bool { UserDefaults.standard.bool("ring.numbers", default: true) }
    static var haptics: Bool { UserDefaults.standard.bool("ring.haptics", default: true) }
    #if !APPSTORE
    static var mouseTrigger: MouseTrigger { MouseTrigger(rawValue: UserDefaults.standard.string("ring.mouseButton", default: "off")) ?? .off }
    #endif
    static var tint: Color { Color(hex: UserDefaults.standard.string("ring.tint", default: "#3B6FD8")) ?? Theme.accent }

    /// All the tools in the user's order (missing ones appended; an id an older version saved, like the Windows tool, is skipped).
    static var order: [RingToolKind] {
        let saved = StoredList.strings("ring.order").compactMap(RingToolKind.init(rawValue:))
        var seen = Set<RingToolKind>()
        var list = saved.filter { seen.insert($0).inserted }
        list.append(contentsOf: RingToolKind.defaultOrder.filter { !seen.contains($0) })
        return list
    }

    static var disabled: Set<RingToolKind> {
        Set(StoredList.strings("ring.disabled").compactMap(RingToolKind.init(rawValue:)))
    }

    static func setOrder(_ list: [RingToolKind]) { StoredList.set(list.map(\.rawValue), key: "ring.order") }
    static func setDisabled(_ set: Set<RingToolKind>) { StoredList.set(set.map(\.rawValue).sorted(), key: "ring.disabled") }

    static var enabledTools: [RingToolKind] {
        let off = disabled
        let list = order.filter { !off.contains($0) }
        return list.isEmpty ? [.calculator] : list
    }

    /// Rings of up to eight tools.
    static var pages: [[RingToolKind]] { paged(enabledTools) }

    static func paged(_ tools: [RingToolKind]) -> [[RingToolKind]] {
        stride(from: 0, to: tools.count, by: 8).map { Array(tools[$0..<min($0 + 8, tools.count)]) }
    }
}

// MARK: - Options for push-past

@MainActor
extension RingToolKind {
    func options() -> [RingOption] {
        switch self {
        case .screenshot:
            return [RingOption(id: "region", title: String(localized: "Region"), symbol: "rectangle.dashed"),
                    RingOption(id: "window", title: String(localized: "Window"), symbol: "macwindow"),
                    RingOption(id: "screen", title: String(localized: "Screen"), symbol: "display")]
        case .screenrecord:
            return [RingOption(id: "screen", title: String(localized: "Screen"), symbol: "display"),
                    RingOption(id: "window", title: String(localized: "Window"), symbol: "macwindow"),
                    RingOption(id: "mic", title: String(localized: "With microphone"), symbol: "mic.fill")]
        case .apps:
            return PinnedAppsStore.shared.apps.map { RingOption(id: $0.path, title: $0.name, symbol: "app", iconPath: $0.path) }
        case .volume:
            return [RingOption(id: "mute", title: String(localized: "Mute"), symbol: "speaker.slash.fill", kind: .mute),
                    RingOption(id: "slider", title: String(localized: "Volume"), symbol: "speaker.wave.2.fill", kind: .slider)]
        case .clock:
            return [RingOption(id: "timer", title: String(localized: "Timer"), symbol: "timer"),
                    RingOption(id: "stopwatch", title: String(localized: "Stopwatch"), symbol: "stopwatch"),
                    RingOption(id: "pomodoro", title: String(localized: "Pomodoro"), symbol: "leaf"),
                    RingOption(id: "alarms", title: String(localized: "Alarm"), symbol: "alarm")]
        case .clipboard:
            return ClipboardStore.shared.ordered().prefix(5).map { item in
                RingOption(id: item.id.uuidString, title: item.preview.isEmpty ? item.kind.title : String(item.preview.prefix(28)), symbol: item.kind.symbol)
            }
        case .notes:
            return NotesStore.shared.recent(4).map { RingOption(id: $0.id.uuidString, title: $0.title, symbol: "note.text") }
        case .askai:
            return [RingOption(id: "new", title: String(localized: "New chat"), symbol: "square.and.pencil")]
        case .voicememo:
            return [RingOption(id: "record", title: String(localized: "Record"), symbol: "mic.fill"),
                    RingOption(id: "list", title: String(localized: "Memos"), symbol: "list.bullet")]
        default:
            return []
        }
    }

    /// The hub's second line: live where it helps, otherwise the tool's fixed subtitle.
    var liveSubtitle: String {
        switch self {
        case .clipboard:
            let n = ClipboardStore.shared.items.count
            return n == 0 ? String(localized: "Nothing copied yet") : String(localized: "Items: \(n)")
        case .todo:
            let n = TodoStore.shared.openCount
            return n == 0 ? String(localized: "All done") : String(localized: "\(n) open")
        case .notes:
            let n = NotesStore.shared.notes.count
            return n == 0 ? String(localized: "Quick scratchpad") : String(localized: "Notes: \(n)")
        case .volume:
            let v = VolumeService.shared
            return v.isMuted ? String(localized: "Muted") : String(localized: "\(Int((v.volume * 100).rounded()))% — tap to mute")
        case .clock:
            let n = ClockService.shared.timers.filter(\.isRunning).count
            return n == 0 ? subtitle : String(localized: "Timers running: \(n)")
        default:
            return subtitle
        }
    }
}
