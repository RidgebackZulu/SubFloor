import Accelerate
import DSPCore
import Foundation

/// Signal ID's one definition of occupied bandwidth, shared by the synthesiser's ground truth
/// (`SignalSynth.occupiedBandwidthHz(for:)`) and the measurer.
enum OccupiedWidth {
    /// The fixed point B = span{ bins ≥ ΣP · binHz / (100 B) } of a linear power spectrum: the width whose band
    /// edges are where the density falls to −20 dB of the signal's mean density over that width. Levels are
    /// averaged over ±1% of B (at least ±1 bin), so the answer doesn't hang on the resolution or on single
    /// bins; the edges are the outermost bins at or above the threshold, so gaps inside count. Iterated from
    /// `start` (Hz). `power` holds only the signal: the measurer subtracts the noise first (bins may then be
    /// slightly negative). `bins` is nil when no bin reaches the threshold (`widthHz` is then the last iterate).
    ///
    /// `noiseSigma` is the standard deviation of a single bin's leftover noise (0 for a noise-free spectrum).
    /// Where the −20 dB level lies under the noise's own scatter it can't be seen, so the threshold is
    /// raised to 3 × that scatter averaged over the ±1% (taken as half as many independent bins, since
    /// neighbouring bins share leakage): at low SNR the width is the part that stands out of the noise.
    static func fixedPoint(_ power: [Double], binHz: Double, start: Double,
                           noiseSigma: Double = 0) -> (widthHz: Double, bins: ClosedRange<Int>?) {
        let prefix = prefixSums(power)
        let total = prefix[power.count]
        var b = start
        var found: ClosedRange<Int>?
        for _ in 0..<40 {
            let reach = max(1, Int((0.01 * b / binHz).rounded()))
            let floor = 3 * noiseSigma * (2 / Double(2 * reach + 1)).squareRoot()
            guard let span = span(prefix, reach: reach, threshold: max(total * binHz / (100 * b), floor))
            else { return (b, nil) }
            found = span
            let next = Double(span.count) * binHz
            if abs(next - b) < binHz / 2 { return (next, span) }
            b = next
        }
        return (b, found)
    }

    /// The outermost bins whose level, averaged over ±`reach` bins, is at or above `threshold`.
    static func span(_ prefix: [Double], reach: Int, threshold: Double) -> ClosedRange<Int>? {
        let n = prefix.count - 1
        func level(_ k: Int) -> Double {
            let lo = max(0, k - reach), hi = min(n - 1, k + reach)
            return (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
        }
        guard let lo = (0..<n).first(where: { level($0) >= threshold }),
              let hi = (0..<n).last(where: { level($0) >= threshold }) else { return nil }
        return lo...hi
    }

    static func prefixSums(_ p: [Double]) -> [Double] {
        var prefix = [Double](repeating: 0, count: p.count + 1)
        for k in p.indices { prefix[k + 1] = prefix[k] + p[k] }
        return prefix
    }
}

/// An averaged power spectrum (linear) of complex baseband, cut to the band the channel filter passes, with
/// its noise level per bin.
///
/// Frames are Blackman-Harris, 75% overlapped, which leaves about half as many independent ones: a noise-only
/// bin's relative standard deviation (`spread`) is √(1.93 / frames).
struct SpectrumView {
    /// Equivalent noise bandwidth of the 4-term Blackman-Harris window, in bins.
    static let enbw = 2.0044
    let power: [Double]
    let binHz: Double
    /// Frequency of bin 0, relative to the baseband's 0 Hz.
    let firstHz: Double
    let spread: Double
    private(set) var noise = 0.0

    /// `binHz` is a target: the FFT size is the power of two nearest rate / binHz (at least 64).
    init(_ samples: [DSPComplex], rate: Double, binHz target: Double, usableHz: Double, maxFrames: Int = 1024) {
        var size = 64
        while size < 1 << 20 && Double(size) * target < rate / 1.414 { size *= 2 }
        let hop = size / 4
        let full = PowerSpectrum.averagePower(samples, size: size, maxFrames: maxFrames, hop: hop)
        let frames = max(1, min(maxFrames, (samples.count - size) / hop + 1))
        let bin = rate / Double(size)
        let half = min(size / 2 - 1, Int(usableHz / 2 / bin))
        power = full[(size / 2 - half)...(size / 2 + half)].map { Double($0) }
        binHz = bin
        firstHz = -Double(half) * bin
        spread = (1.93 / Double(frames)).squareRoot()
    }

    var count: Int { power.count }
    func bin(_ hz: Double) -> Int { min(count - 1, max(0, Int(((hz - firstHz) / binHz).rounded()))) }
    func hz(_ bin: Double) -> Double { firstHz + bin * binHz }

    /// Sets the noise level from the bins outside `excluding` (all of them when nil or fewer than 16 remain):
    /// anchored on their 10th percentile, which is a noise bin's noise × (1 − 1.28 spread) while signals
    /// fill up to about 85% of them, then the mean of the bins up to 4 spreads over that anchor (so the
    /// mean isn't biased, and other signals, a crowded band's neighbours included, don't lift it).
    mutating func estimateNoise(excluding: ClosedRange<Int>?) {
        var values = power.indices.filter { excluding?.contains($0) != true }.map { power[$0] }
        if values.count < 16 { values = power }
        values.sort()
        let anchor = max(values[values.count / 10] / max(1 - 1.2816 * spread, 0.2), 1e-30)
        let kept = values.filter { $0 <= anchor * (1 + 4 * spread) }
        noise = max(kept.isEmpty ? anchor : kept.reduce(0, +) / Double(kept.count), 1e-30)
    }

    /// Takes `other`'s noise density (the same window, so a bin's noise scales with its width).
    mutating func useNoise(of other: SpectrumView) {
        noise = other.noise * binHz / other.binHz
    }

    /// Power over the noise, as a multiple of the noise (0 = noise only).
    func excess(_ k: Int) -> Double { power[k] / noise - 1 }

    /// `excess` averaged over ±`reach` bins.
    func smoothedExcess(reach: Int) -> [Double] {
        let e = power.map { $0 / noise - 1 }
        let prefix = OccupiedWidth.prefixSums(e)
        return e.indices.map { k in
            let lo = max(0, k - reach), hi = min(count - 1, k + reach)
            return (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
        }
    }

    /// The noise-subtracted power of `bins`.
    func signal(_ bins: ClosedRange<Int>) -> [Double] { bins.map { power[$0] - noise } }
}

/// Power-of-two FFTs for the cyclic features (vDSP; setups are made per call, which costs well under a
/// millisecond against the transform itself).
enum FFT {
    /// The smallest power of two ≥ `n` (at least 64).
    static func size(atLeast n: Int) -> Int {
        var size = 64
        while size < n { size *= 2 }
        return size
    }

    /// In-place complex FFT of `re` and `im` (equal counts, a power of two), unscaled either way.
    static func transform(_ re: inout [Float], _ im: inout [Float], inverse: Bool = false) {
        let n = re.count
        let log2n = vDSP_Length(n.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return }
        defer { vDSP_destroy_fftsetup(setup) }
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(inverse ? kFFTDirection_Inverse
                                                                           : kFFTDirection_Forward))
            }
        }
    }

    /// |DFT|² of `segments` of the real sequence `x`, each with its own mean taken out and zero-padded to
    /// `size`, summed: bins 0…size/2 (bin k is k × rate / size). Segments longer than `size` are cut.
    static func power(_ x: [Float], segments: [Range<Int>], size: Int) -> [Float] {
        var sum = [Float](repeating: 0, count: size / 2 + 1)
        var re = [Float](repeating: 0, count: size), im = [Float](repeating: 0, count: size)
        for segment in segments where segment.count >= 8 {
            let m = min(segment.count, size)
            var mean: Float = 0
            x.withUnsafeBufferPointer { p in vDSP_meanv(p.baseAddress! + segment.lowerBound, 1, &mean, vDSP_Length(m)) }
            var shift = -mean
            for k in 0..<size { re[k] = 0; im[k] = 0 }
            x.withUnsafeBufferPointer { p in
                vDSP_vsadd(p.baseAddress! + segment.lowerBound, 1, &shift, &re, 1, vDSP_Length(m))
            }
            transform(&re, &im)
            for k in 0...(size / 2) { sum[k] += re[k] * re[k] + im[k] * im[k] }
        }
        return sum
    }
}

/// The strongest line of a power spectrum within a band: a cyclic feature's (the symbol rate in |x|² or in
/// a squared frequency derivative) or a subcarrier's. `contrast` is the line's bin over the continuum around
/// it (the median of the bins within ±20% of its frequency, its own ±`guardBins` left out); `hz` is
/// interpolated (log-parabola through the peak and its neighbours).
struct SpectralLine {
    var hz: Double
    var contrast: Double
    var power: Double

    init?(_ power: [Float], binHz: Double, in range: ClosedRange<Double>, guardBins: Int = 4) {
        let lo = max(1, Int((range.lowerBound / binHz).rounded(.up)))
        let hi = min(power.count - 2, Int((range.upperBound / binHz).rounded(.down)))
        guard hi > lo, let top = (lo...hi).max(by: { power[$0] < power[$1] }) else { return nil }
        self.init(power, binHz: binHz, at: top, guardBins: guardBins)
    }

    /// The line at bin `top`.
    init?(_ power: [Float], binHz: Double, at top: Int, guardBins: Int = 4) {
        guard top >= 1, top < power.count - 1 else { return nil }
        let k0 = max(1, Int(Double(top) * 0.8)), k1 = min(power.count - 1, Int(Double(top) * 1.2) + 1)
        var around = (k0...k1).filter { abs($0 - top) > guardBins }.map { power[$0] }
        guard around.count >= 8 else { return nil }
        around.sort()
        let continuum = Double(max(around[around.count / 2], 1e-30))
        let a = log(max(Double(power[top - 1]), 1e-30)), b = log(max(Double(power[top]), 1e-30))
        let c = log(max(Double(power[top + 1]), 1e-30))
        let curvature = a - 2 * b + c
        let shift = curvature < 0 ? min(0.5, max(-0.5, 0.5 * (a - c) / curvature)) : 0
        hz = (Double(top) + shift) * binHz
        self.power = Double(power[top])
        contrast = self.power / continuum
    }
}

/// Where a cyclic feature (a real sequence with a line at `hz`, such as |x|² at the symbol rate) peaks,
/// chunk by chunk, so a symbol clock can be followed through a capture whose rate is known only to a part
/// in a few hundred. Each chunk (about 24 cycles, within one segment) gives the phase of the line, and so
/// the time of a peak; over a long segment the phases' drift refines `hz` (least squares on the unwrapped
/// phases).
struct CyclicTiming {
    struct Chunk {
        var range: Range<Int>
        /// A peak of the cyclic component, in samples (fractional).
        var epoch: Double
        /// |line| over the chunk's mean: how clearly the chunk shows it.
        var strength: Double
    }
    var hz: Double
    let rate: Double
    var chunks: [Chunk] = []

    init(_ x: [Float], rate: Double, hz initial: Double, segments: [Range<Int>], cyclesPerChunk: Double = 24) {
        hz = initial
        self.rate = rate
        let chunkLength = max(16, Int(cyclesPerChunk * rate / initial))
        var pieces: [(segment: Int, range: Range<Int>)] = []
        for (s, segment) in segments.enumerated() {
            let count = max(1, segment.count / chunkLength)
            guard segment.count >= chunkLength / 2 else { continue }
            let length = segment.count / count
            for c in 0..<count {
                let start = segment.lowerBound + c * length
                pieces.append((s, start..<(c == count - 1 ? segment.upperBound : start + length)))
            }
        }
        // Complex amplitude of the line in each chunk, against absolute time (so phases compare across chunks).
        func phasors(_ f: Double) -> [(centre: Double, value: (re: Double, im: Double), mean: Double)] {
            pieces.map { piece in
                var re = 0.0, im = 0.0, sum = 0.0
                let w = 2 * Double.pi * f / rate
                var c = cos(w * Double(piece.range.lowerBound)), s = -sin(w * Double(piece.range.lowerBound))
                let dc = cos(w), ds = -sin(w)
                for k in piece.range {
                    let v = Double(x[k])
                    re += v * c
                    im += v * s
                    sum += v
                    (c, s) = (c * dc - s * ds, c * ds + s * dc)
                }
                let mean = sum / Double(piece.range.count)
                // The mean's own leakage into the line is small over many cycles; take it out anyway.
                return (Double(piece.range.lowerBound + piece.range.upperBound - 1) / 2, (re, im), mean)
            }
        }
        // Refine the rate from the phase drift within each segment that holds several chunks.
        for _ in 0..<2 {
            let p = phasors(hz)
            var sxx = 0.0, sxy = 0.0
            for s in segments.indices {
                let own = pieces.indices.filter { pieces[$0].segment == s }
                guard own.count >= 3 else { continue }
                var previous = atan2(p[own[0]].value.im, p[own[0]].value.re)
                var unwrapped = [previous]
                for i in own.dropFirst() {
                    var phase = atan2(p[i].value.im, p[i].value.re)
                    while phase - previous > .pi { phase -= 2 * .pi }
                    while phase - previous < -.pi { phase += 2 * .pi }
                    unwrapped.append(phase)
                    previous = phase
                }
                let t = own.map { p[$0].centre }
                let mt = t.reduce(0, +) / Double(t.count), mp = unwrapped.reduce(0, +) / Double(unwrapped.count)
                for (ti, pi) in zip(t, unwrapped) {
                    sxx += (ti - mt) * (ti - mt)
                    sxy += (ti - mt) * (pi - mp)
                }
            }
            guard sxx > 0 else { break }
            // The phase of x · e^{−jwk} drifts at (true − assumed) × 2π / rate per sample.
            let correction = sxy / sxx * rate / (2 * .pi)
            guard abs(correction) < 0.02 * hz else { break }
            hz += correction
        }
        let period = rate / hz
        chunks = zip(pieces, phasors(hz)).map { piece, p in
            // x ≈ mean + A cos(w k + φ): its line is (A/2) e^{jφ} × count; the peaks are where w k + φ = 0 mod 2π.
            let phase = atan2(p.value.im, p.value.re)
            var epoch = -phase / (2 * .pi) * period
            let start = Double(piece.range.lowerBound)
            epoch += ((start - epoch) / period).rounded(.up) * period
            let amplitude = 2 * (p.value.re * p.value.re + p.value.im * p.value.im).squareRoot()
                / Double(piece.range.count)
            return Chunk(range: piece.range, epoch: epoch, strength: amplitude / max(abs(p.mean), 1e-30))
        }
    }

    /// Each chunk's instants at `fraction` of a cycle after its peaks (0: the peaks themselves), at least
    /// `margin` samples inside the chunk, with the chunk's range.
    func instants(at fraction: Double, margin: Double) -> [(time: Double, chunk: Range<Int>)] {
        let period = rate / hz
        var out: [(time: Double, chunk: Range<Int>)] = []
        for chunk in chunks {
            let lo = Double(chunk.range.lowerBound) + margin, hi = Double(chunk.range.upperBound - 1) - margin
            var t = chunk.epoch + fraction * period
            t -= ((t - lo) / period).rounded(.down) * period
            while t <= hi {
                if t >= lo { out.append((t, chunk.range)) }
                t += period
            }
        }
        return out
    }
}
