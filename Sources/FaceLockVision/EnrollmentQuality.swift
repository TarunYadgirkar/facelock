import CoreVideo
import Foundation
import Vision

/// Vision's face capture quality (0...1), used during enrollment only. Never on the per-check
/// path: Vision's face requests cost more than the whole YuNet + r50 pipeline.
public enum EnrollmentQuality {
    public static func captureQuality(_ frame: CVPixelBuffer) -> Float? {
        let request = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: frame, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        return request.results?.compactMap(\.faceCaptureQuality).max()
    }
}
