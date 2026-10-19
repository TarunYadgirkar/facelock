import FaceLockCore
import Foundation
import Testing

@Suite("Quality gate")
struct QualityGateTests {
    func flags(_ f: DetectedFace) -> QualityFlags {
        QualityGate.geometryFlags(QualityGate.metrics(f, frameWidth: 640, frameHeight: 480))
    }

    @Test("a frontal face of normal size passes")
    func frontal() {
        #expect(flags(frontalFace()).passes)
    }

    @Test("synthetic landmark sets fail the matching check", arguments: [
        (frontalFace(iod: 20), QualityFlags.tooSmall),
        (frontalFace(roll: 30), .tilted),
        (frontalFace(roll: -30), .tilted),
        (frontalFace(yaw: 0.5), .turned),
        (frontalFace(yaw: -0.4), .turned),
        (frontalFace(x: 1), .cutOff),
        (frontalFace(x: 530), .cutOff),
    ])
    func failures(_ f: DetectedFace, _ expected: QualityFlags) {
        #expect(flags(f).contains(expected))
    }

    @Test("roll and yaw just inside the limits pass")
    func limits() {
        #expect(flags(frontalFace(roll: 24)).passes)
        #expect(flags(frontalFace(yaw: 0.34)).passes)
        #expect(flags(frontalFace(iod: 28)).passes)
    }

    @Test("dark and blurry crops fail; no blur check before enrollment sets a floor")
    func cropChecks() {
        #expect(QualityGate.cropFlags(faceLuma: 39, sharpness: 100, sharpnessFloor: nil) == .dark)
        #expect(QualityGate.cropFlags(faceLuma: 120, sharpness: 10, sharpnessFloor: 20) == .blurry)
        #expect(QualityGate.cropFlags(faceLuma: 120, sharpness: 10, sharpnessFloor: nil).passes)
        #expect(QualityGate.sharpnessFloor(enrollmentP5: 80) == 40)
    }

    @Test("Umeyama maps the template onto itself and recovers a known similarity")
    func umeyama() {
        let id = SimilarityTransform.estimate(from: ArcFaceTemplate.points, to: ArcFaceTemplate.points)!
        #expect(abs(id.a - 1) < 1e-9 && abs(id.b) < 1e-9 && abs(id.tx) < 1e-9)
        let known = SimilarityTransform(a: 0.5 * cos(0.2), b: 0.5 * sin(0.2), tx: 12, ty: -7)
        let src = ArcFaceTemplate.points.map { Point2D($0.x * 3 + 100, $0.y * 3 + 50) }
        let dst = src.map(known.apply)
        let fit = SimilarityTransform.estimate(from: src, to: dst)!
        #expect(abs(fit.a - known.a) < 1e-9 && abs(fit.b - known.b) < 1e-9)
        #expect(abs(fit.tx - known.tx) < 1e-6 && abs(fit.ty - known.ty) < 1e-6)
    }

    @Test("NMS keeps the best of overlapping boxes")
    func nms() {
        let a = frontalFace(), b = DetectedFace(box: a.box, landmarks: a.landmarks, score: 0.9)
        let c = frontalFace(x: 20, y: 20, iod: 30)
        let kept = NonMaximumSuppression.apply([b, a, c], iouThreshold: 0.3)
        #expect(kept.count == 2)
        #expect(kept[0].score == 0.95)
    }
}

@Suite("Still face")
struct StillFaceTests {
    func series(count: Int, every seconds: Double, jitter: Double = 0, scale: Double = 0) -> StillFaceDetector {
        (0..<count).reduce(StillFaceDetector()) { d, i in
            let f = frontalFace(x: 260 + jitter * Double(i % 2 == 0 ? 1 : -1), iod: 60 * (1 + scale * Double(i % 2)))
            return d.adding(StillFaceSample(at: t0.addingTimeInterval(Double(i) * seconds), landmarks: f.landmarks,
                                            boxWidth: f.box.width))
        }
    }

    @Test("a static face over 6 checks and 3 minutes is flagged")
    func staticFlagged() {
        #expect(series(count: 6, every: 36).isFlagged)
    }

    @Test("not flagged with jitter, scale change, too few checks or too short a span")
    func notFlagged() {
        #expect(!series(count: 6, every: 36, jitter: 2).isFlagged)
        #expect(!series(count: 6, every: 36, scale: 0.02).isFlagged)
        #expect(!series(count: 5, every: 60).isFlagged)
        #expect(!series(count: 6, every: 30).isFlagged)
    }

    @Test("small sensor noise under 1.5 px RMS still counts as still")
    func noise() {
        #expect(series(count: 6, every: 40, jitter: 1).isFlagged)
    }

    @Test("head-turn challenge needs a 0.15 yaw change")
    func headTurn() {
        #expect(HeadTurnChallenge.passed(yawRange: 0.16))
        #expect(!HeadTurnChallenge.passed(yawRange: 0.1))
        #expect(!HeadTurnChallenge.passed(yawRange: nil))
    }
}

@Suite("Window pacing")
struct WindowGateTests {
    @Test("frames are discarded until exposure settles, capped at 0.6 s after the first frame")
    func settle() {
        var g = WindowGate(policy: .regular, startedAt: 0)
        var a: WindowGate.Action
        (g, a) = g.next(frameAt: 0.03, exposureSettled: false, luma: 100)
        #expect(a == .discard)
        (g, a) = g.next(frameAt: 0.2, exposureSettled: true, luma: 20)
        #expect(a == .discard)
        (g, a) = g.next(frameAt: 0.3, exposureSettled: true, luma: 90)
        #expect(a == .process)
        #expect(g.settledAt == 0.3)

        var capped = WindowGate(policy: .regular, startedAt: 0)
        (capped, a) = capped.next(frameAt: 0.05, exposureSettled: false, luma: 5)
        #expect(a == .discard)
        (capped, a) = capped.next(frameAt: 0.66, exposureSettled: false, luma: 5)
        #expect(a == .process)
    }

    @Test("processed frames are at least 100 ms apart and stop at 6")
    func spacingAndCap() {
        var g = WindowGate(policy: .regular, startedAt: 0)
        var processed = 0
        var t = 0.0
        var a = WindowGate.Action.discard
        while a != .finish {
            t += 1.0 / 30
            (g, a) = g.next(frameAt: t, exposureSettled: true, luma: 100)
            if a == .process { processed += 1 }
        }
        #expect(processed == 6)
        #expect(t < 0.8)
    }

    @Test("a check closes 1.5 s after settling; a countdown counts from its start")
    func deadlines() {
        var g = WindowGate(policy: .regular, startedAt: 10)
        (g, _) = g.next(frameAt: 10.4, exposureSettled: true, luma: 100)
        #expect(abs(g.deadline - 11.9) < 1e-9)
        let c = WindowGate(policy: .countdown(seconds: 10), startedAt: 10)
        #expect(c.deadline == 20)
        #expect(WindowPolicy.countdown(seconds: 10).minFrameSpacing == 0.25)
        #expect(abs(WindowPolicy.recheck.maxOnTime - 2.6) < 1e-9)
    }

    @Test("early accept on the first owner frame")
    func earlyAccept() {
        let t = Thresholds(accept: 0.5)
        let owner = FrameObservation(faces: [observation(score: MatchScore(union: 0.8, anchor: 0.8))])
        let acc = WindowAccumulator(policy: .regular, thresholds: t).adding(owner)
        #expect(acc.shouldStop)
        #expect(acc.verdict == .owner)
        #expect(acc.summary(timing: .zero).owner != nil)
        let countdown = WindowAccumulator(policy: .countdown(seconds: 10), thresholds: t)
            .adding(FrameObservation(faces: [observation(score: MatchScore(union: 0.3, anchor: 0.3))]))
        #expect(countdown.shouldStop)
        #expect(countdown.verdict == .unclear)
    }
}
