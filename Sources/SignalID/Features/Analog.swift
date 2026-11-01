import Accelerate
import DSPCore
import Foundation

/// Amplitude features of one signal's channel: how steady, keyed or voice-like its envelope is, and whether
/// its modulation lies in phase with its carrier (AM) or in quadrature (FM, PM).
///
/// `noisePower` is the channel's noise power (from the spectrum), used to correct the block statistics.
struct EnvelopeFeatures {
    /// Length of the blocks the steadiness and voice statistics use: 20 ms, or long enough to hold 16
    /// independent samples of a narrow signal.
    static let blockSeconds = 0.02
    static let blockIndependent = 16.0
    /// Blocks for the in-phase/quadrature split (≥ 3 periods of 300 Hz audio).
    static let carrierBlockSeconds = 0.01

    /// Standard deviation over mean of the blocks' signal power (noise subtracted).
    var blockCV = 0.0
    /// What a constant envelope would show in this noise (the blocks' own noise).
    var steadyCV = 0.0
    /// Fraction of blocks whose signal power is under 10% of the 90th percentile.
    var pauseFraction = 0.0
    /// The same two for the in-phase modulation (an AM's audio): voice shows in them, not in the power.
    var modulationCV = 0.0
    var modulationPauseFraction = 0.0
    /// (var I − var Q) / var Q about each block's mean phasor: the in-phase modulation over the quadrature
    /// (which for AM is the noise alone). About 0 for noise, a carrier, SSB, QPSK and OFDM; positive when the
    /// modulation is in phase with a carrier (AM, keying), about the modulation's SNR; negative when it is in
    /// quadrature (FM, PM at low index).
    var inPhase = 0.0
    /// E|s|⁴ / (E|s|²)² of the signal with the noise's share taken out: 1 for a constant envelope (FM, FSK,
    /// a carrier), about 1.2–1.6 for filtered PSK, 2 for OFDM, 4 or so for SSB voice.
    var amplitudeM4 = 0.0
    var keying: Keying?
    /// The envelope's two levels and runs, when it has two (keying and bursts are read from them).
    var runs: EnvelopeRuns?

    init(_ z: [DSPComplex], rate: Double, bandwidthHz: Double, noisePower: Double) {
        let n = z.count
        guard n > 0 else { return }
        var power = [Float](repeating: 0, count: n)
        z.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: Float.self, capacity: 2 * n) { f in
                var split = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: f),
                                            imagp: UnsafeMutablePointer(mutating: f + 1))
                vDSP_zvmags(&split, 2, &power, 1, vDSP_Length(n))
            }
        }
        let seconds = max(Self.blockSeconds, Self.blockIndependent / max(bandwidthHz, 1))
        let block = max(1, Int((seconds * rate).rounded()))
        let blocks = Self.blockMeans(power, length: block).map { Double($0) - noisePower }
        (blockCV, pauseFraction) = Self.variation(blocks)
        // A constant envelope A² plus noise: var of a block mean ≈ (2A²σ² + σ⁴) / (samples per block × the
        // filter's correlation, about rate / bandwidth samples per independent one).
        let signal = max(blocks.reduce(0, +) / Double(max(blocks.count, 1)), 1e-30)
        let independent = max(1, Double(block) * min(1, 1.25 * bandwidthHz / rate))
        steadyCV = ((2 * signal * noisePower + noisePower * noisePower) / independent).squareRoot() / signal

        var mean: Float = 0, meanSquare: Float = 0
        vDSP_meanv(power, 1, &mean, vDSP_Length(n))
        vDSP_measqv(power, 1, &meanSquare, vDSP_Length(n))
        let m2 = Double(mean), m4 = Double(meanSquare)
        let s2 = max(m2 - noisePower, 1e-30)
        amplitudeM4 = (m4 - 4 * s2 * noisePower - 2 * noisePower * noisePower) / (s2 * s2)

        let modulation = inPhaseSplit(z, rate: rate)
        (modulationCV, modulationPauseFraction) = Self.variation(modulation)
        runs = EnvelopeRuns(power, rate: rate, bandwidthHz: bandwidthHz)
        keying = runs.flatMap(Keying.init)
    }

    /// Splits each 10 ms block about its mean phasor into in-phase and quadrature; sets `inPhase` and returns
    /// the in-phase variance per 20 ms (pairs of blocks), less the quadrature's (the noise).
    private mutating func inPhaseSplit(_ z: [DSPComplex], rate: Double) -> [Double] {
        let block = max(4, Int((Self.carrierBlockSeconds * rate).rounded()))
        var sumI = 0.0, sumQ = 0.0
        var perBlock: [Double] = []
        z.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: Float.self, capacity: 2 * z.count) { x in
                var start = 0
                let length = vDSP_Length(block)
                while start + block <= z.count {
                    // Block sums of re, im, re², im², re·im; the variances about the mean phasor follow.
                    let re = x + 2 * start, im = x + 2 * start + 1
                    var sr: Float = 0, si: Float = 0, srr: Float = 0, sii: Float = 0, sri: Float = 0
                    vDSP_sve(re, 2, &sr, length)
                    vDSP_sve(im, 2, &si, length)
                    vDSP_svesq(re, 2, &srr, length)
                    vDSP_svesq(im, 2, &sii, length)
                    vDSP_dotpr(re, 2, im, 2, &sri, length)
                    let m = Double(block)
                    let mr = Double(sr) / m, mi = Double(si) / m
                    let rr = Double(srr) / m, ii = Double(sii) / m, ri = Double(sri) / m
                    let norm = (mr * mr + mi * mi).squareRoot()
                    let (c, s) = norm > 0 ? (mr / norm, -mi / norm) : (1.0, 0.0)
                    // I = re c − im s, Q = re s + im c.
                    let meanI = mr * c - mi * s
                    let varI = c * c * rr + s * s * ii - 2 * c * s * ri - meanI * meanI
                    let varQ = s * s * rr + c * c * ii + 2 * c * s * ri
                    sumI += varI
                    sumQ += varQ
                    perBlock.append(varI - varQ)
                    start += block
                }
            }
        }
        inPhase = sumQ > 0 ? (sumI - sumQ) / sumQ : 0
        var pairs: [Double] = []
        var k = 0
        while k + 1 < perBlock.count {
            pairs.append(0.5 * (perBlock[k] + perBlock[k + 1]))
            k += 2
        }
        return pairs
    }

    /// Coefficient of variation (infinite when the mean isn't positive), and the fraction of values under 10%
    /// of the 90th percentile.
    static func variation(_ x: [Double]) -> (cv: Double, pauses: Double) {
        guard x.count >= 4 else { return (0, 0) }
        let mean = x.reduce(0, +) / Double(x.count)
        let variance = x.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(x.count)
        let sorted = x.sorted()
        let p90 = sorted[Int(0.9 * Double(x.count - 1))]
        let pauses = Double(x.filter { $0 < 0.1 * p90 }.count) / Double(x.count)
        return (mean > 0 ? variance.squareRoot() / mean : .infinity, pauses)
    }

    static func blockMeans(_ x: [Float], length: Int) -> [Float] {
        let count = x.count / length
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        x.withUnsafeBufferPointer { p in
            for b in 0..<count {
                var m: Float = 0
                vDSP_meanv(p.baseAddress! + b * length, 1, &m, vDSP_Length(length))
                out[b] = m
            }
        }
        return out
    }
}

/// On/off keying found in a channel's power: the envelope at 1 ms steps, smoothed over about 1 / bandwidth,
/// split by Otsu's threshold, then cut into marks and spaces with hysteresis (40% / 60% of the way from the
/// off to the on amplitude); runs under a quarter of the median run (at least 3 ms) are noise and are
/// merged into their neighbours. Nil when the envelope isn't two-level: the off amplitude must be under 35%
/// of the on amplitude, each level must hold 10–90% of the time, there must be at least 4 marks and 3
/// spaces, and the marks must share one level (their mean amplitudes' spread under 11.5% of their mean: a
/// keyed carrier's is under 10% at 10 dB, speech syllables' over 13%).
struct Keying {
    static let stepSeconds = 0.001
    static let maxOffRatio = 0.35
    static let maxLevelCV = 0.115

    /// Median amplitudes of the two levels.
    var onLevel: Double
    var offLevel: Double
    /// Fraction of the time on.
    var duty: Double
    /// Whole marks and spaces (the first and last runs, cut by the capture, are left out), in seconds.
    var marks: [Double]
    var spaces: [Double]
    /// Spread of the marks' levels (standard deviation over mean).
    var levelCV = 0.0

    init?(_ power: [Float], rate: Double, bandwidthHz: Double) {
        guard let envelope = EnvelopeRuns(power, rate: rate, bandwidthHz: bandwidthHz) else { return nil }
        self.init(envelope)
    }

    init?(_ envelope: EnvelopeRuns) {
        onLevel = envelope.onLevel
        offLevel = envelope.offLevel
        duty = envelope.duty
        guard offLevel < Self.maxOffRatio * onLevel, duty >= 0.1, duty <= 0.9 else { return nil }
        let runs = envelope.runs
        let amplitude = envelope.amplitude
        let stepSeconds = envelope.stepSeconds
        // Each whole mark's level: its middle 60%.
        var levels: [Double] = []
        var position = runs.first?.length ?? 0
        for run in runs.dropFirst().dropLast() {
            if run.on {
                let from = position + run.length / 5, to = position + run.length - run.length / 5
                if to > from { levels.append(amplitude[from..<to].reduce(0, +) / Double(to - from)) }
            }
            position += run.length
        }
        let whole = runs.dropFirst().dropLast()
        marks = whole.filter(\.on).map { Double($0.length) * stepSeconds }
        spaces = whole.filter { !$0.on }.map { Double($0.length) * stepSeconds }
        guard marks.count >= 4, spaces.count >= 3, levels.count >= 4 else { return nil }
        let mean = levels.reduce(0, +) / Double(levels.count)
        levelCV = (levels.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(levels.count)).squareRoot() / mean
        guard levelCV <= Self.maxLevelCV else { return nil }
    }

    /// Runs shorter than `minimum` steps folded into their neighbours, shortest first.
    static func merged(_ input: [(on: Bool, length: Int)], shorterThan minimum: Int) -> [(on: Bool, length: Int)] {
        var runs = input
        while runs.count > 2 {
            guard let k = runs.indices.dropFirst().dropLast().min(by: { runs[$0].length < runs[$1].length }),
                  runs[k].length < minimum else { break }
            let joined = runs[k - 1].length + runs[k].length + runs[k + 1].length
            runs.replaceSubrange((k - 1)...(k + 1), with: [(runs[k - 1].on, joined)])
        }
        return runs
    }

    static func median(_ x: [Int]) -> Int { x.isEmpty ? 0 : x.sorted()[x.count / 2] }

    /// The Morse unit (dot length): marks are 1 or 3 units, spaces 1, 3 or 7. The unit with the least
    /// squared log-error over 20–400 ms (1% steps; each run's error capped so stray runs can't dominate),
    /// refined as the geometric mean of the runs over their unit counts. Nil when the fit is poor (rms
    /// error over 25%).
    func morseUnit() -> Double? {
        let cap = log(1.6) * log(1.6)
        func fit(_ u: Double) -> (cost: Double, sum: Double, count: Int) {
            var cost = 0.0, sum = 0.0, count = 0
            for (runs, units) in [(marks, [1.0, 3]), (spaces, [1.0, 3, 7])] {
                for r in runs {
                    let best = units.map { log(r / ($0 * u)) }.min { abs($0) < abs($1) }!
                    cost += min(best * best, cap)
                    if best * best < cap { sum += best; count += 1 }
                }
            }
            return (cost, sum, count)
        }
        var bestUnit = 0.0, bestCost = Double.infinity
        var u = 0.02
        while u <= 0.4 {
            let c = fit(u).cost
            if c < bestCost { bestCost = c; bestUnit = u }
            u *= 1.01
        }
        // Refine: the unit moves by the mean log-error of the runs it fits.
        for _ in 0..<3 {
            let f = fit(bestUnit)
            guard f.count > 0 else { return nil }
            bestUnit *= exp(f.sum / Double(f.count))
        }
        let total = Double(marks.count + spaces.count)
        guard (fit(bestUnit).cost / total).squareRoot() <= 0.25 else { return nil }
        return bestUnit
    }

    /// Otsu's threshold over a 64-bin histogram of `x`.
    static func otsu(_ x: [Double]) -> Double? {
        guard let lo = x.min(), let hi = x.max(), hi > lo else { return nil }
        let bins = 64
        var histogram = [Double](repeating: 0, count: bins)
        for v in x { histogram[min(bins - 1, Int((v - lo) / (hi - lo) * Double(bins)))] += 1 }
        let total = Double(x.count)
        let sumAll = histogram.enumerated().reduce(0) { $0 + Double($1.offset) * $1.element }
        var weight = 0.0, sum = 0.0, best = 0.0, split = 0
        for k in 0..<(bins - 1) {
            weight += histogram[k]
            sum += Double(k) * histogram[k]
            guard weight > 0, weight < total else { continue }
            let m0 = sum / weight, m1 = (sumAll - sum) / (total - weight)
            let between = weight * (total - weight) * (m0 - m1) * (m0 - m1)
            if between > best { best = between; split = k }
        }
        return lo + Double(split + 1) / Double(bins) * (hi - lo)
    }
}

/// Instantaneous-frequency features of one signal's channel: the FM deviation, the shape of the frequency
/// distribution, and lines in the demodulated baseband (the WFM stereo pilot).
///
/// Noise adds to the instantaneous frequency a spread whose density rises as f² (N0 / (2 Ps) × f², N0 the
/// noise density and Ps the signal power). The modulation's bandwidth is where the frequency's spectrum
/// stops standing over that rise (`modulationBandwidth`); the frequency is low-passed just above it (flat to
/// 1.1 × it, at most 0.7 × the occupied bandwidth), and the noise left in it is the f² density integrated
/// through that filter's response. The deviation is the 99.9th percentile of |f| of the distribution with
/// that Gaussian noise taken out (Richardson–Lucy deconvolution of the histogram): the peak of the clean
/// modulation, but not a single sample's.
struct FrequencyFeatures {
    static let deviationPercentile = 0.999
    /// Richardson–Lucy iterations: more sharpen the histogram's own scatter and, with the noise at a fifth of
    /// the deviation (NFM at 10 dB), pull the 99.9th percentile in by 5–10% (60 did); fewer leave noise in.
    static let deconvolutionIterations = 20
    /// The low-pass is flat to this multiple of the modulation's bandwidth…
    static let passFactor = 1.1
    /// …and no wider than this fraction of the occupied bandwidth.
    static let maxPassFraction = 0.7
    /// Noise-corrected rms of the low-passed frequency, over half the occupied bandwidth.
    var spread = 0.0
    var deviationHz = 0.0
    /// Kurtosis of the clean distribution (FM voice and programme ≳ 2.8; equiprobable FSK tones ≲ 2).
    var kurtosis = 0.0
    /// Peaks of the distribution with a valley under half the lower one between them (FSK tones, AFSK).
    var tonal = false
    /// Lines found in the demodulated baseband, in Hz.
    var lines: [Double] = []
    /// Rms of the frequency noise through the low-pass.
    var noiseHz = 0.0
    /// Bandwidth of the modulation (the demodulated baseband standing over the noise).
    var audioHz = 0.0

    /// `channelHz` is the channel's width (its noise reaches about ±0.625 of it).
    init(_ z: [DSPComplex], rate: Double, occupiedHz: Double, channelHz: Double, noiseDensity: Double,
         signalPower: Double, lineSearchHz: [Double] = []) {
        let n = z.count
        guard n > 64, occupiedHz > 0, signalPower > 0 else { return }
        let f = Self.discriminator(z, rate: rate)
        lines = lineSearchHz.compactMap { Self.line(in: f, rate: rate, near: $0) }

        let edge = min(0.625 * channelHz, rate / 2)
        let noiseScale = noiseDensity / (2 * signalPower)
        audioHz = Self.modulationBandwidth(f, rate: rate, noiseScale: noiseScale, upTo: edge)
        let pass = min(Self.passFactor * audioHz, Self.maxPassFraction * occupiedHz, 0.4 * rate)
        let taps = Self.lowpassTaps(pass: pass / rate)
        // Only every `step`-th output is needed (at least 4 samples per cycle of the pass band's edge).
        let step = max(1, Int(rate / (4 * pass)))
        let filtered = Self.filter(f, taps, step: step)
        // The f² noise through the filter: ∫ f² |H(f)|² df over ±edge (|H| is flat to `pass` and nothing
        // past 1.5 × it).
        let steps = 100
        let top = min(edge, 1.5 * pass)
        var integral = min(pass, top) * min(pass, top) * min(pass, top) / 3
        if top > pass {
            let dx = (top - pass) / Double(steps)
            for i in 0..<steps {
                let x = pass + (Double(i) + 0.5) * dx
                let h = Self.response(taps, at: x / rate)
                integral += x * x * h * h * dx
            }
        }
        noiseHz = (2 * integral * noiseScale).squareRoot()
        // The ends, where the filter ran over held samples, are left out.
        let trim = taps.count / step + 1
        let body = filtered.count > 4 * trim ? Array(filtered[trim..<(filtered.count - trim)]) : filtered
        var meanF: Float = 0, squares: Float = 0
        vDSP_meanv(body, 1, &meanF, vDSP_Length(body.count))
        vDSP_measqv(body, 1, &squares, vDSP_Length(body.count))
        let mean = Double(meanF)
        let variance = Double(squares) - mean * mean
        spread = max(0, variance - noiseHz * noiseHz).squareRoot() / (occupiedHz / 2)
        var centred = [Float](repeating: 0, count: body.count)
        var shift = Float(-mean)
        vDSP_vsadd(body, 1, &shift, &centred, 1, vDSP_Length(body.count))
        let clean = Self.deconvolved(centred, noise: noiseHz)
        deviationHz = clean.percentile(Self.deviationPercentile)
        kurtosis = clean.kurtosis
        tonal = clean.tonal
    }

    /// Instantaneous frequency in Hz: arg(z[k] · conj z[k−1]) × rate / 2π (sample 0 repeats sample 1).
    static func discriminator(_ z: [DSPComplex], rate: Double) -> [Float] {
        let n = z.count
        var re = [Float](repeating: 0, count: n - 1), im = [Float](repeating: 0, count: n - 1)
        z.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: Float.self, capacity: 2 * n) { x in
                let later = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: x + 2),
                                            imagp: UnsafeMutablePointer(mutating: x + 3))
                let earlier = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: x),
                                              imagp: UnsafeMutablePointer(mutating: x + 1))
                re.withUnsafeMutableBufferPointer { r in
                    im.withUnsafeMutableBufferPointer { i in
                        var product = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                        var a = later, b = earlier
                        // Conjugating the first operand (−1): conj(earlier) × later.
                        vDSP_zvmul(&b, 2, &a, 2, &product, 1, vDSP_Length(n - 1), -1)
                    }
                }
            }
        }
        var f = [Float](repeating: 0, count: n)
        f.withUnsafeMutableBufferPointer { out in
            var count = Int32(n - 1)
            vvatan2f(out.baseAddress! + 1, im, re, &count)
            var scale = Float(rate / (2 * .pi))
            vDSP_vsmul(out.baseAddress! + 1, 1, &scale, out.baseAddress! + 1, 1, vDSP_Length(n - 1))
            out[0] = out[1]
        }
        return f
    }

    /// The highest frequency (up to `upTo`) at which the frequency's spectrum, averaged over ±2.5% of `upTo`,
    /// stands at least 2 × over the noise's rise `noiseScale` × f² (two-sided density, Hz²/Hz).
    static func modulationBandwidth(_ f: [Float], rate: Double, noiseScale: Double, upTo: Double) -> Double {
        let size = 2048
        let x = f.map { DSPComplex(real: $0, imag: 0) }
        let p = PowerSpectrum.averagePower(x, size: size, maxFrames: 256, hop: size / 4)
        let binHz = rate / Double(size)
        let top = min(size / 2 - 1, Int(upTo / binHz))
        guard top > 4 else { return upTo }
        let reach = max(1, Int(0.025 * upTo / binHz))
        let density = (0...top).map { Double(p[size / 2 + $0]) / (binHz * SpectrumView.enbw) }
        let prefix = OccupiedWidth.prefixSums(density)
        for k in stride(from: top, through: 1, by: -1) {
            let lo = max(1, k - reach), hi = min(top, k + reach)
            let mean = (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
            let hz = Double(k) * binHz
            if mean >= 2 * noiseScale * hz * hz { return min(upTo, hz + Double(reach) * binHz) }
        }
        return Double(reach) * binHz
    }

    /// Windowed-sinc low-pass (Blackman-Harris) flat to `pass` (cycles per sample), its transition 30% of
    /// that wide.
    static func lowpassTaps(pass: Double) -> [Float] {
        let taps = FIRDesign.tapCount(transition: max(0.3 * pass, 1e-4), max: 4095)
        return FIRDesign.lowpass(taps: taps, cutoff: 1.15 * pass)
    }

    /// `x` through `taps`, every `step`-th output (output k is input k × step), the delay removed and the ends
    /// held.
    static func filter(_ x: [Float], _ taps: [Float], step: Int = 1) -> [Float] {
        let half = taps.count / 2
        let padded = [Float](repeating: x.first ?? 0, count: half) + x + [Float](repeating: x.last ?? 0, count: half)
        let count = (x.count + step - 1) / step
        var out = [Float](repeating: 0, count: count)
        vDSP_desamp(padded, vDSP_Stride(step), taps, &out, vDSP_Length(count), vDSP_Length(taps.count))
        return out
    }

    /// |H| of symmetric taps at `frequency` (cycles per sample).
    static func response(_ taps: [Float], at frequency: Double) -> Double {
        let centre = Double(taps.count - 1) / 2
        var sum = 0.0
        for (k, h) in taps.enumerated() { sum += Double(h) * cos(2 * .pi * frequency * (Double(k) - centre)) }
        return abs(sum)
    }

    /// The strongest bin of the frequency's spectrum within ±1% of `hz` standing 10 dB over the median of
    /// the bins within ±10% of it, its frequency interpolated.
    static func line(in f: [Float], rate: Double, near hz: Double) -> Double? {
        guard hz < rate / 2 else { return nil }
        let size = 8192
        let x = f.map { DSPComplex(real: $0, imag: 0) }
        let p = PowerSpectrum.averagePower(x, size: size, maxFrames: 128, hop: size / 2)
        let binHz = rate / Double(size)
        func bin(_ h: Double) -> Int { min(size - 2, max(1, size / 2 + Int((h / binHz).rounded()))) }
        let near = bin(hz * 0.99)...bin(hz * 1.01)
        guard let peak = near.max(by: { p[$0] < p[$1] }) else { return nil }
        let around = (bin(hz * 0.9)...bin(hz * 1.1)).filter { abs($0 - peak) > 4 }.map { p[$0] }.sorted()
        guard !around.isEmpty, p[peak] >= 10 * around[around.count / 2] else { return nil }
        // Log-parabola through the peak and its neighbours.
        let a = log(max(Double(p[peak - 1]), 1e-30)), b = log(max(Double(p[peak]), 1e-30))
        let c = log(max(Double(p[peak + 1]), 1e-30))
        let curvature = a - 2 * b + c
        let shift = curvature < 0 ? min(0.5, max(-0.5, 0.5 * (a - c) / curvature)) : 0
        return (Double(peak - size / 2) + shift) * binHz
    }

    /// A histogram of `x` with Gaussian noise of rms `noise` deconvolved (Richardson–Lucy).
    static func deconvolved(_ x: [Float], noise: Double) -> Distribution {
        // The range holds all but the farthest 0.001% each side, and room for the noise's blur beyond.
        let (q0, q1) = Self.quantiles(x, 0.00001, 0.99999)
        let lo = q0 - 3 * noise, hi = q1 + 3 * noise
        let bins = 512
        let width = max(hi - lo, 1e-9) / Double(bins)
        var observed = [Double](repeating: 0, count: bins)
        for v in x {
            let k = Int((Double(v) - lo) / width)
            if k >= 0 && k <= bins { observed[min(k, bins - 1)] += 1 }
        }
        var total = 0.0
        vDSP_sveD(observed, 1, &total, vDSP_Length(bins))
        var scale = 1 / max(total, 1)
        vDSP_vsmulD(observed, 1, &scale, &observed, 1, vDSP_Length(bins))
        let sigma = noise / width
        guard sigma > 0.3 else { return Distribution(density: observed, lo: lo, width: width) }
        let reach = min(bins - 1, Int((4 * sigma).rounded(.up)))
        var kernel = (-reach...reach).map { exp(-0.5 * Double($0 * $0) / (sigma * sigma)) }
        var kernelSum = 0.0
        vDSP_sveD(kernel, 1, &kernelSum, vDSP_Length(kernel.count))
        var inverse = 1 / kernelSum
        vDSP_vsmulD(kernel, 1, &inverse, &kernel, 1, vDSP_Length(kernel.count))
        // Blurs into `out` through a zero-padded copy (the kernel is symmetric, so correlation = convolution).
        var padded = [Double](repeating: 0, count: bins + 2 * reach)
        func blur(_ a: [Double], into out: inout [Double]) {
            padded.withUnsafeMutableBufferPointer { p in
                a.withUnsafeBufferPointer {
                    p.baseAddress!.advanced(by: reach).update(from: $0.baseAddress!, count: bins)
                }
            }
            vDSP_convD(padded, 1, kernel, 1, &out, 1, vDSP_Length(bins), vDSP_Length(kernel.count))
        }
        var estimate = observed
        var predicted = [Double](repeating: 0, count: bins)
        var correction = [Double](repeating: 0, count: bins)
        var tiny = 1e-12
        for _ in 0..<Self.deconvolutionIterations {
            blur(estimate, into: &predicted)
            vDSP_vthrD(predicted, 1, &tiny, &predicted, 1, vDSP_Length(bins))
            var ratio = [Double](repeating: 0, count: bins)
            vDSP_vdivD(predicted, 1, observed, 1, &ratio, 1, vDSP_Length(bins))
            blur(ratio, into: &correction)
            vDSP_vmulD(estimate, 1, correction, 1, &estimate, 1, vDSP_Length(bins))
            var sum = 0.0
            vDSP_sveD(estimate, 1, &sum, vDSP_Length(bins))
            guard sum > 0 else { break }
            var normal = 1 / sum
            vDSP_vsmulD(estimate, 1, &normal, &estimate, 1, vDSP_Length(bins))
        }
        return Distribution(density: estimate, lo: lo, width: width)
    }

    /// The `p0` and `p1` quantiles of `x`, to 1/4096 of its range (from a histogram: no sort).
    static func quantiles(_ x: [Float], _ p0: Double, _ p1: Double) -> (Double, Double) {
        var lo: Float = 0, hi: Float = 0
        vDSP_minv(x, 1, &lo, vDSP_Length(x.count))
        vDSP_maxv(x, 1, &hi, vDSP_Length(x.count))
        let bins = 4096
        let width = max(Double(hi - lo), 1e-9) / Double(bins)
        var counts = [Int](repeating: 0, count: bins)
        for v in x { counts[min(bins - 1, Int((Double(v) - Double(lo)) / width))] += 1 }
        func quantile(_ p: Double) -> Double {
            let target = p * Double(x.count)
            var cumulative = 0
            for (k, c) in counts.enumerated() {
                cumulative += c
                if Double(cumulative) >= target { return Double(lo) + (Double(k) + 0.5) * width }
            }
            return Double(hi)
        }
        return (quantile(p0), quantile(p1))
    }

    /// A probability histogram.
    struct Distribution {
        var density: [Double]
        var lo: Double
        var width: Double

        func centre(_ i: Int) -> Double { lo + (Double(i) + 0.5) * width }

        /// The `p` percentile of |x|.
        func percentile(_ p: Double) -> Double {
            let magnitudes = density.indices.map { (abs(centre($0)), density[$0]) }.sorted { $0.0 < $1.0 }
            var cumulative = 0.0
            for (m, d) in magnitudes {
                cumulative += d
                if cumulative >= p { return m }
            }
            return magnitudes.last?.0 ?? 0
        }

        var kurtosis: Double {
            let mean = density.indices.reduce(0) { $0 + centre($1) * density[$1] }
            var m2 = 0.0, m4 = 0.0
            for i in density.indices {
                let d = centre(i) - mean
                m2 += d * d * density[i]
                m4 += d * d * d * d * density[i]
            }
            return m2 > 0 ? m4 / (m2 * m2) : 0
        }

        /// Two peaks (smoothed over 1/32 of the span) with a valley under half the lower one between them.
        var tonal: Bool {
            let reach = density.count / 64
            let prefix = OccupiedWidth.prefixSums(density)
            let s = density.indices.map { k in
                let lo = max(0, k - reach), hi = min(density.count - 1, k + reach)
                return (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
            }
            let peaks = (1..<(s.count - 1)).filter { s[$0] >= s[$0 - 1] && s[$0] > s[$0 + 1] }
            let top = s.max() ?? 0
            let strong = peaks.filter { s[$0] >= 0.25 * top }
            guard strong.count >= 2 else { return false }
            for (a, b) in zip(strong, strong.dropFirst()) {
                let valley = s[a...b].min()!
                if valley < 0.5 * min(s[a], s[b]) { return true }
            }
            return false
        }
    }
}

/// Which way an SSB signal leans: voice is strongest at the low audio frequencies, beside the suppressed
/// carrier, so the stronger edge of the passband is the carrier side (USB: the lower edge).
///
/// `tiltDb` is the power of the upper half of the passband over the lower half's, in dB (negative for USB).
/// `asymmetryDb` is the passband's power over the power in its mirror image about the carrier side (where
/// the other sideband of a DSB signal would lie), the latter floored at its own statistical uncertainty.
struct SidebandFeatures {
    var tiltDb = 0.0
    var asymmetryDb = 0.0

    init(_ view: SpectrumView, occupied: ClosedRange<Int>) {
        let width = occupied.count
        guard width >= 10 else { return }
        let half = width / 2
        let lower = view.signal(occupied.lowerBound...(occupied.lowerBound + half - 1)).reduce(0, +)
        let upper = view.signal((occupied.upperBound - half + 1)...occupied.upperBound).reduce(0, +)
        tiltDb = 10 * log10(max(upper, 1e-30) / max(lower, 1e-30))
        let inside = view.signal(occupied).reduce(0, +)
        let mirror: ClosedRange<Int> = tiltDb < 0
            ? max(0, occupied.lowerBound - width)...max(0, occupied.lowerBound - 1)
            : min(view.count - 1, occupied.upperBound + 1)...min(view.count - 1, occupied.upperBound + width)
        let outside = view.signal(mirror).reduce(0, +)
        let uncertainty = 3 * view.spread * view.noise * Double(mirror.count).squareRoot()
        asymmetryDb = 10 * log10(max(inside, 1e-30) / max(outside, uncertainty, 1e-30))
    }
}
