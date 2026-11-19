import SwiftUI

struct CalendarSettingsPane: View {
    @ObservedObject private var service = CalendarService.shared
    @AppStorage(CalendarService.Key.enabled) private var enabled = false
    @AppStorage(CalendarService.Key.allDay) private var showAllDay = true
    @AppStorage(CalendarService.Key.multiDay) private var showMultiDay = true
    @AppStorage(CalendarService.Key.onlyVideo) private var onlyVideo = false
    @AppStorage(CalendarService.Key.minutesBefore) private var minutesBefore = 10
    @AppStorage(CalendarService.Key.joinCard) private var joinCard = true
    @AppStorage(CalendarService.Key.elapsed) private var elapsed = false

    var body: some View {
        FeaturePane {
            Section {
                Toggle("Show my calendar in the notch", isOn: Binding(
                    get: { enabled },
                    set: { on in if on { service.requestAccess() } else { service.turnOff() } }))
                StatusRow(title: Text("Access"), status: Text(verbatim: statusText), level: statusLevel)
                if service.access == .denied {
                    Button("Open System Settings…") { Permissions.openSettings(.calendars) }
                }
            } footer: {
                SettingsNote("Scout reads your events on this Mac to fill the Calendar widget and workspace. Nothing is sent anywhere.")
            }

            if service.access == .granted || service.access == .sample {
                Section("Calendars to show") {
                    ForEach(service.calendars) { c in
                        Toggle(isOn: Binding(
                            get: { !service.hiddenCalendars.contains(c.id) },
                            set: { on in
                                var set = service.hiddenCalendars
                                if on { set.remove(c.id) } else { set.insert(c.id) }
                                service.hiddenCalendars = set
                            })) {
                            HStack(spacing: 8) {
                                Circle().fill(c.color).frame(width: 9, height: 9)
                                Text(c.title)
                                if !c.sourceTitle.isEmpty { Text(c.sourceTitle).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }

            Section("Events") {
                Toggle("All-day events", isOn: $showAllDay)
                Toggle("Events that span several days", isOn: $showMultiDay)
                Toggle("Only events with a video link", isOn: $onlyVideo)
            }
            .onAppear { service.start(); service.refresh() }
            .onChange(of: showAllDay) { service.refresh() }
            .onChange(of: showMultiDay) { service.refresh() }
            .onChange(of: onlyVideo) { service.refresh() }

            Section {
                Picker("Show a countdown", selection: $minutesBefore) {
                    Text("Never").tag(0)
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) minutes before").tag($0) }
                }
                Toggle("Show a Join card when the meeting starts", isOn: $joinCard)
                Toggle("Show elapsed time during the event", isOn: $elapsed)
            } header: {
                Text("Next meeting")
            } footer: {
                SettingsNote("The countdown appears next to the notch and shows the title when you rest the pointer on it. Zoom, Google Meet, Teams and Webex links get a Join button.")
            }
        }
    }

    private var statusText: String {
        switch service.access {
        case .off: String(localized: "Off")
        case .needsAccess: String(localized: "Waiting for your OK")
        case .denied: String(localized: "Blocked in System Settings")
        case .granted: String(localized: "Allowed")
        case .sample: "Sample events (scripted run)"
        }
    }

    private var statusLevel: StatusRow.Level {
        switch service.access {
        case .granted, .sample: .good
        case .needsAccess: .warn
        case .denied: .bad
        case .off: .neutral
        }
    }
}
