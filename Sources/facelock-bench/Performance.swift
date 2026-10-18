import FaceLockCore
import FaceLockVision
import Foundation

/// An owner enrolled from one stored frame (grace_hopper by default), for runtime-path runs.
struct StandInOwner {
    let recognition: RecognitionContext

    init(pipeline: FacePipeline, frame: BGRABuffer, anchors: Int = 54) throws {
        let a = try pipeline.analyze(frame: frame.vImage, recognition: nil, options: AnalysisOptions(maxFaces: 1, embedAll: true))
        guard let face = a.observation.faces.first, let e = face.embedding else { throw BenchError("no face in the stored frame") }
        let start = Date()
        let templates = (0..<anchors).map { i in
            Template(embedding: e, pool: .anchor, capturedAt: start.addingTimeInterval(Double(i)), session: 0,
                     target: "centre", sharpness: Float(face.sharpness ?? 0))
        }
        recognition = RecognitionContext(gallery: Gallery(templates), thresholds: .uncalibrated)
    }
}

enum Latency {
    static func run(image: URL, lfw: URL?, models: ModelLocator, frames: Int, manifestImages: Int, reps: Int) throws -> [String: Any] {
        let pipeline = try FacePipeline(models: models)
        let frame = try cameraFrame(image)
        let owner = try StandInOwner(pipeline: pipeline, frame: frame)
        var out: [String: Any] = ["runtime_frame": try runtimeFrame(pipeline, frame, owner.recognition, frames: frames)]
        if let lfw {
            out["manifest"] = try manifest(pipeline, lfw: lfw, images: manifestImages, reps: reps)
        }
        out["footprint_mb"] = rounded(Usage.now().footprintMB, 1)
        out["peak_footprint_mb"] = rounded(Usage.now().peakFootprintMB, 1)
        return out
    }

    /// The camera path on one stored 640x480 frame: vImageScale, detect, align, crop checks, embed, score.
    static func runtimeFrame(_ p: FacePipeline, _ frame: BGRABuffer, _ r: RecognitionContext, frames: Int) throws -> [String: Any] {
        for _ in 0..<10 { _ = try autoreleasepool { try p.analyze(frame: frame.vImage, recognition: r) } }
        var times: [StageTimes] = []
        let u0 = Usage.now()
        for _ in 0..<frames {
            times.append(try autoreleasepool { try p.analyze(frame: frame.vImage, recognition: r).times })
        }
        let d = Usage.now().since(u0)
        return stageJSON(times).merging([
            "frames": frames, "cpu_ms_per_frame": rounded(d.cpuMs / Double(frames), 3),
            "cpu_energy_mj_per_frame": rounded(d.energyMJ / Double(frames), 3),
        ]) { a, _ in a }
    }

    /// N2's method on the LFW manifest: time each stage, and take CPU time and energy net of a
    /// prep-only pass (JPEG decode and framing) over the same images.
    static func manifest(_ p: FacePipeline, lfw: URL, images n: Int, reps: Int) throws -> [String: Any] {
        let rows = Array(try LFWManifest.build(lfwFunneled: lfw).rows.prefix(n))
        let root = lfw.deletingLastPathComponent()
        let framer = LFWFramer(pipeline: p)
        func pass(analyze: Bool) throws -> ([StageTimes], cpu: Double, energy: Double) {
            var times: [StageTimes] = []
            let u0 = Usage.now()
            for _ in 0..<reps {
                for row in rows {
                    try autoreleasepool {
                        framer.prepare(try ImageFile.load(root.appendingPathComponent(row.path)))
                        if analyze { times.append(try framer.analyze(recognition: nil, options: AnalysisOptions(maxFaces: 1)).times) }
                    }
                }
            }
            let d = Usage.now().since(u0)
            return (times, d.cpuMs, d.energyMJ)
        }
        _ = try pass(analyze: true)
        let prep = try pass(analyze: false)
        let full = try pass(analyze: true)
        let count = Double(rows.count * reps)
        return stageJSON(full.0).merging([
            "images": rows.count, "reps": reps,
            "cpu_ms_per_frame_net": rounded((full.cpu - prep.cpu) / count, 3),
            "cpu_energy_mj_per_frame_net": rounded((full.energy - prep.energy) / count, 3),
            "prep_cpu_ms_per_image": rounded(prep.cpu / count, 3),
        ]) { a, _ in a }
    }

    static func stageJSON(_ t: [StageTimes]) -> [String: Any] {
        func s(_ xs: [Double]) -> [String: Double] { summary(xs).mapValues { rounded($0, 3) } }
        return ["total_ms": s(t.map(\.total)), "detect_ms": s(t.map(\.detect)), "align_ms": s(t.map(\.align)),
                "quality_ms": s(t.map(\.quality)), "embed_ms": s(t.map(\.embed))]
    }
}

/// A resident process looking again after idling (N4): 3 frames per look.
enum Burst {
    static func run(image: URL, models: ModelLocator, idle: Double, bursts: Int) throws -> [String: Any] {
        let p = try FacePipeline(models: models)
        let frame = try cameraFrame(image)
        let owner = try StandInOwner(pipeline: p, frame: frame)
        func look() throws -> [Double] {
            try (0..<3).map { _ in
                try autoreleasepool {
                    let t0 = Usage.now().wallMs
                    _ = try p.analyze(frame: frame.vImage, recognition: owner.recognition)
                    return Usage.now().wallMs - t0
                }
            }
        }
        _ = try look()
        _ = try look()
        var rows: [[String: Any]] = []
        for _ in 0..<bursts {
            Thread.sleep(forTimeInterval: idle)
            let u0 = Usage.now()
            let t = try look()
            let d = Usage.now().since(u0)
            rows.append(["frames_ms": t.map { rounded($0, 2) }, "look_cpu_ms": rounded(d.cpuMs, 2),
                         "look_cpu_energy_mj": rounded(d.energyMJ, 2)])
        }
        let first = rows.compactMap { ($0["frames_ms"] as? [Double])?.first }
        let later = rows.flatMap { ($0["frames_ms"] as? [Double])?.dropFirst() ?? [] }
        return ["idle_seconds": idle, "bursts": rows, "first_frame_ms": summary(first).mapValues { rounded($0, 2) },
                "later_frames_ms": summary(later).mapValues { rounded($0, 2) },
                "look_cpu_ms": summary(rows.compactMap { $0["look_cpu_ms"] as? Double }).mapValues { rounded($0, 2) },
                "look_cpu_energy_mj": summary(rows.compactMap { $0["look_cpu_energy_mj"] as? Double }).mapValues { rounded($0, 2) },
                "footprint_mb": rounded(Usage.now().footprintMB, 1)]
    }
}

/// Launch to first decision, camera excluded: a fresh process loads both (cached) models,
/// analyses one stored frame and decides against a 120-template gallery.
enum Cold {
    static func run(image: URL, models: ModelLocator, runs: Int) throws -> [String: Any] {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var rows: [[String: Any]] = []
        for _ in 0..<runs {
            let p = Process()
            p.executableURL = exe
            p.arguments = ["cold-child", "--image", image.path] + (models.directories.first.map { ["--models", $0.path] } ?? [])
            let pipe = Pipe()
            p.standardOutput = pipe
            let t0 = Usage.now().wallMs
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let wall = Usage.now().wallMs - t0
            var row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            row["wall_ms"] = rounded(wall, 1)
            rows.append(row)
        }
        let walls = rows.compactMap { $0["wall_ms"] as? Double }
        return ["runs": rows, "wall_ms": summary(walls).mapValues { rounded($0, 1) }]
    }

    static func child(image: URL, models: ModelLocator) throws {
        let t0 = Usage.now()
        let p = try FacePipeline(models: models)
        let loaded = Usage.now()
        let frame = try cameraFrame(image)
        var rng = SystemRandomNumberGenerator()
        let gallery = Gallery((0..<120).map { i in
            Template(embedding: Scorer.normalized((0..<embeddingSize).map { _ in Float.random(in: -1...1, using: &rng) }),
                     pool: .anchor, capturedAt: Date(), session: i % 2, target: "centre", sharpness: 100)
        })
        let r = RecognitionContext(gallery: gallery, thresholds: .uncalibrated)
        let a = try p.analyze(frame: frame.vImage, recognition: r)
        let verdict = VerdictRules.classify(a.observation, r.thresholds).verdict
        let end = Usage.now()
        printJSON(["decision": verdict.rawValue, "model_load_ms": rounded(loaded.wallMs - t0.wallMs, 1),
                   "in_process_ms": rounded(end.wallMs - t0.wallMs, 1), "cpu_ms": rounded(end.cpuMs, 1),
                   "peak_footprint_mb": rounded(end.peakFootprintMB, 1), "footprint_mb": rounded(end.footprintMB, 1)])
    }
}
