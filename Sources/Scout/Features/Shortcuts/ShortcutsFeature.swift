import SwiftUI

@MainActor
enum ShortcutsFeature {
    static func start() {}

    static func registerGallery() {
        FeatureGallery.widget("shortcuts-widget", span: 3) {
            ShortcutsWidgetView(preview: ["Morning routine", "Start focus", "Log water", "New note", "Play playlist", "Lock screen"])
        }
        FeatureGallery.widget("shortcuts-widget-empty", span: 3) { ShortcutsWidgetView(preview: []) }
        FeatureGallery.settings("settings-widgets", height: 1100) { WidgetsSettingsPane() }
    }
}
