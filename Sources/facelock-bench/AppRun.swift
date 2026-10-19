import Darwin
import FaceLockCore
import Foundation

/// The shipping app, measured from outside: launches FaceLock.app on the demo camera (never the
/// real camera, never a lock), samples proc_pid_rusage every half second, and lines the samples up
/// with the app's own check log to split the cost of a check from the cost of waiting between checks.
enum AppRun {
    static let sampleEvery = 0.5
    /// A check's CPU lands from its camera start to this long after its log line (state, menu, log write).
    static let checkTail = 1.0

    struct Sample {
        let t: Double
        let userMs: Double
        let systemMs: Double
        let energyMJ: Double
        let footprintMB: Double
        let residentMB: Double
        let pageins: UInt64
    }

    static func run(app: URL, image: URL, seconds: Double, warmup: Double) async throws -> [String: Any] {
        let exe = app.appendingPathComponent("Contents/MacOS/FaceLock")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else { throw BenchError("no app at \(app.path); run scripts/build-app.sh") }
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("facelock-bench-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: data) }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--demo-camera", image.path, "--demo-enrolled", "--data-dir", data.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let loadBefore = loadAverage()
        try p.run()
        defer { if p.isRunning { p.terminate() } }
        try await Task.sleep(for: .seconds(warmup))
        guard p.isRunning else { throw BenchError("FaceLock exited during warmup") }
        let start = Date()
        var samples: [Sample] = []
        let clock0 = Date()
        while Date().timeIntervalSince(clock0) <= seconds {
            samples.append(sample(pid: p.processIdentifier, t: Date().timeIntervalSince(start)))
            try await Task.sleep(for: .seconds(sampleEvery))
        }
        let end = Date()
        p.terminate()
        p.waitUntilExit()
        let checks = TelemetryLog(url: data.appendingPathComponent("checks.jsonl")).records(since: start)
            .filter { $0.event == .check && $0.at <= end }
        return summarize(samples, checks: checks, start: start, seconds: end.timeIntervalSince(start),
                         load: ["before": loadBefore, "after": loadAverage()])
    }

    static func sample(pid: pid_t, t: Double) -> Sample {
        var r = rusage_info_v6()
        _ = withUnsafeMutablePointer(to: &r) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let ms = { (ticks: UInt64) in Double(ticks) * Double(tb.numer) / Double(tb.denom) / 1e6 }
        return Sample(t: t, userMs: ms(r.ri_user_time), systemMs: ms(r.ri_system_time), energyMJ: Double(r.ri_energy_nj) / 1e6,
                      footprintMB: Double(r.ri_phys_footprint) / 1_048_576, residentMB: Double(r.ri_resident_size) / 1_048_576,
                      pageins: r.ri_pageins)
    }

    static func summarize(_ s: [Sample], checks: [CheckRecord], start: Date, seconds: Double, load: [String: String]) -> [String: Any] {
        guard let first = s.first, let last = s.last, s.count > 2 else { return ["error": "too few samples"] }
        // Each check's busy span on the run's clock: camera on through the tail after its log line.
        let spans = checks.map { c -> ClosedRange<Double> in
            let end = c.at.timeIntervalSince(start)
            return (end - (c.onTime ?? 0) - 0.1)...(end + checkTail)
        }
        var quietCpu = 0.0, quietEnergy = 0.0, quietTime = 0.0
        for (a, b) in zip(s, s.dropFirst()) where !spans.contains(where: { $0.overlaps(a.t...b.t) }) {
            quietCpu += (b.userMs + b.systemMs) - (a.userMs + a.systemMs)
            quietEnergy += b.energyMJ - a.energyMJ
            quietTime += b.t - a.t
        }
        let span = last.t - first.t
        let cpu = (last.userMs + last.systemMs) - (first.userMs + first.systemMs)
        let user = last.userMs - first.userMs
        let energy = last.energyMJ - first.energyMJ
        let quietRate = quietTime > 0 ? quietCpu / quietTime : 0
        let quietEnergyRate = quietTime > 0 ? quietEnergy / quietTime : 0
        let n = Double(max(1, checks.count))
        let perCheckCpu = (cpu - quietRate * span) / n
        let perCheckEnergy = (energy - quietEnergyRate * span) / n
        let quietUserRate = quietTime > 0 ? zip(s, s.dropFirst()).filter { a, b in !spans.contains { $0.overlaps(a.t...b.t) } }
            .reduce(0.0) { $0 + ($1.1.userMs - $1.0.userMs) } / quietTime : 0
        func stats(_ xs: [Double]) -> [String: Double] { summary(xs).mapValues { rounded($0, 1) } }
        return [
            "seconds": rounded(span, 1), "checks": checks.count,
            "verdicts": Dictionary(grouping: checks.compactMap { $0.verdict?.rawValue }) { $0 }.mapValues(\.count),
            "cpu_percent_of_core": rounded(100 * cpu / (span * 1000), 4),
            "cpu_j_per_hour": rounded(energy / 1000 * 3600 / span, 2),
            "between_checks_cpu_percent_of_core": rounded(100 * quietRate / 1000, 4),
            "per_check_cpu_ms": rounded(perCheckCpu, 1),
            "per_check_user_ms": rounded((user - quietUserRate * span) / n, 1),
            "per_check_cpu_energy_mj": rounded(perCheckEnergy, 1),
            "frames_per_check": stats(checks.compactMap { $0.frames.map(Double.init) }),
            "footprint_mb": stats(s.map(\.footprintMB)), "resident_mb": stats(s.map(\.residentMB)),
            "pageins": Int(last.pageins - first.pageins),
            "load_average": load,
        ]
    }

    static func loadAverage() -> String {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) == 3 ? l.map { String(format: "%.2f", $0) }.joined(separator: " ") : "unknown"
    }
}
