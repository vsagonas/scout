import AppKit
import SwiftUI

private struct IslandLayout: Equatable {
    var open: Bool
    var width: CGFloat
    var height: CGFloat
    var top: CGFloat
    var bottom: CGFloat
    var shift: CGFloat
}

/// What the cards under the island lay out by: their width and the sideways shift (animated with the island, by the same spring).
private struct CardLayout: Equatable {
    var width: CGFloat
    var shift: CGFloat
    var count: Int
}

/// Each card's own width (its content's natural width, in the card's own points), by card id.
private struct CardNaturalKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct WingWidthKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    func measureWidth(_ name: String) -> some View {
        background(GeometryReader { Color.clear.preference(key: WingWidthKey.self, value: [name: $0.size.width]) })
    }
}

/// The whole content of a notch window: the island (closed strip with wings, or the open panel), the
/// detail drop-down, the secondary bubble and the cards below it.
struct NotchRootView: View {
    @ObservedObject var model: NotchScreenModel
    @ObservedObject var center: LiveActivityCenter
    @ObservedObject var navigator: NotchNavigator
    @ObservedObject var nook: NookStore
    /// The gallery pins a style, a width cap and an open height; the real notch reads the settings.
    var styleOverride: NotchStyle?
    var widthCapOverride: CGFloat?
    var openHeightOverride: CGFloat?

    @AppStorage("notch.style") private var styleRaw = NotchStyle.classic.rawValue
    @AppStorage("notch.openWidth") private var openWidthPref = 1040.0
    private var openHeightPref: Double { NotchPrefs.openHeight }   // 180 pt; the height is automatic (no setting)
    @Environment(\.colorScheme) private var systemScheme

    @State private var leadingW: CGFloat = 0
    @State private var trailingW: CGFloat = 0
    @State private var detailH: CGFloat = 0
    /// The widest card's own width as its content wants it (0 = no card).
    @State private var cardNatural: CGFloat = 0
    /// The island's height when a drag on the bottom grip began (nil = not resizing).
    @State private var resizeStart: CGFloat?
    @State private var gripHover = false

    private var style: NotchStyle { styleOverride ?? NotchStyle(rawValue: styleRaw) ?? .classic }
    private var hw: CGSize { model.geometry.size }
    private var isOpen: Bool { model.isOpen }
    private var showsDrop: Bool { isOpen && navigator.isDropTargeting }
    private var primary: LiveActivity? { center.primary }
    /// How much bigger the open notch is drawn (Settings › Appearance › Notch › Size; 1 = as designed). The open content is laid out at the island's
    /// size divided by this and scaled up from the top edge, so the island grows to match and stays flush with the screen edge.
    private var scale: CGFloat { isOpen ? Look.scale : 1 }
    /// How much bigger the closed notch's wings are drawn.
    private var wingScale: CGFloat { Look.wingScale }
    /// The closed notch's wings, each exactly as wide as what it shows: the content (at the wing size), 8 pt from the outer edge and 6 pt from
    /// the camera; a side with nothing to show has no wing.
    /// While the hover detail hangs below, both
    /// wings match so it stays centred.
    private var leftWing: CGFloat { wingWidth(leadingW, other: trailingW) + cardGrow / 2 }
    private var rightWing: CGFloat { wingWidth(trailingW, other: leadingW) + cardGrow / 2 }
    private static let wingOuter: CGFloat = 8
    private static let wingInner: CGFloat = 6

    private func wingWidth(_ content: CGFloat, other: CGFloat) -> CGFloat {
        guard primary != nil else { return 0 }
        func padded(_ w: CGFloat) -> CGFloat { w > 0.5 ? w * wingScale + Self.wingOuter + Self.wingInner : 0 }
        if detailActive { return max(padded(content), padded(other), (280 - hw.width) / 2) }
        return padded(content)
    }

    /// How far the closed island moves right so its notch gap stays over the camera when its wings differ (open: centred). A card's growth
    /// is added to both wings alike, so it never moves the island sideways.
    private var islandShift: CGFloat { isOpen ? 0 : rightWing - leftWing }

    // MARK: Cards hang from the island as ONE black shape (the owner, 2026-11-16: the card was wider than the island and off to one side)
    //
    // The card is centred under the island (the same sideways shift) and is as wide as the island's body, the part between its two flares
    // (the island's width minus 2 x the top radius). When the island is too narrow for what the card shows, the island grows to the card's
    // width for as long as the card is up (the spring runs on both), so the notch itself grows down. The island's bottom corners are
    // square while a card hangs from it (the card has the rounded ones). Open, the card hangs centred under the open island, 480 pt at
    // most, and never narrower than its content. Every number below follows the island LIVE: nothing is stored from an earlier size.

    private var cardsShown: Bool { !center.cards.isEmpty }
    /// The widest card's own content width, as drawn (the wings' size factor applies to cards too).
    private var cardNeed: CGFloat { cardsShown ? max(Self.cardFloor, cardNatural * wingScale) : 0 }
    private static let cardFloor: CGFloat = 260
    private static let openCardCap: CGFloat = 480

    /// The closed island's body without any card: the camera and the two wings.
    private var closedBody: CGFloat {
        hw.width + wingWidth(leadingW, other: trailingW) + wingWidth(trailingW, other: leadingW)
    }

    /// How much wider the closed island becomes for the cards (spread over both wings).
    private var cardGrow: CGFloat { (cardsShown && !isOpen) ? max(0, cardNeed - closedBody) : 0 }

    /// The width every card is drawn at (rendered points): the island's body when closed (at least what the cards need), the open island's
    /// width up to a cap when open.
    private var cardWidth: CGFloat {
        guard cardsShown else { return 0 }
        if isOpen { return max(cardNeed, min(openWidth * scale, Self.openCardCap * wingScale)) }
        return max(closedBody, cardNeed)
    }
    private var detailActive: Bool { !isOpen && model.detailVisible && primary?.detail != nil }

    private var topRadius: CGFloat {
        if isOpen { return 12 }
        return (primary != nil || cardsShown || !model.geometry.isHardware) ? 6 : 0
    }

    /// Square while a card hangs from the closed island (one shape with it); the notch's own rounding otherwise.
    private var bottomRadius: CGFloat { isOpen ? 26 : (cardsShown ? 0 : (detailActive ? 18 : (model.geometry.isHardware ? 10 : 12))) }

    /// The open dashboard is as wide as its row of panels (sum of their spans), but never wider than the size
    /// setting and never narrower than the header needs. Overflow panels are hidden. In the content's own points (the island is this times `scale`).
    private var openWidth: CGFloat {
        let cap = min(widthCapOverride ?? CGFloat(openWidthPref), (model.panelSize.width - 40) / scale)
        // A panel that grew into its detail takes the full width the setting allows; the dashboard is only as wide as its row.
        if expandedKind != nil && !showsDrop { return max(cap, min(NotchPrefs.widthRange.lowerBound, cap)) }
        let widgets = nook.sizingSpans.map { CGFloat($0) * NookMetrics.cell }
        let row = widgets.reduce(0, +) + CGFloat(max(0, widgets.count - 1)) * NookMetrics.spacing + (nook.isEditing ? 60 : 0)
        let needed = row + 2 * (12 + 14)
        return max(min(needed, cap), min(NotchPrefs.widthRange.lowerBound, cap))
    }

    private var islandWidth: CGFloat {
        if isOpen { return openWidth * scale }
        return hw.width + leftWing + rightWing + 2 * topRadius
    }

    /// The island's height as the screen sees it: the content's height times the size factor when open.
    private var islandHeight: CGFloat { isOpen ? contentHeight * scale : contentHeight }

    /// Open: the height setting, but never less than the shown workspace needs (the Calendar's month grid, a chat).
    /// The island only ever grows DOWNWARD: its top stays flush with the screen edge. A height dragged on the grip
    /// counts only where there is more to show, between this automatic height and `resizeLimit`. In the content's own points when open.
    private var contentHeight: CGFloat {
        if isOpen {
            let editing = nook.isEditing && navigator.workspace == .nook && !navigator.isDropTargeting
            var height = autoOpenHeight
            if !navigator.isDropTargeting, let limit = resizeLimit, let dragged = navigator.draggedHeight(key: resizeKey) {
                height = min(max(dragged, navigator.resizeFloor(shown: NotchPrefs.resolve(navigator.workspace), automatic: height)), limit)
            }
            return height + (editing ? NotchPrefs.editExtra : 0)
        }
        return detailActive ? hw.height + max(detailH, 30) + 12 : hw.height
    }

    /// The open height before any drag: the setting, the workspace's minimum and what the workspace asks for.
    private var autoOpenHeight: CGFloat {
        let shown = NotchPrefs.resolve(navigator.workspace)
        let wanted = navigator.neededHeight(shown: shown)
        let needed = navigator.isDropTargeting ? 0 : max(NotchPrefs.minimumOpenHeight(for: shown), wanted)
        return min(max(openHeightOverride ?? CGFloat(openHeightPref), needed), maxOpenHeight)
    }

    private var resizeKey: String { navigator.resizeKey(shown: NotchPrefs.resolve(navigator.workspace)) }

    /// How far the grip may pull the island down: the workspace's full content (agent tabs: as far as the panel goes).
    /// nil when everything already fits.
    private var resizeLimit: CGFloat? {
        #if !APPSTORE
        if navigator.activeTab != nil { return maxOpenHeight }
        #endif
        guard let wanted = navigator.resizeMax(shown: NotchPrefs.resolve(navigator.workspace)) else { return nil }
        let limit = min(wanted, maxOpenHeight)
        return limit > autoOpenHeight + 12 ? limit : nil
    }

    private var maxOpenHeight: CGFloat { (model.panelSize.height - 60) / scale }

    /// The scheme the content is drawn in: dark on the closed notch; open, the colours preset (Settings › Appearance › Notch › Colours), and on the
    /// glass style the system's own unless the light preset is on.
    private var contentScheme: ColorScheme {
        if !isOpen { return .dark }
        if style == .classic { return Look.contentScheme }
        return Look.isLight ? .light : systemScheme
    }

    var body: some View {
        VStack(spacing: 0) {
            island
            NotchCardsView(center: center, width: cardWidth, scale: wingScale)
                // The same sideways shift as the island: the card's middle is the island's middle.
                .padding(.leading, max(0, islandShift))
                .padding(.trailing, max(0, -islandShift))
                .animation(resizeStart == nil ? Theme.spring : nil, value: CardLayout(width: cardWidth, shift: islandShift, count: center.cards.count))
        }
        .frame(width: model.panelSize.width, height: model.panelSize.height, alignment: .top)
        // A picture flying into a tab key (the camera's Snap into Clipboard), over everything, taking no clicks.
        .overlay(alignment: .topLeading) { NotchFlyLayer(rects: { [model] in model.panelRects }, island: { [model] in model.islandRect }) }
        .coordinateSpace(name: "notchPanel")
        .onPreferenceChange(NotchRectKey.self) { rects in
            model.islandRect = rects["island"] ?? .zero
            model.cardRects = rects.filter { $0.key.hasPrefix("card.") }.map(\.value)
            model.panelRects = rects.filter { $0.key.hasPrefix("panel.") || $0.key.hasPrefix("tab.") || $0.key.hasPrefix("cal.") || $0.key.hasPrefix("mirror.") }   // "cal.": the Calendar view's columns (self-tests); "mirror.": where Snap's picture starts
        }
        .onPreferenceChange(CardNaturalKey.self) { widths in
            cardNatural = widths.values.max() ?? 0
        }
        .onPreferenceChange(WingWidthKey.self) { widths in
            leadingW = widths["lead"] ?? leadingW
            trailingW = widths["trail"] ?? trailingW
            detailH = widths["detail"] ?? detailH
        }
        .environment(\.nookStore, nook)
        .environment(\.notchNavigator, navigator)
        .environment(\.notchOpenMaxHeight, maxOpenHeight)
        .environment(\.notchIslandFrame, isOpen ? model.islandRect : nil)
        .opacity(model.hiddenForFullscreen ? 0 : 1)
        // The window's own appearance follows the notch (dark closed; open: the colours preset), so what AppKit draws by itself (an SF Symbol
        // that SwiftUI draws through a CGDrawingView, a text field's text, a menu) reads on the surface whatever the Mac's light or dark mode is.
        .background(WindowAppearance(dark: contentScheme == .dark))
    }

    // MARK: Island

    private var island: some View {
        let shape = NotchShape(topRadius: topRadius * scale, bottomRadius: bottomRadius * scale)
        return ZStack(alignment: .top) {
            islandBackground(shape)
            ZStack(alignment: .top) {
                if isOpen {
                    // The content's own space (before the Size setting scales it): a panel measures itself against the island's edges here.
                    openContent
                        .frame(width: openWidth, height: contentHeight, alignment: .top)
                        .coordinateSpace(name: "notchContent")
                        .environment(\.notchContentSize, CGSize(width: openWidth, height: contentHeight))
                        .lookScaled(scale, content: CGSize(width: openWidth, height: contentHeight)).transition(.opacity)
                } else {
                    closedContent.transition(.opacity)
                }
            }
            // Content taller than the island is cut off at the BOTTOM. Centred, it pushed the header up
            // past the top of the screen (the Calendar did that at the default height).
            .frame(width: islandWidth, height: islandHeight, alignment: .top)
            .environment(\.colorScheme, contentScheme)
            .clipShape(shape)
        }
        .frame(width: islandWidth, height: islandHeight, alignment: .top)
        .contentShape(shape)
        .onTapGesture { if !isOpen, NotchPrefs.clickToOpen { navigator.open() } }
        .contextMenu { islandMenu }
        // One shadow for the whole island: without the compositing group every panel, key and word inside cast its own, which drew dark
        // gaps between the panels (the owner wants one screen) and cost a blur per view.
        .compositingGroup()
        .shadow(color: .black.opacity(isOpen ? (Look.isLight ? 0.24 : 0.38) : 0), radius: 16, y: 8)
        // No bubble beside the notch for the other activities any more (the owner, 2026-11-16: the second sparkle at the right).
        .overlay(alignment: .bottom) { resizeGrip }
        .reportRect("island")
        // The notch gap stays over the camera: a wider left wing moves the island left, a wider right wing moves it right.
        .padding(.leading, max(0, islandShift))
        .padding(.trailing, max(0, -islandShift))
        .animation(resizeStart == nil ? Theme.spring : nil, value: IslandLayout(open: isOpen, width: islandWidth, height: islandHeight, top: topRadius, bottom: bottomRadius, shift: islandShift))
        .animation(Theme.quick, value: center.activities.count)
    }

    @ViewBuilder
    private func islandBackground(_ shape: NotchShape) -> some View {
        if isOpen && style == .glass {
            ZStack(alignment: .top) {
                GlassBackground(shape)
                UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous)
                    .fill(Color.black)
                    .frame(width: hw.width, height: hw.height)
            }
        } else {
            shape.fill(isOpen ? Look.surface : Color.black)   // open: one surface with the panels (black, or the light preset's paper); closed: the notch's own black
        }
    }

    // MARK: Resize grip (drag the open island's bottom edge: down shows more of a chat, up makes it smaller)

    @ViewBuilder
    private var resizeGrip: some View {
        if isOpen && !showsDrop, let limit = resizeLimit {
            Capsule()
                .fill(Look.ink(resizeStart != nil ? 0.6 : (gripHover ? 0.45 : 0.2)))
                .environment(\.colorScheme, contentScheme)
                .frame(width: 40, height: 5)
                .frame(width: 160, height: 18)
                .contentShape(Rectangle())
                .onHover { inside in
                    gripHover = inside
                    if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let key = resizeKey
                        if resizeStart == nil {
                            let editing = nook.isEditing && navigator.workspace == .nook
                            resizeStart = contentHeight - (editing ? NotchPrefs.editExtra : 0)
                            navigator.hold("notch.resize")
                        }
                        let wanted = (resizeStart ?? contentHeight) + value.translation.height / scale
                        navigator.setDraggedHeight(min(max(wanted, navigator.resizeFloor(shown: NotchPrefs.resolve(navigator.workspace), automatic: autoOpenHeight)), limit), key: key, save: false)
                    }
                    .onEnded { _ in
                        navigator.setDraggedHeight(navigator.draggedHeight(key: resizeKey), key: resizeKey, save: true)
                        resizeStart = nil
                        navigator.release("notch.resize")
                    })
                .onTapGesture(count: 2) {
                    navigator.setDraggedHeight(nil, key: resizeKey, save: true)
                }
                .help("Drag down to see more. Double-click to go back to the usual height.")
                .padding(.bottom, 1)
                .transition(.opacity)
        }
    }

    // MARK: Closed

    private var closedContent: some View {
        VStack(spacing: 0) {
            if let activity = primary {
                // Each side's content sits beside the camera; the island grows outward from it.
                HStack(spacing: 0) {
                    wingContent(activity.leading, key: "lead")
                        .scaleEffect(wingScale, anchor: .trailing)
                        .padding(.trailing, Self.wingInner)
                        .frame(width: leftWing, alignment: .trailing)
                        .contentShape(Rectangle())
                        .onTapGesture { tapActivity(activity) }
                    Color.clear.frame(width: hw.width)
                    wingContent(trailingContent(activity), key: "trail")
                        .scaleEffect(wingScale, anchor: .leading)
                        .padding(.leading, Self.wingInner)
                        .frame(width: rightWing, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { tapActivity(activity) }
                }
                .frame(height: hw.height)
                .padding(.horizontal, topRadius)
                .transition(.opacity)
                if detailActive, let detail = activity.detail {
                    detail.fixedSize(horizontal: false, vertical: true).measureWidthHeight("detail")
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                        .transition(.opacity)
                }
            } else {
                Color.clear.frame(height: hw.height)
            }
        }
    }

    /// The radio keeps a place at the outer end of the right wing while another activity (the agents) owns the wings:
    /// its station and song for a few seconds, then its sound bars.
    /// The gap before it exists only when the agents' side shows something (no empty space). A click on it opens the Radio tab.
    private var companion: LiveActivity? {
        guard let primary, primary.kind != .radio else { return nil }
        return center.activities.first { $0.kind == .radio }
    }

    private func trailingContent(_ activity: LiveActivity) -> AnyView {
        guard let companion else { return activity.trailing }
        return AnyView(WingRow(spacing: 8) {
            activity.trailing
            companion.trailing.contentShape(Rectangle()).onTapGesture { tapActivity(companion) }
        })
    }

    /// A wing's content at its own size, measured. It is always one view (an empty side measures 0), so the row keeps its three parts and the
    /// notch gap stays over the camera: an empty right wing once dropped out of the row, and the faces slid 26 pt right, under the camera (257).
    private func wingContent(_ content: AnyView, key: String) -> some View {
        ZStack {
            Color.clear.frame(width: 0, height: 0)
            content.fixedSize()
        }
        .fixedSize()
        .measureWidth(key)
    }

    private func tapActivity(_ activity: LiveActivity) {
        if let onTap = activity.onTap { onTap() } else { navigator.open() }
    }

    // MARK: Open

    private var openContent: some View {
        VStack(spacing: 0) {
            NotchHeader(navigator: navigator, nook: nook, hardwareWidth: hw.width / scale,
                        sideWidth: max(40, (openWidth - 2 * (topRadius + 12) - hw.width / scale) / 2))
                .frame(height: hw.height)
                .padding(.horizontal, topRadius + 12)
            ZStack {
                if showsDrop {
                    Registry.dropTargetsView()
                } else if let kind = expandedKind {
                    expandedBody(kind)
                        .id(kind)
                        .transition(expandTransition)
                } else {
                    Registry.workspaceView(.nook)
                        .id("dashboard")
                        .transition(dashboardTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The Agents den fills the open notch edge to edge (its rounded corners clip the picture): no black frame around it
            .padding(.horizontal, fillsIsland ? 0 : topRadius + 14)
            .padding(.top, fillsIsland ? 2 : 6)
            .padding(.bottom, fillsIsland ? 0 : 16)
            .animation(Theme.quick, value: expandedKind)
        }
    }

    /// What the island shows besides the dashboard: a detail a panel expanded into, or (full edition) an agent tab's terminal.
    private enum Expanded: Hashable {
        case detail(WorkspaceKind)
        case tab(String)
    }

    /// The 8-bit Agents den is on show: it takes the whole island below the header.
    /// The camera fills it too.
    private var fillsIsland: Bool { ((expandedKind == .detail(.agents) && Retro.is8bit) || expandedKind == .detail(.mirror)) && !showsDrop }

    private var expandedKind: Expanded? {
        #if !APPSTORE
        if let tab = navigator.activeTab { return .tab(tab) }
        #endif
        let shown = NotchPrefs.resolve(navigator.workspace)
        return shown == .nook ? nil : .detail(shown)
    }

    @ViewBuilder
    private func expandedBody(_ expanded: Expanded) -> some View {
        switch expanded {
        case .detail(let kind):
            Registry.workspaceView(kind)
        case .tab(let id):
            #if !APPSTORE
            AgentTabContentView(tabID: id, navigator: navigator)
            #else
            Text(id).hidden()
            #endif
        }
    }

    /// Where the island's expand animation grows from: the middle of the panel that was clicked (or last had the pointer).
    private var expandAnchor: UnitPoint {
        let island = model.islandRect
        guard island.width > 0, island.height > 0, let key = nook.lastPanel, let rect = nook.panelRects[key] else { return .center }
        return UnitPoint(x: min(1, max(0, (rect.midX - island.minX) / island.width)),
                         y: min(1, max(0, (rect.midY - island.minY) / island.height)))
    }

    /// A panel grows into the island (scale and fade from the panel; Reduce Motion: a cross-fade only).
    private var expandTransition: AnyTransition {
        if ScoutRuntime.reduceMotion { return .opacity }
        return .scale(scale: 0.5, anchor: expandAnchor).combined(with: .opacity)
    }

    private var dashboardTransition: AnyTransition {
        if ScoutRuntime.reduceMotion { return .opacity }
        return .scale(scale: 0.97, anchor: expandAnchor).combined(with: .opacity)
    }

    @ViewBuilder
    private var islandMenu: some View {
        if isOpen {
            Button("Close Notch") { navigator.forceClose() }
        } else {
            Button("Open Notch") { navigator.open() }
        }
        Button("Edit Nook") { nook.beginEditing(navigator: navigator) }
        Menu("Open") {
            ForEach(WorkspaceKind.available.filter { $0 != .nook && $0 != .todo }) { kind in   // the To-dos are in the Calendar
                Button { navigator.open(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
            }
        }
        Divider()
        Button("Settings…") { SettingsWindowController.shared.show() }
        Button("Quit Scout") { NSApp.terminate(nil) }
    }
}

private extension View {
    func measureWidthHeight(_ name: String) -> some View {
        background(GeometryReader { Color.clear.preference(key: WingWidthKey.self, value: [name: $0.size.height]) })
    }
}

// MARK: - Cards under the notch

/// The notifications (an agent finished, a question, a download, a screenshot...): black panels that hang from the island, as if the notch
/// itself grew down to say it, never grey bubbles.
/// All of them are `width` points wide (as drawn; `NotchRootView` works it out from the island,
/// live), and stacked they are one black column: only the last one has the rounded bottom, a hairline divides them.
struct NotchCardsView: View {
    @ObservedObject var center: LiveActivityCenter
    /// The width every card is drawn at, in points as drawn on screen.
    var width: CGFloat = 400
    /// The wings' size factor (Settings > Appearance > Notch > Size): cards are laid out at `width / scale` and drawn `scale` times bigger.
    var scale: CGFloat = 1

    var body: some View {
        let layoutWidth = width / max(scale, 0.01)
        let cards = center.cards
        VStack(spacing: 0) {
            ForEach(cards) { card in
                NotchCardView(card: card, center: center, width: layoutWidth, first: card.id == cards.first?.id, last: card.id == cards.last?.id)
                    .magnified(scale, width: layoutWidth)
                    .reportRect("card.\(card.id)")
                    .transition(ScoutRuntime.reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Theme.spring, value: cards.map(\.id))
    }
}

struct NotchCardView: View {
    let card: NotchCard
    @ObservedObject var center: LiveActivityCenter
    var width: CGFloat = 400
    /// The first card of a stack hangs from the island; the last one has the rounded bottom.
    var first = true
    var last = true
    @State private var hover = false
    @State private var dragY: CGFloat = 0

    var body: some View {
        card.content
            // Its own width is measured (the content may be wider than the slot for a moment, until the island has grown to it).
            .fixedSize(horizontal: true, vertical: true)
            .background(GeometryReader { Color.clear.preference(key: CardNaturalKey.self, value: [card.id: $0.size.width]) })
            .frame(width: width)
            .environment(\.colorScheme, .dark)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: last ? 18 : 0, bottomTrailingRadius: last ? 18 : 0, style: .continuous).fill(Color.black))
            .overlay(alignment: .top) {
                if !first { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.horizontal, 14) }
            }
            .overlay(alignment: .topTrailing) {
                if hover {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(.regularMaterial))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                    .transition(.opacity)
                }
            }
            .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
            .offset(y: min(0, dragY))
            .opacity(1 - min(1, Double(-min(0, dragY)) / 90))
            .onHover { hover = $0 }
            .onTapGesture {
                card.onTap?()
                dismiss()
            }
            .gesture(DragGesture(minimumDistance: 6)
                .onChanged { dragY = $0.translation.height }
                .onEnded { value in
                    if value.translation.height < -26 { dismiss() } else { withAnimation(Theme.quick) { dragY = 0 } }
                })
            .animation(Theme.quick, value: hover)
    }

    private func dismiss() { center.dismissCard(id: card.id) }
}

private struct NotchOpenMaxHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// The tallest the open island can be on this screen (nil outside the real notch, e.g. a picture or a test's fixed panel).
    var notchOpenMaxHeight: CGFloat? {
        get { self[NotchOpenMaxHeightKey.self] }
        set { self[NotchOpenMaxHeightKey.self] = newValue }
    }
}

private struct NotchIslandFrameKey: EnvironmentKey {
    static let defaultValue: CGRect? = nil
}

extension EnvironmentValues {
    /// The open island's frame in the "notchPanel" space (nil when closed, in pictures and tests): a panel can line itself up with its corner.
    var notchIslandFrame: CGRect? {
        get { self[NotchIslandFrameKey.self] }
        set { self[NotchIslandFrameKey.self] = newValue }
    }
}

private struct NotchContentSizeKey: EnvironmentKey {
    static let defaultValue: CGSize? = nil
}

extension EnvironmentValues {
    /// The open island's content size in its own space (the "notchContent" coordinate space; nil outside the open island).
    var notchContentSize: CGSize? {
        get { self[NotchContentSizeKey.self] }
        set { self[NotchContentSizeKey.self] = newValue }
    }
}

/// Side by side, with the gap only between parts that show something: an empty part (the agents' readout between its messages) takes no room
/// and leaves no gap, so the wing is exactly as wide as what it shows.
struct WingRow: Layout {
    var spacing: CGFloat = 8

    init(spacing: CGFloat = 8) { self.spacing = spacing }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let shown = sizes.filter { $0.width > 0.5 }
        let width = shown.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, shown.count - 1))
        return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
            if size.width > 0.5 { x += size.width + spacing }
        }
    }
}
