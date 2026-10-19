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

/// The real camera: one AVCaptureSession configured at launch (front camera, 640x480, BGRA,
/// delegate on the check queue) and left stopped between windows.
public final class CameraSession: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.tarunyadgirkar.facelock.camera", qos: .utility)
    public let device: AVCaptureDevice
    private var handler: (@Sendable (CapturedFrame) -> Void)?
    /// How long the last startRunning() call took.
    public private(set) var lastOpenSeconds: Double?

    public static var authorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }

    public static func defaultDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
    }

    public init(device: AVCaptureDevice? = CameraSession.defaultDevice()) throws {
        guard let device else { throw CameraError.noCamera }
        self.device = device
        super.init()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = session.canSetSessionPreset(.vga640x480) ? .vga640x480 : .medium
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else { throw CameraError.cannotAddOutput }
        session.addOutput(output)
    }

    /// A live preview of this session for enrollment screens. Mirroring is the caller's choice.
    public func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        AVCaptureVideoPreviewLayer(session: session)
    }

    public func start(queue: DispatchQueue, handler: @escaping @Sendable (CapturedFrame) -> Void) {
        self.handler = handler
        output.setSampleBufferDelegate(self, queue: queue)
        sessionQueue.async {
            let t0 = uptimeSeconds()
            self.session.startRunning()
            self.lastOpenSeconds = uptimeSeconds() - t0
        }
    }

    public func stop() {
        handler = nil
        sessionQueue.async { self.session.stopRunning() }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let handler, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let settled = !device.isAdjustingExposure && !device.isAdjustingWhiteBalance
        handler(CapturedFrame(pixelBuffer: pb, time: uptimeSeconds(), exposureSettled: settled))
    }
}

/// Camera connect, disconnect and suspension (lid closed) without polling.
public final class CameraAvailabilityMonitor: @unchecked Sendable {
    private var observers: [NSObjectProtocol] = []
    private var suspension: NSKeyValueObservation?

    public init(device: AVCaptureDevice?, onChange: @escaping @Sendable (Bool) -> Void) {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil) { _ in
            onChange(CameraSession.defaultDevice() != nil)
        })
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { _ in
            onChange(CameraSession.defaultDevice() != nil)
        })
        suspension = device?.observe(\.isSuspended, options: [.new]) { d, _ in onChange(!d.isSuspended) }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
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
