import SwiftUI

// Gallery items for the productivity part's notch faces and settings pages.

@MainActor
enum ProductivityGallery {
    private static func widget<V: View>(_ name: String, cells: Int, @ViewBuilder _ content: @escaping () -> V) {
        let w = CGFloat(cells) * NookMetrics.cell
        // A black "notch" slab (the Classic look) and a lighter one, so both readings are visible.
        Gallery.register("widget-\(name)", size: CGSize(width: w + 32, height: NookMetrics.widgetHeight + 32)) {
            content().frame(width: w, height: NookMetrics.widgetHeight)
                .nookPanelFace()
        }
    }

    private static func settings<V: View>(_ name: String, height: CGFloat, @ViewBuilder _ content: @escaping () -> V) {
        Gallery.register("settings-\(name)", size: CGSize(width: 640, height: height), backdrop: .window) {
            ScrollView { content().padding(24) }
        }
    }

    static func register() {
        widget("timer-idle", cells: 3) { TimerWidgetView(clock: .demo(running: false)) }
        widget("timer-running", cells: 3) { TimerWidgetView(clock: .demo(running: true)) }
        widget("pomodoro", cells: 3) { PomodoroWidgetView(clock: .demo(running: true)) }
        widget("pomodoro-idle", cells: 3) { PomodoroWidgetView(clock: .demo(running: false)) }
        widget("todo-4", cells: 4) { TodoWidgetView() }
        widget("todo-5", cells: 5) { TodoWidgetView() }
        widget("notes-list", cells: 4) { NotesWidgetView() }
        widget("clipboard-5", cells: 5) { ClipboardWidgetView() }
        widget("clipboard-6", cells: 6) { ClipboardWidgetView() }
        widget("quickapps", cells: 3) { QuickAppsWidgetView() }

        Gallery.register("widget-clipboard-workspace", size: CGSize(width: 760, height: 200), backdrop: .window) {
            ClipboardWorkspaceView().background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.06))).padding(10)
        }
        Gallery.register("widget-clipboard-workspace-images", size: CGSize(width: 760, height: 200), backdrop: .window) {
            ClipboardWorkspaceView(filter: .image).background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.06))).padding(10)
        }
        Gallery.register("widget-clipboard-shelf", size: CGSize(width: 1100, height: 250), backdrop: .wallpaper) {
            ClipboardShelfView(store: .shared)
        }

        Gallery.register("tool-todo-window", size: CGSize(width: 780, height: 520), backdrop: .window) {
            TodoWindowView(clock: .demo(running: true))
        }
        settings("askai", height: 1130) { AskAISettingsPane(previewKeyTail: "k3Qa") }
        settings("askai-nokey", height: 1130) { AskAISettingsPane(previewNoKeys: true) }
        settings("clipboard", height: 1000) { ClipboardSettingsPane() }
        settings("clock", height: 900) { ClockSettingsPane() }
        settings("notes", height: 560) { NotesTodoSettingsPane() }
    }
}
