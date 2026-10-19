import CoreGraphics
import CoreImage
import FaceLockCapture
import FaceLockCore
import FaceLockVision
import Foundation

/// One analysed frame on a setup screen.
struct LiveFrame: @unchecked Sendable {
    let observation: FrameObservation
    /// Vision's face capture quality, enrollment only.
    let captureQuality: Float?
    let frameLuma: Double
    /// The frame itself, only for the demo camera (the real camera previews through its own layer).
    let preview: CGImage?
    let at: Date
}

/// A source that can hand the setup screen a picture of what it shows (the demo camera).
protocol PreviewImageSource: AnyObject {
    var previewImage: CGImage? { get }
}

/// The camera stream for enrollment, Teach and Check with someone else: the same pipeline and
/// detector scale as a check (N6), at most one analysed frame every `interval`.
final class LiveCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.tarunyadgirkar.facelock.setup", qos: .userInitiated)
    private let source: FrameSource
    private let pipeline: FacePipeline
    private let recognition: RecognitionContext?
    private let measureCaptureQuality: Bool
    private let interval: Double
    private var lastAnalysed = 0.0
    private var running = false

    init(source: FrameSource, pipeline: FacePipeline, recognition: RecognitionContext?, measureCaptureQuality: Bool,
         interval: Double = 0.12) {
        self.source = source
        self.pipeline = pipeline
        self.recognition = recognition
        self.measureCaptureQuality = measureCaptureQuality
        self.interval = interval
    }

    func start(_ onFrame: @escaping @Sendable (LiveFrame) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            running = true
            lastAnalysed = 0
            source.start(queue: queue) { [weak self] frame in self?.handle(frame, onFrame) }
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.source.stop()
        }
    }

    private func handle(_ frame: CapturedFrame, _ onFrame: @Sendable (LiveFrame) -> Void) {
        guard running, frame.time - lastAnalysed >= interval else { return }
        lastAnalysed = frame.time
        let result: LiveFrame? = autoreleasepool {
            let analysed = PixelBuffers.withVImage(frame.pixelBuffer) { v -> (FrameAnalysis?, Double) in
                (try? pipeline.analyze(frame: v, recognition: recognition), meanLuma(v))
            }
            guard let analysis = analysed.0 else { return nil }
            let quality = measureCaptureQuality && analysis.observation.faces.count == 1
                ? EnrollmentQuality.captureQuality(frame.pixelBuffer) : nil
            return LiveFrame(observation: analysis.observation, captureQuality: quality, frameLuma: analysed.1,
                             preview: (source as? PreviewImageSource)?.previewImage, at: Date())
        }
        if let result { onFrame(result) }
    }
}
