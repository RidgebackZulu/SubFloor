import Accelerate
import CFT8
import DSPCore
import Foundation

/// FT8 slot decoding: every message in a 15 s slot of 12 kHz box audio, with the vendored ft8_lib.
public enum FT8Modem: SlotModem {
    public static let id: ModeID = .ft8
    public static let slotSeconds = 15.0

    /// Decodes one slot (`samples[0]` at the slot boundary). `frequencyHz` is the audio frequency of
    /// tone 0, the lowest of the eight tones (as WSJT-X and ft8_lib report FT8, and as `FT8Encoder`
    /// places it); `audioBand` bounds it. `timeOffset` is the start of the transmission less the
    /// nominal 0.5 s, and `snrDb` is in 2.5 kHz. Decodes are in order of frequency.
    public static func decode(samples: [Float], sampleRate: Double, slotStart: Date,
                              audioBand: ClosedRange<Double>) -> [SlotDecode] {
        FT8Decoder.decode(samples: samples, sampleRate: sampleRate, audioBand: audioBand).map {
            SlotDecode(mode: .ft8, slotStart: slotStart, frequencyHz: $0.frequencyHz, snrDb: $0.snrDb,
                       timeOffset: $0.timeOffset, message: $0.message)
        }
    }
}

/// One decoded FT8 transmission, with the measurements made after decoding.
struct FT8Detection: Sendable, Equatable {
    var message: String
    /// Audio frequency of tone 0.
    var frequencyHz: Double
    /// Start of the transmission relative to the nominal 0.5 s into the slot.
    var timeOffset: Double
    /// SNR in 2.5 kHz.
    var snrDb: Float
    /// ft8_lib's Costas sync score of the candidate it came from.
    var score: Int
    /// Which demodulation decoded it (see `FT8Decoder`).
    var method: FT8Decoder.Method
    var tones: [UInt8]
}

/// The FT8 decoder. ft8_lib finds the signals and does the forward error correction; Swift adds a
/// sharper demodulator in front of ft8_lib's LDPC decoder, and the measurements.
///
/// 1. **Candidates** (`cft8_slot_analyse`): ft8_lib's monitor builds a waterfall of the slot (Hann
///    windowed FFTs two symbols long, 80 ms × 3.125 Hz resolution, magnitudes in 0.5 dB steps) and
///    ranks up to 300 Costas sync candidates.
/// 2. **Sync**, per candidate: the slot's spectrum (one 2^18-point FFT) is cut to ±70 Hz around the
///    candidate (flat over ±40 Hz) and inverse-transformed to a 187.5 Hz complex baseband, 30 samples
///    per symbol, so each tone is one bin of a 30-point DFT. Coarse: the 21 Costas symbols' energy
///    over ±53 ms (5.3 ms steps) and ±1.5 Hz (0.5 Hz steps) around ft8_lib's estimate. Fine: FT8 is
///    phase-continuous, so the Costas symbols' complex amplitudes, phase-referenced to the start, add
///    coherently once the residual frequency offset is removed; their coherent sum is maximised over
///    ±2 samples and ±0.6 Hz in 0.02 Hz steps. (Coherent alignment matters: at −20 dB the energy
///    search alone left 0.3–0.8 Hz errors that lost half the decodes.)
/// 3. **Decode**, trying in turn until one gives a message that passes ft8_lib's LDPC (belief
///    propagation, 30 iterations), CRC-14 and unpacker (the all-zero codeword is rejected):
///    - `.ft8lib`: ft8_lib's own soft bits from its waterfall (`cft8_slot_decode`), as its demo
///      decoder does; this alone reaches about −18 dB (88% decoded) and 10% at −20 dB;
///    - `.single`, `.pairs`, `.triples`, for candidates whose sync quality (`minSyncQuality`) is not
///      noise-like: soft bits from the baseband's symbol DFTs at the sync: for each data symbol, or
///      each run of two or three consecutive data symbols taken coherently (the 64 or 512 tone
///      sequences' summed complex amplitudes), a bit's metric is the largest magnitude among the
///      sequences with that bit 1 less the largest with it 0, normalised to unit spread and scaled by
///      `softBitScale`. Longer runs help the weakest signals; shorter ones are robust to drift and
///      fading. With these, 92% decode at −20 dB and about 50% at −21 dB.
///    The demodulator is written from the FT8 protocol description (Franke, Somerville and Taylor,
///    "The FT4 and FT8 Communication Protocols", QEX, July/August 2020) and general non-coherent MFSK
///    practice; no WSJT-X source was consulted.
///    ft8_lib has no signal subtraction (its `monitor_resynth` is an unfinished experiment behind
///    `WATERFALL_USE_PHASE`), so there is a single pass, which the plan accepts.
/// 4. **Measure** each decode with its now known tones: start and tone-0 frequency maximise the
///    energy of all 79 sent tones on the baseband (0.025 Hz steps; parabolic interpolation in time).
///    Candidates near a decoded signal (±2 Hz, ±0.12 s) are skipped, and duplicate messages dropped.
/// 5. **Filter** to decodes whose tone 0 lies in `audioBand` (ft8_lib analyses the band plus the
///    eight tones' width, so signals at its top edge decode).
/// 6. **SNR** in 2.5 kHz: at full rate, the mean sent-tone energy of 1920-sample symbol DFTs less the
///    noise in a symbol bin, divided by the share of a clean GFSK signal's energy those DFTs capture
///    (measured on a synthesized copy of the same tones, about 0.9), over the noise power density
///    times 2500 Hz. The noise density is a low quantile (25%) of the slot-averaged spectrum in the
///    band (2048-point Hann FFTs), corrected to the mean, so other signals barely raise it.
///
/// Input at other rates is first resampled to 12 kHz; non-finite samples are zeroed (ft8_lib converts
/// waterfall dB values to integers, undefined for NaN).
enum FT8Decoder {
    enum Method: String, Sendable {
        case ft8lib, single, pairs, triples
    }

    static let rate = 12_000.0
    static let samplesPerSymbol = 1_920
    static let toneSpacing = FT8Encoder.toneSpacing
    static let symbolCount = FT8Encoder.toneCount
    static let nominalStart = FT8Encoder.startSeconds
    static let costas = [3, 1, 4, 0, 6, 5, 2]
    /// Tone of each 3-bit value (FT8's Gray code).
    static let gray = [0, 1, 3, 2, 5, 6, 4, 7]
    static let syncSymbols = Array(0..<7) + Array(36..<43) + Array(72..<79)
    /// The two halves of 29 data symbols.
    static let dataHalves = [Array(7..<36), Array(43..<72)]

    /// Most decodes kept per slot.
    static let maxDecodes = 100
    static let maxCandidates: Int32 = 300
    static let minScore: Int32 = 5
    static let ldpcIterations: Int32 = 30
    /// Candidates whose Costas symbols hold less of their energy in the sync tones than this are not
    /// demodulated further. Noise candidates read 0.20 (median) and exceed 0.25 in 3% of cases;
    /// signals at −22 dB read 0.27 and more (−20 dB: 0.35).
    static let minSyncQuality: Float = 0.25
    /// Soft-bit scale after normalising to unit spread, for ft8_lib's belief propagation. Tuned on
    /// seeds the tests do not use: 2.0 decoded 60% at −20 dB, 2.8 91%, 4.0 to 6.5 92% (and about 50%
    /// at −21 dB), 8.0 slightly fewer.
    static let softBitScale: Float = 5.0
    /// The analysed band reaches this far above `audioBand`, so tone 7 of a signal at its top is in it.
    static let toneWidthHz = 8 * toneSpacing
    /// Candidates this close to a decoded signal are skipped.
    static let nearDecodeHz = 2.0
    static let nearDecodeSeconds = 0.12
    /// Reported SNRs are clamped to this range (silence, or a signal far above the noise).
    static let snrRange: ClosedRange<Float> = -40...50

    static func decode(samples: [Float], sampleRate: Double, audioBand: ClosedRange<Double>) -> [FT8Detection] {
        guard sampleRate > 0, sampleRate.isFinite, !samples.isEmpty,
              audioBand.lowerBound.isFinite, audioBand.upperBound.isFinite else { return [] }
        var audio = sampleRate == rate ? samples : resample(samples, from: sampleRate)
        if audio.count > Spectrum.length { audio.removeLast(audio.count - Spectrum.length) }
        for i in audio.indices where !audio[i].isFinite { audio[i] = 0 }
        // ft8_lib reads FFT bin (2·bin + 1) for its top bin: stay a tone below Nyquist.
        let lo = max(audioBand.lowerBound, 0)
        let hi = min(audioBand.upperBound + toneWidthHz, rate / 2 - 2 * toneSpacing)
        guard lo <= audioBand.upperBound, hi - lo >= toneWidthHz else { return [] }

        guard let slot = audio.withUnsafeBufferPointer({
            cft8_slot_analyse($0.baseAddress, Int32($0.count), Int32(rate), Float(lo), Float(hi), maxCandidates, minScore)
        }) else { return [] }
        defer { cft8_slot_free(slot) }
        let count = Int(cft8_slot_candidate_count(slot))
        guard count > 0, let setup = vDSP_create_fftsetup(Spectrum.log2Length, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        let spectrum = Spectrum(audio, setup: setup)
        var baseband = Baseband()
        var found: [FT8Detection] = []
        for index in 0..<count where found.count < maxDecodes {
            let c = cft8_slot_candidate(slot, Int32(index))
            let coarseHz = Double(c.frequency_hz), coarseStart = Double(c.start_seconds)
            if found.contains(where: {
                abs($0.frequencyHz - coarseHz) < nearDecodeHz && abs($0.timeOffset + nominalStart - coarseStart) < nearDecodeSeconds
            }) { continue }

            if !baseband.covers(toneZeroHz: coarseHz) { baseband.load(spectrum, toneZeroHz: coarseHz, setup: setup) }
            let sync = baseband.syncSearch(start: coarseStart, toneZeroHz: coarseHz)
            var message = cft8_message_t()
            var method: Method?
            if cft8_slot_decode(slot, Int32(index), ldpcIterations, &message) == 1 {
                method = .ft8lib
            } else if baseband.syncQuality(start: sync.start, offsetHz: sync.offsetHz) >= minSyncQuality {
                let spectra = baseband.symbolSpectra(start: sync.start, offsetHz: sync.offsetHz)
                for (m, run) in [(Method.single, 1), (.pairs, 2), (.triples, 3)] {
                    var soft = softBits(spectra, run: run)
                    if soft.withUnsafeMutableBufferPointer({ cft8_decode_soft_bits($0.baseAddress, ldpcIterations, &message) }) == 1 {
                        method = m
                        break
                    }
                }
            }
            guard let method else { continue }
            let text = text(of: message)
            let tones = withUnsafeBytes(of: message.tones) { Array($0.bindMemory(to: UInt8.self)) }
            guard !text.isEmpty, !found.contains(where: { $0.message == text }) else { continue }
            let fit = baseband.fit(tones: tones, start: sync.start, offsetHz: sync.offsetHz)
            let start = Int((fit.start * Double(Baseband.decimation)).rounded())
            found.append(FT8Detection(message: text, frequencyHz: fit.toneZeroHz,
                                      timeOffset: Double(start) / rate - nominalStart, snrDb: 0,
                                      score: Int(c.score), method: method, tones: tones))
        }
        found = found.filter { audioBand.contains($0.frequencyHz) }
        guard !found.isEmpty else { return [] }

        let noise = binNoise(audio, band: lo...hi)
        for i in found.indices {
            let start = Int(((found[i].timeOffset + nominalStart) * rate).rounded())
            found[i].snrDb = snr(audio, tones: found[i].tones, start: start, frequencyHz: found[i].frequencyHz,
                                 binNoise: noise)
        }
        return found.sorted { $0.frequencyHz < $1.frequencyHz }
    }

    static func text(of m: cft8_message_t) -> String {
        withUnsafeBytes(of: m.text) { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[..<end], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
    }

    /// Resamples to 12 kHz.
    static func resample(_ samples: [Float], from rate: Double) -> [Float] {
        var resampler = FractionalResampler(inputRate: rate, outputRate: Self.rate)
        var out: [Float] = []
        out.reserveCapacity(Int(Double(samples.count) * Self.rate / rate) + 64)
        samples.withUnsafeBufferPointer { resampler.process($0, into: &out) }
        return out
    }

    // MARK: - Soft bits

    /// 174 soft bits (log p(1)/p(0) up to scale, codeword order) from the 79 × 8 symbol spectra, taking
    /// `run` consecutive data symbols (within each half) coherently.
    static func softBits(_ s: SymbolSpectra, run: Int) -> [Float] {
        var bits = [Float](repeating: 0, count: Int(CFT8_CODEWORD_BITS))
        var bit = 0
        for half in dataHalves {
            var i = 0
            while i < half.count {
                let symbols = Array(half[i..<min(i + run, half.count)])
                let n = symbols.count
                let combos = 1 << (3 * n)
                var magnitude = [Float](repeating: 0, count: combos)
                for v in 0..<combos {
                    var re: Float = 0, im: Float = 0
                    for (j, k) in symbols.enumerated() {
                        let value = (v >> (3 * (n - 1 - j))) & 7
                        let at = k * 8 + gray[value]
                        re += s.re[at]
                        im += s.im[at]
                    }
                    magnitude[v] = (re * re + im * im).squareRoot()
                }
                for b in 0..<(3 * n) {
                    let mask = 1 << (3 * n - 1 - b)
                    var one: Float = 0, zero: Float = 0
                    for v in 0..<combos {
                        if v & mask != 0 { one = max(one, magnitude[v]) } else { zero = max(zero, magnitude[v]) }
                    }
                    bits[bit + b] = one - zero
                }
                bit += 3 * n
                i += n
            }
        }
        // Unit spread, then the decoder's scale.
        let n = Float(bits.count)
        let mean = bits.reduce(0, +) / n
        let spread = (bits.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n).squareRoot()
        guard spread > 0, spread.isFinite else { return [Float](repeating: 0, count: bits.count) }
        let scale = softBitScale / spread
        return bits.map { $0 * scale }
    }

    // MARK: - Slot spectrum and baseband

    /// The slot's spectrum, zero-padded to 2^18 points (0.046 Hz bins): `re`/`im` hold 2·DFT (vDSP's
    /// real-FFT scaling) for bins 1 ..< 2^17, bin 0 zeroed.
    struct Spectrum {
        static let log2Length: vDSP_Length = 18
        static let length = 1 << Int(log2Length)
        static let binHz = FT8Decoder.rate / Double(length)
        var re: [Float]
        var im: [Float]

        init(_ audio: [Float], setup: FFTSetup) {
            let half = Self.length / 2
            var padded = [Float](repeating: 0, count: Self.length)
            for i in 0..<min(audio.count, Self.length) { padded[i] = audio[i] }
            var re = [Float](repeating: 0, count: half), im = re
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    padded.withUnsafeBufferPointer { pp in
                        pp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, Self.log2Length, FFTDirection(kFFTDirection_Forward))
                }
            }
            re[0] = 0
            im[0] = 0
            self.re = re
            self.im = im
        }
    }

    /// The 79 × 8 tone amplitudes of a transmission: `[k·8 + t]` is the 30-point DFT of symbol k at
    /// tone t, phase-referenced to the transmission's start.
    struct SymbolSpectra {
        var re = [Float](repeating: 0, count: 79 * 8)
        var im = [Float](repeating: 0, count: 79 * 8)
    }

    /// 187.5 Hz complex baseband of the slot around one candidate: sample m is audio sample 64·m,
    /// shifted down by `centreHz` (a spectrum bin, near the candidate's tone 3.5). One instance is
    /// reused across candidates (its buffers are scratch).
    struct Baseband {
        static let log2Length: vDSP_Length = 12
        static let length = 1 << Int(log2Length)
        static let decimation = Spectrum.length / length
        static let rate = FT8Decoder.rate / Double(decimation)
        /// Samples per symbol (6.25 Hz tone spacing = one bin of a 30-point DFT).
        static let symbolLength = 30
        /// Pass band (flat) and stop edge, from the centre.
        static let flatHz = 40.0
        static let edgeHz = 70.0
        /// A loaded baseband serves candidates whose tone 0 is within this of the one it was cut for.
        static let reuseHz = 6.0
        /// Coarse sync: the start within ±10 samples (±53 ms) of ft8_lib's, tone 0 within ±1.5 Hz of
        /// its, in 0.5 Hz steps (ft8_lib's grid is 80 ms × 3.125 Hz).
        static let coarseStarts = 10
        static let coarseSteps = 3
        static let coarseStepHz = 0.5
        /// Coherent fine sync: ±2 samples, ±0.6 Hz in 0.02 Hz steps.
        static let fineStarts = 2
        static let fineSteps = 30
        static let fineStepHz = 0.02
        /// e^(−2πi·t·j/30) for tones t = 0…7: `[t·30 + j]`.
        static let dft: (re: [Float], im: [Float]) = {
            var re = [Float](repeating: 0, count: 8 * symbolLength), im = re
            for t in 0..<8 {
                for j in 0..<symbolLength {
                    let a = -2 * Double.pi * Double(t * j) / Double(symbolLength)
                    re[t * symbolLength + j] = Float(cos(a))
                    im[t * symbolLength + j] = Float(sin(a))
                }
            }
            return (re, im)
        }()
        static let syncTones = FT8Decoder.syncSymbols.map { FT8Decoder.costas[$0 % 36] }

        private(set) var centreHz = -Double.infinity
        private var re = [Float](repeating: 0, count: length)
        private var im = [Float](repeating: 0, count: length)
        /// Scratch: the baseband shifted by a trial offset.
        private var shiftedRe = [Float](repeating: 0, count: length)
        private var shiftedIm = [Float](repeating: 0, count: length)

        /// Whether the loaded baseband serves a candidate with tone 0 at `toneZeroHz`.
        func covers(toneZeroHz: Double) -> Bool {
            abs(toneZeroHz + 3.5 * FT8Decoder.toneSpacing - centreHz) <= Self.reuseHz
        }

        /// Cuts the spectrum to ±70 Hz (raised-cosine edges from ±40 Hz) around tone 3.5 of a signal
        /// with tone 0 at `toneZeroHz`, and inverse-transforms it.
        mutating func load(_ s: Spectrum, toneZeroHz: Double, setup: FFTSetup) {
            let n = Self.length
            let centreBin = Int(((toneZeroHz + 3.5 * FT8Decoder.toneSpacing) / Spectrum.binHz).rounded())
            centreHz = Double(centreBin) * Spectrum.binHz
            let edge = Int(Self.edgeHz / Spectrum.binHz)
            let flat = Self.flatHz / Spectrum.binHz
            for i in 0..<n { re[i] = 0; im[i] = 0 }
            for j in -edge...edge {
                let k = centreBin + j
                guard k > 0, k < s.re.count else { continue }
                let d = Double(abs(j))
                let w = d <= flat ? 1 : Float(0.5 * (1 + cos(Double.pi * (d - flat) / (Double(edge) - flat))))
                let at = (j + n) % n
                re[at] = w * s.re[k]
                im[at] = w * s.im[k]
            }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zip(setup, &split, 1, Self.log2Length, FFTDirection(kFFTDirection_Inverse))
                }
            }
        }

        /// The DFTs of symbol k (samples `start + 30k ..< start + 30k + 30`) at `tones`, after shifting
        /// the baseband by −`offsetHz` (tone 0's offset from `centreHz`), phase-referenced to `start`
        /// (so a phase-continuous transmission's symbols add in phase). Written to `outRe[t]`,
        /// `outIm[t]`. Samples outside the baseband count as zero.
        func symbol(_ k: Int, start: Int, offsetHz: Double, tones: Range<Int>,
                    into outRe: UnsafeMutablePointer<Float>, _ outIm: UnsafeMutablePointer<Float>) {
            let len = Self.symbolLength
            let w = -2 * Double.pi * offsetHz / Self.rate
            let base = start + k * len
            for t in tones { outRe[t] = 0; outIm[t] = 0 }
            let lo = max(0, -base), hi = min(len, Self.length - base)
            guard lo < hi else { return }
            let kernels = Self.dft
            re.withUnsafeBufferPointer { zr in
                im.withUnsafeBufferPointer { zi in
                    kernels.re.withUnsafeBufferPointer { kr in
                        kernels.im.withUnsafeBufferPointer { ki in
                            let rr = Float(cos(w)), ri = Float(sin(w))
                            let p0 = w * Double(k * len + lo)
                            var pr = Float(cos(p0)), pi = Float(sin(p0))
                            for j in lo..<hi {
                                let ar = zr[base + j], ai = zi[base + j]
                                let yr = ar * pr - ai * pi, yi = ar * pi + ai * pr
                                for t in tones {
                                    let cr = kr[t * len + j], ci = ki[t * len + j]
                                    outRe[t] += yr * cr - yi * ci
                                    outIm[t] += yr * ci + yi * cr
                                }
                                let npr = pr * rr - pi * ri
                                pi = pr * ri + pi * rr
                                pr = npr
                            }
                        }
                    }
                }
            }
        }

        /// The DFT of symbol k at tone t, as `symbol(_:start:offsetHz:tones:into:_:)`.
        func tone(_ k: Int, _ t: Int, start: Int, offsetHz: Double) -> (re: Float, im: Float) {
            var r = [Float](repeating: 0, count: 8), i = r
            r.withUnsafeMutableBufferPointer { rp in
                i.withUnsafeMutableBufferPointer { ip in
                    symbol(k, start: start, offsetHz: offsetHz, tones: t..<(t + 1), into: rp.baseAddress!, ip.baseAddress!)
                }
            }
            return (r[t], i[t])
        }

        /// Σ |DFT|² over `symbols` at the given tone of each.
        func energy(start: Int, offsetHz: Double, symbols: [Int], tones: [Int]) -> Float {
            var total: Float = 0
            for (k, t) in zip(symbols, tones) {
                let z = tone(k, t, start: start, offsetHz: offsetHz)
                total += z.re * z.re + z.im * z.im
            }
            return total
        }

        /// The best Costas sync near a candidate. Coarse: the 21 Costas symbols' energy over starts
        /// (baseband samples) within ±10 of `start` seconds and tone-0 offsets within ±1.5 Hz of
        /// `toneZeroHz`. Fine: FT8 is phase-continuous, so with the phase referenced to the start the
        /// Costas symbols' amplitudes add coherently once the residual offset δ is removed; their
        /// coherent sum |Σ C_k·e^(−2πi·δ·0.16 s·k)|² peaks sharply in δ and the start, searched over
        /// ±2 samples and ±0.6 Hz.
        mutating func syncSearch(start: Double, toneZeroHz: Double) -> (start: Int, offsetHz: Double) {
            let origin = Int((start * Self.rate).rounded())
            let coarseOffset = toneZeroHz - centreHz
            var best = (start: origin, offsetHz: coarseOffset)
            var bestEnergy: Float = -1
            let len = Self.symbolLength, n = Self.length
            let kernels = Self.dft
            for step in -Self.coarseSteps...Self.coarseSteps {
                let offset = coarseOffset + Self.coarseStepHz * Double(step)
                shift(by: offset)
                shiftedRe.withUnsafeBufferPointer { yr in
                    shiftedIm.withUnsafeBufferPointer { yi in
                        kernels.re.withUnsafeBufferPointer { kr in
                            kernels.im.withUnsafeBufferPointer { ki in
                                for s in (origin - Self.coarseStarts)...(origin + Self.coarseStarts) {
                                    var e: Float = 0
                                    for (k, t) in zip(FT8Decoder.syncSymbols, Self.syncTones) {
                                        let base = s + k * len
                                        let lo = max(0, -base), hi = min(len, n - base)
                                        guard lo < hi else { continue }
                                        var sr: Float = 0, si: Float = 0
                                        for j in lo..<hi {
                                            let ar = yr[base + j], ai = yi[base + j]
                                            let cr = kr[t * len + j], ci = ki[t * len + j]
                                            sr += ar * cr - ai * ci
                                            si += ar * ci + ai * cr
                                        }
                                        e += sr * sr + si * si
                                    }
                                    if e > bestEnergy { bestEnergy = e; best = (s, offset) }
                                }
                            }
                        }
                    }
                }
            }

            let coarse = best
            let symbolSeconds = FT8Encoder.symbolSeconds
            var bestCoherent: Float = -1
            var cr = [Float](repeating: 0, count: FT8Decoder.syncSymbols.count), ci = cr
            for s in (coarse.start - Self.fineStarts)...(coarse.start + Self.fineStarts) {
                for (i, (k, t)) in zip(FT8Decoder.syncSymbols, Self.syncTones).enumerated() {
                    (cr[i], ci[i]) = tone(k, t, start: s, offsetHz: coarse.offsetHz)
                }
                for step in -Self.fineSteps...Self.fineSteps {
                    let d = Self.fineStepHz * Double(step)
                    var sr: Float = 0, si: Float = 0
                    for (i, k) in FT8Decoder.syncSymbols.enumerated() {
                        let a = -2 * Double.pi * d * symbolSeconds * Double(k)
                        let wr = Float(cos(a)), wi = Float(sin(a))
                        sr += cr[i] * wr - ci[i] * wi
                        si += cr[i] * wi + ci[i] * wr
                    }
                    let e = sr * sr + si * si
                    if e > bestCoherent { bestCoherent = e; best = (s, coarse.offsetHz + d) }
                }
            }
            return best
        }

        /// Fills the scratch buffers with the baseband times e^(−2πi·offsetHz·m/rate).
        private mutating func shift(by offsetHz: Double) {
            let w = -2 * Double.pi * offsetHz / Self.rate
            let block = 64
            let stepRe = Float(cos(w)), stepIm = Float(sin(w))
            var m = 0
            while m < Self.length {
                // Exact phasor at each block start, then a recurrence within the block.
                var pr = Float(cos(w * Double(m))), pi = Float(sin(w * Double(m)))
                for j in m..<min(m + block, Self.length) {
                    shiftedRe[j] = re[j] * pr - im[j] * pi
                    shiftedIm[j] = re[j] * pi + im[j] * pr
                    let npr = pr * stepRe - pi * stepIm
                    pi = pr * stepIm + pi * stepRe
                    pr = npr
                }
                m += block
            }
        }

        /// The share of the Costas symbols' energy (over all eight tones) in their sync tones: 1/8 on
        /// average for noise, approaching 1 for a strong signal.
        func syncQuality(start: Int, offsetHz: Double) -> Float {
            var r = [Float](repeating: 0, count: 8), i = r
            var sync: Float = 0, total: Float = 0
            r.withUnsafeMutableBufferPointer { rp in
                i.withUnsafeMutableBufferPointer { ip in
                    for (k, t) in zip(FT8Decoder.syncSymbols, Self.syncTones) {
                        symbol(k, start: start, offsetHz: offsetHz, tones: 0..<8, into: rp.baseAddress!, ip.baseAddress!)
                        for u in 0..<8 { total += rp[u] * rp[u] + ip[u] * ip[u] }
                        sync += rp[t] * rp[t] + ip[t] * ip[t]
                    }
                }
            }
            return total > 0 ? sync / total : 0
        }

        /// All 79 × 8 tone amplitudes at an alignment.
        func symbolSpectra(start: Int, offsetHz: Double) -> SymbolSpectra {
            var s = SymbolSpectra()
            s.re.withUnsafeMutableBufferPointer { r in
                s.im.withUnsafeMutableBufferPointer { i in
                    for k in 0..<FT8Decoder.symbolCount {
                        symbol(k, start: start, offsetHz: offsetHz, tones: 0..<8,
                               into: r.baseAddress! + 8 * k, i.baseAddress! + 8 * k)
                    }
                }
            }
            return s
        }

        /// The alignment of a decoded transmission: maximises the energy of all 79 sent tones over the
        /// start (±2 samples) and tone-0 offset (±0.3 Hz around `offsetHz`, 0.025 Hz steps), then
        /// interpolates the start parabolically. Returns the start in (fractional) baseband samples and
        /// the absolute tone-0 frequency.
        func fit(tones: [UInt8], start: Int, offsetHz: Double) -> (start: Double, toneZeroHz: Double) {
            let all = Array(0..<FT8Decoder.symbolCount), sent = tones.map(Int.init)
            func e(_ s: Int, _ f: Double) -> Float { energy(start: s, offsetHz: f, symbols: all, tones: sent) }
            var best = (start: start, offsetHz: offsetHz)
            var bestEnergy = e(start, offsetHz)
            for s in (start - 2)...(start + 2) {
                for step in -12...12 {
                    let f = offsetHz + 0.025 * Double(step)
                    let v = e(s, f)
                    if v > bestEnergy { bestEnergy = v; best = (s, f) }
                }
            }
            let before = e(best.start - 1, best.offsetHz), after = e(best.start + 1, best.offsetHz)
            let curvature = before - 2 * bestEnergy + after
            var shift = 0.0
            if curvature < 0 { shift = Double(max(-0.5, min(0.5, 0.5 * (before - after) / curvature))) }
            return (Double(best.start) + shift, centreHz + best.offsetHz)
        }
    }

    // MARK: - SNR

    /// Σ over the symbols of |DFT|² of each 1920-sample symbol at its tone, the transmission starting
    /// at sample `start` with tone 0 at `hz` (samples outside the audio count as zero).
    static func toneEnergy(_ x: UnsafeBufferPointer<Float>, tones: [UInt8], start: Int, frequencyHz hz: Double) -> Double {
        let n = samplesPerSymbol
        var total = 0.0
        for (k, tone) in tones.enumerated() {
            let base = start + k * n
            let lo = max(0, -base), hi = min(n, x.count - base)
            guard lo < hi else { continue }
            let w = -2 * Double.pi * (hz + toneSpacing * Double(tone)) / rate
            let rr = Float(cos(w)), ri = Float(sin(w))
            var pr = Float(cos(w * Double(lo))), pi = Float(sin(w * Double(lo)))
            var sr: Float = 0, si: Float = 0
            for j in lo..<hi {
                let v = x[base + j]
                sr += v * pr
                si += v * pi
                let npr = pr * rr - pi * ri
                pi = pr * ri + pi * rr
                pr = npr
            }
            total += Double(sr * sr + si * si)
        }
        return total
    }

    /// Expected |DFT|² of the noise in a 1920-sample rectangular symbol DFT: N·σ², σ² the variance of
    /// the noise if it were white at the band's density. From the 25% quantile of the slot-averaged
    /// 2048-point Hann spectrum over `band` (at least 16 bins), scaled to the mean of the averaged
    /// noise power, whose spread is that of a mean of `frames` exponentials.
    static func binNoise(_ audio: [Float], band: ClosedRange<Double>) -> Double {
        let log2n: vDSP_Length = 11
        let size = 1 << Int(log2n), half = size / 2
        let frames = audio.count / size
        guard frames > 0, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return 0 }
        defer { vDSP_destroy_fftsetup(setup) }
        let window = (0..<size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size))) }
        let windowPower = window.reduce(0.0) { $0 + Double($1) * Double($1) }
        var average = [Double](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: size)
        var re = [Float](repeating: 0, count: half), im = re
        var mags = [Float](repeating: 0, count: half)
        for f in 0..<frames {
            for j in 0..<size { frame[j] = audio[f * size + j] * window[j] }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
                }
            }
            // vDSP's real FFT is twice the DFT; bin 0 packs DC and Nyquist, unused here.
            for k in 1..<half { average[k] += Double(mags[k]) / 4 }
        }
        let binHz = rate / Double(size)
        var lo = max(1, Int((band.lowerBound / binHz).rounded(.up)))
        var hi = min(half - 1, Int((band.upperBound / binHz).rounded(.down)))
        while hi - lo + 1 < 16 && (lo > 1 || hi < half - 1) {
            lo = max(1, lo - 1)
            hi = min(half - 1, hi + 1)
        }
        guard lo <= hi else { return 0 }
        let values = average[lo...hi].map { $0 / Double(frames) }.sorted()
        let quantile = values[values.count / 4]
        // 25% point of a mean of `frames` unit exponentials ≈ 1 − 0.674/√frames.
        let mean = quantile / max(0.1, 1 - 0.674 / Double(frames).squareRoot())
        // Hann frame: E|DFT|² = σ²·Σw². Symbol DFT: E|X|² = N·σ².
        return Double(samplesPerSymbol) * mean / windowPower
    }

    /// SNR in 2.5 kHz of the transmission at `start`, `hz`.
    static func snr(_ audio: [Float], tones: [UInt8], start: Int, frequencyHz hz: Double, binNoise: Double) -> Float {
        let n = Double(samplesPerSymbol)
        let measured = audio.withUnsafeBufferPointer { toneEnergy($0, tones: tones, start: start, frequencyHz: hz) }
        // The share of a unit sine's energy (N²/4 per symbol) that the symbol DFTs capture of clean GFSK.
        let clean = FT8Encoder.waveform(tones: tones, audioHz: hz, sampleRate: rate)
        let captured = clean.withUnsafeBufferPointer { toneEnergy($0, tones: tones, start: 0, frequencyHz: hz) }
        let share = captured / (Double(tones.count) * n * n / 4)
        guard binNoise > 0, share > 0 else { return snrRange.upperBound }
        let perSymbol = measured / Double(tones.count)
        let excess = max(perSymbol - binNoise, binNoise * 1e-4)
        // Signal power A²/2 = 2·|X|²/N² / share; noise σ² = binNoise / N, density σ²/(fs/2).
        let signalPower = 2 * excess / (n * n) / share
        let noiseIn2500 = binNoise / n / (rate / 2) * 2_500
        let snr = Float(10 * log10(signalPower / noiseIn2500))
        return min(max(snr, snrRange.lowerBound), snrRange.upperBound)
    }
}
