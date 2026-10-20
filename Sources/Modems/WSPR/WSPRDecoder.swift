import Accelerate
import DSPCore
import Foundation

/// WSPR slot decoding: every Type 1 message in a 2-minute slot of 12 kHz box audio.
public enum WSPRModem: SlotModem {
    public static let id: ModeID = .wspr
    public static let slotSeconds = 120.0

    /// Decodes one slot. Messages read `"K1ABC FN42 37"`; `frequencyHz` is the signal's centre at
    /// mid-transmission (as `WSPREncoder` places it), `timeOffset` the start of the transmission less
    /// the nominal 1 s, and `snrDb` is in 2.5 kHz.
    public static func decode(samples: [Float], sampleRate: Double, slotStart: Date,
                              audioBand: ClosedRange<Double>) -> [SlotDecode] {
        WSPRDecoder.decode(samples: samples, sampleRate: sampleRate, audioBand: audioBand).map {
            SlotDecode(mode: .wspr, slotStart: slotStart, frequencyHz: $0.frequencyHz, snrDb: $0.snrDb,
                       timeOffset: $0.timeOffset, message: $0.message)
        }
    }
}

/// One decoded WSPR transmission, with the demodulator's measurements.
struct WSPRDetection: Sendable, Equatable {
    var call: String
    var grid: String
    var powerDbm: Int
    /// Audio frequency of the signal's centre at mid-transmission.
    var frequencyHz: Double
    /// Frequency change over the transmission (symbol 0 to symbol 161).
    var driftHz: Double
    /// Start of the transmission relative to the nominal 1 s into the slot.
    var timeOffset: Double
    /// SNR in 2.5 kHz.
    var snrDb: Float
    /// Normalised sync correlation at the final alignment (about 0 for noise, 1 for a clean signal).
    var sync: Float
    /// Data-bit hard decisions that disagree with the decoded message, of 162.
    var bitErrors: Int
    /// Decoding pass (0 = before any subtraction).
    var pass: Int

    var message: String { "\(call) \(grid) \(powerDbm)" }
}

/// The WSPR demodulator, written from the public protocol description (`WSPRCodec`) and general
/// non-coherent FSK practice; no WSJT-X or wsprd source was read.
///
/// Pipeline, per decoding pass:
/// 1. **Downconvert** (once per slot): mix the slot audio down by 1500 Hz and decimate 12 kHz → 375 Hz
///    complex in two stages (×8 then ×4, Blackman-Harris low-passes, flat to ±160 Hz, nothing aliased
///    into ±220 Hz). One symbol is then 256 samples and the tone spacing 375/256 Hz is one bin of a
///    256-point DFT. Other input rates are first resampled to 12 kHz.
/// 2. **Spectrogram:** 256-sample (one symbol) rectangular frames at a quarter-symbol hop, zero-padded
///    to 512-point FFTs, so bins are half a tone spacing (0.73 Hz) apart and a frame aligned with a
///    symbol is that symbol's matched filter. The noise floor is the median of the slot-averaged
///    spectrum over the searched band.
/// 3. **Candidates:** in the slot-averaged spectrum, the summed power of a centre's four tone bins
///    (±0.73 and ±2.2 Hz), at local maxima within ±150 Hz of 1500 Hz and inside `audioBand`, whose
///    estimated SNR is above −33 dB. At most 40, strongest first.
/// 4. **Coarse sync** on the spectrogram: start time −1…+3 s after the nominal 1 s (quarter-symbol
///    steps), centre ±1.5 Hz (half-tone steps) and drift −2…+2 Hz over the transmission (0.5 Hz
///    steps), maximising the normalised correlation of the tone powers with the sync vector: per
///    symbol, the power in the two tones its sync bit allows less the power in the other two, summed
///    with the sync vector's sign and divided by the total power.
/// 5. **Fine sync** on the baseband itself: coordinate ascent over start (to 2 samples, 5 ms),
///    frequency (to 0.025 Hz) and drift (to 0.06 Hz) of the same correlation, the four tones of each
///    symbol measured by direct 256-sample DFTs at the drifted frequency.
/// 6. **Soft bits:** the sync bit fixes which two tones a symbol can be (`sync` for data 0,
///    `sync + 2` for data 1), so the data bit is decided between those two alone (the plan's
///    `(p2 + p3) − (p0 + p1)` also adds the noise of the two tones that cannot be sent). The metric is
///    the non-coherent log-likelihood ratio `ln I0(2√E·|X1|/N) − ln I0(2√E·|X0|/N)`, with the
///    symbol energy E measured from the sync and N the noise floor, and `WSPRFano` gets a metric table
///    matched to the LLRs' spread. Then deinterleave and decode. A failure with a convincing sync is
///    retried at four nearby alignments.
/// 7. **Validate:** `WSPRCodec.unpack` accepts only Type 1 messages with a plausible callsign, a
///    locator and a valid power level. The message is then re-encoded and the decode rejected unless
///    the hard decisions agree with its data bits well beyond chance. Before Fano runs, the sync
///    correlation must be clear of noise. (On pure noise Fano itself never completed within its
///    budget in 2000 trials; these checks guard against interference with structure.)
/// 8. **SNR:** the mean power in the sent tone of each symbol, less the noise floor, over the noise in
///    2.5 kHz (the bin noise times 2500 Hz / (375/256) Hz).
/// 9. **Subtract** every decoded signal from the baseband (each symbol's tone, with its measured
///    complex amplitude) and run another pass, up to three, while passes find new messages. This
///    uncovers weak signals next to strong ones.
enum WSPRDecoder {
    static let inputRate = 12_000.0
    static let basebandRate = 375.0
    static let centreHz = 1_500.0
    static let searchHalfWidthHz = 150.0
    /// Samples per symbol at the baseband rate.
    static let symbolLength = 256
    /// Spectrogram hop, a quarter symbol.
    static let hop = 64
    static let fftLength = 512
    static let log2FFT: vDSP_Length = 9
    static let toneSpacing = basebandRate / Double(symbolLength)
    static let binHz = basebandRate / Double(fftLength)
    static let symbolCount = WSPRCodec.symbolCount
    /// Baseband samples in a slot.
    static let slotLength = Int(WSPRModem.slotSeconds * basebandRate)
    /// Nominal start of a transmission within the slot.
    static let nominalStart = 1.0
    /// Searched start times relative to the nominal one.
    static let timeOffsetRange = -1.0...3.0
    /// Searched drift, total over the transmission, and its coarse step.
    static let maxDriftHz = 2.0
    static let driftStepHz = 0.5
    /// Candidates must reach this estimated SNR (2.5 kHz) in the slot-averaged spectrum. The plan's
    /// −30 dB lost half the signals at −29 dB (the estimate reads about 0.4 dB low, from the frames
    /// outside the transmission, ±0.6 dB). The largest noise peak of a slot is about −35.5 dB, so noise
    /// rarely makes a candidate, and one that it does make fails the sync.
    static let candidateSNRDb = -33.0
    static let maxCandidates = 40
    static let maxPasses = 3
    /// A decode needs at least this sync correlation. Noise reaches about 0.18 at the best fine
    /// alignment; signals at −30 dB show 0.26 and more.
    static let minSync: Float = 0.2
    /// A decode is rejected with more data-bit disagreements than this (of 162; real decodes at
    /// −30 dB show up to about 38).
    static let maxBitErrors = 44
    /// Fano search budget, in look-forward steps per information bit. A failed search costs about
    /// 75 ms on the x86 test harness; 100 000 decodes about 1 in 15 more signals at −30 dB, at three
    /// times the cost.
    static let fanoCycles = 30_000
    /// Sync correlation above which a failed decode is retried at nearby alignments, and the steps.
    static let retrySync: Float = 0.25
    static let retryStart = 8
    static let retryHz = 0.08
    /// 10·log10(2500 Hz / one tone bin's noise bandwidth).
    static let snrBandwidthDb = 10 * log10(2_500 / toneSpacing)

    /// Complex baseband at 375 Hz, sample m at slot time m/375 s.
    struct Baseband {
        var re: [Float]
        var im: [Float]
        var count: Int { re.count }
    }

    /// One sync hypothesis: start sample at 375 Hz, centre offset from 1500 Hz at mid-transmission,
    /// and drift over the transmission.
    struct Alignment: Equatable {
        var start: Int
        var frequency: Double
        var drift: Double
    }

    // MARK: - Slot decode

    static func decode(samples: [Float], sampleRate: Double, audioBand: ClosedRange<Double>) -> [WSPRDetection] {
        guard sampleRate > 0, sampleRate.isFinite, !samples.isEmpty else { return [] }
        let lo = max(audioBand.lowerBound, centreHz - searchHalfWidthHz)
        let hi = min(audioBand.upperBound, centreHz + searchHalfWidthHz)
        // The band must hold a signal (≈ 6 Hz) and enough bins for a noise floor.
        guard hi - lo >= 12 else { return [] }
        let audio = sampleRate == inputRate ? samples : resample(samples, from: sampleRate)
        var baseband = downconvert(audio)
        guard let setup = vDSP_create_fftsetup(log2FFT, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        let band = (lo - centreHz)...(hi - centreHz)
        var found: [WSPRDetection] = []
        for pass in 0..<maxPasses {
            let spectrogram = Spectrogram(baseband, setup: setup)
            guard let floor = spectrogram.noiseFloor(band: band) else { break }
            var fresh: [(WSPRDetection, Alignment)] = []
            for bin in spectrogram.candidates(band: band, floor: floor) {
                let fine = fineSync(baseband, from: coarseSync(spectrogram, bin: bin))
                guard band.contains(fine.frequency),
                      let (detection, alignment) = decode(baseband, near: fine, floor: floor, pass: pass),
                      !found.contains(where: { $0.message == detection.message }),
                      !fresh.contains(where: { $0.0.message == detection.message })
                else { continue }
                fresh.append((detection, alignment))
            }
            guard !fresh.isEmpty else { break }
            for (detection, alignment) in fresh {
                subtract(detection, at: alignment, from: &baseband)
                found.append(detection)
            }
        }
        return found.sorted { $0.frequencyHz < $1.frequencyHz }
    }

    /// Demodulates and decodes at `fine`. If that fails and the sync is clearly a signal's, it retries
    /// 8 samples (21 ms) earlier and later and 0.08 Hz lower and higher: near the threshold the sync
    /// estimate's own noise (some ±10 samples and ±0.05 Hz) costs decodes.
    static func decode(_ z: Baseband, near fine: Alignment, floor: Float, pass: Int) -> (WSPRDetection, Alignment)? {
        let p = tonePowers(z, at: fine)
        var attempts = [fine]
        if syncScore(p) >= retrySync {
            attempts += [Alignment(start: fine.start - retryStart, frequency: fine.frequency, drift: fine.drift),
                         Alignment(start: fine.start + retryStart, frequency: fine.frequency, drift: fine.drift),
                         Alignment(start: fine.start, frequency: fine.frequency - retryHz, drift: fine.drift),
                         Alignment(start: fine.start, frequency: fine.frequency + retryHz, drift: fine.drift)]
        }
        for a in attempts {
            if var d = demodulate(z, at: a, floor: floor) {
                d.pass = pass
                return (d, a)
            }
        }
        return nil
    }

    /// Resamples to 12 kHz.
    static func resample(_ samples: [Float], from rate: Double) -> [Float] {
        var resampler = FractionalResampler(inputRate: rate, outputRate: inputRate)
        var out: [Float] = []
        out.reserveCapacity(Int(Double(samples.count) * inputRate / rate) + 64)
        samples.withUnsafeBufferPointer { resampler.process($0, into: &out) }
        return out
    }

    // MARK: - Downconversion

    static let stage1Factor = 8
    static let stage2Factor = 4
    /// 12 kHz → 1.5 kHz: transition 160…1280 Hz (so nothing aliases into ±220 Hz).
    static let stage1Taps = FIRDesign.lowpass(taps: 65, cutoff: 720 / inputRate)
    /// 1.5 kHz → 375 Hz: transition 165…215 Hz.
    static let stage2Taps = FIRDesign.lowpass(taps: 181, cutoff: 190 / (inputRate / 8))

    /// Mixes 12 kHz audio down by `centreHz` and decimates to one slot of 375 Hz complex baseband
    /// (zero-padded or truncated to 120 s). Baseband sample m is centred on audio sample 32m. A real
    /// tone of amplitude A reads A/2.
    static func downconvert(_ audio: [Float]) -> Baseband {
        let t1 = stage1Taps.count, t2 = stage2Taps.count
        // Front padding that centres both filters, so output m sits on input sample 32m.
        let delay = (t1 - 1) / 2 + (t2 - 1) / 2 * stage1Factor
        let m2 = slotLength
        let m1 = (m2 - 1) * stage2Factor + t2
        let n = (m1 - 1) * stage1Factor + t1
        let copy = min(audio.count, n - delay)

        // Mix: x[n]·e^(−iωn), blocks of 64 samples from a renormalised block phasor times a table
        // of the rotations within a block.
        var re = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
        let w = -2 * Double.pi * centreHz / inputRate
        let blockLength = 64
        let tableRe = (0..<blockLength).map { Float(cos(w * Double($0))) }
        let tableIm = (0..<blockLength).map { Float(sin(w * Double($0))) }
        let stepRe = cos(w * Double(blockLength)), stepIm = sin(w * Double(blockLength))
        var pr = 1.0, pi = 0.0
        audio.withUnsafeBufferPointer { x in
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { q in
                    var start = 0
                    while start < copy {
                        let count = min(blockLength, copy - start)
                        let br = Float(pr), bi = Float(pi)
                        for j in 0..<count {
                            let v = x[start + j]
                            r[delay + start + j] = v * (br * tableRe[j] - bi * tableIm[j])
                            q[delay + start + j] = v * (br * tableIm[j] + bi * tableRe[j])
                        }
                        let nr = pr * stepRe - pi * stepIm
                        pi = pr * stepIm + pi * stepRe
                        let norm = (nr * nr + pi * pi).squareRoot()
                        pr = nr / norm
                        pi /= norm
                        start += count
                    }
                }
            }
        }
        var re1 = [Float](repeating: 0, count: m1), im1 = re1
        vDSP_desamp(re, stage1Factor, stage1Taps, &re1, vDSP_Length(m1), vDSP_Length(t1))
        vDSP_desamp(im, stage1Factor, stage1Taps, &im1, vDSP_Length(m1), vDSP_Length(t1))
        var re2 = [Float](repeating: 0, count: m2), im2 = re2
        vDSP_desamp(re1, stage2Factor, stage2Taps, &re2, vDSP_Length(m2), vDSP_Length(t2))
        vDSP_desamp(im1, stage2Factor, stage2Taps, &im2, vDSP_Length(m2), vDSP_Length(t2))
        return Baseband(re: re2, im: im2)
    }

    // MARK: - Spectrogram and candidates

    /// Power spectra of one-symbol frames at a quarter-symbol hop, 512 bins each, centred: bin b is
    /// (b − 256)·0.73 Hz from 1500 Hz. Unnormalised, so a frame on a symbol has that symbol's DFT
    /// power, the same scale as `toneSpectra`.
    struct Spectrogram {
        var power: [Float]
        var frames: Int
        static let bins = WSPRDecoder.fftLength
        static let centre = WSPRDecoder.fftLength / 2

        init(_ z: Baseband, setup: FFTSetup) {
            let n = WSPRDecoder.fftLength, frame = WSPRDecoder.symbolLength, hop = WSPRDecoder.hop
            frames = (z.count - frame) / hop + 1
            power = [Float](repeating: 0, count: frames * n)
            var re = [Float](repeating: 0, count: n), im = re
            var mags = [Float](repeating: 0, count: n)
            for t in 0..<frames {
                let start = t * hop
                re.withUnsafeMutableBufferPointer { rp in
                    im.withUnsafeMutableBufferPointer { ip in
                        for j in 0..<frame { rp[j] = z.re[start + j]; ip[j] = z.im[start + j] }
                        for j in frame..<n { rp[j] = 0; ip[j] = 0 }
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        vDSP_fft_zip(setup, &split, 1, WSPRDecoder.log2FFT, FFTDirection(kFFTDirection_Forward))
                        vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n))
                    }
                }
                // Swap halves so that bin 256 is 0 Hz.
                let row = t * n, half = n / 2
                for k in 0..<half {
                    power[row + half + k] = mags[k]
                    power[row + k] = mags[half + k]
                }
            }
        }

        static func bin(_ offsetHz: Double) -> Int { centre + Int((offsetHz / WSPRDecoder.binHz).rounded()) }
        static func offset(_ bin: Int) -> Double { Double(bin - centre) * WSPRDecoder.binHz }

        /// Slot-averaged power per bin.
        func average() -> [Float] {
            var avg = [Float](repeating: 0, count: Self.bins)
            for t in 0..<frames {
                let row = t * Self.bins
                for b in 0..<Self.bins { avg[b] += power[row + b] }
            }
            let k = 1 / Float(frames)
            return avg.map { $0 * k }
        }

        /// Bin indices covered by `band` (offsets from 1500 Hz).
        static func bins(in band: ClosedRange<Double>) -> ClosedRange<Int> {
            Int((band.lowerBound / WSPRDecoder.binHz).rounded(.up)) + centre
                ... Int((band.upperBound / WSPRDecoder.binHz).rounded(.down)) + centre
        }

        /// Median slot-averaged power of the bins in `band`: the noise power of one tone bin. Nil if
        /// the band is too narrow or the audio is silent.
        func noiseFloor(band: ClosedRange<Double>) -> Float? {
            let range = Self.bins(in: band)
            guard range.count >= 16, frames > 0 else { return nil }
            let values = average()[range].sorted()
            let median = values[values.count / 2]
            return median > 0 && median.isFinite ? median : nil
        }

        /// Centre bins of likely signals in `band`, strongest first: local maxima (over ±2 bins) of the
        /// four tone bins' summed average power whose SNR estimate reaches `candidateSNRDb`.
        func candidates(band: ClosedRange<Double>, floor: Float) -> [Int] {
            let avg = average()
            let range = Self.bins(in: band)
            var tones = [Float](repeating: 0, count: Self.bins)
            for b in (range.lowerBound - 2)...(range.upperBound + 2) {
                tones[b] = avg[b - 3] + avg[b - 1] + avg[b + 1] + avg[b + 3]
            }
            // (tones − 4·floor)/floor is the signal over one bin's noise; SNR adds −snrBandwidthDb.
            let minExcess = Float(pow(10, (WSPRDecoder.candidateSNRDb + WSPRDecoder.snrBandwidthDb) / 10))
            var found: [(bin: Int, power: Float)] = []
            for b in range {
                let p = tones[b]
                guard (p - 4 * floor) / floor >= minExcess else { continue }
                let isPeak = (1...2).allSatisfy { p > tones[b - $0] && p >= tones[b + $0] }
                if isPeak { found.append((b, p)) }
            }
            return found.sorted { $0.power > $1.power }.prefix(WSPRDecoder.maxCandidates).map(\.bin)
        }
    }

    /// The coarse alignment near candidate centre `bin`: the best sync correlation over start frames,
    /// centres within ±2 bins and drifts, on the spectrogram.
    static func coarseSync(_ s: Spectrogram, bin: Int) -> Alignment {
        let bins = Spectrogram.bins
        let lastFrame = s.frames - 1 - 4 * (symbolCount - 1)
        let firstStart = Int(((nominalStart + timeOffsetRange.lowerBound) * basebandRate / Double(hop)).rounded(.down))
        let lastStart = min(lastFrame,
                            Int(((nominalStart + timeOffsetRange.upperBound) * basebandRate / Double(hop)).rounded(.up)))
        let sync = WSPRCodec.syncVector
        var best = Alignment(start: max(0, firstStart) * hop, frequency: Spectrogram.offset(bin), drift: 0)
        guard lastStart >= max(0, firstStart) else { return best }
        var bestScore = -Float.infinity
        let driftSteps = Int((maxDriftHz / driftStepHz).rounded())
        s.power.withUnsafeBufferPointer { p in
            for di in -driftSteps...driftSteps {
                let drift = Double(di) * driftStepHz
                // Bin offset of symbol k for this drift.
                let shift = (0..<symbolCount).map { k in
                    Int((drift * (Double(k) - 80.5) / 161 / binHz).rounded())
                }
                for b in (bin - 2)...(bin + 2) {
                    for t in max(0, firstStart)...lastStart {
                        var num: Float = 0, den: Float = 0
                        for k in 0..<symbolCount {
                            let at = (t + 4 * k) * bins + b + shift[k]
                            let p0 = p[at - 3], p1 = p[at - 1], p2 = p[at + 1], p3 = p[at + 3]
                            let d = (p1 + p3) - (p0 + p2)
                            num += sync[k] == 1 ? d : -d
                            den += p0 + p1 + p2 + p3
                        }
                        let score = den > 0 ? num / den : 0
                        if score > bestScore {
                            bestScore = score
                            best = Alignment(start: t * hop, frequency: Spectrogram.offset(b), drift: drift)
                        }
                    }
                }
            }
        }
        return best
    }

    // MARK: - Fine sync and demodulation

    /// e^(−2πi·s·n/256) for tones s = 1…3, the DFT kernels of the upper three tones relative to tone 0.
    static let toneKernels: (re: [Float], im: [Float]) = {
        var re = [Float](repeating: 0, count: 3 * symbolLength), im = re
        for s in 1...3 {
            for n in 0..<symbolLength {
                let a = -2 * Double.pi * Double(s * n) / Double(symbolLength)
                re[(s - 1) * symbolLength + n] = Float(cos(a))
                im[(s - 1) * symbolLength + n] = Float(sin(a))
            }
        }
        return (re, im)
    }()

    /// Frequency offset of symbol k's centre for an alignment.
    @inline(__always) static func centre(_ a: Alignment, symbol k: Int) -> Double {
        a.frequency + a.drift * (Double(k) - 80.5) / 161
    }

    /// The four tones' DFTs of every symbol at `a`: `[k·4 + s]`, each Σ z[n]·e^(−iθn) over the
    /// symbol's 256 samples, θ the tone's frequency (samples outside the slot count as zero).
    static func toneSpectra(_ z: Baseband, at a: Alignment, re outRe: inout [Float], im outIm: inout [Float]) {
        let n = symbolLength, count = z.count
        let kernels = toneKernels
        z.re.withUnsafeBufferPointer { zr in
            z.im.withUnsafeBufferPointer { zi in
                kernels.re.withUnsafeBufferPointer { kr in
                    kernels.im.withUnsafeBufferPointer { ki in
                        for k in 0..<symbolCount {
                            let f0 = centre(a, symbol: k) - 1.5 * toneSpacing
                            let w = -2 * Double.pi * f0 / basebandRate
                            let rr = Float(cos(w)), ri = Float(sin(w))
                            var pr: Float = 1, pi: Float = 0
                            var x0r: Float = 0, x0i: Float = 0, x1r: Float = 0, x1i: Float = 0
                            var x2r: Float = 0, x2i: Float = 0, x3r: Float = 0, x3i: Float = 0
                            let base = a.start + k * n
                            let lo = max(0, -base), hi = min(n, count - base)
                            if lo < hi {
                                // Phasor at the first sample used.
                                if lo > 0 {
                                    let w0 = w * Double(lo)
                                    pr = Float(cos(w0)); pi = Float(sin(w0))
                                }
                                for j in lo..<hi {
                                    let ar = zr[base + j], ai = zi[base + j]
                                    let yr = ar * pr - ai * pi, yi = ar * pi + ai * pr
                                    x0r += yr; x0i += yi
                                    let c1r = kr[j], c1i = ki[j]
                                    x1r += yr * c1r - yi * c1i; x1i += yr * c1i + yi * c1r
                                    let c2r = kr[n + j], c2i = ki[n + j]
                                    x2r += yr * c2r - yi * c2i; x2i += yr * c2i + yi * c2r
                                    let c3r = kr[2 * n + j], c3i = ki[2 * n + j]
                                    x3r += yr * c3r - yi * c3i; x3i += yr * c3i + yi * c3r
                                    let npr = pr * rr - pi * ri
                                    pi = pr * ri + pi * rr
                                    pr = npr
                                }
                            }
                            outRe[4 * k] = x0r; outIm[4 * k] = x0i
                            outRe[4 * k + 1] = x1r; outIm[4 * k + 1] = x1i
                            outRe[4 * k + 2] = x2r; outIm[4 * k + 2] = x2i
                            outRe[4 * k + 3] = x3r; outIm[4 * k + 3] = x3i
                        }
                    }
                }
            }
        }
    }

    /// Tone powers `[k·4 + s]` at `a`.
    static func tonePowers(_ z: Baseband, at a: Alignment) -> [Float] {
        var re = [Float](repeating: 0, count: 4 * symbolCount), im = re
        toneSpectra(z, at: a, re: &re, im: &im)
        return (0..<(4 * symbolCount)).map { re[$0] * re[$0] + im[$0] * im[$0] }
    }

    /// Normalised sync correlation of tone powers.
    static func syncScore(_ p: [Float]) -> Float {
        let sync = WSPRCodec.syncVector
        var num: Float = 0, den: Float = 0
        for k in 0..<symbolCount {
            let p0 = p[4 * k], p1 = p[4 * k + 1], p2 = p[4 * k + 2], p3 = p[4 * k + 3]
            let d = (p1 + p3) - (p0 + p2)
            num += sync[k] == 1 ? d : -d
            den += p0 + p1 + p2 + p3
        }
        return den > 0 ? num / den : 0
    }

    /// Refines a coarse alignment on the baseband by coordinate ascent of the sync correlation: a
    /// frequency scan over the coarse bin's width, then ±steps of start, frequency and drift, halving
    /// the steps twice.
    static func fineSync(_ z: Baseband, from coarse: Alignment) -> Alignment {
        var best = coarse
        var bestScore = syncScore(tonePowers(z, at: coarse))
        func consider(_ a: Alignment) {
            let score = syncScore(tonePowers(z, at: a))
            if score > bestScore { bestScore = score; best = a }
        }
        for step in [-0.3, -0.2, -0.1, 0.1, 0.2, 0.3] {
            consider(Alignment(start: coarse.start, frequency: coarse.frequency + step, drift: coarse.drift))
        }
        var dt = 16, df = 0.1, dd = 0.25
        for _ in 0..<3 {
            var improved = true
            var rounds = 0
            while improved && rounds < 4 {
                improved = false
                rounds += 1
                let before = best
                for a in [Alignment(start: before.start - dt, frequency: before.frequency, drift: before.drift),
                          Alignment(start: before.start + dt, frequency: before.frequency, drift: before.drift),
                          Alignment(start: before.start, frequency: before.frequency - df, drift: before.drift),
                          Alignment(start: before.start, frequency: before.frequency + df, drift: before.drift),
                          Alignment(start: before.start, frequency: before.frequency, drift: before.drift - dd),
                          Alignment(start: before.start, frequency: before.frequency, drift: before.drift + dd)] {
                    consider(a)
                }
                improved = best != before
            }
            dt = max(2, dt / 4); df /= 2; dd /= 2
        }
        return best
    }

    /// Demodulates and decodes the transmission at `a`. `floor` is the noise power of one tone bin.
    static func demodulate(_ z: Baseband, at a: Alignment, floor: Float) -> WSPRDetection? {
        let p = tonePowers(z, at: a)
        let sync = syncScore(p)
        guard sync >= minSync else { return nil }
        let syncBits = WSPRCodec.syncVector
        var soft = [Float](repeating: 0, count: symbolCount)
        // Signal energy per symbol: allowed pair less the other pair (the noise cancels on average).
        var energy: Float = 0
        for k in 0..<symbolCount {
            let s = Int(syncBits[k])
            energy += p[4 * k + s] + p[4 * k + s + 2] - p[4 * k + 1 - s] - p[4 * k + 3 - s]
        }
        energy = max(energy / Float(symbolCount), floor * 0.05)
        let gain = 2 * energy.squareRoot() / floor
        for k in 0..<symbolCount {
            let s = Int(syncBits[k])
            soft[k] = Float(logI0(Double(gain * p[4 * k + s + 2].squareRoot()))
                            - logI0(Double(gain * p[4 * k + s].squareRoot())))
        }
        // `WSPRFano` scales its input to unit RMS and reads it as BPSK at the table's Eb/N0, whose LLR
        // per RMS unit is g = 2a/σ² with g² = 8e(1 + 2e), e = Es/N0. Choosing e for g = RMS(LLR)
        // makes the table's metric the exact Fano metric of these LLRs.
        let rms = (soft.reduce(0) { $0 + Double($1) * Double($1) } / Double(symbolCount)).squareRoot()
        let esN0 = (-1 + (1 + rms * rms).squareRoot()) / 4
        let table = WSPRFano.makeMetricTable(ebN0Db: 10 * log10(max(2 * esN0, 1e-3)), scale: WSPRFano.metricScale)
        guard let decoded = WSPRFano.decodeDetailed(softSymbols: WSPRCodec.deinterleave(soft),
                                                    maxCycles: fanoCycles, table: table),
              let message = WSPRCodec.unpack(decoded.bytes),
              let symbols = WSPRCodec.channelSymbols(call: message.call, grid: message.grid, powerDbm: message.powerDbm)
        else { return nil }
        var errors = 0
        var signal: Float = 0
        for k in 0..<symbolCount {
            let sent = Int(symbols[k])
            if (soft[k] > 0) != (sent >= 2) { errors += 1 }
            signal += p[4 * k + sent]
        }
        guard errors <= maxBitErrors else { return nil }
        let excess = max(signal / Float(symbolCount) - floor, floor * 1e-4)
        let snr = 10 * log10(Double(excess / floor)) - snrBandwidthDb
        return WSPRDetection(call: message.call, grid: message.grid, powerDbm: message.powerDbm,
                             frequencyHz: centreHz + a.frequency, driftHz: a.drift,
                             timeOffset: Double(a.start) / basebandRate - nominalStart,
                             snrDb: Float(snr), sync: sync, bitErrors: errors, pass: 0)
    }

    /// ln I0(x) for x ≥ 0.
    static func logI0(_ x: Double) -> Double {
        if x < 15 {
            let q = x * x / 4
            var term = 1.0, sum = 1.0
            for k in 1..<60 {
                term *= q / Double(k * k)
                sum += term
                if term < sum * 1e-12 { break }
            }
            return log(sum)
        }
        return x - 0.5 * log(2 * Double.pi * x) + log1p(1 / (8 * x) + 9 / (128 * x * x))
    }

    // MARK: - Subtraction

    /// Removes a decoded transmission from the baseband: in each symbol, the sent tone with the complex
    /// amplitude measured there (DFT / 256).
    static func subtract(_ d: WSPRDetection, at a: Alignment, from z: inout Baseband) {
        guard let symbols = WSPRCodec.channelSymbols(call: d.call, grid: d.grid, powerDbm: d.powerDbm) else { return }
        var re = [Float](repeating: 0, count: 4 * symbolCount), im = re
        toneSpectra(z, at: a, re: &re, im: &im)
        let n = symbolLength, count = z.count
        for k in 0..<symbolCount {
            let s = Int(symbols[k])
            let cr = re[4 * k + s] / Float(n), ci = im[4 * k + s] / Float(n)
            let f = centre(a, symbol: k) + (Double(s) - 1.5) * toneSpacing
            let w = 2 * Double.pi * f / basebandRate
            let base = a.start + k * n
            let lo = max(0, -base), hi = min(n, count - base)
            guard lo < hi else { continue }
            for j in lo..<hi {
                let ph = w * Double(j)
                let er = Float(cos(ph)), ei = Float(sin(ph))
                z.re[base + j] -= cr * er - ci * ei
                z.im[base + j] -= cr * ei + ci * er
            }
        }
    }
}
