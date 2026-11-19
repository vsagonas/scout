import SwiftUI

/// The announcement board: starts the agent watcher (a real run only) and registers the debug command.
@MainActor
enum LEDFeature {
    /// Called from `Modules.startAll()`.
    static func start() {
        // scout://led.post?text=HELLO&tint=FFB020&seconds=5&mode=step|scroll&symbol=sparkles : for a live look (automation runs).
        DebugCommands.register("led.post") { params in
            guard ScoutRuntime.isAutomation else { return }
            let text = params["text"] ?? "HELLO FROM SCOUT \(LEDFont.heart)"
            let tint = params["tint"].flatMap { Color(hex: $0) } ?? Retro.Ink.yellow
            LEDAnnouncements.shared.allowInScriptedRuns = true
            LEDAnnouncements.shared.post(text, tint: tint, symbol: params["symbol"], seconds: params["seconds"].flatMap(Double.init),
                                         repeating: true, mode: params["mode"].flatMap(LEDMode.init(rawValue:)))
        }
        LEDAnnouncements.shared.watchNotch()   // what waited while the notch was open plays when it closes
        LEDAgentWatcher.shared.start()   // a no-op in scripted runs: nothing is announced by itself there
    }
}

/// Settings › Live Activities: the board's own rows (the "Announcements" switch is the per-kind row in the list above).
struct LEDSettingsSection: View {
    @AppStorage(LEDSettings.scrollKey) private var scroll = false
    @AppStorage(LiveActivityKind.announcement.enabledKey) private var enabled = true

    var body: some View {
        Section {
            Toggle("Scroll the letters like a marquee", isOn: $scroll).toggleStyle(.switch)
            LabeledContent("Show a message on the board") {
                Button("Test") {
                    LEDAnnouncements.shared.allowInScriptedRuns = true   // a click is an explicit ask, even in a scripted live check
                    LEDAnnouncements.shared.post(LEDAnnouncements.boardText(String(localized: "HELLO FROM SCOUT ♥"), english: "HELLO FROM SCOUT ♥"), tint: Retro.Ink.yellow, symbol: "sparkles", repeating: true)
                    // The board plays on the closed notch: Settings lets the notch close for it and opens it again after.
                    SettingsWindowController.shared.notchHold.stepAside { LEDAnnouncements.shared.current != nil }
                }
                .disabled(!enabled)
            }
        } header: {
            Text("Announcements")
        } footer: {
            SettingsFootnote("Short messages light up left of the camera: a new agent says welcome, one that finished says done. With Reduce Motion on, the letters light up in place; this switch makes them scroll anyway.")
        }
    }
}
