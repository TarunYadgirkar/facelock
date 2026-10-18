import Foundation

/// The 9 onboarding targets, in order. Pose rules are provisional (tune from telemetry).
public enum EnrollmentTarget: String, Codable, Sendable, CaseIterable {
    case centre, left, right, up, down, closer, farther, leaningBack = "leaning_back", glasses

    public var title: String {
        switch self {
        case .centre: return "Look at the camera"
        case .left: return "Turn a little to your left"
        case .right: return "Turn a little to your right"
        case .up: return "Tilt your head up a little"
        case .down: return "Tilt your head down a little"
        case .closer: return "Move closer"
        case .farther: return "Move back"
        case .leaningBack: return "Lean back as if reading"
        case .glasses: return "Glasses on, or off if you wear them"
        }
    }

    public var isSkippable: Bool { self == .glasses }
}

public enum EnrollmentRejection: String, Equatable, Sendable {
    case notOneFace, quality, tooSoon, notNovel, wrongPose, targetFull
}

/// Pose measures relative to the centre target, from YuNet's five points only.
public struct PoseMetrics: Equatable, Sendable {
    public let yaw: Double
    /// Nose height between the eye line (0) and the mouth line (1).
    public let pitch: Double
    public let interOcular: Double

    public init(_ l: Landmarks) {
        yaw = l.yawProxy
        let eyeY = l.eyeMidpoint.y, mouthY = (l.points[3].y + l.points[4].y) / 2
        pitch = mouthY > eyeY ? (l.nose.y - eyeY) / (mouthY - eyeY) : 0.5
        interOcular = l.interOcular
    }
}

public struct PoseRules: Equatable, Sendable {
    public var minYawTurn = 0.08
    public var minPitchChange = 0.06
    public var closerScale = 1.15
    public var fartherScale = 0.87

    public init() {}

    /// `centre` is the median pose of the accepted centre frames; nil before there are any.
    public func matches(_ target: EnrollmentTarget, _ p: PoseMetrics, centre: PoseMetrics?) -> Bool {
        guard let c = centre else { return target == .centre || target == .glasses }
        switch target {
        case .centre, .glasses: return true
        // Camera frames are not mirrored: turning to your left moves the nose to the image's right.
        case .left: return p.yaw - c.yaw >= minYawTurn
        case .right: return p.yaw - c.yaw <= -minYawTurn
        case .up: return p.pitch - c.pitch <= -minPitchChange
        case .down: return p.pitch - c.pitch >= minPitchChange
        case .closer: return p.interOcular >= c.interOcular * closerScale
        case .farther: return p.interOcular <= c.interOcular * fartherScale
        case .leaningBack: return p.interOcular <= c.interOcular * 0.93 && p.pitch - c.pitch >= minPitchChange / 2
        }
    }
}

/// Onboarding capture: a target fills after 6 accepted frames at least 250 ms apart whose
/// embedding differs from every frame already accepted in this session (cosine below 0.97).
public struct EnrollmentSession: Equatable, Sendable {
    public static let framesPerTarget = 6
    public static let minSpacing: TimeInterval = 0.25
    public static let noveltyCeiling: Float = 0.97

    public let session: Int
    public let rules: PoseRules
    public private(set) var accepted: [EnrollmentTarget: [Template]] = [:]
    public private(set) var lastAcceptedAt: Date?
    public private(set) var skipped: Set<EnrollmentTarget> = []
    private var centrePoses: [PoseMetrics] = []

    public init(session: Int, rules: PoseRules = PoseRules()) {
        self.session = session
        self.rules = rules
    }

    public func progress(_ t: EnrollmentTarget) -> Double {
        min(1, Double(accepted[t]?.count ?? 0) / Double(Self.framesPerTarget))
    }

    public var currentTarget: EnrollmentTarget? {
        EnrollmentTarget.allCases.first { !skipped.contains($0) && progress($0) < 1 }
    }

    public var isComplete: Bool { currentTarget == nil }
    public var templates: [Template] { EnrollmentTarget.allCases.flatMap { accepted[$0] ?? [] } }

    var centre: PoseMetrics? {
        guard !centrePoses.isEmpty else { return nil }
        func med(_ f: (PoseMetrics) -> Double) -> Double { Stats.median(centrePoses.map(f)) }
        return PoseMetrics(yaw: med(\.yaw), pitch: med(\.pitch), interOcular: med(\.interOcular))
    }

    public func skipping(_ t: EnrollmentTarget) -> EnrollmentSession {
        guard t.isSkippable else { return self }
        var s = self
        s.skipped.insert(t)
        return s
    }

    /// Offers one analysed frame for `target`; returns the new session, or why it was not taken.
    public func offering(_ frame: FrameObservation, for target: EnrollmentTarget, at now: Date)
        -> (EnrollmentSession, EnrollmentRejection?) {
        guard frame.faces.count == 1, let face = frame.faces.first else { return (self, .notOneFace) }
        guard face.quality.passes, let e = face.embedding else { return (self, .quality) }
        guard progress(target) < 1 else { return (self, .targetFull) }
        if let last = lastAcceptedAt, now.timeIntervalSince(last) < Self.minSpacing { return (self, .tooSoon) }
        let pose = PoseMetrics(face.face.landmarks)
        guard rules.matches(target, pose, centre: centre) else { return (self, .wrongPose) }
        if templates.contains(where: { Scorer.cosine(e, $0.vector) >= Self.noveltyCeiling }) { return (self, .notNovel) }
        var s = self
        s.accepted[target, default: []].append(Template(embedding: e, pool: .anchor, capturedAt: now, session: session,
                                                        target: target.rawValue, sharpness: Float(face.sharpness ?? 0)))
        s.lastAcceptedAt = now
        if target == .centre { s.centrePoses.append(pose) }
        return (s, nil)
    }
}

extension PoseMetrics {
    init(yaw: Double, pitch: Double, interOcular: Double) {
        self.yaw = yaw
        self.pitch = pitch
        self.interOcular = interOcular
    }
}

public enum TeachOutcome: Equatable, Sendable {
    case added(templates: Int)
    /// The faces taught score below S against the enrollment: a different person.
    case differentPerson
    case nothingCaptured
}

/// "Teach a new look": after Touch ID or the password, 5 s of frames with exactly one face that
/// passes the quality gate. Frames below the current threshold are accepted (that is the point);
/// the whole look is rejected when its median anchor score is below S.
public struct TeachSession: Equatable, Sendable {
    public static let seconds: TimeInterval = 5

    public let startedAt: Date
    public private(set) var captured: [Template] = []
    public private(set) var anchorScores: [Float] = []

    public init(startedAt: Date) {
        self.startedAt = startedAt
    }

    public func isOver(at now: Date) -> Bool { now.timeIntervalSince(startedAt) >= Self.seconds }

    public func offering(_ frame: FrameObservation, at now: Date, session: Int) -> TeachSession {
        guard !isOver(at: now), frame.faces.count == 1, let f = frame.faces.first, f.quality.passes,
              let e = f.embedding, let score = f.score,
              captured.allSatisfy({ now.timeIntervalSince($0.capturedAt) >= EnrollmentSession.minSpacing }),
              !captured.contains(where: { Scorer.cosine(e, $0.vector) >= EnrollmentSession.noveltyCeiling }) else { return self }
        var t = self
        t.captured.append(Template(embedding: e, pool: .anchor, capturedAt: now, session: session, target: "teach",
                                   sharpness: Float(f.sharpness ?? 0)))
        t.anchorScores.append(score.anchor)
        return t
    }

    public func finish(into gallery: Gallery, thresholds: Thresholds) -> (Gallery, TeachOutcome) {
        guard !captured.isEmpty else { return (gallery, .nothingCaptured) }
        let median = Float(Stats.median(anchorScores.map(Double.init)))
        guard median >= thresholds.stranger else { return (gallery, .differentPerson) }
        return (gallery.adding(captured), .added(templates: captured.count))
    }
}

/// "Check with someone else": the best score a second person reaches against the owner's
/// gallery over 10 s. Their embeddings are never kept.
public struct SomeoneElseCheck: Equatable, Sendable {
    public static let seconds: TimeInterval = 10
    public private(set) var maxScore: Float?

    public init() {}

    public func offering(_ frame: FrameObservation) -> SomeoneElseCheck {
        let best = frame.faces.compactMap { $0.score?.union }.max()
        guard let best else { return self }
        var c = self
        c.maxScore = max(maxScore ?? best, best)
        return c
    }
}
