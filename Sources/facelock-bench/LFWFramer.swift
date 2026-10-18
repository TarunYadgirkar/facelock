import Accelerate
import CoreGraphics
import FaceLockCore
import FaceLockVision
import Foundation

/// Puts a 250x250 LFW image where a face sits in a 640x480 camera frame after the 2x downscale:
/// 240x240 at x = 40 inside the 320x240 detector input, on grey 90. The crop is warped from the
/// original 250x250 pixels. This is the framing N2 measured, so the numbers compare directly.
final class LFWFramer {
    static let side = 250
    static let offsetX = 40.0
    static let scale = 240.0 / 250.0

    let pipeline: FacePipeline
    let full = BGRABuffer(width: LFWFramer.side, height: LFWFramer.side)
    private let fullContext: CGContext

    init(pipeline: FacePipeline) {
        self.pipeline = pipeline
        fullContext = full.context()
    }

    func prepare(_ img: CGImage) {
        let w = FaceDetector.inputWidth, h = FaceDetector.inputHeight
        pipeline.detector.withInput { v in
            let small = CGContext(data: v.data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: v.rowBytes,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            small.interpolationQuality = .high
            small.setFillColor(gray: 90 / 255, alpha: 1)
            small.fill(CGRect(x: 0, y: 0, width: w, height: h))
            small.draw(img, in: CGRect(x: Self.offsetX, y: 0, width: 240, height: 240))
        }
        fullContext.draw(img, in: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
    }

    func toSource(_ p: Point2D) -> Point2D {
        Point2D((p.x / 2 - Self.offsetX) / Self.scale, p.y / 2 / Self.scale)
    }

    func analyze(recognition: RecognitionContext?, options: AnalysisOptions) throws -> FrameAnalysis {
        try pipeline.analyzePrepared(source: full.vImage, toSource: toSource, recognition: recognition, options: options)
    }
}

/// The stored-image camera's 640x480 frame of one image, for runtime-path measurements.
func cameraFrame(_ url: URL) throws -> BGRABuffer {
    let b = BGRABuffer(width: 640, height: 480)
    ImageFile.render(try ImageFile.load(url), into: b)
    return b
}
