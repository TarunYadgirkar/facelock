import Accelerate
import CoreML
import FaceLockCore
import Foundation

/// YuNet on Core ML: a 320x240 BGRA pixel buffer in (Core ML reads it as a BGR image, so no
/// CPU-side float conversion), faces in 640x480 frame pixels out. The decode, including the 2x
/// scale back to the frame, runs inside the graph.
public final class FaceDetector: @unchecked Sendable {
    public static let inputWidth = 320
    public static let inputHeight = 240
    public static let frameWidth = 640.0
    public static let frameHeight = 480.0
    public static let minScore = 0.85
    public static let nmsIoU = 0.3

    private let model: MLModel
    private let provider: MLDictionaryFeatureProvider
    /// The detector input, IOSurface-backed and reused; callers fill it with `withInput`.
    public let input = PixelBuffers.makeBGRA(width: FaceDetector.inputWidth, height: FaceDetector.inputHeight)

    public init(url: URL, compute: ComputeChoice = .neuralEngine) throws {
        model = try loadModel(url, compute: compute)
        provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)])
    }

    /// Writes into the detector input (locked for the duration).
    public func withInput<R>(_ body: (vImage_Buffer) throws -> R) rethrows -> R {
        CVPixelBufferLockBaseAddress(input, [])
        defer { CVPixelBufferUnlockBaseAddress(input, []) }
        let v = vImage_Buffer(data: CVPixelBufferGetBaseAddress(input), height: vImagePixelCount(Self.inputHeight),
                              width: vImagePixelCount(Self.inputWidth), rowBytes: CVPixelBufferGetBytesPerRow(input))
        return try body(v)
    }

    /// Scales a full camera frame into the detector input (vImageScale into the reused buffer).
    public func scale(from source: vImage_Buffer) {
        withInput { dst in
            var src = source, d = dst
            vImageScale_ARGB8888(&src, &d, nil, vImage_Flags(kvImageNoFlags))
        }
    }

    /// Faces scoring at least 0.85 after NMS at IoU 0.3, largest first.
    public func detect() throws -> [DetectedFace] {
        guard let dets = try model.prediction(from: provider).featureValue(for: "dets")?.multiArrayValue else { return [] }
        return NonMaximumSuppression.apply(Self.parse(dets), iouThreshold: Self.nmsIoU).sorted { $0.box.area > $1.box.area }
    }

    static func parse(_ d: MLMultiArray) -> [DetectedFace] {
        let rows = d.shape.count == 3 ? d.shape[1].intValue : d.shape[0].intValue
        let rs = d.strides[d.shape.count == 3 ? 1 : 0].intValue, cs = d.strides[d.shape.count - 1].intValue
        if d.dataType == .float16 {
            return parse(d.dataPointer.assumingMemoryBound(to: Float16.self), rows: rows, rowStride: rs, colStride: cs)
        }
        return parse(d.dataPointer.assumingMemoryBound(to: Float.self), rows: rows, rowStride: rs, colStride: cs)
    }

    static func parse<T: BinaryFloatingPoint>(_ p: UnsafePointer<T>, rows: Int, rowStride rs: Int, colStride cs: Int) -> [DetectedFace] {
        let minScore = T(Self.minScore)
        var faces: [DetectedFace] = []
        for r in 0..<rows where p[r * rs + 14 * cs] >= minScore {
            let v = { (c: Int) in Double(p[r * rs + c * cs]) }
            faces.append(DetectedFace(box: FaceBox(x: v(0), y: v(1), width: v(2), height: v(3)),
                                      landmarks: Landmarks((0..<5).map { Point2D(v(4 + 2 * $0), v(5 + 2 * $0)) }),
                                      score: v(14)))
        }
        return faces
    }
}
