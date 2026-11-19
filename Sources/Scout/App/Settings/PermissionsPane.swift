import AppKit
import AVFoundation
import Contacts
import CoreBluetooth
import CoreGraphics
import CoreLocation
import EventKit
import Speech
import SwiftUI

enum PermissionStatus {
    case allowed, denied, notAsked, unknown

    var text: String {
        switch self {
        case .allowed: String(localized: "Allowed")
        case .denied: String(localized: "Turned off")
        case .notAsked: String(localized: "Not asked yet")
        case .unknown: String(localized: "Check in Settings")
        }
    }

    var tone: StatusPill.Tone {
        switch self {
        case .allowed: .good
        case .denied: .warn
        case .notAsked, .unknown: .neutral
        }
    }
}

struct PermissionInfo: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let why: String
    let pane: Permissions.Pane
    let status: @MainActor () -> PermissionStatus

    /// Accessibility is used for pasting from the clipboard history and for the Windows tool; the full edition also swaps the volume pop-up.
    private static var accessibilityWhy: String {
        #if APPSTORE
        String(localized: "Paste for you from the clipboard history. Asked the first time you use it.")
        #else
        String(localized: "Paste for you, and swap the volume pop-up for Scout's own.")
        #endif
    }

    private static var bluetoothWhy: String {
        #if APPSTORE
        String(localized: "Show your AirPods and other Bluetooth devices when they connect.")
        #else
        String(localized: "Show your AirPods and their battery when they connect.")
        #endif
    }

    private static var screenWhy: String {
        #if APPSTORE
        String(localized: "Screenshots and screen recordings.")
        #else
        String(localized: "Screen recordings and the music visualizer.")
        #endif
    }

    @MainActor static let all: [PermissionInfo] = shared + fullEditionOnly

    /// Contacts (message cards), Full Disk Access (Messages) and Input Monitoring (mouse trigger) are not in the App Store edition.
    @MainActor private static var fullEditionOnly: [PermissionInfo] {
        #if APPSTORE
        []
        #else
        [
            PermissionInfo(id: "contacts", title: String(localized: "Contacts"), symbol: "person.crop.circle",
                           why: String(localized: "Names and photos on message cards."), pane: .contacts) {
                switch CNContactStore.authorizationStatus(for: .contacts) {
                case .authorized: .allowed
                case .denied, .restricted: .denied
                default: .notAsked
                }
            },
            PermissionInfo(id: "disk", title: String(localized: "Full Disk Access"), symbol: "internaldrive",
                           why: String(localized: "Read incoming messages. macOS does not tell apps whether it is on."), pane: .fullDiskAccess) { .unknown },
        ]
        #endif
    }

    @MainActor private static let shared: [PermissionInfo] = [
        PermissionInfo(id: "accessibility", title: String(localized: "Accessibility"), symbol: "accessibility",
                       why: accessibilityWhy, pane: .accessibility) {
            Permissions.accessibilityGranted ? .allowed : .notAsked
        },
        PermissionInfo(id: "automation", title: String(localized: "Spotify and Music"), symbol: "music.note",
                       why: String(localized: "Show covers and press play. Asked when you turn a player on in Settings → Media."), pane: .automation) {
            let service = NowPlayingService.shared
            let ids = [NowPlayingService.spotifyID, NowPlayingService.musicID]
            if ids.contains(where: { service.access(for: $0) == .denied }) { return .denied }
            if ids.contains(where: { service.access(for: $0) == .allowed }) { return .allowed }
            return .notAsked
        },
        PermissionInfo(id: "bluetooth", title: String(localized: "Bluetooth"), symbol: "airpodspro",
                       why: bluetoothWhy, pane: .bluetooth) {
            switch CBManager.authorization {
            case .allowedAlways: .allowed
            case .denied, .restricted: .denied
            default: .notAsked
            }
        },
        PermissionInfo(id: "calendars", title: String(localized: "Calendars"), symbol: "calendar",
                       why: String(localized: "Events in the notch, countdowns and the composer."), pane: .calendars) {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess, .authorized, .writeOnly: .allowed
            case .denied, .restricted: .denied
            default: .notAsked
            }
        },
        PermissionInfo(id: "camera", title: String(localized: "Camera"), symbol: "camera",
                       why: String(localized: "The Mirror widget. Video never leaves your Mac."), pane: .camera) {
            map(AVCaptureDevice.authorizationStatus(for: .video))
        },
        PermissionInfo(id: "microphone", title: String(localized: "Microphone"), symbol: "mic",
                       why: String(localized: "Only for the Prompter to follow your voice."), pane: .microphone) {
            map(AVCaptureDevice.authorizationStatus(for: .audio))
        },
        PermissionInfo(id: "speech", title: String(localized: "Speech Recognition"), symbol: "waveform",
                       why: String(localized: "Lets the Prompter follow your voice, on this Mac."), pane: .speech) {
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: .allowed
            case .denied, .restricted: .denied
            default: .notAsked
            }
        },
        PermissionInfo(id: "screen", title: String(localized: "Screen Recording"), symbol: "record.circle",
                       why: screenWhy, pane: .screenRecording) {
            CGPreflightScreenCaptureAccess() ? .allowed : .notAsked
        },
        PermissionInfo(id: "location", title: String(localized: "Location"), symbol: "location",
                       why: String(localized: "Local weather. A chosen city works without it."), pane: .location) {
            switch CLLocationManager().authorizationStatus {
            case .authorizedAlways, .authorized: .allowed
            case .denied, .restricted: .denied
            default: .notAsked
            }
        },
    ]

    private static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: .allowed
        case .denied, .restricted: .denied
        default: .notAsked
        }
    }
}

struct PermissionsSettingsPane: View {
    @State private var tick = 0
    @ObservedObject private var service = NowPlayingService.shared

    var body: some View {
        Form {
            Section {
                ForEach(PermissionInfo.all) { info in
                    let status = info.status()
                    HStack(spacing: 12) {
                        Image(systemName: info.symbol).font(.system(size: 14))
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.accent.opacity(0.16)))
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.title)
                            Text(info.why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        StatusPill(verbatim: status.text, tone: status.tone)
                        Button("Open Settings") { Permissions.openSettings(info.pane) }
                            .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                SettingsFootnote("Scout asks macOS only when you turn on or open the feature that needs it. Nothing is asked at launch.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .id(tick)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in tick += 1 }
    }
}
