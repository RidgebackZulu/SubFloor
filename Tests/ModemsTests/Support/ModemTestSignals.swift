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
    /// `10·log10(Psignal / (σ²·2500/(fs/2))) == snrDb`, where σ² is the per-sample noise
    /// variance. Deterministic for a given `seed`.
    ///
    /// SNR convention (controller ruling R7, the WSJT convention used by every decode test):
    /// - **Signal power** is the steady in-burst power of the signal: `amplitude²/2` for a tone or a
    ///   constant-envelope mode (RTTY, FT8, WSPR), and the key-down power for CW. PSK31 is not
    ///   constant-envelope (its amplitude dips at every phase reversal), so its reference is the mean
    ///   burst power, the mean square while it transmits (ruling R12). It is never the
    ///   duty-cycle-diluted mean square of a buffer that contains gaps.
    /// - **Noise** is the noise power falling in a 2.5 kHz bandwidth.
    /// - When `signalPower` is nil, Psignal is the mean square of `x`. That is only correct when `x`
    ///   is the signal alone with no silence or padding. Callers **must** pass `signalPower`
    ///   whenever the buffer contains silence, padding, keying gaps or several signals.
    /// - Calling this on an all-zero buffer without `signalPower` adds no noise at all. Use
    ///   `noise(seconds:sigma:seed:sampleRate:)` for noise-only input.
    static func awgn(_ x: [Float], snrDb: Double, sampleRate: Double = 12_000, seed: UInt64,
                     signalPower: Double? = nil) -> [Float] {
        guard !x.isEmpty else { return x }
        let pSignal = signalPower ?? x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)
        let sigma2 = pSignal / pow(10, snrDb / 10) * (sampleRate / 2) / 2_500
        var out = x
        addGaussian(into: &out, sigma: sigma2.squareRoot(), seed: seed)
        return out
    }

    /// Pure white Gaussian noise with standard deviation `sigma` per sample. Every noise-only
    /// test must use this (ruling R7): `awgn` on zeros is silence and makes the test vacuous.
    /// Deterministic for a given `seed`.
    static func noise(seconds: Double, sigma: Float = 0.05, seed: UInt64, sampleRate: Double = 12_000) -> [Float] {
        var out = [Float](repeating: 0, count: Int(seconds * sampleRate))
        addGaussian(into: &out, sigma: Double(sigma), seed: seed)
        return out
    }

    /// Adds N(0, sigma²) to every element, using Box-Muller pairs from a SplitMix64 stream.
    private static func addGaussian(into out: inout [Float], sigma: Double, seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        var i = 0
        while i < out.count {
            // Box-Muller yields two independent normals per pair of uniforms.
            let r = (-2 * log(rng.uniform())).squareRoot()
            let theta = 2 * Double.pi * rng.uniform()
            out[i] += Float(sigma * r * cos(theta))
            if i + 1 < out.count { out[i + 1] += Float(sigma * r * sin(theta)) }
            i += 2
        }
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
