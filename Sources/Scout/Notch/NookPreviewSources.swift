import SwiftUI

/// A live panel made of plain values: gallery scenes and self-tests hand these to `LivePanelLookup.override` to show how the dashboard
/// lays out and expands live panels (a meeting, a download, a timer) without any real service. The real panels are `LivePanels`'.
@MainActor
final class PreviewLivePanel: LivePanelSource {
    let id: String
    let title: String
    let symbol: String
    var isLive = true
    var priority = 0
    let span: Int
    let expandTo: WorkspaceKind?
    private let view: () -> AnyView

    init(id: String, title: String, symbol: String, span: Int, expandTo: WorkspaceKind? = nil, @ViewBuilder view: @escaping () -> some View) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.span = span
        self.expandTo = expandTo
        self.view = { AnyView(view()) }
    }

    func makeView() -> AnyView { view() }
}
