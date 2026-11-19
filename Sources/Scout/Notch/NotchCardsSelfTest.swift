import AppKit
import SwiftUI

/// Self-check of the cards under the notch in an OFFSCREEN panel (nothing shows, the pointer never moves): a card hangs from the island as
/// ONE shape and follows its width and position LIVE (the owner, 2026-11-16: a battery card that came while the notch was open kept its
/// wide open-notch size and its place after the notch closed). Run headless, as its own build:
///   build/Scout.app/Contents/MacOS/Scout --automation --headless --run "scout://notch.selftest.cards?out=/tmp/cards.txt" & PID=$!
/// then wait for the file and `kill $PID`.
///
/// The rule it holds the notch to: the card's middle is the island's middle; its width is the island's body (the island's width minus the
/// two flares, 6 pt each); the island is never narrower than the card (it grows to it); the camera gap stays over the camera; open, the card
/// hangs centred under the open island and is 480 pt at most. After every change (open, close, a message appearing in a wing, faces
/// added, a second card) the numbers are read again once the spring has settled.
@MainActor
enum NotchCardsSelfTest {
    /// Called from `HeadlessChecks.registerAll()`.
    static func register() {
        DebugCommands.register("notch.selftest.cards") { params in
            guard ScoutRuntime.isAutomation else { return }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("notch-cards-selftest.txt")
            Task { @MainActor in await run(out: out) }
        }
    }

    private static let flare: CGFloat = 6
    private static let panelWidth: CGFloat = 1120

    @MainActor private final class Rig {
        let size = CGSize(width: panelWidth, height: 520)
        let model: NotchScreenModel
        let navigator = NotchNavigator()
        let nook = NookStore(persist: false, layout: [.agents, .askAI])
        let center = LiveActivityCenter()
        let panel: NotchPanel
        var taps = 0

        init(open: Bool) {
            model = NotchScreenModel(geometry: .sample16, panelSize: size)
            model.isOpen = open
            navigator.isOpen = open
            nook.liveOverride = NookLive(playing: false, agents: 0)
            nook.tabIDs = { [] }
            panel = NotchPanel(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.navigatorOverride = navigator
            panel.isReleasedWhenClosed = false
            let root = NotchRootView(model: model, center: center, navigator: navigator, nook: nook, styleOverride: .classic)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = CGRect(origin: .zero, size: size)
            panel.contentView = hosting
            panel.orderFrontRegardless()
        }

        func setOpen(_ open: Bool) {
            model.isOpen = open
            navigator.isOpen = open
        }

        /// The cards' frames in the panel, top to bottom.
        var cards: [CGRect] { model.cardRects.sorted { $0.minY < $1.minY } }

        func click(_ p: CGPoint) {
            let location = CGPoint(x: p.x, y: size.height - p.y)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                     pressure: type == .leftMouseUp ? 0 : 1) else { return }
                panel.sendEvent(event)
            }
        }

        func close() {
            panel.contentView = nil
            panel.orderOut(nil)
        }
    }

    /// An activity with fixed-size stand-ins for the wings' content (a face row on the left, a message on the right).
    private static func wings(left: CGFloat, right: CGFloat) -> LiveActivity {
        LiveActivity(id: "cards.test", kind: .agent, expiresAfter: nil, onTap: nil, leading: {
            if left > 0 { Color.green.frame(width: left, height: 18) } else { EmptyView() }
        }, trailing: {
            if right > 0 { Color.orange.frame(width: right, height: 18) } else { EmptyView() }
        })
    }

    private static func battery(_ id: String = "battery.low", onTap: (() -> Void)? = nil) -> NotchCard {
        NotchCard(id: id, kind: .battery, duration: 600, onTap: onTap) {
            DemoCardContent(symbol: "battery.25percent", title: "Battery is low", subtitle: "19 % left. Time to plug in.")
        }
    }

    private static func settle(_ seconds: Double = 1.4) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func run(out: URL) async {
        var lines: [String] = []
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failed += 1 }
            lines.append("cards selftest \(ok ? "ok  " : "FAIL") \(name)\(ok || detail.isEmpty ? "" : "  (\(detail))")")
        }
        func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 1.5) -> Bool { abs(a - b) <= tolerance }
        func f(_ r: CGRect) -> String { String(format: "x %.1f..%.1f y %.1f..%.1f", r.minX, r.maxX, r.minY, r.maxY) }

        LivePanelLookup.override = []
        defer { LivePanelLookup.override = nil }
        let ws = Look.wingScale
        let mid = panelWidth / 2
        let hardware = NotchGeometry.sample16.size.width
        // What a wing of `content` points measures (content at the wing size, 8 pt from the outer edge, 6 pt from the camera), 0 when empty.
        func wing(_ content: CGFloat) -> CGFloat { content > 0 ? content * ws + 14 : 0 }

        /// The closed island with a card: lined up by the rule, and its camera gap over the camera.
        func closedRule(_ rig: Rig, left: CGFloat, right: CGFloat, _ what: String) {
            let island = rig.model.islandRect
            guard let card = rig.cards.first else { check("\(what): a card is there", false, "no card rect"); return }
            let body = island.width - 2 * flare
            check("\(what): the card's middle is the island's middle", near(card.midX, island.midX), "card \(f(card)) island \(f(island))")
            check("\(what): the card is as wide as the island's body", near(card.width, body), "card \(f(card)) island \(f(island))")
            check("\(what): the island is at least as wide as the card needs (the notch grew to it)", card.width >= 320 * ws - 1.5, "card \(f(card))")
            check("\(what): the card hangs right under the island", near(card.minY, island.maxY), "card \(f(card)) island \(f(island))")
            let base = hardware + wing(left) + wing(right)
            let expectedBody = max(base, 320 * ws)
            check("\(what): the width is the wings' own, or the card's when that is more", near(body, expectedBody, 2.5), "body \(body) expected \(expectedBody)")
            // The camera gap: the island's middle is (right wing - left wing) / 2 from the panel's middle, growth being spread alike.
            check("\(what): the camera gap stays over the camera", near(island.midX, mid + (wing(right) - wing(left)) / 2, 2.5), "island \(f(island)) expected middle \(mid + (wing(right) - wing(left)) / 2)")
        }

        func openRule(_ rig: Rig, _ what: String) {
            let island = rig.model.islandRect
            guard let card = rig.cards.first else { check("\(what): a card is there", false, "no card rect"); return }
            check("\(what): the open island is centred", near(island.midX, mid), "island \(f(island))")
            check("\(what): the card is centred under it", near(card.midX, island.midX), "card \(f(card)) island \(f(island))")
            check("\(what): the card is 320 to 480 pt (as drawn: times the size factor) and never wider than the island", card.width >= 320 * ws - 1.5 && card.width <= 480 * ws + 1.5 && card.width <= island.width + 1.5, "card \(f(card)) island \(f(island))")
            check("\(what): the card hangs right under the island", near(card.minY, island.maxY), "card \(f(card)) island \(f(island))")
        }

        // 1. Closed, lopsided: only a left wing, a card comes, goes, and the notch opens and closes with it up.
        let a = Rig(open: false)
        defer { a.close() }
        a.center.show(wings(left: 90, right: 0))
        await settle(0.9)
        a.center.present(battery())
        await settle()
        closedRule(a, left: 90, right: 0, "closed, left wing only")
        check("closed: the island is lopsided as planned (the card sits left of the camera's middle)", a.model.islandRect.midX < mid - 20, "island \(f(a.model.islandRect))")

        a.setOpen(true)
        await settle()
        openRule(a, "closed → open")
        a.setOpen(false)
        await settle()
        closedRule(a, left: 90, right: 0, "open → closed (the card follows the island back)")

        // 2. The wings change under the card: a message appears at the right, faces are added at the left, the message goes.
        a.center.show(wings(left: 90, right: 70))
        await settle()
        closedRule(a, left: 90, right: 70, "a message appears in the right wing")
        a.center.show(wings(left: 150, right: 70))
        await settle()
        closedRule(a, left: 150, right: 70, "faces are added at the left")
        a.center.show(wings(left: 150, right: 0))
        await settle()
        closedRule(a, left: 150, right: 0, "the message goes")
        a.center.show(wings(left: 0, right: 0))
        await settle()
        closedRule(a, left: 0, right: 0, "no wings at all (the bare notch grows to the card)")
        a.center.dismiss(id: "cards.test")
        await settle()
        closedRule(a, left: 0, right: 0, "no activity left")

        // 3. Two cards stacked: one column, the same width and middle.
        a.center.show(wings(left: 90, right: 0))
        a.center.present(NotchCard(id: "second", duration: 600) {
            DemoCardContent(symbol: "arrow.down.circle.fill", title: "Download finished", subtitle: "Scout.zip · 75 MB")
        })
        await settle()
        let two = a.cards
        if two.count == 2 {
            check("two cards: the same width and middle", near(two[0].width, two[1].width) && near(two[0].midX, two[1].midX), "\(f(two[0])) / \(f(two[1]))")
            check("two cards: the second hangs right under the first", near(two[1].minY, two[0].maxY), "\(f(two[0])) / \(f(two[1]))")
            check("two cards: as wide as the island's body", near(two[0].width, a.model.islandRect.width - 2 * flare), "\(f(two[0])) island \(f(a.model.islandRect))")
        } else {
            check("two cards: both have a frame", false, "\(two.count) cards")
        }
        a.center.dismissCard(id: "second")
        await settle(0.8)

        // 4. Gone: the island goes back to its own width, and the card list is empty.
        a.center.dismissCard(id: "battery.low")
        await settle()
        check("no card: no card frame is left (nothing keeps a stale place)", a.model.cardRects.isEmpty, "\(a.model.cardRects)")
        check("no card: the island is back to the camera and the left wing", near(a.model.islandRect.width, hardware + wing(90) + 2 * flare, 2.5), "island \(f(a.model.islandRect))")

        // 5. The owner's case: the card arrives while the notch is OPEN, then the notch closes, and opens again.
        let b = Rig(open: true)
        defer { b.close() }
        b.center.show(wings(left: 90, right: 0))
        await settle(0.9)
        b.center.present(battery())
        await settle()
        openRule(b, "card while open")
        b.setOpen(false)
        await settle()
        closedRule(b, left: 90, right: 0, "card while open → the notch closes")
        b.setOpen(true)
        await settle()
        openRule(b, "… and open again")
        b.setOpen(false)
        await settle()
        closedRule(b, left: 90, right: 0, "… and closed again")

        // 6. The hit area is the drawn card: a click near its left edge (where the old, centred card did not reach) lands on it.
        var taps = 0
        b.center.dismissCard(id: "battery.low")
        b.center.present(battery("tap", onTap: { taps += 1 }))
        await settle()
        if let card = b.cards.first {
            b.click(CGPoint(x: card.minX + 6, y: card.midY))
            await settle(0.5)
            check("clicks: the left edge of the drawn card takes the click", taps == 1 && b.center.cards.isEmpty, "taps \(taps) cards \(b.center.cards.count)")
        } else {
            check("clicks: the card has a frame to click", false)
        }

        let text = lines + ["cards selftest done: \(failed == 0 ? "all passed" : "\(failed) FAILED")"]
        for line in text { print(line) }
        fflush(stdout)
        try? text.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
    }
}
