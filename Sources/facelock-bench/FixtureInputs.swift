import CoreVideo
import FaceLockCore
import FaceLockVision
import Foundation

/// Dumps what tools/make_fixtures.py needs to record independent references (OpenCV YuNet on
/// the same detector input, ONNX Runtime r50 on the same crop) for the public-domain fixture.
/// Writes raw buffers to a directory outside the repo.
enum FixtureInputs {
    static func run(image: URL, models: ModelLocator, out: URL) throws {
        try OwnerReport.refuseRepoPath(out.appendingPathComponent("x"))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let p = try FacePipeline(models: models)
        let frame = try cameraFrame(image)
        let a = try frame.withVImage { try p.analyze(frame: $0, recognition: nil, options: AnalysisOptions(maxFaces: 1, embedAll: true)) }
        guard let f = a.observation.faces.first else { throw BenchError("no face in \(image.path)") }
        try p.detector.withInput { v in
            let rows = (0..<Int(v.height)).map { Data(bytes: v.data + $0 * v.rowBytes, count: Int(v.width) * 4) }
            try rows.reduce(Data(), +).write(to: out.appendingPathComponent("detector_320x240.bgra"))
        }
        try PixelBuffers.withVImage(p.aligner.crop) { v in
            let rows = (0..<112).map { Data(bytes: v.data + $0 * v.rowBytes, count: 112 * 4) }
            try rows.reduce(Data(), +).write(to: out.appendingPathComponent("crop_112.bgra"))
        }
        printJSON(["landmarks": f.face.landmarks.points.map { [$0.x, $0.y] }, "score": f.face.score,
                   "box": [f.face.box.x, f.face.box.y, f.face.box.width, f.face.box.height], "dir": out.path])
    }
}
