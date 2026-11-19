import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

// Debug builds of the App Store edition only (never in release): `scout://sandbox.probe` reports what the sandbox lets Scout do,
// as a card under the notch and as an NSLog line ("PROBE-REPORT"): real folders (Pictures, Movies, Music, Downloads, Desktop:
// listable / writable), Accessibility status, the login-item status, Screen Recording status, and whether
// /usr/sbin/screencapture can even be started from the sandbox. It reads and starts nothing that prompts, and writes nothing.

#if APPSTORE && DEBUG

@MainActor
enum SandboxProbe {
    static func register() {
        DebugCommands.register("sandbox.probe") { _ in run() }
    }

    private static func run() {
        var lines: [String] = []
        lines.append("home \(NSHomeDirectory().suffix(46))")
        lines.append("real \(UserFolders.realHome.path)")
        let folders: [(String, FileManager.SearchPathDirectory)] = [("Pictures", .picturesDirectory), ("Movies", .moviesDirectory), ("Music", .musicDirectory),
                                                                    ("Downloads", .downloadsDirectory), ("Desktop", .desktopDirectory)]
        for (name, directory) in folders {
            let real = UserFolders.standard(directory)
            let list = try? FileManager.default.contentsOfDirectory(atPath: real.path)
            let listed = list.map { "ok \($0.count)" } ?? "NO"
            lines.append("\(name): list \(listed), write \(FileManager.default.isWritableFile(atPath: real.path) ? "yes" : "no")")
        }
        lines.append("Accessibility \(AXIsProcessTrusted()), login item \(SMAppService.mainApp.status.rawValue), Screen Recording \(CGPreflightScreenCaptureAccess())")
        let report = lines.joined(separator: "\n")
        NSLog("PROBE-REPORT\n\(report)")
        LiveActivityCenter.shared.present(NotchCard(id: "probe", duration: 40) {
            Text(report).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white).padding(10)
        })
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-h"]
            process.standardError = Pipe()
            process.standardOutput = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                NSLog("PROBE-EXEC screencapture -h started, exit \(process.terminationStatus)")
            } catch {
                NSLog("PROBE-EXEC screencapture could not be started: \(error.localizedDescription)")
            }
        }
    }
}

#endif
