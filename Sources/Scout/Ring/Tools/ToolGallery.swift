import SwiftUI

// Gallery items for every tool panel (sample data, nothing touches the real system).

@MainActor
enum ToolGallery {
    private static func panel<V: View>(_ name: String, _ w: CGFloat, _ h: CGFloat, @ViewBuilder _ content: @escaping () -> V) {
        Gallery.register("tool-\(name)", size: CGSize(width: w + 40, height: h + 40)) {
            content().frame(width: w, height: h).shadow(color: .black.opacity(0.2), radius: 14, y: 5)
        }
    }

    static func register() {
        panel("clipboard", 380, 460) { ClipboardPickerView() }
        panel("calculator", 340, 420) { CalculatorView(expression: "(1299 * 0.85) + 18%") }
        panel("calculator-empty", 340, 300) { CalculatorView() }
        panel("units", 380, 400) { UnitsView(quick: "72 f to c") }
        panel("units-currency", 380, 400) { UnitsView(quick: "100 usd to eur", category: .currency, amount: "250", from: "USD", to: "GBP") }
        panel("notes", 600, 400) { NotesPanelView() }
        panel("todo", 340, 440) { TodoPanelView() }
        panel("clock-timer", 380, 440) { ClockPanelView(clock: .demo(running: true), tab: .timer) }
        panel("clock-stopwatch", 380, 440) { ClockPanelView(clock: .demo(running: true), tab: .stopwatch) }
        panel("clock-pomodoro", 380, 440) { ClockPanelView(clock: .demo(running: true), tab: .pomodoro) }
        panel("clock-alarms", 380, 440) { ClockPanelView(clock: .demo(running: true), tab: .alarms) }
        #if APPSTORE
        Gallery.register("tool-capture-region", size: CGSize(width: 520, height: 320)) {
            CaptureOverlayPreview(window: false, hole: CGRect(x: 120, y: 90, width: 280, height: 150))
        }
        Gallery.register("tool-capture-window", size: CGSize(width: 520, height: 320)) {
            CaptureOverlayPreview(window: true, hole: CGRect(x: 60, y: 40, width: 400, height: 240))
        }
        #endif
        panel("links", 400, 440) { LinksView() }
        panel("apps", 360, 270) { AppsLauncherView() }
        panel("reminders", 360, 440) { RemindersView() }
        panel("voicememo", 360, 400) { VoiceMemoView() }
        panel("askai", 440, 580) { AskAIView() }
        panel("askai-haiku", 440, 420) { AskAIView(store: AIChatStore(demo: .haikuAnswer)) }
        Gallery.register("tool-askai-modelmenu", size: CGSize(width: 330, height: 420)) {
            AIModelPicker(selected: AIModels.autoID) { _ in }.background(GlassBackground(cornerRadius: 12)).shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        }
        panel("askai-empty", 440, 420) { AskAIView(store: AIChatStore(demo: .empty)) }
        panel("askai-nokey", 440, 420) { AskAIView(store: AIChatStore(demo: .empty), forceNoKey: true) }
        panel("askai-searching", 440, 420) { AskAIView(store: AIChatStore(demo: .searching), input: "") }
        panel("askai-thinking", 440, 420) { AskAIView(store: AIChatStore(demo: .thinking)) }
        panel("askai-error", 440, 420) { AskAIView(store: AIChatStore(demo: .error)) }
        Gallery.register("tool-screenshot-card", size: CGSize(width: 340, height: 90)) {
            ScreenshotCardView(image: NSImage(systemSymbolName: "photo", accessibilityDescription: nil) ?? NSImage(), message: "Screenshot saved and copied", canReveal: true)
                .background(GlassBackground(cornerRadius: 16))
        }
        Gallery.register("tool-clock-banner", size: CGSize(width: 380, height: 90)) {
            ClockRingingBanner(event: ClockRinging(id: "x", title: "Tea", subtitle: "5:00 timer finished", symbol: "timer", source: .timer(UUID())))
                .background(GlassBackground(cornerRadius: 16))
        }
    }
}
