import Accelerate
import DSPCore
import Foundation
import simd

/// Multi-signal PSK31 decoder (BPSK31 and QPSK31): each instance decodes one signal at its own audio
/// frequency from 12 kHz box audio, and detects which of the two modes it is.
public enum PSK31Modem: StreamingModem {
    public static let id: ModeID = .psk31

    public static func makeDecoder(frequencyHz: Double, sampleRate: Double) -> any SignalDecoder {
        PSK31SignalDecoder(frequencyHz: frequencyHz, sampleRate: sampleRate)
    }
}

/// One PSK31 signal.
///
/// Signal chain:
/// 1. NCO mix to baseband, then two decimating low-pass stages (12 kHz → 1.5 kHz → 500 Hz, 16 samples
///    per symbol). The second stage is the channel filter: −6 dB at ±65 Hz, transition 40…90 Hz.
/// 2. Matched filter: the PSK31 transmit pulse, a raised cosine two symbols long (each phase change
///    takes one symbol).
/// 3. Gardner timing recovery with linear interpolation, a fast gain for 64 symbols after acquisition
///    and slower after. A feed-forward Oerder–Meyr estimate (the 31.25 Hz line of |MF|²) supervises
///    it: Gardner escapes its unstable point only slowly at low SNR.
/// 4. Two carrier loops on the symbols, side by side: a Costas loop for BPSK and a fourth-power loop
///    for QPSK. While the active mode's squelch is open its loop frequency is integrated into the NCO
///    (AFC; a third-order loop overall, so a drift is followed without phase lag).
/// 5. Acquisition: every 128 baseband samples an FFT of z² and z⁴ over the last 1.02 s finds the
///    modulation-free carrier line. It is unambiguous over the whole ±15 Hz lock range, rejects idle
///    sidelines of signals outside it and the broad cross-terms of strong neighbours, re-tunes the
///    NCO (on two agreeing estimates) while the loops are unlocked, and is the presence detector.
///    While locked, the line must stay at zero offset or the lock is declared false.
/// 6. BPSK: the matched-filter output has known inter-symbol interference (≈ 1/6 of each neighbour),
///    so symbols are decided by a two-state maximum-likelihood sequence detector, then differentially
///    decoded (no change = 1, reversal = 0). QPSK: the interference is cancelled with hard decisions,
///    and the differential phase of successive symbols feeds the K = 5 Viterbi decoder.
/// 7. Varicode: a character ends at "00".
///
/// Squelch (per mode path): open when a carrier line is present, the average constellation fit
/// (cos 2φ for BPSK, cos 4φ for QPSK, an EMA over symbols) is above threshold, the last 8 symbols
/// each fitted, the envelope carries the 31.25 Hz symbol clock and few symbols fell near zero (the
/// last two reject CW and other keyed carriers). Each character must also fit on average over its
/// own symbols. When the squelch opens, characters decoded since the carrier was found that fit
/// closely are recovered.
///
/// Mode detection: over the last 64 differential phases, the spread around the 2-point (0/180°) and
/// 4-point (0/90/180/270°) hypotheses. On a switch, the characters the other path decoded while
/// detection caught up are recovered from its history.
///
/// Not thread-safe; owned by one thread at a time (see `SignalDecoder`).
public final class PSK31SignalDecoder: SignalDecoder {
    /// The carrier frequency: the NCO plus, while locked, the active loop's residual.
    public var frequencyHz: Double {
        guard activeSquelchOpen else { return tunedHz }
        return tunedHz + Double(mode == .bpsk ? omega2 : omega4) * Self.symbolRate / (2 * .pi)
    }
    public var submode: String { mode == .qpsk ? "QPSK31" : "BPSK31" }

    enum Mode { case bpsk, qpsk }

    // MARK: Constants

    static let symbolRate = 31.25
    private static let stage1Rate = 1_500.0
    private static let basebandTarget = 500.0
    /// Channel filter: −6 dB at 65 Hz, transition 40...90 Hz.
    private static let channelCutoffHz = 65.0
    private static let channelTransitionHz = 50.0

    private static let fftSize = 512
    private static let fftHop = 128
    /// Half-width, in bins, of the local background a carrier line is measured against.
    private static let backgroundBins = 24
    /// Carrier-line presence thresholds: line power over its local background, scaled so that noise
    /// reads like peak over median.
    private static let presenceOn: Float = 18
    private static let presenceOff: Float = 10
    /// Without a carrier for this long, return to the assigned frequency.
    private static let returnAfterSeconds = 5.0
    /// Re-tune the NCO from the FFT only when the line is at least this far off, in Hz.
    private static let jumpMinHz = 1.0

    /// Timing loop gains (fraction of the normalised Gardner error, in samples).
    private static let timingFastGain = 0.3
    private static let timingSlowGain = 0.12
    private static let fastSymbols = 64

    /// Carrier loop noise bandwidths, Hz.
    private static let loopFastHz = 4.0
    private static let loopSlowHz = 2.0
    /// Fraction of the loop frequency moved into the NCO per symbol.
    private static let afcTransfer = 0.05

    /// Minimum normalised symbol-clock line for the squelch.
    private static let clockLineMin: Float = 0.012
    /// Minimum mean fit over a character's own symbols.
    private static let charFitBPSK: Float = 0.35
    private static let charFitQPSK: Float = 0.35

    /// Characters recovered when the squelch opens must fit this well and start this many symbols
    /// after the carrier was found.
    private static let recoveryFit: Float = 0.6
    private static let recoverySettle = 8
    /// Mode detection.
    private static let modeWindow = 64
    private static let modeEvery = 8

    private static let historyRing = 256

    // MARK: State

    private let sampleRate: Double
    private let originHz: Double
    private var tunedHz: Double
    private var nco: NCO
    private var stage1: ComplexDecimator
    private var stage2: ComplexDecimator
    private let basebandRate: Double
    private let samplesPerSymbol: Double
    private let matched: [Float]

    private var scratch: [DSPComplex] = []
    private var mid1: [DSPComplex] = []
    private var baseband: [DSPComplex] = []

    // Matched filter input ring and output ring (for interpolation).
    private var mfIn: [SIMD2<Float>]
    private var mfInHead = 0
    private var mfOut = [SIMD2<Float>](repeating: .zero, count: 64)
    private var mfCount = 0

    // Timing.
    private var nextStrobe: Double
    /// Oerder–Meyr: the symbol-rate line of |matched filter|², as a running sum and its phasor.
    private var omSum = SIMD2<Float>.zero
    private var omMean: Float = 0
    private var omPhasor = SIMD2<Float>(1, 0)
    private let omStep: SIMD2<Float>
    private var omDisagree = 0
    private var yPrev = SIMD2<Float>.zero
    private var fastLeft = PSK31SignalDecoder.fastSymbols
    private var power: Float = 1e-12
    private var lowRing = [Bool](repeating: false, count: 32)
    private var lowCount = 0
    private var clocked = false
    private var symbolIndex = 0

    // Carrier loops.
    private var theta2: Float = 0, omega2: Float = 0
    private var theta4: Float = 0, omega4: Float = 0

    // FFT presence / acquisition.
    private let dft: vDSP_DFT_Setup
    private var fftRing: [SIMD2<Float>]
    private var fftHead = 0
    private var sinceFFT = 0
    private var freshSamples = 0
    private var fftWindow: [Float]
    private var fftInRe: [Float], fftInIm: [Float], fftOutRe: [Float], fftOutIm: [Float]
    private var fftPower: [Float]
    private var prefix: [Double] = []
    private var line2: Float = 0, line4: Float = 0
    private var present = false
    private var inconsistent = 0
    private var candidateHz = Double.nan
    private var absentEstimates = 0
    /// Symbol index of the last presence onset or NCO re-tune.
    private var acquiredAt = Int.min

    // BPSK path.
    private var bpsk = BPSKSequenceDetector()
    private var zRing = [SIMD2<Float>](repeating: .zero, count: 64)
    private var ampA: Float = 0
    private var isiC: Float = 0
    private var bpskVaricode = VaricodeAssembler()
    private var bpskSquelch = Squelch()
    private var bpskFit = [Float](repeating: 0, count: historyRing)

    // QPSK path.
    private var viterbi = QPSKViterbi()
    private var qpskVaricode = VaricodeAssembler()
    private var qpskSquelch = Squelch()
    private var qpskFit = [Float](repeating: 0, count: historyRing)
    private var qpskOdd = [Bool](repeating: false, count: historyRing)
    private var ampA4: Float = 0
    private var isiC4: Float = 0
    private var r4History = [SIMD2<Float>](repeating: .zero, count: 4)
    private var cleanedPrev = SIMD2<Float>.zero

    // Mode detection over differential phases.
    private var mode = Mode.bpsk
    private var dist2 = [Float](repeating: 0, count: modeWindow)
    private var dist4 = [Float](repeating: 0, count: modeWindow)
    private var zeroShift = [Bool](repeating: false, count: modeWindow)
    private var sum2: Float = 0, sum4: Float = 0, zeros = 0, modeFilled = 0, validRun = 0

    // Output.
    private var bpskHistory: [DecodedChar] = []
    private var qpskHistory: [DecodedChar] = []
    private var lastEmittedEnd = Int.min
    private var lastWasCR = false
    private var output = ""
    private var points = [SIMD2<Float>](repeating: .zero, count: 128)
    private var pointCount = 0

    struct DecodedChar {
        var ascii: UInt8
        var start: Int
        var end: Int
        /// Mean constellation fit over the character's own symbols.
        var fit: Float
        /// Passed the per-character checks.
        var gated: Bool
        /// Gated, and the path's squelch was open when it completed.
        var passed = false
    }

    public init(frequencyHz: Double, sampleRate: Double = 12_000) {
        self.sampleRate = sampleRate
        originHz = frequencyHz
        tunedHz = frequencyHz
        nco = NCO(frequency: -frequencyHz, sampleRate: sampleRate)
        let f1 = max(1, Int((sampleRate / Self.stage1Rate).rounded()))
        let rate1 = sampleRate / Double(f1)
        let f2 = max(1, Int((rate1 / Self.basebandTarget).rounded()))
        basebandRate = rate1 / Double(f2)
        samplesPerSymbol = basebandRate / Self.symbolRate
        (stage1, stage2) = Self.makeDecimators(sampleRate: sampleRate, f1: f1, f2: f2)
        // Matched filter: the transmit pulse ½(1 + cos(πt/T)), |t| < T.
        let half = Int(samplesPerSymbol.rounded())
        var h = (-half...half).map { Float(0.5 * (1 + cos(Double.pi * Double($0) / Double(half)))) }
        let sum = h.reduce(0, +)
        h = h.map { $0 / sum }
        matched = h
        mfIn = [SIMD2<Float>](repeating: .zero, count: h.count)
        nextStrobe = samplesPerSymbol
        let w = -2 * Double.pi / samplesPerSymbol
        omStep = SIMD2(Float(cos(w)), Float(sin(w)))
        dft = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.fftSize), .FORWARD)!
        fftRing = [SIMD2<Float>](repeating: .zero, count: Self.fftSize)
        fftWindow = (0..<Self.fftSize).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(Self.fftSize))) }
        fftInRe = [Float](repeating: 0, count: Self.fftSize)
        fftInIm = fftInRe; fftOutRe = fftInRe; fftOutIm = fftInRe; fftPower = fftInRe
    }

    deinit { vDSP_DFT_DestroySetup(dft) }

    private static func makeDecimators(sampleRate: Double, f1: Int, f2: Int) -> (ComplexDecimator, ComplexDecimator) {
        let rate1 = sampleRate / Double(f1)
        // Stage 1 only has to stop what would alias onto the channel: everything within ±120 Hz of a
        // multiple of the stage-1 rate.
        let taps1 = FIRDesign.tapCount(transition: max(rate1 - 240, 100) / sampleRate)
        let s1 = ComplexDecimator(taps: FIRDesign.lowpass(taps: max(taps1, f1), cutoff: 0.5 * rate1 / sampleRate), factor: f1)
        let taps2 = FIRDesign.tapCount(transition: channelTransitionHz / rate1)
        let s2 = ComplexDecimator(taps: FIRDesign.lowpass(taps: max(taps2, f2), cutoff: channelCutoffHz / rate1), factor: f2)
        return (s1, s2)
    }

    // MARK: Processing

    public func process(_ audio: UnsafeBufferPointer<Float>) -> String {
        guard !audio.isEmpty else { return "" }
        output.removeAll(keepingCapacity: true)
        if scratch.count < audio.count { scratch = .init(repeating: DSPComplex(real: 0, imag: 0), count: audio.count) }
        for i in 0..<audio.count { scratch[i] = DSPComplex(real: audio[i], imag: 0) }
        scratch.withUnsafeMutableBufferPointer { s in
            nco.mix(UnsafeMutableBufferPointer(rebasing: s[0..<audio.count]))
        }
        mid1.removeAll(keepingCapacity: true)
        scratch.withUnsafeBufferPointer { s in
            stage1.process(UnsafeBufferPointer(rebasing: s[0..<audio.count]), into: &mid1)
        }
        baseband.removeAll(keepingCapacity: true)
        mid1.withUnsafeBufferPointer { stage2.process($0, into: &baseband) }
        for z in baseband { basebandSample(SIMD2(z.real, z.imag)) }
        return output
    }

    private func basebandSample(_ z: SIMD2<Float>) {
        // Acquisition FFT ring.
        fftRing[fftHead] = z
        fftHead = (fftHead + 1) & (Self.fftSize - 1)
        freshSamples += 1
        sinceFFT += 1
        if sinceFFT >= Self.fftHop {
            sinceFFT = 0
            if freshSamples >= Self.fftSize { analyseCarrierLine() }
        }

        // Matched filter.
        mfIn[mfInHead] = z
        mfInHead = (mfInHead + 1) % mfIn.count
        var acc = SIMD2<Float>.zero
        var idx = mfInHead
        for t in 0..<matched.count {
            acc += matched[t] * mfIn[idx]
            idx += 1
            if idx == mfIn.count { idx = 0 }
        }
        mfOut[mfCount & 63] = acc
        // Oerder–Meyr accumulator over about 64 symbols: |m|² peaks at the symbol instants.
        let a = Float(1 / (64 * samplesPerSymbol))
        omSum += a * (simd_length_squared(acc) * omPhasor - omSum)
        omMean += a * (simd_length_squared(acc) - omMean)
        omPhasor = cmul(omPhasor, omStep)
        if mfCount & 255 == 0 { omPhasor /= simd_length(omPhasor) }
        mfCount += 1

        // Symbol strobes, interpolating between matched-filter outputs.
        let newest = Double(mfCount - 1)
        while nextStrobe <= newest {
            let y = interpolate(at: nextStrobe)
            let mid = interpolate(at: nextStrobe - samplesPerSymbol / 2)
            symbol(y, mid: mid)
        }
    }

    private func interpolate(at x: Double) -> SIMD2<Float> {
        let clamped = max(x, Double(mfCount - 60))
        let i = Int(clamped.rounded(.down))
        let f = Float(clamped - Double(i))
        let a = mfOut[i & 63], b = mfOut[(i + 1) & 63]
        return a + f * (b - a)
    }

    // MARK: Symbol processing

    private func symbol(_ y: SIMD2<Float>, mid: SIMD2<Float>) {
        let k = symbolIndex
        symbolIndex += 1
        let wasOpen = activeSquelchOpen
        // Envelope: PSK31 symbols never fall near zero (the worst interference leaves 2/3 of the
        // amplitude); on-off keyed signals (CW, one tone of RTTY) spend a quarter or more of their
        // symbols there. Count the recent symbols below a tenth of the mean power.
        let low = simd_length_squared(y) < 0.1 * power
        if lowRing[k & 31] { lowCount -= 1 }
        lowRing[k & 31] = low
        if low { lowCount += 1 }
        power += (simd_length_squared(y) - power) / 32
        // Symbol clock: PSK31's envelope dips at every reversal, so |m|² carries a steady 31.25 Hz
        // line. Keyed carriers (CW) do not: measured, PSK31 at −10…+10 dB ≥ 0.023 (5th percentile),
        // CW at 12–40 WPM ≤ 0.012 (95th percentile).
        clocked = simd_length(omSum) >= Self.clockLineMin * omMean
        let p = max(power, 1e-20)

        superviseTiming()

        // Gardner timing error, normalised by the symbol power.
        let diff = y - yPrev
        let e = Double((diff.x * mid.x + diff.y * mid.y) / p)
        let gain = fastLeft > 0 ? Self.timingFastGain : Self.timingSlowGain
        let step = min(max(-gain * e, -1.5), 1.5)
        nextStrobe += samplesPerSymbol + step
        yPrev = y
        if fastLeft > 0 { fastLeft -= 1 }

        // Carrier loops.
        let (alpha, beta) = Self.loopGains(bandwidthHz: fastLeft > 0 ? Self.loopFastHz : Self.loopSlowHz)
        let r2 = rotate(y, by: -theta2)
        let e2 = min(max(r2.x * r2.y / p, -1), 1)
        theta2 = wrap(theta2 + omega2 + alpha * e2)
        omega2 += beta * e2
        let r4 = rotate(y, by: -theta4)
        let r4sq = cmul(r4, r4)
        let e4 = min(max(cmul(r4sq, r4sq).y / (4 * p * p), -1), 1)
        theta4 = wrap(theta4 + omega4 + alpha * e4)
        omega4 += beta * e4
        if !present {
            // No carrier: keep the integrators from random-walking on noise.
            omega2 *= 0.9; omega4 *= 0.9
        }

        // BPSK squelch metric: how tightly the symbol sits on the 0/180° axis. The interference is
        // in phase with the symbol, so the angle needs no cleaning.
        let m2 = simd_length_squared(r2)
        let q2: Float = m2 > 1e-20 ? (r2.x * r2.x - r2.y * r2.y) / m2 : 0
        bpskFit[k & (Self.historyRing - 1)] = q2
        bpskSquelch.update(q2, present: present, lowSymbols: lowCount, clocked: clocked)

        transferAFC()
        bpskPath(r2, k: k)
        qpskPath(r4, k: k)
        if !wasOpen && activeSquelchOpen { recoverOnOpen(k: k) }
        if (k % Self.modeEvery) == 0 { decideMode(k: k) }
    }

    private var activeSquelchOpen: Bool { mode == .bpsk ? bpskSquelch.isOpen : qpskSquelch.isOpen }

    /// The squelch opens some symbols after the loops have locked; the characters decoded in between
    /// are usually right. When it opens, emit those that started well after the carrier was found
    /// (the last presence onset or re-tune) and fit the constellation closely over their own symbols.
    private func recoverOnOpen(k: Int) {
        guard acquiredAt != Int.min else { return }
        let history = mode == .bpsk ? bpskHistory : qpskHistory
        for ch in history where ch.gated && ch.fit >= Self.recoveryFit && ch.end > lastEmittedEnd
            && ch.start >= acquiredAt + Self.recoverySettle && ch.end >= k - 3 * Self.modeWindow / 2 {
            emit(ch)
        }
    }

    /// Gardner alone escapes its unstable point (half a symbol off) only slowly at low SNR, and starts
    /// anywhere after the carrier is found. The feed-forward Oerder–Meyr estimate has no such point:
    /// when it and the strobe disagree by more than a quarter symbol for 8 symbols with a carrier
    /// present, the strobe jumps to it and Gardner carries on from there.
    private func superviseTiming() {
        guard present, simd_length_squared(omSum) > 0 else { omDisagree = 0; return }
        // The phasor at MF index n is e^{-j2πn/sps}, so the line's phase is -2π·n0/sps.
        let sps = samplesPerSymbol
        let n0 = -Double(atan2(omSum.y, omSum.x)) / (2 * .pi) * sps
        // nextStrobe is the strobe just used (it advances after the timing update).
        var diff = (n0 - nextStrobe).truncatingRemainder(dividingBy: sps)
        if diff > sps / 2 { diff -= sps } else if diff < -sps / 2 { diff += sps }
        omDisagree = abs(diff) > sps / 4 ? omDisagree + 1 : 0
        if omDisagree >= 8 {
            nextStrobe += diff
            omDisagree = 0
            fastLeft = max(fastLeft, Self.fastSymbols / 2)
        }
    }

    /// Second-order loop gains for noise bandwidth `bandwidthHz`, damping 0.707, at the symbol rate.
    private static func loopGains(bandwidthHz: Double) -> (Float, Float) {
        let zeta = 0.707
        let bt = bandwidthHz / symbolRate
        let thetaN = bt / (zeta + 1 / (4 * zeta))
        let denom = 1 + 2 * zeta * thetaN + thetaN * thetaN
        return (Float(4 * zeta * thetaN / denom), Float(4 * thetaN * thetaN / denom))
    }

    /// AFC: while the active loop is locked, the NCO integrates a fraction of that loop's frequency.
    /// The loops see the NCO move and their own integrators follow, so the NCO is a third integrator
    /// and the whole loop is third order: closed-loop polynomial s³ + αs² + βs + γβ, stable while
    /// α > γ (α ≥ 0.15 here, γ = 0.05). It tracks a frequency ramp with no steady-state phase error,
    /// and it leaves the inactive loop's own frequency estimate alone.
    private func transferAFC() {
        let open = mode == .bpsk ? bpskSquelch.isOpen : qpskSquelch.isOpen
        guard open else { return }
        let omega = mode == .bpsk ? omega2 : omega4
        let stepHz = Double(omega) * Self.afcTransfer * Self.symbolRate / (2 * .pi)
        let limit = ModeID.psk31.lockRangeHz
        let target = min(max(tunedHz + stepHz, originHz - limit), originHz + limit)
        guard target != tunedHz else { return }
        tunedHz = target
        nco.setFrequency(-tunedHz, sampleRate: sampleRate)
    }

    // MARK: BPSK

    private func bpskPath(_ r: SIMD2<Float>, k: Int) {
        if ampA <= 0 { ampA = sqrt(power) * 0.75; isiC = ampA / 6 }
        zRing[k & 63] = r
        guard let decided = bpsk.push(r.x, isi: isiC) else { return }
        let j = k - BPSKSequenceDetector.depth
        let z = zRing[j & 63]
        // Track the main tap and the neighbour interference from the decisions (LMS).
        let neighbours = decided.previous + decided.next
        let err = z.x - (ampA * decided.current + isiC * neighbours)
        ampA = max(ampA + 0.02 * err * decided.current, 1e-12)
        isiC = min(max(isiC + 0.01 * err * neighbours, 0), 0.3 * ampA)

        if mode == .bpsk && bpskSquelch.isOpen {
            let cleaned = SIMD2(z.x - isiC * neighbours, z.y) / ampA
            addPoint(cleaned)
        }
        let bit = decided.current == decided.previous
        if let ch = bpskVaricode.push(bit, symbol: j) {
            let fit = meanFit(bpskFit, from: ch.start - 1, to: ch.end)
            let passed = fit >= Self.charFitBPSK
            record(DecodedChar(ascii: ch.ascii, start: ch.start, end: ch.end, fit: fit, gated: passed), path: .bpsk)
        }
    }

    // MARK: QPSK

    /// QPSK path, one symbol behind: the interference of the matched filter is a complex ±1/6 of each
    /// neighbour, which turns into up to ±18° of phase error, so it is cancelled using hard decisions
    /// on the neighbours before the differential phase is taken. The differential phase also drives
    /// mode detection, for both modes (BPSK symbols sit on the QPSK axes too).
    private func qpskPath(_ r: SIMD2<Float>, k: Int) {
        r4History[k & 3] = r
        guard k >= 2 else { return }
        if ampA4 <= 0 { ampA4 = sqrt(power) * 0.75; isiC4 = ampA4 / 6 }
        let j = k - 1
        let raw = r4History[j & 3]
        let mine = nearestAxis(raw)
        let around = nearestAxis(r4History[(j - 1) & 3]) + nearestAxis(r)
        let cleaned = raw - isiC4 * around
        // LMS on the main tap and the interference, as for BPSK.
        let err = raw - (ampA4 * mine + isiC4 * around)
        ampA4 = max(ampA4 + 0.02 * (err.x * mine.x + err.y * mine.y), 1e-12)
        isiC4 = min(max(isiC4 + 0.01 * (err.x * around.x + err.y * around.y), 0), 0.3 * ampA4)

        let m = simd_length_squared(cleaned)
        let sq = cmul(cleaned, cleaned)
        let q4: Float = m > 1e-20 ? cmul(sq, sq).x / (m * m) : 0
        qpskFit[j & (Self.historyRing - 1)] = q4
        qpskSquelch.update(q4, present: present, lowSymbols: lowCount, clocked: clocked)

        let d = cmul(cleaned, SIMD2(cleanedPrev.x, -cleanedPrev.y)) / max(power, 1e-20)
        cleanedPrev = cleaned
        updateModeStatistics(psi: atan2(d.y, d.x), k: j)
        // Mode decisions need a window of symbols the QPSK path was locked on (pre-signal noise in the
        // window looks like a mix of both).
        validRun = qpskSquelch.isOpen && present ? validRun + 1 : 0
        qpskOdd[j & (Self.historyRing - 1)] = abs(d.y) > abs(d.x)
        if mode == .qpsk && qpskSquelch.isOpen { addPoint(cleaned / ampA4) }

        guard let bit = viterbi.push(d) else { return }
        let b = j - QPSKViterbi.delay
        if let ch = qpskVaricode.push(bit, symbol: b) {
            // A bit influences the five symbols from its own on.
            let fit = meanFit(qpskFit, from: ch.start, to: ch.end + 4)
            var odd = 0
            for i in ch.start...(ch.end + 4) where qpskOdd[i & (Self.historyRing - 1)] { odd += 1 }
            let span = ch.end + 5 - ch.start
            let passed = fit >= Self.charFitQPSK && Float(odd) >= 0.1 * Float(span)
            record(DecodedChar(ascii: ch.ascii, start: ch.start, end: ch.end, fit: fit, gated: passed), path: .qpsk)
        }
    }

    private func nearestAxis(_ r: SIMD2<Float>) -> SIMD2<Float> {
        abs(r.x) >= abs(r.y) ? SIMD2(r.x >= 0 ? 1 : -1, 0) : SIMD2(0, r.y >= 0 ? 1 : -1)
    }

    private func meanFit(_ ring: [Float], from: Int, to: Int) -> Float {
        guard to >= from, to - from < Self.historyRing else { return 0 }
        var sum: Float = 0
        for i in from...to { sum += ring[i & (Self.historyRing - 1)] }
        return sum / Float(to - from + 1)
    }

    // MARK: Mode detection

    private func updateModeStatistics(psi: Float, k: Int) {
        let slot = k % Self.modeWindow
        let half = Float.pi / 2, quarter = Float.pi / 4
        let a2 = psi - (psi / .pi).rounded() * .pi
        let a4 = psi - (psi / half).rounded() * half
        let z = abs(psi) < quarter
        if modeFilled >= Self.modeWindow {
            sum2 -= dist2[slot]; sum4 -= dist4[slot]
            if zeroShift[slot] { zeros -= 1 }
        } else {
            modeFilled += 1
        }
        dist2[slot] = a2 * a2; dist4[slot] = a4 * a4; zeroShift[slot] = z
        sum2 += a2 * a2; sum4 += a4 * a4
        if z { zeros += 1 }
    }

    private func decideMode(k: Int) {
        guard present, validRun >= Self.modeWindow else { return }
        let n = Float(Self.modeWindow)
        let s2 = sum2 / n, s4 = sum4 / n
        switch mode {
        case .bpsk where s2 > 0.5 && s4 < 0.06 && s4 < s2 / 8:
            switchMode(to: .qpsk, k: k)
        case .qpsk where s2 < 0.25 && Float(zeros) > 0.1 * n:
            switchMode(to: .bpsk, k: k)
        default:
            break
        }
    }

    private func switchMode(to newMode: Mode, k: Int) {
        mode = newMode
        pointCount = 0
        // Recover what the new path decoded while detection caught up.
        let history = newMode == .bpsk ? bpskHistory : qpskHistory
        for ch in history where ch.passed && ch.end > lastEmittedEnd && ch.end >= k - 3 * Self.modeWindow / 2 {
            emit(ch)
        }
    }

    // MARK: Output

    private enum Path { case bpsk, qpsk }

    private func record(_ ch: DecodedChar, path: Path) {
        var c = ch
        let squelchOpen = path == .bpsk ? bpskSquelch.isOpen : qpskSquelch.isOpen
        c.passed = c.gated && squelchOpen
        if path == .bpsk {
            bpskHistory.append(c)
            if bpskHistory.count > 16 { bpskHistory.removeFirst() }
        } else {
            qpskHistory.append(c)
            if qpskHistory.count > 16 { qpskHistory.removeFirst() }
        }
        let active = (path == .bpsk) == (mode == .bpsk)
        if active && c.passed && c.end > lastEmittedEnd { emit(c) }
    }

    private func emit(_ ch: DecodedChar) {
        lastEmittedEnd = ch.end
        let a = ch.ascii
        if a == 13 || a == 10 {
            // CR, LF or CR LF: one line break.
            if !(a == 10 && lastWasCR) { output.append("\n") }
            lastWasCR = a == 13
            return
        }
        lastWasCR = false
        guard a >= 32 && a < 127 else { return }
        output.unicodeScalars.append(Unicode.Scalar(a))
    }

    private func addPoint(_ p: SIMD2<Float>) {
        points[pointCount % points.count] = p
        pointCount += 1
    }

    /// Internal state for tests and tuning.
    struct Diagnostics {
        var present: Bool, line2: Float, line4: Float, bpskOpen: Bool, qpskOpen: Bool
        var qpsk: Bool, spread2: Float, spread4: Float, tunedHz: Double, symbols: Int
        var omega2: Float, omega4: Float, fit2: Float, fit4: Float, strobePhase: Double
        var clockLine: Float, lowSymbols: Int
    }

    var diagnostics: Diagnostics {
        let n = Float(max(modeFilled, 1))
        return Diagnostics(present: present, line2: line2, line4: line4, bpskOpen: bpskSquelch.isOpen,
                           qpskOpen: qpskSquelch.isOpen, qpsk: mode == .qpsk, spread2: sum2 / n, spread4: sum4 / n,
                           tunedHz: tunedHz, symbols: symbolIndex, omega2: omega2, omega4: omega4,
                           fit2: bpskSquelch.level, fit4: qpskSquelch.level,
                           strobePhase: nextStrobe.truncatingRemainder(dividingBy: samplesPerSymbol),
                           clockLine: simd_length(omSum) / max(omMean, 1e-30), lowSymbols: lowCount)
    }

    public func constellation() -> [SIMD2<Float>] {
        let n = min(pointCount, points.count)
        return (0..<n).map { points[(pointCount - n + $0) % points.count] }
    }

    // MARK: Carrier line (acquisition and presence)

    /// FFT of z² and z⁴ over the last second. A BPSK signal (and QPSK idle) squares to a line at twice
    /// its offset; QPSK data needs the fourth power. The line's height over the median bin is the
    /// presence detector; its position re-tunes the NCO while the loops are not locked.
    ///
    /// Neighbours: an idle signal's z² also has sidelines ±31.25 Hz from its carrier line (−6 dB), so
    /// a signal outside the lock range can put a sideline inside it. An in-range peak is only taken
    /// when it is not the sideline of a stronger line and not dwarfed by a line just outside the range.
    /// While locked, the carrier line must stay at zero offset: a loop mistuned by about half the
    /// symbol rate onto one idle tone of a signal looks locked, and this unlocks it.
    private func analyseCarrierLine() {
        let n = Self.fftSize
        var meanPower: Float = 0
        for i in 0..<n { meanPower += simd_length_squared(fftRing[i]) }
        meanPower /= Float(n)
        guard meanPower > 1e-24 else { line2 = 0; line4 = 0; present = false; return }
        let scale = 1 / meanPower
        let range = ModeID.psk31.lockRangeHz + 3
        let side = Self.symbolRate

        let s2 = scanLines(power: 2, scale: scale, inRangeHz: 2 * range, sidelineHz: side)
        let s4 = scanLines(power: 4, scale: scale * scale, inRangeHz: 4 * range, sidelineHz: side)
        line2 = s2.height; line4 = s4.height
        let on2 = s2.height >= Self.presenceOn, on4 = s4.height >= Self.presenceOn
        if !present && (on2 || on4) {
            present = true
            acquiredAt = symbolIndex
            fastLeft = Self.fastSymbols
        } else if present && s2.height < Self.presenceOff && s4.height < Self.presenceOff {
            present = false
        }
        guard present else {
            inconsistent = 0
            candidateHz = .nan
            // Long without a carrier: go back to the assigned frequency (the tracker follows the signal).
            absentEstimates += 1
            if absentEstimates == Int(Self.returnAfterSeconds * basebandRate) / Self.fftHop && tunedHz != originHz {
                tunedHz = originHz
                nco.setFrequency(-tunedHz, sampleRate: sampleRate)
                omega2 = 0; omega4 = 0
            }
            return
        }
        absentEstimates = 0

        let activeOpen = mode == .bpsk ? bpskSquelch.isOpen : qpskSquelch.isOpen
        if activeOpen {
            let check = mode == .bpsk ? s2 : s4
            inconsistent = check.nearZero < Self.presenceOff && check.global >= Self.presenceOn ? inconsistent + 1 : 0
            guard inconsistent >= 2 else { return }
            inconsistent = 0
            bpskSquelch.forceClose(); qpskSquelch.forceClose()
            omega2 = 0; omega4 = 0
        }
        // Either loop locked means the carrier is already found (the BPSK loop closes on QPSK data).
        guard !bpskSquelch.isOpen, !qpskSquelch.isOpen else { return }
        // BPSK (and any idle) squares to a clean line, and its fourth power then agrees. QPSK data has
        // only the fourth-power line and a weak, unreliable z² peak: use z⁴ when it clearly dominates.
        let agree = abs(s2.offsetHz / 2 - s4.offsetHz / 4) < 0.5
        let useFourth = on4 && (!on2 || (!agree && s4.height > 4 * s2.height))
        guard useFourth || on2 else { return }
        let offset = useFourth ? s4.offsetHz / 4 : s2.offsetHz / 2
        let residual = Float(offset * 2 * .pi / Self.symbolRate)
        guard abs(offset) >= Self.jumpMinHz else {
            // Close enough for the loops to pull in, but seed their frequency: on its own a loop
            // integrator that wandered on noise can sit in a false lock.
            omega2 = residual; omega4 = residual
            return
        }
        let limit = ModeID.psk31.lockRangeHz
        let target = min(max(tunedHz + offset, originHz - limit), originHz + limit)
        guard target != tunedHz else { return }
        // A noise peak rarely repeats at the same frequency: re-tune on two estimates that agree.
        defer { candidateHz = target }
        guard abs(target - candidateHz) < 1 else { return }
        tunedHz = target
        nco.setFrequency(-tunedHz, sampleRate: sampleRate)
        omega2 = 0; omega4 = 0
        fastLeft = Self.fastSymbols
        acquiredAt = symbolIndex
        // The window now mixes two tunings: wait for a full fresh one (plus the filters' delay).
        freshSamples = -Int(basebandRate * 0.1)
    }

    struct LineScan {
        /// Height (over the median bin) and frequency of the accepted in-range carrier line.
        var height: Float
        var offsetHz: Double
        /// Height of the strongest line anywhere in the extended range, and of the bins at zero offset.
        var global: Float
        var nearZero: Float
    }

    /// Spectrum of z^power over the last FFT window, searched for carrier lines.
    private func scanLines(power m: Int, scale: Float, inRangeHz: Double, sidelineHz: Double) -> LineScan {
        let n = Self.fftSize
        let binHz = basebandRate / Double(n)
        for i in 0..<n {
            let z = fftRing[(fftHead + i) & (n - 1)]
            var w = z
            for _ in 1..<m { w = cmul(w, z) }
            fftInRe[i] = w.x * scale * fftWindow[i]
            fftInIm[i] = w.y * scale * fftWindow[i]
        }
        vDSP_DFT_Execute(dft, fftInRe, fftInIm, &fftOutRe, &fftOutIm)
        for i in 0..<n { fftPower[i] = fftOutRe[i] * fftOutRe[i] + fftOutIm[i] * fftOutIm[i] }
        func pw(_ b: Int) -> Float { fftPower[(b % n + n) % n] }

        let inRange = Int(inRangeHz / binHz)
        let sideBins = Int((sidelineHz / binHz).rounded())
        // z^m of an idle signal has lines at multiples of the symbol rate around its carrier line.
        let extended = min(inRange + (m / 2) * sideBins + 3, n / 2 - 1 - Self.backgroundBins)

        // Height of a bin over its local background: the mean of the bins within ±backgroundBins,
        // leaving out its own ±3, scaled by ln 2 so pure noise reads like peak/median. A carrier
        // line is narrow; the cross-terms of a strong neighbour are broad humps and stay low.
        let reach = extended + Self.backgroundBins
        prefix.removeAll(keepingCapacity: true)
        prefix.append(0)
        for b in -reach...reach { prefix.append(prefix[prefix.count - 1] + Double(pw(b))) }
        func sum(_ lo: Int, _ hi: Int) -> Double { prefix[hi + reach + 1] - prefix[lo + reach] }
        func height(_ b: Int) -> Float {
            let w = Self.backgroundBins
            let total = sum(b - w, b + w) - sum(b - 3, b + 3)
            let mean = total / Double(2 * w - 6)
            return Float(Double(pw(b)) / max(mean * 0.693, 1e-30))
        }

        var global: Float = 0
        for b in -extended...extended { global = max(global, height(b)) }

        // Highest in-range line that is not a sideline of a stronger line (up to three tries).
        var masked: [Int] = []
        var best = 0
        var bestHeight: Float = 0
        for _ in 0..<3 {
            best = 0; bestHeight = -1
            for b in -inRange...inRange where !masked.contains(where: { abs($0 - b) <= 3 }) {
                let h = height(b)
                if h > bestHeight { bestHeight = h; best = b }
            }
            var isSideline = false
            for k in 1...max(1, m / 2) {
                for sign in [-1, 1] {
                    let c = best + sign * k * sideBins
                    if max(pw(c - 1), pw(c), pw(c + 1)) >= 2 * pw(best) { isSideline = true }
                }
            }
            if !isSideline { break }
            masked.append(best)
            bestHeight = 0
        }

        var nearZero: Float = 0
        let zeroBins = max(2, Int(Double(m) * 1.5 / binHz))
        for b in -zeroBins...zeroBins { nearZero = max(nearZero, height(b)) }

        // Parabolic interpolation on magnitude.
        let l = pw(best - 1).squareRoot(), c = pw(best).squareRoot(), r = pw(best + 1).squareRoot()
        let denom = l - 2 * c + r
        let delta = denom < 0 ? Double(0.5 * (l - r) / denom) : 0
        return LineScan(height: max(bestHeight, 0), offsetHz: (Double(best) + max(min(delta, 0.5), -0.5)) * binHz,
                        global: global, nearZero: nearZero)
    }

    // MARK: Reset

    public func reset() {
        tunedHz = originHz
        nco = NCO(frequency: -originHz, sampleRate: sampleRate)
        let f1 = max(1, Int((sampleRate / Self.stage1Rate).rounded()))
        let f2 = max(1, Int((sampleRate / Double(f1) / Self.basebandTarget).rounded()))
        (stage1, stage2) = Self.makeDecimators(sampleRate: sampleRate, f1: f1, f2: f2)
        for i in mfIn.indices { mfIn[i] = .zero }
        for i in mfOut.indices { mfOut[i] = .zero }
        mfInHead = 0; mfCount = 0
        nextStrobe = samplesPerSymbol
        omSum = .zero; omMean = 0; omPhasor = SIMD2(1, 0); omDisagree = 0
        yPrev = .zero; fastLeft = Self.fastSymbols; power = 1e-12; symbolIndex = 0
        for i in lowRing.indices { lowRing[i] = false }
        lowCount = 0; clocked = false
        theta2 = 0; omega2 = 0; theta4 = 0; omega4 = 0
        for i in fftRing.indices { fftRing[i] = .zero }
        fftHead = 0; sinceFFT = 0; freshSamples = 0; line2 = 0; line4 = 0; present = false; inconsistent = 0; acquiredAt = Int.min
        candidateHz = .nan; absentEstimates = 0
        bpsk = BPSKSequenceDetector()
        ampA = 0; isiC = 0
        for i in 0..<Self.historyRing { bpskFit[i] = 0; qpskFit[i] = 0; qpskOdd[i] = false }
        for i in zRing.indices { zRing[i] = .zero }
        bpskVaricode = VaricodeAssembler(); bpskSquelch = Squelch()
        viterbi.reset(); qpskVaricode = VaricodeAssembler(); qpskSquelch = Squelch(); ampA4 = 0; isiC4 = 0; cleanedPrev = .zero
        for i in r4History.indices { r4History[i] = .zero }
        mode = .bpsk
        for i in 0..<Self.modeWindow { dist2[i] = 0; dist4[i] = 0; zeroShift[i] = false }
        sum2 = 0; sum4 = 0; zeros = 0; modeFilled = 0; validRun = 0
        bpskHistory.removeAll(); qpskHistory.removeAll()
        lastEmittedEnd = Int.min; lastWasCR = false; pointCount = 0
    }
}

// MARK: - Helpers

@inline(__always) private func cmul(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> {
    SIMD2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x)
}

@inline(__always) private func rotate(_ a: SIMD2<Float>, by angle: Float) -> SIMD2<Float> {
    cmul(a, SIMD2(cos(angle), sin(angle)))
}

@inline(__always) private func wrap(_ a: Float) -> Float {
    var x = a
    while x > .pi { x -= 2 * .pi }
    while x < -.pi { x += 2 * .pi }
    return x
}

/// Squelch on a per-symbol fit metric in [-1, 1]: opens once the average is high and the last
/// `goodRunToOpen` symbols each fitted, closes when the average falls or the carrier line goes.
private struct Squelch {
    private(set) var isOpen = false
    private var average: Float = 0
    var level: Float { average }

    mutating func forceClose() { isOpen = false; average = min(average, 0); goodRun = 0 }
    private var goodRun = 0

    /// `lowSymbols`: how many of the last 32 symbols fell near zero amplitude (see `symbol`).
    /// `clocked`: the envelope carries the 31.25 Hz symbol clock (see `symbol`).
    mutating func update(_ q: Float, present: Bool, lowSymbols: Int, clocked: Bool) {
        average += (q - average) * Self.alpha
        goodRun = q > Self.good ? goodRun + 1 : 0
        if isOpen {
            if !present || !clocked || average < Self.close || lowSymbols > Self.lowToClose { isOpen = false }
        } else if present && clocked && average > Self.open && goodRun >= Self.run && lowSymbols <= Self.lowToOpen {
            isOpen = true
        }
    }

    private static let alpha: Float = 1.0 / 12
    private static let open: Float = 0.5
    private static let close: Float = 0.3
    private static let good: Float = 0.5
    private static let run = 8
    private static let lowToOpen = 4
    private static let lowToClose = 8
}

/// Two-state maximum-likelihood sequence detector for BPSK through the PSK31 matched filter, whose
/// output is z[k] = A·a[k] + c·(a[k-1] + a[k+1]) + noise. Ungerboeck's metric for that channel is
/// Σ a[k]·z[k] − c·a[k]·a[k-1], so the state is the previous symbol. Register-exchange survivors.
struct BPSKSequenceDetector {
    static let depth = 12

    private var metric: (Float, Float) = (0, 0)   // state 0: previous symbol +1, state 1: −1
    private var survivor: (UInt32, UInt32) = (0, 0)
    private var pushed = 0

    struct Decision {
        /// Symbols at depth + 1, depth and depth − 1 (older to newer), as ±1.
        var previous: Float
        var current: Float
        var next: Float
    }

    mutating func push(_ z: Float, isi c: Float) -> Decision? {
        // New symbol +1: from +1 costs c, from −1 gains c.
        let plusFromPlus = metric.0 + z - c, plusFromMinus = metric.1 + z + c
        let minusFromPlus = metric.0 - z + c, minusFromMinus = metric.1 - z - c
        let newPlus: Float, newMinus: Float
        let survPlus: UInt32, survMinus: UInt32
        if plusFromPlus >= plusFromMinus { newPlus = plusFromPlus; survPlus = survivor.0 << 1 }
        else { newPlus = plusFromMinus; survPlus = survivor.1 << 1 }
        if minusFromPlus >= minusFromMinus { newMinus = minusFromPlus; survMinus = survivor.0 << 1 | 1 }
        else { newMinus = minusFromMinus; survMinus = survivor.1 << 1 | 1 }
        let top = max(newPlus, newMinus)
        metric = (newPlus - top, newMinus - top)
        survivor = (survPlus, survMinus)
        pushed += 1
        guard pushed > Self.depth + 1 else { return nil }
        let best = newPlus >= newMinus ? survPlus : survMinus
        func symbol(_ age: Int) -> Float { (best >> UInt32(age)) & 1 == 1 ? -1 : 1 }
        return Decision(previous: symbol(Self.depth + 1), current: symbol(Self.depth), next: symbol(Self.depth - 1))
    }
}

/// Collects Varicode bits into characters: a character ends at "00".
struct VaricodeAssembler {
    private var code: UInt32 = 0
    private var length = 0
    private var zeros = 0
    private var start = 0

    struct Character { var ascii: UInt8; var start: Int; var end: Int }

    mutating func push(_ bit: Bool, symbol: Int) -> Character? {
        if bit {
            if length == 0 { start = symbol }
            if zeros == 1 && length > 0 { appendBit(0) }
            zeros = 0
            appendBit(1)
            return nil
        }
        zeros += 1
        guard zeros == 2, length > 0 else { return nil }
        defer { code = 0; length = 0 }
        guard length <= Varicode.maxLength, let ascii = Varicode.decode(value: code) else { return nil }
        return Character(ascii: ascii, start: start, end: symbol)
    }

    private mutating func appendBit(_ b: UInt32) {
        length += 1
        if length <= Varicode.maxLength { code = code << 1 | b }
    }
}
