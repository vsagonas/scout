import SwiftUI

/// Nook widget: your favorite Shortcuts as buttons.
struct ShortcutsWidgetView: View {
    @ObservedObject private var service = ShortcutsService.shared
    @AppStorage(ShortcutsService.Key.favorites) private var favoritesRaw = ""

    private let hues: [Color] = [Color(red: 1.0, green: 0.72, blue: 0.28), Color(red: 0.45, green: 0.72, blue: 1.0),
                                 Color(red: 0.78, green: 0.58, blue: 1.0), Color(red: 0.42, green: 0.86, blue: 0.62),
                                 Color(red: 1.0, green: 0.52, blue: 0.55), Color(red: 0.35, green: 0.85, blue: 0.95)]

    /// Gallery only: show these names.
    private var previewNames: [String]?
    init() {}
    init(preview: [String]) { previewNames = preview }

    private var names: [String] { previewNames ?? service.visibleFavorites }

    private func shortcutButton(_ name: String, index: Int, height: CGFloat) -> some View {
        Button { service.run(name) } label: {
            HStack(spacing: 6) {
                if service.running.contains(name) {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                } else {
                    Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(hues[index % hues.count])
                }
                Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.retro(tint: Look.isLight ? Retro.Ink.plasticMid : Retro.Ink.plasticDark, compact: true))   // charcoal keys in the dark preset, the grey keys of the other widgets on the light one
        .help(name)
    }

    var body: some View {
        Group {
            if names.isEmpty {
                // The grid's empty line at the top, like every panel's (`DashEmpty`).
                DashEmpty(symbol: "square.stack.3d.up", title: "No shortcuts yet", detail: "Your shortcuts, one click away.",
                          actionTitle: "Choose shortcuts") { SettingsWindowController.shared.show(.widgets) }
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                GeometryReader { geo in
                    let wide = geo.size.width >= 210
                    let capacity = wide ? 8 : 4
                    let overflow = names.count > capacity
                    let shown = Array(names.prefix(overflow ? capacity - (wide ? 2 : 1) : capacity))
                    let columns = wide ? [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)] : [GridItem(.flexible())]
                    VStack(alignment: .leading, spacing: 5) {
                        Dash90Title("Shortcuts", symbol: "square.stack.3d.up", tint: Retro.Ink.purple)
                        LazyVGrid(columns: columns, spacing: wide ? 5 : 4) {
                            ForEach(Array(shown.enumerated()), id: \.offset) { index, name in
                                shortcutButton(name, index: index, height: wide ? 20 : 20)
                            }
                        }
                        if overflow {
                            DashMore(count: names.count - shown.count).padding(.leading, 2)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .notchContent()
        .onAppear { if previewNames == nil && !service.loaded { service.reload() } }
    }
}
