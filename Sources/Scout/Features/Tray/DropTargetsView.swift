import SwiftUI

/// Shown in the open notch while files, links or text are dragged toward it: three big zones.
struct NotchDropTargetsView: View {
    enum Zone: String, CaseIterable, Identifiable {
        case keep, airdrop, convert, askAI
        var id: String { rawValue }

        /// Ask AI only while it is one of the notch's workspaces (it takes the picture there).
        @MainActor static var shown: [Zone] { allCases.filter { $0 != .askAI || AskAIPlace.enabledInNotch } }
        var title: String {
            switch self {
            case .keep: String(localized: "Keep")
            case .airdrop: "AirDrop"
            case .convert: String(localized: "Convert")
            case .askAI: String(localized: "Ask AI")
            }
        }
        var subtitle: String {
            switch self {
            case .keep: String(localized: "Park it in the Tray")
            case .airdrop: String(localized: "Send to a nearby device")
            case .convert: String(localized: "Change the format")
            case .askAI: String(localized: "Ask about a picture")
            }
        }
        var symbol: String {
            switch self {
            case .keep: "tray.and.arrow.down.fill"
            case .airdrop: "airplayaudio"
            case .convert: "arrow.triangle.2.circlepath"
            case .askAI: "sparkles"
            }
        }
    }

    @State private var targeted: Set<Zone> = []
    /// Gallery only: draw this zone as if something is held over it.
    private var previewTargeted: Zone?

    init() {}
    init(previewTargeted: Zone?) { self.previewTargeted = previewTargeted }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Zone.shown) { zone in
                zoneView(zone)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .notchContent()
    }

    private func isOn(_ zone: Zone) -> Bool { targeted.contains(zone) || previewTargeted == zone }

    private func zoneView(_ zone: Zone) -> some View {
        let on = isOn(zone)
        return VStack(spacing: 7) {
            Image(systemName: zone.symbol).font(.system(size: 30, weight: .regular)).foregroundStyle(on ? Color.black.opacity(0.85) : Theme.accent).environment(\.symbolVariants, .none)
            Text(zone.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(on ? Color.black.opacity(0.85) : NotchInk.primary)
            Text(zone.subtitle).font(.system(size: 11)).foregroundStyle(on ? Color.black.opacity(0.65) : NotchInk.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(on ? Theme.accent : NotchInk.tile))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(on ? Color.clear : NotchInk.tertiary, style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])))
        .scaleEffect(on && !ScoutRuntime.reduceMotion ? 1.02 : 1)
        .animation(Theme.quick, value: on)
        .contentShape(Rectangle())
        .onDrop(of: DropReader.acceptedTypes, isTargeted: Binding(
            get: { targeted.contains(zone) },
            set: { if $0 { targeted.insert(zone) } else { targeted.remove(zone) } })) { providers in
            handle(zone, providers)
            return true
        }
    }

    private func handle(_ zone: Zone, _ providers: [NSItemProvider]) {
        let store = TrayStore.shared
        Task { @MainActor in
            switch zone {
            case .keep:
                await TrayDrop.handle(providers, into: store, opensTray: false)
            case .airdrop:
                let things = await DropReader.read(providers)
                store.airDrop(things.map { thing -> Any in
                    switch thing {
                    case .file(let url): url
                    case .link(let url): url
                    case .text(let text): text
                    }
                })
            case .askAI:
                if AskAINotchDraft.shared.add(providers: providers) {
                    NotchNavigator.shared.workspace = .askAI
                    AskAINotchFocus.shared.request()
                }
            case .convert:
                let things = await DropReader.read(providers)
                guard !things.isEmpty else { return }
                store.start()
                let added = store.add(things)
                store.selection = Set(added.map(\.id))
                store.convertBarOpen = true
                NotchNavigator.shared.open(.tray)
            }
        }
    }
}
