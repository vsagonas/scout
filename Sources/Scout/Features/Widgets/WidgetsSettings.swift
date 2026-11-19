import SwiftUI

/// "Mirror, Pulse & Shortcuts": one page, one section per widget.
struct WidgetsSettingsPane: View {
    var body: some View {
        FeaturePane {
            MirrorSettingsSection()
            PulseSettingsSection()
            ShortcutsSettingsSection()
        }
    }
}
