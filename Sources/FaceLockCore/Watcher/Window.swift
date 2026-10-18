import Foundation

public enum CheckKind: String, Codable, Sendable, CaseIterable {
    /// From Watching, every `interval`.
    case regular
    /// After a miss, with the camera off in between.
    case recheck
    /// "Check now" from the menu.
    case manual
    /// The camera stays on through the countdown.
    case countdown
    /// The full check a countdown cancel forces.
    case confirm
    /// "Turn your head" after a still-face flag.
    case challenge
}

public enum StopRule: String, Codable, Sendable {
    /// Early accept on the first owner frame.
    case owner
    /// Any face ends the window (the countdown cancels on it).
    case anyFace
    /// Ends once the owner's yaw proxy has moved far enough.
    case headTurn
}

public struct WindowPolicy: Equatable, Sendable, Codable {
    public var settleCap: TimeInterval = 0.6
    public var minSettledLuma: Double = 40
    public var minFrameSpacing: TimeInterval = 0.1
    /// Window length. Counted from the first settled frame for checks, from the start for
    /// countdowns and challenges, whose deadline the panel shows.
    public var duration: TimeInterval
    public var countsFromStart: Bool
    public var maxFrames: Int?
    public var stopRule: StopRule
    public var headTurnRange: Double = 0.15

    public init(duration: TimeInterval, countsFromStart: Bool = false, maxFrames: Int?, stopRule: StopRule,
                minFrameSpacing: TimeInterval = 0.1) {
        self.duration = duration
        self.countsFromStart = countsFromStart
        self.maxFrames = maxFrames
        self.stopRule = stopRule
        self.minFrameSpacing = minFrameSpacing
    }

    public static let regular = WindowPolicy(duration: 1.5, maxFrames: 6, stopRule: .owner)
    public static let recheck = WindowPolicy(duration: 2.0, maxFrames: 6, stopRule: .owner)
    public static let challengeSeconds: TimeInterval = 8

    public static func countdown(seconds: TimeInterval) -> WindowPolicy {
        WindowPolicy(duration: seconds, countsFromStart: true, maxFrames: nil, stopRule: .anyFace, minFrameSpacing: 0.25)
    }

    public static let challenge = WindowPolicy(duration: challengeSeconds, countsFromStart: true, maxFrames: nil,
                                               stopRule: .headTurn)

    public static func forKind(_ kind: CheckKind, countdownSeconds: TimeInterval) -> WindowPolicy {
        switch kind {
        case .regular, .manual: return .regular
        case .recheck, .confirm: return .recheck
        case .countdown: return .countdown(seconds: countdownSeconds)
        case .challenge: return .challenge
        }
    }

    /// Longest the camera can stay on for this window.
    public var maxOnTime: TimeInterval { countsFromStart ? duration : settleCap + duration }
}

/// Frame pacing for one window: discard until exposure settles (capped), then process frames
/// no closer than `minFrameSpacing`, until the duration or frame cap. Times are seconds on any
/// monotonic clock.
public struct WindowGate: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case discard, process, finish }

    public let policy: WindowPolicy
    public let startedAt: Double
    public private(set) var firstFrameAt: Double?
    public private(set) var settledAt: Double?
    public private(set) var lastProcessedAt: Double?
    public private(set) var processed = 0

    public init(policy: WindowPolicy, startedAt: Double) {
        self.policy = policy
        self.startedAt = startedAt
    }

    public var deadline: Double {
        if policy.countsFromStart { return startedAt + policy.duration }
        return (settledAt ?? startedAt + policy.settleCap) + policy.duration
    }

    public func next(frameAt t: Double, exposureSettled: Bool, luma: Double) -> (WindowGate, Action) {
        var g = self
        if g.firstFrameAt == nil { g.firstFrameAt = t }
        if t >= g.deadline { return (g, .finish) }
        if let cap = g.policy.maxFrames, g.processed >= cap { return (g, .finish) }
        if g.settledAt == nil {
            let settled = exposureSettled && luma >= g.policy.minSettledLuma
            guard settled || t - g.startedAt >= g.policy.settleCap else { return (g, .discard) }
            g.settledAt = t
        }
        if let last = g.lastProcessedAt, t - last < g.policy.minFrameSpacing { return (g, .discard) }
        g.lastProcessedAt = t
        g.processed += 1
        return (g, .process)
    }

    public var isFull: Bool { policy.maxFrames.map { processed >= $0 } ?? false }

    public func timing(endedAt t: Double) -> WindowTiming {
        WindowTiming(cameraOn: t - startedAt, firstFrame: firstFrameAt.map { $0 - startedAt },
                     settled: settledAt.map { $0 - startedAt })
    }
}

public struct WindowTiming: Equatable, Sendable, Codable {
    public let cameraOn: TimeInterval
    public let firstFrame: TimeInterval?
    public let settled: TimeInterval?

    public init(cameraOn: TimeInterval, firstFrame: TimeInterval?, settled: TimeInterval?) {
        self.cameraOn = cameraOn
        self.firstFrame = firstFrame
        self.settled = settled
    }

    public static let zero = WindowTiming(cameraOn: 0, firstFrame: nil, settled: nil)
}

public enum WindowVerdict: String, Codable, Sendable {
    case owner, stranger, unclear, away
}

/// The owner face of the window's best owner frame: what still-face, adaptation and the
/// head-turn challenge look at.
public struct OwnerSample: Equatable, Sendable {
    public let landmarks: Landmarks
    public let boxWidth: Double
    public let embedding: [Float]
    public let score: MatchScore
    public let faceCount: Int
    public let sharpness: Double

    public init(landmarks: Landmarks, boxWidth: Double, embedding: [Float], score: MatchScore, faceCount: Int, sharpness: Double) {
        self.landmarks = landmarks
        self.boxWidth = boxWidth
        self.embedding = embedding
        self.score = score
        self.faceCount = faceCount
        self.sharpness = sharpness
    }
}

public struct WindowSummary: Equatable, Sendable {
    public let verdict: WindowVerdict
    public let frames: Int
    public let ownerFrames: Int
    public let strangerFrames: Int
    public let unclearFrames: Int
    public let noFaceFrames: Int
    public let maxFaceCount: Int
    public let bestScore: Float?
    public let bestAnchorScore: Float?
    public let qualityFlags: QualityFlags
    public let secondFace: Bool
    public let owner: OwnerSample?
    public let yawRange: Double?
    public let timing: WindowTiming

    public init(verdict: WindowVerdict, frames: Int, ownerFrames: Int, strangerFrames: Int, unclearFrames: Int,
                noFaceFrames: Int, maxFaceCount: Int, bestScore: Float?, bestAnchorScore: Float?, qualityFlags: QualityFlags,
                secondFace: Bool, owner: OwnerSample?, yawRange: Double?, timing: WindowTiming) {
        self.verdict = verdict
        self.frames = frames
        self.ownerFrames = ownerFrames
        self.strangerFrames = strangerFrames
        self.unclearFrames = unclearFrames
        self.noFaceFrames = noFaceFrames
        self.maxFaceCount = maxFaceCount
        self.bestScore = bestScore
        self.bestAnchorScore = bestAnchorScore
        self.qualityFlags = qualityFlags
        self.secondFace = secondFace
        self.owner = owner
        self.yawRange = yawRange
        self.timing = timing
    }

    public var sawFace: Bool { maxFaceCount > 0 }
}

/// Accumulates frame verdicts for one window and says when it may stop early.
public struct WindowAccumulator: Equatable, Sendable {
    public let policy: WindowPolicy
    public let thresholds: Thresholds
    private(set) var frames = 0
    private(set) var counts: [FrameVerdict: Int] = [:]
    private(set) var maxFaces = 0
    private(set) var bestScore: Float?
    private(set) var bestAnchor: Float?
    private(set) var flags: QualityFlags = []
    private(set) var secondFace = false
    private(set) var owner: OwnerSample?
    private(set) var yawMin: Double?
    private(set) var yawMax: Double?

    public init(policy: WindowPolicy, thresholds: Thresholds) {
        self.policy = policy
        self.thresholds = thresholds
    }

    public func adding(_ frame: FrameObservation) -> WindowAccumulator {
        var a = self
        let c = VerdictRules.classify(frame, thresholds)
        a.frames += 1
        a.counts[c.verdict, default: 0] += 1
        a.maxFaces = max(a.maxFaces, frame.faces.count)
        for f in frame.faces {
            a.flags.formUnion(f.quality)
            if let s = f.score {
                a.bestScore = max(a.bestScore ?? -1, s.union)
                a.bestAnchor = max(a.bestAnchor ?? -1, s.anchor)
            }
        }
        a.secondFace = a.secondFace || c.secondFace
        if let i = c.ownerIndex, let s = frame.faces[i].score, let e = frame.faces[i].embedding {
            let f = frame.faces[i]
            if a.owner.map({ s.union > $0.score.union }) ?? true {
                a.owner = OwnerSample(landmarks: f.face.landmarks, boxWidth: f.face.box.width, embedding: e, score: s,
                                      faceCount: frame.faces.count, sharpness: f.sharpness ?? 0)
            }
            let yaw = f.face.landmarks.yawProxy
            a.yawMin = min(a.yawMin ?? yaw, yaw)
            a.yawMax = max(a.yawMax ?? yaw, yaw)
        }
        return a
    }

    public var yawRange: Double? { yawMin.flatMap { lo in yawMax.map { $0 - lo } } }

    public var shouldStop: Bool {
        switch policy.stopRule {
        case .owner: return (counts[.owner] ?? 0) > 0
        case .anyFace: return maxFaces > 0
        case .headTurn: return (yawRange ?? 0) >= policy.headTurnRange
        }
    }

    public var verdict: WindowVerdict {
        if (counts[.owner] ?? 0) > 0 { return .owner }
        if (counts[.stranger] ?? 0) >= 2 { return .stranger }
        if (counts[.stranger] ?? 0) + (counts[.unclear] ?? 0) > 0 { return .unclear }
        return .away
    }

    public func summary(timing: WindowTiming) -> WindowSummary {
        WindowSummary(verdict: verdict, frames: frames, ownerFrames: counts[.owner] ?? 0,
                      strangerFrames: counts[.stranger] ?? 0, unclearFrames: counts[.unclear] ?? 0,
                      noFaceFrames: counts[.noFace] ?? 0, maxFaceCount: maxFaces, bestScore: bestScore,
                      bestAnchorScore: bestAnchor, qualityFlags: flags, secondFace: secondFace, owner: owner,
                      yawRange: yawRange, timing: timing)
    }
}
