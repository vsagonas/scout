import AppKit
import SwiftUI

// The Radio tab in the 90s look: a small sidebar (Search, Latest, Favourites, the person's lists) on the left, the station list in an
// LCD-ish window on the right with a title bar, and the boombox (the player) under both while a station is loaded. Stations never
// open or change by hovering; hover only highlights a row. Names stay in the system font so they read easily.

struct RadioWorkspaceView: View {
    @ObservedObject private var model: RadioModel
    @ObservedObject private var service: RadioService
    @ObservedObject private var store: RadioStore
    @FocusState private var searchFocused: Bool

    @MainActor init(model: RadioModel? = nil) {
        let m = model ?? RadioModel.shared
        _model = ObservedObject(wrappedValue: m)
        _service = ObservedObject(wrappedValue: m.service)
        _store = ObservedObject(wrappedValue: m.service.store)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                RadioSidebar(model: model, store: store)
                    .frame(width: 148)
                RadioPane(model: model, service: service, store: store, searchFocused: $searchFocused)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            if service.station != nil { RadioPlayerBar(service: service, store: store, stations: model.stations(on: model.shownPage)) }
        }
        .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: "radioView")
        .onPreferenceChange(RadioRectsKey.self) { model.controlRects = $0 }
        .notchContent()
        .onAppear {
            model.tabOpened()   // Favourites if there are any, else Latest, else Search
            model.loadCountries()
            askForHeight()
        }
        .onChange(of: model.stations(on: model.shownPage).count) { askForHeight() }
        .onChange(of: model.shownPage) { askForHeight() }
        .onChange(of: searchFocused) { _, focused in
            if focused { NotchNavigator.shared.hold("radio.search") } else { NotchNavigator.shared.release("radio.search") }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in NotchNavigator.shared.hold("radio.menu") }   // a menu is open: the notch stays
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in NotchNavigator.shared.release("radio.menu") }
        .onChange(of: model.renaming) { _, id in
            if id != nil { NotchNavigator.shared.hold("radio.rename") } else { NotchNavigator.shared.release("radio.rename") }
        }
        .onDisappear {
            NotchNavigator.shared.release("radio.search")
            NotchNavigator.shared.release("radio.rename")
            NotchNavigator.shared.release("radio.menu")
            NotchNavigator.shared.releaseHeight(by: .radio)
        }
    }

    /// A long list can be pulled taller with the island's grip; a short one fits as it is.
    private func askForHeight() {
        let rows = model.stations(on: model.shownPage).count
        NotchNavigator.shared.requestHeight(nil, resizeMax: rows > 5 ? CGFloat(rows) * 38 + 170 : nil, by: .radio)
    }
}

// MARK: - Little parts

/// A small round LED: lit in `tint` with a soft glow, or dark.
struct RadioLED: View {
    var on: Bool
    var tint: Color
    var size: CGFloat = 5

    var body: some View {
        Circle()
            .fill(on ? tint : tint.opacity(0.16))
            .frame(width: size, height: size)
            .shadow(color: on ? tint.opacity(0.85) : .clear, radius: size * 0.5)
    }
}

/// A sunken window face for lists and fields.
enum RadioInk {
    /// The window's face: dark glass in the dark preset, the light well (`Look.well`) in the light one.
    static var window: Color { Look.well(dark: Color(red: 0.035, green: 0.045, blue: 0.05)) }
    static let stripe = Look.ink(0.035)
}

extension View {
    /// The sunken window of the 90s look, or a flat dark card with a hairline in the minimal look (lists, fields).
    @ViewBuilder func radioWindow(radius: CGFloat, depth: CGFloat) -> some View {
        if Retro.is8bit { lookWell().retroBevel(.sunken, cornerRadius: radius, depth: depth, face: RadioInk.window) } else { miniCard(radius: radius + 2) }
    }
}

/// A genre tag as a small coloured chip. The colour comes from the tag's own letters, so it is the same every time.
struct RadioGenreChip: View {
    let tag: String

    static let palette: [Color] = [Retro.Ink.teal, Retro.Ink.magenta, Retro.Ink.purple, Retro.Ink.yellow, Retro.Ink.lime, Retro.Ink.orange]

    static func color(for tag: String) -> Color {
        var h: UInt32 = 5381
        for byte in RadioText.fold(tag).utf8 { h = h &* 33 &+ UInt32(byte) }
        return palette[Int(h % UInt32(palette.count))]
    }

    var body: some View {
        let face = Self.color(for: tag)
        Text(tag.uppercased())
            .font(.system(size: 8.5, weight: .heavy))
            .foregroundStyle(Retro.isLight(face) ? Color.black.opacity(0.85) : Color.white)
            .lineLimit(1)
            .padding(.horizontal, 4).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 2, style: .continuous).fill(face))
            .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.28)).frame(height: 1) }
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    }
}

// MARK: - Sidebar

struct RadioSidebar: View {
    @ObservedObject var model: RadioModel
    @ObservedObject var store: RadioStore
    @FocusState private var renameFocused: Bool
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            item("Search", symbol: "magnifyingglass", page: .search, count: nil, tint: Retro.Ink.teal)
            item("Latest", symbol: "clock", page: .latest, count: store.latest.count, tint: Retro.Ink.purple)
            item("Favourites", symbol: "star", page: .favourites, count: store.favourites.count, tint: Retro.Ink.yellow)
            HStack(spacing: 4) {
                if Retro.is8bit {
                    RetroPixelText(pixelLabel("LISTS"), pixel: 1.25, color: Look.osd.opacity(0.5))
                } else {
                    Text("Lists").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Retro.quietInk)
                }
                Spacer()
                DeckKey(symbol: "plus", compact: true, size: CGSize(width: 9, height: 9), help: String(localized: "New list")) { model.newList() }
            }
            .padding(.leading, 8).padding(.trailing, 2).padding(.top, 5).padding(.bottom, 1)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(store.lists) { list in listItem(list) }
                    if store.lists.isEmpty {
                        Text("Make a list of your own.").font(.system(size: 10.5)).foregroundStyle(NotchInk.tertiary).padding(.horizontal, 8).padding(.top, 2)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func item(_ title: LocalizedStringKey, symbol: String, page: RadioModel.Page, count: Int?, tint: Color) -> some View {
        RadioSidebarItem(title: title, symbol: symbol, count: count, selected: model.shownPage == page, tint: tint) { model.page = page }
    }

    @ViewBuilder
    private func listItem(_ list: RadioList) -> some View {
        if model.renaming == list.id {
            TextField("List name", text: $renameText)
                .textFieldStyle(.plain).font(.system(size: 12))
                .focused($renameFocused)
                .padding(.horizontal, 8).frame(height: 26)
                .radioWindow(radius: 4, depth: 1.25)
                .onSubmit { model.commitRename(list.id, name: renameText) }
                .onExitCommand { model.renaming = nil }
                .onAppear { renameText = list.name; renameFocused = true }
                .onChange(of: renameFocused) { _, focused in if !focused, model.renaming == list.id { model.commitRename(list.id, name: renameText) } }
        } else {
            item(.verbatim(list.name), symbol: "music.note.list", page: .list(list.id), count: list.stations.count, tint: Retro.Ink.magenta)
                .contextMenu {
                    Button("Rename") { model.renaming = list.id }
                    Button("Move up") { store.moveList(list.id, by: -1) }.disabled(store.lists.first?.id == list.id)
                    Button("Move down") { store.moveList(list.id, by: 1) }.disabled(store.lists.last?.id == list.id)
                    Divider()
                    Button("Delete list", role: .destructive) { model.deleteList(list.id) }
                }
        }
    }
}

/// One row of the sidebar. The chosen page is a pressed-in key with its LED lit; hover only tints a row.
struct RadioSidebarItem: View {
    let title: LocalizedStringKey
    let symbol: String
    let count: Int?
    let selected: Bool
    var tint: Color = Retro.Ink.teal
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if Retro.is8bit { RadioLED(on: selected, tint: tint, size: 5) }
                Image(systemName: selected && symbol == "star" ? "star.fill" : symbol).font(.system(size: 11)).frame(width: 14)
                    .foregroundStyle(Retro.is8bit ? (selected ? Look.accent(tint) : NotchInk.secondary) : (selected ? NotchInk.primary : NotchInk.secondary))
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 2)
                if let count, count > 0 { Text(verbatim: "\(count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(NotchInk.tertiary).monospacedDigit() }
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background {
                if !Retro.is8bit {   // the minimal look: the chosen page is a soft rounded fill, hover only lightens a row
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Look.ink(selected ? 0.11 : (hover ? 0.05 : 0)))
                } else if selected {
                    Color.clear.retroBevel(.sunken, cornerRadius: 4, depth: 1.25, face: RadioInk.window)
                } else {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Look.ink(hover ? 0.06 : 0))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Right side

struct RadioPane: View {
    @ObservedObject var model: RadioModel
    @ObservedObject var service: RadioService
    @ObservedObject var store: RadioStore
    var searchFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
        }
    }

    @ViewBuilder
    private var header: some View {
        switch model.shownPage {
        case .search:
            HStack(spacing: 8) {
                RadioSearchField(prompt: "City, region or country", text: $model.query, focus: searchFocused)
                    .onSubmit { model.submit() }
                    .onChange(of: model.query) { model.queryChanged() }
                countryMenu
            }
            .frame(height: 28)
        case .latest: title(pixelLabel("LATEST"), text: "Latest", symbol: "clock", tint: Retro.Ink.purple, detail: store.latest.isEmpty ? nil : "Played last")
        case .favourites: title(pixelLabel("FAVOURITES"), text: "Favourites", symbol: "star.fill", tint: Retro.Ink.yellow, detail: nil)
        case .list(let id): title(pixelLabel("LIST"), text: "List", symbol: "music.note.list", tint: Retro.Ink.magenta, name: store.list(id)?.name)
        }
    }

    /// A 90s title bar. A person's own list name goes in the bar's pixel letters when the dot font knows every letter, else beside them in
    /// the system font.
    @ViewBuilder
    private func title(_ pixel: String, text: LocalizedStringKey, symbol: String, tint: Color, detail: LocalizedStringKey? = nil, name: String? = nil) -> some View {
        if Retro.is8bit { retroTitle(pixel, symbol: symbol, tint: tint, detail: detail, name: name) } else {
            // The minimal look: the page's name as quiet text (a list shows its own name), a short fact at the right.
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(Retro.quietInk)
                (name.map { Text(verbatim: $0) } ?? Text(text)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Retro.quietInk).lineLimit(1)
                Spacer(minLength: 4)
                if let detail { Text(detail).font(.system(size: 10.5)).foregroundStyle(NotchInk.secondary).lineLimit(1) }
            }
            .padding(.horizontal, 4)
            .frame(height: 28, alignment: .center)
        }
    }

    private func retroTitle(_ pixel: String, symbol: String, tint: Color, detail: LocalizedStringKey?, name: String?) -> some View {
        let pixelName = name.flatMap { n in n.count <= 18 && RadioLCDText.canPixel(n) ? n.uppercased() : nil }
        return RetroTitleBar(pixelName ?? pixel, symbol: symbol, tint: tint) {
            if let detail { Text(detail).font(.system(size: 10.5)).foregroundStyle(NotchInk.secondary).lineLimit(1) }
            if let name, pixelName == nil { Text(name).font(.system(size: 11, weight: .semibold)).lineLimit(1).frame(maxWidth: 170, alignment: .trailing) }
        }
        .frame(height: 28, alignment: .center)
    }

    /// The picked country's name, or the word "Country" while none is picked.
    private var countryLabel: Text {
        model.country.map { Text(verbatim: $0.displayName) } ?? Text("Country")
    }

    private var countryMenu: some View {
        let picked = model.country != nil
        return Menu {
            Button("Any country") { model.pickCountry(nil) }
            if !model.countries.isEmpty { Divider() }
            ForEach(model.countries.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }) { c in
                Button { model.pickCountry(c) } label: {
                    if model.country?.code == c.code { Label(c.displayName, systemImage: "checkmark") } else { Text(verbatim: c.displayName) }
                }
            }
        } label: {
            if Retro.is8bit {
                RetroKeyFace(tint: picked ? Retro.Ink.teal : Retro.Ink.plasticMid, compact: false) {
                    HStack(spacing: 4) {
                        Image(systemName: "globe").font(.system(size: 11))
                        countryLabel.font(.system(size: 12, weight: .heavy)).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                    .frame(maxWidth: 130)
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "globe").font(.system(size: 11))
                    countryLabel.font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(picked ? Theme.accent : NotchInk.primary)
                .frame(maxWidth: 130)
                .padding(.horizontal, 10).frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(picked ? Theme.accent.opacity(0.16) : MiniBoom.fill))
                .contentShape(Rectangle())
            }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Browse a country")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let page = model.shownPage
        let stations = model.stations(on: page)
        window {
            if page == .search, stations.isEmpty || (model.phase != .results && model.phase != .searching) {
                searchState
            } else if stations.isEmpty {
                emptyPage(page)
            } else {
                list(stations, page: page)
            }
        }
    }

    /// The LCD-ish window the list and its messages sit in.
    private func window<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .radioWindow(radius: 5, depth: 1.5)
    }

    private func list(_ stations: [RadioStation], page: RadioModel.Page) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 2) {
                ForEach(Array(stations.enumerated()), id: \.element.id) { index, station in
                    RadioStationRow(station: station, model: model, service: service, store: store, page: page, striped: index % 2 == 1)
                }
            }
        }
        .opacity(page == .search && model.phase == .searching ? 0.5 : 1)
    }

    /// One calm line for every way a search can stand.
    @ViewBuilder
    private var searchState: some View {
        switch model.phase {
        case .searching:
            RadioNote(symbol: nil, line: "Looking for stations…", detail: nil, spinner: true)
        case .empty:
            RadioNote(symbol: "magnifyingglass", line: "No stations found there.",
                      detail: "Try a bigger place, or pick a country.")
        case .offline:
            RadioNote(symbol: "wifi.slash", line: .verbatim(RadioSearchError.offline.message), detail: nil, action: "Try again") { model.submit() }
        case .failed:
            RadioNote(symbol: "exclamationmark.triangle", line: .verbatim(RadioSearchError.unavailable.message), detail: nil, action: "Try again") { model.submit() }
        case .idle, .results:
            VStack(spacing: 8) {
                RadioNote(symbol: "dot.radiowaves.left.and.right", line: "Find radio by place",
                          detail: "Type a city, region or country, or pick a country.")
                if !store.places.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            if Retro.is8bit {
                                RetroPixelText(pixelLabel("PLACES"), pixel: 1.25, color: Look.osd.opacity(0.5))
                            } else {
                                Text("Places").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Retro.quietInk)
                            }
                            ForEach(store.places) { place in
                                Button { model.searchPlace(place) } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: place.countryCode == nil ? "mappin" : "globe").font(.system(size: 9, weight: .bold))
                                        Text(verbatim: place.displayText).lineLimit(1)
                                    }
                                }
                                .buttonStyle(.retro(tint: Retro.Ink.plasticMid, compact: true))
                            }
                        }
                        .padding(.horizontal, 6).padding(.bottom, 4)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func emptyPage(_ page: RadioModel.Page) -> some View {
        switch page {
        case .latest: RadioNote(symbol: "clock", line: "Stations you play show up here.", detail: nil)
        case .favourites: RadioNote(symbol: "star", line: "Tap the star on a station to keep it here.", detail: nil)
        case .list: RadioNote(symbol: "music.note.list", line: "This list is empty.", detail: "Use the ••• menu on any station to add it.")
        case .search: EmptyView()
        }
    }
}

/// The search field: a sunken window with a teal glass, a clear button once something is typed.
struct RadioSearchField: View {
    var prompt: LocalizedStringKey
    @Binding var text: String
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(Retro.is8bit ? Look.teal : Retro.quietInk)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Look.ink(0.45))).textFieldStyle(.plain).font(.system(size: 13)).focused(focus)   // in the dark window the prompt is light, on the light preset too
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(maxHeight: .infinity)
        .radioWindow(radius: 5, depth: 1.5)
    }
}

/// An empty or message state: a symbol, one line, an optional second line and action.
struct RadioNote: View {
    var symbol: String?
    var line: LocalizedStringKey
    var detail: LocalizedStringKey?
    var spinner = false
    var action: LocalizedStringKey?
    var run: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            if spinner { ProgressView().controlSize(.small) }
            if let symbol { Image(systemName: symbol).font(.system(size: 22, weight: .light)).foregroundStyle(Retro.is8bit ? Look.teal : Retro.quietInk) }
            Text(line).font(.system(size: 12, weight: .semibold)).multilineTextAlignment(.center)
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(NotchInk.secondary).multilineTextAlignment(.center) }
            if let action, let run { Button(action, action: run).buttonStyle(.retro(tint: Retro.Ink.plasticMid, compact: true)) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Rows

struct RadioStationRow: View {
    let station: RadioStation
    @ObservedObject var model: RadioModel
    @ObservedObject var service: RadioService
    @ObservedObject var store: RadioStore
    let page: RadioModel.Page
    var striped = false
    @State private var hover = false

    private var isCurrent: Bool { service.station?.id == station.id && service.isActive }

    var body: some View {
        if Retro.is8bit { retroRow } else { minimalRow }
    }

    /// The minimal look: a play-state mark (a still waveform while it plays, pause while paused, a faint play triangle otherwise), the name
    /// and the place with its tags as quiet text, the quality, a star and the menu. A soft fill marks the station that is on.
    private var minimalRow: some View {
        HStack(spacing: 9) {
            Image(systemName: isCurrent ? (service.state == .paused ? "pause.fill" : "waveform") : "play.fill")
                .font(.system(size: isCurrent ? 12 : 10, weight: .semibold))
                .foregroundStyle(isCurrent ? Theme.accent : Look.ink(hover ? 0.55 : 0.25))
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(station.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(NotchInk.primary)
                miniSubline
            }
            Spacer(minLength: 4)
            if !station.quality.isEmpty { Text(station.quality).font(.system(size: 10, design: .monospaced)).foregroundStyle(NotchInk.tertiary).lineLimit(1) }
            Button { store.toggleFavourite(station) } label: {
                RadioStarLED(on: store.isFavourite(station.id))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(store.isFavourite(station.id) ? "Remove from favourites" : "Add to favourites")
            .radioRect("star.\(station.id)")
            Menu { RadioStationMenu(station: station, model: model, store: store, page: page) } label: {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).foregroundStyle(NotchInk.secondary)
                    .frame(width: 24, height: 22).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("More")
        }
        .padding(.horizontal, 7).frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isCurrent ? Theme.accent.opacity(0.13) : (hover ? Look.ink(0.06) : Color.clear)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.tap(station) }
        .contextMenu { RadioStationMenu(station: station, model: model, store: store, page: page) }
    }

    /// The place, then up to three genre words after dots; the words give way, last first, when the row is narrow.
    private var miniSubline: some View {
        let tags = Array(station.tags.prefix(3))
        func line(_ n: Int) -> some View {
            let parts = ([station.place].filter { !$0.isEmpty }) + tags.prefix(n)
            return Text(parts.joined(separator: " · ")).font(.system(size: 10.5)).foregroundStyle(NotchInk.secondary).lineLimit(1)
        }
        return ViewThatFits(in: .horizontal) {
            line(tags.count).fixedSize(horizontal: true, vertical: false)
            line(min(2, tags.count)).fixedSize(horizontal: true, vertical: false)
            line(min(1, tags.count)).fixedSize(horizontal: true, vertical: false)
            line(0)
        }
        .frame(height: 14, alignment: .leading)
    }

    private var retroRow: some View {
        HStack(spacing: 9) {
            RadioMonogram(name: station.name, size: 26, playing: isCurrent && service.state != .paused)
            VStack(alignment: .leading, spacing: 1) {
                Text(station.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(isCurrent ? Look.teal : NotchInk.primary)
                subline
            }
            Spacer(minLength: 4)
            if !station.quality.isEmpty { Text(station.quality).font(.system(size: 10, design: .monospaced)).foregroundStyle(NotchInk.tertiary).lineLimit(1) }
            Button { store.toggleFavourite(station) } label: {
                RadioStarLED(on: store.isFavourite(station.id))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(store.isFavourite(station.id) ? "Remove from favourites" : "Add to favourites")
            .radioRect("star.\(station.id)")
            Menu { RadioStationMenu(station: station, model: model, store: store, page: page) } label: {
                Image(systemName: "ellipsis").font(.system(size: 10, weight: .bold)).foregroundStyle(NotchInk.secondary)
                    .frame(width: 22, height: 17)
                    .retroBevel(.raised, cornerRadius: 3, depth: 1, face: Look.isLight ? Retro.Ink.plasticMid : Retro.Ink.plasticDark)   // the ••• key: charcoal in the dark preset, the grey plastic of the other keys on the light one
                    .frame(width: 24, height: 22)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("More")
        }
        .padding(.horizontal, 7).frame(height: 36)
        .background(rowFace)
        .overlay(alignment: .leading) {
            if isCurrent { Retro.Ink.teal.frame(width: 2.5).clipShape(RoundedRectangle(cornerRadius: 1)).padding(.vertical, 4) }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.tap(station) }
        .contextMenu { RadioStationMenu(station: station, model: model, store: store, page: page) }
    }

    private var rowFace: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(isCurrent ? Retro.Ink.teal.opacity(0.16) : (hover ? Look.ink(0.08) : (striped ? RadioInk.stripe : Color.clear)))
    }

    /// The place, then up to three genre chips; the chips give way, last first, when the row is narrow.
    private var subline: some View {
        let place = station.place
        let tags = Array(station.tags.prefix(3))
        func line(_ chips: Int) -> some View {
            HStack(spacing: 6) {
                if !place.isEmpty { Text(place).font(.system(size: 10.5)).foregroundStyle(NotchInk.secondary).lineLimit(1) }
                ForEach(Array(tags.prefix(chips).enumerated()), id: \.offset) { _, tag in RadioGenreChip(tag: tag) }
            }
        }
        return ViewThatFits(in: .horizontal) {
            line(tags.count).fixedSize(horizontal: true, vertical: false)
            line(min(2, tags.count)).fixedSize(horizontal: true, vertical: false)
            line(min(1, tags.count)).fixedSize(horizontal: true, vertical: false)
            line(0)
        }
        .frame(height: 14, alignment: .leading)
    }
}

/// The favourite mark as a little LED: a lit yellow star with a glow when kept, a dark one when not.
struct RadioStarLED: View {
    let on: Bool

    var body: some View {
        if Retro.is8bit {
            Image(systemName: "star.fill")
                .font(.system(size: 11))
                .foregroundStyle(on ? Retro.Ink.yellow : Retro.Ink.yellow.opacity(0.17))
                .shadow(color: on ? Retro.Ink.yellow.opacity(0.85) : .clear, radius: 3)
        } else {
            // The minimal look: an outline star, filled in the accent when kept.
            Image(systemName: on ? "star.fill" : "star")
                .font(.system(size: 11))
                .foregroundStyle(on ? Theme.accent : Look.ink(0.32))
        }
    }
}

/// The ••• menu and the right-click menu of a station.
struct RadioStationMenu: View {
    let station: RadioStation
    @ObservedObject var model: RadioModel
    @ObservedObject var store: RadioStore
    let page: RadioModel.Page

    var body: some View {
        let playing = model.service.station?.id == station.id && model.service.isActive
        Button(playing ? "Pause or resume" : "Play") { model.tap(station) }
        Button(store.isFavourite(station.id) ? "Remove from favourites" : "Add to favourites") { store.toggleFavourite(station) }
        Divider()
        Menu("Add to list") {
            let inLists = store.listsContaining(station.id)
            ForEach(store.lists) { list in
                if inLists.contains(list.id) {
                    Button { store.remove(station.id, fromList: list.id) } label: { Label(list.name, systemImage: "checkmark") }
                } else {
                    Button(list.name) { store.add(station, toList: list.id) }
                }
            }
            if !store.lists.isEmpty { Divider() }
            Button("New list…") { model.newList(adding: station) }
        }
        switch page {
        case .list(let id):
            Divider()
            Button("Move up") { store.move(station.id, inList: id, by: -1) }
            Button("Move down") { store.move(station.id, inList: id, by: 1) }
            Button("Remove from this list") { store.remove(station.id, fromList: id) }
        case .latest:
            Divider()
            Button("Remove from Latest") { store.removeFromLatest(station.id) }
        case .search, .favourites:
            EmptyView()
        }
    }
}

/// A station's tile: its initials on a colour taken from its name, as a small plastic square (no logos are downloaded, so nothing is
/// asked of the station's website just by listing it).
struct RadioMonogram: View {
    let name: String
    var size: CGFloat = 26
    var playing = false

    var body: some View {
        let face = playing ? Retro.Ink.teal : Self.color(for: name)
        Color.clear
            .frame(width: size, height: size)
            .retroBevel(.raised, cornerRadius: max(2, size * 0.14), depth: 1, face: face)
            .overlay {
                if playing {
                    Image(systemName: "waveform").font(.system(size: size * 0.46, weight: .bold)).foregroundStyle(Color.black.opacity(0.8))
                } else {
                    Text(Self.initials(name)).font(.system(size: size * 0.4, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.95))
                }
            }
    }

    static func initials(_ name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }.prefix(2)
        let letters = words.compactMap { $0.first }.map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "♪" : letters
    }

    /// The same colour every time (a stable hash, not Swift's per-launch one).
    static func color(for name: String) -> Color {
        var h: UInt32 = 5381
        for byte in RadioText.fold(name).utf8 { h = h &* 33 &+ UInt32(byte) }
        return Color(hue: Double(h % 360) / 360, saturation: 0.42, brightness: 0.55)
    }
}
