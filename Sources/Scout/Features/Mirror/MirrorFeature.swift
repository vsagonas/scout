import SwiftUI

@MainActor
enum MirrorFeature {
    static func start() {}

    /// The Mirror's headless self-test: `scout://mirror.selftest?out=<file>`. Called from `HeadlessChecks.registerAll()`.
    static func registerHeadless() {
        MirrorSelfTest.register()
    }

    /// Quick checks (SCOUT_SELFTEST=1): the polaroid is built from a drawn picture and made-up agents, never from a camera.
    static func registerSelfTests() {
        MirrorPolaroidChecks.register()
    }

    static func registerGallery() {
        // The dashboard panel.
        FeatureGallery.widget("mirror-widget-stopped", span: 3) { MirrorWidgetView(previewState: .stopped) }
        FeatureGallery.widget("mirror-widget-running", span: 3) { MirrorWidgetView(previewState: .running) }
        FeatureGallery.widget("mirror-widget-denied", span: 3) { MirrorWidgetView(previewState: .denied) }
        FeatureGallery.widget("mirror-widget-nocamera", span: 3) { MirrorWidgetView(previewState: .noCamera) }
        FeatureGallery.widget("mirror-widget-starting", span: 3) { MirrorWidgetView(previewState: .starting) }
        FeatureGallery.widget("mirror-widget-circle", span: 3) { MirrorWidgetView(previewState: .running, previewShape: .circle) }
        FeatureGallery.widget("mirror-widget-square", span: 3) { MirrorWidgetView(previewState: .running, previewShape: .square) }
        FeatureGallery.widget("mirror-widget-circle-denied", span: 3) { MirrorWidgetView(previewState: .denied, previewShape: .circle) }
        FeatureGallery.row("mirror-widget-row", [(span: 3, view: AnyView(MirrorWidgetView(previewState: .running))), (span: 3, view: AnyView(MirrorWidgetView(previewState: .stopped))),
                                                 (span: 3, view: AnyView(MirrorWidgetView(previewState: .denied)))])

        // The Mirror tab at the size the open island gives it (about 990 x 320 under the header).
        let size = CGSize(width: 990, height: 320)
        func view(_ name: String, _ preview: MirrorPreview) {
            FeatureGallery.workspace(name, width: size.width, height: size.height) {
                MirrorScene(model: .shared, tools: MirrorTools(), preview: preview)
            }
        }
        view("mirror-view-1x", MirrorPreview())
        view("mirror-view-whole", MirrorPreview(fill: false))   // Settings: the whole picture with dark sides
        view("mirror-view-zoom2", MirrorPreview(zoom: .zoomed(2, around: CGPoint(x: 0.43, y: 0.40))))
        view("mirror-view-zoom3", MirrorPreview(zoom: .zoomed(3, around: CGPoint(x: 0.43, y: 0.40))))
        view("mirror-view-noflip", MirrorPreview(flip: false))
        view("mirror-view-nobattery", MirrorPreview(battery: nil))   // a Mac without a battery: no glyph
        view("mirror-view-low-battery", MirrorPreview(battery: BatteryState(level: 12, isCharging: false, isPluggedIn: false, isCharged: false, minutesRemaining: 20)))
        view("mirror-view-noaccess", MirrorPreview(state: .stopped))
        view("mirror-view-denied", MirrorPreview(state: .denied))
        view("mirror-view-nocamera", MirrorPreview(state: .noCamera))
        view("mirror-view-starting", MirrorPreview(state: .starting))

        // The tab in the open island (header with the Mirror tab last, the island at the Mirror's own height).
        Gallery.register("mirror-notch-open", size: CGSize(width: 1120, height: 420)) {
            NotchScene(size: CGSize(width: 1120, height: 420), open: true, workspace: .mirror, openHeight: 380)
        }
        // The polaroid the Share key makes (the drawn stand-in picture, made-up agents).
        let sheet = CGSize(width: MirrorPolaroid.width + 60, height: MirrorPolaroid.height + 60)
        // The preview window with its four keys (the owner, 2026-11-18: in Greek the keys were cut by the window's edges): drawn as wide as the
        // window would be, which grows with the keys' names.
        Gallery.register("mirror-share-preview", size: CGSize(width: 620, height: 620), backdrop: .window) {
            if let picture = MirrorPolaroid.samplePhoto(), let polaroid = MirrorPolaroid.image(photo: picture, agents: MirrorPolaroid.sampleAgents(2)) {
                MirrorSharePreviewView(image: polaroid) {}.border(Color.red.opacity(0.6))
            }
        }
        Gallery.register("mirror-polaroid", size: sheet) { MirrorPolaroidSheet(agents: MirrorPolaroid.sampleAgents(3)) }
        Gallery.register("mirror-polaroid-six", size: sheet) { MirrorPolaroidSheet(agents: MirrorPolaroid.sampleAgents(6)) }
        Gallery.register("mirror-polaroid-one", size: sheet) { MirrorPolaroidSheet(agents: MirrorPolaroid.sampleAgents(1)) }
        Gallery.register("mirror-polaroid-none", size: sheet) { MirrorPolaroidSheet(agents: []) }
        // The Settings page's Mirror section.
        FeatureGallery.settings("mirror-settings", height: 520) { FeaturePane { MirrorSettingsSection() } }
    }
}
