import AppKit

// Save and resume: which of Scout's own windows were open, and exactly how (display, frame), so a quit, an update, a restart or a Mac
// restart brings them back as they were. What is INSIDE each window (a draft, a tab...) is remembered by the tools themselves (`ToolMemory`).
// Everything here is in AppKit points (bottom-left origin), the coordinates NSWindow and NSScreen use.

/// A display: its whole frame and the part windows may use (without the menu bar and the Dock).
struct WinDisplay: Equatable {
    var id: Int
    var frame: CGRect
    var visible: CGRect

    @MainActor
    static func current() -> [WinDisplay] {
        NSScreen.screens.enumerated().map { i, s in
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? i
            return WinDisplay(id: id, frame: s.frame, visible: s.visibleFrame)
        }
    }

    /// The display a window belongs to: the one holding its centre, else the one it overlaps most, else the nearest.
    static func holding(_ frame: CGRect, in displays: [WinDisplay]) -> WinDisplay? {
        let c = CGPoint(x: frame.midX, y: frame.midY)
        if let hit = displays.first(where: { $0.frame.contains(c) }) { return hit }
        let overlap = displays.map { d -> (WinDisplay, CGFloat) in
            let i = d.frame.intersection(frame)
            return (d, i.isNull ? 0 : i.width * i.height)
        }.max { $0.1 < $1.1 }
        if let overlap, overlap.1 > 0 { return overlap.0 }
        return displays.min { distance(c, $0.frame) < distance(c, $1.frame) }
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    /// `r` moved (and, when it is bigger, shrunk) to lie inside `area`.
    static func clamped(_ r: CGRect, in area: CGRect) -> CGRect {
        let w = min(r.width, area.width), h = min(r.height, area.height)
        return CGRect(x: min(max(r.minX, area.minX), area.maxX - w), y: min(max(r.minY, area.minY), area.maxY - h), width: w, height: h)
    }
}

struct WinSavedScoutWindow: Codable, Equatable {
    /// "panel:<panel id>" or "window:<frame autosave name>".
    var id: String
    var frame: CGRect
    var displayID: Int
    var displayFrame: CGRect
    /// Written by older versions (a tile of the window snapping, which is gone); read and ignored.
    var zone: String?
    var preSnap: CGRect?
    /// Anything the window needs to reopen the same way (Settings: the page).
    var detail: String?
    /// 0 is the front window.
    var order: Int
}

struct WinResumeState: Codable, Equatable {
    var windows: [WinSavedScoutWindow]
    var saved: Date
}

enum WinResumePlanner {
    /// Where a saved window opens now: on its display when that display still exists (moved with the display if the
    /// arrangement changed), else on the main display, always inside the visible frame.
    static func frame(for w: WinSavedScoutWindow, displays: [WinDisplay]) -> CGRect? {
        guard let main = displays.first else { return nil }
        if let d = displays.first(where: { $0.id == w.displayID }) {
            let moved = w.frame.offsetBy(dx: d.frame.minX - w.displayFrame.minX, dy: d.frame.minY - w.displayFrame.minY)
            return WinDisplay.clamped(moved, in: d.visible)
        }
        return WinDisplay.clamped(w.frame, in: main.visible)
    }
}

@MainActor
final class WinResume {
    static let shared = WinResume()
    static let prefKey = "win.resume.windows"

    /// How to open each window again. Panels by their id, ordinary windows by their frame autosave name. Pickers that close
    /// when you click away (Clipboard, Apps), the Prompter's strip and Pockets are left out on purpose.
    var panelOpeners: [String: () -> Void] = [
        "tool.askai": { AskAIPanel.show() },
        "tool.calculator": { CalculatorPanel.show() },
        "tool.units": { UnitsPanel.show() },
        "tool.notes": { NotesPanel.show() },
        "tool.todo": { TodoPanel.show() },
        "tool.clock": { ClockPanel.show() },
        "tool.links": { LinksPanel.show() },
        "tool.voicememo": { VoiceMemoTool.showPanel() },
        "tool.reminders": { RemindersPanel.show() },
        "prompter.scripts": { PrompterScriptsWindow.show() },
    ]
    var windowOpeners: [String: (String?) -> Void] = [
        "Scout.Settings": { detail in SettingsWindowController.shared.show(detail.flatMap(SettingsPane.init(rawValue:))) },
        "Scout.TodoWindow": { _ in TodoWindowController.shared.show() },
    ]

    var file = JSONFile<WinResumeState>("windows-resume.json")
    /// The displays and the screens' frames (tests give an offscreen one).
    var displays: () -> [WinDisplay] = { WinDisplay.current() }
    var screenFrames: () -> [CGRect] = { NSScreen.screens.map(\.frame) }

    private var observers: [NSObjectProtocol] = []
    private let saver = Debouncer(delay: 1.5)
    var restoring = true
    private var terminating = false

    static var isOn: Bool { Pref.bool(prefKey, true) }

    func start() {
        guard observers.isEmpty, !ScoutRuntime.isScripted else { return }
        let nc = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didChangeScreenNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { self?.windowChanged(window) }
            })
        }
        observers.append(nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willTerminate() }
        })
        // Let the modules finish starting, then bring the windows back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            MainActor.assumeIsolated { self?.restoreAtLaunch() }
        }
    }

    // MARK: Identity

    /// Scout's own windows that come back: titled panels and windows on a screen, not full screen, not minimised; the Prompter's strip
    /// and Pockets never.
    func isEligible(_ w: NSWindow) -> Bool {
        guard w.styleMask.contains(.titled), !w.styleMask.contains(.fullScreen), w.isVisible, !w.isMiniaturized else { return false }
        guard w is FloatingPanel || type(of: w) == NSWindow.self else { return false }
        guard w.level.rawValue <= NSWindow.Level.floating.rawValue else { return false }
        if let id = (w as? FloatingPanel)?.panelID, id == "prompter" || id.hasPrefix("pocket.") { return false }
        return screenFrames().contains { $0.intersects(w.frame) }
    }

    func id(of window: NSWindow) -> String? {
        if let panel = window as? FloatingPanel, let pid = panel.panelID, panelOpeners[pid] != nil { return "panel:\(pid)" }
        if type(of: window) == NSWindow.self, windowOpeners[window.frameAutosaveName] != nil { return "window:\(window.frameAutosaveName)" }
        return nil
    }

    private func detail(for id: String) -> String? {
        id == "window:Scout.Settings" ? SettingsSelection.shared.pane?.rawValue : nil
    }

    // MARK: Saving

    private func windowChanged(_ window: NSWindow?) {
        guard !restoring, !terminating, Self.isOn else { return }
        if let window, id(of: window) == nil { return }
        saver.call { [weak self] in self?.saveNow() }
    }

    private func willTerminate() {
        if !restoring, Self.isOn { saveNow(wait: true) }
        terminating = true
        ToolMemory.flush()
    }

    /// The open windows right now, front first.
    func snapshot(windows: [NSWindow]? = nil, displays: [WinDisplay]? = nil) -> WinResumeState {
        let all = displays ?? self.displays()
        // Front to back; windows the system does not list as ordered (an inactive app's panels) come after.
        let ordered = NSApp.orderedWindows
        let candidates = windows ?? (ordered + NSApp.windows.filter { w in !ordered.contains { $0 === w } })
        var saved: [WinSavedScoutWindow] = []
        for window in candidates where window.isVisible && isEligible(window) {
            guard let id = id(of: window), let d = WinDisplay.holding(window.frame, in: all) else { continue }
            saved.append(WinSavedScoutWindow(id: id, frame: window.frame, displayID: d.id, displayFrame: d.frame,
                                             zone: nil, preSnap: nil, detail: detail(for: id), order: saved.count))
        }
        return WinResumeState(windows: saved, saved: Date())
    }

    /// Writes the open windows to the state file. `wait` writes before returning (at quit, the process is about to end).
    func saveNow(wait: Bool = false) {
        guard !restoring, !terminating else { return }
        let state = snapshot()
        if wait { try? JSONEncoder.scout.encode(state).write(to: file.url, options: .atomic) } else { file.save(state) }
    }

    // MARK: Resuming

    func restoreAtLaunch() {
        defer { restoring = false }
        guard Self.isOn, !ScoutRuntime.isScripted, let state = file.load() else { return }
        restore(state)
    }

    /// Opens the saved windows again, back to front, each on its display at its frame. Returns the windows it reopened (the tests look
    /// at them).
    @discardableResult
    func restore(_ state: WinResumeState, find: ((String) -> NSWindow?)? = nil) -> [NSWindow] {
        let screens = displays()
        var opened: [NSWindow] = []
        for saved in state.windows.sorted(by: { $0.order > $1.order }) {
            let parts = saved.id.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0] == "panel" { panelOpeners[parts[1]]?() } else { windowOpeners[parts[1]]?(saved.detail) }
            let window = find?(saved.id) ?? (parts[0] == "panel" ? Panels.panel(parts[1]) : NSApp.windows.first { $0.frameAutosaveName == parts[1] })
            guard let window else { continue }
            if let frame = WinResumePlanner.frame(for: saved, displays: screens) { window.setFrame(frame, display: true) }
            opened.append(window)
        }
        return opened
    }
}
