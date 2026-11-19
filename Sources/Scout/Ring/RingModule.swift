import SwiftUI

// This module starts everything in Ring/.

@MainActor
enum RingModule {
    /// Ask AI's start and the tools' commands. The radial ring itself is gone.
    static func start() {
        #if !APPSTORE
        AIKeyImport.run()
        #endif
        AskAIPlace.addToSavedWorkspaceListOnce()
        AIMonitor.startOffByDefault()
        registerCommands()
        #if APPSTORE && DEBUG
        SandboxProbe.register()
        #endif
    }

    // MARK: scout:// commands

    private static func registerCommands() {
        DebugCommands.register("units.selftest") { p in
            let out = p["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("units-selftest.txt")
            var report = ""
            for t in ["5 km to mi", "72 f to c", "100 usd to eur", "1 gb in mb", "3 hours to min", "10 stone to kg", "60 mph to km/h",
                      "2.5 l to cups", "0 k to c", "1 yd to ft", "5 xyz to mi", "5 km to kg", "hello"] {
                if let r = UnitCatalog.parse(t) {
                    report += "\(t) -> \(UnitCatalog.format(UnitCatalog.convert(r.value, from: r.from, to: r.to))) \(r.to.symbol)\n"
                } else { report += "\(t) -> no parse\n" }
            }
            try? report.write(to: out, atomically: true, encoding: .utf8)
        }
        DebugCommands.register("todo.window") { _ in TodoWindowController.shared.show() }
        DebugCommands.register("ai.selftest.notch") { p in
            AskAINotchSelfTest.run(out: p["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("ai-notch-selftest.txt"))
        }
        DebugCommands.register("ai.selftest.monitor") { p in
            AIMonitorSelfTest.run(out: p["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("ai-monitor-selftest.txt"))
        }
        DebugCommands.register("ai.selftest") { p in
            let out = p["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("ai-selftest.txt")
            try? AIClient.selfTest().write(to: out, atomically: true, encoding: .utf8)
        }
        for tool in RingToolKind.allCases {
            DebugCommands.register("tool.\(tool.rawValue)") { p in
                if tool == .clock, let tab = p["tab"].flatMap(ClockTab.init(rawValue:)) {
                    RingTools.run(.clock, option: RingOption(id: tab.rawValue, title: tab.title, symbol: tab.symbol))
                } else if let option = p["option"] {
                    RingTools.run(tool, option: tool.options().first { $0.id == option } ?? RingOption(id: option, title: option, symbol: "circle"))
                } else {
                    RingTools.run(tool)
                }
            }
        }
    }

    // MARK: Gallery

    static func registerGallery() {
        ToolGallery.register()
        AskAINotchGallery.register()
        AskAIMonitorGallery.register()
    }
}
