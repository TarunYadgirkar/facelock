import FaceLockCore
import FaceLockSystem
import FaceLockVision
import Foundation

/// Reads the local enrollment in memory and prints aggregates only: counts, thresholds and
/// score quantiles. No template, embedding or image leaves memory. Never commit its output.
enum OwnerReport {
    static var repoRoot: URL { ModelLocator.repoModels.deletingLastPathComponent().resolvingSymlinksInPath() }

    static func refuseRepoPath(_ out: URL) throws {
        let target = out.standardizedFileURL.resolvingSymlinksInPath().path
        let dir = out.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        let root = repoRoot.path
        if target.hasPrefix(root + "/") || dir == root || dir.hasPrefix(root + "/") {
            throw BenchError("refusing to write the owner report inside the repo (\(root)); choose a path outside it")
        }
    }

    static func run(out: URL?) throws {
        if let out { try refuseRepoPath(out) }
        let store = EnrollmentStore(keys: KeychainKeyStore(interactive: false))
        let report: [String: Any]
        switch store.load() {
        case .empty:
            report = ["enrollment": "none", "path": store.url.path,
                      "note": "No enrollment.v2 yet; onboarding in the app creates it. The 0.4 enrollment (mbf) cannot serve r50."]
        case let .needsReenroll(reason):
            report = ["enrollment": "unreadable", "reason": reason.rawValue]
        case let .loaded(p):
            report = aggregates(p)
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let out {
            try SecureFile.write(data, to: out)
        } else {
            print(String(decoding: data, as: UTF8.self))
        }
    }

    static func aggregates(_ p: EnrollmentPayload) -> [String: Any] {
        let g = p.gallery
        let cal = Calibrator.calibrate(g, floor: p.thresholds.floor, stranger: p.thresholds.stranger, ceiling: p.thresholds.ceiling)
        let scores = cal.ownerScores.map(Double.init)
        func q(_ x: Double) -> Double { scores.isEmpty ? .nan : rounded(Stats.quantile(scores, x)) }
        return [
            "templates": ["anchor": g.anchors.count, "adaptive": g.adaptive.count, "sessions": g.sessionCount,
                          "targets": Dictionary(grouping: g.anchors.map(\.target)) { $0 }.mapValues(\.count)],
            "thresholds": ["T": Double(p.thresholds.accept), "F": Double(p.thresholds.floor), "S": Double(p.thresholds.stranger),
                           "C": Double(p.thresholds.ceiling)],
            "block_out_owner_scores": ["n": scores.count, "p2": q(0.02), "p5": q(0.05), "median": q(0.5)],
            "recalibrated_T": Double(cal.thresholds.accept), "looks_close_to_strangers": cal.closeLooks.count,
            "single_session": cal.singleSession, "threshold_changes": p.thresholdLog.count, "model": p.modelID,
        ]
    }
}
