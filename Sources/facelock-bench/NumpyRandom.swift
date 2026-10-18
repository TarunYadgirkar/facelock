import Foundation

/// numpy.random.default_rng(seed) (SeedSequence -> PCG64) and Generator.shuffle, bit for bit,
/// so the harness rebuilds the 0.4 impostor-bank list without Python.
struct SeedSequence {
    private static let initA: UInt32 = 0x43b0_d7e5, multA: UInt32 = 0x931e_8875
    private static let initB: UInt32 = 0x8b51_f9dd, multB: UInt32 = 0x58f3_8ded
    private static let mixL: UInt32 = 0xca01_f9dd, mixR: UInt32 = 0x4973_f715
    private static let poolSize = 4

    let pool: [UInt32]

    init(_ seed: UInt64) {
        var entropy: [UInt32] = []
        var s = seed
        repeat {
            entropy.append(UInt32(truncatingIfNeeded: s))
            s >>= 32
        } while s > 0
        var hashConst = Self.initA
        func hashmix(_ v: UInt32) -> UInt32 {
            var value = v ^ hashConst
            hashConst = hashConst &* Self.multA
            value = value &* hashConst
            return value ^ (value >> 16)
        }
        func mix(_ x: UInt32, _ y: UInt32) -> UInt32 {
            let r = (Self.mixL &* x) &- (Self.mixR &* y)
            return r ^ (r >> 16)
        }
        var mixer = (0..<Self.poolSize).map { hashmix($0 < entropy.count ? entropy[$0] : 0) }
        for src in 0..<Self.poolSize {
            for dst in 0..<Self.poolSize where src != dst {
                mixer[dst] = mix(mixer[dst], hashmix(mixer[src]))
            }
        }
        for src in Self.poolSize..<max(Self.poolSize, entropy.count) {
            for dst in 0..<Self.poolSize {
                mixer[dst] = mix(mixer[dst], hashmix(entropy[src]))
            }
        }
        pool = mixer
    }

    func generateState(words n: Int) -> [UInt32] {
        var hashConst = Self.initB
        return (0..<n).map { i in
            var v = pool[i % pool.count] ^ hashConst
            hashConst = hashConst &* Self.multB
            v = v &* hashConst
            return v ^ (v >> 16)
        }
    }
}

struct PCG64 {
    private static let multiplier = UInt128(0x2360_ED05_1FC6_5DA4) << 64 | UInt128(0x4385_DF64_9FCC_F645)
    private var state: UInt128 = 0
    private let increment: UInt128
    private var buffered: UInt32?

    init(seed: UInt64) {
        let w = SeedSequence(seed).generateState(words: 8)
        let v = (0..<4).map { UInt64(w[2 * $0]) | UInt64(w[2 * $0 + 1]) << 32 }
        let initState = UInt128(v[0]) << 64 | UInt128(v[1])
        increment = (UInt128(v[2]) << 64 | UInt128(v[3])) << 1 | 1
        step()
        state = state &+ initState
        step()
    }

    private mutating func step() {
        state = state &* Self.multiplier &+ increment
    }

    mutating func next64() -> UInt64 {
        step()
        let rot = UInt64(truncatingIfNeeded: state >> 122)
        let x = UInt64(truncatingIfNeeded: state >> 64) ^ UInt64(truncatingIfNeeded: state)
        return (x >> rot) | (x << ((64 &- rot) & 63))
    }

    mutating func next32() -> UInt32 {
        if let b = buffered {
            buffered = nil
            return b
        }
        let n = next64()
        buffered = UInt32(truncatingIfNeeded: n >> 32)
        return UInt32(truncatingIfNeeded: n)
    }

    /// numpy's random_interval: masked rejection sampling in [0, max].
    mutating func interval(_ max: UInt64) -> UInt64 {
        guard max > 0 else { return 0 }
        var mask = max
        for s in [1, 2, 4, 8, 16, 32] as [UInt64] { mask |= mask >> s }
        if max <= 0xffff_ffff {
            while true {
                let v = UInt64(next32()) & mask
                if v <= max { return v }
            }
        }
        while true {
            let v = next64() & mask
            if v <= max { return v }
        }
    }

    /// Generator.shuffle on a 1-D array.
    mutating func shuffle<T>(_ a: [T]) -> [T] {
        var x = a
        for i in stride(from: x.count - 1, through: 1, by: -1) {
            let j = Int(interval(UInt64(i)))
            x.swapAt(i, j)
        }
        return x
    }
}
