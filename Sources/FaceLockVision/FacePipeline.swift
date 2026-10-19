import Accelerate
import FaceLockCore
import Foundation

public struct StageTimes: Equatable, Sendable {
    public var detect = 0.0
    public var align = 0.0
    public var quality = 0.0
    public var embed = 0.0

    public var total: Double { detect + align + quality + embed }
}

public struct FrameAnalysis: Sendable {
    public let observation: FrameObservation
    /// Faces YuNet found, before the `maxFaces` cut.
    public let detectedFaces: Int
    /// Milliseconds per stage.
    public let times: StageTimes
}

public struct AnalysisOptions: Sendable {
    public var maxFaces = 3
    /// Align and embed every face even when it fails the gate (the accuracy harness does, as N2 did).
    public var embedAll = false

    public init(maxFaces: Int = 3, embedAll: Bool = false) {
        self.maxFaces = maxFaces
        self.embedAll = embedAll
    }

    public static let runtime = AnalysisOptions()
}

@inline(__always) func millisNow() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1e6
}

/// YuNet -> quality gate -> similarity alignment -> crop luma and sharpness -> r50 -> L2 norm.
/// Enrollment and runtime run this same code path at the same detector scale (N6).
public final class FacePipeline: @unchecked Sendable {
    public let detector: FaceDetector
    public let aligner = FaceAligner()
    public let analyzer = CropAnalyzer()
    public let embedder: FaceEmbedder
    public let quality: QualityThresholds

    public init(models: ModelLocator = ModelLocator(), compute: ComputeChoice = .neuralEngine,
                quality: QualityThresholds = .standard) throws {
        detector = try FaceDetector(url: try models.url(.detector), compute: compute)
        embedder = try FaceEmbedder(url: try models.url(.recognizer), crop: aligner.crop, compute: compute)
        self.quality = quality
    }

    /// Camera path: a full BGRA frame (640x480 from the capture settings), scaled into the detector
    /// input. Any other aspect is centre-cropped to 4:3 first, never stretched, so faces keep the
    /// proportions they were enrolled with (N6).
    public func analyze(frame: vImage_Buffer, recognition: RecognitionContext?,
                        options: AnalysisOptions = .runtime) throws -> FrameAnalysis {
        let t0 = millisNow()
        let r = Self.detectorRegion(width: Int(frame.width), height: Int(frame.height))
        var region = frame
        region.data = frame.data.advanced(by: r.y * frame.rowBytes + r.x * 4)
        region.width = vImagePixelCount(r.width)
        region.height = vImagePixelCount(r.height)
        detector.scale(from: region)
        let scaleTime = millisNow() - t0
        let sx = Double(r.width) / FaceDetector.frameWidth, sy = Double(r.height) / FaceDetector.frameHeight
        let ox = Double(r.x), oy = Double(r.y)
        let a = try analyzePrepared(source: frame, toSource: { Point2D($0.x * sx + ox, $0.y * sy + oy) },
                                    recognition: recognition, options: options)
        var times = a.times
        times.detect += scaleTime
        return FrameAnalysis(observation: a.observation, detectedFaces: a.detectedFaces, times: times)
    }

    /// The largest centred 4:3 region of a `width` x `height` frame.
    public static func detectorRegion(width w: Int, height h: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        if w * 3 > h * 4 {
            let cw = h * 4 / 3
            return ((w - cw) / 2, 0, cw, h)
        }
        if w * 3 < h * 4 {
            let ch = w * 3 / 4
            return (0, (h - ch) / 2, w, ch)
        }
        return (0, 0, w, h)
    }

    /// The detector input is already filled. `toSource` maps detector output (640x480 frame pixels)
    /// to `source` pixels, the buffer the crop is warped from.
    public func analyzePrepared(source: vImage_Buffer, toSource: (Point2D) -> Point2D, recognition: RecognitionContext?,
                                options: AnalysisOptions = .runtime) throws -> FrameAnalysis {
        var times = StageTimes()
        let t0 = millisNow()
        let detected = try detector.detect()
        let faces = Array(detected.prefix(options.maxFaces))
        times.detect = millisNow() - t0
        let observed = try faces.map { try observe($0, source: source, toSource: toSource, recognition: recognition,
                                                   options: options, times: &times) }
        return FrameAnalysis(observation: FrameObservation(faces: observed), detectedFaces: detected.count, times: times)
    }

    private func observe(_ f: DetectedFace, source: vImage_Buffer, toSource: (Point2D) -> Point2D,
                         recognition: RecognitionContext?, options: AnalysisOptions,
                         times: inout StageTimes) throws -> FaceObservation {
        let m = QualityGate.metrics(f, frameWidth: FaceDetector.frameWidth, frameHeight: FaceDetector.frameHeight)
        var flags = QualityGate.geometryFlags(m, quality)
        guard flags.passes || options.embedAll else {
            return FaceObservation(face: f, metrics: m, quality: flags, score: nil, embedding: nil, faceLuma: nil, sharpness: nil)
        }
        let a0 = millisNow()
        aligner.align(f.landmarks.mapped(toSource), from: source)
        let a1 = millisNow()
        let crop = analyzer.analyze(aligner.crop)
        let a2 = millisNow()
        times.align += a1 - a0
        times.quality += a2 - a1
        flags.formUnion(QualityGate.cropFlags(faceLuma: crop.meanLuma, sharpness: crop.sharpness,
                                              sharpnessFloor: recognition?.sharpnessFloor, quality))
        guard flags.passes || options.embedAll else {
            return FaceObservation(face: f, metrics: m, quality: flags, score: nil, embedding: nil,
                                   faceLuma: crop.meanLuma, sharpness: crop.sharpness)
        }
        let embedding = try embedder.embed()
        times.embed += millisNow() - a2
        return FaceObservation(face: f, metrics: m, quality: flags, score: recognition?.gallery.score(embedding),
                               embedding: embedding, faceLuma: crop.meanLuma, sharpness: crop.sharpness)
    }
}
