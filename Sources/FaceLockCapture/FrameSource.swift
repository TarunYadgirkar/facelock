import CoreVideo
import FaceLockVision
import Foundation

/// Seconds on the uptime clock (stops while the Mac sleeps; checks never run then).
@inline(__always) public func uptimeSeconds() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1e9
}

public struct CapturedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let time: Double
    /// Neither exposure nor white balance is still adjusting.
    public let exposureSettled: Bool

    public init(pixelBuffer: CVPixelBuffer, time: Double, exposureSettled: Bool) {
        self.pixelBuffer = pixelBuffer
        self.time = time
        self.exposureSettled = exposureSettled
    }
}

/// A camera that is configured once and only runs during a window.
public protocol FrameSource: AnyObject, Sendable {
    /// Starts delivering frames, serially, on `queue`.
    func start(queue: DispatchQueue, handler: @escaping @Sendable (CapturedFrame) -> Void)
    func stop()
}

/// The stored-image camera: one image rendered once into a 640x480 BGRA frame, delivered at
/// 30 fps while running. For dry runs, benchmarks, and `--demo-camera` screenshots, so the
/// owner's camera never appears in a committed image.
public final class StoredImageCamera: FrameSource, @unchecked Sendable {
    public static let fps = 30.0

    private let lock = NSLock()
    private var current: CVPixelBuffer
    private let settleDelay: Double
    private var timer: DispatchSourceTimer?
    private var startedAt = 0.0

    public init(image url: URL, settleDelay: Double = 0) throws {
        current = try Self.render(url)
        self.settleDelay = settleDelay
    }

    public var frame: CVPixelBuffer { lock.withLock { current } }

    /// Swaps the scene, e.g. to an empty room (nil) so a dry run walks through the lock sequence.
    public func show(_ url: URL?) throws {
        let next = try Self.render(url)
        lock.withLock { current = next }
    }

    private static func render(_ url: URL?) throws -> CVPixelBuffer {
        let b = BGRABuffer(width: 640, height: 480)
        if let url {
            ImageFile.render(try ImageFile.load(url), into: b)
        } else {
            b.fill(gray: 90)
        }
        let pb = PixelBuffers.makeBGRA(width: 640, height: 480)
        PixelBuffers.copy(b, to: pb)
        return pb
    }

    public func start(queue: DispatchQueue, handler: @escaping @Sendable (CapturedFrame) -> Void) {
        timer?.cancel()
        startedAt = uptimeSeconds()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1 / Self.fps, repeating: 1 / Self.fps, leeway: .milliseconds(2))
        t.setEventHandler { [weak self, settleDelay, startedAt] in
            guard let self else { return }
            let now = uptimeSeconds()
            handler(CapturedFrame(pixelBuffer: self.frame, time: now, exposureSettled: now - startedAt >= settleDelay))
        }
        timer = t
        t.activate()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }
}
