import Accelerate
import DSPCore
import Foundation

/// M-PSK measured without demodulating it:
/// - **Rate:** a pulse-shaped PSK's power |x|² is cyclostationary: its spectrum has a line at the symbol rate
///   (strongest for PSK31's cosine pulses, weaker as an RRC roll-off narrows). The strongest line between
///   0.25 B and 1.1 B (B the occupied width) is taken; `CyclicTiming` refines it and finds where |x|² peaks,
///   which is at the symbols (the power summed over a Nyquist or RRC pulse's tails is greatest there).
/// - **Order:** at those instants (as received, or through a matched RRC filter, whichever shows the stronger
///   line) the symbols sit near the constellation's points e^{j(φ + 2πk/M)}, so sⁿ has a
///   line for n a multiple of M (at n × any residual carrier offset) and none otherwise. Its strength, on the
///   symbols' phases, |Σ e^{jnθ} e^{−j2πfk}| / count at the strongest f (1 for a clean M-PSK, e^{−n²σ²/2} for
///   a phase scatter σ, about √(ln(4 count) / count) for none), is taken for n = 1, 2, 4 and 8; the order is
///   the smallest n whose line is strong.
struct PSKFeatures {
    static let minRateFraction = 0.25
    static let maxRateFraction = 1.1
    static let minLineContrast = 4.0
    /// The rate line's transform: at most 2¹⁸ points (a segment longer than that is cut; the timing refines
    /// the rate anyway).
    static let maxLineFFT = 1 << 18
    static let orders = [1, 2, 4, 8]

    var symbolRate = 0.0
    var lineContrast = 0.0
    var symbolCount = 0
    /// Line strength of the symbols' n-th power for n = 1, 2, 4, 8.
    var powerLines: [Int: Double] = [:]

    init?(_ z: [DSPComplex], rate: Double, occupiedHz: Double, segments: [Range<Int>]) {
        let n = z.count
        guard n > 256, occupiedHz > 0 else { return nil }
        var power = [Float](repeating: 0, count: n)
        z.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: Float.self, capacity: 2 * n) { f in
                var split = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: f),
                                            imagp: UnsafeMutablePointer(mutating: f + 1))
                vDSP_zvmags(&split, 2, &power, 1, vDSP_Length(n))
            }
        }
        let inside = segments.filter { $0.count >= 64 }
        guard let longest = inside.map(\.count).max() else { return nil }
        let size = min(FFT.size(atLeast: 2 * longest), Self.maxLineFFT)
        let spectrum = FFT.power(power, segments: inside, size: size)
        let binHz = rate / Double(size)
        let lo = max(occupiedHz * Self.minRateFraction, 8 * rate / Double(longest))
        let hi = min(occupiedHz * Self.maxRateFraction, 0.45 * rate)
        guard lo < hi, let line = SpectralLine(spectrum, binHz: binHz, in: lo...hi,
                                               guardBins: max(4, 2 * size / longest)) else { return nil }
        lineContrast = line.contrast
        guard lineContrast >= Self.minLineContrast else { return nil }
        let timing = CyclicTiming(power, rate: rate, hz: line.hz, segments: inside)
        symbolRate = timing.hz

        // The symbols at the instants, as received and through a matched root-raised-cosine filter (α 0.35:
        // most PSK is RRC-shaped, and matching takes out its interference and the noise beyond the band;
        // PSK31's cosine pulses are clean at the instants as received). The view whose strongest line is the
        // stronger is kept.
        let instants = timing.instants(at: 0, margin: 1).map(\.time)
        let received = Self.sampled(z, at: instants)
        let matched = Self.sampled(Self.matchedFilter(z, samplesPerSymbol: rate / symbolRate), at: instants)
        symbolCount = received.re.count
        guard symbolCount >= 16 else { return nil }
        var lines: [[Int: Double]] = []
        for view in [received, matched] {
            var strengths: [Int: Double] = [:]
            for order in Self.orders { strengths[order] = Self.lineStrength(view.re, view.im, power: order) }
            lines.append(strengths)
        }
        powerLines = lines.max { ($0.values.max() ?? 0) < ($1.values.max() ?? 0) }!
    }

    /// `z` linearly interpolated at `instants`.
    static func sampled(_ z: [DSPComplex], at instants: [Double]) -> (re: [Float], im: [Float]) {
        var re = [Float](), im = [Float]()
        re.reserveCapacity(instants.count)
        im.reserveCapacity(instants.count)
        for t in instants {
            let k = Int(t), w = Float(t - Double(k))
            guard k + 1 < z.count else { continue }
            re.append(z[k].real + w * (z[k + 1].real - z[k].real))
            im.append(z[k].imag + w * (z[k + 1].imag - z[k].imag))
        }
        return (re, im)
    }

    /// `z` through a root-raised-cosine filter (roll-off 0.35, ±4 symbols), its delay taken out.
    static func matchedFilter(_ z: [DSPComplex], samplesPerSymbol: Double) -> [DSPComplex] {
        let half = max(1, Int((4 * samplesPerSymbol).rounded()))
        let taps = (-half...half).map {
            Float(SynthModulators.rootRaisedCosine(Double($0) / samplesPerSymbol, alpha: 0.35))
        }
        let n = z.count
        var re = [Float](repeating: 0, count: n + 2 * half), im = [Float](repeating: 0, count: n + 2 * half)
        for k in 0..<n {
            re[k + half] = z[k].real
            im[k + half] = z[k].imag
        }
        var outRe = [Float](repeating: 0, count: n), outIm = [Float](repeating: 0, count: n)
        vDSP_conv(re, 1, taps, 1, &outRe, 1, vDSP_Length(n), vDSP_Length(taps.count))
        vDSP_conv(im, 1, taps, 1, &outIm, 1, vDSP_Length(n), vDSP_Length(taps.count))
        return (0..<n).map { DSPComplex(real: outRe[$0], imag: outIm[$0]) }
    }

    /// The noise floor of a line strength over `symbolCount` symbols: the largest of about 4 × count bins of
    /// random phases' spectrum, √(ln(4 count) / count).
    var floor: Double { (log(4 * Double(symbolCount)) / Double(symbolCount)).squareRoot() }

    /// The smallest n of 2, 4, 8 whose line is strong: at least `threshold` and 1.8 × the noise floor, when
    /// s¹'s (a carrier) isn't.
    func order(threshold: Double) -> Int? {
        let strong = max(threshold, 1.8 * floor)
        guard (powerLines[1] ?? 1) < strong else { return nil }
        return [2, 4, 8].first { (powerLines[$0] ?? 0) >= strong }
    }

    /// |Σ e^{jnθ_k} e^{−j2πfk}| / count at the strongest f (zero-padded 4 ×): the symbols' phases only, so a
    /// few noisy symbols' magnitudes (raised to the 8th power) don't swamp it.
    static func lineStrength(_ re: [Float], _ im: [Float], power n: Int) -> Double {
        let m = re.count
        let size = FFT.size(atLeast: 4 * m)
        var xr = [Float](repeating: 0, count: size), xi = [Float](repeating: 0, count: size)
        var norm = 0.0
        for k in 0..<m {
            let angle = Double(n) * atan2(Double(im[k]), Double(re[k]))
            let weight = Double(re[k] * re[k] + im[k] * im[k])
            xr[k] = Float(weight * cos(angle))
            xi[k] = Float(weight * sin(angle))
            norm += weight
        }
        guard norm > 0 else { return 0 }
        FFT.transform(&xr, &xi)
        var best: Float = 0
        for k in 0..<size { best = max(best, xr[k] * xr[k] + xi[k] * xi[k]) }
        return Double(best).squareRoot() / norm
    }
}
