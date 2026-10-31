import Accelerate
import Foundation

/// SplitMix64: small, fast and the same on every platform. `stream` separates independent sequences
/// drawn from one seed (the signal's content, the noise).
struct SynthRandom {
    private var state: UInt64

    init(seed: UInt64, stream: UInt64) {
        state = (seed &* 0x9E37_79B9_7F4A_7C15) ^ (stream &* 0xD1B5_4A32_D192_ED03) ^ 0x5DEE_CE66_D1CE_4E5B
        _ = next()
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// [0, 1).
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    /// Two streams of uniform Floats from one draw each: `a` in (0, 1) (never 0, for a log), `b` in [0, 1).
    /// The same numbers as `next()` would give, without its per-call cost in unoptimised builds.
    mutating func fillUniform(_ a: UnsafeMutablePointer<Float>, _ b: UnsafeMutablePointer<Float>, count: Int) {
        var s = state
        for k in 0..<count {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            a[k] = (Float(UInt32(truncatingIfNeeded: z) >> 8) + 0.5) * (1 / 16_777_216)
            b[k] = Float(UInt32(truncatingIfNeeded: z >> 32) >> 8) * (1 / 16_777_216)
        }
        state = s
    }

    mutating func uniform(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * uniform()
    }

    /// 0..<n.
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }

    /// Standard normal (Box–Muller).
    mutating func gaussian() -> Double {
        let u = max(uniform(), 1e-300)
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * uniform())
    }
}

/// Complex white Gaussian noise, vectorised Box–Muller.
enum SynthNoise {
    /// Adds noise of total power `power` (E|n|²) to interleaved IQ.
    static func add(to iq: inout [Float], power: Double, random: inout SynthRandom) {
        let n = iq.count / 2
        let chunk = 16_384
        var u1 = [Float](repeating: 0, count: chunk)
        var u2 = [Float](repeating: 0, count: chunk)
        var c = [Float](repeating: 0, count: chunk)
        var s = [Float](repeating: 0, count: chunk)
        var minusPower = Float(-power)
        var twoPi = Float(2 * Double.pi)
        var start = 0
        while start < n {
            let m = min(chunk, n - start)
            var count = Int32(m)
            u1.withUnsafeMutableBufferPointer { a in
                u2.withUnsafeMutableBufferPointer { b in random.fillUniform(a.baseAddress!, b.baseAddress!, count: m) }
            }
            u1.withUnsafeMutableBufferPointer { a in
                u2.withUnsafeMutableBufferPointer { b in
                    c.withUnsafeMutableBufferPointer { cp in
                        s.withUnsafeMutableBufferPointer { sp in
                            // r = sqrt(−power · ln u1): each of I and Q then has variance power / 2.
                            vvlogf(a.baseAddress!, a.baseAddress!, &count)
                            vDSP_vsmul(a.baseAddress!, 1, &minusPower, a.baseAddress!, 1, vDSP_Length(m))
                            vvsqrtf(a.baseAddress!, a.baseAddress!, &count)
                            vDSP_vsmul(b.baseAddress!, 1, &twoPi, b.baseAddress!, 1, vDSP_Length(m))
                            vvsincosf(sp.baseAddress!, cp.baseAddress!, b.baseAddress!, &count)
                            vDSP_vmul(cp.baseAddress!, 1, a.baseAddress!, 1, cp.baseAddress!, 1, vDSP_Length(m))
                            vDSP_vmul(sp.baseAddress!, 1, a.baseAddress!, 1, sp.baseAddress!, 1, vDSP_Length(m))
                        }
                    }
                }
            }
            iq.withUnsafeMutableBufferPointer { out in
                let base = out.baseAddress! + 2 * start
                vDSP_vadd(base, 2, c, 1, base, 2, vDSP_Length(m))
                vDSP_vadd(base + 1, 2, s, 1, base + 1, 2, vDSP_Length(m))
            }
            start += m
        }
    }
}
