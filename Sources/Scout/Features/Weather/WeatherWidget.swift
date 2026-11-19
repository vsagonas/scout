import SwiftUI

/// Nook widget: condition, big temperature, high/low, place; the next hours when wide. Tap opens Weather.
/// It follows the dashboard's grid (`DashGrid`) and lies on the one screen like every panel, with no card or colour of its own.
/// row 1 the temperature at the grid's digit height with the condition's symbol, row 2 the place and the condition in the info
/// font, then the high and low and, when the panel is wide, the next hours.
struct WeatherWidgetView: View {
    @ObservedObject private var service = WeatherService.shared
    @AppStorage(WeatherService.Key.unit) private var unitRaw = TemperatureUnit.automatic.rawValue

    /// Gallery only: show this snapshot / state instead of the service's.
    private var previewSnapshot: WeatherSnapshot?
    private var previewState: WeatherService.State?

    init() {}
    init(preview: WeatherSnapshot) { previewSnapshot = preview }
    init(previewState: WeatherService.State) { self.previewState = previewState }

    private var shown: WeatherSnapshot? { previewState != nil ? nil : (previewSnapshot ?? service.snapshot) }
    private var shownState: WeatherService.State { previewState ?? service.state }

    private var unit: TemperatureUnit { TemperatureUnit(rawValue: unitRaw) ?? .automatic }

    var body: some View {
        GeometryReader { geo in
            content(wide: geo.size.width >= 220, width: geo.size.width)
                .padding(DashGrid.inset)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .notchContent()
        .onAppear { if previewSnapshot == nil && previewState == nil { service.widgetAppeared() } }
        .onDisappear { if previewSnapshot == nil && previewState == nil { service.widgetDisappeared() } }
    }

    @ViewBuilder private func content(wide: Bool, width: CGFloat) -> some View {
        if let s = shown {
            weather(s, wide: wide, width: width)
                .contentShape(Rectangle())
                .onTapGesture { service.openWeatherApp() }
        } else {
            status
        }
    }

    /// "21°" as the grid's digits ("21", "-4") and the degree sign beside them.
    static func digits(_ formatted: String) -> String { formatted.filter { "0123456789-".contains($0) } }

    private func weather(_ s: WeatherSnapshot, wide: Bool, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DashReadout {
                // The degree sign: part of the digits in the minimal look; a small LCD ring at the digits' top in the 8-bit one (the segments
                // have no degree sign).
                DashDigits(text: Self.digits(unit.format(s.temperature)) + (Retro.is8bit ? "" : "°"), color: Dash90.surfaceAmber)
                if Retro.is8bit {
                    Circle().strokeBorder(Dash90.surfaceAmber, lineWidth: 1.6).frame(width: 6, height: 6)
                        .alignmentGuide(.lastTextBaseline) { _ in DashGrid.digitHeight }
                }
                Spacer(minLength: 4)
                Image(systemName: s.symbol).symbolRenderingMode(.multicolor).font(.system(size: 17))
            }
            Color.clear.frame(height: DashGrid.readoutGap)
            ViewThatFits(in: .horizontal) {
                placeLine(s, label: true)
                placeLine(s, label: false)
            }
            Color.clear.frame(height: DashGrid.bodyGap)
            VStack(alignment: .leading, spacing: 4) {
                Text("H:\(unit.format(s.high))  L:\(unit.format(s.low))").font(DashGrid.infoFont()).foregroundStyle(NotchInk.secondary).lineLimit(1)
                if wide { hours(s, count: max(2, min(8, Int((width - DashGrid.inset.leading - DashGrid.inset.trailing) / 36)))) }
            }
            .reportDashRow("body")
        }
    }

    /// Row 2: the place (with the arrow when it follows you) and the condition.
    private func placeLine(_ s: WeatherSnapshot, label: Bool) -> some View {
        DashInfoLine {
            if service.isAutomatic { Image(systemName: "location.fill").font(.system(size: 8)).foregroundStyle(NotchInk.tertiary) }
            Text(s.place).font(DashGrid.infoFont(.semibold)).foregroundStyle(NotchInk.primary).fixedSize()
            if label { Text(s.label).fixedSize() }
            Spacer(minLength: 0)
        }
    }

    private func hours(_ s: WeatherSnapshot, count: Int) -> some View {
        let start = Calendar.current.dateInterval(of: .hour, for: Date())?.start ?? Date()
        let next = s.hours.filter { $0.time >= start }.prefix(count)
        return HStack(spacing: 4) {
            ForEach(Array(next), id: \.time) { h in
                VStack(spacing: 2) {
                    (h.time == start ? Text("Now") : Text(verbatim: Self.compactHour(h.time)))
                        .font(DashGrid.infoFont()).foregroundStyle(NotchInk.tertiary).lineLimit(1)
                    Image(systemName: WeatherKind(code: h.code).symbol(day: h.isDay)).symbolRenderingMode(.multicolor).font(.system(size: 13))
                        .frame(height: 18)
                    Text(unit.format(h.temperature)).font(DashGrid.infoFont(.semibold)).foregroundStyle(NotchInk.primary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 4)
    }

    /// The hour as short as the person's language writes it ("1 p", "13"): for a narrow column.
    static func compactHour(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.defaultDigits(amPM: .narrow)))
    }

    /// No weather yet: the grid's empty line, with the key that helps.
    @ViewBuilder private var status: some View {
        switch shownState {
        case .needsLocation:
            DashEmpty(symbol: "location", title: "Weather near you", detail: "Uses your approximate location.",
                      actionTitle: "Use my location") { service.askForLocation() }
        case .locationDenied:
            DashEmpty(symbol: "location.slash", title: "Location is off", detail: "Allow it in System Settings, or pick a city.",
                      actionTitle: "Open Settings") { Permissions.openSettings(.location) }
        case .needsCity:
            DashEmpty(symbol: "magnifyingglass", title: "Choose a city", actionTitle: "Weather settings") {
                SettingsWindowController.shared.show(.weather)
            }
        case .failed(let message):
            DashEmpty(symbol: "wifi.slash", title: .verbatim(message), actionTitle: "Try again") { service.refresh() }
        default:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
