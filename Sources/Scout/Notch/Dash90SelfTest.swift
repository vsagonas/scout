import AppKit
import SwiftUI

/// `scout://dash90.selftest?out=<file>` (headless, its own build: `--automation --headless --run …`, then `kill $PID`).
/// The 90s dashboard (R3): the time as LCD segments, the LED bar levels, every tab key fits at the narrowest header, the selected tab
/// is the pressed key, and real clicks (offscreen panel, nothing shows) on a tab key, on Join, on a to-do box, and typing in the
/// Ask AI terminal and sending into Fast Ask AI. Synthetic data only.
@MainActor
enum Dash90SelfTest {
    static func register() {
        DebugCommands.register("dash90.selftest") { params in
            guard ScoutRuntime.isAutomation else { return }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("dash90-selftest.txt")
            Task { @MainActor in await run(out: out) }
        }
    }

    // MARK: The rig: an offscreen notch with a chosen dashboard, real mouse events

    @MainActor private final class Rig {
        let size = CGSize(width: 1120, height: 700)
        let model: NotchScreenModel
        let navigator = NotchNavigator()
        let nook: NookStore
        let panel: NotchPanel

        init(layout: [WidgetKind], view: @escaping () -> AnyView) {
            model = NotchScreenModel(geometry: .sample16, panelSize: size)
            model.isOpen = true
            navigator.isOpen = true
            nook = NookStore(persist: false, layout: layout)
            nook.liveOverride = NookLive(playing: false, agents: 0)
            nook.tabIDs = { [] }
            nook.viewOverride = { item in item == .panel(layout[0]) ? view() : nil }
            panel = NotchPanel(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.navigatorOverride = navigator
            panel.isReleasedWhenClosed = false
            let root = NotchRootView(model: model, center: LiveActivityCenter(), navigator: navigator, nook: nook, styleOverride: .classic)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = CGRect(origin: .zero, size: size)
            panel.contentView = hosting
            panel.orderFrontRegardless()
        }

        func rect(_ name: String) -> CGRect? { model.panelRects[name] }

        func post(_ type: NSEvent.EventType, _ p: CGPoint) {
            let location = CGPoint(x: p.x, y: size.height - p.y)
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else { return }
            panel.sendEvent(event)
        }

        func click(_ p: CGPoint) {
            post(.leftMouseDown, p)
            post(.leftMouseUp, p)
        }

        func firstTextField() -> NSTextField? {
            func find(_ view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, field.isEditable { return field }
                for sub in view.subviews { if let found = find(sub) { return found } }
                return nil
            }
            return panel.contentView.flatMap(find)
        }

        /// The controls (marked `nookControl()`) inside a panel, top to bottom, then left to right.
        func controls(in panelRect: CGRect) -> [CGRect] {
            nook.controlRects.filter { panelRect.contains(CGPoint(x: $0.midX, y: $0.midY)) }
                .sorted { ($0.minY.rounded(), $0.minX) < ($1.minY.rounded(), $1.minX) }
        }

        func close() {
            panel.contentView = nil
            panel.orderOut(nil)
        }
    }

    private static func settle(_ seconds: Double = 0.45) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: Pixels

    /// The mean brightness of the key's top edge row minus its bottom edge row (a raised key is lit from the top-left: positive;
    /// a pressed-in key is the reverse: negative).
    private static func edgeContrast(selected: Bool, hover: Bool = true) -> Double? {
        let key = NotchIconButton(symbol: "calendar", selected: selected, help: "Calendar", hoverPreview: hover, action: {}).frame(width: 27, height: 24)
        let renderer = ImageRenderer(content: key.padding(2).background(Color.black).environment(\.colorScheme, .dark))
        renderer.scale = 4
        guard let cg = renderer.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        func row(_ y: Int) -> Double {
            var sum = 0.0
            let from = w / 3, to = 2 * w / 3
            for x in from..<to {
                let i = (y * w + x) * 4
                sum += 0.299 * Double(data[i]) + 0.587 * Double(data[i + 1]) + 0.114 * Double(data[i + 2])
            }
            return sum / Double(to - from)
        }
        // The key sits 2 pt in from the picture's edge; its 1.25 pt edge is 5 device pixels at scale 4, so sample the middle of it.
        let top = row(2 * 4 + 2), bottom = row(h - 2 * 4 - 3)
        return top - bottom
    }

    /// True when any of `view` is drawn outside the `width` x 140 pt box it was given (a title or a readout that spills past its panel).
    private static func spills(_ view: AnyView, width: CGFloat, height: CGFloat = NookMetrics.widgetHeight) -> Bool? {
        let canvas = view.frame(width: width, height: height).frame(width: width * 3, height: height + 40).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let left = Int(width) - 1, right = Int(width * 2) + 1
        for y in 0..<h {
            for x in 0..<w where x < left || x > right {
                if data[(y * w + x) * 4 + 3] > 8 { return true }
            }
        }
        return false
    }

    /// The panels (and titles) that must never spill: each live panel at 3 and 4 cells (a tight row squeezes it to 3), Now playing at 4
    /// and 5, the pinned panels at their own width.
    @MainActor private static func spillCases() -> [(String, AnyView, CGFloat)] {
        let now = Date()
        func cells(_ n: Int) -> CGFloat { CGFloat(n) * NookMetrics.cell }
        var cases: [(String, AnyView, CGFloat)] = []
        func live(_ name: String, _ panel: any LivePanelSource) {
            for n in [3, 4] { cases.append(("live \(name) @\(n)", panel.makeView(), cells(n))) }
        }
        live("downloads", LiveSamples.downloads(LiveDownloadsSnapshot(downloads: [LiveSamples.transfer("Scout-0.1.0.zip", fraction: 0.64, total: 75_000_000), LiveSamples.transfer("b.zip", fraction: 0.2)])))
        live("downloads (unknown size)", LiveSamples.downloads(LiveDownloadsSnapshot(downloads: [LiveSamples.transfer("A-very-long-file-name-for-a-backup.zip", fraction: nil)])))
        live("converting", LiveSamples.downloads(LiveDownloadsSnapshot(conversions: 3)))
        live("download done", LiveSamples.downloads(LiveDownloadsSnapshot(done: LiveSamples.transfer("Scout.zip", fraction: 1, total: 75_000_000), doneAt: now)))
        live("recording", LiveSamples.recording(mic: true, since: 3725))
        live("recording (no mic)", LiveSamples.recording(mic: false, since: 754))
        live("timer", LiveSamples.timer(LiveTimerSnapshot(timers: [ClockTimer(label: "Tea", duration: 900, endDate: now.addingTimeInterval(707)), ClockTimer(label: "B", duration: 60, endDate: now.addingTimeInterval(50))])))
        live("pomodoro", LiveSamples.timer(LiveTimerSnapshot(pomodoro: PomodoroState(phase: .work, endDate: now.addingTimeInterval(1450), sessions: 2), pomodoroTotal: 25 * 60)))
        live("meeting now", LiveSamples.meeting([LiveSamples.event("Design review with the whole platform team", start: now.addingTimeInterval(-600), length: 3600, link: LiveSamples.meet)]))
        live("meeting soon", LiveSamples.meeting([LiveSamples.event("Weekly planning", start: now.addingTimeInterval(11 * 60), length: 1800, link: LiveSamples.zoom)]))
        live("bluetooth", LiveSamples.bluetooth([LiveSamples.connection(BluetoothInfo(name: "AirPods Pro", kind: .airPodsPro, left: 100, right: 64, caseLevel: 17))]))
        live("bluetooth (one device, +more)", LiveSamples.bluetooth([LiveSamples.connection(BluetoothInfo(name: "Magic Keyboard", kind: .keyboard, single: 12), ago: 3600),
                                                                      LiveSamples.connection(BluetoothInfo(name: "AirPods Max", kind: .airPodsMax, single: 71))]))
        live("todos", LiveSamples.todos([LiveSamples.todo("Pay the electricity bill", days: -1), LiveSamples.todo("Reply to Marta", days: 0), LiveSamples.todo("Water the plants"), LiveSamples.todo("Book the dentist")]))
        let player = NowPlayingService()
        player.showSample(NowPlayingService.sampleTrack)
        for n in [4, 5] {
            cases.append(("Now playing compact @\(n)", AnyView(MediaWidgetView(service: player, layout: "compact")), cells(n)))
            cases.append(("Now playing expanded @\(n)", AnyView(MediaWidgetView(service: player, layout: "expanded")), cells(n)))
        }
        let idle = NowPlayingService()
        idle.showSample(nil)
        cases.append(("Now playing empty @4", AnyView(MediaWidgetView(service: idle, layout: "compact")), cells(4)))
        let noon = Calendar.current.date(bySettingHour: 12, minute: 41, second: 0, of: now) ?? now
        let meetings = [LiveSamples.event("Design review", start: noon.addingTimeInterval(19 * 60), length: 3600, link: LiveSamples.meet),
                        LiveSamples.event("Dentist", start: noon.addingTimeInterval(4 * 3600), length: 1800)]
        let todos = [TodoTask(title: "Pay the electricity bill", day: Calendar.current.date(byAdding: .day, value: -1, to: noon)), TodoTask(title: "Reply to Marta")]
        cases.append(("Today (clock)", AnyView(TodayWidgetView(events: [], tasks: [], now: noon, fixedBattery: BatteryState(level: 12, isCharging: false, isPluggedIn: false, isCharged: false, minutesRemaining: 38))), cells(4)))
        cases.append(("Today (list)", AnyView(TodayWidgetView(events: meetings, tasks: todos, now: noon)), cells(4)))
        for style in PulseStyle.allCases { cases.append(("CPU and memory (\(style.title))", AnyView(PulseWidgetView(style: style, metrics: [.cpu, .memory, .gpu, .network])), cells(4))) }
        cases.append(("Timer (set up)", AnyView(TimerWidgetView(clock: .demo(running: false))), cells(3)))
        cases.append(("Timer (running)", AnyView(TimerWidgetView(clock: .demo(running: true))), cells(3)))
        cases.append(("Pomodoro", AnyView(PomodoroWidgetView(clock: .demo(running: true))), cells(3)))
        cases.append(("Quick Apps", AnyView(QuickAppsWidgetView()), cells(3)))
        cases.append(("Shortcuts", AnyView(ShortcutsWidgetView(preview: ["Morning routine", "Resize images", "Start focus", "Log water"])), cells(3)))
        cases.append(("To-dos", AnyView(TodoWidgetView()), cells(4)))
        cases.append(("Notes", AnyView(NotesWidgetView()), cells(4)))
        cases.append(("Clipboard", AnyView(ClipboardWidgetView()), cells(5)))
        cases.append(("Prompter", AnyView(PrompterWidgetView()), cells(4)))
        cases.append(("Calendar", AnyView(CalendarWidgetView()), cells(4)))
        return cases
    }

    // MARK: Run

    static func run(out: URL) async {
        var lines: [String] = []
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failed += 1 }
            lines.append("dash90 selftest \(ok ? "ok  " : "FAIL") \(name)\(ok || detail.isEmpty ? "" : "  (\(detail))")")
        }

        // 1. The time as segments (Today's clock and meeting rows).
        let cal = Calendar(identifier: .gregorian)
        func at(_ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: h, minute: m)) ?? Date() }
        let us = Locale(identifier: "en_US"), gb = Locale(identifier: "en_GB")
        let p1 = Dash90Time.parts(at(12, 41), locale: us, calendar: cal)
        check("12:41 in the afternoon, 12-hour: digits \"12:41\" and PM", p1.digits == "12:41" && p1.meridiem == "PM" && p1.withLetter == "12:41P", "\(p1)")
        let p2 = Dash90Time.parts(at(9, 5), locale: us, calendar: cal)
        check("  9:05 in the morning keeps a blank cell in front of the 9 and says AM", p2.digits == " 9:05" && p2.meridiem == "AM" && p2.withLetter == " 9:05A", "\(p2)")
        let p3 = Dash90Time.parts(at(0, 30), locale: us, calendar: cal)
        check("  half past midnight is 12:30 AM", p3.digits == "12:30" && p3.meridiem == "AM", "\(p3)")
        let p4 = Dash90Time.parts(at(21, 7), locale: gb, calendar: cal)
        check("  a 24-hour country shows 21:07 and no AM or PM", p4.digits == "21:07" && p4.meridiem == nil && p4.withLetter == "21:07", "\(p4)")
        let allLit = [p1, p2, p3, p4].allSatisfy { $0.withLetter.allSatisfy { $0 == " " || SevenSegment.supported.contains($0) } }
        check("  every character of every time is one the seven-segment font can light", allLit)
        let r1 = Dash90.segmentReading("37%"), r2 = Dash90.segmentReading("2.3 MB/s"), r3 = Dash90.segmentReading("—")
        check("a Pulse reading becomes digits and a unit (37% / 2.3 MB/s / no sensor)",
              r1 == ("37", "%") && r2 == ("2.3", "MB/S") && r3 == ("--", ""), "\(r1) \(r2) \(r3)")
        check("pixel letters are used only where the font draws the word as written (a Greek month or an accented word falls back to the system font)",
              Dash90.pixelSafe("SATURDAY 15 NOVEMBER 2026") && Dash90.pixelSafe("December") && !Dash90.pixelSafe("Δεκεμβρίου")
                && !Dash90.pixelSafe("Décembre") && !Dash90.pixelSafe("Läuft gerade"))

        // 2. LED bar levels: CPU, memory, battery, progress.
        func lit(_ v: Double, _ n: Int = 10) -> Int { RetroLEDBar.litCount(value: v, segments: n) }
        check("CPU 37% lights 4 of 10 segments, memory 64% lights 6, a full bar 10, an empty one 0, a missing reading 0",
              lit(0.37) == 4 && lit(0.64) == 6 && lit(1) == 10 && lit(0) == 0 && lit(.nan) == 0, "\(lit(0.37)) \(lit(0.64)) \(lit(1)) \(lit(0)) \(lit(.nan))")
        check("  the meter goes green, then yellow, then red (60 % and 85 %)",
              RetroLEDBar.zone(index: 5, segments: 10) == .green && RetroLEDBar.zone(index: 6, segments: 10) == .yellow && RetroLEDBar.zone(index: 9, segments: 10) == .red)
        check("battery 82% lights 7 of 8 segments, 12% lights 1; progress 64% of 18 lights 12, unknown progress a still quarter",
              lit(0.82, 8) == 7 && lit(0.12, 8) == 1 && LiveRetroBar.lit(0.64, segments: 18) == 12 && LiveRetroBar.lit(nil, segments: 18) == 5,
              "\(lit(0.82, 8)) \(lit(0.12, 8)) \(LiveRetroBar.lit(0.64, segments: 18)) \(LiveRetroBar.lit(nil, segments: 18))")
        check("  a battery is green when full, yellow at 40% and red at 20% (high is good)",
              Dash90.goodWhenHigh(82) == Retro.Ink.ledGreen && Dash90.goodWhenHigh(40) == Retro.Ink.ledYellow && Dash90.goodWhenHigh(20) == Retro.Ink.ledRed)

        // 3. Every tab key fits at the narrowest header (and at every width above it), in the normal header and in Edit Nook.
        // The tabs the header really draws: the saved list when there is one (Settings › Notch › Tabs), else every tab.
        let all = NotchPrefs.parseTabs(UserDefaults.standard.string(forKey: "notch.workspaces") ?? "", edited: UserDefaults.standard.bool(forKey: "notch.tabsEdited"))
        let everyTab = NotchPrefs.allTabsInOrder
        var fits = true
        var worst = ""
        for island in stride(from: NotchPrefs.widthRange.lowerBound, through: NotchPrefs.widthRange.upperBound, by: 20) {
            let side = max(40, (CGFloat(island) - 2 * (12 + 12) - NotchGeometry.sample16.size.width) / 2)
            for editing in [false, true] {
                let l = NotchHeader.TabLayout.make(everyTab, sideWidth: side, editing: editing)
                let leftWidth = CGFloat(l.left.count) * (l.width + 2) - 2
                let rightWidth = CGFloat(l.right.count) * (l.width + 2) - 2
                let rightRoom = max(0, side - NotchHeader.TabLayout.reservedRight(editing: editing))
                if l.left.count + l.right.count != everyTab.count || l.width > 27 || l.width < 18 || leftWidth > side + 0.5 || (rightWidth > rightRoom + 0.5 && !l.right.isEmpty) {
                    fits = false
                    worst = "island \(island) editing \(editing): \(l.left.count)+\(l.right.count) of \(everyTab.count) at \(l.width)"
                }
            }
        }
        check("every one of the \(all.count) tab keys (and all \(everyTab.count) the edition has) fits at every header width from the narrowest (\(Int(NotchPrefs.widthRange.lowerBound)) pt) up, 27 pt wide or less",
              fits, worst)
        var mirrorRight = true
        var mirrorWorst = ""
        for island in stride(from: NotchPrefs.widthRange.lowerBound, through: NotchPrefs.widthRange.upperBound, by: 20) {
            let side = max(40, (CGFloat(island) - 2 * (12 + 12) - NotchGeometry.sample16.size.width) / 2)
            for editing in [false, true] {
                for list in [everyTab, Array(everyTab.prefix(6)) + [.mirror], Array(everyTab.prefix(3)), Array(everyTab.prefix(5)) + [.radio]] {
                    let l = NotchHeader.TabLayout.make(list, sideWidth: side, editing: editing, extraLeft: NotchHeader.facesWidth(count: 0, more: 0))
                    let expected = NotchHeader.TabLayout.pinnedRight.filter { list.contains($0) }
                    let ok = Array(l.right.prefix(expected.count)) == expected && !l.left.contains(.mirror) && !l.left.contains(.radio)
                    if !ok { mirrorRight = false; mirrorWorst = "island \(island) editing \(editing): left \(l.left.map(\.rawValue)) right \(l.right.map(\.rawValue))" }
                }
            }
        }
        check("the Mirror (picture) tab and then the Radio always stand first right of the camera, at every header width", mirrorRight, mirrorWorst)
        check("the agents' tiny faces stand left of the camera on every view, the dashboard and the Agents view too",
              NotchHeader.showsFaces(current: .askAI) && NotchHeader.showsFaces(current: .calendar) && NotchHeader.showsFaces(current: .mirror)
                && NotchHeader.showsFaces(current: nil) && NotchHeader.showsFaces(current: .nook) && NotchHeader.showsFaces(current: .agents))
        check("  the room for two faces is always kept, so the keys never move when agents come and go",
              NotchHeader.facesWidth(count: 0, more: 0) == NotchHeader.facesWidth(count: 2, more: 0) && NotchHeader.facesWidth(count: 1, more: 0) == NotchHeader.facesWidth(count: 2, more: 0)
                && NotchHeader.maxFaces == 4)
        let usualSide = (CGFloat(NotchPrefs.openWidth) - 2 * (12 + 12) - NotchGeometry.sample16.size.width) / 2
        let withFaces = NotchHeader.TabLayout.make(everyTab, sideWidth: usualSide, editing: false, extraLeft: NotchHeader.facesWidth(count: 4, more: 1))
        check("  with four faces and a +1 every tab still fits the usual width, at full size",
              withFaces.left.count + withFaces.right.count == everyTab.count && withFaces.width == 27 && withFaces.right.first == .mirror,
              "\(withFaces.left.count)+\(withFaces.right.count) at \(withFaces.width)")
        let narrow = NotchHeader.TabLayout.make(everyTab, sideWidth: max(40, (CGFloat(NotchPrefs.widthRange.lowerBound) - 48 - NotchGeometry.sample16.size.width) / 2), editing: false)
        check("  at the narrowest header the keys keep nearly their full 27 pt (the lock key and the gear take room on the right)", narrow.width >= 25, "width \(narrow.width)")

        // 4. The selected tab is the pressed key.
        check("the selected tab is the sunken (pressed-in) key and the others are raised",
              NotchIconButton.bevel(selected: true) == .sunken && NotchIconButton.bevel(selected: false) == .raised)
        let upRaised = edgeContrast(selected: false), upSelected = edgeContrast(selected: true)
        check("  drawn under the pointer: a raised key is lit along its top edge, the selected one along its bottom edge",
              (upRaised ?? 0) > 3 && (upSelected ?? 0) < -3, "raised \(String(describing: upRaised)), selected \(String(describing: upSelected))")
        let restRaised = edgeContrast(selected: false, hover: false), restSelected = edgeContrast(selected: true, hover: false)
        check("  at rest every key is flat solid black (no edge), the selected one too",
              abs(restRaised ?? 99) < 1 && abs(restSelected ?? 99) < 1, "raised \(String(describing: restRaised)), selected \(String(describing: restSelected))")
        check("  the selected key is lit in the palette (teal), the others are dark plastic",
              Retro.luminance(NotchIconButton.face(selected: true, hover: false)) > Retro.luminance(NotchIconButton.face(selected: false, hover: false))
                && Retro.rgb(NotchIconButton.face(selected: true, hover: false)).g > Retro.rgb(NotchIconButton.face(selected: true, hover: false)).r)

        // 5. Real clicks: a tab key opens its view, and the dashboard key goes back.
        let savedPerform = NookHaptics.perform
        defer { NookHaptics.perform = savedPerform }
        NookHaptics.perform = {}
        LivePanelLookup.override = []
        defer { LivePanelLookup.override = nil }

        // 5a. Today: Join and a to-do box.
        var joins = 0, toggled = 0
        let now = Date()
        let meeting = LiveSamples.event("Design review", start: now.addingTimeInterval(-5 * 60), length: 3600, link: LiveSamples.meet)
        let todo = TodoTask(title: "Reply to Marta")
        let today = Rig(layout: [.today]) {
            AnyView(TodayWidgetView(events: [meeting], tasks: [todo], now: now, onJoin: { _ in joins += 1 }, onToggle: { _ in toggled += 1 }))
        }
        await settle(0.9)
        guard let todayRect = today.rect("panel.today") else {
            check("the Today panel draws", false, "panel rects: \(today.model.panelRects.keys.sorted())")
            today.close()
            finish(lines, failed, out: out)
            return
        }
        let controls = today.controls(in: todayRect)
        check("Today has a Join key and a to-do box, both findable as controls", controls.count >= 2, "controls \(controls.count)")
        if controls.count >= 2 {
            let join = controls[0], box = controls[1]
            today.click(CGPoint(x: join.midX, y: join.midY))
            await settle(0.3)
            check("a real click on Join runs Join and does not open the Calendar", joins == 1 && today.navigator.expanded == nil, "joins \(joins), expanded \(String(describing: today.navigator.expanded))")
            today.click(CGPoint(x: box.midX, y: box.midY))
            await settle(0.3)
            check("a real click on the to-do box ticks that to-do and does not open the Calendar", toggled == 1 && today.navigator.expanded == nil, "toggled \(toggled), expanded \(String(describing: today.navigator.expanded))")
        }
        // A click on the panel's own background still opens the Calendar.
        today.click(CGPoint(x: todayRect.midX, y: todayRect.maxY - 6))
        await settle()
        check("a click on the panel's background still opens the full Calendar", today.navigator.expanded == .calendar, "expanded \(String(describing: today.navigator.expanded))")
        // 5b. The tab keys.
        if let back = today.rect("tab.nook") { today.click(CGPoint(x: back.midX, y: back.midY)) }
        await settle()
        let backAtDashboard = today.navigator.expanded == nil
        if let tab = today.rect("tab.calendar") { today.click(CGPoint(x: tab.midX, y: tab.midY)) }
        await settle()
        let opened = today.navigator.expanded == .calendar
        check("a real click on the Calendar tab key opens the Calendar, and on the dashboard key goes back", backAtDashboard && opened,
              "tab \(String(describing: today.rect("tab.calendar"))), back \(backAtDashboard), opened \(opened)")
        // 5b'. The Mirror key stands right of the camera, the lock key right of it; a real click on the lock key keeps the Calendar (on show) as the
        // opening tab, and a second click lets go.
        let cameraRight = today.size.width / 2 + NotchGeometry.sample16.size.width / 2 - 1
        if let mirrorKey = today.rect("tab.mirror"), let lockKey = today.rect("tab.lock") {
            check("the Mirror key stands right of the camera, and the lock key right of the Mirror key", mirrorKey.minX >= cameraRight && lockKey.minX > mirrorKey.maxX,
                  "camera right \(cameraRight), mirror \(mirrorKey), lock \(lockKey)")
            let air = mirrorKey.minX - (cameraRight + 1)
            check("  with the same air after the camera as the faces keep before it", abs(air - NotchHeader.TabLayout.cameraGap) < 1.5, "air \(air)")
        } else {
            check("the Mirror key and the lock key report their rects (tab.mirror, tab.lock)", false, "mirror \(String(describing: today.rect("tab.mirror"))), lock \(String(describing: today.rect("tab.lock")))")
        }
        let savedLock = UserDefaults.standard.object(forKey: NotchPrefs.lockedTabKey)
        defer { UserDefaults.standard.set(savedLock, forKey: NotchPrefs.lockedTabKey) }
        UserDefaults.standard.removeObject(forKey: NotchPrefs.lockedTabKey)
        if let lockKey = today.rect("tab.lock") { today.click(CGPoint(x: lockKey.midX, y: lockKey.midY)) }
        await settle(0.3)
        let lockedNow = NotchPrefs.lockedTab
        let nextOpening = NotchNavigator()
        nextOpening.open()
        check("a real click on the lock key keeps the tab on show (the Calendar) as the one the notch opens on", lockedNow == .calendar && nextOpening.expanded == .calendar,
              "locked \(String(describing: lockedNow)), next opening \(String(describing: nextOpening.expanded))")
        if let tab = today.rect("tab.calendar") { today.click(CGPoint(x: tab.midX, y: tab.midY)) }
        if let lockKey = today.rect("tab.lock") { today.click(CGPoint(x: lockKey.midX, y: lockKey.midY)) }
        await settle(0.3)
        check("  a second click on it (on the locked tab) lets go: the notch opens on the dashboard again", NotchPrefs.lockedTab == nil && { let n = NotchNavigator(); n.open(); return n.expanded == nil }())
        check("  the key's help says what it does for the tab on show",
              NotchHeader.lockHelp(shown: .calendar, locked: nil).contains("every time") && NotchHeader.lockHelp(shown: .calendar, locked: .calendar).contains("unlock")
                && NotchHeader.lockHelp(shown: .agents, locked: .calendar).contains("now: Calendar") && NotchHeader.lockHelp(shown: .mirror, locked: nil).contains("camera"))
        let tabKinds = all.allSatisfy { today.rect("tab.\($0.rawValue)") != nil }
        check("  every tab key keeps its reported name (tab.<kind>)", tabKinds,
              "missing \(all.filter { today.rect("tab.\($0.rawValue)") == nil }.map(\.rawValue)), all \(all.map(\.rawValue))")
        today.close()

        // 5c. The Ask AI terminal: the real field takes text, the send key sends into Fast Ask AI.
        let store = AIChatStore()
        let draft = AskAINotchDraft()
        let ask = Rig(layout: [.askAI]) { AnyView(AskAIWidgetView(store: store, draft: draft)) }
        await settle(0.9)
        if let askRect = ask.rect("panel.askAI"), let field = ask.firstTextField() {
            check("the terminal has no question yet and Fast Ask AI does not exist", draft.text.isEmpty && store.quickID == nil)
            ask.panel.makeFirstResponder(field)
            (field.currentEditor() as? NSTextView)?.insertText("What is the capital of Portugal?", replacementRange: NSRange(location: 0, length: 0))
            await settle(0.4)
            check("the prompt line's real field takes typed text", draft.text == "What is the capital of Portugal?" && draft.canSend, "draft \"\(draft.text)\"")
            let keys = ask.controls(in: askRect).filter { $0.width < 40 }.sorted { $0.midX > $1.midX }
            if let send = keys.first {
                ask.click(CGPoint(x: send.midX, y: send.midY))
                await settle(0.5)
                let q = store.quickChat
                check("a real click on the send key puts the question into Fast Ask AI; the answer stays in the panel (the dashboard keeps its height)",
                      q?.title == AIChatStore.quickTitle && q?.messages.first?.text == "What is the capital of Portugal?" && draft.text.isEmpty
                        && ask.navigator.neededHeight(shown: .nook) == 0,
                      "quick \(String(describing: q?.messages.first?.text)), draft \"\(draft.text)\", height \(ask.navigator.neededHeight(shown: .nook))")
                check("  the notch stays on the dashboard", ask.navigator.expanded == nil, "expanded \(String(describing: ask.navigator.expanded))")
            } else {
                check("the send key is findable as a control", false, "controls \(ask.controls(in: askRect).map { $0.size })")
            }
            for _ in 0..<200 where store.isBusy { await settle(0.02) }
        } else {
            check("the Ask AI panel and its text field draw", false, "panels \(ask.model.panelRects.keys.sorted())")
        }
        ask.close()

        // 5d. Nothing spills past its panel, even when a tight row squeezes a live panel to 3 cells.
        var spilled: [String] = [], unrendered: [String] = []
        for (name, view, width) in spillCases() {
            switch spills(view, width: width) {
            case true?: spilled.append(name)
            case nil: unrendered.append(name)
            default: break
            }
        }
        check("no title bar or readout spills past its panel (every live panel at 3 and 4 cells, Now playing at 4 and 5, the pinned panels)", spilled.isEmpty, spilled.joined(separator: "; "))
        check("  every one of those pictures could be drawn", unrendered.isEmpty, unrendered.joined(separator: "; "))

        // 6. The panel face never costs a panel its controls: the panel rects keep their names and size.
        let probe = Rig(layout: [.agents, .askAI, .pulse, .today]) { AnyView(Color.clear) }
        await settle(0.8)
        let names = ["panel.agents", "panel.askAI", "panel.pulse", "panel.today"]
        let rects = names.compactMap { probe.rect($0) }
        check("every panel keeps its reported rect (panel.<id>) at 140 pt tall", rects.count == names.count && rects.allSatisfy { abs($0.height - NookMetrics.widgetHeight) < 0.5 },
              "rects \(rects.map { $0.size })")
        probe.close()

        // 7. The dashboard's one grid (`DashGrid`), in both looks: the rows of the default panels stand on the same lines.
        await gridChecks(check)

        finish(lines, failed, out: out)
    }

    // MARK: The grid

    /// A panel drawn offscreen at its real size (a borderless window far off the screen), with the grid rows it reports.
    @MainActor private final class PanelProbe {
        final class Box {
            var rows: [String: CGRect] = [:]
            var frames: [String: CGRect] = [:]
        }

        let box = Box()
        let view: AnyView
        let width: CGFloat
        private let window: NSWindow

        init(_ view: AnyView, width: CGFloat = 4 * NookMetrics.cell) {
            self.view = view
            self.width = width
            window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: width, height: NookMetrics.widgetHeight), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let box = self.box
            let root = view
                .frame(width: width, height: NookMetrics.widgetHeight)
                .coordinateSpace(name: "agentnook")
                .coordinateSpace(name: "dashpanel")
                .onPreferenceChange(DashRowKey.self) { box.rows = $0 }
                .onPreferenceChange(AgentNookFramesKey.self) { box.frames = $0 }
            let hosting = NSHostingView(rootView: root)
            hosting.frame = CGRect(x: 0, y: 0, width: width, height: NookMetrics.widgetHeight)
            window.contentView = hosting
            window.orderFrontRegardless()
        }

        func row(_ name: String) -> CGRect? { box.rows[name] }

        /// The panel as pixels (2 per point, on black), for where its ink starts.
        func pixels() -> (data: [UInt8], w: Int, h: Int)? {
            let renderer = ImageRenderer(content: view.frame(width: width, height: NookMetrics.widgetHeight).background(Color.black).environment(\.colorScheme, .dark))
            renderer.scale = 2
            guard let cg = renderer.cgImage else { return nil }
            let w = cg.width, h = cg.height
            var data = [UInt8](repeating: 0, count: w * h * 4)
            guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return (data, w, h)
        }

        /// The top of the bright ink inside `rect` (in points), skipping the faint ink (symbols, ghost segments): where the letters' tops stand.
        func inkTop(in rect: CGRect, threshold: Double = 130) -> CGFloat? {
            guard let px = pixels() else { return nil }
            let x0 = max(0, Int(rect.minX * 2)), x1 = min(px.w, Int(rect.maxX * 2))
            let y0 = max(0, Int(rect.minY * 2)), y1 = min(px.h, Int(rect.maxY * 2))
            guard x0 < x1, y0 < y1 else { return nil }
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = (y * px.w + x) * 4
                    if 0.299 * Double(px.data[i]) + 0.587 * Double(px.data[i + 1]) + 0.114 * Double(px.data[i + 2]) > threshold { return CGFloat(y) / 2 }
                }
            }
            return nil
        }

        /// Where the bright ink inside `rect` (in points) lies, as the smallest rectangle around it (nil when there is none).
        func inkBounds(in rect: CGRect, threshold: Double = 130) -> CGRect? {
            guard let px = pixels() else { return nil }
            let x0 = max(0, Int(rect.minX * 2)), x1 = min(px.w, Int(rect.maxX * 2))
            let y0 = max(0, Int(rect.minY * 2)), y1 = min(px.h, Int(rect.maxY * 2))
            guard x0 < x1, y0 < y1 else { return nil }
            var box: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = (y * px.w + x) * 4
                    guard 0.299 * Double(px.data[i]) + 0.587 * Double(px.data[i + 1]) + 0.114 * Double(px.data[i + 2]) > threshold else { continue }
                    box = box.map { (min($0.minX, x), min($0.minY, y), max($0.maxX, x), max($0.maxY, y)) } ?? (x, y, x, y)
                }
            }
            return box.map { CGRect(x: CGFloat($0.minX) / 2, y: CGFloat($0.minY) / 2, width: CGFloat($0.maxX - $0.minX + 1) / 2, height: CGFloat($0.maxY - $0.minY + 1) / 2) }
        }

        /// The mean colour (red, green, blue, 0 to 1) of the bright ink inside `rect` (in points): the colour a reading is drawn in.
        func inkColor(in rect: CGRect, threshold: Double = 130) -> (r: Double, g: Double, b: Double)? {
            guard let px = pixels() else { return nil }
            let x0 = max(0, Int(rect.minX * 2)), x1 = min(px.w, Int(rect.maxX * 2))
            let y0 = max(0, Int(rect.minY * 2)), y1 = min(px.h, Int(rect.maxY * 2))
            guard x0 < x1, y0 < y1 else { return nil }
            var sum = (0.0, 0.0, 0.0), n = 0.0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = (y * px.w + x) * 4
                    let r = Double(px.data[i]), g = Double(px.data[i + 1]), b = Double(px.data[i + 2])
                    guard 0.299 * r + 0.587 * g + 0.114 * b > threshold else { continue }
                    sum = (sum.0 + r / 255, sum.1 + g / 255, sum.2 + b / 255)
                    n += 1
                }
            }
            return n > 0 ? (sum.0 / n, sum.1 / n, sum.2 / n) : nil
        }

        func close() {
            window.contentView = nil
            window.orderOut(nil)
        }
    }

    /// The grid in both looks (only the forced one when `SCOUT_8BIT` forces it); the 8-bit/minimal setting is put back afterwards.
    @MainActor private static func gridChecks(_ check: (String, Bool, String) -> Void) async {
        let forced = ProcessInfo.processInfo.environment["SCOUT_8BIT"] != nil
        let saved = UserDefaults.standard.object(forKey: Retro.styleKey)
        for eightBit in forced ? [Retro.is8bit] : [true, false] {
            if !forced { Pref.set(eightBit, Retro.styleKey) }
            await gridChecks(eightBit: eightBit, check)
        }
        if !forced { Pref.set(saved, Retro.styleKey) }
    }

    @MainActor private static func gridChecks(eightBit: Bool, _ check: (String, Bool, String) -> Void) async {
        let look = eightBit ? "[8-bit] " : "[minimal] "
        let inset = DashGrid.inset
        func near(_ a: CGFloat?, _ b: CGFloat?, _ tolerance: CGFloat = 0.5) -> Bool {
            guard let a, let b else { return false }
            return abs(a - b) <= tolerance
        }
        func describe(_ r: CGRect?) -> String { r.map { "\(Int($0.minX)),\($0.minY) \(Int($0.width))x\($0.height)" } ?? "none" }

        let noon = Calendar.current.date(bySettingHour: 12, minute: 41, second: 0, of: Date()) ?? Date()
        let meetings = [LiveSamples.event("Design review", start: noon.addingTimeInterval(19 * 60), length: 3600, link: LiveSamples.meet),
                        LiveSamples.event("Dentist", start: noon.addingTimeInterval(4 * 3600), length: 1800)]
        let todos = [TodoTask(title: "Pay the electricity bill", day: Calendar.current.date(byAdding: .day, value: -1, to: noon)), TodoTask(title: "Reply to Marta")]
        let battery = BatteryState(level: 78, isCharging: false, isPluggedIn: false, isCharged: false, minutesRemaining: 250)

        let pulse = PanelProbe(AnyView(PulseWidgetView(style: .cards, metrics: [.cpu, .memory], battery: battery)))
        let pulseNet = PanelProbe(AnyView(PulseWidgetView(style: .cards, metrics: [.cpu, .network], battery: battery)))
        let today = PanelProbe(AnyView(TodayWidgetView(events: meetings, tasks: todos, now: noon)))
        let todayEmpty = PanelProbe(AnyView(TodayWidgetView(events: [], tasks: [], now: noon)))
        let ask = PanelProbe(AnyView(AskAIWidgetView(store: AIChatStore(), draft: AskAINotchDraft())))
        let agentsEmpty = PanelProbe(AnyView(AgentMiniPanel(store: AgentNookSamples.store(AgentNookSamples.sessions(0)))))
        let agents = PanelProbe(AnyView(AgentMiniPanel(store: AgentNookSamples.store(AgentNookSamples.sessions(3)))), width: 6 * NookMetrics.cell)
        await settle(0.8)
        defer { [pulse, pulseNet, today, todayEmpty, ask, agentsEmpty, agents].forEach { $0.close() } }

        // Row 1: the readouts (CPU and memory, the clock).
        let pr = pulse.row("readout"), tr = today.row("readout")
        check("\(look)CPU & Memory's readings and Today's time stand in row 1 of the grid: the same top (\(Int(inset.top)) pt) and height (\(Int(DashGrid.readoutHeight)) pt)",
              near(pr?.minY, inset.top) && near(tr?.minY, inset.top) && near(pr?.height, DashGrid.readoutHeight) && near(tr?.height, DashGrid.readoutHeight),
              "pulse \(describe(pr)), today \(describe(tr))")
        let pb = pulse.row("readout.baseline")?.maxY, tb = today.row("readout.baseline")?.maxY
        check("\(look)  the CPU and memory digits and the clock's digits share their baseline (within 1 pt)", near(pb, tb, 1), "pulse \(String(describing: pb)), today \(String(describing: tb))")
        if let pr, let tr {
            let pTop = pulse.inkTop(in: pr), tTop = today.inkTop(in: tr)
            check("\(look)  and stand equally tall (their tops within 1 pt): one digit size", near(pTop, tTop, 1), "pulse top \(String(describing: pTop)), today top \(String(describing: tTop))")
        }

        // Row 2 of the grid is Today's date line (CPU & Memory's SSD line moved under its graphs, 2026-11-17, see below).
        let ti = today.row("info"), tei = todayEmpty.row("info")
        check("\(look)Today's date line stands on row 2 of the grid (\(Int(DashGrid.infoTop)) pt down, \(Int(DashGrid.infoHeight)) pt tall), with meetings and without",
              near(ti?.minY, DashGrid.infoTop) && near(tei?.minY, DashGrid.infoTop) && near(ti?.height, DashGrid.infoHeight) && near(tei?.height, DashGrid.infoHeight),
              "today \(describe(ti)), today empty \(describe(tei))")
        // The internet's speeds on CPU & Memory's last line.
        check("\(look)CPU & Memory shows the internet's speeds (down and up); only the Mac's own ports count, a VPN's tunnel and AirDrop do not",
              PulseSample.speedText(1_450_000) == "1.4 MB/s" && PulseSample.speedText(310_000) == "303 KB/s" && PulseSample.speedText(10) == "0 KB/s"
                && PulseSampler.countsTowardInternet("en0") && PulseSampler.countsTowardInternet("en7")
                && !PulseSampler.countsTowardInternet("utun4") && !PulseSampler.countsTowardInternet("awdl0") && !PulseSampler.countsTowardInternet("bridge0")
                && !PulseSampler.countsTowardInternet("ipsec0") && !PulseSampler.countsTowardInternet("llw0"), "")

        // CPU & Memory's own order:
        // the readings, each one's graph, the SSD and battery line, the network line.
        let bottom = NookMetrics.widgetHeight - inset.bottom
        let pr0 = pulse.row("pulse.readout.0"), pr1 = pulse.row("pulse.readout.1")
        let ps0 = pulse.row("pulse.scope.0"), ps1 = pulse.row("pulse.scope.1"), pscopes = ps0
        let pssd = pulse.row("pulse.status"), pnet = pulse.row("pulse.network")
        let ordered = [pr?.maxY, pscopes?.minY, pscopes?.maxY, pssd?.minY, pssd?.maxY, pnet?.minY, pnet?.maxY]
        let inOrder = zip(ordered, ordered.dropFirst()).allSatisfy { a, b in a != nil && b != nil && a! <= b! + 0.5 }
        check("\(look)CPU & Memory, top to bottom: the readings, their graphs, the SSD and battery line, the network line (nothing overlaps)", inOrder,
              "readout \(describe(pr)), graphs \(describe(pscopes)), SSD \(describe(pssd)), network \(describe(pnet))")
        check("\(look)  each graph stands right under its own reading: the same left edge and width as that reading's column",
              near(ps0?.minX, pr0?.minX) && near(ps0?.width, pr0?.width) && near(ps1?.minX, pr1?.minX) && near(ps1?.width, pr1?.width) && (ps0?.width ?? 0) > 20,
              "CPU \(describe(pr0)) / \(describe(ps0)), memory \(describe(pr1)) / \(describe(ps1))")
        check("\(look)  the graphs start right under row 1 with the grid's normal gap (\(Int(DashGrid.readoutGap)) pt, \(Int(DashGrid.infoTop)) pt down)",
              near(pscopes?.minY, DashGrid.infoTop) && near(ps0?.minY, DashGrid.infoTop) && near(ps1?.minY, DashGrid.infoTop) && near(pr.map { $0.maxY + DashGrid.readoutGap }, pscopes?.minY),
              "graphs \(describe(pscopes)), readout \(describe(pr))")
        let scopeHeight = ps0?.height ?? 0
        // Each graph takes half the room between row 1 and the SSD line.
        let room = (pssd?.minY ?? 0) - 4 - (ps0?.minY ?? 0)
        check("\(look)  the graphs take half the room between row 1 and the SSD line (\(String(format: "%.1f", scopeHeight)) pt of \(String(format: "%.1f", room)) pt each, readable: at least 24 pt)",
              scopeHeight >= 24 && abs(scopeHeight - room / 2) <= 1 && near(ps0?.height, ps1?.height) && near(ps0?.maxY, ps1?.maxY),
              "graphs \(describe(ps0)) \(describe(ps1)), SSD \(describe(pssd))")
        check("\(look)  the SSD line sits above the network line, each a single line (\(Int(DashGrid.infoHeight)) pt), a small gap between them; under the graphs the other half of the room",
              near(pssd?.height, DashGrid.infoHeight) && near(pnet?.height, DashGrid.infoHeight)
                && (pssd.flatMap { s in pnet.map { $0.minY - s.maxY } } ?? 0) >= 1 && (pssd.flatMap { s in pnet.map { $0.minY - s.maxY } } ?? 99) <= 6
                && abs((pssd.flatMap { s in pscopes.map { s.minY - $0.maxY } } ?? 0) - (scopeHeight + 4)) <= 1.5,
              "SSD \(describe(pssd)), network \(describe(pnet)), graphs \(describe(pscopes))")
        check("\(look)  the network line is the panel's last: it ends on the bottom inset (\(Int(bottom)) pt), like Ask AI's question line and the lists' room",
              near(pnet?.maxY, bottom), describe(pnet))
        // A reading that keeps a small line under its graph (the network's upload speed) leaves both columns the same room: equal graphs.
        let ns0 = pulseNet.row("pulse.scope.0"), ns1 = pulseNet.row("pulse.scope.1")
        check("\(look)  with Network as a reading: no second network line, and both graphs stay equally tall",
              pulseNet.row("pulse.network") == nil && near(ns0?.height, ns1?.height) && (ns0?.height ?? 0) >= 20 && near(ns0?.minX, pulseNet.row("pulse.readout.0")?.minX) && near(ns1?.minX, pulseNet.row("pulse.readout.1")?.minX),
              "graphs \(describe(ns0)) \(describe(ns1)), readouts \(describe(pulseNet.row("pulse.readout.0"))) \(describe(pulseNet.row("pulse.readout.1"))), network \(describe(pulseNet.row("pulse.network")))")
        if let pssd {
            let pTop = pulse.inkTop(in: pssd), tTop = today.inkTop(in: ti ?? .zero), tib = today.row("info.baseline")?.maxY, pib = pulse.row("info.baseline")?.maxY
            let pCap = pTop.flatMap { top in pib.map { $0 - top } }, tCap = tTop.flatMap { top in tib.map { $0 - top } }
            check("\(look)  the SSD line is in the same font as Today's date line: the letters stand equally tall on their baselines (within 1 pt)", near(pCap, tCap, 1) && (pCap ?? 0) > 5,
                  "SSD line cap \(String(describing: pCap)), date cap \(String(describing: tCap))")
        }

        // The body of Today.
        let tbody = today.row("body"), tebody = todayEmpty.row("body")
        check("\(look)Today's list starts on the grid's body line (\(Int(DashGrid.bodyTop)) pt down), with meetings and without",
              near(tbody?.minY, DashGrid.bodyTop) && near(tebody?.minY, DashGrid.bodyTop), "today \(describe(tbody)), today empty \(describe(tebody))")
        check("\(look)  Today's rows fit the panel: the list ends inside the bottom inset", (tbody?.maxY ?? 999) <= NookMetrics.widgetHeight - inset.bottom + 0.5, describe(tbody))

        // The same left edge in every panel.
        let lefts: [(String, CGRect?)] = [("CPU readout", pr), ("CPU graphs", pscopes), ("CPU SSD line", pssd), ("CPU network line", pnet), ("Today time", tr), ("Today date", ti), ("Ask AI empty line", ask.row("empty")),
                                          ("Agents empty line", agentsEmpty.row("empty")), ("Today empty line", todayEmpty.row("empty"))]
        let offLeft = lefts.filter { !near($0.1?.minX, inset.leading) }
        check("\(look)every panel's lines start \(Int(inset.leading)) pt from its left edge (readouts, graphs, info lines, empty lines)", offLeft.isEmpty,
              offLeft.map { "\($0.0) \(describe($0.1))" }.joined(separator: "; "))

        // Panels without a readout start their list where every first line starts.
        let askEmpty = ask.row("empty"), agentsCalm = agentsEmpty.row("empty")
        check("\(look)an empty list says so in its first row's place, at the top: Ask AI's and the Agents' empty lines stand at \(Int(inset.top)) pt, on one line",
              near(askEmpty?.minY, inset.top) && near(agentsCalm?.minY, inset.top) && near(askEmpty?.height, agentsCalm?.height, 1),
              "ask \(describe(askEmpty)), agents \(describe(agentsCalm))")
        if !eightBit {
            let firstRow = agents.box.frames.filter { $0.key.hasPrefix("nk-") }.values.min { $0.minY < $1.minY }
            check("\(look)  the Agents' first row stands at the top too, its dot at the panel's left edge (no title above it)",
                  near(firstRow?.minY, inset.top) && near(firstRow.map { $0.minX + AgentMiniPanelLayout.rowPadding }, inset.leading) && near(firstRow?.height, DashGrid.rowHeight),
                  "first row \(describe(firstRow)), frames \(agents.box.frames.keys.sorted())")
        }

        // Ask AI's question line: the grid's control bar, on the bottom inset, as tall in both looks.
        let control = ask.row("control")
        check("\(look)Ask AI's question line stands on the bottom inset, \(Int(DashGrid.controlHeight)) pt tall",
              near(control?.maxY, NookMetrics.widgetHeight - inset.bottom) && near(control?.height, DashGrid.controlHeight), describe(control))

        // CPU & Memory in the real notch at each Size (Normal, Large, Extra large: `Look.Size`): the whole notch is scaled, the panel stays 140 pt
        // in its own points, so the graphs keep their height there and are drawn that much larger; nothing is cut and the graphs never shrink.
        let forcedScale = ProcessInfo.processInfo.environment["SCOUT_SCALE"] != nil
        let savedSize = UserDefaults.standard.object(forKey: Look.scaleKey)
        defer { if let savedSize { UserDefaults.standard.set(savedSize, forKey: Look.scaleKey) } else { UserDefaults.standard.removeObject(forKey: Look.scaleKey) } }
        for size in forcedScale ? [Look.size] : Look.Size.allCases {
            if !forcedScale { Pref.set(size.rawValue, Look.scaleKey) }
            let box = PanelProbe.Box()
            let rig = Rig(layout: [.pulse]) {
                AnyView(PulseWidgetView(style: .cards, metrics: [.cpu, .memory], battery: battery).coordinateSpace(name: "dashpanel").onPreferenceChange(DashRowKey.self) { box.rows = $0 })
            }
            await settle(0.9)
            let f = size.factor
            let panel = rig.rect("panel.pulse")
            let graph = box.rows["pulse.scope.0"], net = box.rows["pulse.network"]
            check("\(look)at size \(size.title) (x\(f)) the CPU & Memory panel is \(Int((NookMetrics.widgetHeight * f).rounded())) pt tall on screen, its graphs \(String(format: "%.1f", (graph?.height ?? 0) * f)) pt tall (\(String(format: "%.1f", graph?.height ?? 0)) in panel points, at least 24: half the room), and the network line ends on the bottom inset",
                  near(panel?.height, NookMetrics.widgetHeight * f, 1.5) && (graph?.height ?? 0) >= 24 && near(net?.maxY, NookMetrics.widgetHeight - inset.bottom),
                  "panel \(describe(panel)), graph \(describe(graph)), network \(describe(net)), rows \(box.rows.keys.sorted())")
            rig.close()
        }

        await gpuChecks(eightBit: eightBit, battery: battery, check)
    }

    // MARK: CPU, memory and GPU

    /// The width a reading takes by itself (its name, digits and unit as drawn, nothing around it).
    @MainActor private static func naturalWidth(_ metric: PulseMetric, _ headline: String, smallestDigits: Bool = false) -> CGFloat {
        NSHostingView(rootView: PulseReadout(metric: metric, headline: headline, smallestDigits: smallestDigits).fixedSize()).fittingSize.width
    }

    /// The GPU as the third reading of the CPU & Memory panel, in the look
    /// being checked: with a GPU reading the panel shows three readings with their graphs, all three fit inside it (measured, nothing touches
    /// or spills), at every Size; with no GPU reading, or in a row too tight for the wider panel, it is the panel of CPU and memory as it was.
    @MainActor private static func gpuChecks(eightBit: Bool, battery: BatteryState, _ check: (String, Bool, String) -> Void) async {
        let look = eightBit ? "[8-bit] " : "[minimal] "
        let inset = DashGrid.inset
        func near(_ a: CGFloat?, _ b: CGFloat?, _ tolerance: CGFloat = 0.5) -> Bool {
            guard let a, let b else { return false }
            return abs(a - b) <= tolerance
        }
        func describe(_ r: CGRect?) -> String { r.map { "\(Int($0.minX)),\($0.minY) \(Int($0.width))x\($0.height)" } ?? "none" }
        let span = WidgetKind.pulse.defaultSpan
        let width = CGFloat(span) * NookMetrics.cell
        let oldWidth = 4 * NookMetrics.cell
        let content = width - inset.leading - inset.trailing
        func panel(_ metrics: [PulseMetric], _ sample: PulseSample, width w: CGFloat) -> PanelProbe {
            PanelProbe(AnyView(PulseWidgetView(style: .cards, metrics: metrics, battery: battery).environment(\.pulseSampleOverride, sample)), width: w)
        }
        PulseSampler.shared.loadSamples()   // the graphs' history (the readings themselves come from each panel's own sample)
        let reading = PulseSampler.sample()
        let withGPU = panel([.cpu, .memory, .gpu], reading, width: width)
        let none = panel([.cpu, .memory, .gpu], PulseSampler.sample(gpu: nil), width: width)
        let two = panel([.cpu, .memory], reading, width: width)
        let full = panel([.cpu, .memory, .gpu], PulseSampler.sample(cpu: 1, memory: 1, gpu: 1), width: width)
        let tight = panel([.cpu, .memory, .gpu], reading, width: oldWidth)
        let noneOld = panel([.cpu, .memory, .gpu], PulseSampler.sample(gpu: nil), width: oldWidth)
        let twoOld = panel([.cpu, .memory], reading, width: oldWidth)
        await settle(0.8)
        defer {
            [withGPU, none, two, full, tight, noneOld, twoOld].forEach { $0.close() }
            PulseSampler.shared.clearSamples()
        }

        // The panel is as wide as the look needs: 5 cells for the pixel letters, 6 for the minimal look's system text.
        check("\(look)the CPU & Memory panel is \(span) cells (\(Int(width)) pt) wide by default in this look",
              span == (eightBit ? 5 : 6) && WidgetKind.pulse.defaultSpan == span, "span \(span)")

        // Without the GPU among the chosen metrics (Settings › Pulse), or with it in the first two, there is no third reading and no extra width.
        let savedMetrics = UserDefaults.standard.object(forKey: PulsePrefs.metricsKey)
        Pref.set(PulsePrefs.raw([.cpu, .memory, .network, .disk]), PulsePrefs.metricsKey)
        let withoutGPU = WidgetKind.pulse.defaultSpan
        Pref.set(PulsePrefs.raw([.cpu, .gpu, .network]), PulsePrefs.metricsKey)
        let gpuSecond = WidgetKind.pulse.defaultSpan
        Pref.set(PulsePrefs.raw([.cpu, .network, .gpu]), PulsePrefs.metricsKey)
        let networkSecond = WidgetKind.pulse.defaultSpan
        Pref.set(savedMetrics, PulsePrefs.metricsKey)
        check("\(look)  with GPU switched off in Settings (or among the first two, or after a network reading) the panel is the old 4 cells",
              withoutGPU == 4 && gpuSecond == 4 && networkSecond == 4 && WidgetKind.pulse.defaultSpan == span, "\(withoutGPU) \(gpuSecond) \(networkSecond)")

        // The third reading: in row 1 of the grid like the other two, its graph under it like theirs.
        let rs = (0..<3).map { withGPU.row("pulse.readout.\($0)") }
        let gs = (0..<3).map { withGPU.row("pulse.scope.\($0)") }
        check("\(look)with a GPU reading the panel shows three readings, CPU, memory and GPU, each with its own graph under it",
              rs.allSatisfy { $0 != nil } && gs.allSatisfy { $0 != nil } && withGPU.row("pulse.readout.3") == nil, "readouts \(rs.map(describe)), graphs \(gs.map(describe))")
        check("\(look)  the three readings stand in row 1 of the grid: the same top (\(Int(inset.top)) pt) and height (\(Int(DashGrid.readoutHeight)) pt)",
              rs.allSatisfy { near($0?.minY, inset.top) && near($0?.height, DashGrid.readoutHeight) }, rs.map(describe).joined(separator: " "))
        check("\(look)  each graph stands right under its own reading: the same left edge and width, the grid's normal gap",
              (0..<3).allSatisfy { near(gs[$0]?.minX, rs[$0]?.minX) && near(gs[$0]?.width, rs[$0]?.width) && near(gs[$0]?.minY, DashGrid.infoTop) },
              "readouts \(rs.map(describe)), graphs \(gs.map(describe))")
        let twoGraph = two.row("pulse.scope.0")
        check("\(look)  the graphs are as tall and as high as the two readings' were (\(String(format: "%.1f", twoGraph?.height ?? 0)) pt, at least 24), all three equal",
              (twoGraph?.height ?? 0) >= 24 && gs.allSatisfy { near($0?.height, twoGraph?.height) && near($0?.maxY, twoGraph?.maxY) }, gs.map(describe).joined(separator: " "))
        check("\(look)  the SSD and battery line and the network line stand where they stood with two readings",
              near(withGPU.row("pulse.status")?.minY, two.row("pulse.status")?.minY) && near(withGPU.row("pulse.network")?.minY, two.row("pulse.network")?.minY)
                && near(withGPU.row("pulse.network")?.maxY, NookMetrics.widgetHeight - inset.bottom),
              "status \(describe(withGPU.row("pulse.status"))) / \(describe(two.row("pulse.status"))), network \(describe(withGPU.row("pulse.network"))) / \(describe(two.row("pulse.network")))")

        // Fit, measured: the readings' own widths against the room, and the columns against each other and the panel's edges.
        let natural = [naturalWidth(.cpu, "37%"), naturalWidth(.memory, "64%"), naturalWidth(.gpu, "21%")]
        let gap: CGFloat = 6
        let need = natural.reduce(0, +) + 2 * gap
        let worst = [naturalWidth(.cpu, "100%", smallestDigits: true), naturalWidth(.memory, "100%", smallestDigits: true), naturalWidth(.gpu, "100%", smallestDigits: true)]
        let worstNeed = worst.reduce(0, +) + 2 * gap
        check("\(look)  the three readings fit side by side: \(Int(need)) pt of \(Int(content)) pt (37 / 64 / 21 %), and \(Int(worstNeed)) pt at 100 / 100 / 100 % with the smallest digits",
              need <= content && worstNeed <= content, "natural \(natural), worst \(worst), room \(content)")
        let fits = zip(rs, natural).allSatisfy { r, n in (r?.width ?? 0) >= n - 0.5 }
        let apart = rs[0].flatMap { a in rs[1].map { b in b.minX - a.maxX >= gap - 0.5 } } == true && rs[1].flatMap { a in rs[2].map { b in b.minX - a.maxX >= gap - 0.5 } } == true
        check("\(look)  every reading has the room its own width needs, the columns are \(Int(gap)) pt apart and the last ends inside the panel's right inset",
              fits && apart && near(rs[0]?.minX, inset.leading) && (rs[2]?.maxX ?? 999) <= width - inset.trailing + 0.5,
              "readouts \(rs.map(describe)), natural \(natural), panel \(Int(width))")
        // Pixels: ink in every reading and its graph, none in the gaps between the readings, nothing past the panel's box.
        let band = { (r: CGRect?) in r.map { CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) } }
        let inks = (0..<3).map { i in band(rs[i]).flatMap { withGPU.inkTop(in: $0) } != nil && gs[i].flatMap { withGPU.inkTop(in: $0, threshold: 60) } != nil }
        let gapRects = (0..<2).compactMap { i in rs[i].flatMap { a in rs[i + 1].map { b in CGRect(x: a.maxX, y: a.minY, width: b.minX - a.maxX, height: a.height).insetBy(dx: 1, dy: 0) } } }   // a point in from each side: pixel letters snap to half points
        let inkInGaps = gapRects.compactMap { withGPU.inkBounds(in: $0, threshold: 40) }
        check("\(look)  each reading and its graph draw (the GPU's digits and its line too), and nothing is drawn in the gaps between the readings",
              inks.allSatisfy { $0 } && gapRects.count == 2 && inkInGaps.isEmpty, "ink \(inks), gaps \(gapRects.map(describe)), ink in gaps \(inkInGaps.map(describe))")
        check("\(look)  nothing of the panel is drawn outside its \(Int(width)) x \(Int(NookMetrics.widgetHeight)) pt box",
              spills(withGPU.view, width: width) == false, "")
        // Colour: the GPU's digits in teal in the 8-bit look (CPU green, memory amber), plain soft white in the minimal one; every graph one line colour.
        if let c = rs[0].flatMap({ withGPU.inkColor(in: band($0)!) }), let m = rs[1].flatMap({ withGPU.inkColor(in: band($0)!) }), let g = rs[2].flatMap({ withGPU.inkColor(in: band($0)!) }) {
            let apartFromCPU = abs(g.r - c.r) + abs(g.g - c.g) + abs(g.b - c.b), apartFromMemory = abs(g.r - m.r) + abs(g.g - m.g) + abs(g.b - m.b)
            if eightBit {
                check("\(look)  the GPU's digits are teal (blue as bright as green, little red), not the CPU's green or the memory's amber",
                      g.b >= g.g * 0.7 && g.r <= g.g * 0.6 && apartFromCPU > 0.2 && apartFromMemory > 0.4,
                      "GPU \(g), CPU \(c), memory \(m)")
            } else {
                check("\(look)  the GPU's digits are plain ink like the CPU's and the memory's (the minimal look has no colour in its numbers)",
                      apartFromCPU < 0.15 && apartFromMemory < 0.15, "GPU \(g), CPU \(c), memory \(m)")
            }
        } else {
            check("\(look)  the readings' colours could be measured", false, "no ink")
        }
        if let g0 = gs[0].flatMap({ withGPU.inkColor(in: $0, threshold: 60) }), let g2 = gs[2].flatMap({ withGPU.inkColor(in: $0, threshold: 60) }) {
            check("\(look)  the GPU's graph is drawn in the same line colour as the CPU's and the memory's",
                  abs(g0.r - g2.r) + abs(g0.g - g2.g) + abs(g0.b - g2.b) < 0.08, "CPU line \(g0), GPU line \(g2)")
        } else {
            check("\(look)  the graphs' colours could be measured", false, "no ink")
        }

        // Three readings at 100 %: the smallest digits, still all inside.
        let fr = (0..<3).map { full.row("pulse.readout.\($0)") }
        let fullGaps = (0..<2).compactMap { i in fr[i].flatMap { a in fr[i + 1].map { b in CGRect(x: a.maxX, y: a.minY, width: b.minX - a.maxX, height: a.height).insetBy(dx: 1, dy: 0) } } }
        let fullInk = fullGaps.compactMap { full.inkBounds(in: $0, threshold: 40) }
        let fullSpills = spills(full.view, width: width)
        check("\(look)all three readings at 100 % still fit: three columns inside the panel, apart, nothing drawn between them or outside the panel",
              fr.allSatisfy { $0 != nil } && (fr[2]?.maxX ?? 999) <= width - inset.trailing + 0.5 && fullGaps.count == 2 && fullGaps.allSatisfy { $0.width >= gap - 2.5 }
                && fullInk.isEmpty && fullSpills == false,
              "readouts \(fr.map(describe)), gaps \(fullGaps.map(describe)), ink \(fullInk.map(describe)), spills \(String(describing: fullSpills))")

        // No GPU reading: the panel as it is today, with no empty slot and no dash; the same in a row too tight for the wider panel.
        check("\(look)a Mac that reports no GPU load shows CPU and memory alone: no third reading, no third graph, and the panel's pixels equal the two-reading panel's",
              none.row("pulse.readout.2") == nil && none.row("pulse.scope.2") == nil && none.row("pulse.readout.1") != nil
                && none.pixels().map { n in two.pixels().map { n.data == $0.data } ?? false } == true,
              "readouts \(describe(none.row("pulse.readout.2"))), graphs \(describe(none.row("pulse.scope.2")))")
        check("\(look)  at the old width (4 cells) with no GPU reading the panel's pixels equal the two-reading panel's",
              noneOld.row("pulse.readout.2") == nil && noneOld.pixels().map { n in twoOld.pixels().map { n.data == $0.data } ?? false } == true, "")
        check("\(look)  at the old width (4 cells) with a GPU reading there is no room: CPU and memory alone, exactly the old panel, nothing cut off",
              tight.row("pulse.readout.2") == nil && tight.row("pulse.scope.2") == nil && tight.row("pulse.readout.1") != nil
                && tight.pixels().map { n in twoOld.pixels().map { n.data == $0.data } ?? false } == true && spills(tight.view, width: oldWidth) == false, "")

        // The real notch at each Size: the panel takes its default width, the three readings stand inside it.
        let forcedScale = ProcessInfo.processInfo.environment["SCOUT_SCALE"] != nil
        let savedSize = UserDefaults.standard.object(forKey: Look.scaleKey)
        defer { if let savedSize { UserDefaults.standard.set(savedSize, forKey: Look.scaleKey) } else { UserDefaults.standard.removeObject(forKey: Look.scaleKey) } }
        for size in forcedScale ? [Look.size] : Look.Size.allCases {
            if !forcedScale { Pref.set(size.rawValue, Look.scaleKey) }
            let box = PanelProbe.Box()
            let rig = Rig(layout: [.pulse]) {
                AnyView(PulseWidgetView(style: .cards, metrics: [.cpu, .memory, .gpu], battery: battery).environment(\.pulseSampleOverride, reading)
                    .coordinateSpace(name: "dashpanel").onPreferenceChange(DashRowKey.self) { box.rows = $0 })
            }
            await settle(0.9)
            let f = size.factor
            let panelRect = rig.rect("panel.pulse")
            let r = (0..<3).map { box.rows["pulse.readout.\($0)"] }, g = (0..<3).map { box.rows["pulse.scope.\($0)"] }
            let inside = r.allSatisfy { $0 != nil } && g.allSatisfy { $0 != nil } && (r[2]?.maxX ?? 999) <= width - inset.trailing + 0.5 && near(r[0]?.minX, inset.leading)
            let ordered = zip(r, r.dropFirst()).allSatisfy { a, b in (b?.minX ?? 0) - (a?.maxX ?? 999) >= gap - 0.5 }
            check("\(look)at size \(size.title) (x\(f)) the panel is \(Int((width * f).rounded())) x \(Int((NookMetrics.widgetHeight * f).rounded())) pt on screen and holds the three readings and their graphs, apart, inside its insets",
                  near(panelRect?.width, width * f, 1.5) && near(panelRect?.height, NookMetrics.widgetHeight * f, 1.5) && inside && ordered && (g[2]?.height ?? 0) >= 24,
                  "panel \(describe(panelRect)), readouts \(r.map(describe)), graphs \(g.map(describe))")
            rig.close()
        }

        // The row around the panel: the extra cells come only out of room the row has to spare, so no widget is pushed out or hidden, and a
        // row that was tight before is laid out exactly as it was (the panel keeps four cells and shows CPU and memory alone).
        func layout(_ live: NookLive, _ islandWidth: CGFloat) -> (rows: [[NookItem]], hidden: Int, spans: [NookItem: Int])? {
            let store = NookStore(persist: false, layout: [.agents, .askAI, .pulse, .today])
            store.tabIDs = { [] }
            store.liveOverride = live
            let grid = store.rows(in: islandWidth - 52, maxRows: NookStore.maxRows)
            guard let first = grid.rows.first else { return nil }
            return (grid.rows, grid.hidden, store.spans(for: first, width: islandWidth - 52))
        }
        let defaultRow = NookStore(persist: false, layout: [.agents, .askAI, .pulse, .today])
        defaultRow.tabIDs = { [] }
        defaultRow.liveOverride = NookLive(playing: false, agents: 2)
        let cells = defaultRow.sizingSpans.reduce(0, +), items = defaultRow.sizingSpans.count
        let rowWidth = CGFloat(cells) * NookMetrics.cell + CGFloat(items - 1) * NookMetrics.spacing + 2 * (12 + 14)
        let calm = layout(NookLive(playing: false, agents: 2), min(rowWidth, 1040))
        check("\(look)the default dashboard (Agents, Ask AI, CPU & Memory, Today) is \(Int(rowWidth)) pt wide, inside the default 1040 pt, on one row with every panel shown, the Pulse panel \(span) cells and the Agents panel 4",
              rowWidth <= 1040 && calm?.rows.count == 1 && calm?.rows.first?.count == 4 && calm?.hidden == 0
                && calm?.spans[.panel(.pulse)] == span && calm?.spans[.panel(.agents)] == 4 && calm?.spans[.panel(.askAI)] == 4 && calm?.spans[.panel(.today)] == 4,
              "width \(rowWidth), rows \(String(describing: calm?.rows.map { $0.map(\.id) })), spans \(String(describing: calm?.spans.map { "\($0.key.id) \($0.value)" }))")
        let music = layout(NookLive(playing: true, agents: 2), 1040)
        check("\(look)  with music playing at 1040 pt every panel is still shown on one row, laid out as before the GPU reading: CPU & Memory 4 cells, the Agents panel 3",
              music?.rows.count == 1 && music?.rows.first?.count == 5 && music?.hidden == 0 && music?.spans[.panel(.pulse)] == 4 && music?.spans[.panel(.agents)] == 3,
              "rows \(String(describing: music?.rows.map { $0.map(\.id) })), spans \(String(describing: music?.spans.map { "\($0.key.id) \($0.value)" }))")
        let narrow = layout(NookLive(playing: false, agents: 2), 680)
        check("\(look)  at the narrowest notch (680 pt) the rows are as they were (Agents, Ask AI, CPU & Memory, then Today below), CPU & Memory 4 cells and the Agents panel keeps its 4",
              narrow?.rows.count == 2 && narrow?.rows.first?.map(\.id) == ["agents", "askAI", "pulse"] && narrow?.rows.last?.map(\.id) == ["today"] && narrow?.hidden == 0
                && narrow?.spans[.panel(.pulse)] == 4 && narrow?.spans[.panel(.agents)] == 4,
              "rows \(String(describing: narrow?.rows.map { $0.map(\.id) })), spans \(String(describing: narrow?.spans.map { "\($0.key.id) \($0.value)" }))")
    }

    private static func finish(_ lines: [String], _ failed: Int, out file: URL) {
        var out = lines
        out.append("dash90 selftest done: \(failed == 0 ? "all passed" : "\(failed) FAILED")")
        for line in out { print(line) }
        fflush(stdout)
        try? out.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}
