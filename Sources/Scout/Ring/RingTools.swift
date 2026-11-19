import AppKit
import SwiftUI

// B2 — what each ring tool does when it runs (a click on the slice, or a push-past option).

@MainActor
enum RingTools {
    static func run(_ tool: RingToolKind, option: RingOption? = nil) {
        switch tool {
        case .clipboard:
            if let option, let id = UUID(uuidString: option.id), let item = ClipboardStore.shared.items.first(where: { $0.id == id }) {
                ClipboardStore.shared.pick(item)
            } else {
                ClipboardPickerPanel.show()
            }
        case .screenshot:
            ScreenshotTool.capture(ScreenshotTool.Mode(rawValue: option?.id ?? "") ?? ScreenshotTool.defaultMode)
        case .askai:
            AskAIPlace.open(newChat: option?.id == "new")
        case .notes:
            NotesPanel.show(noteID: option.flatMap { UUID(uuidString: $0.id) })
        case .calculator:
            CalculatorPanel.show()
        case .todo:
            TodoPanel.show()
        case .volume:
            VolumeService.shared.toggleMute()
            Toast.show(VolumeService.shared.isMuted ? "Sound muted" : "Sound on", symbol: VolumeService.shared.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", style: .info)
        case .clock:
            ClockPanel.show(tab: option.flatMap { ClockTab(rawValue: $0.id) })
        case .units:
            UnitsPanel.show()
        case .links:
            LinksPanel.show()
        case .apps:
            if let option, let app = PinnedAppsStore.shared.apps.first(where: { $0.path == option.id }) {
                PinnedAppsStore.shared.open(app)
            } else {
                AppsPanel.show()
            }
        case .reminders:
            RemindersPanel.show()
        case .voicememo:
            if option?.id == "list" { VoiceMemoTool.showPanel() } else { VoiceMemoTool.runFromRing() }
        case .screenrecord:
            ScreenRecordTool.start(ScreenRecordTool.Mode(rawValue: option?.id ?? "") ?? .screen)
        case .colorpicker:
            ColorPickerTool.pick()
        }
    }
}
