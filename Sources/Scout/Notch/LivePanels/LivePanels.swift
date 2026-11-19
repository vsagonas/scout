import Combine
import SwiftUI

// The "only while it is happening" panels of the open notch's dashboard: the next meeting, downloads and conversions in
// progress, a screen recording, AirPods / Bluetooth battery, a running timer or Pomodoro, and open to-dos. The dashboard
// renders `LivePanels.shared.live` after its own panels, sizes each by `span` (cells of 50 pt, 140 pt tall) and opens
// `expandTo` when one is clicked. (Now playing is the dashboard's own.)

@MainActor
protocol LivePanelSource: AnyObject {
    var id: String { get }              // "live.meeting", "live.downloads", ...
    var title: String { get }           // for menus
    var symbol: String { get }          // SF Symbol name
    var isLive: Bool { get }            // show it now?
    var priority: Int { get }           // higher first among live panels
    var span: Int { get }               // width in dashboard cells
    var expandTo: WorkspaceKind? { get } // the full view a click opens, if any
    func makeView() -> AnyView          // the compact panel
}

/// Decides which panels are live and in what order. `live` is republished only when the set or the order really changes
/// (the notch re-lays out on every publish); ticking text lives inside the panel views (TimelineView), never here.
@MainActor
final class LivePanels: ObservableObject {
    static let shared = LivePanels()

    @Published private(set) var live: [any LivePanelSource] = []
    let all: [any LivePanelSource]

    /// How often `live` was republished (the self-test checks that a tick alone never does).
    private(set) var publishCount = 0

    private let clock: () -> Date
    private let heartbeat: Bool
    private var bag = Set<AnyCancellable>()
    private var wake: Timer?

    convenience init() {
        self.init(sources: [LiveRecordingPanel.live(), LiveMeetingPanel.live(), LiveTimerPanel.live(),
                            LiveDownloadsPanel.live(), LiveBluetoothPanel.live(), LiveTodosPanel.live(),
                            RadioLivePanel.live()])
    }

    /// `sources` and `now` are injectable: galleries and self-tests feed synthetic states and their own clock.
    init(sources: [any LivePanelSource], now: @escaping () -> Date = Date.init, heartbeat: Bool = true) {
        all = sources
        clock = now
        self.heartbeat = heartbeat
        for case let source as any LiveDriven in sources {
            source.changes.receive(on: DispatchQueue.main).sink { [weak self] in self?.recompute() }.store(in: &bag)
        }
        recompute()
    }

    /// Looks at every source again; publishes only if the live set or its order changed.
    func recompute() {
        let now = clock()
        let ordered = all.enumerated().filter { $0.element.isLive }
            .sorted { a, b in a.element.priority == b.element.priority ? a.offset < b.offset : a.element.priority > b.element.priority }
            .map(\.element)
        if ordered.map(\.id) != live.map(\.id) {
            live = ordered
            publishCount += 1
        }
        scheduleWake(from: now)
    }

    func stop() {
        wake?.invalidate()
        wake = nil
        bag.removeAll()
    }

    /// One timer, set for the earliest moment any source can change by the clock alone (30 s at most).
    private func scheduleWake(from now: Date) {
        wake?.invalidate()
        wake = nil
        guard heartbeat else { return }
        var next = now.addingTimeInterval(30)
        for case let source as any LiveDriven in all {
            if let due = source.nextWake(after: now), due < next { next = due }
        }
        let delay = max(0.25, next.timeIntervalSince(now) + 0.05)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.recompute() }
        }
        timer.tolerance = min(1, delay * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        wake = timer
    }
}
