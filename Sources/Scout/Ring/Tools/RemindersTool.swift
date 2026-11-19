import AppKit
import EventKit
import SwiftUI

// B2 Reminders (P2): incomplete reminders of the default list, add with a due time, check off.
// Access is asked on first open; scripted runs use sample data and never touch EventKit.

struct ReminderRow: Identifiable, Equatable {
    var id: String
    var title: String
    var due: Date?
    var isDone = false
}

enum ReminderDue: String, CaseIterable, Identifiable {
    case none, hour, tonight, tomorrow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: String(localized: "No date")
        case .hour: String(localized: "In an hour")
        case .tonight: String(localized: "Tonight")
        case .tomorrow: String(localized: "Tomorrow")
        }
    }

    func date(from now: Date = Date()) -> Date? {
        let cal = Calendar.current
        switch self {
        case .none: return nil
        case .hour: return now.addingTimeInterval(3600)
        case .tonight:
            let tonight = cal.date(bySettingHour: 20, minute: 0, second: 0, of: now) ?? now
            return tonight > now ? tonight : cal.date(byAdding: .day, value: 1, to: tonight)
        case .tomorrow:
            let t = cal.date(byAdding: .day, value: 1, to: now) ?? now
            return cal.date(bySettingHour: 9, minute: 0, second: 0, of: t)
        }
    }
}

@MainActor
final class RemindersModel: ObservableObject {
    static let shared = RemindersModel()

    enum Access { case unknown, granted, denied }

    @Published private(set) var items: [ReminderRow] = []
    @Published private(set) var access: Access = .unknown
    @Published private(set) var listName = String(localized: "Reminders")

    private let store = EKEventStore()
    private var ekItems: [String: EKReminder] = [:]

    init() {
        if ScoutRuntime.isScripted {
            access = .granted
            let now = Date()
            items = [ReminderRow(id: "1", title: "Call the dentist", due: now.addingTimeInterval(3600)),
                     ReminderRow(id: "2", title: "Buy stamps", due: nil),
                     ReminderRow(id: "3", title: "Send the invoice to Marta", due: Calendar.current.date(byAdding: .day, value: 1, to: now)),
                     ReminderRow(id: "4", title: "Water the plants", due: nil)]
        }
    }

    /// Asks for access the first time, then loads.
    func open() {
        guard !ScoutRuntime.isScripted else { return }
        store.requestFullAccessToReminders { [weak self] granted, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.access = granted ? .granted : .denied
                    if granted { self.reload() }
                }
            }
        }
    }

    func reload() {
        guard !ScoutRuntime.isScripted else { return }
        let calendar = store.defaultCalendarForNewReminders()
        listName = calendar?.title ?? String(localized: "Reminders")
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendar.map { [$0] })
        store.fetchReminders(matching: predicate) { [weak self] reminders in
            let rows: [(ReminderRow, EKReminder)] = (reminders ?? []).map { r in
                (ReminderRow(id: r.calendarItemIdentifier, title: r.title ?? String(localized: "Untitled"), due: r.dueDateComponents.flatMap { Calendar.current.date(from: $0) }), r)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.ekItems = Dictionary(uniqueKeysWithValues: rows.map { ($0.0.id, $0.1) })
                    self.items = rows.map(\.0).sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
                }
            }
        }
    }

    func add(_ title: String, due: ReminderDue) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if ScoutRuntime.isScripted {
            items.insert(ReminderRow(id: UUID().uuidString, title: clean, due: due.date()), at: 0)   // sample list only; no real reminder
            return
        }
        let r = EKReminder(eventStore: store)
        r.title = clean
        r.calendar = store.defaultCalendarForNewReminders()
        if let date = due.date() {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            if due != .none { r.addAlarm(EKAlarm(absoluteDate: date)) }
        }
        do {
            try store.save(r, commit: true)
            reload()
        } catch {
            Toast.show("Couldn't save the reminder", symbol: "exclamationmark.triangle.fill", style: .error)
        }
    }

    func toggle(_ row: ReminderRow) {
        if ScoutRuntime.isScripted {
            if let i = items.firstIndex(where: { $0.id == row.id }) { items[i].isDone.toggle() }
            return
        }
        guard let r = ekItems[row.id] else { return }
        r.isCompleted = true
        try? store.save(r, commit: true)
        items.removeAll { $0.id == row.id }
    }
}

@MainActor
enum RemindersPanel {
    static func show() {
        RemindersModel.shared.open()
        let draft = ToolMemory.load(RemindersDraft.self, ToolMemory.reminderDraft)
        ToolPanels.show("reminders", size: CGSize(width: 360, height: 440), minSize: CGSize(width: 320, height: 320), resizable: true) {
            RemindersView(title: draft?.title ?? "", due: draft.flatMap { ReminderDue(rawValue: $0.due) } ?? .none)
        }
    }
}

/// The reminder being typed when the panel closed.
struct RemindersDraft: Codable, Equatable {
    var title: String
    var due: String
}

struct RemindersView: View {
    @ObservedObject var model: RemindersModel
    @State private var title: String
    @State private var due: ReminderDue
    @FocusState private var focused: Bool

    init(model: RemindersModel? = nil, title: String = "", due: ReminderDue = .none) {
        self.model = model ?? RemindersModel.shared
        _title = State(initialValue: title)
        _due = State(initialValue: due)
    }

    var body: some View {
        ToolPanelFrame("Reminders", symbol: "bell", accessory: {
            Text(model.listName).font(.system(size: 11)).foregroundStyle(.secondary)
        }) {
            if model.access == .denied {
                ToolEmptyState(symbol: "lock.shield", message: String(localized: "Scout needs access to your reminders."), actionTitle: String(localized: "Open System Settings")) {
                    Permissions.openSettings(.reminders)
                }
            } else {
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent)
                        TextField("New reminder", text: $title).textFieldStyle(.plain).font(.system(size: 13.5)).focused($focused).onSubmit(add)
                        Picker("", selection: $due) { ForEach(ReminderDue.allCases) { Text($0.title).tag($0) } }
                            .labelsHidden().frame(width: 110).controlSize(.small)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
                    .padding(.horizontal, 12)
                    if model.items.isEmpty {
                        ToolEmptyState(symbol: "checkmark.circle", message: String(localized: "No open reminders."))
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 1) {
                                ForEach(model.items) { row in
                                    HStack(spacing: 9) {
                                        Button { model.toggle(row) } label: {
                                            Image(systemName: row.isDone ? "checkmark.circle.fill" : "circle").font(.system(size: 17))
                                                .foregroundStyle(row.isDone ? Theme.accent : Color.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(row.title).font(.system(size: 13.5)).strikethrough(row.isDone).lineLimit(2)
                                            if let d = row.due {
                                                Text(d.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11))
                                                    .foregroundStyle(d < Date() ? Color.red : Color.secondary)
                                            }
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                }
                            }
                            .padding(.horizontal, 6)
                        }
                    }
                }
                .padding(.bottom, 10)
            }
        }
        .onAppear { focused = true }
        .onChange(of: title) { _, _ in saveDraft() }
        .onChange(of: due) { _, _ in saveDraft() }
    }

    private func saveDraft() {
        ToolMemory.save(title.isEmpty && due == .none ? nil : RemindersDraft(title: title, due: due.rawValue), ToolMemory.reminderDraft)
    }

    private func add() {
        model.add(title, due: due)
        title = ""
    }
}
