import AVFoundation
import SwiftUI

/// Nook widget: a mirror. Circle / rounded / square, flipped like a real mirror, camera picker, Start button. A click on it
/// (not on a button) expands it into the Mirror tab.
struct MirrorWidgetView: View {
    @ObservedObject private var model = MirrorModel.shared
    @ObservedObject private var nav = NotchNavigator.shared
    @AppStorage(MirrorModel.Key.shape) private var shapeRaw = MirrorShape.rounded.rawValue
    @AppStorage(MirrorModel.Key.flip) private var flip = true
    @AppStorage(MirrorModel.Key.camera) private var cameraID = ""
    @State private var hovering = false

    /// Gallery only.
    private var previewState: MirrorModel.State?
    private var previewShape: MirrorShape?
    init() {}
    init(previewState: MirrorModel.State, previewShape: MirrorShape? = nil) {
        self.previewState = previewState
        self.previewShape = previewShape
    }

    private var shape: MirrorShape { previewShape ?? MirrorShape(rawValue: shapeRaw) ?? .rounded }
    private var state: MirrorModel.State { previewState ?? model.state }

    var body: some View {
        ZStack {
            mirror
            controls
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .notchContent()
        .onHover { hovering = $0 }
        .onAppear { if previewState == nil { model.viewAppeared(autostart: Pref.bool(MirrorModel.Key.autostart, false)) } }
        .onDisappear { if previewState == nil { model.viewDisappeared() } }
        .onChange(of: nav.isOpen) { if !nav.isOpen { model.stop() } }
    }

    // MARK: The mirror itself

    @ViewBuilder private var mirror: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let size = shape == .circle ? CGSize(width: side, height: side) : geo.size
            ZStack {
                if state == .running {
                    if previewState != nil || model.session == nil { MirrorStandIn() } else if let session = model.session { CameraPreview(session: session, flip: flip) }
                    // The mini viewfinder: corner marks, LIVE and the time (the camera is on; nothing is recorded).
                    TimelineView(.animation(minimumInterval: 20, paused: previewState != nil || !nav.isOpen)) { timeline in
                        MirrorViewfinderOSD(osd: MirrorOSD.make(frozen: false, scale: 1, battery: nil, date: previewState != nil ? MirrorOSD.sampleDate : timeline.date,
                                                                 standIn: previewState != nil || model.session == nil),
                                            compact: true, circle: shape == .circle)
                    }
                } else {
                    stateScreen
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(clip)
            .overlay(clip.strokeBorder(Look.hairline, lineWidth: 1))
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    private var clip: AnyInsettableShape {
        switch shape {
        case .circle: AnyInsettableShape(Circle())
        case .rounded: AnyInsettableShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        case .square: AnyInsettableShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }

    /// Standing by, starting, no access, no camera: a CRT glass with its one key. "NO SIGNAL" static only where there is no access.
    @ViewBuilder private var stateScreen: some View {
        switch state {
        case .stopped:
            MirrorNoSignal(title: pixelLabel("NO SIGNAL"), showsStatic: MirrorSignalRule.showsStatic(for: .stopped), cornerRadius: shape == .square ? 6 : 20, compact: true, plated: false) {
                Button { model.start() } label: { Label("Start", systemImage: "video.fill") }
                    .buttonStyle(StartKeyStyle())
            }
        case .starting:
            MirrorNoSignal(title: pixelLabel("STARTING"), showsStatic: MirrorSignalRule.showsStatic(for: .starting), cornerRadius: shape == .square ? 6 : 20, compact: true, plated: false) {
                ProgressView().controlSize(.small)
            }
        case .denied:
            MirrorNoSignal(title: pixelLabel("NO SIGNAL"), showsStatic: MirrorSignalRule.showsStatic(for: .denied), cornerRadius: shape == .square ? 6 : 20, compact: true) {
                MirrorPlateContent(message: "Camera access is off", actionTitle: "Open Settings", action: { Permissions.openSettings(.camera) }, compact: true)
            }
        case .noCamera:
            MirrorNoSignal(title: pixelLabel("NO SIGNAL"), showsStatic: MirrorSignalRule.showsStatic(for: .noCamera), cornerRadius: shape == .square ? 6 : 20, compact: true) {
                MirrorPlateContent(message: "No camera found", actionTitle: "Try again", action: { model.refreshDevices(); model.start() }, compact: true)
            }
        case .running:
            EmptyView()
        }
    }

    // MARK: Keys over the mirror

    /// Flip, camera and stop while the picture runs, as small plastic keys. Hover only reveals them; a click is what acts.
    @ViewBuilder private var controls: some View {
        if state == .running {
            VStack {
                Spacer()
                HStack(spacing: 5) {
                    MirrorToolButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", on: flip, size: CGSize(width: 14, height: 12),
                                     help: flip ? "Mirrored" : "Not mirrored") { flip.toggle() }
                    if model.devices.count > 1 {
                        Menu {
                            ForEach(model.devices) { d in
                                Button { model.selectCamera(d.id) } label: {
                                    if d.id == cameraID || (cameraID.isEmpty && d.id == model.devices.first?.id) { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
                                }
                            }
                        } label: {
                            if Retro.is8bit {
                                RetroKeyFace(tint: Retro.Ink.plasticMid, compact: true) { Image(systemName: "camera.on.rectangle").frame(width: 14, height: 12) }
                            } else {
                                Image(systemName: "camera.on.rectangle").font(.system(size: 10, weight: .semibold)).foregroundStyle(Retro.quietInk)
                                    .frame(width: 22, height: 22)
                                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(MiniBoom.fill))
                                    .contentShape(Rectangle())
                            }
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    }
                    MirrorToolButton(symbol: "stop.fill", size: CGSize(width: 14, height: 12), help: "Stop camera") { model.stop() }
                }
                .padding(.bottom, 8)
                .opacity(hovering || previewState != nil ? 1 : 0)
                .animation(Theme.quick, value: hovering)
            }
        }
    }
}

/// The Start key of the stopped mirror: the yellow plastic key in the 8-bit look, a plain pill in the minimal one.
private struct StartKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        if Retro.is8bit {
            RetroButtonStyle(tint: Retro.Ink.yellow, compact: false).makeBody(configuration: configuration)
        } else {
            NotchPillButtonStyle().makeBody(configuration: configuration)
        }
    }
}

/// Type erasure for the three clip shapes.
struct AnyInsettableShape: InsettableShape {
    private let pathBuilder: @Sendable (CGRect) -> Path
    private let insetBuilder: @Sendable (CGFloat) -> AnyInsettableShape

    init<S: InsettableShape>(_ shape: S) {
        pathBuilder = { shape.path(in: $0) }
        insetBuilder = { AnyInsettableShape(shape.inset(by: $0)) }
    }

    func path(in rect: CGRect) -> Path { pathBuilder(rect) }
    func inset(by amount: CGFloat) -> AnyInsettableShape { insetBuilder(amount) }
}
