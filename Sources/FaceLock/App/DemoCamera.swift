import CoreGraphics
import CoreVideo
import FaceLockCapture
import FaceLockCore
import FaceLockVision
import Foundation

/// Small random moves of a stored photo: rotation, scale, shift, a horizontal shear that reads as
/// a slight head turn, and brightness. Deterministic for a given seed.
struct Jitter: Sendable {
    var rotation = 0.0
    var scale = 1.0
    var dx = 0.0
    var dy = 0.0
    var shear = 0.0
    var brightness = 1.0

    static func random(_ rng: inout SplitMix) -> Jitter {
        Jitter(rotation: rng.uniform(-0.14, 0.14), scale: rng.uniform(0.86, 1.18), dx: rng.uniform(-36, 36),
               dy: rng.uniform(-24, 24), shear: rng.uniform(-0.14, 0.14), brightness: rng.uniform(0.82, 1.12))
    }
}

struct SplitMix: Sendable {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * Double(next() >> 11) / Double(1 << 53)
    }
}

/// Renders a stored photo into 640x480 BGRA frames, the camera's format.
final class DemoRenderer: @unchecked Sendable {
    let image: CGImage
    private let buffer = BGRABuffer(width: 640, height: 480)

    init(url: URL) throws {
        image = try ImageFile.load(url)
    }

    /// nil `jitter` is the empty room.
    func render(_ jitter: Jitter?, into pb: CVPixelBuffer) -> CGImage? {
        buffer.fill(gray: 90)
        let ctx = buffer.context()
        if let j = jitter {
            let w = Double(buffer.width), h = Double(buffer.height)
            let s = min(w / Double(image.width), h / Double(image.height)) * j.scale
            let iw = Double(image.width) * s, ih = Double(image.height) * s
            ctx.saveGState()
            ctx.translateBy(x: w / 2 + j.dx, y: h / 2 + j.dy)
            ctx.rotate(by: j.rotation)
            ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: j.shear, d: 1, tx: 0, ty: 0))
            ctx.draw(image, in: CGRect(x: -iw / 2, y: -ih / 2, width: iw, height: ih))
            ctx.restoreGState()
            ctx.setFillColor(gray: j.brightness < 1 ? 0 : 1, alpha: abs(1 - j.brightness))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        PixelBuffers.copy(buffer, to: pb)
        return ctx.makeImage()
    }
}

/// Which way the demo scene is: the photo in front of the camera, or an empty room.
final class DemoScene: @unchecked Sendable {
    private let lock = NSLock()
    private var present = true
    private var observers: [@Sendable (Bool) -> Void] = []

    var isPresent: Bool { lock.withLock { present } }

    func set(present p: Bool) {
        let list = lock.withLock { () -> [@Sendable (Bool) -> Void] in
            present = p
            return observers
        }
        list.forEach { $0(p) }
    }

    func observe(_ f: @escaping @Sendable (Bool) -> Void) {
        lock.withLock { observers.append(f) }
    }
}

/// The setup screens' demo camera: a fresh jittered frame every 1/15 s, so enrollment sees new
/// angles of the stored photo.
final class JitterCamera: FrameSource, PreviewImageSource, @unchecked Sendable {
    static let fps = 15.0
    private let renderer: DemoRenderer
    private let scene: DemoScene
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var rng: SplitMix
    private var latest: CGImage?
    private let buffers = [PixelBuffers.makeBGRA(width: 640, height: 480), PixelBuffers.makeBGRA(width: 640, height: 480)]
    private var index = 0

    init(renderer: DemoRenderer, scene: DemoScene, seed: UInt64 = 7) {
        self.renderer = renderer
        self.scene = scene
        rng = SplitMix(state: seed)
    }

    var previewImage: CGImage? { lock.withLock { latest } }

    func start(queue: DispatchQueue, handler: @escaping @Sendable (CapturedFrame) -> Void) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1 / Self.fps, repeating: 1 / Self.fps, leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let pb = self.buffers[self.index % 2]
            self.index += 1
            let jitter = self.scene.isPresent ? Jitter.random(&self.rng) : nil
            let img = self.renderer.render(jitter, into: pb)
            self.lock.withLock { self.latest = img }
            handler(CapturedFrame(pixelBuffer: pb, time: uptimeSeconds(), exposureSettled: true))
        }
        timer = t
        t.activate()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

/// `--demo-enrolled`: an enrollment of the stored photo made the way onboarding makes one,
/// 9 targets of 6 jittered frames, 3 s apart so the block-out calibration has real neighbours.
enum DemoEnrollment {
    static func make(renderer: DemoRenderer, pipeline: FacePipeline, now: Date = Date()) -> [Template] {
        var rng = SplitMix(state: 42)
        let pb = PixelBuffers.makeBGRA(width: 640, height: 480)
        let start = now.addingTimeInterval(-600)
        var templates: [Template] = []
        var attempts = 0
        let targets = EnrollmentTarget.allCases
        while templates.count < targets.count * EnrollmentSession.framesPerTarget, attempts < 400 {
            attempts += 1
            _ = renderer.render(Jitter.random(&rng), into: pb)
            let face: FaceObservation? = PixelBuffers.withVImage(pb) { v in
                (try? pipeline.analyze(frame: v, recognition: nil))?.observation.faces.first
            }
            guard let face, face.quality.passes, let e = face.embedding,
                  !templates.contains(where: { Scorer.cosine(e, $0.vector) >= EnrollmentSession.noveltyCeiling }) else { continue }
            let i = templates.count
            templates.append(Template(embedding: e, pool: .anchor, capturedAt: start.addingTimeInterval(Double(i) * 3),
                                      session: 0, target: targets[i / EnrollmentSession.framesPerTarget].rawValue,
                                      sharpness: Float(face.sharpness ?? 0)))
        }
        return templates
    }
}
