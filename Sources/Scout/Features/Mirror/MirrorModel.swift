@preconcurrency import AVFoundation
import AppKit
import CoreImage
import SwiftUI

enum MirrorShape: String, CaseIterable, Identifiable {
    case circle, rounded, square
    var id: String { rawValue }
    var title: String {
        switch self {
        case .circle: String(localized: "Circle")
        case .rounded: String(localized: "Rounded")
        case .square: String(localized: "Square")
        }
    }
}

// MARK: - The camera behind the model

enum MirrorAuthorization: Equatable { case notDetermined, authorized, denied }

enum MirrorStartResult: Equatable {
    case running(aspect: CGFloat)
    case noCamera
}

/// What the Mirror needs from a camera. The real one is `MirrorAVDriver`; the self-test uses a stand-in that counts the calls,
/// so the rules (when the camera starts, when it stops, when macOS may ask) are checked without ever opening a camera.
@MainActor
protocol MirrorCameraDriver: AnyObject {
    var authorization: MirrorAuthorization { get }
    func requestAccess(_ done: @escaping @MainActor (Bool) -> Void)
    func devices() -> [MirrorModel.CameraInfo]
    func start(deviceID: String, _ done: @escaping @MainActor (MirrorStartResult) -> Void)
    func stop()
    /// The next frame as a still, held in memory only (the Freeze button); nil when none came.
    func snapshot(_ done: @escaping @MainActor (CGImage?) -> Void)
}

/// The real camera: one `AVCaptureSession` shared by the dashboard panel and the Mirror tab. It never asks macOS for access by
/// itself: `requestAccess` runs only from a button.
@MainActor
final class MirrorAVDriver: MirrorCameraDriver {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "scout.mirror.session")
    private let frameQueue = DispatchQueue(label: "scout.mirror.frames")
    private let grabber = MirrorFrameGrabber()

    var authorization: MirrorAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func requestAccess(_ done: @escaping @MainActor (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in done(granted) }
        }
    }

    private static func discover() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    func devices() -> [MirrorModel.CameraInfo] {
        Self.discover().map { MirrorModel.CameraInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    private func chosenDevice(_ id: String) -> AVCaptureDevice? {
        let all = Self.discover()
        if let match = all.first(where: { $0.uniqueID == id }) { return match }
        return AVCaptureDevice.default(for: .video) ?? all.first
    }

    func start(deviceID: String, _ done: @escaping @MainActor (MirrorStartResult) -> Void) {
        guard let device = chosenDevice(deviceID) else { done(.noCamera); return }
        queue.async { [session, grabber, frameQueue] in
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            session.sessionPreset = .high
            var ok = false
            if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
                ok = true
            }
            if ok {
                // Only to hold a frame when Freeze is pressed: the frames go nowhere else and are not kept.
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(grabber, queue: frameQueue)
                if session.canAddOutput(output) {
                    session.addOutput(output)
                    if let connection = output.connection(with: .video) {
                        connection.automaticallyAdjustsVideoMirroring = false
                        if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
                    }
                }
            }
            session.commitConfiguration()
            var aspect: CGFloat = 16.0 / 9.0
            if ok {
                session.startRunning()
                let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                if size.width > 0, size.height > 0 { aspect = CGFloat(max(size.width, size.height)) / CGFloat(min(size.width, size.height)) }
            }
            let result: MirrorStartResult = ok ? .running(aspect: aspect) : .noCamera
            Task { @MainActor in done(result) }
        }
    }

    func stop() {
        grabber.cancelAll()
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            session.commitConfiguration()
        }
    }

    func snapshot(_ done: @escaping @MainActor (CGImage?) -> Void) {
        let once = MirrorOnce()
        let finish: @Sendable (CGImage?) -> Void = { image in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if once.claim() { done(image) } }
            }
        }
        grabber.request(finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { finish(nil) }
    }
}

/// Lets a completion run once, from the main thread only.
private final class MirrorOnce: @unchecked Sendable {
    private var used = false
    func claim() -> Bool {
        if used { return false }
        used = true
        return true
    }
}

/// Turns the next camera frame into a still when asked, and does nothing with any other frame.
final class MirrorFrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [@Sendable (CGImage?) -> Void] = []
    private static let context = CIContext()

    func request(_ done: @escaping @Sendable (CGImage?) -> Void) {
        lock.lock()
        waiting.append(done)
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let list = waiting
        waiting = []
        lock.unlock()
        list.forEach { $0(nil) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        let list = waiting
        waiting = []
        lock.unlock()
        guard !list.isEmpty else { return }
        var image: CGImage?
        if let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let ci = CIImage(cvPixelBuffer: buffer)
            image = Self.context.createCGImage(ci, from: ci.extent)
        }
        list.forEach { $0(image) }
    }
}

// MARK: - The model

/// The camera behind the Mirror panel and the Mirror tab. ONE camera session for both. It runs only while at least one of them
/// is on screen (`viewAppeared` / `viewDisappeared`) and stops the moment the last one goes, so the green light is never on
/// otherwise. macOS asks for camera access only when `start()` is called from a button, never by itself.
@MainActor
final class MirrorModel: ObservableObject {
    static let shared = MirrorModel()

    enum State: Equatable { case stopped, starting, running, denied, noCamera }

    enum Key {
        static let shape = "mirror.shape"
        static let flip = "mirror.flip"
        static let camera = "mirror.camera"
        static let autostart = "mirror.autostart"
        static let lightLevel = "mirror.lightLevel"
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var devices: [CameraInfo] = []
    /// Width over height of the picture the camera delivers (16:9 until it says otherwise).
    @Published private(set) var aspect: CGFloat = 16.0 / 9.0

    struct CameraInfo: Identifiable, Hashable {
        let id: String
        let name: String
    }

    private let driver: MirrorCameraDriver
    /// True in scripted runs (self-tests, galleries, live checks): the camera never starts and nothing is asked.
    let scripted: Bool
    private var visibleCount = 0
    /// Bumped by every start and stop, so an answer that arrives after a stop (the macOS prompt, a slow camera) is ignored.
    private var generation = 0

    init(driver: MirrorCameraDriver? = nil, scripted: Bool = ScoutRuntime.isScripted) {
        self.driver = driver ?? MirrorAVDriver()
        self.scripted = scripted
    }

    /// The live session for the preview layer (nil for a stand-in driver).
    var session: AVCaptureSession? { (driver as? MirrorAVDriver)?.session }

    var authorization: MirrorAuthorization { driver.authorization }
    var selectedCameraID: String { Pref.string(Key.camera, "") }
    var viewersOnScreen: Int { visibleCount }

    // MARK: Devices

    func refreshDevices() {
        if scripted {
            devices = [CameraInfo(id: "sample-1", name: "FaceTime HD Camera"), CameraInfo(id: "sample-2", name: "iPhone Camera")]
            return
        }
        devices = driver.devices()
    }

    // MARK: Visibility

    /// The panel or the tab came on screen. `autostart`: start now when macOS has already allowed the camera (it never asks here).
    func viewAppeared(autostart: Bool) {
        visibleCount += 1
        refreshDevices()
        if scripted { return }
        if (state == .denied && driver.authorization == .authorized) || state == .noCamera { state = .stopped }
        if autostart, state == .stopped, driver.authorization == .authorized { start() }
    }

    func viewDisappeared() {
        visibleCount = max(0, visibleCount - 1)
        if visibleCount == 0 { stop() }
    }

    // MARK: Start / stop

    /// "Start" / "Turn on the camera": the only place macOS asks for camera access.
    func start() {
        guard !scripted, state != .running, state != .starting else { return }
        switch driver.authorization {
        case .authorized:
            run()
        case .notDetermined:
            state = .starting
            generation += 1
            let mine = generation
            driver.requestAccess { [weak self] granted in
                guard let self, mine == self.generation else { return }
                if granted {
                    self.state = .stopped
                    if self.visibleCount > 0 { self.run() }
                } else {
                    self.state = .denied
                }
            }
        case .denied:
            state = .denied
        }
    }

    private func run() {
        state = .starting
        generation += 1
        let mine = generation
        driver.start(deviceID: selectedCameraID) { [weak self] result in
            guard let self, mine == self.generation else { return }
            switch result {
            case .running(let aspect):
                self.aspect = aspect
                self.state = .running
            case .noCamera:
                self.state = .noCamera
            }
        }
    }

    func stop() {
        guard state == .running || state == .starting else { return }
        generation += 1
        state = .stopped
        driver.stop()
    }

    func selectCamera(_ id: String) {
        Pref.set(id, Key.camera)
        if state == .running { stop(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.start() } }
    }

    /// Holds the current frame as a still (nothing is saved).
    func snapshot(_ done: @escaping @MainActor (CGImage?) -> Void) {
        guard state == .running else { done(nil); return }
        driver.snapshot(done)
    }
}

// MARK: - Preview

/// Hosts the camera's preview layer, flipped like a mirror when `flip` is on. It never takes mouse events.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    var flip: Bool

    func makeNSView(context: Context) -> PreviewNSView {
        let v = PreviewNSView()
        v.previewLayer.videoGravity = .resizeAspectFill
        v.attach(session)
        v.flip = flip
        return v
    }

    func updateNSView(_ view: PreviewNSView, context: Context) {
        view.attach(session)
        view.flip = flip
    }

    final class PreviewNSView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        var flip = true { didSet { applyMirroring() } }
        private var started: NSObjectProtocol?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = previewLayer
        }

        required init?(coder: NSCoder) { fatalError() }

        deinit { if let started { NotificationCenter.default.removeObserver(started) } }

        func attach(_ session: AVCaptureSession) {
            guard previewLayer.session !== session else { return }
            previewLayer.session = session
            if let started { NotificationCenter.default.removeObserver(started) }
            // The connection exists only once the session runs: set the mirroring again when it does.
            started = NotificationCenter.default.addObserver(forName: AVCaptureSession.didStartRunningNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyMirroring() }
            }
            applyMirroring()
        }

        private func applyMirroring() {
            guard let c = previewLayer.connection, c.isVideoMirroringSupported else { return }
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = flip
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
