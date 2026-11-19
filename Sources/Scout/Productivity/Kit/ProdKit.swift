import AppKit
import SwiftUI

// Small helpers shared by the productivity part's stores, tools, widgets and settings pages.

enum ProdFormat {
    /// "3:05", "1:02:03".
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "3:05.42" for the stopwatch.
    static func stopwatch(_ seconds: TimeInterval) -> String {
        let t = max(0, seconds)
        let cs = Int((t * 100).rounded(.down)) % 100
        return clock(t) + String(format: ".%02d", cs)
    }

    /// "now", "5m", "3h", "2d", "4w": the shortest unit the person's language has for it (a locale-aware formatter), "now" under 45 seconds.
    static func age(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        switch s {
        case ..<45: return String(localized: "now")
        case ..<3600: return abbreviated(DateComponents(minute: max(1, Int(s / 60))))
        case ..<86_400: return abbreviated(DateComponents(hour: Int(s / 3600)))
        case ..<(86_400 * 14): return abbreviated(DateComponents(day: Int(s / 86_400)))
        default: return abbreviated(DateComponents(weekOfMonth: Int(s / (86_400 * 7))))
        }
    }

    private static func abbreviated(_ components: DateComponents) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        return formatter.string(from: components) ?? ""
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}


/// Reads and writes a JSON-encoded array in UserDefaults (for small lists like ignored apps).
enum StoredList {
    static func strings(_ key: String, default fallback: [String] = []) -> [String] {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return fallback }
        return list
    }

    static func set(_ list: [String], key: String) {
        guard let data = try? JSONEncoder().encode(list), let raw = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(raw, forKey: key)
    }

    static func decode(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8), let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    static func encode(_ list: [String]) -> String {
        guard let data = try? JSONEncoder().encode(list), let raw = String(data: data, encoding: .utf8) else { return "[]" }
        return raw
    }
}

extension UserDefaults {
    func bool(_ key: String, default fallback: Bool) -> Bool { object(forKey: key) as? Bool ?? fallback }
    func int(_ key: String, default fallback: Int) -> Int { object(forKey: key) as? Int ?? fallback }
    func double(_ key: String, default fallback: Double) -> Double { object(forKey: key) as? Double ?? fallback }
    func string(_ key: String, default fallback: String) -> String { string(forKey: key) ?? fallback }
}

/// Posts ⌘V into the frontmost app. Needs Accessibility. Returns false when it can't.
@MainActor
enum PasteBack {
    static func canPost() -> Bool { !ScoutRuntime.isScripted && Permissions.accessibilityGranted }

    /// Call after the picker panel has closed. A short delay lets the previous app become key again.
    static func commandV(after delay: TimeInterval = 0.12) {
        guard canPost() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cgAnnotatedSessionEventTap)
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}

/// Sounds by name (the macOS alert sounds). Silent in scripted runs.
enum ProdSound {
    static let names = ["Glass", "Ping", "Hero", "Submarine", "Funk", "Tink", "Pop", "Purr", "Blow", "Bottle", "Frog", "Morse", "Basso", "Sosumi"]

    static func play(_ name: String) {
        guard !ScoutRuntime.isScripted else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}

/// A search box with the Mac's look: the prompt is a literal that localizes itself (the Ring tools' `ToolSearchField` takes a plain String).
struct ProdSearchField: View {
    var prompt: LocalizedStringKey
    @Binding var text: String
    var focus: FocusState<Bool>.Binding?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            field
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
    }

    @ViewBuilder private var field: some View {
        if let focus {
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 13)).focused(focus)
        } else {
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 13))
        }
    }
}

/// A symbol and one short line for an empty list (the line is a literal that localizes itself).
struct ProdEmptyState: View {
    let symbol: String
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
            Text(message).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
