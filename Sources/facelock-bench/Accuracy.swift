import FaceLockCore
import FaceLockVision
import Foundation

/// One manifest image through the production pipeline, kept in memory only.
struct EmbeddedImage {
    let row: ManifestRow
    let embedding: [Float]?
    let faceCount: Int
    let quality: QualityFlags
    let sharpness: Double
}

enum Accuracy {
    static func embedAll(_ rows: [ManifestRow], root: URL, framer: LFWFramer) throws -> [EmbeddedImage] {
        try rows.map { row in
            try autoreleasepool {
                framer.prepare(try ImageFile.load(root.appendingPathComponent(row.path)))
                let a = try framer.analyze(recognition: nil, options: AnalysisOptions(maxFaces: 1, embedAll: true))
                let f = a.observation.faces.first
                return EmbeddedImage(row: row, embedding: f?.embedding, faceCount: a.detectedFaces,
                                     quality: f?.quality ?? [], sharpness: f?.sharpness ?? 0)
            }
        }
    }

    /// score.py: each stand-in owner enrolled with all of their images, genuine probes scored
    /// leave-one-out, the 4,000 strangers (minus the owner's own identity) against each enrollment.
    static func scores(_ images: [EmbeddedImage], rule: ScoreRule) -> (genuine: [Float], impostor: [Float]) {
        let ok = images.filter { $0.embedding != nil }
        var g: [Float] = [], i: [Float] = []
        for o in LFWManifest.owners {
            let own = EmbeddingMatrix(ok.filter { $0.row.isGenuine && $0.row.identity == o }.map { $0.embedding! })
            let imp = EmbeddingMatrix(ok.filter { !$0.row.isGenuine && $0.row.identity != o }.map { $0.embedding! })
            g += aggregate(own.similarities(own), rows: own.rows, cols: own.rows, rule: rule, leaveOneOut: true)
            i += aggregate(imp.similarities(own), rows: imp.rows, cols: own.rows, rule: rule, leaveOneOut: false)
        }
        return (g, i)
    }

    static func run(lfw: URL, models: ModelLocator, anchorsPerOwner: Int) throws -> [String: Any] {
        let manifest = try LFWManifest.build(lfwFunneled: lfw)
        guard manifest.matches else {
            throw BenchError("manifest sha256 \(manifest.sha256) does not match \(LFWManifest.expectedSHA256); is \(lfw.path) LFW funneled (figshare 5976015)?")
        }
        let framer = LFWFramer(pipeline: try FacePipeline(models: models))
        let t0 = Date()
        let images = try embedAll(manifest.rows, root: lfw.deletingLastPathComponent(), framer: framer)
        let elapsed = Date().timeIntervalSince(t0)

        let top3 = scores(images, rule: .top3)
        let strangerMax = Double(top3.impostor.max() ?? .nan)
        let floor = rounded(Double(ModelCalibration.floor(fromStrangerMax: strangerMax)), 2)
        var out: [String: Any] = [
            "manifest_sha256": manifest.sha256, "n_images": images.count,
            "no_face": images.filter { $0.embedding == nil }.count,
            "embed_seconds": rounded(elapsed, 1),
            "derived_floor_F": rounded(floor, 2), "committed_floor_F": rounded(Double(ModelCalibration.floor), 2),
            "floor_matches_committed": Float(floor) == ModelCalibration.floor,
        ]
        for rule in ScoreRule.allCases {
            let s = rule == .top3 ? top3 : scores(images, rule: rule)
            out[rule.rawValue] = ErrorMetrics(genuine: s.genuine, impostor: s.impostor, floor: floor).json
        }
        out["quality_gate"] = gateSummary(images)
        out["adaptation_replay"] = AdaptationReplay.run(images, floor: Float(floor), anchorsPerOwner: anchorsPerOwner)
        return out
    }

    /// How many manifest images the runtime gate would call unclear (the scores above embed every image, as N2 did).
    static func gateSummary(_ images: [EmbeddedImage]) -> [String: Any] {
        var flags: [String: Int] = [:]
        for img in images {
            for name in img.quality.names { flags[name, default: 0] += 1 }
        }
        return ["genuine_failing": images.filter { $0.row.isGenuine && !$0.quality.passes }.count,
                "impostor_failing": images.filter { !$0.row.isGenuine && !$0.quality.passes }.count,
                "multi_face_images": images.filter { $0.faceCount > 1 }.count, "flags": flags]
    }
}

/// Replays each stand-in owner's images in order with adaptation on, then scores the strangers
/// against the adapted gallery. Fails if any stranger reaches F - 0.05.
enum AdaptationReplay {
    static let spacing: TimeInterval = 7201

    static func run(_ images: [EmbeddedImage], floor: Float, anchorsPerOwner: Int) -> [String: Any] {
        let strangers = images.filter { !$0.row.isGenuine && $0.embedding != nil }
        var perOwner: [String: Any] = [:]
        var worst: Float = -1
        for o in LFWManifest.owners {
            let own = images.filter { $0.row.isGenuine && $0.row.identity == o && $0.embedding != nil }
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let anchors = own.prefix(anchorsPerOwner).enumerated().map { j, img in
                Template(embedding: img.embedding!, pool: .anchor, capturedAt: start.addingTimeInterval(Double(j) * 600),
                         session: j, target: "lfw", sharpness: Float(img.sharpness))
            }
            let report = Calibrator.calibrate(Gallery(anchors), floor: floor)
            let t = report.thresholds
            var gallery = Gallery(anchors)
            var rejected: [String: Int] = [:]
            for (j, img) in own.dropFirst(anchorsPerOwner).enumerated() {
                let now = start.addingTimeInterval(Double(anchorsPerOwner) * 600 + Double(j + 1) * spacing)
                gallery = Adaptation.expiring(gallery, now: now)
                guard let s = gallery.score(img.embedding!), img.quality.passes, VerdictRules.isOwner(s, t) else {
                    rejected["not_owner_frame", default: 0] += 1
                    continue
                }
                let c = AdaptationCandidate(embedding: img.embedding!, qualityPassed: true, faceCount: img.faceCount,
                                            anchorScore: s.anchor, sharpness: Float(img.sharpness))
                let ctx = AdaptationContext(threshold: t.accept, strangerOrUnclearSinceUnlock: false, secondsSinceInput: 5, now: now)
                if let r = Adaptation.evaluate(c, in: gallery, context: ctx) {
                    rejected[r.rawValue, default: 0] += 1
                } else {
                    gallery = Adaptation.adding(Adaptation.template(for: c, at: now, session: 0), to: gallery)
                }
            }
            let others = strangers.filter { $0.row.identity != o }
            let base = others.compactMap { Gallery(anchors).score($0.embedding!)?.union }.max() ?? .nan
            let adapted = others.compactMap { gallery.score($0.embedding!) }
            let adaptedMax = adapted.map(\.union).max() ?? .nan
            let accepted = adapted.filter { VerdictRules.isOwner($0, t) }.count
            worst = max(worst, adaptedMax)
            perOwner[o] = ["anchors": anchors.count, "adaptive": gallery.adaptive.count, "T": rounded(Double(t.accept)),
                           "stranger_max_anchors": rounded(Double(base)), "stranger_max_adapted": rounded(Double(adaptedMax)),
                           "strangers_accepted": accepted, "rejections": rejected]
        }
        let limit = floor - 0.05
        return ["per_owner": perOwner, "stranger_max_adapted": rounded(Double(worst)), "limit_F_minus_0.05": rounded(Double(limit)),
                "pass": worst <= limit, "spacing_seconds": spacing]
    }
}
