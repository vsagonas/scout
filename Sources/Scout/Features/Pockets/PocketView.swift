import AppKit
import SwiftUI

/// The floating Pocket: drop files in, drag them out together, convert, AirDrop, move to the Tray.
struct PocketView: View {
    let pocketID: UUID
    @ObservedObject private var store = PocketStore.shared
    @State private var targeted = false
    @State private var showFormats = false

    private var pocket: Pocket? { store.pocket(pocketID) }
    private var urls: [URL] { store.urls(of: pocketID) }

    var body: some View {
        VStack(spacing: 6) {
            header
            ZStack {
                stack
                CellInteraction(dragURLs: { urls }, onMouseDown: { _ in }, onClickWithoutDrag: { _ in }, onDoubleClick: {
                    if let first = urls.first, !ScoutRuntime.isScripted { NSWorkspace.shared.activateFileViewerSelecting([first]) }
                }, makeMenu: { nil })
            }
            .frame(height: 100)
            footer
        }
        .padding(10)
        .frame(width: 196, height: 212)
        .background(GlassBackground(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.accent.opacity(targeted ? 0.95 : 0), lineWidth: 2.5))
        .animation(Theme.quick, value: targeted)
        .onDrop(of: DropReader.acceptedTypes, isTargeted: $targeted) { providers in
            Task {
                let things = await DropReader.read(providers)
                let files = things.compactMap { thing -> URL? in if case .file(let u) = thing { return u } else { return nil } }
                PocketStore.shared.add(files, to: pocketID)
            }
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(Theme.accent).font(.system(size: 12))
            Text("Pocket").font(.system(size: 12, weight: .semibold))
            Spacer()
            Button { PocketsController.shared.minimize(pocketID) } label: { Image(systemName: "minus") }
                .buttonStyle(.plain).help("Minimize").frame(width: 20, height: 20).background(Circle().fill(.quaternary))
            Button { PocketsController.shared.close(pocketID) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("Close and empty").frame(width: 20, height: 20).background(Circle().fill(.quaternary))
        }
        .font(.system(size: 10, weight: .bold))
    }

    @ViewBuilder private var stack: some View {
        if urls.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "arrow.down.doc").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                Text("Drop files here").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4])).foregroundStyle(.tertiary))
        } else {
            ZStack {
                ForEach(Array(urls.prefix(4).enumerated().reversed()), id: \.offset) { index, url in
                    FileThumbnail(url: url, side: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        .rotationEffect(.degrees(Double(index) * 5 - (urls.count > 1 ? 4 : 0)))
                        .offset(x: CGFloat(index) * 7 - 10, y: CGFloat(index) * -4 + 4)
                }
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text("\(urls.count)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(Color.black.opacity(0.85))
                            .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Theme.accent))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .help("Drag the stack to take all the files with you")
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            footerButton("airplayaudio", Text(verbatim: "AirDrop")) { TrayStore.shared.airDrop(urls) }
            Menu {
                let formats = Converter.formats(for: urls)
                ForEach(formats) { f in Button(f.title) { convert(urls, to: f) } }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .frame(width: 30, height: 26).background(Capsule().fill(.quaternary)).help("Convert").disabled(urls.isEmpty)
            footerButton("tray.full", Text("Move to the Tray")) { moveToTray() }
            Spacer(minLength: 0)
            footerButton("trash", Text("Empty the Pocket")) { store.empty(pocketID) }
        }
        .disabled(urls.isEmpty)
    }

    private func footerButton(_ symbol: String, _ help: Text, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 30, height: 26).background(Capsule().fill(.quaternary)) }
            .buttonStyle(.plain).help(help)
    }

    private func moveToTray() {
        let files = urls
        TrayStore.shared.start()
        TrayStore.shared.add(files: files)
        store.empty(pocketID)
        Toast.show("Moved to the Tray", symbol: "tray.full.fill")
    }

    private func convert(_ sources: [URL], to format: ConvertFormat) {
        TrayStore.shared.convert(sources, to: format, addToTray: false) { results in
            PocketStore.shared.add(results, to: pocketID)
        }
    }
}

/// The strip of minimized Pockets: click one to bring it back; drop files on a chip to add them.
struct PocketSwitcherView: View {
    @ObservedObject private var store = PocketStore.shared

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(Theme.accent).font(.system(size: 12))
            ForEach(store.pockets.filter(\.minimized)) { p in
                Chip(pocket: p)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GlassBackground(Capsule()))
    }

    private struct Chip: View {
        let pocket: Pocket
        @State private var targeted = false

        var body: some View {
            Button { PocketsController.shared.show(pocket.id, near: nil) } label: {
                Text("Files: \(pocket.entries.count)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(targeted ? Theme.accent.opacity(0.6) : Color.primary.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .onDrop(of: DropReader.acceptedTypes, isTargeted: $targeted) { providers in
                Task {
                    let things = await DropReader.read(providers)
                    let files = things.compactMap { thing -> URL? in if case .file(let u) = thing { return u } else { return nil } }
                    PocketStore.shared.add(files, to: pocket.id)
                }
                return true
            }
        }
    }
}
