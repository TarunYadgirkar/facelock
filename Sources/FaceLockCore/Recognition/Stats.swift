import Foundation

public enum Stats {
    /// numpy.quantile's default (linear) method.
    public static func quantile(_ values: [Double], _ q: Double) -> Double {
        quantileSorted(values.sorted(), q)
    }

    public static func quantileSorted(_ s: [Double], _ q: Double) -> Double {
        guard !s.isEmpty else { return .nan }
        let pos = q * Double(s.count - 1)
        let lo = Int(pos.rounded(.down)), hi = min(lo + 1, s.count - 1)
        return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
    }

    public static func mean(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.reduce(0, +) / Double(v.count) }

    /// Population variance, as numpy's var().
    public static func variance(_ v: [Double]) -> Double {
        let m = mean(v)
        return v.isEmpty ? .nan : v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count)
    }

    public static func median(_ v: [Double]) -> Double { quantile(v, 0.5) }

    /// Fraction of `sorted` strictly below `t`.
    public static func fractionBelow(_ sorted: [Double], _ t: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        return Double(lowerBound(sorted, t)) / Double(sorted.count)
    }

    /// First index whose value is >= t.
    public static func lowerBound(_ sorted: [Double], _ t: Double) -> Int {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
