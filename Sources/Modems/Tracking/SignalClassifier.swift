import Accelerate
import Foundation
import simd

/// The auto-detected mode of one tracked signal.
public struct Classification: Sendable, Equatable {
    /// Nil when the signal matches no mode: a plain carrier, noise, or a mode SubFloor doesn't decode.
    public var mode: ModeID?
    /// "CW", "BPSK31", "QPSK31", "RTTY 45", "FT8" or "WSPR"; empty when `mode` is nil.
    public var submode: String
    /// 0...1, from how far each of the rule's features lies past its threshold: 0.5 when one only just
    /// passed, 1 when every one is at or beyond its "solid" level. At least 0.5 whenever `mode` is set
    /// (0.375 for FT8 whose slot timing could not be checked); 0 when `mode` is nil.
    public var confidence: Float

    public init(mode: ModeID?, submode: String, confidence: Float) {
        self.mode = mode
        self.submode = submode
        self.confidence = confidence
    }

    public static let unknown = Classification(mode: nil, submode: "", confidence: 0)
}

/// Rule-based auto-detect for one `Track`, from a short capture of the box audio.
///
/// The audio is mixed down at the track's frequency to complex baseband at 500 Hz (±150 Hz kept;
/// a triangular CIC stage to 2 kHz, then a 65-tap Blackman FIR), and the rules are checked in order:
/// 1. **RTTY**: the tracker paired the track as FSK; two tones 170 ± 15 Hz apart within 6 dB show in
///    the baseband spectrum, and their short-time energies are anticorrelated (keying).
/// 2. **CW**: the envelope (16 ms smoothing) has std/mean > 0.6 and an on/off (bimodal) histogram:
///    an Otsu split with the off level below 0.35 of the on level, at least 3 key-down runs, and
///    key-up and key-down runs with medians of at least 20 ms. PSK31's reversal dips are shorter.
/// 3. **PSK31**: occupied bandwidth ≤ 80 Hz, and either the tracker's ±15.6 ± 2 Hz idle sidebands or
///    a 31.25 Hz symbol-clock line in |z|² at least 7 dB over its neighbourhood. A trial
///    demodulation (symbols at the clock line's phase, differential phases) must show phase changes
///    on at least 15% of the symbols (a carrier shows none) and fit a 2- or 4-point constellation;
///    QPSK31 when only the 4-point fit holds. QPSK31 idle is BPSK31's reversals, so it reads BPSK31
///    until text is sent (the PSK31 decoder detects the mode itself as well).
/// 4. **FT8**: a constant envelope, 25-65 Hz occupied, and per-symbol (0.16 s) frames dominated by
///    single tones on a 6.25 Hz grid, at least 4 distinct within 8 grid steps; the transmission's
///    onset (or end) lies within ±2 s of its nominal place in a 15 s UTC slot (+0.5 s, or +13.14 s).
/// 5. **WSPR**: about 6 Hz occupied (2.5-10 Hz), the signal in 1400-1600 Hz, a constant envelope, and
///    per-symbol (0.683 s) tones on a 1.4648 Hz grid, at least 2 distinct within 4 steps.
/// 6. Otherwise nil.
///
/// Thresholds were tuned on test seeds kept apart from the asserting tests (see the tests).
///
/// Capture length: at least 2 s (shorter returns `.unknown`); only the last 16 s are used. 2 s
/// classifies CW, PSK31 and RTTY; FT8's slot check needs the onset or end of the transmission
/// inside the capture (otherwise the FT8 confidence is scaled by 0.75); WSPR needs about 4 s or
/// more for its tones to show (8 s in the tests).
///
/// Cost per call, release build: 0.3 ms for 2 s and 2.3-3 ms for 16 s on the x86 Linux check harness
/// with its pure-Swift Accelerate stand-in; real vDSP on Apple Silicon should be well under that.
///
/// Stateless and thread-safe.
public enum SignalClassifier {
    // MARK: Constants

    static let minSeconds = 1.95
    static let maxSeconds = 16.0
    static let stage1Rate = 2_000.0
    static let basebandRate = 500.0
    static let firTaps = 65
    static let firCutoffHz = 250.0
    /// Half-width of the baseband analysed for the spectral rules.
    static let analysisHalfWidthHz = 150.0

    // Occupied region: bins ≥ 6 dB over the median, seeded within ±20 Hz of the track, gaps ≤ 6 Hz.
    static let regionThreshold: Float = 4
    static let regionSeedHz = 20.0
    static let regionGapHz = 6.0

    // RTTY
    static let rttyShiftHz = 170.0
    static let rttyShiftToleranceHz = 15.0
    static let rttyLevelDb: Float = 6
    static let rttyMaxCorrelation: Float = -0.3
    static let rttySolidCorrelation: Float = -0.8

    // CW
    static let envelopeSmoothingSeconds = 0.016
    static let cwEnvelopeRatio: Float = 0.6
    static let cwSolidEnvelopeRatio: Float = 0.9
    static let cwMaxDepth: Float = 0.35
    static let cwSolidDepth: Float = 0.1
    static let cwMinRunSeconds = 0.020
    static let cwSolidRunSeconds = 0.040
    static let cwMinKeyDownRuns = 3

    // PSK31
    static let pskSymbolRate = 31.25
    static let pskMaxBandwidthHz = 80.0
    static let pskSolidBandwidthHz = 55.0
    static let pskSidebandHz = 15.625
    static let pskSidebandToleranceHz = 2.0
    static let pskLineDb: Float = 7
    static let pskSolidLineDb: Float = 17
    static let pskMinFit: Float = 0.4
    static let pskSolidFit: Float = 0.9
    /// A PSK31 signal changes phase: this fraction of its symbols at least (a carrier has none).
    static let pskMinTransitions: Float = 0.15
    static let pskSolidTransitions: Float = 0.3
    /// QPSK31 when the 2-point fit stays below this while the 4-point fit passes `pskMinFit`.
    static let qpskMaxBPSKFit: Float = 0.5
    static let pskMinSymbols = 16

    // Constant-envelope modes (FT8, WSPR): std/mean of the envelope while on.
    static let constantEnvelopeSpread: Float = 0.3
    static let constantEnvelopeSolid: Float = 0.12
    static let toneFrameConcentration: Float = 0.5
    static let toneGridFit: Float = 0.8
    static let toneGridSolidFit: Float = 0.95

    // FT8
    static let ft8SpacingHz = 6.25
    static let ft8SymbolSeconds = 0.16
    static let ft8BandwidthHz = 25.0...65.0
    static let ft8MinTones = 4
    static let ft8MaxSpanSteps = 7
    static let ft8SlotSeconds = 15.0
    static let ft8StartSeconds = 0.5
    static let ft8LengthSeconds = 79 * 0.16
    static let ft8TimingToleranceSeconds = 2.0
    static let ft8SolidTimingSeconds = 0.5

    // WSPR
    static let wsprSpacingHz = 12_000.0 / 8_192
    static let wsprSymbolSeconds = 8_192.0 / 12_000
    static let wsprBandwidthHz = 2.5...10.0
    static let wsprSolidBandwidthHz = 7.0
    static let wsprBand = 1_400.0...1_600.0
    static let wsprMinTones = 2
    static let wsprMaxSpanSteps = 3

    // MARK: Classification

    /// Classifies `track` from `audio`, the latest box audio (at least 2 s, ending now).
    /// - Parameter utcSecondOfMinute: the UTC second within the minute (0..<60) at which the first
    ///   sample of `audio` was received; nil when unknown, which leaves FT8's slot timing unchecked.
    public static func classify(track: Track, audio: ArraySlice<Float>, sampleRate: Double,
                                utcSecondOfMinute: Double?) -> Classification {
        guard Double(audio.count) >= minSeconds * sampleRate else { return .unknown }
        let a = Analysis(track: track, audio: audio, sampleRate: sampleRate, utcSecondOfMinute: utcSecondOfMinute)
        if let c = a.rtty() { return c }
        if let c = a.cw() { return c }
        if let c = a.psk31() { return c }
        if let c = a.ft8() { return c }
        if let c = a.wspr() { return c }
        return .unknown
    }

    /// 0.5 at `threshold`, 1 at `solid`, 0 as far again on the failing side; linear between. Either
    /// direction: `solid` may lie above or below `threshold`.
    static func score(_ x: Double, threshold: Double, solid: Double) -> Float {
        let t = (x - threshold) / (solid - threshold)
        return Float(0.5 + 0.5 * min(max(t, -1), 1))
    }

    static func score(_ x: Float, threshold: Float, solid: Float) -> Float {
        score(Double(x), threshold: Double(threshold), solid: Double(solid))
    }

    // MARK: - Analysis

    /// The features of one capture. Each rule computes what it needs on first use.
    struct Analysis {
        let track: Track
        /// UTC second of minute at baseband sample 0.
        let utcSecondOfMinute: Double?
        /// Complex baseband centred on the track, at `rate` (≈ 500 Hz).
        let z: [SIMD2<Float>]
        let rate: Double
        let seconds: Double
        let spectrum: Spectrum
        let envelope: [Float]

        init(track: Track, audio: ArraySlice<Float>, sampleRate: Double, utcSecondOfMinute: Double?) {
            self.track = track
            let keep = min(audio.count, Int(SignalClassifier.maxSeconds * sampleRate))
            let slice = audio[(audio.endIndex - keep)...]
            let (z, rate) = SignalClassifier.baseband(slice, centreHz: track.frequencyHz, sampleRate: sampleRate)
            // UTC time of baseband sample 0: past the dropped head and the filters' start-up.
            let skipped = Double(audio.count - keep) / sampleRate
            self.utcSecondOfMinute = utcSecondOfMinute.map {
                $0 + skipped + SignalClassifier.basebandDelaySeconds(sampleRate: sampleRate)
            }
            self.z = z
            self.rate = rate
            seconds = Double(z.count) / rate
            spectrum = Spectrum(z, rate: rate)
            let smoothing = max(1, Int((SignalClassifier.envelopeSmoothingSeconds * rate).rounded()))
            envelope = SignalClassifier.boxcar(z, smoothing).map { simd_length($0) }
        }

        // MARK: Rule 1: RTTY

        func rtty() -> Classification? {
            guard track.isFSKPair else { return nil }
            let half = SignalClassifier.rttyShiftHz / 2
            // Each tone within half the shift tolerance, with the track's centre up to 22 Hz off.
            let reach = SignalClassifier.rttyShiftToleranceHz / 2 + 22
            // Each tone: its strongest bin, then the power centroid of ±25 Hz around it (the keying
            // lines around a tone make the strongest bin data-dependent).
            guard let lowPeak = spectrum.peak(in: (-half - reach)...(-half + reach)),
                  let highPeak = spectrum.peak(in: (half - reach)...(half + reach)),
                  min(lowPeak.power, highPeak.power) > SignalClassifier.regionThreshold * spectrum.median,
                  let low = spectrum.lump(around: lowPeak.hz), let high = spectrum.lump(around: highPeak.hz)
            else { return nil }
            let shiftError = abs(high.hz - low.hz - SignalClassifier.rttyShiftHz)
            let levelDb = abs(10 * log10(high.power / low.power))
            guard shiftError <= SignalClassifier.rttyShiftToleranceHz, levelDb <= SignalClassifier.rttyLevelDb,
                  let correlation = toneEnergyCorrelation(low.hz, high.hz),
                  correlation <= SignalClassifier.rttyMaxCorrelation else { return nil }
            // The level balance only gates: over 2 s it follows the text (mark/space duty), not quality.
            let confidence = min(
                SignalClassifier.score(shiftError, threshold: SignalClassifier.rttyShiftToleranceHz, solid: 5),
                SignalClassifier.score(correlation, threshold: SignalClassifier.rttyMaxCorrelation,
                                       solid: SignalClassifier.rttySolidCorrelation))
            return Classification(mode: .rtty, submode: "RTTY 45", confidence: confidence)
        }

        /// Pearson correlation of the short-time energies at two baseband frequencies, each series with
        /// its ±100 ms moving average removed so slow fading cancels while 45 Bd keying stays.
        func toneEnergyCorrelation(_ hz1: Double, _ hz2: Double) -> Float? {
            let length = max(1, Int((0.011 * rate).rounded()))       // half an RTTY bit
            let e1 = toneEnergy(hz1, length), e2 = toneEnergy(hz2, length)
            let h = Int((0.1 * rate).rounded())
            guard e1.count > 2 * h + 16 else { return nil }
            let a = SignalClassifier.highPass(e1, h), b = SignalClassifier.highPass(e2, h)
            return SignalClassifier.correlation(a, b)
        }

        private func toneEnergy(_ hz: Double, _ length: Int) -> [Float] {
            let w = -2 * Double.pi * hz / rate
            var shifted = [SIMD2<Float>](repeating: .zero, count: z.count)
            for (n, v) in z.enumerated() {
                let p = w * Double(n)
                shifted[n] = cmul(v, SIMD2(Float(cos(p)), Float(sin(p))))
            }
            return SignalClassifier.boxcar(shifted, length).map { simd_length_squared($0) }
        }

        // MARK: Rule 2: CW

        func cw() -> Classification? {
            guard let k = SignalClassifier.keying(envelope, rate: rate), k.isOnOff,
                  k.envelopeRatio > SignalClassifier.cwEnvelopeRatio else { return nil }
            let shortest = min(k.medianKeyDownSeconds, k.medianKeyUpSeconds)
            let confidence = min(
                SignalClassifier.score(k.envelopeRatio, threshold: SignalClassifier.cwEnvelopeRatio,
                                       solid: SignalClassifier.cwSolidEnvelopeRatio),
                SignalClassifier.score(k.depth, threshold: SignalClassifier.cwMaxDepth, solid: SignalClassifier.cwSolidDepth),
                SignalClassifier.score(shortest, threshold: SignalClassifier.cwMinRunSeconds,
                                       solid: SignalClassifier.cwSolidRunSeconds))
            return Classification(mode: .cw, submode: "CW", confidence: confidence)
        }

        // MARK: Rule 3: PSK31

        func psk31() -> Classification? {
            let region = spectrum.region
            guard let region, region.bandwidthHz <= SignalClassifier.pskMaxBandwidthHz else { return nil }
            let target = SignalClassifier.pskSidebandHz, tolerance = SignalClassifier.pskSidebandToleranceHz
            let sidebands = track.peakOffsetsHz.contains { abs($0 + target) <= tolerance }
                && track.peakOffsetsHz.contains { abs($0 - target) <= tolerance }
            let psk = SignalClassifier.pskTrial(z, rate: rate)
            guard sidebands || psk.lineDb >= SignalClassifier.pskLineDb,
                  psk.symbols >= SignalClassifier.pskMinSymbols,
                  psk.transitions >= SignalClassifier.pskMinTransitions,
                  max(psk.fit2, psk.fit4) >= SignalClassifier.pskMinFit else { return nil }
            let qpsk = psk.fit2 < SignalClassifier.qpskMaxBPSKFit
            let fit = qpsk ? psk.fit4 : psk.fit2
            let lineScore = SignalClassifier.score(psk.lineDb, threshold: SignalClassifier.pskLineDb,
                                                   solid: SignalClassifier.pskSolidLineDb)
            let confidence = min(
                SignalClassifier.score(region.bandwidthHz, threshold: SignalClassifier.pskMaxBandwidthHz,
                                       solid: SignalClassifier.pskSolidBandwidthHz),
                sidebands ? max(lineScore, 0.75) : lineScore,
                SignalClassifier.score(fit, threshold: SignalClassifier.pskMinFit, solid: SignalClassifier.pskSolidFit),
                SignalClassifier.score(psk.transitions, threshold: SignalClassifier.pskMinTransitions,
                                       solid: SignalClassifier.pskSolidTransitions))
            return Classification(mode: .psk31, submode: qpsk ? "QPSK31" : "BPSK31", confidence: confidence)
        }

        // MARK: Rule 4: FT8

        func ft8() -> Classification? {
            guard let region = spectrum.region, SignalClassifier.ft8BandwidthHz.contains(region.bandwidthHz) else {
                return nil
            }
            let flat = flatEnvelope(region)
            guard let spread = constantEnvelopeSpread(flat), spread <= SignalClassifier.constantEnvelopeSpread,
                  let tones = SignalClassifier.toneGrid(
                      z, rate: rate, symbolSeconds: SignalClassifier.ft8SymbolSeconds,
                      spacingHz: SignalClassifier.ft8SpacingHz,
                      span: (region.lowHz - 5)...(region.highHz + 5)),
                  tones.fit >= SignalClassifier.toneGridFit, tones.distinct >= SignalClassifier.ft8MinTones,
                  tones.spanSteps <= SignalClassifier.ft8MaxSpanSteps else { return nil }
            var confidence = min(
                SignalClassifier.score(spread, threshold: SignalClassifier.constantEnvelopeSpread,
                                       solid: SignalClassifier.constantEnvelopeSolid),
                SignalClassifier.score(tones.fit, threshold: SignalClassifier.toneGridFit,
                                       solid: SignalClassifier.toneGridSolidFit),
                SignalClassifier.score(Double(tones.distinct), threshold: Double(SignalClassifier.ft8MinTones) - 0.5,
                                       solid: 6))
            switch slotTiming(flat) {
            case .misaligned:
                return nil
            case .aligned(let error):
                confidence = min(confidence, SignalClassifier.score(
                    error, threshold: SignalClassifier.ft8TimingToleranceSeconds, solid: SignalClassifier.ft8SolidTimingSeconds))
            case .unverified:
                confidence *= 0.75
            }
            return Classification(mode: .ft8, submode: "FT8", confidence: confidence)
        }

        enum SlotTiming { case aligned(errorSeconds: Double), misaligned, unverified }

        /// Where the transmission's onset (or end), found on `envelope`, falls within the 15 s FT8 slot.
        func slotTiming(_ envelope: [Float]) -> SlotTiming {
            guard let utc = utcSecondOfMinute else { return .unverified }
            let slot = SignalClassifier.ft8SlotSeconds
            func error(_ t: Double, nominal: Double) -> Double {
                var d = (t - nominal).truncatingRemainder(dividingBy: slot)
                if d > slot / 2 { d -= slot }
                if d < -slot / 2 { d += slot }
                return abs(d)
            }
            let edges = SignalClassifier.onOffEdges(envelope, rate: rate)
            let tolerance = SignalClassifier.ft8TimingToleranceSeconds
            if let onset = edges.onset {
                let e = error(utc + onset, nominal: SignalClassifier.ft8StartSeconds)
                return e <= tolerance ? .aligned(errorSeconds: e) : .misaligned
            }
            if let end = edges.end {
                let e = error(utc + end, nominal: SignalClassifier.ft8StartSeconds + SignalClassifier.ft8LengthSeconds)
                return e <= tolerance ? .aligned(errorSeconds: e) : .misaligned
            }
            // No edge at all while the tones are present: on for longer than one FT8 transmission
            // (12.64 s, plus a second of margin) is not FT8.
            if edges.onThroughout && seconds > SignalClassifier.ft8LengthSeconds + 1 { return .misaligned }
            return .unverified
        }

        // MARK: Rule 5: WSPR

        func wspr() -> Classification? {
            guard let region = spectrum.region, SignalClassifier.wsprBandwidthHz.contains(region.bandwidthHz),
                  SignalClassifier.wsprBand.contains(track.frequencyHz + region.centroidHz),
                  let spread = constantEnvelopeSpread(flatEnvelope(region)),
                  spread <= SignalClassifier.constantEnvelopeSpread,
                  let tones = SignalClassifier.toneGrid(
                      z, rate: rate, symbolSeconds: SignalClassifier.wsprSymbolSeconds,
                      spacingHz: SignalClassifier.wsprSpacingHz,
                      span: (region.lowHz - 3)...(region.highHz + 3)),
                  tones.fit >= SignalClassifier.toneGridFit, tones.distinct >= SignalClassifier.wsprMinTones,
                  tones.spanSteps <= SignalClassifier.wsprMaxSpanSteps else { return nil }
            let confidence = min(
                SignalClassifier.score(spread, threshold: SignalClassifier.constantEnvelopeSpread,
                                       solid: SignalClassifier.constantEnvelopeSolid),
                SignalClassifier.score(tones.fit, threshold: SignalClassifier.toneGridFit,
                                       solid: SignalClassifier.toneGridSolidFit),
                SignalClassifier.score(region.bandwidthHz, threshold: SignalClassifier.wsprBandwidthHz.upperBound,
                                       solid: SignalClassifier.wsprSolidBandwidthHz))
            return Classification(mode: .wspr, submode: "WSPR", confidence: confidence)
        }

        /// The envelope of the occupied region, flat across it: the baseband is shifted to the region's
        /// centroid and smoothed only as much as keeps its edges within 3% (a boxcar of an eighth of a
        /// cycle at the region's half-width), so FSK tone changes do not look like amplitude changes.
        func flatEnvelope(_ region: Spectrum.Region) -> [Float] {
            let halfWidth = max(region.highHz - region.centroidHz, region.centroidHz - region.lowHz, 5)
            let w = -2 * Double.pi * region.centroidHz / rate
            var centred = [SIMD2<Float>](repeating: .zero, count: z.count)
            for (n, v) in z.enumerated() {
                let p = w * Double(n)
                centred[n] = cmul(v, SIMD2(Float(cos(p)), Float(sin(p))))
            }
            let length = max(1, Int((rate / (8 * halfWidth)).rounded(.down)))
            return SignalClassifier.boxcar(centred, length).map { simd_length($0) }
        }

        /// Std/mean of an envelope while the signal is on (above half its 90th percentile); nil when
        /// it is on/off keyed (`Keying.isOnOff`) or on for under 1 s.
        func constantEnvelopeSpread(_ envelope: [Float]) -> Float? {
            if let k = SignalClassifier.keying(envelope, rate: rate), k.isOnOff { return nil }
            let top = SignalClassifier.percentile(envelope, 0.9)
            let on = envelope.filter { $0 > 0.5 * top }
            guard on.count >= Int(rate) else { return nil }
            let (mean, sd) = SignalClassifier.meanAndDeviation(on)
            return mean > 0 ? sd / mean : nil
        }
    }

    // MARK: - Baseband

    /// Mixes `audio` down at `centreHz` and decimates to ≈ 500 Hz complex baseband: a triangular
    /// (2nd-order CIC) stage to ≈ 2 kHz, then a 65-tap Blackman low-pass (−6 dB at 250 Hz, flat to
    /// ±165 Hz, ≥ 55 dB down from ±335 Hz, so nothing aliases into ±150 Hz). A real tone of amplitude A
    /// reads A/2.
    static func baseband(_ audio: ArraySlice<Float>, centreHz: Double, sampleRate: Double) -> (z: [SIMD2<Float>], rate: Double) {
        let d1 = max(1, Int((sampleRate / stage1Rate).rounded()))
        let rate1 = sampleRate / Double(d1)
        let d2 = max(1, Int((rate1 / basebandRate).rounded()))
        let rate = rate1 / Double(d2)

        // Mix: x[n] = a[n]·e^(−iωn). Blocks of 64 samples: a renormalised block phasor times a table
        // of the rotations within a block, so the inner loop has no recurrence and vectorises.
        let n = audio.count
        var re = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
        let w = -2 * Double.pi * centreHz / sampleRate
        let blockLength = 64
        let tableRe = (0..<blockLength).map { Float(cos(w * Double($0))) }
        let tableIm = (0..<blockLength).map { Float(sin(w * Double($0))) }
        let stepRe = cos(w * Double(blockLength)), stepIm = sin(w * Double(blockLength))
        var pr = 1.0, pi = 0.0
        audio.withUnsafeBufferPointer { x in
            var start = 0
            while start < n {
                let count = min(blockLength, n - start)
                let br = Float(pr), bi = Float(pi)
                for j in 0..<count {
                    let cr = br * tableRe[j] - bi * tableIm[j]
                    let ci = br * tableIm[j] + bi * tableRe[j]
                    re[start + j] = x[start + j] * cr
                    im[start + j] = x[start + j] * ci
                }
                let nr = pr * stepRe - pi * stepIm
                pi = pr * stepIm + pi * stepRe
                let r = (nr * nr + pi * pi).squareRoot()
                pr = nr / r
                pi /= r
                start += count
            }
        }

        // Stage 1: two cascaded d1-sample boxcars (a triangle of 2·d1 − 1 taps), every d1-th sample.
        let triLength = 2 * d1 - 1
        let tri = (0..<triLength).map { Float(min($0 + 1, triLength - $0)) / Float(d1 * d1) }
        let m1 = n >= triLength ? (n - triLength) / d1 + 1 : 0
        var re1 = [Float](repeating: 0, count: m1), im1 = re1
        if m1 > 0 {
            vDSP_desamp(re, d1, tri, &re1, vDSP_Length(m1), vDSP_Length(triLength))
            vDSP_desamp(im, d1, tri, &im1, vDSP_Length(m1), vDSP_Length(triLength))
        }
        guard d2 > 1 else { return ((0..<m1).map { SIMD2(re1[$0], im1[$0]) }, rate) }

        // Stage 2: windowed-sinc low-pass, every d2-th sample.
        let taps = firTaps
        let fc = min(firCutoffHz, 0.45 * rate1) / rate1
        let mid = Double(taps - 1) / 2
        var h = (0..<taps).map { j -> Float in
            let t = Double(j) - mid
            let sinc = t == 0 ? 2 * fc : sin(2 * .pi * fc * t) / (.pi * t)
            let blackman = 0.42 - 0.5 * cos(2 * .pi * Double(j) / Double(taps - 1))
                + 0.08 * cos(4 * .pi * Double(j) / Double(taps - 1))
            return Float(sinc * blackman)
        }
        let gain = h.reduce(0, +)
        h = h.map { $0 / gain }
        let m2 = m1 >= taps ? (m1 - taps) / d2 + 1 : 0
        var re2 = [Float](repeating: 0, count: m2), im2 = re2
        if m2 > 0 {
            vDSP_desamp(re1, d2, h, &re2, vDSP_Length(m2), vDSP_Length(taps))
            vDSP_desamp(im1, d2, h, &im2, vDSP_Length(m2), vDSP_Length(taps))
        }
        return ((0..<m2).map { SIMD2(re2[$0], im2[$0]) }, rate)
    }

    /// Time from the first audio sample to the centre of the first baseband sample's filter span.
    static func basebandDelaySeconds(sampleRate: Double) -> Double {
        let d1 = max(1, Int((sampleRate / stage1Rate).rounded()))
        let d2 = max(1, Int((sampleRate / Double(d1) / basebandRate).rounded()))
        return (Double(d1 - 1) + (d2 > 1 ? Double((firTaps - 1) / 2 * d1) : 0)) / sampleRate
    }

    /// Moving average of `length` samples, centred (the first and last samples use what exists).
    static func boxcar(_ z: [SIMD2<Float>], _ length: Int) -> [SIMD2<Float>] {
        guard length > 1, z.count > length else { return z }
        var out = [SIMD2<Float>](repeating: .zero, count: z.count)
        let before = length / 2
        var sum = SIMD2<Float>.zero
        var lo = 0, hi = 0                 // window [lo, hi)
        for i in z.indices {
            let wantLo = max(0, i - before), wantHi = min(z.count, i - before + length)
            while hi < wantHi { sum += z[hi]; hi += 1 }
            while lo < wantLo { sum -= z[lo]; lo += 1 }
            out[i] = sum / Float(hi - lo)
        }
        return out
    }

    // MARK: - Spectrum

    /// Welch power spectrum of the baseband (Hann, 50% overlap, segments up to 4 s), and the occupied
    /// region around the track.
    struct Spectrum {
        /// Power by bin, index `i` at `(i − zero)·binHz`.
        var power: [Float] = []
        var binHz = 1.0
        var zero = 0
        /// Median power over ±`analysisHalfWidthHz`, the noise reference.
        var median: Float = 0
        var region: Region?

        struct Region {
            var lowHz: Double
            var highHz: Double
            /// Width holding 90% of the region's power above the median (5th to 95th percentile).
            var bandwidthHz: Double
            /// Power centroid relative to the track's frequency.
            var centroidHz: Double
        }

        init(_ z: [SIMD2<Float>], rate: Double) {
            var segment = 128
            while segment * 2 <= min(z.count / 2, 2_048) { segment *= 2 }
            guard z.count >= segment, let dft = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(segment), .FORWARD)
            else { return }
            defer { vDSP_DFT_DestroySetup(dft) }
            let window = (0..<segment).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(segment))) }
            var inRe = [Float](repeating: 0, count: segment), inIm = inRe, outRe = inRe, outIm = inRe
            var sum = [Float](repeating: 0, count: segment)
            var segments = 0
            var start = 0
            while start + segment <= z.count {
                for j in 0..<segment {
                    inRe[j] = z[start + j].x * window[j]
                    inIm[j] = z[start + j].y * window[j]
                }
                vDSP_DFT_Execute(dft, inRe, inIm, &outRe, &outIm)
                for j in 0..<segment { sum[j] += outRe[j] * outRe[j] + outIm[j] * outIm[j] }
                segments += 1
                start += segment / 2
            }
            // fftshift: negative frequencies first.
            let half = segment / 2
            power = (0..<segment).map { sum[($0 + half) % segment] / Float(segments) }
            zero = half
            binHz = rate / Double(segment)
            let span = Int(SignalClassifier.analysisHalfWidthHz / binHz)
            let lo = max(0, zero - span), hi = min(segment - 1, zero + span)
            median = SignalClassifier.percentile(Array(power[lo...hi]), 0.5)
            region = findRegion(lo: lo, hi: hi)
        }

        func hz(_ bin: Int) -> Double { Double(bin - zero) * binHz }

        /// Strongest bin in a baseband frequency range, refined by parabolic interpolation.
        func peak(in range: ClosedRange<Double>) -> (hz: Double, power: Float)? {
            guard !power.isEmpty else { return nil }
            let lo = max(1, zero + Int((range.lowerBound / binHz).rounded(.up)))
            let hi = min(power.count - 2, zero + Int((range.upperBound / binHz).rounded(.down)))
            guard lo <= hi else { return nil }
            var best = lo
            for k in lo...hi where power[k] > power[best] { best = k }
            let a = power[best - 1], b = power[best], c = power[best + 1]
            let denom = a - 2 * b + c
            let delta = denom < 0 ? Double(min(max(0.5 * (a - c) / denom, -0.5), 0.5)) : 0
            return (hz(best) + delta * binHz, b)
        }

        /// Power centroid and total of the excess over the median within ±25 Hz of `hz`; nil if none.
        func lump(around hz: Double) -> (hz: Double, power: Float)? {
            let centre = zero + Int((hz / binHz).rounded())
            let radius = Int((25 / binHz).rounded())
            let lo = max(0, centre - radius), hi = min(power.count - 1, centre + radius)
            guard lo <= hi else { return nil }
            var total = 0.0, moment = 0.0
            for k in lo...hi {
                let e = Double(max(power[k] - median, 0))
                total += e
                moment += e * self.hz(k)
            }
            return total > 0 ? (moment / total, Float(total)) : nil
        }

        /// Bins ≥ 6 dB over the median, seeded within ±20 Hz of the centre, grown across gaps of up to
        /// 6 Hz (so an idle PSK31 twin or an FT8 tone set is one region, neighbours 40 Hz away are not).
        private func findRegion(lo: Int, hi: Int) -> Region? {
            let threshold = SignalClassifier.regionThreshold * median
            let seed = Int(SignalClassifier.regionSeedHz / binHz)
            let seeds = (max(lo, zero - seed)...min(hi, zero + seed)).filter { power[$0] > threshold }
            guard var first = seeds.first, var last = seeds.last else { return nil }
            let gap = Int((SignalClassifier.regionGapHz / binHz).rounded())
            var k = first - 1
            while k >= lo && first - k <= gap {
                if power[k] > threshold { first = k }
                k -= 1
            }
            k = last + 1
            while k <= hi && k - last <= gap {
                if power[k] > threshold { last = k }
                k += 1
            }
            let excess = (first...last).map { Double(max(power[$0] - median, 0)) }
            let total = excess.reduce(0, +)
            guard total > 0 else { return nil }
            // Each bin's excess spread uniformly over [k − ½, k + ½].
            func quantile(_ q: Double) -> Double {
                var acc = 0.0
                for (i, e) in excess.enumerated() {
                    if acc + e >= q * total {
                        let f = e > 0 ? (q * total - acc) / e : 0
                        return Double(first + i) - 0.5 + f
                    }
                    acc += e
                }
                return Double(last) + 0.5
            }
            let width = (quantile(0.95) - quantile(0.05)) * binHz
            var centroid = 0.0
            for (i, e) in excess.enumerated() { centroid += e * hz(first + i) }
            return Region(lowHz: hz(first), highHz: hz(last), bandwidthHz: width, centroidHz: centroid / total)
        }
    }

    // MARK: - Keying

    struct Keying {
        var envelopeRatio: Float
        /// Mean off level over mean on level, from an Otsu split.
        var depth: Float
        var keyDownRuns: Int
        var medianKeyDownSeconds: Double
        var medianKeyUpSeconds: Double

        /// Bimodal on/off keying: a deep split, at least `cwMinKeyDownRuns` key-down runs, and
        /// key-down and key-up runs with medians of at least `cwMinRunSeconds`.
        var isOnOff: Bool {
            depth < SignalClassifier.cwMaxDepth && keyDownRuns >= SignalClassifier.cwMinKeyDownRuns
                && medianKeyDownSeconds >= SignalClassifier.cwMinRunSeconds
                && medianKeyUpSeconds >= SignalClassifier.cwMinRunSeconds
        }
    }

    /// On/off structure of an envelope: an Otsu threshold on its histogram, then runs with ±15%
    /// hysteresis around it. Runs touching either end of the capture are left out of the medians.
    static func keying(_ e: [Float], rate: Double) -> Keying? {
        guard e.count >= 64 else { return nil }
        let (mean, sd) = meanAndDeviation(e)
        guard mean > 0 else { return nil }
        // Percentiles from every few samples: the envelope is smoothed over several anyway.
        let top = percentile(Array(stride(from: 0, to: e.count, by: max(1, e.count / 2_000)).map { e[$0] }), 0.99)
        guard top > 0 else { return nil }
        let bins = 64
        var histogram = [Double](repeating: 0, count: bins)
        for v in e { histogram[min(bins - 1, Int(v / top * Float(bins)))] += 1 }
        // Otsu: maximise the between-class variance.
        let total = Double(e.count)
        let sumAll = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset) * $1.element }
        var w0 = 0.0, sum0 = 0.0, best = -1.0, split = bins / 2
        for t in 0..<(bins - 1) {
            w0 += histogram[t]
            sum0 += Double(t) * histogram[t]
            let w1 = total - w0
            guard w0 > 0, w1 > 0 else { continue }
            let m0 = sum0 / w0, m1 = (sumAll - sum0) / w1
            let between = w0 * w1 * (m0 - m1) * (m0 - m1)
            if between > best { best = between; split = t + 1 }
        }
        let threshold = Float(split) / Float(bins) * top
        var onSum: Float = 0, offSum: Float = 0, onCount = 0, offCount = 0
        for v in e {
            if v >= threshold { onSum += v; onCount += 1 } else { offSum += v; offCount += 1 }
        }
        guard onCount > 0, offCount > 0 else { return nil }
        let depth = (offSum / Float(offCount)) / (onSum / Float(onCount))

        var runs: [(on: Bool, length: Int)] = []
        var state = e[0] >= threshold
        var length = 0
        for v in e {
            let next = state ? v >= 0.85 * threshold : v > 1.15 * threshold
            if next == state {
                length += 1
            } else {
                runs.append((state, length))
                state = next
                length = 1
            }
        }
        runs.append((state, length))
        let inner = runs.count > 2 ? Array(runs[1..<(runs.count - 1)]) : []
        let down = inner.filter(\.on).map { Double($0.length) / rate }
        let up = inner.filter { !$0.on }.map { Double($0.length) / rate }
        return Keying(envelopeRatio: sd / mean, depth: depth, keyDownRuns: runs.filter(\.on).count,
                      medianKeyDownSeconds: median(down), medianKeyUpSeconds: median(up))
    }

    /// Onset and end of a transmission: 50 ms block energies against the geometric mean of their
    /// 3rd and 90th percentiles (when those are at least 10 dB apart). An onset needs ≥ 0.25 s below
    /// before and ≥ 1 s above after; an end the reverse. `onThroughout` means no on/off contrast at
    /// all (on throughout when the caller knows a signal is present).
    static func onOffEdges(_ e: [Float], rate: Double) -> (onset: Double?, end: Double?, onThroughout: Bool) {
        let block = max(1, Int((0.05 * rate).rounded()))
        let count = e.count / block
        guard count >= 8 else { return (nil, nil, false) }
        var energy = [Float](repeating: 0, count: count)
        for b in 0..<count {
            var s: Float = 0
            for j in 0..<block { s += e[b * block + j] * e[b * block + j] }
            energy[b] = s / Float(block)
        }
        let low = percentile(energy, 0.03), high = percentile(energy, 0.9)
        guard high > 10 * max(low, 1e-30) else { return (nil, nil, low > 0) }
        let threshold = (low * high).squareRoot()
        let above = energy.map { $0 > threshold }
        let before = 5, after = 20                  // 0.25 s and 1 s of blocks
        var onset: Double?, end: Double?
        for b in before..<count where above[b] && !above[b - 1] {
            let quiet = above[(b - before)..<b].filter { !$0 }.count >= before - 1
            let held = b + after <= count && above[b..<(b + after)].filter { $0 }.count >= after - 2
            if quiet && held { onset = Double(b * block) / rate; break }
        }
        for b in stride(from: count - before, through: after, by: -1) where !above[b] && above[b - 1] {
            let quiet = above[b..<(b + before)].filter { !$0 }.count >= before - 1
            let held = above[(b - after)..<b].filter { $0 }.count >= after - 2
            if quiet && held { end = Double(b * block) / rate; break }
        }
        return (onset, end, false)
    }

    // MARK: - PSK31 trial demodulation

    struct PSKTrial {
        /// The 31.25 Hz line of |z|² over the mean of its neighbourhood (±3…9 Hz), in dB.
        var lineDb: Float
        /// |mean(u²)| and |mean(u⁴)| of the unit differential phasors u of consecutive symbols.
        var fit2: Float
        var fit4: Float
        /// Fraction of phase changes larger than 45°: zero for a carrier, about 0.4 for BPSK31 text.
        var transitions: Float
        var symbols: Int
    }

    /// Finds the symbol clock from the 31.25 Hz line of |z|² (Oerder–Meyr: |z|² peaks at the symbol
    /// instants and dips between them on every phase change), samples the baseband there through a
    /// one-symbol Hann filter (close to matched to PSK31's cosine-shaped transitions) and measures how
    /// well successive phase changes fit 2 (BPSK) or 4 (QPSK) points. Symbols below a fifth of the
    /// on level (gaps, noise before the onset) are skipped.
    static func pskTrial(_ z: [SIMD2<Float>], rate: Double) -> PSKTrial {
        let symbol = rate / pskSymbolRate
        // |z|² after a quarter-symbol boxcar, summed in blocks of 4 (125 Hz: the lines searched lie
        // below 41 Hz).
        let power = boxcar(z, max(1, Int((symbol / 4).rounded()))).map { simd_length_squared($0) }
        let block = 4
        let p = (0..<(power.count / block)).map { b in power[(b * block)..<((b + 1) * block)].reduce(0, +) }
        let pRate = rate / Double(block)
        let mean = p.reduce(0, +) / Float(max(p.count, 1))
        func line(_ hz: Double) -> SIMD2<Double> {
            let w = -2 * Double.pi * hz / pRate
            let cw = cos(w), sw = sin(w)
            var c = 1.0, s = 0.0, re = 0.0, im = 0.0
            for (n, v) in p.enumerated() {
                let x = Double(v - mean)
                re += x * c
                im += x * s
                let nc = c * cw - s * sw
                s = s * cw + c * sw
                c = nc
                if n & 1_023 == 1_023 {
                    let r = (c * c + s * s).squareRoot()
                    c /= r
                    s /= r
                }
            }
            return SIMD2(re, im)
        }
        let clock = line(pskSymbolRate)
        var reference = 0.0
        let offsets: [Double] = [3, 4.5, 6, 7.5, 9]
        for d in offsets {
            for sign in [-1.0, 1.0] {
                let x = line(pskSymbolRate + sign * d)
                reference += x.x * x.x + x.y * x.y
            }
        }
        reference /= Double(2 * offsets.count)
        let clockPower = clock.x * clock.x + clock.y * clock.y
        let lineDb = Float(10 * log10(max(clockPower, 1e-30) / max(reference, 1e-30)))

        // |z|² ≈ a + b·cos(ω(n − n0)) gives X ≈ (b/2)·N·e^(−iωn0); block b covers samples
        // 4b…4b + 3, centred on 4b + 1.5.
        let omega = 2 * Double.pi * pskSymbolRate / rate
        var n0 = -atan2(clock.y, clock.x) / omega + Double(block - 1) / 2
        n0 = n0.truncatingRemainder(dividingBy: symbol)
        if n0 < 0 { n0 += symbol }
        let filtered = hann(z, 2 * Int((symbol / 2).rounded()) + 1)
        var samples: [SIMD2<Float>] = []
        var t = n0
        while t < Double(filtered.count - 1) {
            let i = Int(t), f = Float(t - Double(i))
            samples.append(filtered[i] * (1 - f) + filtered[i + 1] * f)
            t += symbol
        }
        let levels = samples.map { simd_length_squared($0) }
        let onLevel = percentile(levels, 0.8)
        var sum2 = SIMD2<Float>.zero, sum4 = SIMD2<Float>.zero
        var count = 0, changes = 0
        let cos45 = Float(0.5).squareRoot()
        for k in samples.indices.dropFirst() where levels[k] > 0.2 * onLevel && levels[k - 1] > 0.2 * onLevel {
            let d = cmul(samples[k], SIMD2(samples[k - 1].x, -samples[k - 1].y))
            let length = simd_length(d)
            guard length > 0 else { continue }
            let u = d / length
            let u2 = cmul(u, u)
            sum2 += u2
            sum4 += cmul(u2, u2)
            count += 1
            if u.x < cos45 { changes += 1 }
        }
        guard count > 0 else { return PSKTrial(lineDb: lineDb, fit2: 0, fit4: 0, transitions: 0, symbols: 0) }
        return PSKTrial(lineDb: lineDb, fit2: simd_length(sum2) / Float(count), fit4: simd_length(sum4) / Float(count),
                        transitions: Float(changes) / Float(count), symbols: count)
    }

    /// Centred FIR with Hann taps `0.5 − 0.5·cos(2π(j + 1)/(length + 1))`, unity gain at DC; `length`
    /// odd. The ends use the taps that fall inside the data.
    static func hann(_ z: [SIMD2<Float>], _ length: Int) -> [SIMD2<Float>] {
        let taps = (0..<length).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0 + 1) / Double(length + 1))) }
        let gain = taps.reduce(0, +)
        let half = length / 2
        var out = [SIMD2<Float>](repeating: .zero, count: z.count)
        for i in z.indices {
            var acc = SIMD2<Float>.zero
            for j in max(0, half - i)..<min(length, z.count - i + half) { acc += taps[j] * z[i - half + j] }
            out[i] = acc / gain
        }
        return out
    }

    // MARK: - Tone grids (FT8, WSPR)

    struct ToneGrid {
        /// |mean(e^(2πi·f/spacing))| over the dominant tones of clean frames: 1 when all sit on one grid.
        var fit: Float
        var distinct: Int
        var spanSteps: Int
    }

    /// Splits the baseband into one-symbol frames at quarter-symbol steps and finds each frame's
    /// dominant tone on an 8× oversampled grid within `span`, with its concentration (the share of
    /// the frame's in-span power within half a tone spacing of it). Of the four symbol phases, the one
    /// with the highest mean concentration is aligned with the symbols; its frames whose dominant
    /// tone holds at least half the power give the tones. Nil with fewer than 4 such frames.
    static func toneGrid(_ z: [SIMD2<Float>], rate: Double, symbolSeconds: Double, spacingHz: Double,
                         span: ClosedRange<Double>) -> ToneGrid? {
        let symbol = symbolSeconds * rate
        let frame = Int(symbol.rounded())
        guard frame >= 8, z.count >= frame else { return nil }
        let step = spacingHz / 8
        let freqs = stride(from: span.lowerBound, through: span.upperBound, by: step).map { $0 }
        guard freqs.count >= 9 else { return nil }
        // Twiddles per grid frequency over one frame.
        var twiddle = [SIMD2<Float>](repeating: .zero, count: freqs.count * frame)
        for (fi, f) in freqs.enumerated() {
            for n in 0..<frame {
                let p = -2 * Double.pi * f * Double(n) / rate
                twiddle[fi * frame + n] = SIMD2(Float(cos(p)), Float(sin(p)))
            }
        }
        let lobe = 4                                       // ±half a tone spacing, in grid steps
        var frames: [(phase: Int, hz: Double, concentration: Float)] = []
        var power = [Float](repeating: 0, count: freqs.count)
        var k = 0
        while true {
            let start = Int((Double(k) * symbol / 4).rounded())
            guard start + frame <= z.count else { break }
            defer { k += 1 }
            for fi in freqs.indices {
                var acc = SIMD2<Float>.zero
                let base = fi * frame
                for n in 0..<frame { acc += cmul(z[start + n], twiddle[base + n]) }
                power[fi] = simd_length_squared(acc)
            }
            var best = 0
            for fi in power.indices where power[fi] > power[best] { best = fi }
            let total = power.reduce(0, +)
            guard total > 0, best > 0, best < power.count - 1 else { continue }
            let lobeSum = power[max(0, best - lobe)...min(power.count - 1, best + lobe)].reduce(0, +)
            let a = power[best - 1], b = power[best], c = power[best + 1]
            let denom = a - 2 * b + c
            let delta = denom < 0 ? Double(min(max(0.5 * (a - c) / denom, -0.5), 0.5)) : 0
            frames.append((k % 4, freqs[best] + delta * step, lobeSum / total))
        }
        var sums = [Float](repeating: 0, count: 4), counts = [Float](repeating: 0, count: 4)
        for f in frames {
            sums[f.phase] += f.concentration
            counts[f.phase] += 1
        }
        let means = (0..<4).map { sums[$0] / max(counts[$0], 1) }
        let phase = means.indices.max { means[$0] < means[$1] } ?? 0
        let tones = frames.filter { $0.phase == phase && $0.concentration >= toneFrameConcentration }.map(\.hz)
        guard tones.count >= 4 else { return nil }
        var phasor = SIMD2<Double>.zero
        for f in tones {
            let p = 2 * Double.pi * f / spacingHz
            phasor += SIMD2(cos(p), sin(p))
        }
        phasor /= Double(tones.count)
        let offset = atan2(phasor.y, phasor.x) / (2 * .pi) * spacingHz
        let indices = Set(tones.map { Int((($0 - offset) / spacingHz).rounded()) })
        return ToneGrid(fit: Float(simd_length(phasor)), distinct: indices.count,
                        spanSteps: (indices.max() ?? 0) - (indices.min() ?? 0))
    }

    // MARK: - Statistics

    static func percentile(_ x: [Float], _ q: Double) -> Float {
        guard !x.isEmpty else { return 0 }
        let sorted = x.sorted()
        return sorted[min(sorted.count - 1, max(0, Int((q * Double(sorted.count - 1)).rounded())))]
    }

    static func median(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        let s = x.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func meanAndDeviation(_ x: [Float]) -> (mean: Float, deviation: Float) {
        guard !x.isEmpty else { return (0, 0) }
        let mean = x.reduce(0, +) / Float(x.count)
        let variance = x.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(x.count)
        return (mean, variance.squareRoot())
    }

    /// `x` minus its centred moving average of 2h + 1 samples (the ends are dropped).
    static func highPass(_ x: [Float], _ h: Int) -> [Float] {
        guard x.count > 2 * h + 1 else { return [] }
        var out = [Float](repeating: 0, count: x.count - 2 * h)
        var sum = x[0...(2 * h)].reduce(0, +)
        for i in out.indices {
            if i > 0 { sum += x[i + 2 * h] - x[i - 1] }
            out[i] = x[i + h] - sum / Float(2 * h + 1)
        }
        return out
    }

    static func correlation(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, a.count >= 8 else { return nil }
        let ma = a.reduce(0, +) / Float(a.count), mb = b.reduce(0, +) / Float(b.count)
        var cov: Float = 0, va: Float = 0, vb: Float = 0
        for i in a.indices {
            let x = a[i] - ma, y = b[i] - mb
            cov += x * y
            va += x * x
            vb += y * y
        }
        guard va > 0, vb > 0 else { return nil }
        return cov / (va * vb).squareRoot()
    }
}
