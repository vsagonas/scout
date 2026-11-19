#if !APPSTORE
import AppKit
import os
import SwiftTerm
import SwiftUI

/// One agent tab: a folder, a start command and the live terminal (SwiftTerm) that shows it. The view and its
/// process live as long as the tab does, whether or not the notch is open.
@MainActor
final class AgentTab: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id: String
    let kind: AgentTabKind
    let folder: String
    private(set) var startedAt: Date

    @Published private(set) var title = ""
    @Published private(set) var isRunning = false
    /// Set when the process has ended (nil while it runs or before it starts).
    @Published private(set) var exitCode: Int32?
    /// Output the user has not seen, and the process has gone quiet: it is probably waiting for an answer.
    @Published private(set) var waiting = false
    /// The close confirmation is showing.
    @Published var confirmingClose = false

    /// The last start used the kind's resume command (a restart that brings the agent's conversation back).
    private(set) var startedWithResume = false

    private(set) var view: NotchTerminalView?
    weak var store: AgentTabStore?

    /// When the last output arrived (written from the terminal's parse thread).
    private let outputStamp = OSAllocatedUnfairLock(initialState: Date())
    private var seenStamp = Date.distantPast
    /// Output must stay quiet this long before a tab counts as "waiting".
    static let quietSeconds: TimeInterval = 4

    init(id: String = UUID().uuidString, kind: AgentTabKind, folder: String, startedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.folder = AgentTabFolder.normalized(folder)
        self.startedAt = startedAt
        super.init()
    }

    // MARK: Names

    var folderName: String { AgentTabFolder.name(folder) }
    var initial: String { AgentTabFolder.initial(folder) }
    var menuTitle: String { "\(kind.title) · \(folderName)" }
    var hasEnded: Bool { !isRunning && exitCode != nil }

    /// What the hover tooltip says.
    var helpText: String {
        var text = "\(menuTitle)\n\(AgentTabFolder.abbreviated(folder))"
        if hasEnded {
            let code = exitCode ?? 0
            text += "\n" + (code == 0 ? String(localized: "Ended") : String(localized: "Ended (code \(code))"))
        } else if waiting { text += "\n" + String(localized: "Waiting for you") }
        return text
    }

    var needsAttention: Bool { waiting || hasEnded }

    var info: AgentTabInfo {
        AgentTabInfo(id: id, kind: kind, folder: folder, startedAt: startedAt, isRunning: isRunning, pid: pid)
    }

    var record: AgentTabRecord { AgentTabRecord(id: id, kind: kind, folder: folder, startedAt: startedAt) }

    /// The tab's process id while it runs. After `exec` this is the agent itself.
    var pid: Int32? {
        guard isRunning, let pid = view?.process.shellPid, pid > 0 else { return nil }
        return pid
    }

    // MARK: Process

    private func makeView() -> NotchTerminalView {
        let v = NotchTerminalView(frame: CGRect(x: 0, y: 0, width: 680, height: 300))
        v.processDelegate = self
        let stamp = outputStamp
        v.setProcessOutputHandler { stamp.withLock { $0 = Date() } }
        view = v
        applyAppearance()
        return v
    }

    /// Starts (or restarts) the process. `resume` runs the kind's resume command instead of the start command.
    func start(resume: Bool, shell: String, override: String?) {
        let v = view ?? makeView()
        if exitCode != nil {
            v.resetToInitialState()
        }
        exitCode = nil
        waiting = false
        startedWithResume = resume
        let now = Date()
        startedAt = now
        seenStamp = now
        outputStamp.withLock { $0 = now }
        let launch = AgentTabLauncher.make(kind: kind, folder: folder, resume: resume, shell: shell, override: override)
        v.startProcess(executable: launch.executable, args: launch.args, environment: AgentTabLauncher.environment(),
                       execName: nil, currentDirectory: launch.directory)
        isRunning = true
    }

    /// Ends the process (SIGTERM, then SIGKILL after two seconds if it ignores it).
    func terminate() {
        confirmingClose = false
        guard let v = view, v.process.running else { isRunning = false; return }
        v.terminate()
        let pid = v.process.shellPid
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak v] in
            guard let v, v.process.running else { return }
            let current = v.process.shellPid
            if current > 0, current == pid { kill(current, SIGKILL) }
        }
    }

    /// Fonts, colors and keys (the shared Terminal settings).
    func applyAppearance() {
        guard let v = view else { return }
        let size = CGFloat(Pref.int(TerminalSession.Key.fontSize, 12))
        v.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        v.nativeBackgroundColor = NSColor.black
        v.nativeForegroundColor = NSColor(white: 0.90, alpha: 1)
        v.caretColor = NSColor(Theme.accent)
        v.optionAsMetaKey = Pref.bool(TerminalSession.Key.optionAsMeta, true)
    }

    // MARK: Attention

    /// The user is looking at this tab: whatever output there was has been seen.
    func markViewed() {
        seenStamp = outputStamp.withLock { $0 }
        if waiting { waiting = false }
    }

    /// Once a second: unseen output that has gone quiet means the agent is waiting for the user.
    func tick(viewed: Bool, now: Date = Date()) {
        guard isRunning else { if waiting { waiting = false }; return }
        if viewed { markViewed(); return }
        let stamp = outputStamp.withLock { $0 }
        let isWaiting = stamp > seenStamp && now.timeIntervalSince(stamp) >= Self.quietSeconds
        if isWaiting != waiting { waiting = isWaiting }
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) { self.title = title }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isRunning = false
        waiting = false
        self.exitCode = exitCode ?? 0
        store?.tabEnded(self)
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        isRunning = false
        waiting = false
        exitCode = 127
        store?.tabEnded(self)
    }

    // MARK: Samples (gallery only: no process, no view)

    enum SampleState { case running, waiting, ended(Int32) }

    static func sample(_ kind: AgentTabKind, folder: String, state: SampleState = .running, id: String = UUID().uuidString) -> AgentTab {
        let tab = AgentTab(id: id, kind: kind, folder: folder, startedAt: Date().addingTimeInterval(-1260))
        switch state {
        case .running: tab.isRunning = true
        case .waiting: tab.isRunning = true; tab.waiting = true
        case .ended(let code): tab.exitCode = code
        }
        return tab
    }
}
#endif
