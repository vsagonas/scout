import SwiftUI

// The building blocks of the Mac App Store screenshots. Each screenshot is one 1440 x 900 point screen:
// our own calm wallpaper, a menu bar with the camera notch, the real Scout views with sample data, and one
// headline with a one-line subline. The gallery renders it at 2x, so the files are 2880 x 1800 (16:10).

/// The screen every scene is drawn on.
enum StoreScreen {
    static let size = CGSize(width: 1440, height: 900)
    static let notch = NotchGeometry.sample16
}

// MARK: - Wallpaper

/// Colour families for the scenes' own gradient wallpapers (no photos).
enum StoreTint {
    case sky, rose, mint, sand, lilac, ocean, peach

    /// Three base stops (top-left to bottom-right) and two soft glows.
    fileprivate func stops(dark: Bool) -> (base: [Color], glowA: Color, glowB: Color) {
        func c(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
        switch (self, dark) {
        case (.sky, false): return ([c(0.71, 0.83, 0.99), c(0.82, 0.80, 0.98), c(0.98, 0.86, 0.84)], c(1.0, 0.93, 0.86), c(0.62, 0.80, 0.98))
        case (.sky, true): return ([c(0.07, 0.11, 0.26), c(0.17, 0.12, 0.30), c(0.30, 0.13, 0.27)], c(0.35, 0.22, 0.52), c(0.10, 0.28, 0.50))
        case (.rose, false): return ([c(0.99, 0.84, 0.82), c(0.97, 0.80, 0.88), c(0.84, 0.82, 0.98)], c(1.0, 0.90, 0.78), c(0.90, 0.78, 0.98))
        case (.rose, true): return ([c(0.28, 0.10, 0.16), c(0.24, 0.10, 0.27), c(0.12, 0.12, 0.30)], c(0.52, 0.20, 0.30), c(0.30, 0.16, 0.50))
        case (.mint, false): return ([c(0.78, 0.93, 0.88), c(0.74, 0.90, 0.94), c(0.82, 0.86, 0.98)], c(0.90, 0.98, 0.84), c(0.66, 0.86, 0.98))
        case (.mint, true): return ([c(0.05, 0.20, 0.20), c(0.06, 0.18, 0.28), c(0.14, 0.13, 0.30)], c(0.10, 0.36, 0.30), c(0.12, 0.26, 0.48))
        case (.sand, false): return ([c(0.99, 0.91, 0.78), c(0.99, 0.84, 0.76), c(0.92, 0.82, 0.92)], c(1.0, 0.95, 0.72), c(0.98, 0.76, 0.74))
        case (.sand, true): return ([c(0.26, 0.17, 0.08), c(0.28, 0.12, 0.12), c(0.20, 0.11, 0.24)], c(0.50, 0.32, 0.10), c(0.48, 0.16, 0.20))
        case (.lilac, false): return ([c(0.86, 0.82, 0.99), c(0.80, 0.84, 0.99), c(0.95, 0.84, 0.94)], c(0.96, 0.88, 1.0), c(0.70, 0.82, 1.0))
        case (.lilac, true): return ([c(0.14, 0.10, 0.30), c(0.10, 0.13, 0.30), c(0.24, 0.11, 0.28)], c(0.34, 0.20, 0.54), c(0.14, 0.24, 0.52))
        case (.ocean, false): return ([c(0.66, 0.86, 0.96), c(0.72, 0.88, 0.92), c(0.80, 0.84, 0.98)], c(0.84, 0.97, 0.90), c(0.60, 0.78, 0.97))
        case (.ocean, true): return ([c(0.04, 0.16, 0.26), c(0.05, 0.20, 0.27), c(0.12, 0.15, 0.30)], c(0.06, 0.34, 0.40), c(0.10, 0.22, 0.50))
        case (.peach, false): return ([c(1.0, 0.87, 0.78), c(0.99, 0.82, 0.82), c(0.88, 0.84, 0.98)], c(1.0, 0.93, 0.70), c(0.96, 0.74, 0.80))
        case (.peach, true): return ([c(0.28, 0.14, 0.09), c(0.27, 0.10, 0.17), c(0.15, 0.11, 0.28)], c(0.52, 0.28, 0.12), c(0.46, 0.14, 0.26))
        }
    }
}

struct StoreWallpaper: View {
    let tint: StoreTint
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = tint.stops(dark: scheme == .dark)
        ZStack {
            LinearGradient(colors: s.base, startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [s.glowA.opacity(0.65), .clear], center: UnitPoint(x: 0.80, y: 0.85), startRadius: 0, endRadius: 760)
            RadialGradient(colors: [s.glowB.opacity(0.55), .clear], center: UnitPoint(x: 0.10, y: 0.62), startRadius: 0, endRadius: 640)
            RadialGradient(colors: [s.glowA.opacity(0.35), .clear], center: UnitPoint(x: 0.55, y: 0.08), startRadius: 0, endRadius: 520)
        }
    }
}

// MARK: - Menu bar

/// The top strip of the screen: translucent menu bar, the camera notch, and a few menu extras (one is Scout's).
/// `menus` and `extras` say how many menu titles (Finder, File, Edit, View, Go, Window) and menu extras (date,
/// Wi-Fi, battery, Scout) are drawn: an open notch panel covers the middle of the bar like it does on a real
/// screen, so the scenes only draw what stays visible and never a half-hidden glyph.
struct StoreMenuBar: View {
    var menus = 6
    var extras = 4
    @Environment(\.colorScheme) private var scheme

    private var clock: String {
        let cal = Calendar.current
        let day = cal.date(bySettingHour: 9, minute: 41, second: 0, of: Date()) ?? Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = extras > 1 ? "EEE MMM d  h:mm a" : "EEE h:mm a"   // short clock when the open notch leaves little room
        return f.string(from: day)
    }

    var body: some View {
        let ink = scheme == .dark ? Color.white : Color.black
        ZStack(alignment: .top) {
            Rectangle().fill(scheme == .dark ? Color.black.opacity(0.30) : Color.white.opacity(0.46))
                .frame(height: StoreScreen.notch.size.height)
            HStack(spacing: 18) {
                Image(systemName: "applelogo").font(.system(size: 14))
                ForEach(Array(["Finder", "File", "Edit", "View", "Go", "Window"].prefix(menus).enumerated()), id: \.offset) { i, title in
                    Text(title).font(.system(size: 13, weight: i == 0 ? .bold : .regular))
                }
                Spacer()
                if extras > 3 { Image(nsImage: AppIconInUse.menuBarImage).renderingMode(.template) }   // Scout's own menu bar face, as the real menu bar draws it
                if extras > 2 { Image(systemName: "battery.75percent").font(.system(size: 14)) }
                if extras > 1 { Image(systemName: "wifi").font(.system(size: 13)) }
                if extras > 0 { Text(clock).font(.system(size: 13)).monospacedDigit() }
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 16)
            .frame(height: StoreScreen.notch.size.height)
            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous)
                .fill(Color.black)
                .frame(width: StoreScreen.notch.size.width, height: StoreScreen.notch.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Caption (headline + subline)

struct StoreCaption: View {
    let headline: String
    let subline: String
    var alignment: HorizontalAlignment = .center
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = scheme == .dark ? Color.white : Color(white: 0.09)
        VStack(alignment: alignment, spacing: 16) {
            Text(headline)
                .font(.system(size: 72, weight: .bold))
                .tracking(-1.6)
                .foregroundStyle(ink)
            Text(subline)
                .font(.system(size: 29, weight: .regular))
                .foregroundStyle(ink.opacity(scheme == .dark ? 0.72 : 0.66))
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - A calm desktop behind the ring and the panels

/// A soft, abstract app window (no real app is drawn): title bar dots and a few bars of "content".
struct StoreMockWindow: View {
    var width: CGFloat
    var height: CGFloat
    var accent: Color = Theme.amber
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let bar = (dark ? Color.white : Color.black).opacity(dark ? 0.16 : 0.10)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 11, height: 11)
                Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 11, height: 11)
                Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25)).frame(width: 11, height: 11)
                Spacer()
            }
            .padding(.horizontal, 14).frame(height: 36)
            VStack(alignment: .leading, spacing: 11) {
                RoundedRectangle(cornerRadius: 5).fill(accent.opacity(0.55)).frame(width: width * 0.34, height: 14)
                ForEach(0..<max(1, Int((height - 90) / 24)), id: \.self) { i in
                    RoundedRectangle(cornerRadius: 4).fill(bar).frame(width: width * (i % 3 == 0 ? 0.78 : (i % 3 == 1 ? 0.62 : 0.70)), height: 9)
                }
            }
            .padding(.horizontal, 22).padding(.top, 10)
            Spacer(minLength: 0)
        }
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(dark ? Color(white: 0.13, opacity: 0.88) : Color(white: 1.0, opacity: 0.66)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder((dark ? Color.white : Color.black).opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(dark ? 0.40 : 0.14), radius: 24, y: 10)
    }
}

// MARK: - The notch on the screen

/// The real `NotchRootView` on a panel as wide as the (logical) screen of the scene, centred at the top. The open island's height is never
/// chosen here: it is what the app itself gives that view (180 pt for the dashboard, `NotchPrefs.minimumOpenHeight(for:)`, the height the
/// view asks its notch for), so a picture can never show another height than the app opens at.
/// The panel is as tall as the screen, so nothing clips the island.
@MainActor
struct StoreNotch: View {
    let screenWidth: CGFloat
    let panelHeight: CGFloat
    @ObservedObject private var model: NotchScreenModel
    @ObservedObject private var center: LiveActivityCenter
    @ObservedObject private var navigator: NotchNavigator
    @ObservedObject private var nook: NookStore

    /// What the Mac App Store edition offers in the notch header (everything but the Terminal), in the app's own order.
    static let workspaces: [WorkspaceKind] = [.nook, .askAI, .tray, .calendar, .clipboard, .agents, .prompter, .music]

    /// `live` stands in for what plays, what is open and what runs (the Nook's agentic row); `detail` is the pointer resting
    /// on the closed notch (the hover list under the wings). `request` is the height the shown view asks its notch for, taken from the view's
    /// own function (a view that asks through the app's shared notch cannot reach this scene's own navigator).
    init(screenWidth: CGFloat, open: Bool, workspace: WorkspaceKind = .nook, openWidth: CGFloat = 1040, panelHeight: CGFloat = StoreScreen.size.height,
         layout: [WidgetKind]? = nil, live: NookLive? = nil, drop: Bool = false, detail: Bool = false, request: CGFloat? = nil,
         setup: (LiveActivityCenter) -> Void = { _ in }) {
        UserDefaults.standard.set(Double(openWidth), forKey: "notch.openWidth")
        UserDefaults.standard.set(Self.workspaces.map(\.rawValue).joined(separator: ","), forKey: "notch.workspaces")
        UserDefaults.standard.set("classic", forKey: "notch.style")
        self.screenWidth = screenWidth
        self.panelHeight = panelHeight
        let model = NotchScreenModel(geometry: StoreScreen.notch, panelSize: CGSize(width: screenWidth, height: panelHeight))
        model.isOpen = open
        model.detailVisible = detail
        let center = LiveActivityCenter()
        setup(center)
        let navigator = NotchNavigator()
        navigator.workspace = workspace
        navigator.isDropTargeting = drop
        if let request { navigator.requestHeight(request, resizeMax: nil, by: workspace) }
        self.model = model
        self.center = center
        self.navigator = navigator
        let nook = NookStore(persist: false, layout: layout)
        nook.liveOverride = live
        self.nook = nook
    }

    var body: some View {
        NotchRootView(model: model, center: center, navigator: navigator, nook: nook, styleOverride: .classic)
            .frame(width: screenWidth, height: panelHeight, alignment: .top)
    }
}

// MARK: - A full scene

/// Wallpaper + screen layer + caption, 1440 x 900 points.
/// The notch UI is small on a real screen, and App Store thumbnails are small too, so the notch scenes magnify
/// the "screen": its logical size is (1440 / zoom) x (900 / zoom) points, drawn zoom times larger. Menu bar,
/// notch and panels are scaled together, so the menu bar still runs edge to edge. The same vector drawing
/// scaled up stays crisp at 2880 x 1800. The screen closure gets the logical screen width.
struct StoreScene<Screen: View, Caption: View>: View {
    let tint: StoreTint
    var zoom: CGFloat = 1
    var menus = 6
    var extras = 4
    @ViewBuilder var screen: (CGFloat) -> Screen
    @ViewBuilder var caption: () -> Caption

    var body: some View {
        let width = StoreScreen.size.width / zoom
        ZStack(alignment: .topLeading) {
            StoreWallpaper(tint: tint)
            ZStack(alignment: .topLeading) {
                StoreMenuBar(menus: menus, extras: extras)
                screen(width)
            }
            .frame(width: width, height: StoreScreen.size.height / zoom, alignment: .topLeading)
            .scaleEffect(zoom, anchor: .topLeading)
            caption()
        }
        .frame(width: StoreScreen.size.width, height: StoreScreen.size.height, alignment: .topLeading)
        .clipped()
    }
}
