import AppKit
import ScreenCaptureKit

// `scout://ai.selftest.monitor` (scripted runs only): checks Monitor without taking a picture of the real screen.
//  1. which display is chosen (windows and pointer made up),
//  2. which running applications count as Scout's own (the ones the filter leaves out),
//  3. the real filter, when this build already has Screen Recording (it is only built, never used for a picture;
//     without the permission this is skipped and macOS is not asked),
//  4. a question sent with Monitor on gets a sample screen attached (canned answer, no network).
// The result goes to `ai-monitor-selftest.txt`.

@MainActor
enum AIMonitorSelfTest {
    static func run(out: URL) {
        guard ScoutRuntime.isScripted else { return }
        Task { @MainActor in
            var report: [String] = []
            func check(_ name: String, _ ok: Bool, _ detail: String = "") { report.append("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")") }

            // 1. Display choice
            let a = AIMonitor.DisplaySample(id: 1, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982))
            let b = AIMonitor.DisplaySample(id: 2, bounds: CGRect(x: 1512, y: 0, width: 1920, height: 1080))
            let own: pid_t = 100, other: pid_t = 200
            func window(_ pid: pid_t, layer: Int = 0, alpha: Double = 1, _ r: CGRect) -> AIMonitor.WindowSample { .init(pid: pid, layer: layer, alpha: alpha, bounds: r) }
            let onA = CGPoint(x: 700, y: 20)
            check("display: the other app's front window wins over the pointer",
                  AIMonitor.pickDisplay(windows: [window(own, CGRect(x: 100, y: 100, width: 800, height: 600)), window(other, CGRect(x: 1700, y: 200, width: 900, height: 700))],
                                        displays: [a, b], pointer: onA, ownPID: own) == 2)
            check("display: Scout's own windows are skipped",
                  AIMonitor.pickDisplay(windows: [window(own, CGRect(x: 1700, y: 200, width: 900, height: 700)), window(other, CGRect(x: 100, y: 100, width: 900, height: 700))],
                                        displays: [a, b], pointer: CGPoint(x: 1800, y: 20), ownPID: own) == 1)
            check("display: menu bar, transparent and tiny windows are skipped, then the pointer decides",
                  AIMonitor.pickDisplay(windows: [window(other, layer: 25, CGRect(x: 1600, y: 0, width: 1000, height: 30)),
                                                  window(other, alpha: 0, CGRect(x: 1600, y: 100, width: 900, height: 700)),
                                                  window(other, CGRect(x: 1600, y: 100, width: 60, height: 40))],
                                        displays: [a, b], pointer: CGPoint(x: 1800, y: 20), ownPID: own) == 2)
            check("display: a window across two displays goes to the one it mostly covers",
                  AIMonitor.pickDisplay(windows: [window(other, CGRect(x: 1300, y: 100, width: 1000, height: 700))], displays: [a, b], pointer: onA, ownPID: own) == 2)

            // 2. Which applications are Scout
            check("own: this process", AIMonitor.isOwn(bundleID: "x.other", pid: own, ownPID: own, ownBundle: "com.vsag.Scout"))
            check("own: another copy with Scout's bundle identifier", AIMonitor.isOwn(bundleID: "com.vsag.Scout", pid: other, ownPID: own, ownBundle: "com.vsag.Scout"))
            check("own: another app is not", !AIMonitor.isOwn(bundleID: "com.apple.Safari", pid: other, ownPID: own, ownBundle: "com.vsag.Scout"))
            check("own: no bundle identifier excludes nothing by name", !AIMonitor.isOwn(bundleID: nil, pid: other, ownPID: own, ownBundle: nil))

            // 3. The real filter, only if the permission is already there
            if CGPreflightScreenCaptureAccess() {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    if let display = content.displays.first {
                        let pid = getpid(), bundle = Bundle.main.bundleIdentifier
                        let ours = AIMonitor.ownApplications(in: content, ownPID: pid, ownBundle: bundle)
                        let filter = AIMonitor.makeFilter(content: content, display: display, ownPID: pid, ownBundle: bundle)
                        var detail = "\(content.applications.count) applications on the screen, \(ours.count) of them Scout"
                        check("filter: Scout's application is found among the applications and handed to the filter as excluded", !ours.isEmpty, detail)
                        if #available(macOS 15.2, *) {
                            let leaked = filter.includedApplications.filter { AIMonitor.isOwn(bundleID: $0.bundleIdentifier, pid: $0.processID, ownPID: pid, ownBundle: bundle) }
                            detail = "the filter reads back \(filter.includedApplications.count) included applications, \(filter.includedDisplays.count) display(s)"
                            check("filter: Scout's application is not among the filter's included applications", leaked.isEmpty, detail)
                        }
                    }
                } catch {
                    report.append("SKIP filter: could not list the screen content (\(error.localizedDescription))")
                }
            } else {
                report.append("SKIP filter: this build has no Screen Recording permission (macOS was not asked)")
            }

            // 4. A question with Monitor on
            let store = AIChatStore.shared
            let was = AIMonitor.isOn
            UserDefaults.standard.set(true, forKey: AIMonitor.key)
            store.send(text: "What is on my screen?", imageFiles: [])
            let capturing = store.capturingID != nil
            try? await Task.sleep(nanoseconds: 700_000_000)
            let question = store.current?.messages.last { $0.role == .user }
            check("flow: the question waited for its picture", capturing)
            check("flow: a screen picture is attached to the question", question?.imageFiles.contains { AIImages.isScreen($0) } ?? false, question?.imageFiles.joined(separator: ",") ?? "no question")
            check("flow: the answer started once the picture was attached", store.isStreaming || (store.current?.messages.last?.role == .assistant))
            check("flow: not busy capturing any more", store.capturingID == nil)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            check("flow: the answer finished", !store.isStreaming)
            UserDefaults.standard.set(was, forKey: AIMonitor.key)

            try? report.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        }
    }
}
