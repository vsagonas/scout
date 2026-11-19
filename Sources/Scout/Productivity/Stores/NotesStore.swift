import AppKit
import SwiftUI

// B3 — notes (the scratchpad panel and the Notes widget share this), to-dos and saved links.

struct ScoutNote: Identifiable, Codable, Equatable {
    var id = UUID()
    var text = ""
    var created = Date()
    var modified = Date()

    var title: String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.isEmpty ? String(localized: "New note") : String(line.prefix(60))
    }

    /// The text after the title line, for list subtitles.
    var snippet: String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.dropFirst().joined(separator: " ")
    }
}

@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    @Published private(set) var notes: [ScoutNote] = []
    /// The note the widget and panel have selected.
    @Published var selectedID: UUID?

    private let file = JSONFile<[ScoutNote]>("notes.json")
    private let saver = Debouncer(delay: 0.6)
    private var persists: Bool { !ScoutRuntime.isScripted }

    init() {
        if ScoutRuntime.isScripted {
            notes = Self.sampleNotes()
        } else {
            notes = file.load() ?? []
        }
        notes.sort { $0.modified > $1.modified }
        selectedID = notes.first?.id
    }

    var selected: ScoutNote? { notes.first { $0.id == selectedID } }

    func note(_ id: UUID) -> ScoutNote? { notes.first { $0.id == id } }

    @discardableResult
    func add(text: String = "") -> ScoutNote {
        let note = ScoutNote(text: text)
        notes.insert(note, at: 0)
        selectedID = note.id
        save()
        return note
    }

    /// Edits keep the list order stable while typing; the order refreshes when the list is next opened.
    func update(_ id: UUID, text: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].text != text else { return }
        notes[i].text = text
        notes[i].modified = Date()
        save()
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        if selectedID == id { selectedID = notes.first?.id }
        save()
    }

    func resort() { notes.sort { $0.modified > $1.modified } }

    func search(_ query: String) -> [ScoutNote] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return notes }
        return notes.filter { $0.text.lowercased().contains(q) }
    }

    func recent(_ count: Int) -> [ScoutNote] { Array(notes.sorted { $0.modified > $1.modified }.prefix(count)) }

    private func save() {
        guard persists else { return }
        saver.call { [weak self] in
            guard let self else { return }
            self.file.save(self.notes)
        }
    }

    // MARK: Export

    enum ExportFormat: String, CaseIterable, Identifiable {
        case txt, md, rtf, pdf
        var id: String { rawValue }
        var title: String { rawValue.uppercased() }
    }

    /// Asks where to save, then writes the note. Only on click.
    func export(_ note: ScoutNote, as format: ExportFormat) {
        guard !ScoutRuntime.isScripted else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(note.title).\(format.rawValue)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch format {
            case .txt, .md:
                try note.text.write(to: url, atomically: true, encoding: .utf8)
            case .rtf:
                let attributed = NSAttributedString(string: note.text, attributes: [.font: NSFont.systemFont(ofSize: 13)])
                let data = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                try data.write(to: url)
            case .pdf:
                let view = NSTextView(frame: CGRect(x: 0, y: 0, width: 540, height: 760))
                view.string = note.text
                view.font = .systemFont(ofSize: 13)
                view.textContainerInset = NSSize(width: 24, height: 24)
                view.sizeToFit()
                view.frame.size.height = max(760, view.frame.height)
                try view.dataWithPDF(inside: view.bounds).write(to: url)
            }
            Toast.show("Exported \(url.lastPathComponent)", symbol: "square.and.arrow.up")
        } catch {
            Toast.show("Couldn't export the note", symbol: "exclamationmark.triangle.fill", style: .error)
        }
    }

    #if APPSTORE
    private var sharePicker: NSSharingServicePicker?

    /// The App Store edition has no AppleScript to Notes: the system share sheet lists Notes (and Mail, Messages, AirDrop…).
    func share(_ note: ScoutNote) {
        guard !ScoutRuntime.isScripted else { return }
        let window = NSApp.keyWindow ?? NSApp.orderedWindows.first { $0.isVisible && $0.contentView != nil }
        guard let window, let view = window.contentView else {
            Toast.show("Open a Scout window first, then share", symbol: "square.and.arrow.up", style: .info)
            return
        }
        let picker = NSSharingServicePicker(items: [note.text])
        sharePicker = picker
        let point = window.mouseLocationOutsideOfEventStream
        picker.show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1), of: view, preferredEdge: .minY)
    }
    #else
    /// AppleScript to the Notes app, only when the user clicks. The first use shows macOS's automation prompt.
    func sendToAppleNotes(_ note: ScoutNote) {
        guard !ScoutRuntime.isScripted else { return }
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let body = note.text.split(separator: "\n", omittingEmptySubsequences: false).map { esc(String($0)) }.joined(separator: "<br>")
        let source = "tell application \"Notes\" to make new note with properties {name:\"\(esc(note.title))\", body:\"\(body)\"}"
        if AppleScript.run(source) != nil {
            Toast.show("Sent to Apple Notes", symbol: "note.text")
        } else {
            Toast.show("Couldn't reach Notes — allow Scout under Automation", symbol: "exclamationmark.triangle.fill", style: .warning, duration: 3)
        }
    }
    #endif

    private static func sampleNotes() -> [ScoutNote] {
        let now = Date()
        func make(_ text: String, ago: TimeInterval) -> ScoutNote {
            var n = ScoutNote(text: text)
            n.created = now.addingTimeInterval(-ago)
            n.modified = now.addingTimeInterval(-ago)
            return n
        }
        return [
            make("Trip packing\n- passport\n- charger and adapter\n- the small camera\n- umbrella", ago: 600),
            make("Ideas for the weekend\nBake bread. Fix the bike light. Call Marta back about Sunday.", ago: 8_000),
            make("Call script\nHi, this is about the invoice from March. Could you confirm the amount and the due date?", ago: 90_000),
            make("Wi-Fi at the studio\nNetwork: Loft-5G\nPassword is on the fridge.", ago: 300_000),
        ]
    }
}

// MARK: - To-dos

struct TodoTask: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var done = false
    var created = Date()
    var completed: Date?
    /// Optional day the task is planned for (start of day).
    var day: Date?
    /// Minutes of focus logged against this task.
    var focusMinutes = 0
}

@MainActor
final class TodoStore: ObservableObject {
    static let shared = TodoStore()

    @Published private(set) var tasks: [TodoTask] = []

    private let file = JSONFile<[TodoTask]>("todos.json")
    private var isPreview = false
    private var persists: Bool { !ScoutRuntime.isScripted && !isPreview }

    init() {
        tasks = ScoutRuntime.isScripted ? Self.sampleTasks() : (file.load() ?? [])
        purgeOldCompleted()
    }

    /// Pictures and self-tests: a store of its own with these tasks, which never reads or writes the to-do file.
    init(preview tasks: [TodoTask]) {
        isPreview = true
        self.tasks = tasks
    }

    /// Setting `todo.autoClearDays`: finished tasks older than that many days are removed (0 = never).
    func purgeOldCompleted() {
        let days = UserDefaults.standard.int("todo.autoClearDays", default: 0)
        guard days > 0, persists else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let before = tasks.count
        tasks.removeAll { $0.done && ($0.completed ?? Date()) < cutoff }
        if tasks.count != before { save() }
    }

    var openTasks: [TodoTask] { tasks.filter { !$0.done } }
    var doneTasks: [TodoTask] { tasks.filter(\.done) }
    var openCount: Int { openTasks.count }

    @discardableResult
    func add(_ title: String, day: Date? = nil) -> TodoTask? {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let task = TodoTask(title: clean, day: day.map { Calendar.current.startOfDay(for: $0) })
        tasks.insert(task, at: 0)
        save()
        return task
    }

    func toggle(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].done.toggle()
        tasks[i].completed = tasks[i].done ? Date() : nil
        save()
    }

    func rename(_ id: UUID, to title: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        tasks[i].title = clean
        save()
    }

    func setDay(_ id: UUID, _ day: Date?) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].day = day.map { Calendar.current.startOfDay(for: $0) }
        save()
    }

    func addFocus(_ id: UUID, minutes: Int) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].focusMinutes += minutes
        save()
    }

    func delete(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        save()
    }

    func clearCompleted() {
        tasks.removeAll(where: \.done)
        save()
    }

    func tasks(on day: Date) -> [TodoTask] {
        tasks.filter { $0.day.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false }
    }

    private func save() {
        guard persists else { return }
        file.save(tasks)
    }

    private static func sampleTasks() -> [TodoTask] {
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        func make(_ title: String, done: Bool = false, day: Date? = nil, focus: Int = 0) -> TodoTask {
            var t = TodoTask(title: title, done: done, day: day, focusMinutes: focus)
            if done { t.completed = now }
            return t
        }
        return [
            make("Reply to Marta about Sunday", day: today),
            make("Review the agent settings page", day: today, focus: 25),
            make("Book the dentist"),
            make("Water the plants", day: Calendar.current.date(byAdding: .day, value: 2, to: today)),
            make("Pay the electricity bill", done: true),
            make("Send the invoice", done: true),
        ]
    }
}

// MARK: - Links

struct SavedLink: Identifiable, Codable, Equatable {
    var id = UUID()
    var url: String
    var title: String?
    var date = Date()

    var host: String { URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url }
    var displayTitle: String { (title?.isEmpty == false ? title : nil) ?? host }
}

@MainActor
final class LinksStore: ObservableObject {
    static let shared = LinksStore()

    @Published private(set) var links: [SavedLink] = []

    private let file = JSONFile<[SavedLink]>("links.json")
    private var persists: Bool { !ScoutRuntime.isScripted }

    init() {
        links = ScoutRuntime.isScripted ? Self.sampleLinks() : (file.load() ?? [])
    }

    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: \.isWhitespace) else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let host = url.host, host.contains(".") else { return nil }
        return url
    }

    /// Saves a link and fetches its title in the background (never in scripted runs).
    @discardableResult
    func add(_ raw: String) -> Bool {
        guard let url = Self.normalize(raw) else { return false }
        if let i = links.firstIndex(where: { $0.url == url.absoluteString }) {
            let moved = links.remove(at: i)
            links.insert(moved, at: 0)
            save()
            return true
        }
        let link = SavedLink(url: url.absoluteString)
        links.insert(link, at: 0)
        save()
        if !ScoutRuntime.isScripted { fetchTitle(for: link.id, url: url) }
        return true
    }

    func delete(_ id: UUID) {
        links.removeAll { $0.id == id }
        save()
    }

    func search(_ query: String) -> [SavedLink] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return links }
        return links.filter { $0.url.lowercased().contains(q) || ($0.title ?? "").lowercased().contains(q) }
    }

    func open(_ link: SavedLink) {
        guard !ScoutRuntime.isScripted, let url = URL(string: link.url) else { return }
        NSWorkspace.shared.open(url)
    }

    private func fetchTitle(for id: UUID, url: URL) {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Mozilla/5.0 (Macintosh) Scout", forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data, let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                  let range = html.range(of: "<title[^>]*>(.*?)</title>", options: [.regularExpression, .caseInsensitive]) else { return }
            var title = String(html[range])
            title = title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            title = title.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&quot;", with: "\"").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            let clipped = String(title.prefix(140))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let i = LinksStore.shared.links.firstIndex(where: { $0.id == id }) else { return }
                    LinksStore.shared.links[i].title = clipped
                    LinksStore.shared.save()
                }
            }
        }.resume()
    }

    private func save() {
        guard persists else { return }
        file.save(links)
    }

    private static func sampleLinks() -> [SavedLink] {
        let now = Date()
        func make(_ url: String, _ title: String, ago: TimeInterval) -> SavedLink {
            var l = SavedLink(url: url, title: title)
            l.date = now.addingTimeInterval(-ago)
            return l
        }
        return [
            make("https://developer.apple.com/design/human-interface-guidelines", "Human Interface Guidelines", ago: 300),
            make("https://www.swift.org/blog/", "Swift.org — Blog", ago: 7_000),
            make("https://www.example.com/recipes/sourdough", "A patient sourdough, step by step", ago: 50_000),
            make("https://news.example.org/transit-map", "How the new transit map was drawn", ago: 200_000),
        ]
    }
}

// MARK: - Pinned apps

struct PinnedApp: Identifiable, Codable, Equatable {
    var path: String
    var id: String { path }
    var name: String { FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "") }
    var url: URL { URL(fileURLWithPath: path) }
}

@MainActor
final class PinnedAppsStore: ObservableObject {
    static let shared = PinnedAppsStore()
    static let maxApps = 8

    @Published private(set) var apps: [PinnedApp] = []

    private let file = JSONFile<[PinnedApp]>("pinned-apps.json")
    private var persists: Bool { !ScoutRuntime.isScripted }

    init() {
        if ScoutRuntime.isScripted {
            apps = Self.defaultApps()
        } else {
            apps = file.load() ?? Self.defaultApps()
        }
    }

    private static func defaultApps() -> [PinnedApp] {
        ["/Applications/Safari.app", "/System/Applications/Safari.app", "/System/Cryptexes/App/System/Applications/Safari.app",
         "/System/Applications/Notes.app", "/System/Applications/Calendar.app", "/System/Applications/Music.app",
         "/System/Applications/Messages.app", "/System/Applications/Mail.app"]
            .filter { FileManager.default.fileExists(atPath: $0) }
            .reduce(into: [PinnedApp]()) { list, path in
                if !list.contains(where: { $0.name == PinnedApp(path: path).name }) { list.append(PinnedApp(path: path)) }
            }
    }

    var isFull: Bool { apps.count >= Self.maxApps }

    func add(_ url: URL) {
        guard !isFull, url.pathExtension == "app", !apps.contains(where: { $0.path == url.path }) else { return }
        apps.append(PinnedApp(path: url.path))
        save()
    }

    func remove(_ app: PinnedApp) {
        apps.removeAll { $0.path == app.path }
        save()
    }

    func move(from: IndexSet, to: Int) {
        apps.move(fromOffsets: from, toOffset: to)
        save()
    }

    func open(_ app: PinnedApp) {
        guard !ScoutRuntime.isScripted else { return }
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Opens an "Add app" file chooser (Applications folder). Only on click.
    func chooseApp() {
        guard !ScoutRuntime.isScripted else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Pin")
        if panel.runModal() == .OK { panel.urls.forEach(add) }
    }

    private func save() {
        guard persists else { return }
        file.save(apps)
    }
}
