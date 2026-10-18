import Foundation

public struct LookCloseness: Equatable, Sendable, Codable {
    public let target: String
    public let session: Int
    public let lowestScore: Float
}

public struct CalibrationReport: Equatable, Sendable, Codable {
    public let thresholds: Thresholds
    /// p2 of the block-out owner scores; nil when no template had an eligible comparison.
    public let ownerLow: Float?
    /// Block-out top-3 score of each template that had eligible comparisons.
    public let ownerScores: [Float]
    /// T fell to F: these looks score close to the stranger range.
    public let closeLooks: [LookCloseness]
    public let clampedToFloor: Bool
    public let clampedToCeiling: Bool
    public let singleSession: Bool
    public let someoneElseMax: Float?
    public let raisedForSomeoneElse: Bool
    public let computedAt: Date

    public var looksCloseToStrangers: Bool { clampedToFloor }
}

public struct ThresholdChange: Equatable, Sendable, Codable {
    public let at: Date
    public let reason: String
    public let old: Thresholds?
    public let new: Thresholds
}

public enum Calibrator {
    public static let ownerMargin: Float = 0.05
    public static let someoneElseMargin: Float = 0.05
    public static let blockOutSeconds: TimeInterval = 2
    public static let ownerLowQuantile = 0.02

    /// Each anchor scored top-3 against anchors from other targets or sessions only, never
    /// against one captured within 2 s of it or in the same target segment (no near-duplicates).
    public static func blockOutScores(_ anchors: [Template]) -> [(Template, Float)] {
        anchors.compactMap { t in
            let e = t.embedding
            let others = anchors.filter { o in
                o.id != t.id && !(o.session == t.session && o.target == t.target)
                    && abs(o.capturedAt.timeIntervalSince(t.capturedAt)) > blockOutSeconds
            }
            let cos = others.map { Scorer.cosine(e, $0.vector) }
            return Scorer.meanOfTop(cos).map { (t, $0) }
        }
    }

    public static func calibrate(_ gallery: Gallery, floor: Float = ModelCalibration.floor,
                                 stranger: Float = ModelCalibration.strangerScore,
                                 ceiling: Float = ModelCalibration.ceiling, now: Date = Date()) -> CalibrationReport {
        let scored = blockOutScores(gallery.anchors)
        let scores = scored.map(\.1)
        let low = scores.isEmpty ? nil : Float(Stats.quantile(scores.map(Double.init), ownerLowQuantile))
        let raw = (low ?? floor) - ownerMargin
        let accept = min(max(raw, floor), ceiling)
        let toFloor = low == nil || raw < floor
        let close = toFloor ? closeLooks(scored, floor: floor) : []
        return CalibrationReport(
            thresholds: Thresholds(accept: accept, floor: floor, stranger: stranger, ceiling: ceiling),
            ownerLow: low, ownerScores: scores, closeLooks: close, clampedToFloor: toFloor,
            clampedToCeiling: raw > ceiling, singleSession: gallery.sessionCount <= 1, someoneElseMax: nil,
            raisedForSomeoneElse: false, computedAt: now)
    }

    /// Looks whose own score leaves less than the owner margin above F.
    static func closeLooks(_ scored: [(Template, Float)], floor: Float) -> [LookCloseness] {
        let near = scored.filter { $0.1 - ownerMargin < floor }
        let grouped = Dictionary(grouping: near) { "\($0.0.session)/\($0.0.target)" }
        return grouped.values.compactMap { group in
            group.min { $0.1 < $1.1 }.map { LookCloseness(target: $0.0.target, session: $0.0.session, lowestScore: $0.1) }
        }.sorted { $0.lowestScore < $1.lowestScore }
    }

    /// "Check with someone else": a second person's best score against the owner's gallery. If it
    /// comes within 0.05 of T, T rises to that score + 0.05, capped at C.
    public static func adjusting(_ report: CalibrationReport, someoneElseMax other: Float) -> CalibrationReport {
        let t = report.thresholds
        let raise = other >= t.accept - someoneElseMargin
        let accept = raise ? min(other + someoneElseMargin, t.ceiling) : t.accept
        return CalibrationReport(
            thresholds: Thresholds(accept: max(accept, t.accept), floor: t.floor, stranger: t.stranger, ceiling: t.ceiling),
            ownerLow: report.ownerLow, ownerScores: report.ownerScores, closeLooks: report.closeLooks,
            clampedToFloor: report.clampedToFloor, clampedToCeiling: report.clampedToCeiling || (raise && accept >= t.ceiling),
            singleSession: report.singleSession, someoneElseMax: other, raisedForSomeoneElse: raise && accept > t.accept,
            computedAt: report.computedAt)
    }

    public static func change(from old: Thresholds?, to report: CalibrationReport, reason: String) -> ThresholdChange {
        ThresholdChange(at: report.computedAt, reason: reason, old: old, new: report.thresholds)
    }

    /// Plain wording for the calibration result screen.
    public static func headline(_ r: CalibrationReport) -> String {
        if r.ownerLow == nil { return "Not enough looks to calibrate yet." }
        if r.clampedToFloor {
            let n = r.closeLooks.count
            return n == 1 ? "1 look scores close to strangers. Teach it later."
                : "\(n) looks score close to strangers. Teach them later."
        }
        return "Your looks pass with room to spare."
    }
}
