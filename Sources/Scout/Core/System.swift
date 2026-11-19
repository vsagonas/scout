import AppKit
import ApplicationServices
import Security

// MARK: - Keychain (API keys and other secrets; never UserDefaults)

enum Keychain {
    static let service = "com.vsag.Scout"

    enum KeychainError: Error { case unexpected(OSStatus) }

    static func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpected(status) }
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Permissions

/// Ask for a permission ONLY when the user turns on or opens the feature that needs it, never at launch,
/// and never in scripted runs (`ScoutRuntime.isScripted`).
enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt once (and adds Scout to the Accessibility list).
    static func requestAccessibility() {
        guard !ScoutRuntime.isScripted else { return }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case screenRecording = "Privacy_ScreenCapture"
        case microphone = "Privacy_Microphone"
        case camera = "Privacy_Camera"
        case calendars = "Privacy_Calendars"
        case reminders = "Privacy_Reminders"
        case contacts = "Privacy_Contacts"
        case fullDiskAccess = "Privacy_AllFiles"
        case automation = "Privacy_Automation"
        case location = "Privacy_LocationServices"
        case bluetooth = "Privacy_Bluetooth"
        case speech = "Privacy_SpeechRecognition"
        case inputMonitoring = "Privacy_ListenEvent"
    }

    static func openSettings(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Small helpers everyone needs

enum Shell {
    /// Runs a tool and returns stdout (nil on failure). Blocking: call off the main thread.
    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String], input: String? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        if let input {
            let inPipe = Pipe()
            process.standardInput = inPipe
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum AppleScript {
    /// Runs AppleScript source and returns the string result. Main thread (NSAppleScript is not thread-safe).
    @MainActor
    @discardableResult
    static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil { return nil }
        return result?.stringValue
    }
}
