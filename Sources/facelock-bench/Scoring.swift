import Accelerate
import FaceLockCore
import Foundation

/// Row-major n x 512 embeddings.
struct EmbeddingMatrix {
    let rows: Int
    let values: [Float]

    init(_ list: [[Float]]) {
        rows = list.count
        values = list.flatMap { $0 }
    }

    /// self (m x 512) times other^T (512 x n) -> m x n.
    func similarities(_ other: EmbeddingMatrix) -> [Float] {
        let d = embeddingSize
        var t = [Float](repeating: 0, count: other.values.count)
        vDSP_mtrans(other.values, 1, &t, 1, vDSP_Length(d), vDSP_Length(other.rows))
        var out = [Float](repeating: 0, count: rows * other.rows)
        vDSP_mmul(values, 1, t, 1, &out, 1, vDSP_Length(rows), vDSP_Length(other.rows), vDSP_Length(d))
        return out
    }
}

enum ScoreRule: String, CaseIterable {
    case top3, mean
}

/// Per-row aggregate of an m x n similarity block, skipping the diagonal when `leaveOneOut`.
func aggregate(_ s: [Float], rows m: Int, cols n: Int, rule: ScoreRule, leaveOneOut: Bool) -> [Float] {
    (0..<m).map { i in
        var vals: [Float] = []
        vals.reserveCapacity(n)
        for j in 0..<n where !(leaveOneOut && i == j) { vals.append(s[i * n + j]) }
        switch rule {
        case .top3: return Scorer.meanOfTop(vals) ?? .nan
        case .mean: return vals.isEmpty ? .nan : vals.reduce(0, +) / Float(vals.count)
        }
    }
}

struct ErrorMetrics {
    let genuine: [Double]
    let impostor: [Double]
    let floor: Double

    init(genuine g: [Float], impostor i: [Float], floor: Double) {
        genuine = g.map(Double.init).sorted()
        impostor = i.map(Double.init).sorted()
        self.floor = floor
    }

    /// score.py's EER: over every observed score, the threshold where FAR and FRR are closest.
    var eer: Double {
        let ts = Array(Set(genuine + impostor)).sorted()
        var best = (gap: Double.infinity, value: 0.0)
        for t in ts {
            let far = 1 - Double(Stats.lowerBound(impostor, t)) / Double(impostor.count)
            let frr = Double(Stats.lowerBound(genuine, t)) / Double(genuine.count)
            if abs(far - frr) < best.gap { best = (abs(far - frr), (far + frr) / 2) }
        }
        return best.value
    }

    var dprime: Double {
        abs(Stats.mean(genuine) - Stats.mean(impostor)) / ((Stats.variance(genuine) + Stats.variance(impostor)) / 2).squareRoot()
    }

    func frr(at t: Double) -> Double { Stats.fractionBelow(genuine, t) }
    func far(at t: Double) -> Double { 1 - Double(Stats.lowerBound(impostor, t)) / Double(impostor.count) }

    static let sweep = stride(from: 0.30, through: 0.601, by: 0.05).map { rounded($0, 2) }

    var json: [String: Any] {
        let imax = impostor.last ?? .nan
        let thr = imax + 1e-4
        return [
            "genuine_n": genuine.count, "impostor_n": impostor.count,
            "impostor_max": rounded(imax), "impostor_p99": rounded(Stats.quantileSorted(impostor, 0.99)),
            "impostor_p999": rounded(Stats.quantileSorted(impostor, 0.999)),
            "genuine_p1": rounded(Stats.quantileSorted(genuine, 0.01)), "genuine_p5": rounded(Stats.quantileSorted(genuine, 0.05)),
            "genuine_median": rounded(Stats.quantileSorted(genuine, 0.5)),
            "eer_pct": rounded(100 * eer), "dprime": rounded(dprime, 2),
            "frr_just_above_impostor_max_pct": rounded(100 * frr(at: thr)),
            "frr_at_floor_pct": rounded(100 * frr(at: floor)), "far_at_floor_pct": rounded(100 * far(at: floor)),
            "frr_sweep_pct": Dictionary(uniqueKeysWithValues: Self.sweep.map { (String(format: "%.2f", $0), rounded(100 * frr(at: $0))) }),
        ]
    }
}
