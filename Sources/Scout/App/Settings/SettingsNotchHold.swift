import AppKit
import Combine

/// The notch behind the Settings window
///
/// While the Settings window is on show and the person is working in it:
///  - the notch opens (on the screen the window is on, else the main notched screen) and is held open: it does not close when the pointer leaves
///    it, nor when the person clicks in Settings or anywhere else (`NotchNavigator.holdOpenReasons`);
///  - the Settings window floats one step above the notch panels, so the notch shows behind it and every change draws there live.
/// When the window closes, is minimised, or Scout is no longer the app in use, the hold goes, the window goes back to its ordinary level, and a
/// notch that Settings opened closes again (one that was already open stays, and behaves as usual).
///
/// Another Scout window that takes the keyboard (the welcome tour replayed from Settings, a file chooser) is not under the raised level: a chooser
/// is a modal panel at a lower level and would hide behind Settings. The tour also lets the notch go (it would cover the top of the tour); a file
/// chooser keeps the hold.
@MainActor
final class SettingsNotchHold {
    static let reason = "settings.window"
    /// One step above the notch panels' level.
    static let aboveNotch = NSWindow.Level(rawValue: NotchPanel.notchLevel.rawValue + 1)

    /// What the window that has the keyboard means for the hold.
    enum Keyboard: Equatable {
        case settings   // Settings itself, a notch panel (the person typed in the notch), a sheet of Settings, or nothing known: hold and raise
        case chooser    // another panel (an open or save panel, the colour panel, an alert): hold, but Settings steps down so the panel shows
        case other      // any other Scout window (the tour, a to-do list): no hold, no raise
    }

    /// Where `key` (the Scout window that last took the keyboard; nil = none known) puts the hold.
    static func keyboard(_ key: NSWindow?, settings: NSWindow) -> Keyboard {
        guard let key else { return .settings }
        if key === settings || key is NotchPanel || settings.attachedSheet === key { return .settings }
        if key is NSPanel { return .chooser }   // open and save panels, the colour panel, alerts, the ring's panels; when one goes Settings takes the keyboard back
        return key.isVisible ? .other : .settings   // a window that has closed no longer counts
    }

    private let navigator: NotchNavigator
    private let openNotch: @MainActor (NSWindow) -> Void
    private weak var window: NSWindow?
    private weak var key: NSWindow?
    private var normalLevel: NSWindow.Level = .normal
    private var appActive = true
    private var closing = false
    private var observers: [NSObjectProtocol] = []
    private var cancellable: AnyCancellable?
    /// The notch is held for Settings now.
    private(set) var isHolding = false
    /// Settings opened the notch (it was closed), so Settings closes it again.
    private var openedByUs = false

    /// `openNotch` opens the notch for the window (the app: `NotchManager.openBehind`; self-tests: their own navigator).
    init(navigator: NotchNavigator? = nil, openNotch: (@MainActor (NSWindow) -> Void)? = nil) {
        self.navigator = navigator ?? .shared
        self.openNotch = openNotch ?? { NotchManager.shared.openBehind($0) }
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    /// Starts watching the window (once).
    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.closing = true; self?.update() }
        })
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(nc.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let w = note.object as? NSWindow else { return }
                self.becameKey(w)
            }
        })
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.appActivityChanged(false) }
        })
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.appActivityChanged(true) }
        })
        // The person closed the notch themselves (Esc, the shortcut): that is theirs to do; Settings no longer owns it. A notch that opens
        // again while Settings is on show is held again.
        cancellable = navigator.$isOpen.removeDuplicates().sink { [weak self] open in
            MainActor.assumeIsolated {
                guard let self, self.isHolding, !self.pausedForBoard else { return }
                if open { self.navigator.hold(Self.reason) } else { self.openedByUs = false }
            }
        }
    }

    /// The Settings window was brought forward (`show`).
    func windowShown() {
        closing = false
        appActive = true
        key = window
        update()
    }

    /// Scout became the app in use, or stopped being it (the person went to another app).
    func appActivityChanged(_ active: Bool) {
        appActive = active
        update()
    }

    /// A Scout window took the keyboard.
    func becameKey(_ w: NSWindow) {
        guard w !== key else { return }
        if w !== window, w is NotchPanel { return }   // the person typed in the notch: nothing changes
        key = w
        update()
    }

    /// Looks at the window and the app and holds, raises, releases or lowers as needed.
    func update() {
        guard let window else { return }
        let keyboard = Self.keyboard(key, settings: window)
        let wanted = !closing && window.isVisible && !window.isMiniaturized && appActive && keyboard != .other
        if wanted, !isHolding { engage(window) } else if !wanted, isHolding { disengage() }
        let raise = wanted && keyboard == .settings
        if raise, window.level != Self.aboveNotch {
            normalLevel = window.level
            window.level = Self.aboveNotch
        } else if !raise, window.level == Self.aboveNotch {
            window.level = normalLevel
        }
        // The shared colour panel (a colour well in a pane opens it) floats at a low level and may never take the keyboard: it rises with Settings.
        if raise || NSColorPanel.sharedColorPanelExists {
            let panel = NSColorPanel.shared
            let wanted = raise ? Self.aboveColours : colourLevel
            if raise, panel.level != Self.aboveColours { colourLevel = panel.level }
            if panel.level != wanted { panel.level = wanted }
        }
    }

    /// One step above Settings when it is raised.
    static let aboveColours = NSWindow.Level(rawValue: aboveNotch.rawValue + 1)
    private var colourLevel: NSWindow.Level = .floating

    /// The board's Test (Settings › Live Activities): the board plays on the CLOSED notch, so the notch closes for the message and opens
    /// again behind Settings when it is over.
    /// `playing` says whether the message is on the board.
    func stepAside(whilePlaying playing: @escaping @MainActor () -> Bool) {
        guard let window, isHolding else { return }
        let reopen = navigator.isOpen
        pausedForBoard = true
        navigator.release(Self.reason)
        navigator.close()
        boardTask?.cancel()
        boardTask = Task { @MainActor [weak self] in
            var started = false
            for tick in 0..<160 {   // a quarter of a second at a time, 40 s at most
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                if playing() { started = true } else if started || tick >= 12 { break }   // over, or it never started within 3 s
            }
            guard let self, !Task.isCancelled else { return }
            self.pausedForBoard = false
            guard self.isHolding else { return }
            self.navigator.hold(Self.reason)
            if reopen, !self.navigator.isOpen { self.openNotch(window) }
        }
    }
    private var pausedForBoard = false
    private var boardTask: Task<Void, Never>?

    private func engage(_ window: NSWindow) {
        isHolding = true
        openedByUs = !navigator.isOpen
        navigator.hold(Self.reason)
        if openedByUs { openNotch(window) }
    }

    private func disengage() {
        isHolding = false
        navigator.release(Self.reason)
        if openedByUs {
            openedByUs = false
            navigator.close()   // honours any other hold
        }
    }
}
