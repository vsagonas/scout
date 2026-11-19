import SwiftUI

@MainActor
enum AppGalleryItems {
    static func register() {
        Gallery.register("app-settings-window", size: CGSize(width: 900, height: 640), backdrop: .window) {
            let _ = { SettingsSelection.shared.pane = .general }()
            SettingsRootView()
        }
        Gallery.register("app-settings-window-notch", size: CGSize(width: 900, height: 640), backdrop: .window) {
            let _ = { SettingsSelection.shared.pane = .notch }()
            SettingsRootView()
        }
        Gallery.register("app-settings-window-tall", size: CGSize(width: 900, height: 1180), backdrop: .window) {
            let _ = { SettingsSelection.shared.pane = .hud }()
            SettingsRootView()
        }
        NotchGalleryItems.settingsPage("general", .general, height: 700)
        NotchGalleryItems.settingsPage("shortcuts", .shortcuts, height: 1040)
        NotchGalleryItems.settingsPage("permissions", .permissions, height: 1080)
        NotchGalleryItems.settingsPage("about", .about, height: 760)
        for page in 0..<OnboardingView.pageCount {
            Gallery.register("app-onboarding-\(page + 1)", size: OnboardingView.windowSize(for: Look.size, screen: nil), backdrop: .window) {
                OnboardingView(initialPage: page)
            }
        }
        // Where the tour window opens: the middle of the screen's visible frame, at the size pick (run it with SCOUT_SCALE=normal, large, xlarge).
        Gallery.register("app-tour-centred", size: TourCentredScene.screen, backdrop: .screenTop) { TourCentredScene() }
        Gallery.register("app-icon", size: CGSize(width: 520, height: 200), backdrop: .window) {
            HStack(spacing: 24) {
                ForEach([160.0, 96, 48, 24], id: \.self) { size in
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: size, height: size)
                }
            }
        }
    }
}

/// A 1440 x 900 screen with its menu bar strip, and the welcome tour where `OnboardingWindow` puts it (the same placement function, the
/// same room: the visible frame below the menu bar). The dashed lines run through the middle of that room.
private struct TourCentredScene: View {
    static let screen = CGSize(width: 1440, height: 900)
    private let menuBar: CGFloat = 37
    private let titleBar: CGFloat = 28

    var body: some View {
        let room = CGRect(x: 0, y: 0, width: Self.screen.width, height: Self.screen.height - menuBar)   // bottom-left origin, like AppKit
        let layout = OnboardingView.windowSize(for: Look.size, room: room.size)
        let frame = OnboardingWindow.placed(size: CGSize(width: layout.width, height: layout.height + titleBar), middle: CGPoint(x: room.midX, y: room.midY), in: room)
        let model = OnboardingModel(page: OnboardingView.sizePage)
        let _ = { model.room = room.size }()
        let top = Self.screen.height - frame.maxY   // from the top of the picture
        ZStack(alignment: .topLeading) {
            Path { p in
                p.move(to: CGPoint(x: room.midX, y: menuBar)); p.addLine(to: CGPoint(x: room.midX, y: Self.screen.height))
                p.move(to: CGPoint(x: 0, y: Self.screen.height - room.midY)); p.addLine(to: CGPoint(x: Self.screen.width, y: Self.screen.height - room.midY))
            }
            .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
            VStack(spacing: 0) {
                Color.clear.frame(height: titleBar)
                OnboardingView(model: model)
            }
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            .offset(x: frame.minX, y: top)
            Text("\(Look.size.title): window \(Int(frame.width)) x \(Int(frame.height)); room left \(Int(frame.minX)), right \(Int(Self.screen.width - frame.maxX)), below the menu bar \(Int(room.maxY - frame.maxY)), above the bottom \(Int(frame.minY))")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.white).padding(.leading, 12).padding(.top, 10)
        }
        .frame(width: Self.screen.width, height: Self.screen.height, alignment: .topLeading)
    }
}
