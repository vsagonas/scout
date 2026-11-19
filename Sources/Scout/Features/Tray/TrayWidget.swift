import SwiftUI

/// Nook widget: the Tray in small. Thumbnails of the newest items; drop files on it; clicking the panel opens the full Tray.
struct TrayWidgetView: View {
    @ObservedObject private var store: TrayStore
    @State private var targeted = false

    @MainActor init(store: TrayStore? = nil) { _store = ObservedObject(wrappedValue: store ?? TrayStore.shared) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Dash90Title("Tray", symbol: "tray.full", tint: Retro.Ink.orange) {
                if !store.items.isEmpty { Dash90Text(String(localized: "Items: \(store.items.count)"), pixel: 1, color: Look.osd) }
            }
            if store.items.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 22, weight: .light)).foregroundStyle(targeted ? Theme.accent : NotchInk.tertiary)
                    Text("Drop files here").font(.system(size: 11, weight: .medium)).foregroundStyle(NotchInk.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 6, style: .circular).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(targeted ? Theme.accent : NotchInk.tertiary))
            } else {
                let recent = Array(store.items.suffix(4).reversed())
                HStack(spacing: 6) {
                    ForEach(recent) { item in
                        Group {
                            if let url = store.url(for: item) { FileThumbnail(url: url, side: 34) } else { Image(systemName: "questionmark").frame(width: 34, height: 34) }
                        }
                        .frame(width: 38, height: 38)
                        .lookWell()
                        .retroBevel(.sunken, cornerRadius: 3, depth: 1, face: Dash90.lcdFace)
                    }
                    if store.items.count > recent.count {
                        Text(verbatim: "+\(store.items.count - recent.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(NotchInk.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Text(recent.compactMap { store.url(for: $0)?.lastPathComponent }.prefix(2).joined(separator: ", "))
                    .font(.system(size: 10)).foregroundStyle(NotchInk.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Dash90.radius, style: .circular).strokeBorder(Theme.accent.opacity(targeted ? 0.9 : 0), lineWidth: 2))
        .notchContent()
        .onDrop(of: DropReader.acceptedTypes, isTargeted: $targeted) { providers in
            Task { await TrayDrop.handle(providers, into: store, opensTray: false) }
            return true
        }
        .onAppear { store.start() }
    }
}

/// Card under the notch after a conversion: preview, name, "Show in Finder".
struct ConversionResultCard: View {
    let url: URL
    var extra = 0
    let format: ConvertFormat

    var body: some View {
        HStack(spacing: 12) {
            FileThumbnail(url: url, side: 44).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(extra > 0 ? "Converted to \(format.title) · More: \(extra)" : "Converted to \(format.title)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Image(systemName: "folder").font(.system(size: 10, weight: .semibold))
                Text("Show in Finder").font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 9).padding(.vertical, 5).background(Capsule().fill(.quaternary))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(width: 380)
    }
}
