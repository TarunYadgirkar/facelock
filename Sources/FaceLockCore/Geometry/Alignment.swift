import Foundation

/// The standard InsightFace ArcFace 5-point template for a 112x112 crop.
public enum ArcFaceTemplate {
    public static let cropSize = 112
    public static let points: [Point2D] = [
        Point2D(38.2946, 51.6963), Point2D(73.5318, 51.5014), Point2D(56.0252, 71.7366),
        Point2D(41.5493, 92.3655), Point2D(70.7299, 92.2041),
    ]
}

/// 4-DOF similarity: x' = a x - b y + tx, y' = b x + a y + ty.
public struct SimilarityTransform: Equatable, Sendable {
    public let a: Double
    public let b: Double
    public let tx: Double
    public let ty: Double

    public init(a: Double, b: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.tx = tx
        self.ty = ty
    }

    /// Least-squares (Umeyama) similarity taking `source` onto `target`.
    public static func estimate(from source: [Point2D], to target: [Point2D]) -> SimilarityTransform? {
        guard source.count == target.count, source.count >= 2 else { return nil }
        let n = Double(source.count)
        let ms = Point2D(source.map(\.x).reduce(0, +) / n, source.map(\.y).reduce(0, +) / n)
        let md = Point2D(target.map(\.x).reduce(0, +) / n, target.map(\.y).reduce(0, +) / n)
        var sa = 0.0, sb = 0.0, norm = 0.0
        for (s, d) in zip(source, target) {
            let sx = s.x - ms.x, sy = s.y - ms.y, dx = d.x - md.x, dy = d.y - md.y
            sa += sx * dx + sy * dy
            sb += sx * dy - sy * dx
            norm += sx * sx + sy * sy
        }
        guard norm > 0 else { return nil }
        let a = sa / norm, b = sb / norm
        return SimilarityTransform(a: a, b: b, tx: md.x - (a * ms.x - b * ms.y), ty: md.y - (b * ms.x + a * ms.y))
    }

    public static func toArcFace(_ landmarks: Landmarks) -> SimilarityTransform? {
        estimate(from: landmarks.points, to: ArcFaceTemplate.points)
    }

    public func apply(_ p: Point2D) -> Point2D {
        Point2D(a * p.x - b * p.y + tx, b * p.x + a * p.y + ty)
    }

    public var scale: Double { (a * a + b * b).squareRoot() }

    /// Row-major 2x3 matrix in OpenCV's top-left-origin convention.
    public var matrix: [Double] { [a, -b, tx, b, a, ty] }
}

/// The affine (a, b, c, d, tx, ty) that vImageAffineWarp expects for a top-left-origin similarity,
/// conjugated with y flips of the source and destination (vImage measures y from the bottom).
public struct WarpTransform: Equatable, Sendable {
    public let a: Double
    public let b: Double
    public let c: Double
    public let d: Double
    public let tx: Double
    public let ty: Double

    public init(similarity m: SimilarityTransform, sourceHeight: Int, destinationHeight: Int = ArcFaceTemplate.cropSize) {
        let hs = Double(sourceHeight) - 0.5, hd = Double(destinationHeight) - 0.5
        let mat = m.matrix
        a = mat[0]
        b = -mat[3]
        c = -mat[1]
        d = mat[4]
        tx = mat[2] + mat[1] * hs
        ty = hd - (mat[5] + mat[4] * hs)
    }
}
