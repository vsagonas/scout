import Foundation

/// What a person had in a tool's panel (a draft, a tab, a search) survives closing the panel, quitting, an update and a restart.
/// Small `Pref` keys, written a moment after the last change (and at quit), read when the panel opens.
@MainActor
enum ToolMemory {
    /// NSNull means "forget this key".
    private static var pending: [String: Any] = [:]
    private static let writer = Debouncer(delay: 0.5)

    static func string(_ key: String) -> String? { UserDefaults.standard.string(forKey: key) }

    /// Remembers `value` (nil or empty forgets it).
    static func set(_ value: String?, _ key: String) {
        pending[key] = (value?.isEmpty ?? true) ? NSNull() : value as Any
        writer.call { flush() }
    }

    static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T?, _ key: String) {
        pending[key] = value.flatMap { try? JSONEncoder().encode($0) } ?? NSNull()
        writer.call { flush() }
    }

    /// Writes what is waiting now (the app calls this at quit).
    static func flush() {
        for (key, value) in pending {
            if value is NSNull { UserDefaults.standard.removeObject(forKey: key) } else { UserDefaults.standard.set(value, forKey: key) }
        }
        pending = [:]
    }

    // The keys, one per thing remembered.
    static let askDraft = "tool.askai.draft"
    static let clockTab = "tool.clock.tab"
    static let unitsState = "tool.units.state"
    static let calcExpression = "tool.calc.expression"
    static let linksSearch = "tool.links.search"
    static let reminderDraft = "tool.reminders.draft"
    static let clipboardState = "tool.clipboard.state"
}
