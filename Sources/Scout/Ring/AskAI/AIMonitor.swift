import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI

// Ask AI "Monitor": while it is on, every question takes a fresh picture of the screen the owner is working on and
// sends it along, like a monitor device that watches next to the chat. Scout's own windows (the notch, the Ask AI panel,
// the ring, cards) are left out of the picture. One setting, `ai.monitor`, shared by the notch, the panel and Settings.
//
// ScreenCaptureKit in both editions (it works in the sandbox with the Screen Recording permission). Scripted runs
// never capture: they attach a drawn sample screen, so the whole flow can be seen without touching the real screen.

/// Why a question went out without its picture.
enum AIMonitorNote: Equatable {
    case noAccess
    case failed

    var text: String {
        switch self {
        case .noAccess: String(localized: "Scout couldn't see your screen, so that question went without a picture. Allow Scout under Screen Recording.")
        case .failed: String(localized: "Scout couldn't take the picture this time, so that question went without it.")
        }
    }
}

@MainActor
enum AIMonitor {
    nonisolated static let key = "ai.monitor"

    /// Longest side of the picture the model gets.
    nonisolated static let longEdge: CGFloat = 1568
    /// A picture that is not ready after this long is dropped: sending is never held up.
    nonisolated static let patience: Double = 5

    enum Outcome: Sendable {
        case picture(String)
        case noAccess
        case failed
    }

    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    /// The chip and the Settings switch. Turning it on asks macOS for Screen Recording once (the owner just asked for it).
    static func setOn(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
        AIChatStore.shared.monitorNote = nil
        if on, !ScoutRuntime.isScripted, !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
    }

    static func toggle() { setOn(!isOn) }

    /// Monitor is OFF by default:
    /// it starts off at every launch, and turning it on lasts until the notch closes.
    private static var offWhenClosed: AnyCancellable?

    static func startOffByDefault() {
        guard offWhenClosed == nil else { return }
        UserDefaults.standard.set(false, forKey: key)
        offWhenClosed = NotchNavigator.shared.$isOpen.removeDuplicates().dropFirst().sink { open in
            MainActor.assumeIsolated { if !open, isOn { UserDefaults.standard.set(false, forKey: key) } }
        }
    }

    // MARK: Taking the picture

    /// A fresh picture of the screen being worked on, saved like a picked picture (file name with the screen prefix).
    /// Never throws and never waits longer than `patience`.
    static func capture() async -> Outcome {
        if ScoutRuntime.isScripted {
            return sampleScreenFile().map { .picture($0) } ?? .failed
        }
        let display = targetDisplayID()
        let pid = getpid()
        let bundle = Bundle.main.bundleIdentifier
        return await withCheckedContinuation { continuation in
            let gate = Gate(continuation)
            Task { gate.finish(await shoot(display: display, ownPID: pid, ownBundle: bundle)) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(patience * 1_000_000_000))
                gate.finish(.failed)
            }
        }
    }

    /// Resumes the continuation once: the picture or the timeout, whichever comes first.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Outcome, Never>?
        init(_ continuation: CheckedContinuation<Outcome, Never>) { self.continuation = continuation }

        func finish(_ outcome: Outcome) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: outcome)
        }
    }

    nonisolated private static func shoot(display wanted: CGDirectDisplayID, ownPID: pid_t, ownBundle: String?) async -> Outcome {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == wanted }) ?? content.displays.first else { return .failed }
            let filter = makeFilter(content: content, display: display, ownPID: ownPID, ownBundle: ownBundle)
            let config = SCStreamConfiguration()
            // The system scales the picture to this size: no big image is built and cut down afterwards.
            let native = max(1, CGFloat(filter.pointPixelScale))
            let fit = min(native, longEdge / CGFloat(max(1, max(display.width, display.height))))
            config.width = max(1, Int((CGFloat(display.width) * fit).rounded()))
            config.height = max(1, Int((CGFloat(display.height) * fit).rounded()))
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let name = AIImages.store(cgImage: image, prefix: AIImages.screenPrefix) else { return .failed }
            return .picture(name)
        } catch {
            let declined = (error as? SCStreamError)?.code == .userDeclined
            return declined || !CGPreflightScreenCaptureAccess() ? .noAccess : .failed
        }
    }

    /// The whole display, with every window of Scout's own application left out.
    nonisolated static func makeFilter(content: SCShareableContent, display: SCDisplay, ownPID: pid_t, ownBundle: String?) -> SCContentFilter {
        SCContentFilter(display: display, excludingApplications: ownApplications(in: content, ownPID: ownPID, ownBundle: ownBundle), exceptingWindows: [])
    }

    /// The running applications of the shareable content that are Scout.
    nonisolated static func ownApplications(in content: SCShareableContent, ownPID: pid_t, ownBundle: String?) -> [SCRunningApplication] {
        content.applications.filter { isOwn(bundleID: $0.bundleIdentifier, pid: $0.processID, ownPID: ownPID, ownBundle: ownBundle) }
    }

    /// Is this running application Scout (this process, or any copy with Scout's bundle identifier)?
    nonisolated static func isOwn(bundleID: String?, pid: pid_t, ownPID: pid_t, ownBundle: String?) -> Bool {
        if pid == ownPID { return true }
        guard let ownBundle, !ownBundle.isEmpty else { return false }
        return bundleID == ownBundle
    }

    // MARK: Which display

    struct WindowSample {
        var pid: pid_t
        var layer: Int
        var alpha: Double
        /// Quartz coordinates: origin top-left of the main display, y down.
        var bounds: CGRect
    }

    struct DisplaySample {
        var id: CGDirectDisplayID
        var bounds: CGRect
    }

    /// The display the owner is working on: where the frontmost ordinary window of another app sits (the notch and the
    /// panel never take the keyboard from it); with no such window, the display under the pointer.
    /// `windows` come front to back. Pure, so it can be checked without a screen.
    nonisolated static func pickDisplay(windows: [WindowSample], displays: [DisplaySample], pointer: CGPoint, ownPID: pid_t) -> CGDirectDisplayID? {
        func display(containing point: CGPoint) -> DisplaySample? { displays.first { $0.bounds.contains(point) } }
        for w in windows where w.layer == 0 && w.alpha > 0.01 && w.pid != ownPID && w.bounds.width >= 120 && w.bounds.height >= 80 {
            let best = displays.max { $0.bounds.intersection(w.bounds).area < $1.bounds.intersection(w.bounds).area }
            if let best, best.bounds.intersection(w.bounds).area > 0 { return best.id }
        }
        return (display(containing: pointer) ?? displays.first)?.id
    }

    private static func targetDisplayID() -> CGDirectDisplayID {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let displays = ids.prefix(Int(count)).map { DisplaySample(id: $0, bounds: CGDisplayBounds($0)) }
        var windows: [WindowSample] = []
        let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for w in info {
            guard let dict = w[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            windows.append(WindowSample(pid: (w[kCGWindowOwnerPID as String] as? Int32) ?? 0, layer: (w[kCGWindowLayer as String] as? Int) ?? 0,
                                        alpha: (w[kCGWindowAlpha as String] as? Double) ?? 1, bounds: bounds))
        }
        let mouse = NSEvent.mouseLocation
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let pointer = CGPoint(x: mouse.x, y: mainHeight - mouse.y)
        return pickDisplay(windows: windows, displays: displays, pointer: pointer, ownPID: getpid()) ?? CGMainDisplayID()
    }

    // MARK: Samples (scripted runs and the gallery: never the real screen)

    /// A drawn stand-in for a screen: a desktop, a menu bar and a window with an error in it.
    static func sampleScreen(size: CGSize = CGSize(width: 1568, height: 980)) -> CGImage? {
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(calibratedRed: 0.17, green: 0.24, blue: 0.52, alpha: 1), NSColor(calibratedRed: 0.55, green: 0.25, blue: 0.5, alpha: 1)])?
                .draw(in: rect, angle: -30)
            // Menu bar
            NSColor.black.withAlphaComponent(0.35).setFill()
            CGRect(x: 0, y: rect.height - 30, width: rect.width, height: 30).fill()
            let bar: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white]
            ("Xcode   File   Edit   View   Product" as NSString).draw(at: CGPoint(x: 70, y: rect.height - 25), withAttributes: bar)
            ("Fri 15 Nov  10:41" as NSString).draw(at: CGPoint(x: rect.width - 190, y: rect.height - 25), withAttributes: bar)
            // The window
            let window = CGRect(x: 170, y: 130, width: rect.width - 340, height: rect.height - 260)
            NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
            NSBezierPath(roundedRect: window, xRadius: 14, yRadius: 14).fill()
            NSColor(calibratedWhite: 0.9, alpha: 1).setFill()
            CGRect(x: window.minX, y: window.maxY - 44, width: window.width, height: 44).fill()
            for (i, color) in [NSColor.systemRed, NSColor.systemYellow, NSColor.systemGreen].enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: CGRect(x: window.minX + 18 + CGFloat(i) * 24, y: window.maxY - 30, width: 14, height: 14)).fill()
            }
            let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.darkGray]
            ("Build failed — Lisbon.xcodeproj" as NSString).draw(at: CGPoint(x: window.midX - 120, y: window.maxY - 33), withAttributes: title)
            let code: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 18, weight: .regular), .foregroundColor: NSColor(calibratedWhite: 0.25, alpha: 1)]
            let lines = ["func plan(day: Int) -> [Stop] {", "    let stops = Route.default.stops", "    return stops.filter { $0.open(on: day) }", "}"]
            for (i, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: window.minX + 40, y: window.maxY - 100 - CGFloat(i) * 30), withAttributes: code)
            }
            NSColor.systemRed.withAlphaComponent(0.14).setFill()
            CGRect(x: window.minX + 24, y: window.maxY - 290, width: window.width - 48, height: 40).fill()
            let error: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 18, weight: .medium), .foregroundColor: NSColor.systemRed]
            ("error: value of type 'Route' has no member 'default'" as NSString).draw(at: CGPoint(x: window.minX + 40, y: window.maxY - 279), withAttributes: error)
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static func sampleScreenFile() -> String? {
        sampleScreen().flatMap { AIImages.store(cgImage: $0, prefix: AIImages.screenPrefix) }
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
