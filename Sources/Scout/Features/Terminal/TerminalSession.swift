#if !APPSTORE
import AppKit
import SwiftTerm
import SwiftUI

/// A terminal view that takes keyboard focus on the first click, even in a non-activating panel.
final class NotchTerminalView: LocalProcessTerminalView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let window, !window.isKeyWindow { window.makeKey() }
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

/// The one terminal session of the Terminal workspace. It keeps running while the notch is closed
/// (setting `term.keepRunning`); the view is reused each time the workspace appears.
@MainActor
final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    static let shared = TerminalSession()

    enum Key {
        static let shell = "term.shell"            // "" = the login shell ($SHELL)
        static let startFolder = "term.startFolder" // "" = home
        static let optionAsMeta = "term.optionAsMeta"
        static let fontSize = "term.fontSize"
        static let keepRunning = "term.keepRunning"
    }

    @Published private(set) var title = ""
    @Published private(set) var exitCode: Int32?
    @Published private(set) var isRunning = false
    @Published private(set) var focused = false

    private(set) var view: NotchTerminalView?
    static let holdReason = "terminal"

    // MARK: Settings

    static var loginShell: String { ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" }

    static var shellPath: String {
        let chosen = Pref.string(Key.shell, "")
        return chosen.isEmpty || !FileManager.default.isExecutableFile(atPath: chosen) ? loginShell : chosen
    }

    static var startFolder: String {
        let chosen = Pref.string(Key.startFolder, "")
        var isDir: ObjCBool = false
        if !chosen.isEmpty, FileManager.default.fileExists(atPath: (chosen as NSString).expandingTildeInPath, isDirectory: &isDir), isDir.boolValue {
            return (chosen as NSString).expandingTildeInPath
        }
        return NSHomeDirectory()
    }

    /// Shells listed in /etc/shells that exist on this Mac.
    static var availableShells: [String] {
        let text = (try? String(contentsOfFile: "/etc/shells", encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Session

    /// The terminal view (created on first use). Starts the shell when none is running.
    func ensureView() -> NotchTerminalView {
        if let view {
            if !isRunning && exitCode == nil { startShell(in: view) }
            return view
        }
        let v = NotchTerminalView(frame: CGRect(x: 0, y: 0, width: 680, height: 176))
        v.processDelegate = self
        view = v
        applyAppearance()
        startShell(in: v)
        return v
    }

    private func startShell(in v: NotchTerminalView) {
        guard !ScoutRuntime.isScripted else { return }
        exitCode = nil
        let shell = Self.shellPath
        v.startProcess(executable: shell, args: ["-l"], environment: nil, execName: nil, currentDirectory: Self.startFolder)
        isRunning = true
    }

    func restart() {
        view?.terminate()
        isRunning = false
        exitCode = nil
        if let view {
            view.resetToInitialState()
            startShell(in: view)
        }
    }

    /// Fonts, colors and keys (called at start and when the settings change).
    func applyAppearance() {
        guard let v = view else { return }
        let size = CGFloat(Pref.int(Key.fontSize, 12))
        v.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        v.nativeBackgroundColor = NSColor.black
        v.nativeForegroundColor = NSColor(white: 0.90, alpha: 1)
        v.caretColor = NSColor(Theme.accent)
        v.optionAsMetaKey = Pref.bool(Key.optionAsMeta, true)
    }

    private var focusTimer: Timer?

    /// While the workspace is visible, hold the notch open whenever the terminal has keyboard focus.
    func workspaceAppeared() {
        focusTimer?.invalidate()
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let v = self.view else { return }
                let has = v.window?.isKeyWindow == true && v.window?.firstResponder === v
                if has != self.focused { self.focusChanged(has) }
            }
        }
    }

    /// The workspace went away: stop the shell unless it should keep running.
    func workspaceDisappeared() {
        focusTimer?.invalidate()
        focusTimer = nil
        releaseHold()
        if !Pref.bool(Key.keepRunning, true) {
            view?.terminate()
            isRunning = false
            exitCode = nil
        }
    }

    func releaseHold() {
        focused = false
        NotchNavigator.shared.release(Self.holdReason)
    }

    private func focusChanged(_ focus: Bool) {
        focused = focus
        if focus { NotchNavigator.shared.hold(Self.holdReason) } else { NotchNavigator.shared.release(Self.holdReason) }
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) { self.title = title }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isRunning = false
        self.exitCode = exitCode ?? 0
        releaseHold()
    }
}
#endif
