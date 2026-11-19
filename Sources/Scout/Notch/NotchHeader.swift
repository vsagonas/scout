import SwiftUI

/// The open notch's top strip sits in the menu-bar band, so the middle `hardwareWidth` (the camera housing) stays empty.
/// The tab icons (the dashboard and the full views, in the order of Settings › Notch › Tabs) sit LEFT of it and, when they
/// need the room, continue RIGHT of it before the gear. A click opens one.
/// The "+" menu and the "‹ back" control are gone at the owner's word (2026-11-15): the dashboard tab goes back, Esc too.
/// RIGHT of it: the Mirror tab (always on this side), the lock key and the gear (and, in Edit Nook, Done and "restore defaults").
/// The lock key keeps the tab on show as the one the notch opens on (instead of the dashboard); that tab's key wears a tiny lock.
/// LEFT of the camera, right beside it, the agents' tiny faces on every view but the dashboard and the Agents view (they show the agents
/// already)
struct NotchHeader: View {
    @ObservedObject var navigator: NotchNavigator
    @ObservedObject var nook: NookStore
    let hardwareWidth: CGFloat
    let sideWidth: CGFloat
    @AppStorage("notch.workspaces") private var raw = ""
    @AppStorage("notch.tabsEdited") private var edited = false
    @AppStorage(NotchPrefs.lockedTabKey) private var lockedRaw = ""
    @Environment(\.notchLockPreview) private var lockPreview
    @ObservedObject private var agents = AgentsStore.shared

    private let buttonWidth: CGFloat = 27
    private let gap: CGFloat = 2

    /// What shows now: the expanded detail or the dashboard (nil while an agent tab is open, full edition).
    private var current: WorkspaceKind? {
        #if !APPSTORE
        if navigator.activeTab != nil { return nil }
        #endif
        return NotchPrefs.resolve(navigator.workspace)
    }

    private var editing: Bool { nook.isEditing && current == .nook }

    /// The tab the lock key keeps as the opening one (gallery pictures can ask for any).
    private var locked: WorkspaceKind? {
        if let lockPreview { return lockPreview.locked }
        return NotchPrefs.lockedTab(raw: lockedRaw)
    }

    /// Every tab shows: left of the camera first,
    /// then right of it before the gear. Only when even both sides cannot hold them at full size do the buttons get narrower.
    struct TabLayout: Equatable {
        var left: [WorkspaceKind]
        var right: [WorkspaceKind]
        var width: CGFloat

        /// The keys of `all` that sit left and right of the camera at the widest key width (27 down to 18) that holds them.
        /// `extraLeft` is room the left side keeps beside the camera for something that is not a key (the agents' faces).
        static func make(_ all: [WorkspaceKind], sideWidth: CGFloat, editing: Bool, buttonWidth: CGFloat = 27, gap: CGFloat = 2,
                         extraLeft: CGFloat = 0) -> TabLayout {
            // The picture tab (Mirror) and then the Radio always stand RIGHT of the camera, first after it;
            // the other tabs fill
            // the left side first and spill over to the right after them.
            let pinned = pinnedRight.filter { all.contains($0) }
            let rest = all.filter { !pinnedRight.contains($0) }
            let rightRoom = max(0, sideWidth - reservedRight(editing: editing) - cameraGap)
            let leftRoom = max(0, sideWidth - extraLeft)
            var width = buttonWidth
            while true {
                let leftCap = max(1, Int((leftRoom + gap) / (width + gap)))
                let rightCap = max(pinned.count, Int((rightRoom + gap) / (width + gap)))
                let spill = max(0, rightCap - pinned.count)
                if rest.count <= leftCap + spill || width <= 18 {
                    let left = Array(rest.prefix(leftCap))
                    return TabLayout(left: left, right: pinned + Array(rest.dropFirst(leftCap).prefix(spill)), width: width)
                }
                width -= 1
            }
        }

        /// The air between the camera housing and the first key right of it: the same as between the faces and the camera on the left
        static let cameraGap: CGFloat = 6
        /// Tabs that always sit right of the camera, first after it, in this order.
        static let pinnedRight: [WorkspaceKind] = [.mirror, .radio]

        /// The room the right side keeps for what is not a tab: the lock key and the gear (27 pt and 2 pt each, a little air), and in
        /// Edit Nook the restore key and Done as well.
        static func reservedRight(editing: Bool) -> CGFloat { editing ? 161 : 64 }
    }

    private func tabLayout(facesWidth: CGFloat) -> TabLayout {
        TabLayout.make(NotchPrefs.parseTabs(raw, edited: edited), sideWidth: sideWidth, editing: editing, buttonWidth: buttonWidth, gap: gap,
                       extraLeft: facesWidth)
    }

    // MARK: The agents' tiny faces

    /// The faces show on every view, the dashboard and the Agents view too
    static func showsFaces(current: WorkspaceKind?) -> Bool { true }
    /// At most this many faces stand in the header, then a "+N".
    static let maxFaces = 4
    /// The room left of the camera is ALWAYS kept for at least this many faces, so the tab keys never move when agents come and go
    static let reservedFaces = 2

    /// The room the faces take left of the camera (with their "+N" and a little air after the keys); never less than `reservedFaces`.
    static func facesWidth(count: Int, more: Int) -> CGFloat {
        let n = max(count, reservedFaces)
        return CGFloat(n) * AgentFaceArt.side + CGFloat(n - 1) * 3 + (more > 0 ? 18 : 0) + 10
    }

    private var faces: (shown: [AgentWingSummary.Face], more: Int) {
        guard Self.showsFaces(current: current) else { return ([], 0) }
        let summary = AgentWingSummary.make(sessions: agents.sessions)
        let shown = Array(summary.faces.prefix(Self.maxFaces))
        return (shown, summary.faces.count + summary.moreFaces - shown.count)
    }

    /// The minimal look's stand-in for a face: a small dot in the colour of what the agent does.
    static func dot(_ mood: AgentFaceMood) -> Color {
        switch mood {
        case .working: Theme.accent
        case .asking: .orange
        case .finished: .green
        case .stopped: .red
        case .idle: .gray
        }
    }

    /// A tap on a face opens the Agents view with THAT agent's window open;
    /// a tap on "+N" opens the Agents view.
    @ViewBuilder private func facesView(_ f: (shown: [AgentWingSummary.Face], more: Int)) -> some View {
        if Retro.is8bit {
            pixelFaces(f)
        } else {
            // The minimal look: the same cpu glyph and counts as the closed notch's wing.
            Button { openAgents(nil) } label: {
                AgentWingCount(summary: AgentWingSummary.make(sessions: agents.sessions))
                    .frame(height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Agents")
            .padding(.leading, 4).padding(.trailing, 6)
            .reportRect("header.faces")
        }
    }

    private func pixelFaces(_ f: (shown: [AgentWingSummary.Face], more: Int)) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(f.shown.enumerated()), id: \.element.id) { index, face in
                Button { openAgents(face.id) } label: {
                    Group {
                        if Retro.is8bit {
                            AgentFaceIcon(agent: face.agent, mood: face.mood, phase: AgentFaceArt.phase(for: face.id), variant: face.variant)
                        } else {
                            Circle().fill(Self.dot(face.mood)).frame(width: 8, height: 8).frame(width: 12, height: AgentFaceArt.side)
                        }
                    }
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(StillButtonStyle())
                .help(Self.faceHelp(face, sessions: agents.sessions))
                .accessibilityLabel(Self.faceHelp(face, sessions: agents.sessions))
                .reportRect("header.face.\(index)")
            }
            if f.more > 0 {
                Button { openAgents(nil) } label: {
                    Text(verbatim: "+\(f.more)").font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(Look.ink(0.75))
                        .frame(height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Agents")
            }
        }
        .padding(.leading, 4).padding(.trailing, 6)
        .reportRect("header.faces")
    }

    /// Opens the Agents view, with `id`'s window open when it is given.
    private func openAgents(_ id: String?) {
        if let id { agents.focusID = id }
        withAnimation(Theme.quick) { navigator.expand(.agents) }
    }

    /// "site: working", for the face's help and its accessibility label.
    static func faceHelp(_ face: AgentWingSummary.Face, sessions: [AgentSession]) -> String {
        let project = sessions.first { $0.id == face.id }?.project ?? String(localized: "Agent")
        switch face.mood {
        case .working: return String(localized: "\(project): working")
        case .asking: return String(localized: "\(project): needs you")
        case .finished: return String(localized: "\(project): finished")
        case .stopped: return String(localized: "\(project): stopped")
        case .idle: return String(localized: "\(project): asleep")
        }
    }

    var body: some View {
        let f = faces
        let tabs = tabLayout(facesWidth: Self.facesWidth(count: f.shown.count, more: f.more))
        HStack(spacing: 0) {
            HStack(spacing: gap) {
                ForEach(tabs.left) { kind in tab(kind, width: tabs.width) }
                if !f.shown.isEmpty {
                    Spacer(minLength: 0)
                    facesView(f)
                }
            }
            .frame(width: sideWidth, alignment: .leading)
            Color.clear.frame(width: hardwareWidth)
            HStack(spacing: gap) {
                Color.clear.frame(width: TabLayout.cameraGap - gap, height: 1)   // with the stack's gap: cameraGap of air after the camera
                ForEach(tabs.right) { kind in tab(kind, width: tabs.width) }
                Spacer(minLength: 4)
                if editing {
                    NotchIconButton(symbol: "arrow.counterclockwise", selected: false, help: String(localized: "Restore default widgets")) {
                        withAnimation(Theme.quick) { nook.restoreDefaults() }
                    }
                    Button("Done") { nook.endEditing(navigator: navigator) }
                        .buttonStyle(.retro(tint: Retro.Ink.yellow, compact: true))
                }
                lockKey
                NotchIconButton(symbol: "gearshape", selected: false, help: String(localized: "Settings")) {
                    SettingsWindowController.shared.show()   // the notch stays open behind it, so the person sees what they change
                }
            }
            .frame(width: sideWidth, alignment: .trailing)
        }
    }

    private func tab(_ kind: WorkspaceKind, width: CGFloat) -> some View {
        NotchTabButton(kind: kind, selected: kind == current, width: width, locked: kind == locked) { open(kind) }
            .reportRect("tab.\(kind.rawValue)")
    }

    /// The lock key, next to the gear: pressed in while the tab on show is the one the notch opens on; a click keeps this tab as the
    /// opening one (an older lock moves here), a click on the locked tab lets go. The Mirror and agent tabs cannot be kept.
    private var lockKey: some View {
        let shown = current
        let on = shown != nil && locked == shown
        let can = shown.map(NotchPrefs.canLock) ?? false
        return NotchIconButton(symbol: on ? "lock.fill" : "lock.open", selected: on,
                               help: Self.lockHelp(shown: shown, locked: locked), enabled: can) {
            guard let shown, NotchPrefs.canLock(shown) else { return }
            NotchPrefs.toggleLock(on: shown)
            NookHaptics.tick()
        }
        .reportRect("tab.lock")
    }

    /// What the lock key's tooltip says for the tab on show (`nil`: an agent tab) and the locked one.
    static func lockHelp(shown: WorkspaceKind?, locked: WorkspaceKind?) -> String {
        guard let shown else { return String(localized: "An agent tab cannot be kept as the opening tab") }
        if !NotchPrefs.canLock(shown) { return String(localized: "The \(shown.title) uses the camera, so it never opens by itself") }
        if locked == shown { return String(localized: "The notch opens on \(shown.title). Press to unlock: it opens on the dashboard again") }
        if let locked { return String(localized: "Open the notch on \(shown.title) (now: \(locked.title))") }
        return String(localized: "Open the notch on \(shown.title) every time, not the dashboard")
    }

    /// The dashboard tab goes back to the dashboard; any other tab opens its full view. Ask AI also puts the cursor in its input.
    private func open(_ kind: WorkspaceKind) {
        if kind == .askAI { AskAINotchFocus.shared.request() }
        withAnimation(Theme.quick) {
            if kind == .nook { navigator.collapse() } else { navigator.expand(kind) }
        }
    }
}

/// A tab icon in the header: a click opens it.
struct NotchTabButton: View {
    let kind: WorkspaceKind
    let selected: Bool
    var width: CGFloat = 27
    /// The lock key keeps this tab as the one the notch opens on: the key wears a tiny lock.
    var locked = false
    let action: () -> Void

    var body: some View {
        NotchIconButton(symbol: kind.symbol, selected: selected, help: locked ? String(localized: "\(kind.title): the notch opens on it") : kind.title, width: width,
                        badge: locked ? "lock.fill" : nil, action: action)
    }
}

/// A tab or gear key in the header: a small beveled plastic key. Raised at rest; the selected one is pressed in and lit in the
/// palette. 24 pt tall, at most 27 pt wide, so every tab still fits on both sides of the camera.
struct NotchIconButton: View {
    let symbol: String
    var selected = false
    var help: String
    var width: CGFloat = 27
    /// A tiny glyph in the key's corner (the lock on the tab the notch opens on).
    var badge: String?
    /// A key that cannot be used now draws dim and ignores clicks.
    var enabled = true
    /// Pictures and tests: draw the key as if the pointer were on it (true) or not (false).
    var hoverPreview: Bool? = nil
    var action: () -> Void
    @State private var hover = false

    /// The look of a key: the selected one is pressed in.
    static func bevel(selected: Bool) -> RetroBevelStyle { selected ? .sunken : .raised }

    /// The colour of the plastic: a lit teal for the selected key, dark plastic for the rest (a touch lighter under the pointer).
    static func face(selected: Bool, hover: Bool) -> Color {
        if Look.isLight {   // the light preset's plastic: pale teal for the selected key, warm cream for the rest
            return selected ? Retro.shade(Retro.Ink.teal, 0.62) : Retro.shade(Color(red: 0.90, green: 0.86, blue: 0.78), hover ? 0.30 : 0)
        }
        return selected ? Retro.shade(Retro.Ink.teal, -0.58) : Retro.shade(Retro.Ink.plasticDark, hover ? 0.10 : 0)
    }

    var body: some View {
        let lit = hoverPreview ?? hover
        Button(action: action) {
            LookSymbol(name: symbol, size: 12, weight: .semibold)
                .foregroundStyle(selected ? Look.teal : Look.ink(lit ? 0.85 : 0.62))
                .shadow(color: selected && !Look.isLight ? Retro.Ink.teal.opacity(0.6) : .clear, radius: 2.5)
                .frame(width: width, height: 24)
                .overlay(alignment: .bottomTrailing) {
                    if let badge {
                        Image(systemName: badge).font(.system(size: 6, weight: .heavy)).foregroundStyle(Look.teal)
                            .padding(.trailing, 3).padding(.bottom, 2.5)
                    }
                }
                .offset(y: selected && lit ? 0.5 : 0)
                .modifier(NotchKeyFace(lit: lit, selected: selected))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.38)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A header key's face: flat solid black like the notch at rest, the 90s plastic key (pressed in when it is the tab on show) only while the
/// pointer is on it.
/// The tab on show keeps its teal icon at rest.
private struct NotchKeyFace: ViewModifier {
    let lit: Bool
    let selected: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if lit {
            content.retroBevel(NotchIconButton.bevel(selected: selected), cornerRadius: 5, depth: 1.25, face: NotchIconButton.face(selected: selected, hover: true))
        } else {
            content.background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Look.surface))   // the open notch's own surface
        }
    }
}

/// Gallery only: draw the header as if the lock key kept `locked` (nil: no lock), whatever the setting says.
struct NotchLockPreview {
    var locked: WorkspaceKind?
}

private struct NotchLockPreviewKey: EnvironmentKey {
    static let defaultValue: NotchLockPreview? = nil
}

extension EnvironmentValues {
    var notchLockPreview: NotchLockPreview? {
        get { self[NotchLockPreviewKey.self] }
        set { self[NotchLockPreviewKey.self] = newValue }
    }
}
