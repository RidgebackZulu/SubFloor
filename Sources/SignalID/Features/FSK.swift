import Accelerate
import DSPCore
import Foundation

/// n-FSK and MFSK measured from a channel's instantaneous frequency, without demodulating it:
/// 1. **Frequency.** Products z[k]·z*[k−d] with the longest lag that stays unambiguous (d ≈ 0.8 × rate / B,
///    B the occupied width: a heavily oversampled channel turns too little phase in one sample to rise over
///    the noise), less the noise's own share (which points at 0 Hz and would pull every tone in by its share
///    of the power: 10% at 10 dB).
/// 2. **Symbol rate.** The frequency, smoothed (the products summed over a span), changes most at the symbol
///    boundaries where the tone changes, so the spectrum of its squared change has a line at the symbol rate.
///    Spans of 1, 4 and 16 / B are tried (a slow MFSK's line only stands out of the noise when smoothed;
///    each span only for rates whose symbols are 4 spans or more), and the strongest line between B / 150 and
///    1.3 B over its continuum kept. Segments (a TDMA signal's bursts) are transformed separately and their
///    spectra summed. A harmonic can win by chance (MFSK16's sharp boundaries make its second as strong as
///    its first), so the rate is the lowest of the line and its sub-multiples (½, ⅓, ¼, when they are lines
///    too: 8 × their continuum and a quarter of its contrast) whose symbols each hold one tone, steps 3–4
///    being run for each in turn: the symbols must sit on a grid, and each symbol window's two halves must
///    agree (correlation ≥ 0.5; a harmonic's half-symbols hold one tone as well, but a sub-multiple's double
///    symbols straddle two, and a DFT peak lands on one of them, so the grid alone can't tell).
///    `CyclicTiming` refines the rate and follows the boundaries.
/// 3. **Symbols.** A long symbol's frequency (32 samples or more) is the peak of its middle 60%'s spectrum
///    (`SymbolSpectrum`: a filter bank matched to a steady tone, which lag products aren't when the channel's
///    noise is far wider than one tone, as in MFSK). A short one's is its phase advance over the whole symbol
///    (the discriminator summed): its noise comes only from the two ends, which neighbours share, and it is
///    linear in the tones, so a Gaussian pulse's interference is exactly a neighbour's share. (The wrapped
///    angle between the ends was tried: C4FM's outer tones turn 0.4 of a cycle a symbol, and at 10 dB the
///    noise wraps 2% of them a whole cycle, which spoils the spread below by 10–20%.)
///    Neighbouring symbols' share (a Gaussian pulse's, the channel filter's) is taken out blind from their
///    correlation (`equalised`).
/// 4. **Tone grid.** Two ways:
///    - a scan: the largest s at which the symbols sit on a grid, a local maximum, at least 0.7, of
///      |mean e^{j2πf/s}| (s up to 1.15 × the frequencies' span). Grid positions holding symbols are the tones
///      seen; the count is the next power of two at or above their span (alphabets carry whole bits; 3 s of
///      MFSK16 is 47 symbols, which leave some of its 16 tones unseen), an isolated stray position at either
///      end left out. This is what finds MFSK;
///    - when the scan finds none, for 2, 4 or 8 tones, an equally spaced Gaussian mixture fitted by EM
///      (`ToneMixture`), the count chosen by BIC (a single Gaussian competing): at 10 dB a 4800 Bd 4-FSK's
///      symbols scatter by 0.4 of the spacing, which blurs the scan's grid but leaves the mixture's tones
///      apart. Its grid must also show in the values (see below).
///    The spacing is refined by least squares on the symbols whose neighbours share their tone, when there are
///    enough of them, and on all the symbols otherwise. For short symbols it comes from the symbols' spread
///    instead (var f + 2 cov(f_k, f_k+1), in which the noise cancels; see below): at 10 dB C4FM's symbols
///    can't be told apart one by one, but 14 000 of them pin down their spread.
struct FSKFeatures {
    static let minRateFraction = 1.0 / 150
    static let maxRateFraction = 1.3
    static let minConcentration = 0.7
    static let maxResidual = 0.25
    static let minSettled = 24
    static let minOnGrid = 0.8
    /// The rate line's transform: at most 2¹⁸ points (a segment longer than that is cut; the timing refines
    /// the rate anyway).
    static let maxLineFFT = 1 << 18
    static let maxTones = 64
    static let scanStep = 0.99
    /// Below this the rate line is noise: the rest isn't worked out.
    static let minLineContrast = 4.0
    static let smoothingMultiples = [1, 4, 16]
    static let minSubmultipleContrast = 8.0
    static let minHalfAgreement = 0.5
    /// A long symbol's window: its middle 60%.
    static let window = 0.2...0.8
    /// Symbols shorter than this (in samples) are measured by their phase advance.
    static let shortSymbolSamples = 32.0

    var symbolRate = 0.0
    /// The rate line over its continuum.
    var lineContrast = 0.0
    var spacingHz = 0.0
    /// How cleanly the symbols sit on the grid: the scan's |mean e^{j2πf/s}|, or for the mixture
    /// exp(−2π² σ² / s²), the same quantity for its Gaussian scatter.
    var concentration = 0.0
    /// The symbols' scatter about their tones over the spacing: the mixture's σ / s, or for the scan the σ / s
    /// of a Gaussian scatter with its concentration.
    var scatter = 0.0
    /// The grid positions seen, in Hz from the channel's centre.
    var tones: [Double] = []
    var toneCount = 0
    var symbolCount = 0
    /// Fraction of the symbols within `maxResidual` spacings of a grid position (the scan), or within the
    /// mixture's ±2.5 σ.
    var onGrid = 0.0
    /// Fraction of neighbouring symbols on different tones (random 2-FSK: ½; a tone sampled at twice its own
    /// frequency, which an FM tone's rate line invites: 1).
    var alternation = 0.0
    /// Neighbouring symbols' share in each symbol's frequency (g₁ / g₀; about 0.05 for C4FM's Gaussian BT 0.5).
    var isi = 0.0
    /// Correlation of each symbol window's two halves' frequencies: high when the window holds one symbol, about
    /// 0 when a wrong (sub-multiple) rate makes it straddle independent ones.
    var halfAgreement = 0.0

    /// `segments` are where the signal is on (the whole channel for a continuous one). `noisePower` is the
    /// channel's noise power, `noiseCorrelation(d)` its correlation d samples apart, and `signalPower` the
    /// signal's.
    init?(_ z: [DSPComplex], rate: Double, occupiedHz: Double, segments: [Range<Int>], noisePower: Double = 0,
          signalPower: Double = 0, noiseCorrelation: (Int) -> Double = { _ in 0 }) {
        let n = z.count
        guard n > 256, occupiedHz > 0 else { return nil }
        let lag = max(1, Int(0.8 * rate / occupiedHz))
        var (pr, pi) = Self.lagProducts(z, lag: lag)
        var bias = -Float(noisePower * noiseCorrelation(lag))
        vDSP_vsadd(pr, 1, &bias, &pr, 1, vDSP_Length(n))
        let frequencyRate = rate / Double(lag)
        let lo = Self.minRateFraction * occupiedHz
        let hi = min(Self.maxRateFraction * occupiedHz, 0.45 * rate)

        // The rate line at each smoothing span; the strongest kept.
        let base = max(1, Int((rate / occupiedHz).rounded()))
        var best: (line: SpectralLine, candidates: [SpectralLine], g: [Float], inside: [Range<Int>])?
        for multiple in Self.smoothingMultiples {
            let half = base * multiple / 2
            let top = multiple == 1 ? hi : min(hi, rate / (4 * Double(2 * half + 1)))
            let a = max(1, half)
            let inside = segments.compactMap { s -> Range<Int>? in
                let r = max(s.lowerBound, a + lag)..<min(s.upperBound, n - a)
                return r.count >= 64 ? r : nil
            }
            guard let longest = inside.map(\.count).max() else { continue }
            let bottom = max(lo, 8 * rate / Double(longest))
            guard bottom < top else { continue }
            let f = Self.frequency(Self.movingSum(pr, half: half), Self.movingSum(pi, half: half), rate: frequencyRate)
            let g = Self.squaredChange(f, over: a)
            guard let lines = Self.rateLines(g, rate: rate, in: bottom...top, segments: inside),
                  lines.strongest.contrast > (best?.line.contrast ?? 0) else { continue }
            best = (lines.strongest, lines.candidates, g, inside)
        }
        guard let best, best.line.contrast >= Self.minLineContrast else { return nil }
        // The symbol rate is the lowest of the line and its sub-multiples whose symbols each sit on one tone
        // (a harmonic's half-symbols do too, but a sub-multiple's double symbols straddle two tones).
        var strongest: FSKFeatures?
        for candidate in best.candidates.sorted(by: { $0.hz < $1.hz }) {
            guard let measured = FSKFeatures(z, rate: rate, occupiedHz: occupiedHz, line: candidate, g: best.g,
                                             segments: best.inside, lag: lag,
                                             noisePower: noisePower, signalPower: signalPower) else { continue }
            if measured.onGrid >= Self.minOnGrid && measured.scatter <= ToneMixture.maxScatter
                && measured.halfAgreement >= Self.minHalfAgreement {
                self = measured
                return
            }
            if candidate.hz == best.line.hz { strongest = measured }
        }
        guard let strongest else { return nil }
        self = strongest
    }

    /// The symbols, grid and tones at the rate of `line` (see the type's notes).
    private init?(_ z: [DSPComplex], rate: Double, occupiedHz: Double, line: SpectralLine, g: [Float],
                  segments: [Range<Int>], lag: Int, noisePower: Double,
                  signalPower: Double) {
        let n = z.count
        lineContrast = line.contrast
        let timing = CyclicTiming(g, rate: rate, hz: line.hz, segments: segments)
        symbolRate = timing.hz
        let period = rate / symbolRate

        // Each symbol's frequency (the products and g are centred d/2 samples back, so the boundaries sit d/2
        // before the epochs): a long symbol's from its middle 60%'s spectrum; a short one's from its phase
        // advance (the discriminator summed over the whole symbol).
        let short = period < Self.shortSymbolSamples
        let length = short ? max(2, Int(period.rounded()))
            : max(2, Int(((Self.window.upperBound - Self.window.lowerBound) * period).rounded()))
        let offset = short ? 0 : Self.window.lowerBound
        let peaks = short ? nil : SymbolSpectrum(length: length, rate: rate, limitHz: 0.6 * occupiedHz)
        let halfPeaks = short ? nil : SymbolSpectrum(length: length / 2, rate: rate, limitHz: 0.6 * occupiedHz)
        let advance = short ? OccupiedWidth.prefixSums(FrequencyFeatures.discriminator(z, rate: rate).map(Double.init))
            : []
        var frequencies: [Double] = []
        var halves: [(Double, Double)] = []
        var times: [Double] = []
        for (epoch, chunk) in timing.instants(at: 0, margin: 0) {
            let b = epoch - Double(lag) / 2
            let from = Int((b + offset * period).rounded()) + (short ? 1 : 0)
            guard from >= 1, from + length <= n, chunk.contains(from), chunk.contains(from + length - 1)
            else { continue }
            let middle = from + length / 2
            if let peaks, let halfPeaks {
                guard let f = peaks.frequency(z, from: from), let first = halfPeaks.frequency(z, from: from),
                      let second = halfPeaks.frequency(z, from: middle) else { continue }
                frequencies.append(f)
                halves.append((first, second))
            } else {
                frequencies.append((advance[from + length] - advance[from]) / Double(length))
                halves.append(((advance[middle] - advance[from]) / Double(middle - from),
                               (advance[from + length] - advance[middle]) / Double(from + length - middle)))
            }
            times.append(b)
        }
        halfAgreement = Self.correlation(halves)
        // The phase advance's noise: its two ends' phase noise, N / (2 S) each.
        let noiseVariance = short && signalPower > 0
            ? noisePower / signalPower * pow(rate / (2 * .pi * Double(length)), 2) : 0
        symbolCount = frequencies.count
        guard symbolCount >= 16 else { return nil }
        let adjacent = (0..<(symbolCount - 1)).map { abs(times[$0 + 1] - times[$0] - period) < 0.25 * period }
        let (values, ratio) = Self.equalised(frequencies, adjacent: adjacent, noiseVariance: noiseVariance)
        isi = ratio

        // The grid: the scan, or the mixture when the scan finds none.
        var index: [Double]
        var on: [Bool]
        var gridTones: Int?
        if let grid = Self.grid(values), let scanned = Self.positions(values, grid) {
            spacingHz = grid.spacing
            var count = 2
            while count < (scanned.max()! - scanned.min()! + 1) { count *= 2 }
            gridTones = count
            concentration = grid.concentration
            scatter = (-log(max(grid.concentration, 1e-9)) / (2 * .pi * .pi)).squareRoot()
            index = values.map { (($0 - grid.offset) / grid.spacing).rounded() }
            on = zip(values, index).map { abs($0 - grid.offset - $1 * grid.spacing) <= Self.maxResidual * grid.spacing }
        } else if let mixture = ToneMixture.best(values) {
            spacingHz = mixture.spacing
            scatter = mixture.sigma / mixture.spacing
            gridTones = mixture.tones
            let first = mixture.centre - Double(mixture.tones - 1) / 2 * mixture.spacing
            // The grid must show in the values themselves: a smooth distribution (uniform, an FM tone's
            // arcsine) is fitted by a mixture with σ about 0.29 s too, but has no modulation at s.
            var re = 0.0, im = 0.0
            for v in values {
                re += cos(2 * .pi * (v - first) / mixture.spacing)
                im += sin(2 * .pi * (v - first) / mixture.spacing)
            }
            concentration = (re * re + im * im).squareRoot() / Double(symbolCount)
            guard concentration >= max(0.5 * exp(-2 * .pi * .pi * scatter * scatter),
                                       4 / Double(symbolCount).squareRoot()) else { return nil }
            index = values.map { min(Double(mixture.tones - 1), max(0, (($0 - first) / mixture.spacing).rounded())) }
            on = zip(values, index).map { abs($0 - first - $1 * mixture.spacing) <= 2.5 * mixture.sigma }
        } else {
            return nil
        }
        onGrid = Double(on.filter { $0 }.count) / Double(symbolCount)
        var changes = 0, pairs = 0
        for k in 0..<(symbolCount - 1) where adjacent[k] && on[k] && on[k + 1] {
            pairs += 1
            if index[k] != index[k + 1] { changes += 1 }
        }
        alternation = pairs > 0 ? Double(changes) / Double(pairs) : 0
        let settled = (1..<max(1, symbolCount - 1)).filter { (k: Int) -> Bool in
            let joined = adjacent[k - 1] && adjacent[k] && on[k]
            return joined && index[k - 1] == index[k] && index[k + 1] == index[k]
        }
        // The settled symbols' own frequencies when there are enough of them; else the equalised ones.
        let useSettled = Set(settled.map { index[$0] }).count >= 2 && settled.count >= Self.minSettled
        let fitted = useSettled ? settled : (0..<symbolCount).filter { on[$0] }
        let fitValues = useSettled ? frequencies : values
        guard var fit = Self.line(fitted.map { index[$0] }, fitted.map { fitValues[$0] }), fit.slope > 0 else {
            return nil
        }
        // Short symbols at low SNR scatter too far for their tones to be told one by one; their spread isn't.
        // With f_k = g₁ t_k−1 + g₀ t_k + g₁ t_k+1 (g₀ + 2g₁ = 1) and noise only in the ends, which neighbours
        // share: var f = (g₀² + 2g₁²) var t + n and cov(f_k, f_k+1) = 2g₀g₁ var t − n/2, so
        // var f + 2 cov = (1 − 2g₁²) var t whatever the noise n, and only second order in the interference.
        // var t over the tones' second moment in spacings, (n² − 1) / 12 for n tones equally used (as random or
        // scrambled data uses them: at 10 dB the mixture's own weights are too loose for this), is the spacing².
        if short, let tones = gridTones {
            let mean = frequencies.reduce(0, +) / Double(symbolCount)
            var variance = 0.0, covariance = 0.0, pairs = 0
            for k in 0..<symbolCount {
                variance += (frequencies[k] - mean) * (frequencies[k] - mean)
                if k < symbolCount - 1 && adjacent[k] {
                    covariance += (frequencies[k] - mean) * (frequencies[k + 1] - mean)
                    pairs += 1
                }
            }
            let g1 = isi / (1 + 2 * isi)
            let spread = (variance / Double(symbolCount) + 2 * covariance / Double(max(pairs, 1))) / (1 - 2 * g1 * g1)
            // The grid positions' middle, in the grid's own numbering (the scan's starts anywhere).
            let onGrid = (0..<symbolCount).filter { on[$0] }
            let centre = onGrid.reduce(0) { $0 + index[$1] } / Double(max(onGrid.count, 1))
            let moment = Double(tones * tones - 1) / 12
            if pairs >= 100, spread > 0 {
                let spacing = (spread / moment).squareRoot()
                fit = (spacing, mean - spacing * centre)
            }
        }
        spacingHz = fit.slope
        var counts: [Int: Int] = [:]
        for k in 0..<symbolCount where on[k] { counts[Int(index[k]), default: 0] += 1 }
        var seen = counts.keys.sorted()
        // An isolated stray position at either end (one symbol, two or more empty positions away).
        while seen.count > 2, counts[seen[0]] == 1, seen[1] - seen[0] > 2 { seen.removeFirst() }
        while seen.count > 2, counts[seen[seen.count - 1]] == 1, seen[seen.count - 1] - seen[seen.count - 2] > 2 {
            seen.removeLast()
        }
        guard let first = seen.first, let last = seen.last, last > first else { return nil }
        tones = (first...last).map { fit.intercept + fit.slope * Double($0) }
        var count = 2
        while count < tones.count { count *= 2 }
        toneCount = count
    }

    /// A clean n-FSK: a symbol-rate line standing `minContrast` over its continuum, symbols on a grid of 2 to
    /// 64 tones (Olivia's largest alphabet; HF fax's grey levels can pass for 128), 80% of them within reach
    /// of a tone and their scatter ≤ 0.45 spacing, and, for 2 tones, changing tone between 20% and 85% of the
    /// time (random data: half; a tone sampled at twice its frequency: always).
    func isFSK(minContrast: Double) -> Bool {
        (2...Self.maxTones).contains(toneCount) && lineContrast >= minContrast && onGrid >= Self.minOnGrid
            && scatter <= ToneMixture.maxScatter && (tones.count > 2 || (0.2...0.85).contains(alternation))
    }

    /// The strongest line of `g`'s spectrum in `range`, and the candidates for the rate: it and its
    /// sub-multiples (½, ⅓, ¼) within the range that are lines too: 8 × their continuum (which a chance bin of
    /// random data's continuum reaches once in 3000) and a quarter of the strongest's contrast (a fundamental
    /// its harmonic beat is still about as strong).
    static func rateLines(_ g: [Float], rate: Double, in range: ClosedRange<Double>,
                          segments: [Range<Int>]) -> (strongest: SpectralLine, candidates: [SpectralLine])? {
        guard let longest = segments.map(\.count).max() else { return nil }
        let size = min(FFT.size(atLeast: 2 * longest), Self.maxLineFFT)
        let power = FFT.power(g, segments: segments, size: size)
        let binHz = rate / Double(size)
        let guardBins = max(4, 2 * size / longest)
        guard let line = SpectralLine(power, binHz: binHz, in: range, guardBins: guardBins) else { return nil }
        var candidates = [line]
        for k in [2.0, 3.0, 4.0] {
            let target = line.hz / k
            guard target >= range.lowerBound else { continue }
            let k0 = max(1, Int(target * 0.98 / binHz)), k1 = min(power.count - 2, Int(target * 1.02 / binHz) + 1)
            guard k0 < k1, let top = (k0...k1).max(by: { power[$0] < power[$1] }),
                  let sub = SpectralLine(power, binHz: binHz, at: top, guardBins: guardBins),
                  sub.contrast >= max(minSubmultipleContrast, 0.25 * line.contrast) else { continue }
            candidates.append(sub)
        }
        return (line, candidates)
    }

    /// The grid the scan finds (see the type's notes): spacing, offset (a grid position) and concentration,
    /// or nil when there is none.
    static func grid(_ values: [Double]) -> (spacing: Double, offset: Double, concentration: Double)? {
        let sorted = values.sorted()
        let p2 = sorted[sorted.count / 50], p98 = sorted[sorted.count - 1 - sorted.count / 50]
        let span = p98 - p2
        guard span > 0 else { return nil }
        // A histogram (512 bins) stands in for the values in the scan.
        let lo = sorted.first!, hi = sorted.last!
        let bins = 512
        let width = max(hi - lo, 1e-9) / Double(bins)
        var histogram = [Double](repeating: 0, count: bins)
        for v in values { histogram[min(bins - 1, Int((v - lo) / width))] += 1 }
        let centres = (0..<bins).map { lo + (Double($0) + 0.5) * width }
        let used = histogram.indices.filter { histogram[$0] > 0 }
        func concentration(_ s: Double) -> Double {
            var re = 0.0, im = 0.0
            for b in used {
                let angle = 2 * Double.pi * centres[b] / s
                re += histogram[b] * cos(angle)
                im += histogram[b] * sin(angle)
            }
            return (re * re + im * im).squareRoot() / Double(values.count)
        }
        // Largest spacing first, 1% steps down to span / 128.
        var scan: [(s: Double, r: Double)] = []
        var s = 1.15 * span
        while s >= span / 128 && s > 2 * width {
            scan.append((s, concentration(s)))
            s *= Self.scanStep
        }
        guard scan.count >= 3 else { return nil }
        for i in 1..<(scan.count - 1) where scan[i].r >= minConcentration
            && scan[i].r >= scan[i - 1].r && scan[i].r >= scan[i + 1].r {
            // Refine on the values themselves (parabola through the three).
            let (a, b, c) = (scan[i - 1].r, scan[i].r, scan[i + 1].r)
            let curvature = a - 2 * b + c
            let shift = curvature < 0 ? min(0.5, max(-0.5, 0.5 * (a - c) / curvature)) : 0
            let spacing = scan[i].s * pow(Self.scanStep, shift)
            var re = 0.0, im = 0.0
            for v in values {
                re += cos(2 * .pi * v / spacing)
                im += sin(2 * .pi * v / spacing)
            }
            let offset = atan2(im, re) / (2 * .pi) * spacing
            return (spacing, offset, (re * re + im * im).squareRoot() / Double(values.count))
        }
        return nil
    }

    /// The grid positions holding symbols (within `maxResidual`), or nil when fewer than 2.
    static func positions(_ values: [Double], _ grid: (spacing: Double, offset: Double, concentration: Double))
        -> Set<Int>? {
        var seen = Set<Int>()
        for v in values {
            let i = ((v - grid.offset) / grid.spacing).rounded()
            if abs(v - grid.offset - i * grid.spacing) <= maxResidual * grid.spacing { seen.insert(Int(i)) }
        }
        return seen.count >= 2 ? seen : nil
    }

    /// The symbol frequencies with their neighbours' share taken out, blind: with independent symbols, the
    /// correlation of neighbouring symbols' frequencies, ρ₁, comes only from intersymbol interference (after
    /// the noise's share, `noiseVariance`, is taken out: of the variance, and of the covariance, where
    /// neighbouring phase advances share an end and so −½ of it). For f_k = g₀ t_k + g₁ (t_k−1 + t_k+1),
    /// ρ₁ = 2r / (1 + 2r²) with r = g₁ / g₀, and t_k ≈ (f_k − r (f_k−1 + f_k+1)) (1 + 2r) / (1 − 2r²) (the
    /// pulse's shares sum to 1). A missing neighbour counts as the mean. No change when ρ₁ is under 0.04
    /// (rectangular FSK) or under 3 / √pairs (MFSK16's 46 symbols can't measure it, and a wrong r moves its
    /// tones by their spacing); correlated data can't be told from interference, so r is at most 0.3. Returns
    /// the values and r.
    static func equalised(_ f: [Double], adjacent: [Bool], noiseVariance: Double = 0) -> ([Double], Double) {
        let n = f.count
        let mean = f.reduce(0, +) / Double(n)
        var c0 = 0.0, c1 = 0.0, pairs = 0
        for k in 0..<n {
            c0 += (f[k] - mean) * (f[k] - mean)
            if k < n - 1 && adjacent[k] {
                c1 += (f[k] - mean) * (f[k + 1] - mean)
                pairs += 1
            }
        }
        let signal = c0 / Double(n) - noiseVariance
        guard signal > 0, pairs > 0 else { return (f, 0) }
        // Neighbours share an end, so their noise runs against each other by half its variance.
        let covariance = c1 / Double(pairs) + noiseVariance / 2
        guard covariance / signal >= max(0.04, 3 / Double(pairs).squareRoot()) else { return (f, 0) }
        let rho = min(0.7, covariance / signal)
        let r = min(0.3, (1 - max(0, 1 - 2 * rho * rho).squareRoot()) / (2 * rho))
        let gain = (1 + 2 * r) / (1 - 2 * r * r)
        let values = (0..<n).map { k -> Double in
            let before = k > 0 && adjacent[k - 1] ? f[k - 1] : mean
            let after = k < n - 1 && adjacent[k] ? f[k + 1] : mean
            return mean + (f[k] - mean - r * (before + after - 2 * mean)) * gain
        }
        return (values, r)
    }

    /// Pearson correlation of pairs (0 when either side doesn't vary).
    static func correlation(_ pairs: [(Double, Double)]) -> Double {
        guard pairs.count >= 2 else { return 0 }
        let ma = pairs.reduce(0) { $0 + $1.0 } / Double(pairs.count)
        let mb = pairs.reduce(0) { $0 + $1.1 } / Double(pairs.count)
        var saa = 0.0, sbb = 0.0, sab = 0.0
        for (a, b) in pairs {
            saa += (a - ma) * (a - ma)
            sbb += (b - mb) * (b - mb)
            sab += (a - ma) * (b - mb)
        }
        return saa > 0 && sbb > 0 ? sab / (saa * sbb).squareRoot() : 0
    }

    /// Least-squares line y = intercept + slope · x, or nil when x doesn't vary.
    static func line(_ x: [Double], _ y: [Double]) -> (slope: Double, intercept: Double)? {
        guard x.count >= 2 else { return nil }
        let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
        var sxx = 0.0, sxy = 0.0
        for (a, b) in zip(x, y) {
            sxx += (a - mx) * (a - mx)
            sxy += (a - mx) * (b - my)
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        return (slope, my - slope * mx)
    }

    // MARK: Building blocks

    /// z[k] · z*[k − lag] as separate real and imaginary parts (the first `lag` repeat index `lag`).
    static func lagProducts(_ z: [DSPComplex], lag: Int = 1) -> (re: [Float], im: [Float]) {
        let n = z.count
        var re = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
        guard n > lag else { return (re, im) }
        z.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: Float.self, capacity: 2 * n) { x in
                re.withUnsafeMutableBufferPointer { r in
                    im.withUnsafeMutableBufferPointer { i in
                        var later = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: x + 2 * lag),
                                                    imagp: UnsafeMutablePointer(mutating: x + 2 * lag + 1))
                        var earlier = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: x),
                                                      imagp: UnsafeMutablePointer(mutating: x + 1))
                        var product = DSPSplitComplex(realp: r.baseAddress! + lag, imagp: i.baseAddress! + lag)
                        vDSP_zvmul(&earlier, 2, &later, 2, &product, 1, vDSP_Length(n - lag), -1)
                    }
                }
            }
        }
        for k in 0..<lag {
            re[k] = re[lag]
            im[k] = im[lag]
        }
        return (re, im)
    }

    /// Centred sums over ±`half` samples (the ends over what there is).
    static func movingSum(_ x: [Float], half: Int) -> [Float] {
        guard half > 0 else { return x }
        let n = x.count
        var prefix = [Double](repeating: 0, count: n + 1)
        for k in 0..<n { prefix[k + 1] = prefix[k] + Double(x[k]) }
        return (0..<n).map { Float(prefix[min(n, $0 + half + 1)] - prefix[max(0, $0 - half)]) }
    }

    /// The angle of (re, im) in Hz, one turn being `rate`.
    static func frequency(_ re: [Float], _ im: [Float], rate: Double) -> [Float] {
        var f = [Float](repeating: 0, count: re.count)
        var count = Int32(re.count)
        vvatan2f(&f, im, re, &count)
        var scale = Float(rate / (2 * .pi))
        vDSP_vsmul(f, 1, &scale, &f, 1, vDSP_Length(f.count))
        return f
    }

    /// (f[k + a] − f[k − a])², written at k (0 within `a` of the ends).
    static func squaredChange(_ f: [Float], over a: Int) -> [Float] {
        let n = f.count
        var g = [Float](repeating: 0, count: n)
        guard n > 2 * a else { return g }
        f.withUnsafeBufferPointer { p in
            g.withUnsafeMutableBufferPointer { out in
                let count = vDSP_Length(n - 2 * a)
                vDSP_vsub(p.baseAddress!, 1, p.baseAddress! + 2 * a, 1, out.baseAddress! + a, 1, count)
                vDSP_vsq(out.baseAddress! + a, 1, out.baseAddress! + a, 1, count)
            }
        }
        return g
    }
}

/// The frequency of a stretch of `length` samples: the peak of its spectrum (rectangular window, zero-padded
/// 8 ×, log-parabola through the peak) within ±`limitHz` of 0 Hz: a steady tone's maximum-likelihood
/// frequency.
struct SymbolSpectrum {
    let length: Int
    let size: Int
    let rate: Double
    let reach: Int
    private let setup: FFTSetup
    private let log2n: vDSP_Length

    init(length: Int, rate: Double, limitHz: Double) {
        self.length = length
        self.rate = rate
        size = FFT.size(atLeast: 8 * length)
        log2n = vDSP_Length(size.trailingZeroBitCount)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        reach = min(size / 2 - 2, max(2, Int(limitHz / (rate / Double(size)))))
    }

    func frequency(_ z: [DSPComplex], from: Int) -> Double? {
        var re = [Float](repeating: 0, count: size), im = [Float](repeating: 0, count: size)
        for k in 0..<length {
            re[k] = z[from + k].real
            im[k] = z[from + k].imag
        }
        var best = 0
        var power = [Float](repeating: 0, count: 2 * reach + 3)
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
        // Bins −reach−1 … reach+1 (FFT order: negative frequencies at the top).
        for j in 0..<power.count {
            let k = (j - reach - 1 + size) % size
            power[j] = re[k] * re[k] + im[k] * im[k]
        }
        for j in 1...(2 * reach + 1) where power[j] > power[best] || best == 0 { best = j }
        guard power[best] > 0 else { return nil }
        let a = log(Double(max(power[best - 1], 1e-30))), b = log(Double(power[best]))
        let c = log(Double(max(power[best + 1], 1e-30)))
        let curvature = a - 2 * b + c
        let shift = curvature < 0 ? min(0.5, max(-0.5, 0.5 * (a - c) / curvature)) : 0
        return (Double(best - reach - 1) + shift) * rate / Double(size)
    }
}

/// An equally spaced Gaussian mixture: 2, 4 or 8 tones a spacing apart, each blurred by the same noise,
/// fitted to symbol frequencies by EM on a 512-bin histogram (the positions a linear fit, the weights free).
/// Started from the quantiles at (k + ½) / tones (equiprobable tones' centres). `best` picks the count by
/// BIC against a single Gaussian (an FM signal's frequencies), among the fits whose tones stand apart
/// (σ ≤ 0.45 spacing: a 4800 Bd 4-FSK's at 10 dB reach 0.4; a smooth distribution's fit is caught by its
/// missing modulation at the spacing, in `FSKFeatures`) and each holds at least 0.3 / tones of the symbols.
struct ToneMixture {
    static let counts = [2, 4, 8]
    static let maxScatter = 0.45
    static let iterations = 40

    var tones: Int
    var centre: Double
    var spacing: Double
    var sigma: Double
    var weights: [Double]
    var logLikelihood: Double

    static func best(_ values: [Double]) -> ToneMixture? {
        let sorted = values.sorted()
        let n = sorted.count
        let lo = sorted[n / 1000], hi = sorted[n - 1 - n / 1000]
        guard hi > lo else { return nil }
        let pad = 0.1 * (hi - lo)
        let bins = 512
        let width = (hi - lo + 2 * pad) / Double(bins)
        var histogram = [Double](repeating: 0, count: bins)
        for v in values {
            let b = Int((v - lo + pad) / width)
            if b >= 0 && b < bins { histogram[b] += 1 }
        }
        let centres = (0..<bins).map { lo - pad + (Double($0) + 0.5) * width }
        let total = histogram.reduce(0, +)
        // A single Gaussian.
        let mean = zip(centres, histogram).reduce(0) { $0 + $1.0 * $1.1 } / total
        let variance = max(zip(centres, histogram).reduce(0) { $0 + ($1.0 - mean) * ($1.0 - mean) * $1.1 } / total,
                           width * width)
        var bestScore = 2 * Self.logLikelihood(centres, histogram, means: [mean], sigma: variance.squareRoot(),
                                               weights: [1]) - 2 * log(total)
        var best: ToneMixture?
        for tones in counts {
            guard let m = fit(centres, histogram, sorted: sorted, tones: tones), m.sigma <= maxScatter * m.spacing,
                  m.weights.allSatisfy({ $0 >= 0.3 / Double(tones) }) else { continue }
            let parameters = Double(tones + 2)
            let score = 2 * m.logLikelihood - parameters * log(total)
            guard score > bestScore else { continue }
            bestScore = score
            best = m
        }
        return best
    }

    static func fit(_ centres: [Double], _ histogram: [Double], sorted: [Double], tones: Int) -> ToneMixture? {
        let n = sorted.count
        let position = (0..<tones).map { Double($0) - Double(tones - 1) / 2 }
        let quantile = { (p: Double) in sorted[min(n - 1, Int(p * Double(n)))] }
        var centre = quantile(0.5)
        var spacing = (quantile(1 - 0.5 / Double(tones)) - quantile(0.5 / Double(tones))) / Double(tones - 1)
        guard spacing > 0 else { return nil }
        var sigma = spacing / 4
        var weights = [Double](repeating: 1 / Double(tones), count: tones)
        let total = histogram.reduce(0, +)
        var gamma = [Double](repeating: 0, count: tones)
        for _ in 0..<iterations {
            var sw = 0.0, swx = 0.0, swy = 0.0, swxx = 0.0, swxy = 0.0
            var mass = [Double](repeating: 0, count: tones)
            var assignments: [(b: Int, k: Int, w: Double)] = []
            assignments.reserveCapacity(histogram.count * tones)
            for (b, h) in histogram.enumerated() where h > 0 {
                var sum = 0.0
                for k in 0..<tones {
                    let d = (centres[b] - centre - position[k] * spacing) / sigma
                    gamma[k] = weights[k] * exp(-0.5 * d * d)
                    sum += gamma[k]
                }
                guard sum > 0 else { continue }
                for k in 0..<tones {
                    let w = h * gamma[k] / sum
                    guard w > 0 else { continue }
                    assignments.append((b, k, w))
                    mass[k] += w
                    sw += w
                    swx += w * position[k]
                    swy += w * centres[b]
                    swxx += w * position[k] * position[k]
                    swxy += w * position[k] * centres[b]
                }
            }
            let denominator = sw * swxx - swx * swx
            guard sw > 0, denominator > 0 else { return nil }
            spacing = (sw * swxy - swx * swy) / denominator
            centre = (swy - spacing * swx) / sw
            guard spacing > 0 else { return nil }
            var squares = 0.0
            for a in assignments {
                let d = centres[a.b] - centre - position[a.k] * spacing
                squares += a.w * d * d
            }
            sigma = max((squares / sw).squareRoot(), 1e-3 * spacing)
            weights = mass.map { $0 / total }
        }
        let means = position.map { centre + $0 * spacing }
        return ToneMixture(tones: tones, centre: centre, spacing: spacing, sigma: sigma, weights: weights,
                           logLikelihood: logLikelihood(centres, histogram, means: means, sigma: sigma,
                                                        weights: weights))
    }

    /// Σ h log(Σ w N(x; μ, σ)) over the histogram (the bin width's constant left out: it is the same for every
    /// model on the same histogram).
    static func logLikelihood(_ centres: [Double], _ histogram: [Double], means: [Double], sigma: Double,
                              weights: [Double]) -> Double {
        var sum = 0.0
        let norm = 1 / (sigma * (2 * Double.pi).squareRoot())
        for (b, h) in histogram.enumerated() where h > 0 {
            var p = 0.0
            for (m, w) in zip(means, weights) {
                let d = (centres[b] - m) / sigma
                p += w * norm * exp(-0.5 * d * d)
            }
            sum += h * log(max(p, 1e-300))
        }
        return sum
    }
}

/// A subcarrier inside a demodulated signal (an FM signal's instantaneous frequency, an AM signal's envelope):
/// AFSK (APRS's Bell 202 in NFM), MSK audio (ACARS in AM), or a steady tone (NOAA APT's 2400 Hz).
///
/// The audio's spectrum, less its noise, must be band-pass: 5% of its power below f₅ and f₅ at least 0.3 × the
/// median frequency (an FSK signal's own frequency is a baseband pulse train, strongest near 0 Hz). Then:
/// - a line standing 15 dB over the bins ±3–4 beside it and holding ≥ 10% of the audio's power is a tone
///   subcarrier;
/// - otherwise the band (f₅…f₉₅, half as wide again: about its −20 dB width) is mixed to 0 Hz and measured as
///   FSK (`FSKFeatures`): a clean one
///   (`isFSK`, its rate line 8 × its continuum) at a rate of at least a twentieth of the band (a few tones,
///   as AFSK and MSK audio have) gives its tones, in audio Hz, and its rate.
struct Subcarrier {
    static let size = 2048
    static let minBandPass = 0.3
    static let lineContrastDb = 15.0
    static let minLineFraction = 0.1
    static let minLineContrast = 8.0
    static let bandWidening = 1.5

    var tonesHz: [Double] = []
    var symbolRate: Double?
    var fsk: FSKFeatures?

    /// `noiseDensity(f)` is the noise's two-sided density in the audio at f (Hz² / Hz for a frequency).
    init?(audio: [Float], rate: Double, noiseDensity: (Double) -> Double) {
        guard audio.count > Self.size * 4 else { return nil }
        var mean: Float = 0
        vDSP_meanv(audio, 1, &mean, vDSP_Length(audio.count))
        let x = audio.map { DSPComplex(real: $0 - mean, imag: 0) }
        let p = PowerSpectrum.averagePower(x, size: Self.size, maxFrames: 256, hop: Self.size / 4)
        let binHz = rate / Double(Self.size)
        let top = Int(0.45 * rate / binHz)
        guard top > 16 else { return nil }
        // Positive frequencies (both halves of a real signal's spectrum are alike), less the noise.
        let raw = (0...top).map { Double(p[Self.size / 2 + $0]) }
        let signal = (0...top).map { k in max(0, raw[k] - noiseDensity(Double(k) * binHz) * binHz * SpectrumView.enbw) }
        let total = signal.dropFirst().reduce(0, +)
        guard total > 0 else { return nil }
        var cumulative = 0.0
        var f5 = 0.0, f50 = 0.0, f95 = 0.0
        for k in 1...top {
            cumulative += signal[k]
            let hz = Double(k) * binHz
            if f5 == 0 && cumulative >= 0.05 * total { f5 = hz }
            if f50 == 0 && cumulative >= 0.5 * total { f50 = hz }
            if f95 == 0 && cumulative >= 0.95 * total { f95 = hz }
        }
        guard f5 >= Self.minBandPass * f50, f95 > f5 else { return nil }
        // A steady tone.
        let peak = (1...top).max { raw[$0] < raw[$1] }!
        if peak >= 5 && peak + 4 <= top {
            let beside = (raw[peak - 4] + raw[peak - 3] + raw[peak + 3] + raw[peak + 4]) / 4
            let lobe = (peak - 2...peak + 2).reduce(0) { $0 + signal[$1] }
            if raw[peak] >= beside * pow(10, Self.lineContrastDb / 10) && lobe >= Self.minLineFraction * total {
                let line = SpectralLine(p.suffix(from: Self.size / 2).map { $0 }, binHz: binHz, at: peak)
                tonesHz = [line?.hz ?? Double(peak) * binHz]
                return
            }
        }
        // FSK in the band.
        // f₅…f₉₅ holds 90% of the power: the band's −20 dB width is about half as much again.
        let centre = (f5 + f95) / 2
        let width = Self.bandWidening * (f95 - f5)
        guard centre > 0.6 * width else { return nil }
        let band = Channel.extract(SignalMeasurer.interleaved(x), sampleRate: rate, offsetHz: centre,
                                   bandwidthHz: width)
        guard let fsk = FSKFeatures(band.samples, rate: band.rate, occupiedHz: width,
                                    segments: [0..<band.samples.count]),
              fsk.isFSK(minContrast: Self.minLineContrast), fsk.symbolRate >= (f95 - f5) / 20 else { return nil }
        self.fsk = fsk
        tonesHz = fsk.tones.map { centre + $0 }
        symbolRate = fsk.symbolRate
    }
}
