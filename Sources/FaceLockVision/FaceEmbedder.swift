import CoreML
import CoreVideo
import FaceLockCore
import Foundation

/// ArcFace w600k_r50 on Core ML: the aligned 112x112 crop in, an L2-normalized 512-float embedding out.
public final class FaceEmbedder: @unchecked Sendable {
    private let model: MLModel
    private let provider: MLDictionaryFeatureProvider

    public init(url: URL, crop: CVPixelBuffer, compute: ComputeChoice = .neuralEngine) throws {
        model = try loadModel(url, compute: compute)
        provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: crop)])
    }

    public func embed() throws -> [Float] {
        guard let v = try model.prediction(from: provider).featureValue(for: "embedding")?.multiArrayValue else {
            return []
        }
        let stride = v.strides[v.strides.count - 1].intValue
        let out: [Float]
        switch v.dataType {
        case .float16:
            let p = v.dataPointer.assumingMemoryBound(to: Float16.self)
            out = (0..<embeddingSize).map { Float(p[$0 * stride]) }
        default:
            let p = v.dataPointer.assumingMemoryBound(to: Float.self)
            out = (0..<embeddingSize).map { p[$0 * stride] }
        }
        return Scorer.normalized(out)
    }
}
