import AppKit
import SwiftUI

/// Self-tests of the Windows feature (save and resume, and the Ask AI window's narrowest width). Run headless, your own binary only:
/// `build/Scout.app/Contents/MacOS/Scout --automation --headless --run "scout://win.selftest.resume?out=<file>"`.
/// They use synthetic displays and offscreen windows (x -20000): no real window of the owner's is read or moved.
@MainActor
enum WinSelfTests {
    static func register() {
        func command(_ name: String, _ defaultFile: String, _ run: @escaping (WinTestReport) async -> Void) {
            DebugCommands.register("win.selftest.\(name)") { params in
                guard ScoutRuntime.isAutomation else { return }
                let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file(defaultFile)
                Task { @MainActor in
                    let report = WinTestReport("win.selftest.\(name)")
                    await run(report)
                    report.write(to: out)
                }
            }
        }
        command("resume", "win-resume-selftest.json") { WinResumeTests.run($0) }
        command("askai", "win-askai-selftest.json") { WinAskAITests.run($0) }
    }
}

/// Collects checks and writes them as JSON: {"test", "passed", "failed", "pass", "checks":[{"name","ok","detail"}]}.
@MainActor
final class WinTestReport {
    let name: String
    private(set) var checks: [(name: String, ok: Bool, detail: String)] = []

    init(_ name: String) { self.name = name }

    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        checks.append((name, ok, ok ? "" : detail()))
    }

    func equal(_ name: String, _ a: CGRect, _ b: CGRect, tolerance: CGFloat = 0.5) {
        let same = abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
        check(name, same, "got \(fmt(a)) expected \(fmt(b))")
    }

    func note(_ name: String, _ detail: String) { checks.append((name, true, detail)) }

    func fmt(_ r: CGRect) -> String { "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))" }

    var failed: Int { checks.filter { !$0.ok }.count }

    func write(to out: URL) {
        let rows: [[String: Any]] = checks.map { ["name": $0.name, "ok": $0.ok, "detail": $0.detail] }
        let json: [String: Any] = ["test": name, "passed": checks.count - failed, "failed": failed, "pass": failed == 0, "checks": rows]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: out) }
    }
}

// MARK: - Save and resume

@MainActor
enum WinResumeTests {
    static let screen = CGRect(x: -20600, y: -20400, width: 1000, height: 700)
    /// 24 pt of "menu bar" at the top.
    static let visible = CGRect(x: -20600, y: -20400, width: 1000, height: 676)
    static let display = WinDisplay(id: 90, frame: screen, visible: visible)

    static func panel(id: String?, size: CGSize = CGSize(width: 300, height: 200), at origin: CGPoint, titled: Bool = true) -> FloatingPanel {
        var style: NSWindow.StyleMask = [.closable, .resizable, .fullSizeContentView, .nonactivatingPanel]
        if titled { style.insert(.titled) }
        let p = FloatingPanel(contentRect: CGRect(origin: origin, size: size), styleMask: style, backing: .buffered, defer: false)
        p.panelID = id
        p.allowsOffscreen = true
        p.isReleasedWhenClosed = false
        p.level = .floating
        p.orderFrontRegardless()
        p.setFrame(CGRect(origin: origin, size: size), display: false)
        return p
    }

    static func run(_ t: WinTestReport) {
        // Where a saved window opens again.
        let main = WinDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visible: CGRect(x: 0, y: 0, width: 1440, height: 875))
        let right = WinDisplay(id: 2, frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), visible: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
        func saved(_ frame: CGRect, on d: WinDisplay) -> WinSavedScoutWindow {
            WinSavedScoutWindow(id: "panel:tool.notes", frame: frame, displayID: d.id, displayFrame: d.frame, zone: nil, preSnap: nil, detail: nil, order: 0)
        }
        let onRight = saved(CGRect(x: 1600, y: 200, width: 500, height: 400), on: right)
        t.equal("a window opens again where it was, on its own display", WinResumePlanner.frame(for: onRight, displays: [main, right]) ?? .zero, onRight.frame)
        let movedRight = WinDisplay(id: 2, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), visible: CGRect(x: -1920, y: 0, width: 1920, height: 1055))
        t.equal("  that display moved to the other side: the window moves with it", WinResumePlanner.frame(for: onRight, displays: [main, movedRight]) ?? .zero,
                CGRect(x: -1760, y: 200, width: 500, height: 400))
        t.check("  that display is gone: it opens on the main one, inside its visible frame",
                (WinResumePlanner.frame(for: onRight, displays: [main]).map { main.visible.contains($0) } ?? false), t.fmt(WinResumePlanner.frame(for: onRight, displays: [main]) ?? .zero))
        let huge = saved(CGRect(x: 100, y: 100, width: 3000, height: 2000), on: main)
        t.equal("  a window bigger than its display is made to fit", WinResumePlanner.frame(for: huge, displays: [main]) ?? .zero, main.visible)
        t.check("  with no display at all nothing is planned", WinResumePlanner.frame(for: onRight, displays: []) == nil)
        t.check("the display a window belongs to: the one holding its centre, else the one it overlaps most",
                WinDisplay.holding(CGRect(x: 1500, y: 100, width: 100, height: 100), in: [main, right])?.id == 2
                    && WinDisplay.holding(CGRect(x: 1300, y: 100, width: 400, height: 100), in: [main, right])?.id == 2
                    && WinDisplay.holding(CGRect(x: 5000, y: 5000, width: 10, height: 10), in: [main, right])?.id == 2)

        // A real snapshot of offscreen panels, and a restore that puts them back.
        let resume = WinResume()
        resume.displays = { [display] }
        resume.screenFrames = { [screen] }
        resume.panelOpeners = ["test.one": {}, "test.two": {}]
        resume.windowOpeners = [:]
        let one = panel(id: "test.one", at: CGPoint(x: -20500, y: -20300))
        let two = panel(id: "test.two", size: CGSize(width: 260, height: 180), at: CGPoint(x: -20100, y: -20200))
        let strip = panel(id: "prompter", at: CGPoint(x: -20400, y: -20100))
        let bare = panel(id: "test.one", at: CGPoint(x: -20300, y: -20250), titled: false)
        defer { [one, two, strip, bare].forEach { $0.orderOut(nil); $0.close() } }
        let state = resume.snapshot(windows: [one, two, strip, bare], displays: [display])
        t.check("a snapshot keeps Scout's two panels, front first, and leaves out the Prompter's strip and an untitled window",
                state.windows.map(\.id) == ["panel:test.one", "panel:test.two"] && state.windows.map(\.order) == [0, 1], "\(state.windows.map(\.id))")
        t.equal("  with their frames", state.windows.first?.frame ?? .zero, one.frame)
        t.check("  and their display", state.windows.allSatisfy { $0.displayID == 90 && $0.displayFrame == screen })
        let firstFrame = one.frame, secondFrame = two.frame
        one.setFrame(CGRect(x: -20550, y: -20350, width: 200, height: 150), display: false)
        two.setFrame(CGRect(x: -20000, y: -20000, width: 400, height: 300), display: false)
        let reopened = resume.restore(state) { id in id == "panel:test.one" ? one : (id == "panel:test.two" ? two : nil) }
        t.check("restore reopens both, back to front", reopened.count == 2 && reopened.first === two && reopened.last === one)
        t.equal("  the first panel is back where it was", one.frame, firstFrame)
        t.equal("  and so is the second", two.frame, secondFrame)

        // The file: written and read back, and a file of an older version (with a tile) still reads.
        let file = JSONFile<WinResumeState>("win-test-resume.json")
        defer { try? FileManager.default.removeItem(at: file.url) }
        try? JSONEncoder.scout.encode(state).write(to: file.url, options: .atomic)
        t.check("the state file is written and read back the same", file.load()?.windows == state.windows)
        let old = #"{"windows":[{"id":"panel:tool.notes","frame":[[10,20],[300,200]],"displayID":1,"displayFrame":[[0,0],[1440,900]],"zone":"leftHalf","preSnap":[[5,5],[100,100]],"order":0}],"saved":0}"#
        let decoded = try? JSONDecoder().decode(WinResumeState.self, from: Data(old.utf8))
        t.check("  a file an older version wrote (with the snapping tile) still opens its windows", decoded?.windows.first?.frame == CGRect(x: 10, y: 20, width: 300, height: 200))

        // The setting.
        let savedPref = UserDefaults.standard.object(forKey: WinResume.prefKey)
        defer { UserDefaults.standard.set(savedPref, forKey: WinResume.prefKey) }
        UserDefaults.standard.removeObject(forKey: WinResume.prefKey)
        let onByDefault = WinResume.isOn
        Pref.set(false, WinResume.prefKey)
        t.check("resume is on unless switched off in Settings > Windows", onByDefault && !WinResume.isOn)
    }
}

// MARK: - The Ask AI window's narrowest width

@MainActor
enum WinAskAITests {
    static func run(_ t: WinTestReport) {
        let collapsed = AskAIMetrics.rowWidth(placeholder: "Ask anything", collapsed: true)
        let full = AskAIMetrics.rowWidth(placeholder: "Ask anything", collapsed: false)
        let fullOn = AskAIMetrics.rowWidth(placeholder: "Ask about your screen", collapsed: false)
        let collapsedOn = AskAIMetrics.rowWidth(placeholder: "Ask about your screen", collapsed: true)
        let header = AskAIMetrics.headerWidth()
        t.note("row with the chip as an icon, whole \"Ask anything\"", "\(collapsed) pt")
        t.note("row with the chip's word, whole \"Ask anything\"", "\(full) pt")
        t.note("row with the chip's word, whole \"Ask about your screen\"", "\(fullOn) pt")
        t.note("row with the chip as an icon, whole \"Ask about your screen\"", "\(collapsedOn) pt")
        t.note("header (title, model, history, new chat, close), natural width", "\(header) pt")
        t.check("the icon-only chip makes the row narrower", collapsed < full - 20, "\(collapsed) vs \(full)")
        t.check("the minimum panel width is the collapsed row's", AskAIMetrics.minPanelWidth == collapsed)
        t.check("the panel's minimum is under the old one (360)", AskAIMetrics.minPanelWidth < 360)
        t.check("the chip collapses below the full row's width, not above", AskAIMetrics.collapseBelow(placeholder: "Ask anything") == full)
        let chip = NSHostingView(rootView: AIMonitorChip(isOn: false, action: {}).environment(\.aiMonitorCompact, true))
        let wide = NSHostingView(rootView: AIMonitorChip(isOn: false, action: {}))
        t.check("the chip is narrower as an icon", chip.fittingSize.width < wide.fittingSize.width - 30, "\(chip.fittingSize.width) vs \(wide.fittingSize.width)")
        t.note("the header needs", "\(header) pt (the panel's minimum is \(AskAIMetrics.minPanelWidth) pt)")
    }
}
