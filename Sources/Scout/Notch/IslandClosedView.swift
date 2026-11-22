import SwiftUI

// The closed island as separate shapes beside the housing (plan C2 to C4, decisions A4, A5, D4): the agents' round bubbles on the left, capsules
// on the right, each exactly as big as what it shows, nothing drawn where nothing shows. The housing is the camera notch or pill (never drawn
// here) or, on a display without a cutout, Scout's own small black capsule ("drawn"). Where every shape stands comes from `IslandRows`.

/// The measured width of each block of the closed view, by block name.
private struct IslandWidthKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue()) { $1 } }
}

/// The natural height of a capsule's content.
private struct IslandHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension CutoutContext {
    /// How much bigger than at the normal size the rows are drawn: content inside a capsule scales by it.
    @MainActor var contentScale: CGFloat {
        geometry.map { IslandRows.contentScale(geometry: $0, sizeFactor: Look.wingScale) } ?? 1
    }
}

extension View {
    /// `reportRect`, only while `shown` (a shape that is not there is not a pointer target).
    func reportRect(_ name: String, when shown: Bool) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: NotchRectKey.self, value: shown ? [name: proxy.frame(in: .named("notchPanel"))] : [:])
        })
    }
}

/// Lays a capsule out: its two shapes (fill and hairline) take the whole box, the content stands `capsulePadding` from the left end; the box is the
/// content's natural width times `scale` plus the padding at both ends, `height` tall. Content that measures nothing gives a box of no size.
private struct IslandCapsuleLayout: Layout {
    var scale: CGFloat
    var height: CGFloat
    /// 0 to 1: how much of its width the capsule has grown (the calm version grows in width instead of in scale).
    var grow: CGFloat = 1
    var animatableData: CGFloat {
        get { grow }
        set { grow = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.last else { return .zero }
        let natural = content.sizeThatFits(.unspecified)
        guard natural.width > 0.5 else { return .zero }
        return CGSize(width: (natural.width * scale + 2 * IslandTuning.capsulePadding) * grow, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.last else { return }
        // The first shape is the rim, the second the black body inside it (a stroked capsule left stray marks at its two ends in a picture).
        let hairline = min(IslandTuning.capsuleHairline, max(0, bounds.height / 2 - 0.5))
        let body = bounds.insetBy(dx: hairline, dy: hairline)
        for (index, shape) in subviews.dropLast().enumerated() {
            let rect = index == 0 ? bounds : body
            shape.place(at: rect.origin, anchor: .topLeading, proposal: ProposedViewSize(rect.size))
        }
        content.place(at: CGPoint(x: bounds.minX + IslandTuning.capsulePadding, y: bounds.midY), anchor: .leading, proposal: .unspecified)
    }
}

/// A black capsule exactly as wide as its content plus the padding, as tall as a bubble. Content taller than the capsule is scaled down to fit.
/// With nothing to show it has no size and draws nothing.
struct IslandCapsule<Content: View>: View {
    var height: CGFloat
    /// The size setting's scale for the content (1 at the normal size).
    var scale: CGFloat = 1
    var hovered = false
    @ViewBuilder var content: Content
    @State private var naturalHeight: CGFloat = 0
    /// False until the capsule has appeared: under Reduce Motion it then grows from no width to its own (and fades in); otherwise it is whole at once
    /// and its parent grows it in by scale.
    @State private var open = false

    var body: some View {
        let fit = naturalHeight > 0.5 ? min(scale, max(0.1, (height - 4) / naturalHeight)) : scale
        IslandCapsuleLayout(scale: fit, height: height, grow: (ScoutRuntime.reduceMotion && !ScoutRuntime.isGallery && !open) ? 0 : 1) {   // pictures are taken whole
            Capsule().fill(Color(white: hovered ? IslandTuning.hoverHairlineOpacity : IslandTuning.neutralRingOpacity))   // white at that opacity over black
            Capsule().fill(Color.black)
            content.fixedSize()
                .background(GeometryReader { Color.clear.preference(key: IslandHeightKey.self, value: $0.size.height) })
                .scaleEffect(fit, anchor: .leading)
        }
        .clipShape(Capsule())
        .onPreferenceChange(IslandHeightKey.self) { naturalHeight = $0 }
        .onAppear {
            if ScoutRuntime.reduceMotion { withAnimation(Theme.spring) { open = true } } else { open = true }
        }
        .animation(.easeOut(duration: IslandTuning.hoverFade), value: hovered)
    }
}

/// The closed island's rows for one display: the left side (the agents' bubbles, or another activity's leading capsule), the right side (the
/// agents' news capsule, or another activity's trailing capsule, then the radio's capsule), and on a display without a cutout the drawn capsule.
struct IslandClosedView: View {
    let geometry: NotchGeometry
    /// The panel's width: the housing is centred in it.
    let panelWidth: CGFloat
    let primary: LiveActivity?
    /// The radio beside whatever else owns the sides.
    let companion: LiveActivity?
    /// The name of the shape under the pointer (`NotchScreenModel.hoveredHit`).
    let hovered: String?
    /// The size setting's factor for the wings (1, 1.15, 1.3).
    let sizeFactor: CGFloat
    let navigator: NotchNavigator
    let center: LiveActivityCenter

    @Environment(\.displayScale) private var displayScale
    @State private var widths: [String: CGFloat] = [:]

    private var isAgent: Bool { primary?.kind == .agent }
    /// The strip and a little below it (`IslandTuning.rowsOverflow`).
    private var canvasHeight: CGFloat { geometry.stripHeight + IslandTuning.rowsOverflow }
    private var isDrawn: Bool { geometry.kind == .none }
    private var rightName: String { isAgent ? "capsule.news" : "capsule.trail" }

    var body: some View {
        let d = IslandRows.diameter(geometry: geometry, sizeFactor: sizeFactor)
        let scale = IslandRows.contentScale(geometry: geometry, sizeFactor: sizeFactor)
        let context = CutoutContext(kind: geometry.kind, rows: true, rowHeight: d, displayScale: displayScale, hovered: hovered, geometry: geometry)
        let layout = IslandRows.layout(geometry: geometry, panelWidth: panelWidth, sizeFactor: sizeFactor,
                                       left: [IslandRows.Piece(name: isAgent ? "agents" : "capsule.lead", width: widths["left"] ?? 0)],
                                       right: [IslandRows.Piece(name: rightName, width: widths["right"] ?? 0),
                                               IslandRows.Piece(name: "capsule.companion", width: widths["companion"] ?? 0)],
                                       displayScale: displayScale)
        func rect(_ name: String) -> CGRect? { (layout.left + layout.right).first { $0.name == name }?.rect }
        let edge = layout.leftEdge   // the left side ends here whatever its width
        let y0 = layout.rowY   // where a block stands before it is measured: the right place already, so it never slides in from a corner
        let rightStart = layout.rightStart
        let afterNews = ((rect("capsule.news") ?? rect("capsule.trail"))?.maxX).map { $0 + IslandTuning.gap } ?? rightStart
        return ZStack(alignment: .topLeading) {
            if isDrawn { drawnCapsule(layout.housing) }
            // Everything beside the housing is cut off inside the housing's keep-out, so no animation frame can ever touch it.
            ZStack(alignment: .topLeading) {
                if let primary {
                    if isAgent {
                        block(primary.leading, key: "left", rect: rect("agents"), edge: edge, y0: y0)
                        block(primary.trailing.contentShape(Capsule()).reportRect("capsule.news", when: (widths["right"] ?? 0) > 0.5)
                                .onTapGesture { click("capsule.news") },
                              key: "right", rect: rect("capsule.news"), x0: rightStart, y0: y0)
                    } else {
                        block(capsule(primary.leading, d, scale, key: "left", name: "capsule.lead"), key: "left", rect: rect("capsule.lead"), edge: edge, y0: y0)
                        block(capsule(primary.trailing, d, scale, key: "right", name: "capsule.trail"), key: "right", rect: rect("capsule.trail"), x0: rightStart, y0: y0)
                    }
                    if let companion {
                        block(capsule(companion.trailing, d, scale, key: "companion", name: "capsule.companion"), key: "companion", rect: rect("capsule.companion"), x0: afterNews, y0: y0)
                    }
                }
            }
            .frame(width: panelWidth, height: canvasHeight, alignment: .topLeading)
            .mask(alignment: .topLeading) { keepOutMask(layout.keepOut).frame(width: panelWidth, height: canvasHeight, alignment: .topLeading) }
        }
        .frame(width: panelWidth, height: canvasHeight, alignment: .topLeading)
        .environment(\.cutout, context)
        .environment(\.colorScheme, .dark)
        .onPreferenceChange(IslandWidthKey.self) { widths = $0 }
        .animation(Theme.spring, value: layout)
    }

    /// Everything of the strip except the keep-out, as a mask.
    private func keepOutMask(_ keepOut: CGRect) -> some View {
        let height = canvasHeight
        return Path { path in
            path.addRect(CGRect(x: 0, y: 0, width: max(0, keepOut.minX), height: height))
            path.addRect(CGRect(x: keepOut.maxX, y: 0, width: max(0, panelWidth - keepOut.maxX), height: height))
            path.addRect(CGRect(x: keepOut.minX, y: 0, width: keepOut.width, height: max(0, keepOut.minY)))
            path.addRect(CGRect(x: keepOut.minX, y: keepOut.maxY, width: keepOut.width, height: max(0, height - keepOut.maxY)))
        }
        .fill(Color.white)
    }

    /// One block of a side at its place. The left side hangs from a fixed line (its trailing end stays 6 pt from the housing whatever its width,
    /// so a row that grows never moves into the clearance); the right side starts at a fixed place. Until its width is known a block is drawn
    /// invisibly (only to be measured), so nothing flashes over the housing.
    @ViewBuilder
    private func block<Content: View>(_ content: Content, key: String, rect: CGRect?, edge: CGFloat? = nil, x0: CGFloat = 0, y0: CGFloat) -> some View {
        let measured = content
            .fixedSize()
            .background(GeometryReader { Color.clear.preference(key: IslandWidthKey.self, value: [key: $0.size.width]) })
        if let edge {
            measured
                .frame(width: edge, alignment: .trailing)
                .padding(.top, rect?.minY ?? y0)
                .opacity(rect == nil ? 0 : 1)
                .allowsHitTesting(rect != nil)
        } else {
            measured
                .padding(.leading, rect?.minX ?? x0)
                .padding(.top, rect?.minY ?? y0)
                .opacity(rect == nil ? 0 : 1)
                .allowsHitTesting(rect != nil)
        }
    }

    /// Another activity's side in a plain capsule.
    private func capsule(_ content: AnyView, _ height: CGFloat, _ scale: CGFloat, key: String, name: String) -> some View {
        IslandCapsule(height: height, scale: scale, hovered: hovered == name) { content }
            .contentShape(Capsule())
            .reportRect(name, when: (widths[key] ?? 0) > 0.5)
            .onTapGesture { click(name) }
    }

    /// A click on a shape of the rows: the island's one click function, unless Settings says that clicking the notch does not open it (one rule for
    /// every shape: the bubbles, "+N", the capsules and the drawn capsule; the pointer still highlights them).
    private func click(_ name: String) {
        guard NotchPrefs.clickToOpen else { return }
        IslandHit.perform(name, geometry: geometry, navigator: navigator, center: center)
    }

    /// Scout's own capsule on a display without a cutout: the housing, the anchor, a click target.
    private func drawnCapsule(_ housing: CGRect) -> some View {
        ZStack {
            Capsule().fill(hovered == IslandHit.drawn ? Color(white: IslandTuning.hoverHairlineOpacity) : Color.black)   // the rim brightens under the pointer
            Capsule().fill(Color.black).padding(IslandTuning.capsuleHairline)
        }
            .frame(width: housing.width, height: housing.height)
            .contentShape(Capsule())
            .reportRect(IslandHit.drawn)
            .onTapGesture { click(IslandHit.drawn) }
            .padding(.leading, housing.minX)
            .padding(.top, housing.minY)
            .animation(.easeOut(duration: IslandTuning.hoverFade), value: hovered)
    }
}
