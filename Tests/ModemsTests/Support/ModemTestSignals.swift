import Foundation

/// Shared synthetic-signal helpers for modem tests.
enum ModemTestSignals {
    /// A pure sine tone.
    static func tone(_ hz: Double, seconds: Double, amplitude: Float = 0.5, sampleRate: Double = 12_000) -> [Float] {
        let n = Int(seconds * sampleRate)
        return (0..<n).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / sampleRate)) }
    }

    /// Adds white Gaussian noise so that the signal-to-noise ratio measured in a
    /// 2.5 kHz bandwidth equals `snrDb`:
    /// `10·log10(Psignal / (σ²·2500/(fs/2))) == snrDb`, where Psignal is the mean
    /// square of `x` and σ² the per-sample noise variance. Deterministic for a given `seed`.
    static func awgn(_ x: [Float], snrDb: Double, sampleRate: Double = 12_000, seed: UInt64) -> [Float] {
        guard !x.isEmpty else { return x }
        let pSignal = x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)
        let sigma2 = pSignal / pow(10, snrDb / 10) * (sampleRate / 2) / 2_500
        let sigma = sigma2.squareRoot()
        var rng = SplitMix64(seed: seed)
        var out = x
        var i = 0
        while i < out.count {
            // Box-Muller yields two independent normals per pair of uniforms.
            let r = (-2 * log(rng.uniform())).squareRoot()
            let theta = 2 * Double.pi * rng.uniform()
            out[i] += Float(sigma * r * cos(theta))
            if i + 1 < out.count { out[i + 1] += Float(sigma * r * sin(theta)) }
            i += 2
        }
        return out
    }

    /// `1 − levenshtein(sent, received) / sent.count`, clamped to ≥ 0.
    static func characterAccuracy(sent: String, received: String) -> Double {
        let a = Array(sent), b = Array(received)
        guard !a.isEmpty else { return b.isEmpty ? 1 : 0 }
        guard !b.isEmpty else { return 0 }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return max(0, 1 - Double(prev[b.count]) / Double(a.count))
    }
}

/// Small deterministic generator; uniform() is in the open interval (0, 1).
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double {
        (Double(next() >> 11) + 0.5) / Double(1 << 53)
    }
}
