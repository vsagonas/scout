import SwiftUI

// This module starts everything in Notch/, Media/, System/ and App/.

@MainActor
enum NotchModule {
    /// Create the notch windows, start NowPlaying / Volume / Battery / Bluetooth / HUD, register commands.
    static func start() {
        NotchPrefs.applyDefaultTabOrderOnce()
        registerCommands()
        NowPlayingService.shared.start()
        MediaActivityController.shared.start()
        VolumeService.shared.start()
        HUDController.shared.start()
        #if !APPSTORE
        MediaKeyTap.shared.start()
        #endif
        BatteryService.shared.start()
        BluetoothService.shared.start()
        NotchManager.shared.start()
    }

    static func registerGallery() {
        NotchGalleryItems.register()
        MediaGalleryItems.register()
        AppGalleryItems.register()
        SystemGalleryItems.register()
        LivePanelsGallery.register()
        LookGallery.register()   // look-*: the size and colours settings
    }

    private static func registerCommands() {
        DebugCommands.register("notch.open") { params in
            NotchNavigator.shared.open(params["ws"].flatMap(WorkspaceKind.init(rawValue:)))
        }
        DebugCommands.register("onboarding") { params in
            OnboardingWindow.shared.show(page: Int(params["page"] ?? "") ?? 0)
        }
        DebugCommands.register("notch.debug") { params in
            let m = NotchManager.shared
            var lines = ["controllers: \(m.controllers.count)", "open: \(NotchNavigator.shared.isOpen)", "screens: \(NSScreen.screens.count)"]
            for c in m.controllers {
                lines.append("display \(c.displayID) panel \(NSStringFromRect(c.panel.frame)) visible \(c.panel.isVisible) ignores \(c.panel.ignoresMouseEvents) level \(c.panel.level.rawValue) model.open \(c.model.isOpen) island \(NSStringFromRect(c.model.islandRect)) geo \(c.model.geometry)")
            }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("notch-debug.txt")
            try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        }
        DebugCommands.register("notch.close") { _ in NotchNavigator.shared.forceClose() }
        DebugCommands.register("panel.selftest.drag") { params in
            guard ScoutRuntime.isAutomation else { return }
            PanelDragSelfTest.run(out: params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("panel-drag-selftest.txt"))
        }
        DebugCommands.register("notch.selftest.resize") { params in
            guard ScoutRuntime.isAutomation else { return }
            NotchResizeSelfTest.run(out: params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("notch-resize-selftest.txt"))
        }
        DebugCommands.register("notch.edit") { _ in NookStore.shared.beginEditing() }
        DebugCommands.register("settings") { params in
            SettingsWindowController.shared.show(params["pane"].flatMap(SettingsPane.init(rawValue:)))
        }
        DebugCommands.register("settings.selftest") { params in
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("settings-selftest.txt")
            SettingsSelfTest.run(out: out, row: Int(params["row"] ?? "") ?? 3, bringToFront: params["front"] != "0",
                                 forceActivate: params["activate"] == "1", regular: params["regular"] == "1")
        }
        DebugCommands.register("activity.demo") { params in
            let seconds = Double(params["seconds"] ?? "") ?? 12
            if let kind = params["kind"].flatMap(LiveActivityKind.init(rawValue:)), kind.isAvailable {
                LiveActivityCenter.shared.show(SampleActivities.make(kind, expiresAfter: seconds))
            } else {
                LiveActivityKind.allCases.filter(\.isAvailable).forEach { LiveActivityCenter.shared.show(SampleActivities.make($0, expiresAfter: seconds)) }
            }
        }
        DebugCommands.register("activity.clear") { _ in
            LiveActivityKind.allCases.forEach { LiveActivityCenter.shared.dismissAll(kind: $0) }
        }
        DebugCommands.register("card.demo") { _ in
            LiveActivityCenter.shared.present(NotchCard(id: "demo.card", kind: .download, duration: 8) {
                DemoCardContent(symbol: "arrow.down.circle.fill", title: "Download finished", subtitle: "Scout-0.1.0.zip · 75 MB")
            })
            Toast.show("Copied to the clipboard", symbol: "doc.on.clipboard.fill")
        }
    }
}

struct DemoCardContent: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 320)
    }
}

struct LockScreenSettingsPane: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.rectangle.on.rectangle").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Lock-screen widgets aren't here yet").font(.system(size: 14, weight: .semibold))
            Text("Showing what's playing and a running timer over the lock screen needs private system spaces, so Scout leaves it out until it can be done safely.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
