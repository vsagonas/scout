#if !APPSTORE
import SwiftTerm
import SwiftUI

@MainActor
enum TerminalFeature {
    static func start() {
        DebugCommands.register("terminal.open") { _ in NotchNavigator.shared.open(.terminal) }
        AgentTabCommands.register()
        // Last run's tabs: back in their folders, the agents resumed (unless switched off, then they wait under "+ › Resume").
        AgentTabStore.shared.restoreOnLaunch()
    }

    static func registerSelfTests() {
        AgentTabSelfTest.register()
        FeaturesSelfTest.add("terminal: SwiftTerm runs a process and reads its output") {
            let view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 480, height: 200))
            view.startProcess(executable: "/bin/sh", args: ["-c", "echo scout-terminal-ok"], environment: nil, execName: nil, currentDirectory: NSTemporaryDirectory())
            let end = Date().addingTimeInterval(3)
            var text = ""
            while Date() < end {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
                text = String(decoding: view.getBufferAsData(), as: UTF8.self)
                if text.contains("scout-terminal-ok") { break }
            }
            view.terminate()
            return text.contains("scout-terminal-ok")
        }
    }

    static func registerGallery() {
        FeatureGallery.workspace("terminal-workspace") { TerminalWorkspaceView() }
        FeatureGallery.settings("settings-terminal", height: 560) { TerminalSettingsPane() }
        AgentTabGallery.registerGallery()
    }
}
#endif
