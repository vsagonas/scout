import AppKit
import SwiftUI

/// The Mirror tab: the front camera as a true mirror, with a small floating toolbar (zoom, Snap to the clipboard, Share; Flip is in Settings › Mirror).
/// The camera runs only while this view (or the dashboard's Mirror panel) is on screen; nothing is recorded or saved.
struct MirrorWorkspaceView: View {
    @StateObject private var tools = MirrorTools()

    var body: some View { MirrorScene(model: .shared, tools: tools) }
}

/// What a gallery picture shows instead of the live state: a state, a zoom, the light, a frozen frame.
struct MirrorPreview {
    var state: MirrorModel.State = .running
    var zoom = MirrorZoom()
    var lightOn = false
    var lightLevel = 0.7
    var frozen = false
    var flip = true
    /// The picture fills the whole view (the default) or shows whole with dark sides.
    var fill = true
    /// The battery the viewfinder shows (a Mac with a battery by default; nil draws a Mac without one).
    var battery: BatteryState? = .sample
    /// The date and time the stamp shows (fixed, so a picture is the same every time).
    var date = MirrorOSD.sampleDate
}

/// The Mirror's picture, states and toolbar. `preview` is for galleries only (never opens a camera).
struct MirrorScene: View {
    @ObservedObject var model: MirrorModel
    @ObservedObject var tools: MirrorTools
    var preview: MirrorPreview?
    /// The tab starts the camera by itself only when macOS has already allowed it.
    var autostart = true
    @ObservedObject private var nav = NotchNavigator.shared
    @ObservedObject private var batteryService = BatteryService.shared
    @AppStorage(MirrorModel.Key.flip) private var flipPref = true
    /// The picture fills the
    /// Mirror's whole shape (its edges are cropped); Settings › Mirror can show the whole picture with dark sides instead.
    @AppStorage(MirrorScene.fillKey) private var fillPref = true
    static let fillKey = "mirror.fill"

    init(model: MirrorModel, tools: MirrorTools, preview: MirrorPreview? = nil, autostart: Bool = true) {
        self.model = model
        self.tools = tools
        self.preview = preview
        self.autostart = autostart
    }

    private enum Face { case picture, prompt, starting, denied, noCamera }

    private var face: Face {
        if let p = preview {
            switch p.state {
            case .running: return .picture
            case .stopped: return .prompt
            case .starting: return .starting
            case .denied: return .denied
            case .noCamera: return .noCamera
            }
        }
        if model.scripted { return .picture }   // a drawn stand-in: scripted runs never open the camera
        switch model.state {
        case .running: return .picture
        case .stopped: return .prompt
        case .starting: return .starting
        case .denied: return .denied
        case .noCamera: return .noCamera
        }
    }

    private var flip: Bool { preview?.flip ?? flipPref }
    private var fills: Bool { preview?.fill ?? fillPref }
    private var zoom: MirrorZoom { preview?.zoom ?? tools.zoom }
    private var lightOn: Bool { preview?.lightOn ?? tools.lightOn }
    private var lightLevel: Double { preview?.lightLevel ?? tools.lightLevel }
    private var frozen: Bool { preview?.frozen ?? tools.isFrozen }
    private var standIn: Bool { preview != nil || model.scripted || model.session == nil }

    private var aspect: CGFloat {
        if let image = tools.frozen, preview == nil, image.height > 0 { return CGFloat(image.width) / CGFloat(image.height) }
        return model.aspect
    }

    private static let corner: CGFloat = 22
    private static let pictureCorner: CGFloat = 16
    /// The light's ring around the picture.
    private static let rim: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let area = geo.size
            let showsPicture = face == .picture
            let pictureSize = Self.pictureSize(aspect: aspect, in: CGSize(width: max(0, area.width - 2 * insetForLight), height: max(0, area.height - 2 * insetForLight)), fill: fills)
            ZStack {
                if showsPicture {
                    container
                    picture(size: pictureSize)
                } else {
                    stateView
                }
            }
            .overlay(alignment: .bottom) { if showsPicture { toolbar.padding(.bottom, 10 + insetForLight) } }
            .frame(width: area.width, height: area.height)
        }
        .coordinateSpace(name: "mirrorScene")
        .onPreferenceChange(MirrorRectsKey.self) { rects in tools.buttonRects = rects }
        .notchContent()
        .onAppear {
            guard preview == nil else { return }
            MirrorTools.active = tools
            model.viewAppeared(autostart: autostart)
        }
        .onDisappear {
            guard preview == nil else { return }
            if MirrorTools.active === tools { MirrorTools.active = nil }
            model.viewDisappeared()
            tools.unfreeze()
        }
        .onChange(of: nav.isOpen) { if !nav.isOpen, preview == nil { model.stop() } }
        .onChange(of: flipPref) { if preview == nil { tools.flipSwitched() } }
        .onChange(of: model.state) { if model.state != .running { tools.unfreeze() } }
    }

    private var insetForLight: CGFloat { lightOn ? Self.rim : 0 }

    /// The picture's frame in the view: the whole view when it fills (the camera's picture is cropped to that shape), else the
    /// biggest picture of the camera's own shape that fits.
    static func pictureSize(aspect: CGFloat, in size: CGSize, fill: Bool) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        return fill ? size : fit(aspect: aspect, in: size)
    }

    /// The biggest picture of this shape that fits in `size`: nothing is cropped, so the whole face is always there.
    static func fit(aspect: CGFloat, in size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, aspect > 0 else { return .zero }
        if size.width / size.height > aspect { return CGSize(width: size.height * aspect, height: size.height) }
        return CGSize(width: size.width, height: size.width / aspect)
    }

    // MARK: The view's frame and the ring light

    /// The camera fills the open notch edge to edge:
    /// no frame, no hairline, no bevel, square corners (the island's own outline rounds the bottom ones). Only the ring light
    /// draws its glowing rim around the picture.
    private var container: some View {
        let shape = RoundedRectangle(cornerRadius: lightOn ? Self.corner : 0, style: .continuous)
        return ZStack {
            shape.fill(lightOn ? Color.white.opacity(0.15 + 0.55 * lightLevel) : Color.black)
            // A soft glow along the edge, brightest at the very edge and fading inward, like a ring light.
            if lightOn { MirrorGlow(width: 48, strength: lightLevel).clipShape(shape) }
        }
        .animation(nil, value: lightOn)
    }

    /// The picture's corner: square edge to edge, rounded inside the ring light's rim.
    private var pictureRadius: CGFloat { lightOn ? Self.pictureCorner : 0 }

    // MARK: The picture

    private func picture(size: CGSize) -> some View {
        // Filling, the picture takes the view's own shape.
        let shape = RoundedRectangle(cornerRadius: pictureRadius, style: .continuous)
        return ZStack {
            zoomed(size: size)
            MirrorInputLayer(tools: tools, zoomed: zoom.isZoomed)
        }
        .frame(width: size.width, height: size.height)
        .overlay {
            // The light spills a little into the edge of the picture.
            if lightOn { MirrorGlow(width: 14, strength: 0.6 * lightLevel) }
        }
        .overlay {
            // The stamp's clock moves on while the tab is on screen (a check every 20 s at most); a still picture and a closed notch draw one frame.
            TimelineView(.animation(minimumInterval: 20, paused: preview != nil || !nav.isOpen)) { timeline in
                MirrorViewfinderOSD(osd: osd(at: preview?.date ?? timeline.date))
            }
        }
        .overlay { NotchFlyFlash(from: MirrorSnap.from) }   // Snap's flash
        .clipShape(shape)
        .overlay(shape.strokeBorder(frozen ? Retro.Ink.yellow.opacity(0.9) : Color.clear, lineWidth: 1.5).allowsHitTesting(false))
        .shadow(color: .black.opacity(lightOn ? 0.30 : 0), radius: 10)
        .help("Click to zoom in on a spot. Scroll or pinch to zoom, drag to move, double-click for the whole picture.")
        .reportRect(MirrorSnap.from)   // where Snap's picture lifts off on its way into the Clipboard key
    }

    /// The picture, `scale` times as big as the view and moved so only the zoomed part shows (never outside the picture).
    private func zoomed(size: CGSize) -> some View {
        let z = zoom
        return content
            .frame(width: size.width * z.scale, height: size.height * z.scale)
            .offset(x: z.origin.x * size.width, y: z.origin.y * size.height)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
    }

    @ViewBuilder private var content: some View {
        if preview == nil, let image = tools.frozen {
            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                .scaleEffect(x: flip ? -1 : 1, y: 1)
        } else if !standIn, let session = model.session {
            CameraPreview(session: session, flip: flip)
        } else {
            // The stand-in is a 16:9 "camera picture" too: filling, its edges are cropped like the real one's.
            MirrorStandIn().aspectRatio(16.0 / 9.0, contentMode: fills ? .fill : .fit).scaleEffect(x: flip ? -1 : 1, y: 1)
        }
    }

    /// What the viewfinder says over the picture (see `MirrorOSD`).
    private func osd(at date: Date) -> MirrorOSD {
        MirrorOSD.make(frozen: frozen, scale: zoom.scale, battery: preview.map(\.battery) ?? batteryService.state, date: date, standIn: standIn)
    }

    // MARK: No picture yet

    @ViewBuilder private var stateView: some View {
        switch face {
        case .prompt:
            MirrorNoSignal(title: pixelLabel("NO SIGNAL"), showsStatic: MirrorSignalRule.showsStatic(for: .stopped), cornerRadius: 0) {
                MirrorPlateContent(symbol: "person.crop.circle", message: "Turn on the camera to see yourself. Nothing is recorded.",
                                   actionTitle: "Turn on the camera") { model.start() }
            }
        case .starting:
            MirrorNoSignal(title: pixelLabel("STARTING"), showsStatic: MirrorSignalRule.showsStatic(for: .starting), cornerRadius: 0, plated: false) {
                ProgressView().controlSize(.small).padding(.vertical, 4)
            }
        case .denied:
            MirrorNoSignal(title: pixelLabel("NO SIGNAL"), showsStatic: MirrorSignalRule.showsStatic(for: .denied), cornerRadius: 0) {
                MirrorPlateContent(symbol: "video.slash", message: "Camera access is off for Scout.", actionTitle: "Open Settings") {
                    Permissions.openSettings(.camera)
                }
            }
        case .noCamera:
            MirrorNoSignal(title: pixelLabel("NO SIGNAL"), showsStatic: MirrorSignalRule.showsStatic(for: .noCamera), cornerRadius: 0) {
                MirrorPlateContent(symbol: "video.slash", message: "No camera found.", actionTitle: "Try again") {
                    model.refreshDevices()
                    model.start()
                }
            }
        case .picture:
            EmptyView()
        }
    }

    // MARK: The toolbar

    /// The toolbar is its own view (`MirrorToolbar`); another button joins it through `extras`.
    private var toolbar: some View {
        MirrorToolbar(model: model, tools: tools, zoom: zoom,
                      onSnap: { if preview == nil { MirrorSnap.start(model: model, tools: tools, flip: flip) } }) { toolbarExtras }
    }

    /// The Share key after Snap: a polaroid of the picture with the agents (`MirrorShare`). A gallery picture draws it and never acts.
    @ViewBuilder private var toolbarExtras: some View { MirrorShareKey(model: model, tools: tools, flip: flip, enabled: preview == nil) }
}

// MARK: - Mouse, wheel and pinch

/// Catches the clicks, drags, wheel and pinch over the picture and hands them to the tools (unit coordinates, top-left origin).
struct MirrorInputLayer: NSViewRepresentable {
    let tools: MirrorTools
    var zoomed: Bool

    func makeNSView(context: Context) -> MirrorInputNSView {
        let view = MirrorInputNSView()
        view.tools = tools
        view.zoomed = zoomed
        return view
    }

    func updateNSView(_ view: MirrorInputNSView, context: Context) {
        view.tools = tools
        view.zoomed = zoomed
    }
}

final class MirrorInputNSView: NSView {
    weak var tools: MirrorTools?
    var zoomed = false {
        didSet { if zoomed != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    private var downAt: CGPoint?
    private var last: CGPoint = .zero
    private var dragging = false

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: zoomed ? .openHand : .arrow)
    }

    private func place(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseDown(with event: NSEvent) {
        let p = place(event)
        downAt = p
        last = p
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt, bounds.width > 0, bounds.height > 0 else { return }
        let p = place(event)
        if !dragging, hypot(p.x - start.x, p.y - start.y) > 4 {
            dragging = true
            tools?.dragBegan()
            if zoomed { NSCursor.closedHand.set() }
        }
        if dragging { tools?.pan(by: CGPoint(x: (p.x - last.x) / bounds.width, y: (p.y - last.y) / bounds.height)) }
        last = p
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = dragging
        let started = downAt != nil
        downAt = nil
        dragging = false
        if wasDragging {
            tools?.dragEnded()
            if zoomed { NSCursor.openHand.set() }
            return
        }
        guard started else { return }
        let u = MirrorZoom.unit(place(event), in: bounds.size)
        switch event.clickCount {
        case 1: tools?.click(at: u)
        case 2: tools?.doubleClick()
        default: break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let u = MirrorZoom.unit(place(event), in: bounds.size)
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        tools?.scroll(dy: dy, precise: event.hasPreciseScrollingDeltas, at: u)
    }

    override func magnify(with event: NSEvent) {
        tools?.magnify(event.magnification, at: MirrorZoom.unit(place(event), in: bounds.size))
    }
}

/// A soft white glow along the INSIDE of the four edges: white at the edge, fading to nothing `width` points in. Plain gradients,
/// not a blur (a blur does not render in offscreen captures and costs more on a live screen). The corners are a little brighter,
/// as in a ring light. Clip it to the shape it belongs to.
struct MirrorGlow: View {
    var width: CGFloat
    var strength: Double

    private var fade: [Gradient.Stop] {
        [.init(color: Color.white.opacity(strength), location: 0), .init(color: Color.white.opacity(strength * 0.3), location: 0.4),
         .init(color: Color.white.opacity(0), location: 1)]
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(stops: fade, startPoint: .top, endPoint: .bottom).frame(height: width)
                Spacer(minLength: 0)
            }
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(stops: fade, startPoint: .bottom, endPoint: .top).frame(height: width)
            }
            HStack(spacing: 0) {
                LinearGradient(stops: fade, startPoint: .leading, endPoint: .trailing).frame(width: width)
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(stops: fade, startPoint: .trailing, endPoint: .leading).frame(width: width)
            }
        }
        .allowsHitTesting(false)
    }
}
