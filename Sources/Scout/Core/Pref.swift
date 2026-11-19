import Foundation

/// Typed reads/writes of UserDefaults with a fallback (shared by the whole app; was duplicated in two parts of the app).
enum Pref {
    static func bool(_ key: String, _ fallback: Bool) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? fallback }
    static func int(_ key: String, _ fallback: Int) -> Int { UserDefaults.standard.object(forKey: key) as? Int ?? fallback }
    static func double(_ key: String, _ fallback: Double) -> Double { UserDefaults.standard.object(forKey: key) as? Double ?? fallback }
    static func string(_ key: String, _ fallback: String) -> String { UserDefaults.standard.string(forKey: key) ?? fallback }
    static func set(_ value: Any?, _ key: String) { UserDefaults.standard.set(value, forKey: key) }
}
