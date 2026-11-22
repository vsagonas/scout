import AppKit
import Darwin

// The display report: what the system says about every connected display and what Scout made of it, as plain text a person can copy and send
// (Settings › Notch › Copy display details, or `scout://display.report?out=<file>` in a scripted run). The new MacBook Pro's real values are
// unknown to us, so this is how they reach the people who correct the numbers. Nothing personal is ever in it: no display name, serial number,
// vendor or product id, no user or computer name. The model id (`hw.model`) is the one identifier it carries, because the detection needs it.

extension DisplayFacts {
    /// `hw.model` ("MacBookPro18,1"), or nil when the system would not say (that counts as "not on the list").
    static let hardwareModel: String? = {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        let text = String(cString: buffer)
        return text.isEmpty ? nil : text
    }()

    /// What the system says about one display now. Never prompts, never throws: every call that fails reads as unknown (nil, zero, false).
    @MainActor
    static func gather(_ screen: NSScreen) -> DisplayFacts {
        let id = screen.displayID
        let insets = screen.safeAreaInsets
        var facts = DisplayFacts(displayID: id, frame: screen.frame)
        facts.visibleFrame = screen.visibleFrame
        facts.safeInsets = DisplayInsets(top: insets.top, left: insets.left, bottom: insets.bottom, right: insets.right)
        facts.auxLeft = screen.auxiliaryTopLeftArea ?? .zero
        facts.auxRight = screen.auxiliaryTopRightArea ?? .zero
        facts.menuBar = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        facts.barThickness = NSStatusBar.system.thickness
        facts.backingScale = screen.backingScaleFactor
        if id != 0, let mode = CGDisplayCopyDisplayMode(id) { facts.pixelSize = CGSize(width: mode.pixelWidth, height: mode.pixelHeight) }
        facts.isBuiltIn = id != 0 && CGDisplayIsBuiltin(id) != 0
        facts.modelID = hardwareModel
        if #available(macOS 27.0, *) { facts.isTouch = screen.touchCapabilities.contains(.multiTouch) }
        return facts
    }
}

enum DisplayReport {
    /// One display of the report.
    struct Entry: Equatable {
        var facts: DisplayFacts
        var decision: DisplayDecision
        var isMain: Bool
    }

    /// The text of the report. Pure: the same facts give the same text.
    static func format(entries: [Entry], override: CutoutOverride, noneShape: NoneShape, agentStyle: AgentWingStyle, appVersion: String, system: String) -> String {
        var lines: [String] = []
        lines.append("Scout display report")
        lines.append("Scout \(appVersion), macOS \(system)")
        lines.append("Camera cutout setting: \(override.rawValue)")
        lines.append("On displays without a camera cutout: \(noneShape.rawValue)")
        lines.append("Agents beside the notch: \(agentStyle.rawValue)")
        lines.append("Displays: \(entries.count)")
        for (index, entry) in entries.enumerated() {
            let f = entry.facts
            let g = entry.decision.geometry
            lines.append("")
            lines.append("Display \(index + 1)" + (entry.isMain ? " (main)" : ""))
            lines.append("  frame: \(rect(f.frame))")
            lines.append("  visible frame: \(rect(f.visibleFrame))")
            lines.append("  safe area insets: top \(num(f.safeInsets.top)), left \(num(f.safeInsets.left)), bottom \(num(f.safeInsets.bottom)), right \(num(f.safeInsets.right))")
            lines.append("  area left of the housing: \(f.auxLeft.width > 0 ? rect(f.auxLeft) : "none")")
            lines.append("  area right of the housing: \(f.auxRight.width > 0 ? rect(f.auxRight) : "none")")
            lines.append("  housing between the areas: " + (f.hasAux ? "\(num(f.housingWidth)) pt wide, \(num((f.housingShare ?? 0) * 100, 1)) % of the width" : "not reported"))
            lines.append("  menu bar height: " + (f.menuBar > 0 ? "\(num(f.menuBar)) pt" : "none (hidden or unknown)") + ", status bar thickness \(num(f.barThickness)) pt")
            lines.append("  backing scale: \(num(f.backingScale))")
            lines.append("  pixels: " + (f.pixelSize.map { "\(Int($0.width)) x \(Int($0.height))" } ?? "unknown"))
            lines.append("  built in: \(f.isBuiltIn ? "yes" : "no")")
            lines.append("  model id: \(f.modelID ?? "unknown")")
            lines.append("  touch: \(f.isTouch ? "yes" : "no")")
            lines.append("  kind chosen: \(g.kind.rawValue)" + (g.kind == .none ? ", drawn as \(g.noneShape.rawValue)" : "") + (g.kind == .notch ? ", agents as \(g.agentStyle.rawValue)" : ""))
            lines.append("  housing chosen: \(num(g.size.width)) x \(num(g.size.height)) pt, \(num(g.topInset)) pt below the top edge, strip \(num(g.stripHeight)) pt")
            if entry.decision.notes.isEmpty {
                lines.append("  notes: none")
            } else {
                lines.append("  notes:")
                for note in entry.decision.notes { lines.append("    - \(note)") }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The report of the displays connected now.
    @MainActor
    static func current() -> String {
        let override = NotchPrefs.cutoutOverride, shape = NotchPrefs.noneShape, style = NotchPrefs.agentStyle
        let entries = NSScreen.screens.enumerated().map { index, screen -> Entry in
            let facts = DisplayFacts.gather(screen)
            return Entry(facts: facts, decision: NotchGeometry.make(facts: facts, override: override, noneShape: shape, agentStyle: style), isMain: index == 0)
        }
        return format(entries: entries, override: override, noneShape: shape, agentStyle: style,
                      appVersion: "\(ScoutRuntime.version) (\(ScoutRuntime.build))", system: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    /// Settings › Notch › Copy display details. A scripted run never touches the real clipboard.
    @MainActor
    @discardableResult
    static func copyToClipboard() -> Bool {
        guard !ScoutRuntime.isScripted else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(current(), forType: .string)
    }

    /// `scout://display.report?out=<file>` (scripted runs only): writes the report of this Mac's displays. It reads the screens and nothing else, so
    /// a tester on a Mac we have never seen can run it from a build started with `--automation --headless --run`.
    @MainActor
    static func register() {
        DebugCommands.register("display.report") { params in
            guard ScoutRuntime.isAutomation else { return }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("display-report.txt")
            try? current().write(to: out, atomically: true, encoding: .utf8)
        }
    }

    private static func num(_ value: CGFloat, _ digits: Int = 2) -> String {
        var text = String(format: "%.\(digits)f", Double(value))
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }

    private static func rect(_ r: CGRect) -> String {
        "x \(num(r.origin.x)), y \(num(r.origin.y)), w \(num(r.width)), h \(num(r.height))"
    }
}
