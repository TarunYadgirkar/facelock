import Accelerate
import CoreVideo
import FaceLockCore
import Foundation

/// Similarity-warps the face from the full-resolution frame into a reused 112x112 crop.
public final class FaceAligner: @unchecked Sendable {
    public let crop = PixelBuffers.makeBGRA(width: ArcFaceTemplate.cropSize, height: ArcFaceTemplate.cropSize)

    public init() {}

    /// `landmarks` are in `source` pixel coordinates (top-left origin).
    @discardableResult
    public func align(_ landmarks: Landmarks, from source: vImage_Buffer) -> Bool {
        guard let m = SimilarityTransform.toArcFace(landmarks) else { return false }
        // Always from the whole frame: vImage's result depends on the source extent (a face-sized
        // source region moved the LFW stranger max by up to 0.004), and N2 measured the whole frame.
        let w = WarpTransform(similarity: m, sourceHeight: Int(source.height))
        var t = vImage_AffineTransform(a: Float(w.a), b: Float(w.b), c: Float(w.c), d: Float(w.d),
                                       tx: Float(w.tx), ty: Float(w.ty))
        CVPixelBufferLockBaseAddress(crop, [])
        defer { CVPixelBufferUnlockBaseAddress(crop, []) }
        var src = source
        var dst = vImage_Buffer(data: CVPixelBufferGetBaseAddress(crop), height: vImagePixelCount(ArcFaceTemplate.cropSize),
                                width: vImagePixelCount(ArcFaceTemplate.cropSize), rowBytes: CVPixelBufferGetBytesPerRow(crop))
        var bg: [UInt8] = [0, 0, 0, 0]
        let err = vImageAffineWarp_ARGB8888(&src, &dst, nil, &t, &bg,
                                            vImage_Flags(kvImageBackgroundColorFill | kvImageDoNotTile))
        return err == kvImageNoError
    }
}

/// Face-crop luma and Laplacian variance (sharpness) of the 112x112 crop, with buffers allocated once.
public final class CropAnalyzer: @unchecked Sendable {
    private let size = ArcFaceTemplate.cropSize
    private let luma8: UnsafeMutablePointer<UInt8>
    private let lumaF: UnsafeMutablePointer<Float>
    private let lap: UnsafeMutablePointer<Float>
    private static let laplacian: [Float] = [0, 1, 0, 1, -4, 1, 0, 1, 0]

    public init() {
        luma8 = .allocate(capacity: size * size)
        lumaF = .allocate(capacity: size * size)
        lap = .allocate(capacity: size * size)
    }

    deinit {
        luma8.deallocate()
        lumaF.deallocate()
        lap.deallocate()
    }

    public struct Result: Sendable, Equatable {
        public let meanLuma: Double
        public let sharpness: Double
    }

    public func analyze(_ crop: CVPixelBuffer) -> Result {
        PixelBuffers.withVImage(crop) { src in
            var s = src
            var y8 = vImage_Buffer(data: luma8, height: vImagePixelCount(size), width: vImagePixelCount(size), rowBytes: size)
            // BGRA memory order: B, G, R, A weights for BT.601 luma, divisor 256
            let matrix: [Int16] = [29, 150, 77, 0]
            var pre: [Int16] = [0, 0, 0, 0]
            vImageMatrixMultiply_ARGB8888ToPlanar8(&s, &y8, matrix, 256, &pre, 0, vImage_Flags(kvImageNoFlags))
            var yf = vImage_Buffer(data: lumaF, height: vImagePixelCount(size), width: vImagePixelCount(size),
                                   rowBytes: size * 4)
            vImageConvert_Planar8toPlanarF(&y8, &yf, 255, 0, vImage_Flags(kvImageNoFlags))
            var out = vImage_Buffer(data: lap, height: vImagePixelCount(size), width: vImagePixelCount(size), rowBytes: size * 4)
            vImageConvolve_PlanarF(&yf, &out, nil, 0, 0, Self.laplacian, 3, 3, 0, vImage_Flags(kvImageEdgeExtend))
            let n = vDSP_Length(size * size)
            var mean: Float = 0, lapMean: Float = 0, lapSq: Float = 0
            vDSP_meanv(lumaF, 1, &mean, n)
            vDSP_meanv(lap, 1, &lapMean, n)
            vDSP_measqv(lap, 1, &lapSq, n)
            return Result(meanLuma: Double(mean), sharpness: Double(lapSq - lapMean * lapMean))
        }
    }
}
