import SwiftUI

// Settings keys of the notch (the notch code prefix `notch.*`, `nook.*`).

enum NotchStyle: String, CaseIterable, Identifiable {
    case classic, glass
    var id: String { rawValue }
    var title: String { self == .classic ? String(localized: "Classic") : String(localized: "Glass") }
}

enum NotchScreenMode: String, CaseIterable, Identifiable {
    case main, all, notched
    var id: String { rawValue }
    var title: String {
        switch self {
        case .main: String(localized: "Main display")
        case .all: String(localized: "All displays")
        case .notched: String(localized: "Only displays with a notch")
        }
    }
}

enum NotchHover: String, CaseIterable, Identifiable {
    case open, details, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .open: String(localized: "Open the notch")
        case .details: String(localized: "Show what's happening")
        case .off: String(localized: "Nothing (click to open)")
        }
    }
}

enum NotchPrefs {
    static var style: NotchStyle { NotchStyle(rawValue: Pref.string("notch.style", "classic")) ?? .classic }
    static var screens: NotchScreenMode { NotchScreenMode(rawValue: Pref.string("notch.screens", "main")) ?? .main }
    static var virtualNotch: Bool { Pref.bool("notch.virtual", true) }
    static var hover: NotchHover { NotchHover(rawValue: Pref.string("notch.hover", "open")) ?? .open }
    static var hoverDelay: Double { max(0, min(1.5, Pref.double("notch.hoverDelay", 0.15))) }
    static var clickToOpen: Bool { Pref.bool("notch.clickToOpen", true) }
    static var openWidth: Double { Pref.double("notch.openWidth", 1040) }
    /// Always 180 pt: the height is automatic now, the dashboard grows by whole rows when its widgets need them.
    /// A workspace that needs more room still opens taller (`minimumOpenHeight`).
    static var openHeight: Double { Self.defaultOpenHeight }
    /// The open notch's height from the start.
    static let defaultOpenHeight: Double = 180
    static var haptics: Bool { Pref.bool("notch.haptics", true) }
    static var hideInFullscreen: Bool { Pref.bool("notch.hideInFullscreen", true) }
    static var gestures: Bool { Pref.bool("notch.gestures", true) }
    static var gestureInvert: Bool { Pref.bool("notch.gestureInvert", false) }
    /// A widget with a detail opens by itself when the pointer rests on it (the old Settings switch read "Open a widget when the pointer rests on it").

    static let widthRange: ClosedRange<Double> = 680...1300
    static let heightRange: ClosedRange<Double> = 180...420   // no longer a setting (the height is automatic); kept for the pictures
    /// Extra height the Nook gets in edit mode (the palette of other widgets).
    static let editExtra: CGFloat = 58

    /// The open notch grows to at least this height for a workspace whose content needs more room than the
    /// height setting gives. Calendar (the calendar and the to-dos in one view): the header 32, 6 above and 16 below, and the view's own
    /// 10 + 10 padding; that leaves 326 pt. Wide, the to-do column has its heading, the add field and six rows; narrow, the month and the
    /// agenda take 166, the rule and gaps 17, and the to-dos under them their heading and three rows of two (the old To-dos view had 410).
    /// Tray: the empty drop box with its two lines of text needs the default 200.
    static func minimumOpenHeight(for kind: WorkspaceKind) -> CGFloat {
        switch merged(kind) {
        case .calendar: calendarHeight
        case .tray: 200
        case .clipboard: 240   // the search row and the 118 pt cards (230 fits; a taller menu bar needs a little more); without it a lower notch cut the cards (owner's picture, 2026-11-15)
        case .notes: 240
        case .radio: 320   // the sidebar, the search row, five station rows and the player bar
        case .mirror: 380   // the face needs room: a 16:9 picture about 570 pt wide and 320 high under the header
        // The 8-bit Agents den: never shorter than the whole room, whatever happened to its height request
        // An open agent's window asks for more on top.
        case .agents: Retro.is8bit ? AgentDenLayout.islandHeight() : 0
        default: 0
        }
    }

    // The old "workspaces" list (icons along the header) is gone: every detail can open from its panel, a hotkey, the ring or
    // the island's right-click menu, and which PANELS show is the dashboard's layout (Edit Nook). These keep older callers working.

    /// Every detail this edition has (they are all enabled; the saved `notch.workspaces` list of older versions is ignored).
    static var workspaces: [WorkspaceKind] { WorkspaceKind.available }

    static func parseWorkspaces(_ raw: String) -> [WorkspaceKind] { WorkspaceKind.available }

    /// The height the merged Calendar view (the calendar and the to-dos) needs; see `minimumOpenHeight(for:)`.
    /// The Calendar's own minimum: the month with the header (166 + 74); the view asks for more when the day's events or to-dos need it,
    /// and for `calendarTallHeight` when the to-dos stand under the month.
    static let calendarHeight: CGFloat = 240
    /// The merged view's tallest: the to-dos under the month (a narrow island), or a busy day.
    static let calendarTallHeight: CGFloat = 400

    /// The view that took over for `kind`: the To-dos view is part of the Calendar now,
    /// so everything that names the To-dos (a panel, a hotkey, a saved lock, a saved tab list) means the Calendar.
    static func merged(_ kind: WorkspaceKind) -> WorkspaceKind { kind == .todo ? .calendar : kind }

    /// What the island shows for `wanted`: itself when this edition has it, the dashboard otherwise (the To-dos are in the Calendar).
    static func resolve(_ wanted: WorkspaceKind) -> WorkspaceKind {
        let kind = merged(wanted)
        return kind.isAvailable ? kind : .nook
    }

    // MARK: Tabs (the icons along the open notch's header, left of the camera; back at the owner's word, 2026-11-15)

    /// Kinds that came after a tab list could be saved: they join a saved list at the end until the person edits the list.
    private static let newerTabs: [WorkspaceKind] = [.notes, .radio, .mirror]   // Mirror stays last

    /// The owner's order.
    static let frontTabs: [WorkspaceKind] = [.nook, .agents, .askAI, .calendar, .clipboard]
    static let defaultTabOrder: [WorkspaceKind] = frontTabs + [.prompter, .music, .notes, .terminal, .radio, .mirror]

    /// Views that never get a tab in the header. The Tray stays a dashboard panel; a click on it
    /// still opens it. The To-dos are in the Calendar tab now; their panel, hotkey and lock
    /// open the Calendar (`merged`). A saved tab list that has one of them loses it too.
    static let notTabs: Set<WorkspaceKind> = [.tray, .todo]

    /// Every tab this edition has, in the default order.
    static var allTabsInOrder: [WorkspaceKind] {
        let ordered = defaultTabOrder.filter { $0.isAvailable && !notTabs.contains($0) }
        return ordered + WorkspaceKind.available.filter { !ordered.contains($0) && !notTabs.contains($0) }
    }

    /// Once: a saved tab list takes the owner's order (those five first, the rest as they were).
    static func applyDefaultTabOrderOnce() {
        guard !Pref.bool("notch.tabOrder2", false) else { return }
        Pref.set(true, "notch.tabOrder2")
        let raw = Pref.string("notch.workspaces", "")
        guard !raw.isEmpty else { return }
        let list = parseTabs(raw, edited: Pref.bool("notch.tabsEdited", false))
        let front = frontTabs.filter { list.contains($0) }
        Pref.set((front + list.filter { !front.contains($0) }).map(\.rawValue).joined(separator: ","), "notch.workspaces")
    }

    /// The header's tab icons in order, from `notch.workspaces` (the same list older versions kept; empty = every one).
    static var tabs: [WorkspaceKind] { parseTabs(Pref.string("notch.workspaces", ""), edited: Pref.bool("notch.tabsEdited", false)) }

    static func parseTabs(_ raw: String, edited: Bool) -> [WorkspaceKind] {
        let saved = raw.split(separator: ",").compactMap { WorkspaceKind(rawValue: String($0)) }
        // A saved To-dos tab is the Calendar now: it takes the To-dos' place when the list has no Calendar tab of its own (else it just goes).
        let named = saved.compactMap { $0 == .todo ? (saved.contains(.calendar) ? nil : .calendar) : $0 }
        let parsed = named.filter { $0.isAvailable && !notTabs.contains($0) }
        var seen = Set<WorkspaceKind>()
        var list = parsed.filter { seen.insert($0).inserted }
        if raw.isEmpty || list.isEmpty { return allTabsInOrder }
        if !edited { list += newerTabs.filter { $0.isAvailable && !list.contains($0) } }
        return list
    }

    static func saveTabs(_ list: [WorkspaceKind]) {
        guard !list.isEmpty else { return }
        Pref.set(list.map(\.rawValue).joined(separator: ","), "notch.workspaces")
        Pref.set(true, "notch.tabsEdited")
    }

    // MARK: The tab the notch opens on

    static let lockedTabKey = "notch.lockedTab"

    /// Tabs the lock key cannot keep. The Mirror starts the camera the moment it shows, and a pointer brushing the notch must never do that.
    static func canLock(_ kind: WorkspaceKind) -> Bool { kind.isAvailable && kind != .mirror && kind != .todo }

    /// The tab a saved lock (`raw`) keeps as the one the notch opens on; nil = no lock (or one this edition cannot keep). A lock saved on the
    /// To-dos keeps the Calendar, where the to-dos are now.
    static func lockedTab(raw: String) -> WorkspaceKind? {
        guard let saved = WorkspaceKind(rawValue: raw) else { return nil }
        let kind = merged(saved)
        return canLock(kind) ? kind : nil
    }

    /// The tab the lock key keeps; nil = the notch opens on the dashboard.
    static var lockedTab: WorkspaceKind? { lockedTab(raw: Pref.string(lockedTabKey, "")) }

    /// What a plain opening of the notch (the pointer, a click, a swipe, the menu) shows first: the locked tab, else the dashboard.
    static var openingWorkspace: WorkspaceKind { lockedTab ?? .nook }

    /// The lock key on `kind`, the tab on show: it keeps `kind` as the opening tab (an older lock moves here), and when `kind` already is
    /// the locked one it lets go, so the notch opens on the dashboard again.
    static func toggleLock(on shown: WorkspaceKind) {
        let kind = merged(shown)
        if lockedTab == kind { Pref.set(nil, lockedTabKey) }
        else if canLock(kind) { Pref.set(kind.rawValue, lockedTabKey) }
    }
}
