import SwiftUI

// This module starts everything in Features/.

@MainActor
enum FeaturesModule {
    /// Start calendar, weather, downloads, messages, agents… (each only if its setting is on), register commands.
    static func start() {
        DebugCommands.register("sandbox.report") { _ in SandboxReport.show() }
        CalendarFeature.start()
        WeatherFeature.start()
        PulseFeature.start()
        MirrorFeature.start()
        ShortcutsFeature.start()
        TrayFeature.start()
        DownloadsFeature.start()
        TerminalFeature.start()
        PrompterFeature.start()
        PocketsFeature.start()
        VideoFeature.start()
        MessagesFeature.start()
        AgentsFeature.start()
        RadioFeature.start()
    }

    static func registerGallery() {
        WeatherFeature.registerSelfTests()
        PulseFeature.registerSelfTests()
        TrayFeature.registerSelfTests()
        DownloadsFeature.registerSelfTests()
        TerminalFeature.registerSelfTests()
        PrompterFeature.registerSelfTests()
        PocketsFeature.registerSelfTests()
        VideoFeature.registerSelfTests()
        MessagesFeature.registerSelfTests()
        AgentsFeature.registerSelfTests()
        RadioFeature.registerSelfTests()
        MirrorFeature.registerSelfTests()
        FeaturesSelfTest.runIfRequested()
        CalendarFeature.registerGallery()
        WeatherFeature.registerGallery()
        PulseFeature.registerGallery()
        MirrorFeature.registerGallery()
        ShortcutsFeature.registerGallery()
        TrayFeature.registerGallery()
        DownloadsFeature.registerGallery()
        TerminalFeature.registerGallery()
        PrompterFeature.registerGallery()
        PocketsFeature.registerGallery()
        VideoFeature.registerGallery()
        MessagesFeature.registerGallery()
        AgentsFeature.registerGallery()
        RadioFeature.registerGallery()
    }
}

// Nook widgets
#if APPSTORE
struct AIUsageWidgetView: View { var body: some View { NotInEditionView(title: "AI Usage").notchContent() } }
#else
struct AIUsageWidgetView: View { var body: some View { PlaceholderView(title: "AI Usage", lane: .c) } }
#endif

// Workspaces

/// Shown in the open notch while files or a link are dragged over it: Tray / AirDrop / Convert.

// Settings pages
