import AppKit
import SwiftUI

// Shared building blocks for the ring tools' floating panels.

/// The standard tool panel: glass, header (symbol, title, accessory, close) and content.
struct ToolPanelFrame<Accessory: View, Content: View>: View {
    let title: LocalizedStringKey
    var symbol: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringKey, symbol: String? = nil, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.symbol = symbol
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title, symbol: symbol, accessory: accessory)
            content()
        }
        .background(GlassBackground(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A symbol, one short line and an optional action — what every empty list shows. `message` and `actionTitle` are finished text: callers
/// write `String(localized: "...")` for a literal.
struct ToolEmptyState: View {
    let symbol: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
            Text(message).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action).controlSize(.small).buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `prompt` is finished text: callers write `String(localized: "...")` for a literal.
struct ToolSearchField: View {
    var prompt: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            field
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
    }

    @ViewBuilder private var field: some View {
        if let focus {
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 13)).focused(focus)
        } else {
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 13))
        }
    }
}

/// The picture for a clipboard item: image thumbnail, file icon, color swatch or type symbol.
struct ClipboardGlyph: View {
    let item: ClipboardItem
    var size: CGFloat = 30

    var body: some View {
        Group {
            switch item.kind {
            case .image:
                if let image = ClipboardImages.thumbnail(for: item, maxPixel: Int(size * 3)) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else { symbol }
            case .file:
                if let path = item.filePaths.first {
                    Image(nsImage: AppIcons.icon(forPath: path)).resizable().scaledToFit().padding(2)
                } else { symbol }
            case .color:
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(item.color ?? .gray)
                    .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
            case .text, .link:
                symbol
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    private var symbol: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(Color.primary.opacity(0.08))
            Image(systemName: item.kind.symbol).font(.system(size: size * 0.42)).foregroundStyle(.secondary)
        }
    }
}

/// The small app icon of where an item was copied from.
struct SourceAppIcon: View {
    let bundleID: String?
    var size: CGFloat = 14

    var body: some View {
        if let image = AppIcons.icon(forBundleID: bundleID) {
            Image(nsImage: image).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "app").font(.system(size: size * 0.8)).foregroundStyle(.tertiary).frame(width: size, height: size)
        }
    }
}

/// Opens a panel for a tool with the standard options.
@MainActor
enum ToolPanels {
    static func show<Content: View>(_ id: String, size: CGSize, minSize: CGSize? = nil, resizable: Bool = false,
                                    position: Panels.Position = .remembered, closesWhenInactive: Bool = false,
                                    @ViewBuilder content: () -> Content) {
        Panels.show(id: "tool.\(id)", options: Panels.Options(size: size, minSize: minSize, resizable: resizable, position: position,
                                                               closesWhenInactive: closesWhenInactive), content: content)
    }
}

/// How long ago something happened, in the user's language ("5 min. ago", "yesterday"): the system's relative-date words.
enum ToolFormat {
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale.current
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
