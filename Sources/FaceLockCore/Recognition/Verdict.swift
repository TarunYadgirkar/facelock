import Foundation

/// Decision thresholds for r50 (provisional; see docs/how-it-decides.md).
public struct Thresholds: Equatable, Sendable, Codable {
    /// T: the owner's calibrated acceptance score (union top-3).
    public var accept: Float
    /// F: anchor-only floor, from the committed harness.
    public var floor: Float
    /// S: a quality face at or below this is a stranger.
    public var stranger: Float
    /// C: T never rises above this.
    public var ceiling: Float

    public init(accept: Float, floor: Float = ModelCalibration.floor,
                stranger: Float = ModelCalibration.strangerScore, ceiling: Float = ModelCalibration.ceiling) {
        self.accept = accept
        self.floor = floor
        self.stranger = stranger
        self.ceiling = ceiling
    }

    /// Before any calibration: accept at the floor.
    public static let uncalibrated = Thresholds(accept: ModelCalibration.floor)
}

/// Numbers that belong to the model, detector and alignment, not to one owner. Recompute F with
/// `facelock-bench accuracy` and commit it whenever any of the three changes.
public enum ModelCalibration {
    public static let modelID = "ArcFaceR50-fp16+YuNet320x240+umeyama-vimage"
    /// ceil to 0.01 of (highest top-3 stranger score over all stand-in owners + 0.10): 0.3330 + 0.10.
    public static let floor: Float = 0.44
    public static let floorSource = "facelock-bench accuracy, LFW stand-in owners, stranger max 0.3330 + 0.10"
    public static let strangerScore: Float = 0.25
    public static let ceiling: Float = 0.60
    public static let floorMargin = 0.10

    public static func floor(fromStrangerMax max: Double) -> Float {
        Float(((max + floorMargin) * 100 - 1e-9).rounded(.up) / 100)
    }
}

public enum FrameVerdict: String, Codable, Sendable {
    case owner, stranger, unclear, noFace = "no_face"
}

public struct FaceObservation: Sendable, Equatable {
    public let face: DetectedFace
    public let metrics: FaceGeometryMetrics
    public let quality: QualityFlags
    public let score: MatchScore?
    public let embedding: [Float]?
    public let faceLuma: Double?
    public let sharpness: Double?

    public init(face: DetectedFace, metrics: FaceGeometryMetrics, quality: QualityFlags, score: MatchScore?,
                embedding: [Float]?, faceLuma: Double?, sharpness: Double?) {
        self.face = face
        self.metrics = metrics
        self.quality = quality
        self.score = score
        self.embedding = embedding
        self.faceLuma = faceLuma
        self.sharpness = sharpness
    }
}

public struct FrameObservation: Sendable, Equatable {
    public let faces: [FaceObservation]

    public init(faces: [FaceObservation]) {
        self.faces = faces
    }
}

public struct FrameClassification: Sendable, Equatable {
    public let verdict: FrameVerdict
    /// Index into `faces` of the owner face, when the verdict is owner.
    public let ownerIndex: Int?
    /// Another face big enough to read the screen sits next to the owner.
    public let secondFace: Bool
}

public enum VerdictRules {
    public static let secondFaceMinInterOcular = 28.0

    public static func isOwner(_ s: MatchScore, _ t: Thresholds) -> Bool {
        s.union >= t.accept && s.anchor >= t.floor
    }

    public static func classify(_ frame: FrameObservation, _ t: Thresholds) -> FrameClassification {
        let faces = frame.faces
        guard !faces.isEmpty else { return FrameClassification(verdict: .noFace, ownerIndex: nil, secondFace: false) }
        let owner = faces.indices
            .filter { faces[$0].quality.passes && faces[$0].score.map { isOwner($0, t) } == true }
            .max { faces[$0].score!.union < faces[$1].score!.union }
        if let o = owner {
            let other = faces.indices.contains { $0 != o && faces[$0].metrics.interOcular >= secondFaceMinInterOcular }
            return FrameClassification(verdict: .owner, ownerIndex: o, secondFace: other)
        }
        if faces.count == 1, faces[0].quality.passes, let s = faces[0].score, s.union <= t.stranger {
            return FrameClassification(verdict: .stranger, ownerIndex: nil, secondFace: false)
        }
        return FrameClassification(verdict: .unclear, ownerIndex: nil, secondFace: false)
    }
}
