import SwiftUI

// Settings pages for the features code: native grouped forms (like System Settings), hosted by the notch's scroll view.

/// The container every the features code settings page uses.
struct FeaturePane<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        Form { content() }
            .formStyle(.grouped)
            .scrollDisabled(true)
    }
}

/// A grey caption under a row or section.
struct SettingsNote: View {
    let text: Text
    init(_ key: LocalizedStringKey) { self.text = Text(key) }
    init(verbatim: String) { self.text = Text(verbatim: verbatim) }
    var body: some View {
        text.font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A status line with a colored dot: "Ready", "Not installed", "Allowed"…
struct StatusRow: View {
    enum Level { case good, warn, bad, neutral }
    let title: Text
    let status: Text
    var level: Level = .neutral

    /// Both lines are `Text`: `Text("Access")` localizes a literal, `Text(verbatim: name)` shows a user's or an already localized string.
    init(title: Text, status: Text, level: Level = .neutral) { self.title = title; self.status = status; self.level = level }
    init(title: LocalizedStringKey, status: LocalizedStringKey, level: Level = .neutral) { self.init(title: Text(title), status: Text(status), level: level) }

    private var color: Color {
        switch level {
        case .good: .green
        case .warn: .orange
        case .bad: .red
        case .neutral: .secondary
        }
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                status.foregroundStyle(.secondary)
            }
        } label: { title }
    }
}
