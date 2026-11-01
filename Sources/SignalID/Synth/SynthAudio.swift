import Accelerate
import Foundation

/// The modulating audio of AM and FM test signals, peak-normalised to ±1.
enum SynthAudio {
    /// `count` samples of `kind` at `rate`. Generated at a lower audio rate when `rate` is far above the
    /// audio's bandwidth, then interpolated. `preEmphasis` (FM voice) lifts voice by 6 dB/octave across its
    /// band before it is normalised, as an FM transmitter does.
    static func make(_ kind: SynthSpec.Audio, rate: Double, count n: Int, preEmphasis: Bool = false,
                     random: inout SynthRandom) -> [Float] {
        let factor = max(1, Int(rate / max(4 * kind.highestHz, 8000)))
        let audioRate = rate / Double(factor)
        let m = (n + factor - 1) / factor + SynthDSP.interpolatorHalfSpan + 1
        let a = generate(kind, rate: audioRate, count: m, preEmphasis: preEmphasis, random: &random)
        return factor == 1 ? Array(a.prefix(n)) : SynthDSP.interpolate(a, factor: factor, count: n)
    }

    private static func generate(_ kind: SynthSpec.Audio, rate: Double, count n: Int, preEmphasis: Bool,
                                 random: inout SynthRandom) -> [Float] {
        switch kind {
        case .voice(let low, let high):
            // Driven into the transmitter's clipper: rms 0.45 of the peak (FM: after pre-emphasis).
            let tilt = -6 + (preEmphasis ? 20 * log10(high / low) : 0)
            var a = bandNoise(low: low, high: high, tiltDb: tilt, rms: 0.45, rate: rate, count: n, random: &random)
            let envelope = syllables(rate: rate, count: n, random: &random)
            vDSP_vmul(a, 1, envelope, 1, &a, 1, vDSP_Length(n))
            return clamp(a)
        case .program(let low, let high, let pilot):
            var a = bandNoise(low: low, high: high, tiltDb: 0, rms: 0.4, rate: rate, count: n, random: &random)
            // Slow level changes, as music has, never down to silence.
            let f = random.uniform(0.1...0.3), p = 2 * Double.pi * random.uniform()
            for i in 0..<n { a[i] *= Float(0.85 + 0.15 * sin(2 * .pi * f * Double(i) / rate + p)) }
            a = clamp(a)
            guard let pilot else { return a }
            let p0 = 2 * Double.pi * random.uniform()
            return (0..<n).map { i in 0.9 * a[i] + 0.1 * Float(sin(2 * .pi * pilot * Double(i) / rate + p0)) }
        case .tone(let hz):
            let p0 = 2 * Double.pi * random.uniform()
            return (0..<n).map { Float(sin(2 * .pi * hz * Double($0) / rate + p0)) }
        case .afsk(let centre, let fsk):
            let f = SynthModulators.fskFrequency(fsk, rate: rate, count: n, random: &random).map { $0 + centre }
            let phase = SynthDSP.integrate(f, rate: rate, start: 2 * .pi * random.uniform())
            return SynthDSP.unitPhasor(phase).re
        case .timeTicks:
            return timeTicks(rate: rate, count: n, random: &random)
        case .aptVideo:
            return apt(rate: rate, count: n, random: &random)
        case .faxVideo(let lpm):
            return fax(linesPerMinute: lpm, rate: rate, count: n, random: &random)
        }
    }

    // MARK: Kinds

    /// Real Gaussian noise between `low` and `high` Hz with a linear-in-dB tilt across the band, at `rms`.
    private static func bandNoise(low: Double, high: Double, tiltDb: Double, rms: Double, rate: Double,
                                  count n: Int, random: inout SynthRandom) -> [Float] {
        let x = SynthDSP.shapedNoise(count: n, rate: rate, random: &random) { f in
            let a = abs(f)
            guard a >= low && a <= high else { return 0 }
            return pow(10, tiltDb * (a - low) / (high - low) / 20)
        }
        var re = x.re
        var power: Float = 0
        vDSP_measqv(re, 1, &power, vDSP_Length(n))
        var k = Float(rms) / max(power.squareRoot(), 1e-20)
        vDSP_vsmul(re, 1, &k, &re, 1, vDSP_Length(n))
        return re
    }

    /// Syllables of 80–300 ms at levels 0.45–1 with 30–150 ms gaps, in phrases of 1.5–4 s separated by
    /// 0.3–0.9 s pauses; 30 ms raised-cosine edges.
    static func syllables(rate: Double, count n: Int, random: inout SynthRandom) -> [Float] {
        var key = [Float](repeating: 0, count: n)
        var t = -random.uniform(0...0.5)
        var phraseEnd = t + random.uniform(1.5...4)
        while t * rate < Double(n) {
            if t >= phraseEnd {
                t += random.uniform(0.3...0.9)
                phraseEnd = t + random.uniform(1.5...4)
                continue
            }
            let length = random.uniform(0.08...0.3)
            let level = Float(random.uniform(0.45...1))
            let from = max(0, Int(t * rate)), to = min(n, Int((t + length) * rate))
            if to > from { for i in from..<to { key[i] = level } }
            t += length + random.uniform(0.03...0.15)
        }
        return SynthDSP.smoothKey(key, rate: rate, seconds: 0.03)
    }

    /// WWV-like: the capture starts at a random point in the second.
    private static func timeTicks(rate: Double, count n: Int, random: inout SynthRandom) -> [Float] {
        let start = random.uniform()
        let p0 = 2 * Double.pi * random.uniform()
        return (0..<n).map { i in
            let t = Double(i) / rate + start
            let s = t - floor(t)
            if s < 0.005 { return Float(sin(2 * .pi * 1000 * s)) }
            if s < 0.03 || s >= 0.99 { return 0 }
            return Float(0.5 * sin(2 * .pi * 600 * t + p0))
        }
    }

    /// A smooth random image: `components` sinusoids across the line, drifting slowly line to line.
    private struct Image {
        var frequency: [Double] = []
        var amplitude: [Double] = []
        var phase: [Double] = []
        var drift: [Double] = []

        init(components: Int, maxHz: Double, random: inout SynthRandom) {
            for j in 0..<components {
                frequency.append(2 * pow(maxHz / 2, Double(j) / Double(components - 1)) * random.uniform(0.8...1.2))
                amplitude.append(random.uniform(0.3...1) / Double(j + 1).squareRoot())
                phase.append(2 * .pi * random.uniform())
                drift.append(random.uniform(-0.2...0.2))
            }
            let total = amplitude.reduce(0, +)
            amplitude = amplitude.map { $0 / total }
        }

        /// −1…1 at `s` seconds into line `line`.
        func value(_ s: Double, line: Int) -> Double {
            var v = 0.0
            for j in frequency.indices {
                v += amplitude[j] * sin(2 * .pi * frequency[j] * s + phase[j] + drift[j] * Double(line))
            }
            return max(-1, min(1, 2.2 * v))
        }
    }

    /// 2 lines/s; each line opens with a 1040 Hz sync burst (7 cycles), then image; a 2400 Hz subcarrier
    /// carries it at 10–95% amplitude.
    private static func apt(rate: Double, count n: Int, random: inout SynthRandom) -> [Float] {
        let image = Image(components: 24, maxHz: 1000, random: &random)
        let start = random.uniform(0...0.5)
        let sync = 7.0 / 1040
        let p0 = 2 * Double.pi * random.uniform()
        return (0..<n).map { i in
            let t = Double(i) / rate + start
            let line = Int(t / 0.5)
            let s = t - Double(line) * 0.5
            let video = s < sync ? 0.5 + 0.5 * sin(2 * .pi * 1040 * s) : 0.5 + 0.5 * image.value(s, line: line)
            return Float((0.1 + 0.85 * video) / 0.95 * sin(2 * .pi * 2400 * t + p0))
        }
    }

    /// Lines of `60 / lpm` s: a white margin for the first 5%, then image up to about 400 Hz of detail.
    private static func fax(linesPerMinute: Double, rate: Double, count n: Int,
                            random: inout SynthRandom) -> [Float] {
        let line = 60 / linesPerMinute
        let image = Image(components: 16, maxHz: 400, random: &random)
        let start = random.uniform(0...line)
        let video = (0..<n).map { i -> Float in
            let t = Double(i) / rate + start
            let k = Int(t / line)
            let s = t - Double(k) * line
            return s < 0.05 * line ? 1 : Float(image.value(s, line: k))
        }
        return clamp(SynthDSP.smoothKey(video, rate: rate, seconds: 0.002))
    }

    private static func clamp(_ a: [Float]) -> [Float] {
        var a = a
        var lo: Float = -1, hi: Float = 1
        vDSP_vclip(a, 1, &lo, &hi, &a, 1, vDSP_Length(a.count))
        return a
    }
}
