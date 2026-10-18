import Darwin
import Foundation

/// Process CPU time, CPU energy (ri_energy_nj) and memory from proc_pid_rusage.
struct Usage {
    let cpuMs: Double
    let energyMJ: Double
    let footprintMB: Double
    let peakFootprintMB: Double
    let wallMs: Double

    static func now(pid: pid_t = getpid()) -> Usage {
        var r = rusage_info_v6()
        _ = withUnsafeMutablePointer(to: &r) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let ticks = Double(r.ri_user_time + r.ri_system_time) * Double(tb.numer) / Double(tb.denom)
        return Usage(cpuMs: ticks / 1e6, energyMJ: Double(r.ri_energy_nj) / 1e6,
                     footprintMB: Double(r.ri_phys_footprint) / 1_048_576,
                     peakFootprintMB: Double(r.ri_lifetime_max_phys_footprint) / 1_048_576,
                     wallMs: Double(DispatchTime.now().uptimeNanoseconds) / 1e6)
    }

    func since(_ start: Usage) -> (cpuMs: Double, energyMJ: Double, wallMs: Double) {
        (cpuMs - start.cpuMs, energyMJ - start.energyMJ, wallMs - start.wallMs)
    }
}

func summary(_ xs: [Double]) -> [String: Double] {
    guard !xs.isEmpty else { return [:] }
    let s = xs.sorted()
    return ["mean": s.reduce(0, +) / Double(s.count), "p50": s[s.count / 2],
            "p95": s[min(s.count - 1, Int(Double(s.count) * 0.95))], "max": s[s.count - 1], "n": Double(s.count)]
}

func rounded(_ x: Double, _ places: Int = 4) -> Double {
    let p = pow(10, Double(places))
    return (x * p).rounded() / p
}

func printJSON(_ obj: Any) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

func chipSlug() -> String {
    var size = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
    let name = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return name.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
}
