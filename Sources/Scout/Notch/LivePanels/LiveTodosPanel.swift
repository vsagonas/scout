import Combine
import SwiftUI

// live.todos: while there are open (unchecked) to-dos. The count and the first three, overdue and due-today first, each
// with a checkbox that completes it.

struct LiveTodo: Equatable, Identifiable {
    var id: UUID
    var title: String
    var day: Date?   // start of the planned day
}

struct LiveTodosSnapshot: Equatable {
    var open: [LiveTodo] = []   // in the store's order (newest first)
}

@MainActor
final class LiveTodosPanel: LiveDriven {
    static let rows = 3

    let id = "live.todos"
    let title = String(localized: "To-dos")
    let symbol = "checklist"
    let priority = 10
    let span = 4

    let feed: LiveFeed<LiveTodosSnapshot>
    private let complete: (UUID) -> Void

    var changes: AnyPublisher<Void, Never> { feed.changes }
    var isLive: Bool { !feed.value.open.isEmpty }

    /// The to-dos are part of the Calendar view.
    var expandTo: WorkspaceKind? { .calendar }

    init(feed: LiveFeed<LiveTodosSnapshot>, complete: @escaping (UUID) -> Void) {
        self.feed = feed
        self.complete = complete
    }

    static func live() -> LiveTodosPanel {
        let store = TodoStore.shared
        let feed = LiveFeed<LiveTodosSnapshot>(read: {
            LiveTodosSnapshot(open: store.tasks.filter { !$0.done }.map { LiveTodo(id: $0.id, title: $0.title, day: $0.day) })
        }, triggers: [store.liveTrigger])
        return LiveTodosPanel(feed: feed) { TodoStore.shared.toggle($0) }
    }

    enum Urgency: Int, Comparable {
        case overdue, today, other
        static func < (a: Urgency, b: Urgency) -> Bool { a.rawValue < b.rawValue }
    }

    static func urgency(_ todo: LiveTodo, now: Date) -> Urgency {
        guard let day = todo.day else { return .other }
        let today = Calendar.current.startOfDay(for: now)
        if day < today { return .overdue }
        return Calendar.current.isDate(day, inSameDayAs: today) ? .today : .other
    }

    /// Overdue (oldest day first), due today, then the rest as the store has them (undated before later days).
    static func ordered(_ todos: [LiveTodo], now: Date) -> [LiveTodo] {
        todos.enumerated().sorted { a, b in
            let ua = urgency(a.element, now: now), ub = urgency(b.element, now: now)
            if ua != ub { return ua < ub }
            if ua == .overdue, let da = a.element.day, let db = b.element.day, da != db { return da < db }
            if ua == .other, (a.element.day == nil) != (b.element.day == nil) { return a.element.day == nil }
            if ua == .other, let da = a.element.day, let db = b.element.day, da != db { return da < db }
            return a.offset < b.offset
        }.map(\.element)
    }

    func makeView() -> AnyView { AnyView(LiveTodosView(feed: feed, complete: complete)) }
}

// MARK: - View

struct LiveTodosView: View {
    @ObservedObject var feed: LiveFeed<LiveTodosSnapshot>
    var clock: () -> Date = Date.init
    var complete: (UUID) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in   // a to-do turns overdue at midnight
            let now = clock()
            let open = LiveTodosPanel.ordered(feed.value.open, now: now)
            let shown = Array(open.prefix(LiveTodosPanel.rows))
            let overdue = open.filter { LiveTodosPanel.urgency($0, now: now) == .overdue }.count
            LiveRetroFrame(symbol: "checklist", title: "To-dos", tint: Retro.Ink.purple, trailing: {
                if overdue > 0 { LampOrMini(text: String(localized: "\(overdue) overdue")) } else { LiveRetroFact(text: String(localized: "\(open.count) open")) }
            }) {
                if Retro.is8bit {
                    Dash90LCD(padding: 4, fill: true) {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(shown) { todo in row(todo, now: now) }
                            if open.count > shown.count {
                                Dash90Text(String(localized: "+\(open.count - shown.count) more"), pixel: 1, color: Dash90.amber.opacity(0.8)).padding(.leading, 3).padding(.top, 2)
                            }
                        }
                    }
                } else {
                    // The minimal look: a plain list, a ring for each open to-do (red when overdue, the accent when due today).
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(shown) { todo in miniRow(todo, now: now) }
                        if open.count > shown.count {
                            Text("+\(open.count - shown.count) more").font(.system(size: 10.5)).foregroundStyle(NotchInk.secondary).padding(.leading, 5).padding(.top, 2)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The colour of a to-do's box: red when overdue, amber when due today, green otherwise.
    static func boxTint(_ urgency: LiveTodosPanel.Urgency) -> Color {
        switch urgency {
        case .overdue: Retro.Ink.ledRed
        case .today: Dash90.amber
        case .other: Dash90.green
        }
    }

    private func miniRow(_ todo: LiveTodo, now: Date) -> some View {
        let urgency = LiveTodosPanel.urgency(todo, now: now)
        let ring: Color = urgency == .overdue ? Color(red: 1.0, green: 0.35, blue: 0.30) : (urgency == .today ? Theme.accent : Look.ink(0.45))
        return HStack(spacing: 7) {
            Button { complete(todo.id) } label: {
                Image(systemName: "circle").font(.system(size: 13)).foregroundStyle(ring).padding(3).contentShape(Rectangle())
            }
            .buttonStyle(.plain).liveControl().help("Mark as done")
            .accessibilityLabel("Mark as done")
            Text(todo.title).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 2)
        }
        .frame(height: 22)
    }

    private func row(_ todo: LiveTodo, now: Date) -> some View {
        let urgency = LiveTodosPanel.urgency(todo, now: now)
        return HStack(spacing: 6) {
            Button { complete(todo.id) } label: {
                Dash90Box(checked: false, tint: Self.boxTint(urgency), size: 14).padding(3).contentShape(Rectangle())
            }
            .buttonStyle(.plain).liveControl().help("Mark as done")
            Text(todo.title).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 2)
        }
        .frame(height: 21)
    }
}
