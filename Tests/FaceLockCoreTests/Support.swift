import FaceLockCore
import Foundation

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func unit(_ seed: Int, size: Int = embeddingSize) -> [Float] {
    var x = UInt64(truncatingIfNeeded: seed &* 2_654_435_761 &+ 1)
    let v = (0..<size).map { _ -> Float in
        x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(Int64(bitPattern: x >> 11) % 2001 - 1000) / 1000
    }
    return Scorer.normalized(v)
}

/// A unit vector whose cosine with `base` is `c`.
func vector(near base: [Float], cosine c: Float, seed: Int) -> [Float] {
    let r = unit(seed)
    let d = zip(r, base).reduce(0) { $0 + $1.0 * $1.1 }
    let ortho = Scorer.normalized(zip(r, base).map { $0 - d * $1 })
    let s = (1 - c * c).squareRoot()
    return zip(base, ortho).map { c * $0 + s * $1 }
}

func template(_ e: [Float], pool: TemplatePool = .anchor, at seconds: Double = 0, session: Int = 0,
              target: String = "centre", sharpness: Float = 100) -> Template {
    Template(embedding: e, pool: pool, capturedAt: t0.addingTimeInterval(seconds), session: session, target: target,
             sharpness: sharpness)
}

func frontalFace(x: Double = 260, y: Double = 140, iod: Double = 60, roll: Double = 0, yaw: Double = 0) -> DetectedFace {
    let r = roll * .pi / 180
    let cx = x + iod, cy = y + iod * 0.9
    func rot(_ dx: Double, _ dy: Double) -> Point2D { Point2D(cx + dx * cos(r) - dy * sin(r), cy + dx * sin(r) + dy * cos(r)) }
    let pts = [rot(-iod / 2, -iod * 0.3), rot(iod / 2, -iod * 0.3), rot(yaw * iod, iod * 0.15),
               rot(-iod * 0.4, iod * 0.6), rot(iod * 0.4, iod * 0.6)]
    return DetectedFace(box: FaceBox(x: x, y: y, width: iod * 2, height: iod * 2.4), landmarks: Landmarks(pts), score: 0.95)
}

func observation(score: MatchScore?, quality: QualityFlags = [], face: DetectedFace = frontalFace(),
                 embedding: [Float]? = nil) -> FaceObservation {
    FaceObservation(face: face, metrics: QualityGate.metrics(face, frameWidth: 640, frameHeight: 480), quality: quality,
                    score: score, embedding: embedding ?? (score == nil ? nil : unit(1)), faceLuma: 120, sharpness: 100)
}

func ownerSample(_ face: DetectedFace = frontalFace(), faces: Int = 1) -> OwnerSample {
    OwnerSample(landmarks: face.landmarks, boxWidth: face.box.width, embedding: unit(1),
                score: MatchScore(union: 0.8, anchor: 0.8), faceCount: faces, sharpness: 100)
}

func summary(_ v: WindowVerdict, secondFace: Bool = false, owner: OwnerSample? = nil, yawRange: Double? = nil,
             faces: Int? = nil, onTime: Double = 0.4) -> WindowSummary {
    let count = faces ?? (v == .away ? 0 : 1)
    return WindowSummary(verdict: v, frames: 3, ownerFrames: v == .owner ? 1 : 0, strangerFrames: v == .stranger ? 2 : 0,
                         unclearFrames: v == .unclear ? 1 : 0, noFaceFrames: v == .away ? 3 : 0, maxFaceCount: count,
                         bestScore: v == .away ? nil : 0.5, bestAnchorScore: v == .away ? nil : 0.5, qualityFlags: [],
                         secondFace: secondFace, owner: v == .owner ? (owner ?? ownerSample()) : nil, yawRange: yawRange,
                         timing: WindowTiming(cameraOn: onTime, firstFrame: 0.05, settled: 0.2))
}

/// Feeds events to the reducer and keeps the state and the effects of the last step.
struct Harness {
    var state: WatcherState
    var effects: [WatcherEffect] = []
    var now = t0

    init(settings: WatcherSettings = WatcherSettings()) {
        state = WatcherState(settings: settings)
    }

    mutating func send(_ e: WatcherEvent, after seconds: Double = 0) {
        now = now.addingTimeInterval(seconds)
        let t = Watcher.reduce(state, e, now: now)
        state = t.state
        effects = t.effects
    }

    var windowID: Int? {
        for case let .startWindow(id, _, _) in effects.reversed() { return id }
        return nil
    }

    var startedKind: CheckKind? {
        for case let .startWindow(_, kind, _) in effects.reversed() { return kind }
        return nil
    }

    var scheduledDelay: Double? {
        for case let .schedule(at) in effects.reversed() { return at.timeIntervalSince(now) }
        return nil
    }

    var records: [CheckRecord] {
        effects.compactMap { if case let .record(r) = $0 { return r } else { return nil } }
    }

    func has(_ e: WatcherEffect) -> Bool { effects.contains(e) }

    var locked: Bool { effects.contains(.lock) }

    /// Finishes the running window with `s`.
    mutating func finish(_ s: WindowSummary, after seconds: Double = 0) {
        guard let id = state.activeWindow?.id else { return }
        send(.windowFinished(id: id, summary: s), after: seconds)
    }

    /// From start, finishes windows with `verdicts` in turn, firing the timer between them.
    mutating func run(_ verdicts: [WindowVerdict]) {
        for (i, v) in verdicts.enumerated() {
            if i > 0 { send(.timerFired, after: scheduledDelay ?? 0) }
            finish(summary(v))
        }
    }
}
