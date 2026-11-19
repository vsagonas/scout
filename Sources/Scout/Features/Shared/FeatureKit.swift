import AppKit
import SwiftUI

// Shared building blocks for the features code: colors for notch content, small buttons and chips, empty states,
// the gallery stages (a black notch stand-in), and a few helpers.

/// Notch content is drawn on black (Classic) or dark glass, so the features code uses explicit light-on-dark colors
/// and forces the dark scheme on its roots (see `notchContent()`).
enum NotchInk {
    // Semantic inks (Core/Retro/ScoutLook.swift): white on the dark surface, near-black on the light preset's paper. They follow the colour
    // scheme of the view they are used in, so a screen (`.lookScreen()`) inside the light surface keeps its light-on-dark inks.
    static let primary = Look.primary
    static let secondary = Look.secondary
    static let tertiary = Look.faint
    static let tile = Look.tile
    static let tileStrong = Look.tileStrong
    static let hairline = Look.hairline
}

/// A modifier of its own (not an inline `.environment`): the same call written inline in `notchContent` crashed the Shortcuts widget's body.
struct NotchLeftToRight: ViewModifier {
    func body(content: Content) -> some View { content.environment(\.layoutDirection, .leftToRight) }
}

extension View {
    /// Root modifier for widgets and workspaces: the open notch's colour scheme (dark: white text; light preset: dark text), amber tint.
    /// `screen: true` for a floating window that is always dark (the Prompter, the den): light on dark whatever the preset.
    func notchContent(screen: Bool = false) -> some View {
        self.modifier(NotchLeftToRight())   // the island and its widgets are drawn around the camera notch: left stays left in Arabic (the text itself still reads right to left)
            .environment(\.colorScheme, screen ? .dark : Look.contentScheme)
            .foregroundStyle(NotchInk.primary)
            .tint(Theme.accent)
    }

    /// A soft rounded tile behind a group (used inside widgets).
    func notchTile(radius: CGFloat = 10, fill: Color = NotchInk.tile) -> some View {
        self.background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
    }
}

extension NSPanel {
    /// Panels from `Panels.show` are titled with a hidden title bar, which still adds ~28 pt of blank space on
    /// top. Compact floating pieces (Prompter, Pockets) drop the title bar so the frame is exactly the content.
    func dropTitleBar(size: CGSize) {
        styleMask = [.borderless, .nonactivatingPanel]
        setContentSize(size)
    }
}

// MARK: - Buttons and chips

struct NotchPillButtonStyle: ButtonStyle {
    var prominent = false
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .semibold))
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : NotchInk.primary)
            .padding(.horizontal, compact ? 9 : 12)
            .padding(.vertical, compact ? 4 : 6)
            .background(Capsule().fill(prominent ? Theme.accent : NotchInk.tileStrong))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == NotchPillButtonStyle {
    static var notchPill: NotchPillButtonStyle { NotchPillButtonStyle() }
    static var notchPillProminent: NotchPillButtonStyle { NotchPillButtonStyle(prominent: true) }
    static var notchPillCompact: NotchPillButtonStyle { NotchPillButtonStyle(compact: true) }
}

struct NotchIconButtonStyle: ButtonStyle {
    var size: CGFloat = 24
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(NotchInk.primary)
            .frame(width: size, height: size)
            .background(Circle().fill(NotchInk.tileStrong))
            .opacity(configuration.isPressed ? 0.65 : 1)
            .contentShape(Circle())
    }
}

struct NotchChip: View {
    let title: Text
    var symbol: String?
    var selected = false
    var action: () -> Void

    /// `title` is a `Text`: `Text("All open")` localizes a literal, `Text(verbatim: name)` shows a name as it is.
    init(title: Text, symbol: String? = nil, selected: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.selected = selected; self.action = action
    }
    init(title: LocalizedStringKey, symbol: String? = nil, selected: Bool = false, action: @escaping () -> Void) {
        self.init(title: Text(title), symbol: symbol, selected: selected, action: action)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
                title.font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(selected ? Color.black.opacity(0.85) : NotchInk.primary)
            .background(Capsule().fill(selected ? Theme.accent : NotchInk.tileStrong))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Empty state for widgets and workspaces: a symbol, one short line, one action.
struct NotchEmptyState: View {
    let symbol: String
    let message: Text
    var detail: Text?
    var actionTitle: Text?
    var action: (() -> Void)?

    /// The lines are `Text`: `Text("Calendar access is off")` localizes a literal, `Text(verbatim: line)` shows a string already made.
    init(symbol: String, message: Text, detail: Text? = nil, actionTitle: Text? = nil, action: (() -> Void)? = nil) {
        self.symbol = symbol; self.message = message; self.detail = detail; self.actionTitle = actionTitle; self.action = action
    }
    init(symbol: String, message: LocalizedStringKey, detail: LocalizedStringKey? = nil, actionTitle: LocalizedStringKey? = nil, action: (() -> Void)? = nil) {
        self.init(symbol: symbol, message: Text(message), detail: detail.map { Text($0) }, actionTitle: actionTitle.map { Text($0) }, action: action)
    }

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 20, weight: .regular)).foregroundStyle(Theme.accent)
            message.font(.system(size: 12, weight: .semibold)).multilineTextAlignment(.center)
            if let detail {
                detail.font(.system(size: 11)).foregroundStyle(NotchInk.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(action: action) { actionTitle }.buttonStyle(.notchPillCompact)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Small helpers

enum FeatureFormat {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// "5 seconds" in the person's language (a measurement formatter: the plural comes right).
    static func seconds(_ n: Int) -> String {
        Measurement(value: Double(n), unit: UnitDuration.seconds).formatted(.measurement(width: .wide, usage: .asProvided))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension Color {
    init(nsColorLoose c: NSColor) {
        let s = c.usingColorSpace(.sRGB) ?? NSColor.systemBlue
        self.init(.sRGB, red: Double(s.redComponent), green: Double(s.greenComponent), blue: Double(s.blueComponent), opacity: 1)
    }
}

/// Reads and writes a Bool/Int/String user default without an @AppStorage property (for services).
// MARK: - Gallery stages

/// What the features' gallery items sit on: a black "notch" with the open notch's bottom corners.
struct NotchStage<Content: View>: View {
    var width: CGFloat
    var height: CGFloat
    var padding: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(width: width, height: height)
            .notchContent()
            .padding(padding)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24, style: .continuous).fill(Look.surface))   // black, or the light preset's paper
    }
}

@MainActor
enum FeatureGallery {
    static func widgetWidth(_ span: Int) -> CGFloat { CGFloat(span) * NookMetrics.cell + CGFloat(max(0, span - 1)) * NookMetrics.spacing }

    /// A widget at its real size on a black notch.
    static func widget<V: View>(_ name: String, span: Int, @ViewBuilder _ content: @escaping () -> V) {
        let w = widgetWidth(span)
        Gallery.register(name, size: CGSize(width: w + 24 + 40, height: NookMetrics.widgetHeight + 24 + 30), backdrop: .wallpaper) {
            NotchStage(width: w, height: NookMetrics.widgetHeight) { content().frame(width: w, height: NookMetrics.widgetHeight).nookPanelFace() }
        }
    }

    /// A row of widgets (as the Nook draws them) on one black notch.
    static func row(_ name: String, _ items: [(span: Int, view: AnyView)]) {
        let widths = items.map { widgetWidth($0.span) }
        let total = widths.reduce(0, +) + CGFloat(max(0, items.count - 1)) * NookMetrics.spacing
        Gallery.register(name, size: CGSize(width: total + 24 + 40, height: NookMetrics.widgetHeight + 24 + 30)) {
            NotchStage(width: total, height: NookMetrics.widgetHeight) {
                HStack(spacing: NookMetrics.spacing) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        item.view.frame(width: widths[i], height: NookMetrics.widgetHeight)
                            .nookPanelFace()
                    }
                }
            }
        }
    }

    /// A workspace in the open notch's content area (about 680×200).
    static func workspace<V: View>(_ name: String, width: CGFloat = 680, height: CGFloat = 200, @ViewBuilder _ content: @escaping () -> V) {
        Gallery.register(name, size: CGSize(width: width + 24 + 40, height: height + 24 + 30)) {
            NotchStage(width: width, height: height) { content() }
        }
    }

    /// A settings page the way the Settings window hosts it (scroll view, 24 pt padding).
    static func settings<V: View>(_ name: String, height: CGFloat = 640, @ViewBuilder _ content: @escaping () -> V) {
        Gallery.register(name, size: CGSize(width: 640, height: height), backdrop: .window) {
            ScrollView {
                content().padding(24).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// What a Registry slot shows in the App Store edition for things that edition leaves out.
struct NotInEditionView: View {
    let title: Text
    var detail: LocalizedStringKey = "This part of Scout isn't in the Mac App Store edition."

    init(title: Text, detail: LocalizedStringKey = "This part of Scout isn't in the Mac App Store edition.") { self.title = title; self.detail = detail }
    init(title: LocalizedStringKey, detail: LocalizedStringKey = "This part of Scout isn't in the Mac App Store edition.") { self.init(title: Text(title), detail: detail) }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "lock.slash").font(.system(size: 20)).foregroundStyle(.secondary)
            title.font(.system(size: 13, weight: .semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
    }
}
