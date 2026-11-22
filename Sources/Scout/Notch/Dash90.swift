import SwiftUI

// The 90s language of the dashboard (R3), built only from the kit in Core/Retro: an LCD window, an LCD checkbox, a floppy disk,
// an LED bar that fills one colour (progress, battery), a scope trace on CRT glass, keys, and the colour each panel wears.
// Everything draws still: nothing here moves by itself. Readable first: long words stay in the system font.

private struct Dash90EditingKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True while the dashboard is in Edit Nook: a panel with a title at its top-left keeps clear of the red remove key.
    var dash90Editing: Bool {
        get { self[Dash90EditingKey.self] }
        set { self[Dash90EditingKey.self] = newValue }
    }
}

enum Dash90 {
    /// The face of an LCD window and of every sunken field and list box on the dashboard: dark glass in the dark preset (a plain dark well in
    /// the minimal look), the one light well in the light preset (`Look.well`).
    static var lcdFace: Color { Look.well(dark: Retro.is8bit ? Color(red: 0.035, green: 0.055, blue: 0.045) : Color(white: 0.075)) }
    /// The two screen inks: phosphor amber and green in the 8-bit look, soft white in the minimal one (numbers carry no colour there). They
    /// follow the colour scheme of the well they are drawn in: the phosphor colours themselves on dark glass, their deeper shade (`Look.accent`)
    /// on the light well.
    static var amber: Color { Retro.is8bit ? Look.accent(Retro.Ink.phosphorAmber) : Look.ink(0.92) }
    static var green: Color { Retro.is8bit ? Look.accent(Retro.Ink.phosphorGreen) : Look.ink(0.92) }
    /// The corner radius of every dashboard panel's plastic face (the kit's panel radius).
    static let radius = RetroPanelModifier.radius
    /// The open notch's one surface: the island and every panel share this colour, so the dashboard reads as ONE SCREEN, and it is
    /// black.
    /// Only the pointer lights a panel up.
    static var screen: Color { Look.surface }   // black in the dark preset; the light preset's warm paper (Core/Retro/ScoutLook.swift)

    /// The colour a dashboard panel wears in its title bar (and the label stripe of panels that have no title bar).
    @MainActor static func tint(_ item: NookItem) -> Color {
        switch item {
        case .panel(let kind): tint(kind)
        case .tab: Retro.Ink.purple
        case .nowPlaying: Retro.Ink.magenta
        case .live(let id):
            switch id {
            case "live.recording": Retro.Ink.red
            case "live.meeting": Retro.Ink.teal
            case "live.timer": Retro.Ink.orange
            case "live.downloads": Retro.Ink.teal
            case "live.bluetooth": Retro.Ink.purple
            case "live.todos": Retro.Ink.purple
            default: Retro.Ink.magenta
            }
        }
    }

    /// The label stripe along the top of a panel: none any more.
    @MainActor static func stripe(_ item: NookItem) -> Color? { nil }

    static func tint(_ kind: WidgetKind) -> Color {
        switch kind {
        case .agents, .weather, .clipboard, .quickApps: Retro.Ink.teal
        case .askAI, .volume: Retro.Ink.lime
        case .pulse: Retro.Ink.teal
        case .today, .notes: Retro.Ink.yellow
        case .calendar, .media, .aiUsage: Retro.Ink.magenta
        case .mirror, .todo, .shortcuts, .prompter: Retro.Ink.purple
        case .timer, .tray: Retro.Ink.orange
        case .pomodoro: Retro.Ink.red
        }
    }

    /// A Pulse reading split for LCD digits: the number as segment text and its unit as pixel letters. "37%" is ("37", "%"),
    /// "2.3 MB/s" is ("2.3", "MB/S"), and a sensor that reports nothing ("—") is ("--", "").
    static func segmentReading(_ headline: String) -> (digits: String, unit: String) {
        let t = headline.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("%") {
            let n = String(t.dropLast())
            return (n.allSatisfy { SevenSegment.supported.contains($0) } && !n.isEmpty ? n : "--", "%")
        }
        let parts = t.split(separator: " ", maxSplits: 1).map(String.init)
        guard let first = parts.first, !first.isEmpty, first.allSatisfy({ SevenSegment.supported.contains($0) }) else { return ("--", "") }
        return (first, parts.count > 1 ? parts[1].uppercased() : "")
    }

    /// The colour of a Pulse metric's digits (soft white in the minimal look; the bars keep their colours). On the light preset's paper the
    /// phosphor colours take their deeper shade (`Look.accent`), like every accent written on the surface, so the digits read as well as the
    /// text beside them; in a dark scheme they are the phosphor colours themselves.
    static func pulseColor(_ metric: PulseMetric) -> Color {
        if !Retro.is8bit { return Look.ink(0.92) }
        return switch metric {
        case .cpu: Look.accent(Retro.Ink.phosphorGreen)
        case .memory: Look.accent(Retro.Ink.phosphorAmber)
        case .gpu: Look.teal
        case .disk: Look.yellow
        case .battery: Look.accent(Retro.Ink.ledGreen)
        case .network: Look.teal
        }
    }

    /// The two screen inks for a readout written straight on the open notch's surface (Today's time and rows): `amber` and `green`, in their
    /// deeper shade on the light preset's paper (`Look.accent`; inside a screen, `.lookScreen()`, they stay the phosphor colours).
    static var surfaceAmber: Color { Retro.is8bit ? Look.accent(Retro.Ink.phosphorAmber) : Look.ink(0.92) }
    static var surfaceGreen: Color { Retro.is8bit ? Look.accent(Retro.Ink.phosphorGreen) : Look.ink(0.92) }
    /// The CPU and memory traces on the surface (the phosphor green, deeper on paper).
    static var traceGreen: Color { Look.accent(Retro.Ink.phosphorGreen) }

    /// The colour of a battery or level that is good when it is high: green, yellow at 40 % and below, red at 20 % and below.
    static func goodWhenHigh(_ percent: Int) -> Color {
        percent <= 20 ? Retro.Ink.ledRed : (percent <= 40 ? Retro.Ink.ledYellow : Retro.Ink.ledGreen)
    }

    /// True when the pixel font draws every character of the text as written
    static func pixelSafe(_ text: String) -> Bool { text.allSatisfy { LEDFont.drawsAsWritten($0) } }

    /// The text for pixel letters: capitals (a character the font lacks stays as it is and draws blank, so callers check `pixelSafe`).
    static func pixel(_ text: String) -> String { text.uppercased() }

    /// Capitals for pixel letters, cut to `maxChars` with a "." at the end when too long.
    static func clipped(_ text: String, maxChars: Int) -> String {
        let t = text.uppercased()
        return t.count <= maxChars ? t : String(t.prefix(max(1, maxChars - 1))) + "."
    }
}

// MARK: - The dashboard's one grid

/// The one grid every dashboard panel follows, in both looks, both presets and every Size (the Size setting scales the whole open notch,
/// so these points hold at every size). The 8-bit Agent TV is a picture of its own and the only exception.
///
/// The rows, from the panel's top edge (a panel without a readout starts its list at `inset.top`):
///   row 1, the READOUT  (8…32):  big numbers (CPU and memory, the clock), `digitHeight` tall, their labels and units on the digits' baseline.
///   row 2, the INFO LINE (36…49): one line in `infoFont` (Today's date).
///   the BODY            (55…132): the panel's list (meetings and to-dos).
/// CPU & Memory keeps row 1 and then has its own order (the owner, 2026-11-17: the graphs under their readings, under them the SSD, under
/// it the network): each reading's graph right under it at 36 pt (it stretches), then the SSD and battery line (the info font), then the
/// network line as the panel's last line, on the bottom inset.
/// A list row is `rowHeight` tall, one line, its title in `rowTitle`. "+N more" is `DashMore`, an empty list says so with `DashEmpty`.
enum DashGrid {
    /// The room between a panel's edge and its content: 8 pt top and bottom, 10 pt at the sides (where every title's name starts).
    static let inset = EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
    /// Row 1: the readout's height, and the height of its seven-segment digits (one size in every panel).
    static let readoutHeight: CGFloat = 24
    static let digitHeight: CGFloat = 24
    /// The gap between the readout and the info line.
    static let readoutGap: CGFloat = 4
    /// Row 2: the info line's height.
    static let infoHeight: CGFloat = 13
    /// The gap between the info line and the body.
    static let bodyGap: CGFloat = 6
    /// A list row (a meeting, a to-do, an agent): one line this tall.
    static let rowHeight: CGFloat = 22
    /// The "+N more" line.
    static let moreHeight: CGFloat = 11
    /// A control bar at a panel's bottom (the Ask AI question line): its field and keys are this tall in both looks.
    static let controlHeight: CGFloat = 26
    /// In Edit Nook a panel's first line moves this far right, clear of the red remove key (the titles do the same).
    static let editClearance: CGFloat = 20

    /// Where the info line starts, from the panel's top edge (36).
    static var infoTop: CGFloat { inset.top + readoutHeight + readoutGap }
    /// Where the body starts, from the panel's top edge (55).
    static var bodyTop: CGFloat { infoTop + infoHeight + bodyGap }
    /// How tall the body is in a 140 pt panel (77).
    static var bodyHeight: CGFloat { NookMetrics.widgetHeight - bodyTop - inset.bottom }

    /// The info line's font (the same in both looks: long words stay readable), its first word or figure in `.semibold`.
    static func infoFont(_ weight: Font.Weight = .medium) -> Font { .system(size: 10.5, weight: weight).monospacedDigit() }
    /// The small symbol that leads an info item (a drive, a battery).
    static let infoSymbolSize: CGFloat = 9.5
    /// A list row's title (a meeting, a to-do, an agent's project) and its quieter text beside it.
    static let rowTitle = Font.system(size: 12, weight: .semibold)
    static let rowText = Font.system(size: 11)
    /// The labels beside the digits ("CPU", "MEMORY") and their units ("%", "PM"): pixel letters this size in the 8-bit look.
    static let labelPixel: CGFloat = 1
    /// The ink of a label beside the digits.
    static var labelInk: Color { Look.osd.opacity(0.85) }
}

/// Row 1 of a panel: the readout, `DashGrid.readoutHeight` tall, its pieces standing on one baseline (the digits' bottom in the 8-bit look, the
/// text baseline in the minimal one).
struct DashReadout<Content: View>: View {
    /// False for a readout whose first piece stands clear of the remove key anyway (CPU & Memory's three readings: the labels sit on the digits'
    /// baseline, under the key).
    var clearsRemoveKey = true
    @ViewBuilder var content: () -> Content
    @Environment(\.dash90Editing) private var editing

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 3) { content() }
            .reportBaseline("readout.baseline", .lastTextBaseline)
            .padding(.leading, editing && clearsRemoveKey ? DashGrid.editClearance : 0)   // Edit Nook: clear of the red remove key, like a title
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: DashGrid.readoutHeight, alignment: .bottomLeading)
            .reportDashRow("readout")
    }
}

/// Row 2 of a panel: one line in the info font, quiet ink, `DashGrid.infoHeight` tall.
struct DashInfoLine<Content: View>: View {
    var spacing: CGFloat = 4
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) { content() }
            .reportBaseline("info.baseline", .firstTextBaseline)
            .font(DashGrid.infoFont())
            .foregroundStyle(NotchInk.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: DashGrid.infoHeight, alignment: .leading)
            .reportDashRow("info")
    }
}

/// The big digits of a readout, `DashGrid.digitHeight` tall: LCD segments in the 8-bit look, the rounded system digits in the minimal one (the
/// same font and size in every panel, so the CPU, the memory and the clock read as one set). The minimal digits are never shrunk to the row's
/// height and take their own width (one width for every digit, so a reading that changes keeps its place; a name at their left stays put).
struct DashDigits: View {
    let text: String
    var height: CGFloat = DashGrid.digitHeight
    var color: Color

    var body: some View {
        if Retro.is8bit {
            SevenSegmentText(text, height: height, color: color)
        } else {
            Text(text).font(.system(size: height * 1.15, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(color)
                .lineLimit(1).fixedSize()
                .frame(height: height)
        }
    }
}

/// A label beside the digits ("CPU", "MEMORY"): pixel letters in the 8-bit look, the system font in the minimal one; one size and ink everywhere.
struct DashLabel: View {
    let text: String
    var color: Color = DashGrid.labelInk

    init(_ text: String, color: Color = DashGrid.labelInk) {
        self.text = text
        self.color = color
    }

    var body: some View { Dash90Text(text, pixel: DashGrid.labelPixel, color: color) }
}

/// "+3 more" under a list, the same in every panel: the info font in the faint ink.
struct DashMore: View {
    let count: Int

    var body: some View {
        Text("+\(count) more").font(DashGrid.infoFont()).foregroundStyle(NotchInk.tertiary).lineLimit(1)
            .frame(height: DashGrid.moreHeight, alignment: .leading)
    }
}

/// An empty list, said in its first row's place (top-left, where the list would start), the same in every panel and both looks: a small
/// symbol and a line in the row font, a quieter line under it. ("No agents running", "No questions yet", "Nothing left today".)
struct DashEmpty: View {
    let symbol: String
    let title: LocalizedStringKey
    var detail: LocalizedStringKey?
    /// A key under the lines when there is something to do about it ("Use my location", "Choose shortcuts").
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?
    @Environment(\.dash90Editing) private var editing

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(NotchInk.tertiary).frame(width: 14)
                Text(title).font(DashGrid.rowTitle).foregroundStyle(NotchInk.secondary).lineLimit(1)
            }
            .padding(.leading, editing ? DashGrid.editClearance : 0)   // Edit Nook: clear of the red remove key
            .frame(height: DashGrid.rowHeight, alignment: .leading)
            if let detail {
                Text(detail).font(DashGrid.infoFont()).foregroundStyle(NotchInk.tertiary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.retro(compact: true)).lineLimit(1).nookControl()
                    .padding(.leading, 20).padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .reportDashRow("empty")
    }
}

/// Where the grid's rows are drawn, by name ("readout", "info", "empty"), in the `dashpanel` space a self-test gives a panel: the dashboard
/// self-test checks that the rows of different panels stand on the same lines.
struct DashRowKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { a, _ in a } }
}

extension View {
    /// Reports this row's frame in the `dashpanel` space under `name` (nothing happens outside a self-test's panel).
    func reportDashRow(_ name: String) -> some View {
        background(GeometryReader { proxy in Color.clear.preference(key: DashRowKey.self, value: [name: proxy.frame(in: .named("dashpanel"))]) })
    }

    /// Reports this view's text baseline (`guide`) as the bottom edge of a 1 pt mark standing on it, under `name`.
    func reportBaseline(_ name: String, _ guide: VerticalAlignment) -> some View {
        overlay(alignment: Alignment(horizontal: .leading, vertical: guide)) {
            Color.clear.frame(width: 1, height: 1).reportDashRow(name).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

// MARK: - The title strip of a panel

/// A panel's title: only text, no bar, no stripes, no colour.
/// The name in a quiet neutral ink (pixel capitals in the 8-bit style, the system
/// font otherwise), with a short fact (or any small view) at its right. 20 pt tall. In Edit Nook it keeps clear of the red remove key.
/// A narrow panel (a live panel squeezed to 3 cells) never lets the line spill out: it drops the fact, then uses the `short` title.
/// `symbol` and `tint` are kept so older callers still compile; the title draws neither.
struct Dash90Title<Trailing: View>: View {
    let title: String
    var short: String?
    var symbol: String?
    var tint: Color
    let trailing: Trailing
    @Environment(\.dash90Editing) private var editing

    /// `Dash90Title("Today", ...)` localizes a literal (the key is the English title); `Dash90Title(verbatim: name, ...)` shows a finished string.
    init(_ title: String.LocalizationValue, short: String.LocalizationValue? = nil, symbol: String? = nil, tint: Color, @ViewBuilder trailing: () -> Trailing) {
        self.init(verbatim: String(localized: title), short: short.map { String(localized: $0) }, symbol: symbol, tint: tint, trailing: trailing)
    }

    init(verbatim title: String, short: String? = nil, symbol: String? = nil, tint: Color, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.short = short
        self.symbol = symbol
        self.tint = tint
        self.trailing = trailing()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(title, withFact: true)
            line(title, withFact: false)
            line(short ?? title, withFact: false)
        }
    }

    /// One header line, the same height in every panel and every look, its name at the same place:
    /// the name sits in a fixed box at the top-left, the fact at the right is centred on it
    /// and can never make the line taller.
    private func line(_ text: String, withFact: Bool) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Group {
                if Retro.is8bit && Dash90.pixelSafe(text) {   // a title the pixel font cannot draw (Greek, Russian…) uses the system font
                    RetroPixelText(Dash90.pixel(text), pixel: 1.5, color: Retro.quietInk)
                } else {
                    Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Retro.quietInk).lineLimit(1).fixedSize()
                }
            }
            .frame(height: 14, alignment: .leading)
            Spacer(minLength: 4)
            if withFact { trailing.frame(maxHeight: RetroTitleBar<EmptyView>.barHeight) }
        }
        .padding(.leading, editing ? 22 : 2)
        .padding(.trailing, 2)
        .frame(height: RetroTitleBar<EmptyView>.barHeight)
    }
}

extension Dash90Title where Trailing == EmptyView {
    init(_ title: String.LocalizationValue, short: String.LocalizationValue? = nil, symbol: String? = nil, tint: Color) {
        self.init(title, short: short, symbol: symbol, tint: tint) { EmptyView() }
    }

    init(verbatim title: String, short: String? = nil, symbol: String? = nil, tint: Color) {
        self.init(verbatim: title, short: short, symbol: symbol, tint: tint) { EmptyView() }
    }
}

extension Dash90Title where Trailing == RetroPixelText {
    /// A title with a short fact at its right in pixel letters.
    init(_ title: String.LocalizationValue, short: String.LocalizationValue? = nil, symbol: String? = nil, tint: Color, fact: String, factColor: Color = Retro.Ink.osdWhite) {
        self.init(title, short: short, symbol: symbol, tint: tint) { RetroPixelText(Dash90.pixel(fact), pixel: 1, color: factColor) }
    }
}

/// Seven-segment digits at the tallest of three heights that fits the width given (a clock in a panel squeezed to 3 cells uses a smaller one).
struct Dash90Digits: View {
    let text: String
    var big: CGFloat = 28
    var color: Color = Dash90.amber
    var ghost = true

    var body: some View {
        ViewThatFits(in: .horizontal) {
            SevenSegmentText(text, height: big, color: color, ghost: ghost)
            SevenSegmentText(text, height: (big * 0.78).rounded(), color: color, ghost: ghost)
            SevenSegmentText(text, height: (big * 0.6).rounded(), color: color, ghost: ghost)
        }
    }
}

/// A red lamp with its word, in pixel letters ("1 OVERDUE", "ON AIR"): the kit's LED red, still.
struct Dash90Lamp: View {
    let text: String
    var color: Color = Retro.Ink.ledRed

    /// `Dash90Lamp(text: "now")` localizes a literal; `Dash90Lamp(verbatim: word)` shows a finished string.
    init(text: String.LocalizationValue, color: Color = Retro.Ink.ledRed) { self.text = String(localized: text); self.color = color }
    init(verbatim: String, color: Color = Retro.Ink.ledRed) { self.text = verbatim; self.color = color }

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
                .shadow(color: color.opacity(Retro.is8bit ? 0.8 : 0), radius: 2.5)
            if Dash90.pixelSafe(text) { RetroPixelText(Dash90.pixel(text), pixel: 1, color: color) }
            else { Text(text.uppercased()).font(.system(size: 7, weight: .bold)).foregroundStyle(color).lineLimit(1).fixedSize() }
        }
        .padding(.horizontal, 3).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 2, style: .circular).fill(Look.isLight ? Look.paper.opacity(0.85) : Color.black.opacity(0.72)))   // a chip red reads on: dark in the dark preset, paper in the light one
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// Pixel capitals when the font has every letter, the system font when it has not (a Greek month, an accented name).
struct Dash90Text: View {
    let text: String
    var pixel: CGFloat
    var color: Color

    init(_ text: String, pixel: CGFloat = 1.5, color: Color = Retro.Ink.osdWhite) {
        self.text = text
        self.pixel = pixel
        self.color = color
    }

    var body: some View {
        if Dash90.pixelSafe(text) {
            RetroPixelText(text.uppercased(), pixel: pixel, color: color)
        } else {
            Text(text.uppercased()).font(.system(size: pixel * 6, weight: .semibold)).foregroundStyle(color).lineLimit(1)
        }
    }
}

// MARK: - LCD window, checkbox, floppy, LED bar, scope

/// An LCD window: sunken, with a faint sheen; dark glass in the dark preset, the light well in the light one. Put segments, pixel letters and
/// system text on it.
struct Dash90LCD<Content: View>: View {
    var padding: CGFloat = 6
    var radius: CGFloat = 4
    /// True: the window takes the height it is given (a list that fills the rest of the panel).
    var fill = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        if Retro.is8bit {
            content()
                .lookWell()   // dark glass with light inks in the dark preset; the light preset's light well with dark inks
                .padding(padding)
                .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
                .retroBevel(.sunken, cornerRadius: radius, depth: 1.2, face: Dash90.lcdFace)
        } else {
            // The minimal look: no grey well. The content lies on the one screen like every panel's.
            // its first letters on the panel's inset.
            content()
                .padding(.horizontal, 2).padding(.vertical, padding)
                .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        }
    }
}

extension View {
    /// A dashboard text field's face: the kit's sunken bevel on the well face (`Dash90.lcdFace`, dark in the dark preset, the light well in the light
    /// one). In the minimal look under the light preset it is the soft white field the other minimal fields wear (`miniCard`), not a grey box.
    @ViewBuilder func dash90Field(cornerRadius: CGFloat = 4, depth: CGFloat = 1.2) -> some View {
        if Look.isLight, !Retro.is8bit {
            lookWell().miniCard(radius: cornerRadius + 3)
        } else {
            lookWell().retroBevel(.sunken, cornerRadius: cornerRadius, depth: depth, face: Dash90.lcdFace)
        }
    }
}

/// A little square LCD box for a to-do: a dark window with a thin lit frame inside when open, a lit tick when done.
struct Dash90Box: View {
    var checked = false
    var tint: Color = Dash90.green
    var size: CGFloat = 14

    var body: some View {
        if Retro.is8bit { lcdBox } else {
            Image(systemName: checked ? "checkmark.square.fill" : "square").font(.system(size: size * 0.95, weight: .regular))
                .foregroundStyle(checked ? Theme.accent : Look.ink(0.5)).frame(width: size, height: size)
                .accessibilityLabel(checked ? "Done" : "Open")
        }
    }

    private var lcdBox: some View {
        Canvas { ctx, s in
            let u = s.width / 14
            if checked {
                var tick = Path()
                tick.move(to: CGPoint(x: 3.2 * u, y: 7.4 * u))
                tick.addLine(to: CGPoint(x: 5.9 * u, y: 10.0 * u))
                tick.addLine(to: CGPoint(x: 10.8 * u, y: 3.8 * u))
                ctx.stroke(tick, with: .color(tint.opacity(0.28)), style: StrokeStyle(lineWidth: 3.6 * u, lineCap: .square, lineJoin: .miter))
                ctx.stroke(tick, with: .color(tint), style: StrokeStyle(lineWidth: 1.9 * u, lineCap: .square, lineJoin: .miter))
            } else {
                ctx.stroke(Path(CGRect(x: 3.5 * u, y: 3.5 * u, width: 7 * u, height: 7 * u)), with: .color(tint.opacity(0.55)), lineWidth: max(1, 1.1 * u))
            }
        }
        .frame(width: size, height: size)
        .retroBevel(.sunken, cornerRadius: 2, depth: 1, face: Dash90.lcdFace)
        .accessibilityLabel(checked ? "Done" : "Open")
    }
}

/// A 3.5 inch floppy disk drawn in code: body with a cut corner, the metal shutter, the label and the write-protect notch.
struct Dash90Floppy: View {
    var tint: Color = Retro.Ink.teal
    var size: CGFloat = 30

    var body: some View {
        if Retro.is8bit { disk } else {
            Image(systemName: "arrow.down.circle").font(.system(size: size * 0.8, weight: .regular)).foregroundStyle(tint)
                .frame(width: size, height: size).accessibilityHidden(true)
        }
    }

    private var disk: some View {
        Canvas { ctx, s in
            let u = s.width / 30
            let r = 2.6 * u
            var body = Path()
            body.move(to: CGPoint(x: r, y: 0))
            body.addLine(to: CGPoint(x: 24.5 * u, y: 0))
            body.addLine(to: CGPoint(x: 30 * u, y: 5.5 * u))
            body.addLine(to: CGPoint(x: 30 * u, y: 30 * u - r))
            body.addQuadCurve(to: CGPoint(x: 30 * u - r, y: 30 * u), control: CGPoint(x: 30 * u, y: 30 * u))
            body.addLine(to: CGPoint(x: r, y: 30 * u))
            body.addQuadCurve(to: CGPoint(x: 0, y: 30 * u - r), control: CGPoint(x: 0, y: 30 * u))
            body.addLine(to: CGPoint(x: 0, y: r))
            body.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
            ctx.fill(body, with: .linearGradient(Gradient(colors: [Retro.shade(tint, -0.20), Retro.shade(tint, -0.52)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: s.height)))
            ctx.stroke(body, with: .color(Retro.shade(tint, -0.70)), lineWidth: 1)
            // The metal shutter, with its window.
            let shutter = CGRect(x: 6.5 * u, y: 0, width: 17 * u, height: 10 * u)
            ctx.fill(Path(shutter), with: .linearGradient(Gradient(colors: [Color(white: 0.88), Color(white: 0.58)]), startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: 10 * u)))
            ctx.fill(Path(CGRect(x: 16.5 * u, y: 1.8 * u, width: 4.2 * u, height: 6.4 * u)), with: .color(Color(white: 0.16)))
            // The label.
            let label = CGRect(x: 4 * u, y: 15.5 * u, width: 22 * u, height: 14.5 * u)
            ctx.fill(Path(label), with: .color(Retro.Ink.osdWhite.opacity(0.92)))
            for row in 0..<3 {
                ctx.fill(Path(CGRect(x: 6.5 * u, y: (19 + 3.2 * CGFloat(row)) * u, width: (row == 2 ? 9 : 17) * u, height: 1.1 * u)), with: .color(tint.opacity(0.75)))
            }
            // The write-protect notch.
            ctx.fill(Path(CGRect(x: 2 * u, y: 25 * u, width: 2 * u, height: 3 * u)), with: .color(Color.black.opacity(0.6)))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A row of LED segments in one colour (progress, battery): lit ones glow, unlit ones stay faintly visible. `color` picks each
/// segment's colour from its index and the count, so a level can change colour (battery) or stay one colour (progress).
struct Dash90LEDBar: View {
    let value: Double
    var segments = 10
    var size: CGSize
    var color: (Int, Int) -> Color = { _, _ in Retro.Ink.ledGreen }

    var body: some View {
        if Retro.is8bit { ledBody } else {
            // The minimal look: a slim rounded bar that fills to the value, in the colour its last lit segment would have.
            let v = min(1, max(0, value.isNaN ? 0 : value))
            let lit = RetroLEDBar.litCount(value: value, segments: segments)
            let thick = min(5, size.height)
            ZStack(alignment: .leading) {
                Capsule().fill(Look.ink(0.12))
                Capsule().fill(color(max(0, lit - 1), max(1, segments))).frame(width: max(thick, size.width * v), height: thick).opacity(v > 0 ? 1 : 0)
            }
            .frame(width: size.width, height: thick).frame(width: size.width, height: size.height)
            .accessibilityLabel("Level \(Int((v * 100).rounded())) percent")
        }
    }

    private var ledBody: some View {
        let lit = RetroLEDBar.litCount(value: value, segments: segments)
        return Canvas { ctx, canvas in
            guard segments > 0 else { return }
            let inset: CGFloat = 2, gap: CGFloat = 1.5
            let length = canvas.width - 2 * inset
            let thick = canvas.height - 2 * inset
            let seg = (length - gap * CGFloat(segments - 1)) / CGFloat(segments)
            guard seg > 0.5, thick > 0.5 else { return }
            for i in 0..<segments {
                let rect = CGRect(x: inset + CGFloat(i) * (seg + gap), y: inset, width: seg, height: thick)
                let c = color(i, segments)
                ctx.fill(Path(rect), with: .color(i < lit ? c : c.opacity(0.15)))
                if i < lit {
                    ctx.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(1, thick / 4))), with: .color(Color.white.opacity(0.35)))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .retroBevel(.sunken, cornerRadius: 2, depth: 1, face: Look.well(dark: Color(red: 0.045, green: 0.05, blue: 0.05)))   // the track: dark in the dark preset, the light well in the light one
        .accessibilityLabel("Level \(Int((min(1, max(0, value)) * 100).rounded())) percent")
    }
}

/// A kit LED meter that takes the width it is given (the kit's bar wants a fixed size).
struct Dash90FlexBar: View {
    let value: Double
    var segments = 10
    var height: CGFloat = 11

    var body: some View {
        GeometryReader { geo in
            RetroLEDBar(value: value, segments: segments, size: CGSize(width: geo.size.width, height: height))
        }
        .frame(height: height)
    }
}

/// A history trace: only the green line, straight on the panel.
/// The newest value is at the right.
struct Dash90Scope: View {
    let values: [Double]
    var color: Color = Retro.Ink.phosphorGreen
    var historyLength = 40

    var body: some View {
        Canvas { ctx, s in
            guard values.count > 1 else { return }
            let step = s.width / CGFloat(max(2, historyLength - 1))
            let offset = s.width - step * CGFloat(values.count - 1)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: offset + CGFloat(i) * step, y: s.height - 3 - CGFloat(min(1, max(0, v))) * (s.height - 6))
            }
            var line = Path()
            line.move(to: pts[0])
            pts.dropFirst().forEach { line.addLine(to: $0) }
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: Retro.is8bit ? 1.4 : 1.2, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Time as segments

/// A time of day as LCD segment text: `digits` ("12:41", " 9:05" in 12-hour countries, "21:07" in 24-hour ones) and the AM/PM that goes
/// with it (nil in 24-hour countries). Every character of `digits` is one the seven-segment font can light.
enum Dash90Time {
    struct Parts: Equatable {
        var digits: String
        var meridiem: String?

        /// The digits with a small "A" or "P" after them, the way a pocket LCD clock shows the half of the day.
        var withLetter: String { digits + (meridiem == "PM" ? "P" : (meridiem == "AM" ? "A" : "")) }

        /// `withLetter` without the blank cell in front of a one-digit hour, for lists where the times line up at the right.
        var trimmed: String { withLetter.trimmingCharacters(in: .whitespaces) }
    }

    static func parts(_ date: Date, locale: Locale = .current, calendar: Calendar = .current) -> Parts {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let hour = c.hour ?? 0, minute = c.minute ?? 0
        let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "HH"
        if template.contains("a") {
            let h = hour % 12 == 0 ? 12 : hour % 12
            return Parts(digits: String(format: "%2d:%02d", h, minute), meridiem: hour < 12 ? "AM" : "PM")
        }
        return Parts(digits: String(format: "%02d:%02d", hour, minute), meridiem: nil)
    }
}

// MARK: - Keys

/// A square-ish plastic key for an icon (transport, send, pause): raised, sunken while pressed. `lit` glows in the tint.
struct Dash90KeyStyle: ButtonStyle {
    var tint: Color = Retro.Ink.plasticMid
    var width: CGFloat = 26
    var height: CGFloat = 22
    var lit = false

    func makeBody(configuration: Configuration) -> some View {
        Dash90KeyBody(configuration: configuration, tint: tint, width: width, height: height, lit: lit)
    }
}

private struct Dash90KeyBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    let width: CGFloat
    let height: CGFloat
    let lit: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let pressed = configuration.isPressed
        let minimal = !Retro.is8bit
        let quiet = minimal && tint == Retro.Ink.plasticMid   // the plain grey key becomes a quiet dark one with a light label
        let base = quiet ? Color(white: 0.2) : tint
        let face = pressed ? Retro.shade(base, -0.14) : base
        let ink = quiet ? Color.white.opacity(0.9) : (Retro.isLight(tint) ? Color(red: 0.08, green: 0.08, blue: 0.09) : Retro.Ink.osdWhite)
        configuration.label
            .font(.system(size: 10.5, weight: minimal ? .semibold : .heavy))
            .foregroundStyle(ink)
            .frame(width: width, height: height)
            .offset(y: pressed && !minimal ? 0.75 : 0)
            .retroBevel(pressed ? .sunken : .raised, cornerRadius: minimal ? 6 : 4, depth: 1.25, face: face)
            .shadow(color: lit && !minimal ? tint.opacity(0.55) : .clear, radius: 3)
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.45)
    }
}

extension ButtonStyle where Self == Dash90KeyStyle {
    static func dash90Key(tint: Color = Retro.Ink.plasticMid, width: CGFloat = 26, height: CGFloat = 22, lit: Bool = false) -> Dash90KeyStyle {
        Dash90KeyStyle(tint: tint, width: width, height: height, lit: lit)
    }
}

// MARK: - The panel face

extension View {
    /// A dashboard panel's face: the open notch's own colour (`Dash90.screen`), flat, with no edge and no stripe, so the panels and the
    /// island are one surface. `tint` is kept for older callers.
    func nookPanelFace(tint: Color? = nil) -> some View {
        modifier(NookFaceFill())
    }
}

/// The panel's fill: the notch's own colour on the classic notch; nothing on the glass one, so the glass shows through every panel like
/// through the island.
private struct NookFaceFill: ViewModifier {
    @AppStorage("notch.style") private var style = NotchStyle.classic.rawValue

    func body(content: Content) -> some View {
        content
            .background(style == NotchStyle.glass.rawValue ? Color.clear : Dash90.screen)
            .clipShape(RoundedRectangle(cornerRadius: Dash90.radius, style: .circular))
    }
}

extension ButtonStyle where Self == RetroButtonStyle {
    /// A grey plastic key, the small one when `compact`.
    static func retro(compact: Bool) -> RetroButtonStyle { RetroButtonStyle(compact: compact) }
}
