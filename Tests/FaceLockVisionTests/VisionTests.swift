import Accelerate
import CoreGraphics
import CoreVideo
import FaceLockCapture
import FaceLockCore
import FaceLockVision
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

enum Fixtures {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    static let grace = dir.appendingPathComponent("grace_hopper.jpg")
    static let modelsPresent = ModelLocator().isAvailable

    struct Reference: Decodable {
        struct Detector: Decodable {
            let score: Double
            let landmarks: [[Double]]
        }
        let detector: Detector
    }

    static func reference() throws -> Reference {
        try JSONDecoder().decode(Reference.self, from: Data(contentsOf: dir.appendingPathComponent("grace_hopper_reference.json")))
    }

    static func r50Reference() throws -> [Float] {
        let d = try Data(contentsOf: dir.appendingPathComponent("grace_hopper_r50.f16"))
        return d.withUnsafeBytes { raw in (0..<embeddingSize).map { Float(raw.loadUnaligned(fromByteOffset: $0 * 2, as: Float16.self)) } }
    }

    static func frame(_ url: URL = grace) throws -> BGRABuffer {
        let b = BGRABuffer(width: 640, height: 480)
        ImageFile.render(try ImageFile.load(url), into: b)
        return b
    }

    static func blankImage() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("facelock-blank-\(UUID().uuidString).png")
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 256,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return url
    }
}

func cosine(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

func lanczos3(_ x: Double) -> Double {
    if x == 0 { return 1 }
    if abs(x) >= 3 { return 0 }
    let px = Double.pi * x
    return 3 * sin(px) * sin(px / 3) / (px * px)
}

/// The reference crop: the inverse similarity sampled with a plain Lanczos3 kernel (vImage's
/// geometry resampling is Lanczos-type), pixel centres on integers as in OpenCV, border 0.
func referenceCrop(_ frame: BGRABuffer, _ m: SimilarityTransform) -> [UInt8] {
    let n = m.a * m.a + m.b * m.b, size = ArcFaceTemplate.cropSize
    let widen = max(1, 1 / m.scale), r = 3 * widen
    var out = [UInt8](repeating: 0, count: size * size * 4)
    let p = frame.bytes
    for y in 0..<size {
        for x in 0..<size {
            let dx = Double(x) - m.tx, dy = Double(y) - m.ty
            let sx = (m.a * dx + m.b * dy) / n, sy = (-m.b * dx + m.a * dy) / n
            var acc = [0.0, 0.0, 0.0], wsum = 0.0
            for yy in Int((sy - r).rounded(.up))...Int((sy + r).rounded(.down)) {
                let wy = lanczos3((Double(yy) - sy) / widen)
                for xx in Int((sx - r).rounded(.up))...Int((sx + r).rounded(.down)) {
                    let w = wy * lanczos3((Double(xx) - sx) / widen)
                    wsum += w
                    guard xx >= 0, yy >= 0, xx < frame.width, yy < frame.height else { continue }
                    for c in 0..<3 { acc[c] += w * Double(p[yy * frame.rowBytes + xx * 4 + c]) }
                }
            }
            for c in 0..<3 { out[(y * size + x) * 4 + c] = UInt8(max(0, min(255, (acc[c] / wsum).rounded()))) }
        }
    }
    return out
}

@Suite("Vision (needs models/; run tools/convert_models.py)", .serialized, .enabled(if: Fixtures.modelsPresent, "models/ is absent; run tools/convert_models.py"))
struct VisionTests {
    @Test("grace_hopper: one face, score at least 0.9, landmarks within 1 px of OpenCV's")
    func detection() throws {
        let p = try FacePipeline()
        let a = try Fixtures.frame().withVImage { try p.analyze(frame: $0, recognition: nil, options: AnalysisOptions(embedAll: true)) }
        #expect(a.detectedFaces == 1)
        let face = try #require(a.observation.faces.first).face
        #expect(face.score >= 0.9)
        let ref = try Fixtures.reference().detector
        for (got, want) in zip(face.landmarks.points, ref.landmarks) {
            #expect(got.distance(to: Point2D(want[0], want[1])) <= 1.0)
        }
        #expect(a.observation.faces[0].quality.passes)
    }

    /// The face drawn at about 1 m (inter-ocular ~36 px), where the warp scale is near 1, as in the
    /// LFW probe. Against OpenCV's bilinear warpAffine this detailed photo differs by about 2.6
    /// (the probe measured 0.8-0.9 on LFW); a 0.25 px geometry error alone adds about 3.
    @Test("vImage crop matches the reference warp at identical landmarks (mean abs diff < 1.5)")
    func crop() throws {
        let p = try FacePipeline()
        let frame = BGRABuffer(width: 640, height: 480)
        frame.fill(gray: 90)
        let img = try ImageFile.load(Fixtures.grace)
        let w = Double(img.width) * 0.48, h = Double(img.height) * 0.48
        frame.context().draw(img, in: CGRect(x: (640 - w) / 2, y: (480 - h) / 2, width: w, height: h))
        let a = try frame.withVImage { try p.analyze(frame: $0, recognition: nil, options: AnalysisOptions(embedAll: true)) }
        let lm = try #require(a.observation.faces.first).face.landmarks
        let m = try #require(SimilarityTransform.toArcFace(lm))
        #expect(m.scale > 0.85 && m.scale < 1.15)
        let ref = referenceCrop(frame, m)
        let got: [UInt8] = PixelBuffers.withVImage(p.aligner.crop) { v in
            let q = v.data.assumingMemoryBound(to: UInt8.self)
            return (0..<112).flatMap { y in (0..<448).map { q[y * v.rowBytes + $0] } }
        }
        var sum = 0.0, n = 0
        for i in 0..<got.count where i % 4 != 3 {
            sum += abs(Double(got[i]) - Double(ref[i]))
            n += 1
        }
        #expect(sum / Double(n) < 1.5, "mean abs diff \(sum / Double(n))")
    }

    @Test("r50 on the Neural Engine agrees with the CPU and with the ONNX Runtime fixture (cosine >= 0.999)")
    func embedding() throws {
        let frame = try Fixtures.frame()
        func embed(_ c: ComputeChoice) throws -> [Float] {
            let p = try FacePipeline(compute: c)
            let a = try frame.withVImage { try p.analyze(frame: $0, recognition: nil, options: AnalysisOptions(maxFaces: 1, embedAll: true)) }
            return try #require(a.observation.faces.first?.embedding)
        }
        let ane = try embed(.neuralEngine), cpu = try embed(.cpu)
        #expect(cosine(ane, cpu) >= 0.999)
        #expect(cosine(ane, try Fixtures.r50Reference()) >= 0.999)
    }

    @Test("compute plan: YuNet entirely on the Neural Engine, r50 at least 95%")
    func computePlans() async throws {
        let m = ModelLocator()
        let yunet = try await computePlan(try m.url(.detector))
        #expect(yunet.neuralEngineOpShare == 1)
        let r50 = try await computePlan(try m.url(.recognizer))
        #expect(r50.neuralEngineOpShare >= 0.95)
        #expect(r50.neuralEngineCostShare >= 0.95)
    }

    @Test("Vision capture quality is available for enrollment")
    func captureQuality() throws {
        let frame = try Fixtures.frame()
        let pb = PixelBuffers.makeBGRA(width: 640, height: 480)
        PixelBuffers.copy(frame, to: pb)
        let q = try #require(EnrollmentQuality.captureQuality(pb))
        #expect(q > 0 && q <= 1)
    }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T?
    func set(_ x: T) { lock.withLock { v = x } }
    var value: T? { lock.withLock { v } }
}

@Suite("Check windows on the stored-image camera", .serialized, .enabled(if: Fixtures.modelsPresent, "models/ is absent; run tools/convert_models.py"))
struct CheckRunnerTests {
    func runWindow(image: URL, gallery: (FacePipeline) throws -> Gallery, policy: WindowPolicy = .regular) async throws -> WindowSummary {
        let p = try FacePipeline()
        let runner = CheckRunner(source: try StoredImageCamera(image: image), pipeline: p)
        let r = RecognitionContext(gallery: try gallery(p), thresholds: Thresholds(accept: 0.5))
        let out = Box<WindowSummary>()
        runner.startWindow(id: 1, kind: .regular, policy: policy, recognition: r) { _, s in out.set(s) }
        for _ in 0..<60 where out.value == nil { try await Task.sleep(for: .milliseconds(50)) }
        return try #require(out.value)
    }

    func ownerGallery(_ p: FacePipeline) throws -> Gallery {
        let a = try Fixtures.frame().withVImage { try p.analyze(frame: $0, recognition: nil, options: AnalysisOptions(embedAll: true)) }
        let e = try #require(a.observation.faces.first?.embedding)
        return Gallery((0..<3).map { _ in Template(embedding: e, pool: .anchor, capturedAt: Date(), session: 0, target: "centre", sharpness: 1) })
    }

    @Test("the owner is accepted on the first frame and the camera stops at once")
    func earlyAccept() async throws {
        let s = try await runWindow(image: Fixtures.grace, gallery: ownerGallery)
        #expect(s.verdict == .owner)
        #expect(s.frames == 1)
        #expect(s.timing.cameraOn < 0.3)
        #expect(s.owner != nil)
    }

    @Test("someone not enrolled fills the window with stranger frames")
    func stranger() async throws {
        let s = try await runWindow(image: Fixtures.grace) { _ in
            Gallery((0..<3).map { i in
                Template(embedding: Scorer.normalized((0..<embeddingSize).map { Float(sin(Double($0 * (i + 3)))) }), pool: .anchor,
                         capturedAt: Date(), session: 0, target: "centre", sharpness: 1)
            })
        }
        #expect(s.verdict == .stranger)
        #expect(s.frames == 6)
    }

    @Test("an empty scene is away after the frame cap")
    func away() async throws {
        let s = try await runWindow(image: try Fixtures.blankImage(), gallery: ownerGallery)
        #expect(s.verdict == .away)
        #expect(s.frames == 6)
        #expect(s.maxFaceCount == 0)
    }
}
