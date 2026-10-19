import AVFoundation
import CoreMedia
import FaceLockCore
import Foundation

public enum CameraError: Error, CustomStringConvertible {
    case noCamera, cannotAddInput, cannotAddOutput

    public var description: String {
        switch self {
        case .noCamera: return "No camera found"
        case .cannotAddInput: return "The camera could not be opened"
        case .cannotAddOutput: return "The camera output could not be configured"
        }
    }
}

/// The real camera: one AVCaptureSession configured once (front camera, 640x480, BGRA, delegate
/// on the check queue) and left stopped between windows.
public final class CameraSession: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public static let frameWidth = 640
    public static let frameHeight = 480

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.tarunyadgirkar.facelock.camera", qos: .utility)
    public let device: AVCaptureDevice
    private let lock = NSLock()
    private var handler: (@Sendable (CapturedFrame) -> Void)?
    private var runtimeErrorObserver: NSObjectProtocol?
    private var storedOpenSeconds: Double?
    private var storedRuntimeError: (@Sendable () -> Void)?

    /// Called on any queue when the session reports a runtime error; the session is dead after one.
    public var onRuntimeError: (@Sendable () -> Void)? {
        get { lock.withLock { storedRuntimeError } }
        set { lock.withLock { storedRuntimeError = newValue } }
    }

    /// How long the last startRunning() call took.
    public var lastOpenSeconds: Double? { lock.withLock { storedOpenSeconds } }

    public static var authorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }

    static let watchedTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external]

    /// The camera to watch with: the built-in one unless it is suspended (lid closed), then any
    /// other connected camera that is not. Continuity Camera only when it is the system default.
    public static func preferredDevice() -> AVCaptureDevice? {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: watchedTypes, mediaType: .video, position: .unspecified).devices
        let usable = found.filter(isUsable)
        let builtIn = { (d: AVCaptureDevice) in d.deviceType == .builtInWideAngleCamera }
        return usable.first(where: builtIn) ?? usable.first ?? found.first(where: builtIn) ?? found.first
            ?? AVCaptureDevice.default(for: .video)
    }

    public static func defaultDevice() -> AVCaptureDevice? { preferredDevice() }

    public static func isUsable(_ d: AVCaptureDevice) -> Bool { d.isConnected && !d.isSuspended }

    public init(device: AVCaptureDevice? = CameraSession.preferredDevice()) throws {
        guard let device else { throw CameraError.noCamera }
        self.device = device
        super.init()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = session.canSetSessionPreset(.vga640x480) ? .vga640x480 : .medium
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)
        // 640x480 whatever the preset gives, so the detector sees the scale it was enrolled at (N6).
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                kCVPixelBufferWidthKey as String: Self.frameWidth,
                                kCVPixelBufferHeightKey as String: Self.frameHeight]
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else { throw CameraError.cannotAddOutput }
        session.addOutput(output)
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
            self?.onRuntimeError?()
        }
    }

    deinit {
        runtimeErrorObserver.map(NotificationCenter.default.removeObserver)
    }

    /// A live preview of this session for enrollment screens. Mirroring is the caller's choice.
    public func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        AVCaptureVideoPreviewLayer(session: session)
    }

    public func start(queue: DispatchQueue, handler: @escaping @Sendable (CapturedFrame) -> Void) {
        lock.withLock { self.handler = handler }
        output.setSampleBufferDelegate(self, queue: queue)
        sessionQueue.async {
            let t0 = uptimeSeconds()
            self.session.startRunning()
            let open = uptimeSeconds() - t0
            self.lock.withLock { self.storedOpenSeconds = open }
        }
    }

    public func stop() {
        lock.withLock { handler = nil }
        sessionQueue.async { self.session.stopRunning() }
    }

    /// Runs the camera until its first frame or `timeout`, then stops it. True when a frame came.
    public func probe(timeout: TimeInterval = 5) async -> Bool {
        let queue = DispatchQueue(label: "com.tarunyadgirkar.facelock.camera.probe", qos: .utility)
        let once = Once()
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            start(queue: queue) { [weak self] _ in
                guard once.claim() else { return }
                self?.stop()
                c.resume(returning: true)
            }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard once.claim() else { return }
                self?.stop()
                c.resume(returning: false)
            }
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let handler = lock.withLock({ self.handler }), let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let settled = !device.isAdjustingExposure && !device.isAdjustingWhiteBalance
        handler(CapturedFrame(pixelBuffer: pb, time: uptimeSeconds(), exposureSettled: settled))
    }
}

/// True for the first caller only.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}

/// The watcher camera's own connection and suspension (lid closed), observed without polling.
/// Reports the device's state at once, then on every change.
public final class CameraAvailabilityMonitor: @unchecked Sendable {
    public struct DeviceState: Equatable, Sendable {
        public let deviceID: String
        public let connected: Bool
        public let suspended: Bool

        public init(deviceID: String, connected: Bool, suspended: Bool) {
            self.deviceID = deviceID
            self.connected = connected
            self.suspended = suspended
        }

        public var usable: Bool { connected && !suspended }
    }

    private var observations: [NSKeyValueObservation] = []

    public init(device: AVCaptureDevice, onChange: @escaping @Sendable (DeviceState) -> Void) {
        let report = { @Sendable (d: AVCaptureDevice) in
            onChange(DeviceState(deviceID: d.uniqueID, connected: d.isConnected, suspended: d.isSuspended))
        }
        observations.append(device.observe(\.isSuspended, options: [.initial, .new]) { d, _ in report(d) })
        observations.append(device.observe(\.isConnected, options: [.new]) { d, _ in report(d) })
    }

    deinit {
        observations.forEach { $0.invalidate() }
    }
}

/// Any video camera that connects, for a Mac that had none or lost its watcher camera. Audio
/// devices (AirPods and the like) are ignored.
public final class CameraArrivalMonitor: @unchecked Sendable {
    private var observer: NSObjectProtocol?

    public init(onArrival: @escaping @Sendable () -> Void) {
        observer = NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil,
                                                          queue: nil) { note in
            guard let d = note.object as? AVCaptureDevice, d.hasMediaType(.video) else { return }
            onArrival()
        }
    }

    deinit {
        observer.map(NotificationCenter.default.removeObserver)
    }
}

/// Median and p95 of camera timings over several checks, for Diagnostics > Measure camera timing.
public struct CameraTimingReport: Equatable, Sendable {
    public let checks: Int
    public let firstFrame: (median: Double, p95: Double)?
    public let settled: (median: Double, p95: Double)?
    public let onTime: (median: Double, p95: Double)?

    public init(_ timings: [WindowTiming]) {
        func agg(_ xs: [Double]) -> (Double, Double)? {
            xs.isEmpty ? nil : (Stats.median(xs), Stats.quantile(xs, 0.95))
        }
        checks = timings.count
        firstFrame = agg(timings.compactMap(\.firstFrame))
        settled = agg(timings.compactMap(\.settled))
        onTime = agg(timings.map(\.cameraOn))
    }

    public static func == (a: CameraTimingReport, b: CameraTimingReport) -> Bool {
        a.checks == b.checks && a.onTime?.median == b.onTime?.median && a.onTime?.p95 == b.onTime?.p95
    }
}
