import Foundation

/// Provisional runtime gate (not measured; tune from local telemetry).
public struct QualityThresholds: Equatable, Sendable, Codable {
    public var minInterOcular: Double = 28
    public var maxRollDegrees: Double = 25
    public var maxYawProxy: Double = 0.35
    public var minEdgeMargin: Double = 2
    public var minFaceLuma: Double = 40
    /// Sharpness must reach this fraction of the enrollment's 5th percentile.
    public var sharpnessFraction: Double = 0.5

    public init() {}

    public static let standard = QualityThresholds()
}

public struct QualityFlags: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let tooSmall = QualityFlags(rawValue: 1 << 0)
    public static let tilted = QualityFlags(rawValue: 1 << 1)
    public static let turned = QualityFlags(rawValue: 1 << 2)
    public static let cutOff = QualityFlags(rawValue: 1 << 3)
    public static let dark = QualityFlags(rawValue: 1 << 4)
    public static let blurry = QualityFlags(rawValue: 1 << 5)

    public static let named: [(QualityFlags, String)] = [
        (.tooSmall, "too_small"), (.tilted, "tilted"), (.turned, "turned"),
        (.cutOff, "cut_off"), (.dark, "dark"), (.blurry, "blurry"),
    ]

    public var names: [String] { Self.named.filter { contains($0.0) }.map(\.1) }
    public var passes: Bool { isEmpty }
}

public struct FaceGeometryMetrics: Equatable, Sendable, Codable {
    public let interOcular: Double
    public let rollDegrees: Double
    public let yawProxy: Double
    public let edgeMargin: Double
}

public enum QualityGate {
    public static func metrics(_ face: DetectedFace, frameWidth: Double, frameHeight: Double) -> FaceGeometryMetrics {
        let b = face.box
        let margin = min(b.x, b.y, frameWidth - (b.x + b.width), frameHeight - (b.y + b.height))
        return FaceGeometryMetrics(interOcular: face.landmarks.interOcular, rollDegrees: face.landmarks.rollDegrees,
                                   yawProxy: face.landmarks.yawProxy, edgeMargin: margin)
    }

    /// The checks that need only YuNet's output, so a failing face skips alignment and embedding.
    public static func geometryFlags(_ m: FaceGeometryMetrics, _ t: QualityThresholds = .standard) -> QualityFlags {
        var flags: QualityFlags = []
        if m.interOcular < t.minInterOcular { flags.insert(.tooSmall) }
        if abs(m.rollDegrees) > t.maxRollDegrees { flags.insert(.tilted) }
        if !(abs(m.yawProxy) <= t.maxYawProxy) { flags.insert(.turned) }
        if m.edgeMargin < t.minEdgeMargin { flags.insert(.cutOff) }
        return flags
    }

    /// Checks on the aligned 112x112 crop. `sharpnessFloor` is nil until an enrollment sets it.
    public static func cropFlags(faceLuma: Double, sharpness: Double, sharpnessFloor: Double?,
                                 _ t: QualityThresholds = .standard) -> QualityFlags {
        var flags: QualityFlags = []
        if faceLuma < t.minFaceLuma { flags.insert(.dark) }
        if let floor = sharpnessFloor, sharpness < floor { flags.insert(.blurry) }
        return flags
    }

    public static func sharpnessFloor(enrollmentP5: Double?, _ t: QualityThresholds = .standard) -> Double? {
        enrollmentP5.map { $0 * t.sharpnessFraction }
    }
}
