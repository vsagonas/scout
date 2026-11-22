import AppKit
import Darwin

/// `scout://island.selftest.settings?out=<file>` (headless): the new settings: the three stored choices and their defaults, the one-time move from
/// the old switch (all four branches), which displays get a notch (kind by shape by mode), what makes the panels rebuild, and the display report
/// (its text, that nothing personal is in it, and the headless command that writes it). Hand-made facts only; the settings it writes are put back.
@MainActor
enum IslandSettingsSelfTest {
    static func register() {
        DisplayReport.register()   // scout://display.report?out=<file>, available in a headless run too
        SuiteCheck.register("island.selftest.settings", suite: "island settings") { check in
            let kept = saved()
            defer { restore(kept) }
            storedChoices(check)
            migration(check)
            predicate(check)
            signature(check)
            report(check)
            command(check)
        }
    }

    // MARK: The settings, put back at the end

    private static let keys = ["notch.cutout", "notch.shape", "notch.agentStyle", "notch.screens", "notch.virtual"]

    private static func saved() -> [String: Any] {
        var kept: [String: Any] = [:]
        for key in keys { if let v = UserDefaults.standard.object(forKey: key) { kept[key] = v } }
        return kept
    }

    private static func restore(_ kept: [String: Any]) {
        for key in keys {
            if let v = kept[key] { UserDefaults.standard.set(v, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    // MARK: The three stored choices

    private static func storedChoices(_ check: SuiteCheck) {
        let d = UserDefaults.standard
        for key in keys { d.removeObject(forKey: key) }
        check("unset: the override is Automatic, the shape is the tab (as before), the agent style is faces",
              NotchPrefs.cutoutOverride == .automatic && NotchPrefs.noneShape == .tab && NotchPrefs.agentStyle == .faces)
        d.set("pill", forKey: "notch.cutout"); d.set("island", forKey: "notch.shape"); d.set("bubbles", forKey: "notch.agentStyle")
        check("the stored words are read back: pill, island, bubbles", NotchPrefs.cutoutOverride == .pill && NotchPrefs.noneShape == .island && NotchPrefs.agentStyle == .bubbles)
        d.set("notch", forKey: "notch.cutout"); d.set("nothing", forKey: "notch.shape")
        check("notch and nothing are read back (the shape's word for the tab is \"notch\")", NotchPrefs.cutoutOverride == .notch && NotchPrefs.noneShape == .nothing)
        d.set("none", forKey: "notch.cutout"); d.set("notch", forKey: "notch.shape")
        check("none is read back, and the shape word \"notch\" is the tab", NotchPrefs.cutoutOverride == .none && NotchPrefs.noneShape == .tab)
        d.set("sideways", forKey: "notch.cutout"); d.set("sideways", forKey: "notch.shape"); d.set("sideways", forKey: "notch.agentStyle")
        check("a word that is no choice falls back to the defaults", NotchPrefs.cutoutOverride == .automatic && NotchPrefs.noneShape == .tab && NotchPrefs.agentStyle == .faces)
        for key in keys { d.removeObject(forKey: key) }
        check("every choice has a title, and the titles of each picker differ",
              Set(CutoutOverride.allCases.map(\.title)).count == 4 && Set(NoneShape.allCases.map(\.title)).count == 3 && Set(AgentWingStyle.allCases.map(\.title)).count == 2
              && !(CutoutOverride.allCases.map(\.title) + NoneShape.allCases.map(\.title) + AgentWingStyle.allCases.map(\.title)).contains(""))
        check("the screen mode that leaves out displays without a cutout is called that", NotchScreenMode.notched.rawValue == "notched")
    }

    // MARK: The one-time move

    private static func migration(_ check: SuiteCheck) {
        typealias Row = (name: String, stored: String?, usedBefore: Bool, virtual: Bool?, expected: NoneShape?)
        let rows: [Row] = [
            ("already set to the island: kept", "island", false, nil, nil),
            ("already set to nothing, used before, the old switch on: kept", "nothing", true, true, nil),
            ("already set to the tab, a new install: kept", "notch", false, nil, nil),
            ("used before, no old switch written: the tab (the switch was on by default)", nil, true, nil, .tab),
            ("used before, the old switch on: the tab", nil, true, true, .tab),
            ("used before, the old switch off: nothing", nil, true, false, .nothing),
            ("not used before but the old switch exists, on: the tab", nil, false, true, .tab),
            ("not used before but the old switch exists, off: nothing", nil, false, false, .nothing),
            ("a new install: the island", nil, false, nil, .island),
            ("a stored word that is no shape counts as unset (used before, switch off): nothing", "sideways", true, false, .nothing),
            ("a stored word that is no shape counts as unset (a new install): the island", "sideways", false, nil, .island),
        ]
        for row in rows {
            let got = NoneShapeMigration.decide(stored: row.stored, usedBefore: row.usedBefore, virtual: row.virtual)
            check("move: \(row.name)", got == row.expected, "\(String(describing: got))")
        }
        // A scripted run never moves anything: this run is scripted, so the call must leave the settings alone.
        let d = UserDefaults.standard
        d.removeObject(forKey: "notch.shape")
        NoneShapeMigration.runOnce(usedBefore: false)
        check("a scripted run never writes notch.shape", d.object(forKey: "notch.shape") == nil)
        realMove(check)
    }

    /// The real reading and writing of `runOnce`, on a temporary settings suite (never the owner's settings): each branch stores the word `decide`
    /// gives, a stored shape stays, and the word is the one `NotchPrefs.noneShape` reads back.
    private static func realMove(_ check: SuiteCheck) {
        let name = "com.vsag.Scout.autotest.islandmove"   // the same prefix the other suites' temporary settings use
        guard let suite = UserDefaults(suiteName: name) else { check("a temporary settings suite exists", false); return }
        suite.removePersistentDomain(forName: name)
        defer { suite.removePersistentDomain(forName: name) }
        func run(_ label: String, stored: String? = nil, virtual: Bool? = nil, usedBefore: Bool, expected: String?) {
            suite.removeObject(forKey: "notch.shape"); suite.removeObject(forKey: "notch.virtual")
            if let stored { suite.set(stored, forKey: "notch.shape") }
            if let virtual { suite.set(virtual, forKey: "notch.virtual") }
            NoneShapeMigration.runOnce(usedBefore: usedBefore, defaults: suite, forceReal: true)
            let got = suite.string(forKey: "notch.shape")
            check("real move on a temporary suite: \(label) stores \(expected ?? "nothing new")", got == expected, "stored \(String(describing: got))")
        }
        run("a new install", usedBefore: false, expected: "island")
        run("used before, no old switch", usedBefore: true, expected: "notch")
        run("used before, the old switch on", virtual: true, usedBefore: true, expected: "notch")
        run("used before, the old switch off", virtual: false, usedBefore: true, expected: "nothing")
        run("not used before, the old switch exists and is off", virtual: false, usedBefore: false, expected: "nothing")
        run("already set to the island (used before, the old switch off)", stored: "island", virtual: false, usedBefore: true, expected: "island")
        run("already set to nothing (a new install)", stored: "nothing", usedBefore: false, expected: "nothing")
        run("a stored word that is no shape (a new install)", stored: "sideways", usedBefore: false, expected: "island")
        // The stored word is what NotchPrefs reads back (the same key and words).
        let d = UserDefaults.standard
        let kept = d.object(forKey: "notch.shape")
        defer { if let kept { d.set(kept, forKey: "notch.shape") } else { d.removeObject(forKey: "notch.shape") } }
        run("a new install, read back", usedBefore: false, expected: "island")
        d.set(suite.string(forKey: "notch.shape"), forKey: "notch.shape")
        check("the word the move stores is the shape NotchPrefs reads back (island)", NotchPrefs.noneShape == .island)
        run("used before, read back", usedBefore: true, expected: "notch")
        d.set(suite.string(forKey: "notch.shape"), forKey: "notch.shape")
        check("the word the move stores for a used-before Mac is the tab", NotchPrefs.noneShape == .tab)
        // The guard of a scripted run holds for the temporary suite too, and the owner's own settings were never touched by any of it.
        suite.removeObject(forKey: "notch.shape")
        NoneShapeMigration.runOnce(usedBefore: false, defaults: suite)
        check("without forceReal a scripted run writes nothing, to a temporary suite either", suite.object(forKey: "notch.shape") == nil)
    }

    // MARK: Which displays get a notch

    private static func predicate(_ check: SuiteCheck) {
        // kind, shape, mode, expected. A notch or a pill always; no cutout only when the shape is not Nothing and the mode is not "only displays with a camera cutout".
        typealias Row = (CutoutKind, NoneShape, NotchScreenMode, Bool)
        let rows: [Row] = [
            (.notch, .island, .main, true), (.notch, .island, .all, true), (.notch, .island, .notched, true),
            (.notch, .tab, .main, true), (.notch, .tab, .all, true), (.notch, .tab, .notched, true),
            (.notch, .nothing, .main, true), (.notch, .nothing, .all, true), (.notch, .nothing, .notched, true),
            (.pill, .island, .main, true), (.pill, .island, .all, true), (.pill, .island, .notched, true),
            (.pill, .tab, .main, true), (.pill, .tab, .all, true), (.pill, .tab, .notched, true),
            (.pill, .nothing, .main, true), (.pill, .nothing, .all, true), (.pill, .nothing, .notched, true),
            (.none, .island, .main, true), (.none, .island, .all, true), (.none, .island, .notched, false),
            (.none, .tab, .main, true), (.none, .tab, .all, true), (.none, .tab, .notched, false),
            (.none, .nothing, .main, false), (.none, .nothing, .all, false), (.none, .nothing, .notched, false),
        ]
        var wrong: [String] = []
        for (kind, shape, mode, expected) in rows where NotchScreenPolicy.keeps(kind: kind, shape: shape, mode: mode) != expected {
            wrong.append("\(kind) \(shape) \(mode)")
        }
        check("the notch goes on a display: kind by shape by mode (\(rows.count) rows)", wrong.isEmpty, wrong.joined(separator: "; "))
        // Ask AI's "does the main screen have a notch" is the same predicate on the main screen's geometry, and the dashboard must open there: a pill
        // keeps its notch (it draws the bubbles) but cannot show Ask AI, so the floating window is used.
        let d = UserDefaults.standard
        var same = true
        if let main = NSScreen.screens.first {
            let geometry = NotchGeometry.make(for: main)
            for shape in NoneShape.allCases {
                for mode in NotchScreenMode.allCases {
                    d.set(shape.rawValue, forKey: "notch.shape"); d.set(mode.rawValue, forKey: "notch.screens")
                    if AskAIPlace.mainScreenHasNotch != (NotchScreenPolicy.keeps(kind: geometry.kind, shape: shape, mode: mode) && geometry.kind != .pill) { same = false }
                }
            }
        }
        check("Ask AI's main-screen check is the same predicate, and never true for a pill (every shape and mode on this Mac's main screen)", same)
        var pillWrong: [String] = []
        for shape in NoneShape.allCases {
            for mode in NotchScreenMode.allCases {
                if NotchScreenPolicy.holdsDashboard(geometry: .samplePill16, shape: shape, mode: mode) { pillWrong.append("pill \(shape) \(mode)") }
                if !NotchScreenPolicy.holdsDashboard(geometry: .sample16, shape: shape, mode: mode) { pillWrong.append("notch \(shape) \(mode)") }
                if NotchScreenPolicy.holdsDashboard(geometry: .sampleNone, shape: shape, mode: mode) != NotchScreenPolicy.keeps(kind: .none, shape: shape, mode: mode) { pillWrong.append("none \(shape) \(mode)") }
            }
        }
        check("the dashboard predicate: a pill never (all nine shape and mode pairs), a notch always, no cutout as the notch predicate says", pillWrong.isEmpty, pillWrong.joined(separator: "; "))
        askAIOnAPill(check)
    }

    /// Ask AI on a pill display: the notch is not available (its dashboard cannot open there), so Ask AI uses its window; a classic notch under the
    /// pointer still is. The shared manager gets test controllers that cover every screen (no panel is shown), and gets them taken away again.
    private static func askAIOnAPill(_ check: SuiteCheck) {
        let huge = CGRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000)   // holds the real pointer wherever it is
        func controller(_ g: NotchGeometry) -> NotchController { NotchController(geometry: g, screenFrame: huge, panelFrame: CGRect(x: -700, y: -360, width: 1400, height: 720), showsPanel: false) }
        let manager = NotchManager.shared
        let before = manager.controllers
        defer { manager.install(controllers: before) }
        manager.install(controllers: [controller(.samplePill16)])
        check("Ask AI: with the pointer on a pill display the notch is not available, so Ask AI opens its window", !AskAIPlace.notchAvailable)
        manager.install(controllers: [controller(.sample16)])
        check("Ask AI: with the pointer on a classic notch the notch is available (when Ask AI is on in the notch)", AskAIPlace.notchAvailable == AskAIPlace.enabledInNotch)
        manager.install(controllers: [controller(.sampleNone)])
        check("Ask AI: with the pointer on a drawn island the notch is available (when Ask AI is on in the notch)", AskAIPlace.notchAvailable == AskAIPlace.enabledInNotch)
        manager.install(controllers: [])
        check("Ask AI: with no notch at all it is not available", !AskAIPlace.notchAvailable)
    }

    // MARK: The signature

    private static func display(_ id: UInt32, _ width: CGFloat, _ height: CGFloat, safe: CGFloat = 0, housing: CGFloat? = nil, bar: CGFloat = 0,
                                builtIn: Bool = true, model: String? = nil) -> DisplayFacts {
        var f = DisplayFacts(displayID: id, frame: CGRect(x: 0, y: 0, width: width, height: height))
        f.visibleFrame = CGRect(x: 0, y: 0, width: width, height: height - bar)
        f.safeInsets = DisplayInsets(top: safe)
        if let housing {
            let aux = (width - housing) / 2
            f.auxLeft = CGRect(x: 0, y: height - 32, width: aux, height: 32)
            f.auxRight = CGRect(x: width - aux, y: height - 32, width: aux, height: 32)
        }
        f.menuBar = bar
        f.barThickness = 24
        f.isBuiltIn = builtIn
        f.modelID = model
        return f
    }

    private static func signature(_ check: SuiteCheck) {
        let laptop = display(1, 1728, 1117, safe: 32, housing: 185, bar: 37, model: "MacBookPro18,2")
        let external = display(2, 2560, 1440, bar: 24, builtIn: false)
        func sig(_ displays: [DisplayFacts], mode: NotchScreenMode = .all, override: CutoutOverride = .automatic, shape: NoneShape = .island, style: AgentWingStyle = .faces) -> String {
            NotchScreenPolicy.signature(displays: displays, mode: mode, override: override, noneShape: shape, agentStyle: style)
        }
        let base = sig([laptop, external])
        check("the signature is the same for the same inputs", sig([laptop, external]) == base)
        check("the signature changes with the override", sig([laptop, external], override: .pill) != base && sig([laptop, external], override: .none) != sig([laptop, external], override: .pill))
        check("the signature changes with the shape for displays without a cutout", sig([laptop, external], shape: .tab) != base && sig([laptop, external], shape: .nothing) != base)
        check("the signature changes with the agent style", sig([laptop, external], style: .bubbles) != base)
        check("the signature changes with the display mode", sig([laptop, external], mode: .main) != base && sig([laptop, external], mode: .notched) != base)
        var moved = laptop; moved.frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        check("the signature changes with a display's frame (another scaled mode)", sig([moved, external]) != base)
        var hidden = laptop; hidden.safeInsets = DisplayInsets(top: 0)
        check("the signature changes with a display's hidden top", sig([hidden, external]) != base)
        var wider = laptop; wider.auxLeft.size.width += 10
        check("the signature changes with an area beside the housing", sig([laptop, wider]) != sig([laptop, laptop]) && sig([wider, external]) != base)
        var touch = laptop; touch.isTouch = true
        check("the signature changes with touch, the model id and built-in", sig([touch, external]) != base && sig([display(1, 1728, 1117, safe: 32, housing: 185, bar: 37, model: "Mac17,10"), external]) != base
              && sig([laptop, display(2, 2560, 1440, bar: 24, builtIn: true)]) != base)
        var taller = external; taller.menuBar = 25; taller.visibleFrame.size.height -= 1
        check("the signature changes with the bar height of a display without a cutout (whole points)", sig([laptop, taller]) != base)
        var fractional = external; fractional.menuBar = 24.3
        check("a bar height that rounds to the same whole point leaves it alone", sig([laptop, fractional]) == base)
        var barOfNotch = laptop; barOfNotch.menuBar = 40
        check("the bar height of a display WITH a cutout is not part of it", sig([barOfNotch, external]) == base)
        var otherRim = laptop; otherRim.visibleFrame = CGRect(x: 0, y: 70, width: 1728, height: 1010); otherRim.backingScale = 1; otherRim.pixelSize = CGSize(width: 1, height: 1)
        check("the Dock, the backing scale and the pixel size are not part of it", sig([otherRim, external]) == base)
        check("the real call reads the connected displays and the stored choices", !NotchScreenPolicy.currentSignature().isEmpty)
    }

    // MARK: The report

    private static func report(_ check: SuiteCheck) {
        let laptop = display(1, 1728, 1117, safe: 32, housing: 185, bar: 37, model: "Mac17,10")
        var pillFacts = display(2, 1736, 1117, safe: 0, housing: 59, bar: 48, model: "Mac17,10")
        pillFacts.isTouch = true
        pillFacts.pixelSize = CGSize(width: 3472, height: 2234)
        let override = CutoutOverride.automatic, shape = NoneShape.island, style = AgentWingStyle.faces
        let entries = [laptop, pillFacts].enumerated().map { i, f in
            DisplayReport.Entry(facts: f, decision: NotchGeometry.make(facts: f, override: override, noneShape: shape, agentStyle: style), isMain: i == 0)
        }
        let text = DisplayReport.format(entries: entries, override: override, noneShape: shape, agentStyle: style, appVersion: "1.0.20 (1)", system: "Version 27.0")
        check("the report names the settings and the number of displays",
              text.contains("Camera cutout setting: automatic") && text.contains("On displays without a camera cutout: island") && text.contains("Agents beside the notch: faces")
              && text.contains("Displays: 2"))
        check("each display has its own section, the first marked main", text.contains("Display 1 (main)") && text.contains("Display 2\n"))
        for field in ["frame: ", "visible frame: ", "safe area insets: ", "area left of the housing: ", "area right of the housing: ", "housing between the areas: ",
                      "menu bar height: ", "backing scale: ", "pixels: ", "built in: ", "model id: ", "touch: ", "kind chosen: ", "housing chosen: ", "notes:"] {
            check("the report prints \"\(field.trimmingCharacters(in: .whitespaces))\" for every display", text.components(separatedBy: "  \(field)").count - 1 == 2, "\(text.components(separatedBy: "  \(field)").count - 1) times")
        }
        check("the report carries the numbers: the frame, the insets, an area, the pixels, the model, the touch, the housing chosen",
              text.contains("frame: x 0, y 0, w 1728, h 1117") && text.contains("safe area insets: top 32, left 0, bottom 0, right 0") && text.contains("area left of the housing: x 0, y 1085, w 771.5, h 32")
              && text.contains("pixels: 3472 x 2234") && text.contains("model id: Mac17,10") && text.contains("touch: yes") && text.contains("housing chosen: 58 x 31 pt, 8.5 pt below the top edge, strip 48 pt"))
        check("the report carries the notes, among them the contradiction of a listed model with a classic-looking housing",
              text.contains("CONTRADICTION") && text.contains("kind chosen: pill") && text.contains("notes:\n    - pill:"))
        check("a display without areas says so", DisplayReport.format(entries: [DisplayReport.Entry(facts: display(1, 1920, 1080, bar: 24, builtIn: false),
              decision: NotchGeometry.make(facts: display(1, 1920, 1080, bar: 24, builtIn: false), noneShape: .island), isMain: true)], override: .automatic, noneShape: .island,
              agentStyle: .faces, appVersion: "x", system: "y").contains("area left of the housing: none"))
        check("the report is the same text for the same facts", DisplayReport.format(entries: entries, override: override, noneShape: shape, agentStyle: style,
              appVersion: "1.0.20 (1)", system: "Version 27.0") == text)

        // Nothing personal: the real report of THIS Mac must not hold its owner's or computer's names, nor a display's name or serial.
        let real = DisplayReport.current()
        var personal: [(String, String)] = [("user name", NSUserName()), ("full user name", NSFullUserName()), ("home folder", NSHomeDirectory())]
        if let name = Host.current().localizedName { personal.append(("computer name", name)) }
        var host = [CChar](repeating: 0, count: 256)
        if gethostname(&host, host.count - 1) == 0 { personal.append(("host name", String(cString: host))) }
        for screen in NSScreen.screens { personal.append(("display name", screen.localizedName)) }
        let leaked = personal.filter { $0.1.count >= 4 && real.contains($0.1) }.map(\.0)
        check("nothing personal is in the report of this Mac (user, computer and display names, home folder: \(personal.count) strings searched)", leaked.isEmpty, leaked.joined(separator: ", "))
        check("the report of this Mac has one section for each connected display", real.components(separatedBy: "\nDisplay ").count - 1 == NSScreen.screens.count,
              "\(real.components(separatedBy: "\nDisplay ").count - 1) sections for \(NSScreen.screens.count) displays")
        let facts = NSScreen.screens.map { DisplayFacts.gather($0) }
        check("gathering reads every display without a failure: the frames match", zip(facts, NSScreen.screens).allSatisfy { $0.frame == $1.frame })
    }

    // MARK: The headless command

    private static func command(_ check: SuiteCheck) {
        let file = AppPaths.file("display-report-selftest.txt")   // the scripted runs' own folder
        try? FileManager.default.removeItem(at: file)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let url = URL(string: "scout://display.report?out=\(file.path)") else { check("the command address is valid", false); return }
        DebugCommands.run(url: url)
        let written = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        check("scout://display.report?out=<file> writes the report", written.hasPrefix("Scout display report\n") && written.contains("Display 1"), String(written.prefix(60)))
        try? FileManager.default.removeItem(at: file)
        DebugCommands.run(url: url, automation: false)
        check("the command runs in scripted runs only: outside automation the same link writes nothing", !FileManager.default.fileExists(atPath: file.path))
    }
}
