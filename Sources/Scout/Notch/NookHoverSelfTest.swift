import AppKit
import SwiftUI

/// `scout://nook.selftest.hover?out=<file>` (headless, its own build: `--automation --headless --run …`, then `kill $PID`).
/// Every dashboard panel lights up under the pointer:
/// each widget kind, alone on the open island, is drawn twice without the pointer and once with it, in 8-bit and minimal, dark and light.
/// With the pointer, a large share of the island must change; between the two pictures without it, only what moves by itself may change.
/// A sheet per look goes next to the report (`<out>-<look>.png`: left without the pointer, right with it). The two settings are put back.
@MainActor
enum NookHoverSelfTest {
    static func register() {
        DebugCommands.register("nook.selftest.hover") { params in
            guard ScoutRuntime.isAutomation else { return }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("nook-hover-selftest.txt")
            Task { @MainActor in await run(out: out) }
        }
    }

    static let size = CGSize(width: 1000, height: 260)

    private static func render(_ kind: WidgetKind, hover: Bool, dark: Bool) async -> NSBitmapImageRep? {
        let root = NotchScene(size: size, open: true, layout: [kind])
            .environment(\.nookPreviewHover, hover ? NookItem.panel(kind).id : nil)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 300_000_000)
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        defer { window.orderOut(nil) }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    /// The share of pixels (every second one) whose brightness moved by more than about 4 of 255 between two pictures.
    private static func changed(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bitsPerSample == 8, b.bitsPerSample == 8, !a.isPlanar, !b.isPlanar,
              let pa = a.bitmapData, let pb = b.bitmapData else { return -1 }
        let sa = a.samplesPerPixel, sb = b.samplesPerPixel, ra = a.bytesPerRow, rb = b.bytesPerRow
        var moved = 0
        var total = 0
        for y in stride(from: 0, to: a.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: a.pixelsWide, by: 2) {
                let i = y * ra + x * sa
                let j = y * rb + x * sb
                let la = Int(pa[i]) * 3 + Int(pa[i + 1]) * 6 + Int(pa[i + 2])
                let lb = Int(pb[j]) * 3 + Int(pb[j + 1]) * 6 + Int(pb[j + 2])
                if abs(la - lb) > 40 { moved += 1 }
                total += 1
            }
        }
        return total == 0 ? -1 : Double(moved) / Double(total)
    }

    private static func sheet(_ rows: [(off: NSBitmapImageRep, on: NSBitmapImageRep)], to file: URL) {
        let half = CGSize(width: size.width / 2, height: size.height / 2)
        let image = NSImage(size: CGSize(width: size.width, height: half.height * CGFloat(rows.count)))
        image.lockFocus()
        for (i, row) in rows.enumerated() {
            let y = image.size.height - CGFloat(i + 1) * half.height
            row.off.draw(in: CGRect(x: 0, y: y, width: half.width, height: half.height))
            row.on.draw(in: CGRect(x: half.width, y: y, width: half.width, height: half.height))
        }
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: file)
        }
    }

    static func run(out: URL) async {
        var lines: [String] = []
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failed += 1 }
            lines.append("nook hover selftest \(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        }
        // No live panels, like the other dashboard checks: the clock must not decide what the island shows. A panel joins it for the
        // 40 minutes before the sample meeting (1 PM), which changed the pictures and failed this check between about 12:20 and 13:00 (2026-11-17).
        LivePanelLookup.override = []
        defer { LivePanelLookup.override = nil }
        let keys = [Retro.styleKey, Look.presetKey]
        var kept: [String: Any] = [:]
        for key in keys { if let v = UserDefaults.standard.object(forKey: key) { kept[key] = v } }
        defer {
            for key in keys {
                if let v = kept[key] { UserDefaults.standard.set(v, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }

        check("every panel kind says it lights up under the pointer", WidgetKind.allCases.allSatisfy { NookItem.panel($0).highlightsOnHover }
              && NookItem.nowPlaying.highlightsOnHover && NookItem.tab("x").highlightsOnHover)
        for (eightBit, light) in [(true, false), (false, false), (true, true), (false, true)] {
            Pref.set(eightBit, Retro.styleKey)
            Pref.set((light ? Look.Preset.light : Look.Preset.dark).rawValue, Look.presetKey)
            let look = "\(eightBit ? "8-bit" : "minimal") \(light ? "light" : "dark")"
            var rows: [(off: NSBitmapImageRep, on: NSBitmapImageRep)] = []
            var bad: [String] = []
            for kind in WidgetKind.allCases {
                guard let off = await render(kind, hover: false, dark: !light), let again = await render(kind, hover: false, dark: !light),
                      let on = await render(kind, hover: true, dark: !light) else {
                    bad.append("\(kind.rawValue) (no picture)")
                    continue
                }
                rows.append((off, on))
                let lit = changed(off, on)
                let noise = changed(off, again)
                let ok = lit >= 0.05 && lit > noise * 3 + 0.01
                if !ok { bad.append(String(format: "%@ lit %.3f noise %.3f", kind.rawValue, lit, noise)) }
                lines.append(String(format: "nook hover selftest      %@ %@: lit %.3f, by itself %.3f", look, kind.rawValue, lit, noise))
            }
            check("\(look): every one of the \(WidgetKind.allCases.count) panels gets the hover background", bad.isEmpty, bad.joined(separator: "; "))
            sheet(rows, to: out.deletingPathExtension().appendingPathExtension("\(eightBit ? "8bit" : "minimal")-\(light ? "light" : "dark").png"))
        }
        var text = lines
        text.append("nook hover selftest done: \(failed == 0 ? "all passed" : "\(failed) FAILED")")
        for line in text { print(line) }
        fflush(stdout)
        try? text.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
    }
}
