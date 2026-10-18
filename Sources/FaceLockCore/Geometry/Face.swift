import Foundation

public struct Point2D: Equatable, Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public func distance(to other: Point2D) -> Double {
        ((x - other.x) * (x - other.x) + (y - other.y) * (y - other.y)).squareRoot()
    }
}

public struct FaceBox: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var area: Double { width * height }

    public func iou(_ other: FaceBox) -> Double {
        let x1 = max(x, other.x), y1 = max(y, other.y)
        let x2 = min(x + width, other.x + other.width), y2 = min(y + height, other.y + other.height)
        let inter = max(0, x2 - x1) * max(0, y2 - y1)
        let union = area + other.area - inter
        return union > 0 ? inter / union : 0
    }
}

/// YuNet's five points, in image order: the eye nearer the image's left edge first,
/// then the other eye, the nose tip, and the two mouth corners in the same left-right order.
/// This is also the order of the ArcFace alignment template.
public struct Landmarks: Equatable, Sendable, Codable {
    public let points: [Point2D]

    public init(_ points: [Point2D]) {
        precondition(points.count == 5, "five landmarks")
        self.points = points
    }

    public var leftEye: Point2D { points[0] }
    public var rightEye: Point2D { points[1] }
    public var nose: Point2D { points[2] }

    public var eyeMidpoint: Point2D {
        Point2D((leftEye.x + rightEye.x) / 2, (leftEye.y + rightEye.y) / 2)
    }

    public var interOcular: Double { leftEye.distance(to: rightEye) }

    public var rollDegrees: Double {
        atan2(rightEye.y - leftEye.y, rightEye.x - leftEye.x) * 180 / .pi
    }

    /// Horizontal nose offset from the eye midpoint, in inter-ocular units. Signed, so a head
    /// turn shows up as a change of value; the quality gate uses its magnitude.
    public var yawProxy: Double {
        let iod = interOcular
        return iod > 0 ? (nose.x - eyeMidpoint.x) / iod : .infinity
    }

    public func mapped(_ transform: (Point2D) -> Point2D) -> Landmarks {
        Landmarks(points.map(transform))
    }
}

public struct DetectedFace: Equatable, Sendable, Codable {
    public let box: FaceBox
    public let landmarks: Landmarks
    public let score: Double

    public init(box: FaceBox, landmarks: Landmarks, score: Double) {
        self.box = box
        self.landmarks = landmarks
        self.score = score
    }
}

public enum NonMaximumSuppression {
    /// Greedy NMS by score; returns the kept faces, highest score first.
    public static func apply(_ faces: [DetectedFace], iouThreshold: Double) -> [DetectedFace] {
        faces.sorted { $0.score > $1.score }.reduce(into: [DetectedFace]()) { kept, face in
            if kept.allSatisfy({ $0.box.iou(face.box) <= iouThreshold }) {
                kept.append(face)
            }
        }
    }
}
