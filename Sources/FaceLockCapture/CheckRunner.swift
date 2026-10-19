import CoreVideo
import FaceLockCore
import FaceLockVision
import Foundation
import os

/// Runs one window against a frame source: discards frames until exposure settles (0.6 s cap
/// from the first frame), processes frames no closer than the policy spacing, and stops on early
/// accept, the frame cap or the deadline. The camera runs only between start and finish. A camera
/// that sends nothing within `WindowPolicy.openTimeout` ends the window as `.cameraFailed`.
public final class CheckRunner: CheckPerforming, @unchecked Sendable {
    private struct Run {
        let id: Int
        var gate: WindowGate
        var accumulator: WindowAccumulator
        let recognition: RecognitionContext
        let completion: @Sendable (Int, WindowSummary) -> Void
    }

    private static let log = Logger(subsystem: "com.tarunyadgirkar.facelock", category: "check")
    /// Slack after the last possible frame before the watchdog ends the window.
    private static let watchdogSlack: TimeInterval = 0.25

    private let queue = DispatchQueue(label: "com.tarunyadgirkar.facelock.check", qos: .utility)
    private let source: FrameSource
    private let pipeline: FacePipeline
    private let watchdog: DispatchSourceTimer
    private var run: Run?
    private var frameObserver: (@Sendable (FrameAnalysis) -> Void)?

    public init(source: FrameSource, pipeline: FacePipeline) {
        self.source = source
        self.pipeline = pipeline
        watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .distantFuture)
        watchdog.setEventHandler { [weak self] in self?.finish() }
        watchdog.activate()
    }

    deinit {
        watchdog.cancel()
    }

    /// Every analysed frame, for Diagnostics and benchmarks.
    public func observeFrames(_ observer: @escaping @Sendable (FrameAnalysis) -> Void) {
        queue.async { self.frameObserver = observer }
    }

    public func startWindow(id: Int, kind: CheckKind, policy: WindowPolicy, recognition: RecognitionContext,
                            completion: @escaping @Sendable (Int, WindowSummary) -> Void) {
        queue.async {
            if self.run != nil { self.stopCamera() }
            let start = uptimeSeconds()
            self.run = Run(id: id, gate: WindowGate(policy: policy, startedAt: start),
                           accumulator: WindowAccumulator(policy: policy, thresholds: recognition.thresholds),
                           recognition: recognition, completion: completion)
            // Countdowns run to their shown deadline; checks first wait for the camera to open.
            let firstWait = policy.countsFromStart ? policy.duration : WindowPolicy.openTimeout
            self.watchdog.schedule(deadline: .now() + firstWait + Self.watchdogSlack)
            self.source.start(queue: self.queue) { frame in self.handle(frame) }
        }
    }

    public func abortWindow() {
        queue.async {
            guard self.run != nil else { return }
            self.stopCamera()
            self.run = nil
        }
    }

    private func stopCamera() {
        source.stop()
        watchdog.schedule(deadline: .distantFuture)
    }

    private func handle(_ frame: CapturedFrame) {
        guard var r = run else { return }
        if r.gate.firstFrameAt == nil {
            r.accumulator = r.accumulator.noting(frameSize: FrameSize(width: CVPixelBufferGetWidth(frame.pixelBuffer),
                                                                      height: CVPixelBufferGetHeight(frame.pixelBuffer)))
            // The settle cap and the duration count from the first frame, so a slow open is not a miss.
            if !r.gate.policy.countsFromStart {
                watchdog.schedule(deadline: .now() + r.gate.policy.maxOnTime + Self.watchdogSlack)
            }
        }
        let luma = r.gate.settledAt == nil
            ? PixelBuffers.withVImage(frame.pixelBuffer) { meanLuma($0) } : 255
        let (gate, action) = r.gate.next(frameAt: frame.time, exposureSettled: frame.exposureSettled, luma: luma)
        r.gate = gate
        run = r
        switch action {
        case .discard: return
        case .finish: return finish()
        case .process: break
        }
        let result: Result<FrameAnalysis, Error> = autoreleasepool {
            PixelBuffers.withVImage(frame.pixelBuffer) { v in Result { try pipeline.analyze(frame: v, recognition: r.recognition) } }
        }
        switch result {
        case let .success(analysis):
            frameObserver?(analysis)
            r.accumulator = r.accumulator.adding(analysis.observation)
        case let .failure(error):
            Self.log.error("frame analysis failed: \(String(describing: error), privacy: .public)")
            r.accumulator = r.accumulator.addingFailure()
        }
        run = r
        if r.accumulator.shouldStop || r.gate.isFull { finish() }
    }

    private func finish() {
        guard let r = run else { return }
        stopCamera()
        run = nil
        r.completion(r.id, r.accumulator.summary(timing: r.gate.timing(endedAt: uptimeSeconds())))
    }
}
