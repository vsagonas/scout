import SwiftUI

// The Mirror as a 90s camcorder's viewfinder (our own drawing, no real brand): corner marks, "LIVE" (never "REC": nothing is recorded,
// and the app says so), the date and time stamp in orange digits, the zoom level while zoomed, FROZEN while frozen, a battery glyph
// when this Mac has a battery. All of it is drawn OVER the picture as an on-screen display that never takes a click, and none of
// it sits in the middle of the picture. The no-access screens get a CRT frame with "NO SIGNAL" static (a still texture).

/// What the viewfinder says, as plain data (the drawing and the self-test read the same thing).
struct MirrorOSD: Equatable {
    enum Item: Equatable {
        case live
        case frozen
        case zoom(String)
        case battery(level: Int, charging: Bool)
        case stamp(date: String, time: String)
        case sample
    }

    var items: [Item]

    /// The items for a state: LIVE while the picture is live (FROZEN instead while a frame is held: it is not live then), the zoom
    /// level only while zoomed, the battery only when the Mac has one, the stamp always, and "sample" for a drawn stand-in picture.
    static func make(frozen: Bool, scale: CGFloat, battery: BatteryState?, date: Date, standIn: Bool, calendar: Calendar = .current) -> MirrorOSD {
        var items: [Item] = [frozen ? .frozen : .live]
        if let label = zoomLabel(scale) { items.append(.zoom(label)) }
        if let battery { items.append(.battery(level: min(100, max(0, battery.level)), charging: battery.isPluggedIn)) }
        let parts = stamp(date, calendar: calendar)
        items.append(.stamp(date: parts.date, time: parts.time))
        if standIn { items.append(.sample) }
        return MirrorOSD(items: items)
    }

    /// "2X" while zoomed, "1.5X" for a step in between; nil at 1×.
    static func zoomLabel(_ scale: CGFloat) -> String? {
        guard scale >= 1.05 else { return nil }
        return abs(scale - scale.rounded()) < 0.05 ? "\(Int(scale.rounded()))X" : String(format: "%.1fX", scale)
    }

    /// "2026-11-15" and "22:41" (24 hours, so it never needs AM or PM).
    static func stamp(_ date: Date, calendar: Calendar = .current) -> (date: String, time: String) {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return (String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0), String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0))
    }

    /// Every word the display draws in pixel letters (the self-test checks LIVE is there and REC never is).
    var words: [String] {
        items.compactMap { item in
            switch item {
            case .live: "LIVE"
            case .frozen: pixelLabel("FROZEN")
            case .zoom(let label): label
            case .battery, .stamp, .sample: nil
            }
        }
    }

    /// The date a gallery picture shows.
    static var sampleDate: Date {
        DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 11, day: 15, hour: 22, minute: 41).date ?? Date(timeIntervalSince1970: 1_800_000_000)
    }
}

// MARK: - The display

struct MirrorViewfinderOSD: View {
    let osd: MirrorOSD
    /// The mini viewfinder of the dashboard panel: smaller marks, smaller letters, no date.
    var compact = false
    /// The panel can be a circle: the marks follow it.
    var circle = false

    /// A picture narrower than this (the whole-picture setting, a small tab) lifts the stamp above the toolbar, which is centred at the bottom.
    static let narrowWidth: CGFloat = 760

    var body: some View {
        if Retro.is8bit { viewfinder } else { minimal }
    }

    /// The minimal look: no viewfinder (no corner marks, no LIVE, no date stamp, no battery). Only the facts that change what you see stay, as
    /// small quiet labels: FROZEN while a frame is held, the zoom level while zoomed, and "Sample picture" over a drawn stand-in.
    private var minimal: some View {
        let frozen = osd.items.contains(.frozen)
        var zoom: String?
        for case .zoom(let label) in osd.items { zoom = label }
        let sample = osd.items.contains(.sample)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 4) {
                    if frozen { miniTag("Frozen", symbol: "pause.fill") }
                    if sample { miniTag(compact ? "Sample" : "Sample picture", symbol: nil) }
                }
                Spacer(minLength: 4)
                if let zoom { miniTag(.verbatim(zoom.replacingOccurrences(of: "X", with: "×").lowercased()), symbol: nil) }
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? 8 : 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(osd.words.joined(separator: ", "))
    }

    private func miniTag(_ text: LocalizedStringKey, symbol: String?) -> some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: compact ? 6.5 : 8, weight: .bold)) }
            Text(text).font(.system(size: compact ? 8.5 : 10.5, weight: .semibold)).lineLimit(1).fixedSize()
        }
        .foregroundStyle(Color.white.opacity(0.92))
        .padding(.horizontal, compact ? 5 : 7).padding(.vertical, compact ? 2 : 3)
        .background(Capsule().fill(Color.black.opacity(0.45)))
    }

    private var viewfinder: some View {
        GeometryReader { geo in
            let narrow = !compact && geo.size.width < Self.narrowWidth
            ZStack {
                // No corner marks in the Camera tab; the
                // dashboard panel's small viewfinder keeps its little ones.
                if compact { MirrorCornerMarks(inset: 7, arm: 9, circle: circle) }
                VStack(spacing: 0) {
                    if compact && circle {
                        // A round panel is narrow at the top: LIVE sits in the middle there, and the clock and the sample note stay off.
                        leadingItems.frame(maxWidth: .infinity)
                    } else {
                        HStack(alignment: .top, spacing: 8) {
                            leading
                            Spacer(minLength: 4)
                            trailing
                        }
                    }
                    Spacer(minLength: 0)
                    if !compact {
                        HStack(alignment: .bottom) {
                            stamp
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(compact ? EdgeInsets(top: circle ? 14 : 11, leading: circle ? 30 : 13, bottom: 10, trailing: circle ? 30 : 13)
                                 : EdgeInsets(top: 24, leading: 26, bottom: narrow ? 66 : 22, trailing: 26))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(osd.words.joined(separator: ", "))
    }

    private var pixel: CGFloat { compact ? 1.25 : 2 }

    private var leading: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            leadingItems
            if osd.items.contains(.sample) {
                Text(compact ? "Sample" : "Sample picture").font(.system(size: compact ? 8 : 9, weight: .medium)).foregroundStyle(Color.white.opacity(0.62))
                    .shadow(color: .black.opacity(0.6), radius: 1)
            }
        }
    }

    @ViewBuilder private var leadingItems: some View {
        ForEach(Array(osd.items.enumerated()), id: \.offset) { _, item in
            switch item {
            case .live:
                HStack(spacing: compact ? 3 : 5) {
                    Circle().fill(Retro.Ink.ledRed).frame(width: compact ? 5 : 8, height: compact ? 5 : 8)
                        .shadow(color: Retro.Ink.ledRed.opacity(0.8), radius: compact ? 2 : 3)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 0.8))
                    RetroOSD("LIVE", pixel: pixel, color: Retro.Ink.osdWhite)
                }
            case .frozen:
                HStack(spacing: compact ? 3 : 5) {
                    HStack(spacing: compact ? 1.5 : 2) {
                        Rectangle().frame(width: compact ? 2 : 3, height: compact ? 6 : 9)
                        Rectangle().frame(width: compact ? 2 : 3, height: compact ? 6 : 9)
                    }
                    .foregroundStyle(Retro.Ink.yellow)
                    .shadow(color: .black.opacity(0.7), radius: 0.5)
                    RetroOSD(pixelLabel("FROZEN"), pixel: pixel, color: Retro.Ink.yellow)
                }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: compact ? 4 : 8) {
            ForEach(Array(osd.items.enumerated()), id: \.offset) { _, item in
                switch item {
                case .zoom(let label):
                    RetroOSD(label, pixel: pixel, color: Retro.Ink.yellow)
                case .battery(let level, let charging):
                    MirrorBatteryGlyph(level: level, charging: charging, width: compact ? 15 : 24)
                case .stamp where compact:
                    stamp   // the mini viewfinder keeps its clock at the top, out of the way of the keys
                default:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder private var stamp: some View {
        ForEach(Array(osd.items.enumerated()), id: \.offset) { _, item in
            if case .stamp(let date, let time) = item {
                if compact {
                    SevenSegmentText(time, height: 9, color: Retro.Ink.orange, ghost: false)
                        .shadow(color: .black.opacity(0.8), radius: 0.8)
                } else {
                    ViewThatFits(in: .horizontal) {
                        SevenSegmentText(date + " " + time, height: 14, color: Retro.Ink.orange, ghost: false).fixedSize()
                        SevenSegmentText(time, height: 14, color: Retro.Ink.orange, ghost: false).fixedSize()
                    }
                    .shadow(color: .black.opacity(0.8), radius: 1)
                }
            }
        }
    }
}

/// Four corner marks like a viewfinder's frame (or four short arcs on a round panel), white with a dark edge so they show over any picture.
struct MirrorCornerMarks: View {
    var inset: CGFloat = 14
    var arm: CGFloat = 16
    var circle = false

    var body: some View {
        Canvas { ctx, size in
            guard size.width > inset * 2 + arm, size.height > inset * 2 + arm else { return }
            var p = Path()
            if circle {
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = min(size.width, size.height) / 2 - inset
                for k in 0..<4 {
                    let mid = Double(k) * 90 + 45
                    // Each arc is its own piece: move to its start first, or the pieces join up in one line.
                    let a0 = (mid - 13) * .pi / 180
                    p.move(to: CGPoint(x: c.x + r * cos(a0), y: c.y + r * sin(a0)))
                    p.addArc(center: c, radius: r, startAngle: .degrees(mid - 13), endAngle: .degrees(mid + 13), clockwise: false)
                }
            } else {
                let x0 = ctx.snapped(inset), y0 = ctx.snapped(inset), x1 = ctx.snapped(size.width - inset), y1 = ctx.snapped(size.height - inset)
                for (x, y, dx, dy) in [(x0, y0, 1.0, 1.0), (x1, y0, -1.0, 1.0), (x0, y1, 1.0, -1.0), (x1, y1, -1.0, -1.0)] {
                    p.move(to: CGPoint(x: x + dx * arm, y: y))
                    p.addLine(to: CGPoint(x: x, y: y))
                    p.addLine(to: CGPoint(x: x, y: y + dy * arm))
                }
            }
            ctx.stroke(p, with: .color(Color.black.opacity(0.65)), style: StrokeStyle(lineWidth: 3.4, lineCap: .square, lineJoin: .miter))
            ctx.stroke(p, with: .color(Retro.Ink.osdWhite.opacity(0.92)), style: StrokeStyle(lineWidth: 1.7, lineCap: .square, lineJoin: .miter))
        }
        .allowsHitTesting(false)
    }
}

/// A battery glyph for the display: an outline with a tip, filled to the level in LED green, yellow or red, and a bolt while plugged in.
struct MirrorBatteryGlyph: View {
    let level: Int
    let charging: Bool
    var width: CGFloat = 24

    /// The LED colour of a level.
    static func color(level: Int) -> Color {
        level > 35 ? Retro.Ink.ledGreen : (level > 15 ? Retro.Ink.ledYellow : Retro.Ink.ledRed)
    }

    var body: some View {
        let height = width * 0.46
        Canvas { ctx, size in
            let body = CGRect(x: 0.5, y: 0.5, width: size.width - 3.5, height: size.height - 1)
            let line = Retro.Ink.osdWhite.opacity(0.95)
            ctx.stroke(Path(roundedRect: body.insetBy(dx: -1.2, dy: -1.2), cornerRadius: 2), with: .color(Color.black.opacity(0.65)), lineWidth: 1.2 + 2)
            ctx.stroke(Path(roundedRect: body, cornerRadius: 1.5), with: .color(line), lineWidth: 1.2)
            ctx.fill(Path(CGRect(x: body.maxX + 0.6, y: size.height * 0.3, width: 1.8, height: size.height * 0.4)), with: .color(line))
            let inner = body.insetBy(dx: 2, dy: 2)
            let fill = CGRect(x: inner.minX, y: inner.minY, width: inner.width * CGFloat(min(100, max(0, level))) / 100, height: inner.height)
            ctx.fill(Path(fill), with: .color(Self.color(level: level)))
            if charging {
                let c = CGPoint(x: body.midX, y: body.midY)
                var bolt = Path()
                bolt.move(to: CGPoint(x: c.x + 1.2, y: c.y - 3.4))
                bolt.addLine(to: CGPoint(x: c.x - 2, y: c.y + 0.6))
                bolt.addLine(to: CGPoint(x: c.x, y: c.y + 0.6))
                bolt.addLine(to: CGPoint(x: c.x - 1.2, y: c.y + 3.4))
                bolt.addLine(to: CGPoint(x: c.x + 2, y: c.y - 0.6))
                bolt.addLine(to: CGPoint(x: c.x, y: c.y - 0.6))
                bolt.closeSubpath()
                ctx.fill(bolt, with: .color(Color.black.opacity(0.85)))
            }
        }
        .frame(width: width, height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(charging ? Text("Battery \(level) percent, plugged in") : Text("Battery \(level) percent"))
    }
}

// MARK: - No picture: NO SIGNAL

/// Where "NO SIGNAL" static is welcome: the screens that say there is no picture to see (the camera is off or not allowed, no camera
/// found). Never over a running picture, and not while the camera is starting.
enum MirrorSignalRule {
    static func showsStatic(for state: MirrorModel.State) -> Bool {
        switch state {
        case .stopped, .denied, .noCamera: true
        case .starting, .running: false
        }
    }
}

/// What the Mirror shows when there is no picture to show: a CRT glass with "NO SIGNAL" static (a still texture, never flickering) behind a
/// plastic plate that holds the message and the one key. `static` false draws a dark glass instead (the camera is starting).
struct MirrorNoSignal<Plate: View>: View {
    /// The word in pixel letters (`pixelLabel("NO SIGNAL")`). `showsStatic` false means the camera is starting.
    var title: String
    var showsStatic = true
    var cornerRadius: CGFloat = 22
    /// The dashboard panel's small version.
    var compact = false
    /// False puts the contents straight on the glass (a lone key), without the plastic plate.
    var plated = true
    @ViewBuilder var plate: () -> Plate

    var body: some View {
        if Retro.is8bit { screen } else { quiet }
    }

    /// The minimal look: a flat dark card with the message (or the one button) in the middle, in plain text. No static, no glass, no marks.
    private var quiet: some View {
        VStack(spacing: compact ? 5 : 8) {
            plate()
            if !showsStatic { Text("Starting…").font(.system(size: compact ? 10.5 : 12)).foregroundStyle(NotchInk.secondary) }
        }
        .padding(.horizontal, compact ? 9 : 22).padding(.vertical, compact ? 7 : 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.06))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Retro.hairline, lineWidth: 0.5).allowsHitTesting(false))
        .accessibilityElement(children: .contain)
    }

    private var screen: some View {
        ZStack {
            if showsStatic {
                CRTNoise(seed: 11, strength: 0.42)
                Color.black.opacity(0.30)
            } else {
                Color.black
            }
            VStack {
                HStack {
                    HStack(spacing: compact ? 3 : 5) {
                        Rectangle().fill(showsStatic ? Retro.Ink.ledRed : Retro.Ink.ledYellow).frame(width: compact ? 4 : 6, height: compact ? 4 : 6)
                        RetroOSD(title, pixel: compact ? 1.25 : 2, color: Retro.Ink.osdWhite)
                    }
                    Spacer()
                }
                Spacer()
            }
            .padding(compact ? EdgeInsets(top: 12, leading: 14, bottom: 10, trailing: 14) : EdgeInsets(top: 24, leading: 26, bottom: 22, trailing: 26))
            if compact { MirrorCornerMarks(inset: 7, arm: 9).opacity(0.7) }   // none in the Camera tab
            if plated {
                plate()
                    .padding(.horizontal, compact ? 9 : 22).padding(.vertical, compact ? 7 : 14)
                    .frame(maxWidth: compact ? 120 : 420)
                    .retroBevel(.raised, cornerRadius: compact ? 6 : 8, depth: compact ? 1.25 : 1.5, face: RadioBoom.body)
                    .shadow(color: .black.opacity(0.55), radius: compact ? 5 : 8, y: 3)
                    .offset(y: compact ? 6 : 0)
            } else {
                plate().offset(y: compact ? 6 : 0)
            }
        }
        .crtScreen(cornerRadius: cornerRadius, scanlines: 0.07, tint: nil, vignette: 0.30)
        .accessibilityElement(children: .contain)
    }
}

/// The plate's contents: a symbol, a message, an optional second line and one key.
struct MirrorPlateContent: View {
    var symbol: String?
    var message: LocalizedStringKey?
    var detail: LocalizedStringKey?
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 5 : 7) {
            if let symbol, !compact { Image(systemName: symbol).font(.system(size: 20, weight: .regular)).foregroundStyle(Retro.is8bit ? Retro.Ink.yellow : Retro.quietInk) }
            if let message {
                Text(message).font(.system(size: compact ? 11 : 12, weight: .semibold)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(NotchInk.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true) }
            if let actionTitle, let action {
                if Retro.is8bit {
                    Button(actionTitle, action: action).buttonStyle(.retro(tint: Retro.Ink.yellow, compact: compact))
                } else {
                    Button(actionTitle, action: action).buttonStyle(NotchPillButtonStyle(compact: compact))
                }
            }
        }
    }
}
