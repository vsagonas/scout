import SwiftUI

@MainActor
enum WeatherFeature {
    static func start() {
        DebugCommands.register("weather.refresh") { _ in WeatherService.shared.refresh() }
    }

    static func registerGallery() {
        // The widget in different skies (sample data is injected through the service in scripted runs).
        let kinds: [(String, WeatherKind, Bool)] = [("clear-day", .clear, true), ("partly-day", .partly, true), ("rain", .rain, true),
                                                    ("snow", .snow, true), ("clear-night", .clear, false), ("thunder", .thunder, false)]
        for (name, kind, day) in kinds {
            FeatureGallery.widget("weather-widget-\(name)", span: 3) {
                WeatherWidgetView(preview: WeatherSamples.snapshot(kind: kind, day: day))
            }
        }
        FeatureGallery.widget("weather-widget-wide", span: 5) { WeatherWidgetView(preview: WeatherSamples.snapshot(kind: .partly, day: true)) }
        FeatureGallery.widget("weather-widget-needs-location", span: 3) { WeatherWidgetView(previewState: .needsLocation) }
        FeatureGallery.settings("settings-weather", height: 600) { WeatherSettingsPane() }
    }
}
