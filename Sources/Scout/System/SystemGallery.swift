import SwiftUI

@MainActor
enum SystemGalleryItems {
    static func register() {
        let sampleService = VolumeService()
        #if APPSTORE
        let hudRows = 3
        #else
        let hudRows = 4
        #endif
        Gallery.register("system-hud", size: CGSize(width: 520, height: CGFloat(hudRows) * 78 + 8)) {
            VStack(spacing: 0) {
                strip("Volume 60 %", HUDActivity.make(kind: .volume, value: 0.6, muted: false, service: sampleService, expiresAfter: nil))
                strip("Volume 100 %", HUDActivity.make(kind: .volume, value: 1, muted: false, service: sampleService, expiresAfter: nil))
                strip("Muted", HUDActivity.make(kind: .volume, value: 0.4, muted: true, service: sampleService, expiresAfter: nil))
                #if !APPSTORE
                strip("Brightness 35 %", HUDActivity.make(kind: .brightness, value: 0.35, muted: false, service: sampleService, expiresAfter: nil))
                #endif
            }
        }
        let battery: [(String, BatteryState)] = [
            ("Plugged in", BatteryState(level: 64, isCharging: true, isPluggedIn: true, isCharged: false, minutesRemaining: 54)),
            ("On battery", BatteryState(level: 62, isCharging: false, isPluggedIn: false, isCharged: false, minutesRemaining: 410)),
            ("Low", BatteryState(level: 18, isCharging: false, isPluggedIn: false, isCharged: false, minutesRemaining: 32)),
            ("Fully charged", BatteryState(level: 100, isCharging: false, isPluggedIn: true, isCharged: true, minutesRemaining: nil)),
        ]
        Gallery.register("system-battery", size: CGSize(width: 520, height: CGFloat(battery.count) * 78 + 8)) {
            VStack(spacing: 0) {
                ForEach(battery, id: \.0) { item in strip(item.0, BatteryActivity.make(state: item.1, expiresAfter: nil)) }
            }
        }
        Gallery.register("system-bluetooth", size: CGSize(width: 520, height: 3 * 78 + 8)) {
            VStack(spacing: 0) {
                #if APPSTORE
                strip("AirPods Pro (no battery in this edition)", BluetoothActivity.make(info: .airPodsPro, expiresAfter: nil))
                strip("AirPods Max", BluetoothActivity.make(info: BluetoothInfo(name: "AirPods Max", kind: .airPodsMax), expiresAfter: nil))
                #else
                strip("AirPods Pro", BluetoothActivity.make(info: .airPodsPro, expiresAfter: nil))
                strip("AirPods Max", BluetoothActivity.make(info: BluetoothInfo(name: "AirPods Max", kind: .airPodsMax, single: 71), expiresAfter: nil))
                #endif
                strip("Keyboard, no battery report", BluetoothActivity.make(info: BluetoothInfo(name: "Magic Keyboard", kind: .keyboard), expiresAfter: nil))
            }
        }
        Gallery.register("system-bluetooth-detail", size: CGSize(width: 520, height: 160)) {
            NotchScene(size: CGSize(width: 520, height: 160), kinds: [.bluetooth], detail: true)
        }
        Gallery.register("system-volume-widget", size: CGSize(width: 340, height: 180)) {
            let _ = VolumeService.shared.start()
            VolumeWidgetView()
                .frame(width: CGFloat(WidgetKind.volume.defaultSpan) * NookMetrics.cell, height: NookMetrics.widgetHeight)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.1)))
                .padding(14)
                .background(Color.black.opacity(0.85))
                .environment(\.colorScheme, .dark)
        }
        NotchGalleryItems.settingsPage("hud", .hud, height: 760)
    }

    /// One closed-notch strip with a caption above it.
    private static func strip(_ label: String, _ activity: LiveActivity) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 8).frame(height: 14)
            ActivityStrip(activity: activity).frame(width: 520, height: 58).clipped()
            Color.clear.frame(height: 6)
        }
        .frame(width: 520, height: 78, alignment: .top)
    }
}

/// A closed notch showing exactly one given activity.
struct ActivityStrip: View {
    let size = CGSize(width: 520, height: 58)
    @ObservedObject var model = NotchScreenModel(geometry: .sample16, panelSize: CGSize(width: 520, height: 58))
    @ObservedObject var center = LiveActivityCenter()
    @ObservedObject var navigator = NotchNavigator()
    @ObservedObject var nook = NookStore(persist: false)

    init(activity: LiveActivity) {
        center.show(activity)
    }

    var body: some View {
        ZStack(alignment: .top) {
            MockMenuBar()
            NotchRootView(model: model, center: center, navigator: navigator, nook: nook)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }
}
