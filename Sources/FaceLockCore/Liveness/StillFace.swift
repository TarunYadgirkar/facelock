import Foundation

public enum StillFaceMode: String, Codable, Sendable, CaseIterable {
    case off
    /// Log flags, never lock. The shipping default until telemetry shows the owner's false-flag rate.
    case observe
    /// A flag starts the head-turn challenge.
    case on
}

public struct StillFaceSample: Equatable, Sendable {
    public let at: Date
    public let landmarks: Landmarks
    public let boxWidth: Double

    public init(at: Date, landmarks: Landmarks, boxWidth: Double) {
        self.at = at
        self.landmarks = landmarks
        self.boxWidth = boxWidth
    }
}

/// Flags a face that stays perfectly still over consecutive present checks, as a propped-up
/// photo does. It cannot tell a video of the owner from the owner.
public struct StillFaceDetector: Equatable, Sendable {
    public static let minChecks = 6
    public static let minSpan: TimeInterval = 180
    public static let maxRMSMotion = 1.5
    public static let maxScaleChange = 0.01

    public private(set) var samples: [StillFaceSample] = []

    public init() {}

    public func adding(_ s: StillFaceSample) -> StillFaceDetector {
        var d = self
        d.samples = Array((samples + [s]).suffix(Self.minChecks * 4))
        return d
    }

    public func reset() -> StillFaceDetector { StillFaceDetector() }

    /// RMS distance of each landmark from its mean position over the recent samples.
    public static func rmsMotion(_ s: [StillFaceSample]) -> Double {
        guard !s.isEmpty else { return 0 }
        var total = 0.0
        for k in 0..<5 {
            let xs = s.map { $0.landmarks.points[k].x }, ys = s.map { $0.landmarks.points[k].y }
            let mx = Stats.mean(xs), my = Stats.mean(ys)
            total += zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.0 - mx) + ($1.1 - my) * ($1.1 - my) }
        }
        return (total / Double(5 * s.count)).squareRoot()
    }

    public static func scaleChange(_ s: [StillFaceSample]) -> Double {
        let w = s.map(\.boxWidth)
        guard let lo = w.min(), let hi = w.max(), Stats.mean(w) > 0 else { return 0 }
        return (hi - lo) / Stats.mean(w)
    }

    public var isFlagged: Bool {
        let recent = Array(samples.suffix(Self.minChecks))
        guard recent.count >= Self.minChecks, let first = recent.first, let last = recent.last,
              last.at.timeIntervalSince(first.at) >= Self.minSpan else { return false }
        return Self.rmsMotion(recent) < Self.maxRMSMotion && Self.scaleChange(recent) < Self.maxScaleChange
    }
}

/// "Turn your head": the owner's yaw proxy must move by at least `requiredRange` within the window.
public enum HeadTurnChallenge {
    public static let requiredRange = 0.15
    public static let seconds: TimeInterval = 8

    public static func passed(yawRange: Double?) -> Bool {
        (yawRange ?? 0) >= requiredRange
    }
}
