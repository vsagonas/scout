#if !APPSTORE
import SwiftUI

struct MessagesSettingsPane: View {
    @ObservedObject private var service = MessagesService.shared
    @AppStorage(MessagesService.Key.enabled) private var enabled = false
    @AppStorage(MessagesService.Key.showText) private var showText = true
    @AppStorage(MessagesService.Key.cardSeconds) private var seconds = 8
    @AppStorage(MessagesService.Key.contacts) private var contacts = false
    @State private var contactsAnswer: Bool?

    var body: some View {
        FeaturePane {
            Section {
                Toggle("Show new messages under the notch", isOn: $enabled)
                    .onChange(of: enabled) { service.recheckAccess() }
                StatusRow(title: Text("Full Disk Access"), status: Text(verbatim: statusText), level: statusLevel)
                if service.access == .needsFullDiskAccess {
                    Button("Open System Settings…") { Permissions.openSettings(.fullDiskAccess) }
                    SettingsNote("Add Scout under Privacy & Security › Full Disk Access, switch it on, then quit and reopen Scout. macOS keeps Messages' database locked until you do. Scout only reads it, and only for new messages.")
                }
            } header: {
                Text("Messages")
            } footer: {
                SettingsNote("When a message arrives, a card drops below the notch with the sender, the text and a reply box. It stays quiet while the Messages app is in front. Scout never sends anything unless you type a reply and press Return.")
            }

            Section("Card") {
                Toggle("Show the message text", isOn: $showText)
                Picker("Keep the card for", selection: $seconds) {
                    ForEach([5, 8, 12, 20], id: \.self) { Text(verbatim: FeatureFormat.seconds($0)).tag($0) }
                }
                Button("Preview a card") { MessagesService.shared.demo() }
            }

            Section {
                Toggle("Use Contacts for names and photos", isOn: Binding(
                    get: { contacts },
                    set: { on in
                        if on, !ScoutRuntime.isScripted { ContactLookup.shared.requestAccess { contacts = $0; contactsAnswer = $0 } } else { contacts = on }
                    }))
                if contactsAnswer == false {
                    Text("Contacts access wasn't allowed. Change it in System Settings › Privacy & Security › Contacts.").font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                SettingsNote("Without Contacts a card shows the phone number or email. Contacts are only read on this Mac.")
            }
        }
        .onAppear { service.recheckAccess() }
    }

    private var statusText: String {
        switch service.access {
        case .off: String(localized: "Off")
        case .needsFullDiskAccess: String(localized: "Needed: not allowed yet")
        case .ready: String(localized: "Allowed")
        case .sample: "Sample messages (scripted run)"
        }
    }

    private var statusLevel: StatusRow.Level {
        switch service.access {
        case .ready, .sample: .good
        case .needsFullDiskAccess: .bad
        case .off: .neutral
        }
    }
}
#endif
