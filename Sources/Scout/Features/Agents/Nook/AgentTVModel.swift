import SwiftUI

// Agent TV. This file is the logic only: which room the channel display shows,
// what the set shows at each width, where the den's spots are, what the window shows by the real hour. The drawing is in
// AgentNookPanelView (the set), AgentTVConsole (the wide set), AgentDenArt / AgentDenView / AgentDenWindow (the den).

// MARK: - The set's channel

/// The channel display of the set: "CH 02 NOTES" for the room in focus.
enum AgentTVChannel {
    struct Pick: Equatable {
        /// 1 is the first room (the one that needs you sorts first).
        var channel: Int
        var id: String
        var project: String
    }

    /// The room in focus: the first that needs you, else the busiest of the working ones (most helpers, then most to-dos left,
    /// then the one that sorts first), else the first room.
    static func focus(_ models: [AgentNookRoomModel]) -> Pick? {
        guard !models.isEmpty else { return nil }
        func pick(_ i: Int) -> Pick { Pick(channel: i + 1, id: models[i].id, project: models[i].project) }
        if let i = models.firstIndex(where: { $0.look == .needsYou }) { return pick(i) }
        var best: Int?
        for i in models.indices where models[i].look == .working {
            if let b = best, score(models[i]) <= score(models[b]) { continue }
            best = i
        }
        return pick(best ?? 0)
    }

    private static func score(_ m: AgentNookRoomModel) -> Int { m.helpers * 100 + max(0, m.todoTotal - m.todoDone) }

    /// "CH 02": two digits, like a set's own display.
    static func channelText(_ channel: Int) -> String { String(format: "CH %02d", min(99, max(0, channel))) }

    /// The ON AIR lamp is lit while any agent needs you.
    static func onAir(_ models: [AgentNookRoomModel]) -> Bool { models.contains { $0.look == .needsYou } }
}

// MARK: - The set at every width

/// What the set shows at a panel width (3 to 16 cells, 140 pt tall): how big the glass is, how many rooms stand on it and how big they
/// are. Up to 9 cells the kit's `CRTSet` is the body; from 10 cells on (500 pt) it is a wide console with a speaker at the left.
enum AgentTVLayout {
    static let height: CGFloat = NookMetrics.widgetHeight
    /// From this width the set is the wide console (10 cells).
    static let wideFrom: CGFloat = 500
    /// The wide console's control strip at the right, and the speaker at the left (it grows with the panel).
    static let consoleStrip: CGFloat = 84
    static let consoleSpeakerMin: CGFloat = 40
    /// From this much speaker on, the console has two (one each side of the glass), otherwise one at the left.
    static let twoSpeakersFrom: CGFloat = 100
    static let consoleBezel: CGFloat = 6
    static let consoleMask = CRTSetLayout.maskThickness
    /// The widest glass of the console; any more width goes to the speaker.
    static let glassMax: CGFloat = 540

    /// The OSD band along the top of the glass, and the margin the rooms keep from the glass edge.
    static let band: CGFloat = 16
    static let margin: CGFloat = 3

    struct Plan: Equatable {
        var wide: Bool
        var glass: CGRect
        /// The wide console's speaker (left) and control strip (right); zero for the kit's set.
        var speaker: CGFloat
        var strip: CGFloat
        /// The space the rooms have on the glass.
        var rooms: CGSize
        var style: AgentNookLayout.Style
        var shown: Int
        var more: Int
        var roomWidth: CGFloat
    }

    static func width(cells: Int) -> CGFloat { AgentNookLayout.width(cells: cells) }

    /// The glass of the set, in the panel's own space.
    static func glass(panelWidth w: CGFloat) -> (rect: CGRect, speaker: CGFloat, strip: CGFloat) {
        if w >= wideFrom {
            let bezel = consoleBezel, mask = consoleMask
            let avail = w - 2 * bezel - consoleStrip - 6   // the well between the speaker and the strip
            let glassWell = min(glassMax + 2 * mask, avail - consoleSpeakerMin)
            let speaker = avail - glassWell
            let x = bezel + leftSpeaker(speaker) + mask
            return (CGRect(x: x, y: bezel + mask, width: glassWell - 2 * mask, height: height - 2 * bezel - 2 * mask), speaker, consoleStrip)
        }
        let layout = CRTSetLayout(size: CGSize(width: w, height: height), compact: false)
        return (layout.screen, 0, 0)
    }

    /// The left speaker's share of the console's speaker width (the rest is the right one).
    static func leftSpeaker(_ total: CGFloat) -> CGFloat { total >= twoSpeakersFrom ? total / 2 : total }

    static func plan(panelWidth w: CGFloat, count: Int) -> Plan {
        let g = glass(panelWidth: w)
        let rooms = CGSize(width: max(0, g.rect.width - 2 * margin), height: max(0, g.rect.height - band - 2 * margin))
        let p = AgentNookLayout.plan(rowWidth: rooms.width, count: count)
        return Plan(wide: w >= wideFrom, glass: g.rect, speaker: g.speaker, strip: g.strip, rooms: rooms, style: p.style, shown: p.shown, more: p.more, roomWidth: p.roomWidth)
    }
}

// MARK: - The den

/// What the den shows for one agent: the room's look, plus how long a finished task took.
struct AgentDenStation: Identifiable, Equatable {
    var room: AgentNookRoomModel
    var tookSeconds: TimeInterval?
    var id: String { room.id }

    init(_ s: AgentSession) {
        room = AgentNookRoomModel(s)
        if room.look == .finished || room.look == .stopped, let end = s.finishedAt {
            tookSeconds = max(0, end.timeIntervalSince(s.turnStartedAt))
        } else {
            tookSeconds = nil
        }
    }

    /// One station per agent, in the one fixed order the set's rooms and the faces use (the first started on the left).
    static func stations(_ sessions: [AgentSession]) -> [AgentDenStation] {
        AgentTileMetrics.ordered(sessions).map(AgentDenStation.init)
    }

    /// How long the task took, as the digits for the TV's screen and the unit on its cabinet: "12" "MIN", "45" "SEC", "2" "HRS".
    static func took(_ seconds: TimeInterval) -> (digits: String, unit: String) {
        let s = Int(seconds.rounded())
        if s < 60 { return (String(s), "SEC") }
        let minutes = s / 60
        if minutes < 100 { return (String(minutes), "MIN") }
        return (String(min(99, Int((Double(minutes) / 60).rounded()))), "HRS")
    }
}

/// Where an agent stands in the den (the footprint is the picture and the name plate under it).
struct AgentDenSpot: Equatable {
    var index: Int
    var rect: CGRect
    /// The size of one pixel of this station, a multiple of half a point.
    var px: CGFloat
    /// 0 is the front row (the one that needs you stands there first), 1 the back row.
    var row: Int
}

/// The den's layout: how big the room is, and where 1 to 9 agents stand without turning into a crowd.
enum AgentDenLayout {
    /// A station is 44 x 36 cells of its own pixel size: the picture (the floor is row 27), a floor row under it for the helpers; the
    /// name plate is added under that.
    static let cells = (w: 44, h: 36)
    static let plateHeight: CGFloat = 22
    static let wallHeight: CGFloat = 242
    /// The stations stand in a band that starts below the wall's decoration.
    static let bandTop: CGFloat = 120
    /// The rug's inner frame (the gold border is inside the rug's edge): stations stay inside it, so none stands on the fringe.
    static let rugEdgeCells = 9
    static let rugBorderCells = 4
    static let sideMargin: CGFloat = CGFloat(rugEdgeCells + rugBorderCells) * AgentDenArt.roomCell + 6
    static let bottomMargin: CGFloat = CGFloat(2 + rugBorderCells) * AgentDenArt.roomCell
    static let gapMax: CGFloat = 10
    static let gapMin: CGFloat = 2
    static let maxPixel: CGFloat = 5
    static let minPixel: CGFloat = 1

    /// The den's height in a notch, and what the island adds around it (header, the gaps above and under the view).
    static let baseHeight: CGFloat = 360
    static let chrome: CGFloat = 59
    static let windowWidth: CGFloat = 410
    static let windowMargin: CGFloat = 8
    /// Between the last station and the window.
    static let windowGap: CGFloat = 12

    /// With an agent open, its window lies UNDER the den across the whole width:
    /// this much more.
    static let drawerHeight: CGFloat = 250
    /// The shortest the window under the den may be before the den gives up some of its own height (a short screen).
    static let shortestWindow: CGFloat = 160

    /// The island height (header included) for the den, with a bit more when the window shows a banner.
    static func islandHeight(extra: CGFloat = 0) -> CGFloat { baseHeight + extra + chrome }

    /// The room the island gives the den when it spends `inset` points on its header and the gaps above and under the view (`notchBodyInset`;
    /// nil in a picture or a test with no island: the base height). The island is asked for `baseHeight + chrome`, but the den fills the island
    /// edge to edge under a header that is shorter than `chrome` (the old gaps around a framed den), so more than `baseHeight` is left.
    /// The island itself keeps its height; the den is laid out to everything it gives.
    static func fillHeight(inset: CGFloat?) -> CGFloat { baseHeight + max(0, chrome - (inset ?? chrome)) }

    /// `height` cut down to whole cells of the room's pixel (`AgentDenArt.roomCell`): the room is drawn in whole cells, so the rug's border ends
    /// exactly `bottomMargin` above the bottom edge and no cell is cut in half there. The few points left over (less than one cell) stay above the room.
    static func wholeCells(_ height: CGFloat) -> CGFloat { ((height + 0.01) / AgentDenArt.roomCell).rounded(.down) * AgentDenArt.roomCell }   // 0.01: a height a hair under a whole number of cells counts as that number

    /// What the window shows needs more height: the banner of an automatic opening.
    static func extraHeight(banner: Bool) -> CGFloat { banner ? 36 : 0 }

    /// The width of the window for a den this wide (narrower dens give it less).
    static func windowWidth(for width: CGFloat) -> CGFloat { min(windowWidth, max(300, width * 0.46)) }

    /// The right edge of the free floor: the whole rug, or what is left of the window (nothing is ever drawn under it).
    static func rightEdge(width: CGFloat, window: Bool) -> CGFloat {
        window ? width - windowWidth(for: width) - windowMargin - windowGap : width - sideMargin
    }

    /// The helpers on a station's floor row: how many are drawn (up to four) and how many are left for the "+N", so that the row, with
    /// the "+N" in pixel digits, fits the 44 cells.
    static func helperRow(count: Int) -> (drawn: Int, more: Int) {
        guard count > 0 else { return (0, 0) }
        var drawn = min(4, count)
        while drawn > 1 {
            let more = count - drawn
            let need = drawn * 9 - 1 + (more > 0 ? 1 + AgentPixel.textWidth("+\(more)") : 0)
            if need <= cells.w - 2 { break }
            drawn -= 1
        }
        return (drawn, count - drawn)
    }

    /// Where a station's helpers stand: right under their agent, the row centred on the agent's figure (its head's middle, in the state's
    /// own picture) and the first row under its body: for a standing agent that is the row under its feet, for the one at its desk and the
    /// one on its beanbag (no feet) the row under the body, in front of the furniture: the helpers win the place. Cells of the station.
    /// `gap` is the space between two helpers: 1, and 2 when an even number stands (so the row is an even number of cells wide and its middle
    /// is a cell edge, like the figure's). `top` is the helpers' row at rest: awake helpers (they hop a row up) rest one row lower, so a
    /// hop never lands on the agent. `label` is where the "+N" starts; a row that would leave the station is shifted to stay inside, the
    /// "+N" with it.
    static func helperSpot(look: AgentNookLook, drawn: Int, more: Int) -> (left: Int, top: Int, gap: Int, label: Int, width: Int) {
        guard drawn > 0 else { return (0, 0, 1, 0, 0) }
        let place = AgentDenArt.pictureOrigin(look), box = AgentPixelWorld.figureBox(look)
        let middle = place.x + box.x + AgentPixelSprites.figureWidth / 2
        let gap = drawn % 2 == 0 ? 2 : 1
        let width = drawn * 8 + (drawn - 1) * gap
        let tail = more > 0 ? 2 + AgentPixel.textWidth("+\(more)") : 0   // the "+N" and its space
        let left = max(1, min(middle - width / 2, cells.w - 1 - width - tail))
        let top = place.y + box.y + box.h + (look == .working ? 1 : 0)
        return (left, top, gap, left + width + 2, width)
    }

    /// The spots of `count` agents in a den `size` big, on the floor between `sideMargin` and `rightEdge`. One row when that gives bigger
    /// pixels, two rows otherwise; the first agents (the ones that need you) stand in the front row.
    static func spots(count: Int, size: CGSize, rightEdge: CGFloat? = nil) -> [AgentDenSpot] {
        guard count > 0 else { return [] }
        let left = sideMargin
        let right = max(left + 40, min(size.width - sideMargin, rightEdge ?? (size.width - sideMargin)))
        let top = bandTop, bottom = size.height - bottomMargin
        // The pixel size and the back row are the base den's (a den taller than that, which the island's full height makes, stands a single or
        // front row lower on its longer floor and keeps the sizes; a back row stays where it stood, at the foot of the wall).
        let baseBottom = min(size.height, baseHeight) - bottomMargin
        let bandH = max(80, baseBottom - top)
        let usableW = right - left
        let cw = CGFloat(cells.w), ch = CGFloat(cells.h)

        func fit(columns: Int, rows: Int, gap: CGFloat) -> CGFloat {
            let byWidth = (usableW - CGFloat(columns - 1) * gap) / (CGFloat(columns) * cw)
            let rowHeight = (bandH - CGFloat(rows - 1) * 4) / CGFloat(rows) - plateHeight
            let byHeight = rowHeight / ch
            return min(maxPixel, (min(byWidth, byHeight) * 2).rounded(.down) / 2)
        }
        func best(columns: Int, rows: Int) -> (px: CGFloat, gap: CGFloat) {
            let wide = fit(columns: columns, rows: rows, gap: gapMax)
            if wide >= minPixel { return (wide, gapMax) }
            return (max(0.5, fit(columns: columns, rows: rows, gap: gapMin)), gapMin)
        }
        let one = best(columns: count, rows: 1)
        let frontCount = (count + 1) / 2
        let two = count >= 2 ? best(columns: frontCount, rows: 2) : (px: CGFloat(0), gap: gapMax)
        let rows = two.px > one.px ? 2 : 1
        let chosen = rows == 1 ? one : two
        let px = chosen.px, gap = chosen.gap

        let w = cw * px, h = ch * px + plateHeight
        var out: [AgentDenSpot] = []
        func place(_ indices: [Int], row: Int, bottomY: CGFloat) {
            let n = indices.count
            let total = CGFloat(n) * w + CGFloat(n - 1) * gap
            var x = left + (usableW - total) / 2
            for i in indices {
                out.append(AgentDenSpot(index: i, rect: CGRect(x: x, y: bottomY - h, width: w, height: h), px: px, row: row))
                x += w + gap
            }
        }
        if rows == 1 {
            place(Array(0..<count), row: 0, bottomY: bottom)
        } else {
            place(Array(0..<frontCount), row: 0, bottomY: bottom)
            place(Array(frontCount..<count), row: 1, bottomY: baseBottom - h - 4)
        }
        return out.sorted { $0.index < $1.index }
    }

    /// True when no spot touches another and every spot is inside the room and between `sideMargin` and `rightEdge`.
    static func isValid(_ spots: [AgentDenSpot], in size: CGSize, rightEdge: CGFloat? = nil) -> Bool {
        let room = CGRect(origin: .zero, size: size)
        let right = rightEdge ?? (size.width - sideMargin)
        for (i, a) in spots.enumerated() {
            guard room.contains(a.rect), a.rect.minX >= sideMargin - 0.5, a.rect.maxX <= right + 0.5 else { return false }
            for b in spots.dropFirst(i + 1) where a.rect.intersects(b.rect) { return false }
        }
        return true
    }
}

// MARK: - The window and the clock

/// The window shows day or night by the real hour; the wall clock shows the real time.
enum AgentDenSky {
    /// Day from 7 in the morning until 7 in the evening.
    static func isDay(hour: Int) -> Bool { (7..<19).contains(hour) }

    static func hour(of date: Date, calendar: Calendar = .current) -> Int { calendar.component(.hour, from: date) }

    static func isDay(_ date: Date, calendar: Calendar = .current) -> Bool { isDay(hour: hour(of: date, calendar: calendar)) }

    /// The hands of the wall clock in degrees from 12 o'clock, clockwise.
    static func clockAngles(_ date: Date, calendar: Calendar = .current) -> (hour: Double, minute: Double) {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let h = Double((c.hour ?? 0) % 12), m = Double(c.minute ?? 0)
        return ((h + m / 60) * 30, m * 6)
    }
}

/// A fixed moment for pictures and tests (the den reads the real time otherwise).
private struct AgentDenTimeKey: EnvironmentKey { static let defaultValue: Date? = nil }

extension EnvironmentValues {
    /// A fixed time for the den's window and wall clock; nil is the real time (a gallery picture sets it).
    var agentDenTime: Date? {
        get { self[AgentDenTimeKey.self] }
        set { self[AgentDenTimeKey.self] = newValue }
    }
}
