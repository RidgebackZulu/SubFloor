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

    /// Carrier-line presence thresholds: line power over its local background, scaled so that noise
    /// reads like peak over median.
    private static let presenceOn: Float = 18
    private static let presenceOff: Float = 10
    /// How far a line must stand out of its surroundings to count as the parent of an idle sideline:
    /// the bins of a neighbour's broad cross-term hump rarely reach it (noise-like, P ≈ 0.4% per bin),
    /// while a weak signal's own line sitting on such a hump does.
    private static let sidelineParentHeight: Float = 8
    /// An open path is declared falsely locked when its line at zero offset stays below this height
    /// for this many consecutive estimates while a line is present elsewhere.
    private static let absentLine: Float = 4
    private static let misplacedEstimates = 3
    /// A carrier line back within this many symbols is the same transmission.
    private static let flickerSymbols = 64
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
    /// Characters must start this many symbols after an estimated carrier start (it is found to a
    /// few symbols; a character begun in the noise just before must not get through).
    private static let startMargin = 2
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
    private let lines: CarrierLineScanner
    private var line2: Float = 0, line4: Float = 0
    private var present = false
    /// Latest heights of the z² and z⁴ lines at zero offset.
    private var line2AtZero: Float = 0, line4AtZero: Float = 0
    private var inconsistent2 = 0, inconsistent4 = 0
    private var candidateHz = Double.nan
    /// Symbol index at which the carrier line was last lost.
    private var absentSince = Int.min
    private var absentEstimates = 0
    /// Symbol index of the last presence onset or NCO re-tune.
    private var acquiredAt = Int.min

    // BPSK path.
    private var bpsk = BPSKSequenceDetector()
    private var zRing = [SIMD2<Float>](repeating: .zero, count: 64)
    private var ampA: Float = 0
    private var isiC: Float = 0
    private var bpskVaricode = VaricodeAssembler()
    private var bpskSquelch = PSK31Squelch()
    private var bpskBalance = ConstellationBalance()
    private var bpskFit = [Float](repeating: 0, count: historyRing)

    // QPSK path.
    private var viterbi = QPSKViterbi()
    private var qpskVaricode = VaricodeAssembler()
    private var qpskSquelch = PSK31Squelch()
    private var qpskBalance = ConstellationBalance()
    /// The QPSK code decoded in both phase senses (a transmission on the opposite sideband reverses
    /// it); the sense whose best path fits better on average is used.
    private var viterbiInverted = QPSKViterbi()
    private var qpskVaricodeInverted = VaricodeAssembler()
    private var senseGain: Float = 0
    private var invertedGain: Float = 0
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
        lines = CarrierLineScanner(basebandRate: basebandRate)
    }

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
        if lines.push(z) { analyseCarrierLine() }

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
        let confident = r2.x * r2.x > 0.25 * p
        bpskBalance.push(confident ? (r2.x > 0 ? 0 : 2) : nil)
        bpskSquelch.update(q2, present: present, lowSymbols: lowCount, clocked: clocked,
                           balanced: bpskBalance.isBalanced(), symbol: k)

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
        for ch in history where ch.gated && recoverable(ch) && ch.end > lastEmittedEnd
            && ch.end >= k - 3 * Self.modeWindow / 2 {
            emit(ch)
        }
    }

    /// A carrier was just found or re-tuned to. The balance windows restart so that only symbols of
    /// this carrier count: noise before it has randomly signed symbols and would pass a single tone.
    ///
    /// `since`: where the carrier itself began, if known (the line is seen up to a second late). The
    /// settling margin then counts from there.
    private func markAcquired(since start: Int? = nil) {
        acquiredAt = start.map { $0 + Self.startMargin - Self.recoverySettle } ?? symbolIndex
        fastLeft = Self.fastSymbols
        bpskBalance.reset(); qpskBalance.reset()
    }

    /// Walks back from now while the BPSK fit over 6 symbols stays high: the symbol where the carrier
    /// began, when the loops had already locked on it before its line was seen. Nil when they had not.
    private func signalStart() -> Int? {
        let k = symbolIndex
        var j = k
        while j - 6 >= max(0, k - 96) && meanFit(bpskFit, from: j - 6, to: j - 1) >= 0.45 { j -= 1 }
        return j < k - 8 ? j : nil
    }

    /// Started after the carrier was found and the loops had settled.
    private func settled(_ ch: DecodedChar) -> Bool {
        acquiredAt != Int.min && ch.start >= acquiredAt + Self.recoverySettle
    }

    /// Settled, and fits closely over its own symbols: safe to emit after the fact.
    private func recoverable(_ ch: DecodedChar) -> Bool { settled(ch) && ch.fit >= Self.recoveryFit }

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
        qpskBalance.push(m > 0.25 * power ? axisIndex(cleaned) : nil)
        qpskSquelch.update(q4, present: present, lowSymbols: lowCount, clocked: clocked,
                           balanced: qpskBalance.isBalanced(), symbol: j)

        let d = cmul(cleaned, SIMD2(cleanedPrev.x, -cleanedPrev.y)) / max(power, 1e-20)
        cleanedPrev = cleaned
        updateModeStatistics(psi: atan2(d.y, d.x), k: j)
        // Mode decisions need a window of symbols the QPSK path was locked on (pre-signal noise in the
        // window looks like a mix of both).
        validRun = (qpskSquelch.isOpen || bpskSquelch.isOpen) && present ? validRun + 1 : 0
        qpskOdd[j & (Self.historyRing - 1)] = abs(d.y) > abs(d.x)
        if mode == .qpsk && qpskSquelch.isOpen { addPoint(cleaned / ampA4) }

        let bit = viterbi.push(d)
        let bitInverted = viterbiInverted.push(SIMD2(d.x, -d.y))
        senseGain += (viterbi.lastGain - senseGain) / 32
        invertedGain += (viterbiInverted.lastGain - invertedGain) / 32
        let b = j - QPSKViterbi.delay
        // Both senses keep decoding; characters are taken from the one that fits better now.
        let useInverted = invertedGain > senseGain
        let normal = bit.flatMap { qpskVaricode.push($0, symbol: b) }
        let inverted = bitInverted.flatMap { qpskVaricodeInverted.push($0, symbol: b) }
        if let ch = useInverted ? inverted : normal {
            // A bit influences the five symbols from its own on.
            let fit = meanFit(qpskFit, from: ch.start, to: ch.end + 4)
            var odd = 0
            for i in ch.start...(ch.end + 4) where qpskOdd[i & (Self.historyRing - 1)] { odd += 1 }
            let span = ch.end + 5 - ch.start
            let passed = fit >= Self.charFitQPSK && Float(odd) >= 0.1 * Float(span)
            record(DecodedChar(ascii: ch.ascii, start: ch.start, end: ch.end, fit: fit, gated: passed), path: .qpsk)
        }
    }

    /// 0, 1, 2, 3 for the +1, +j, −1, −j axis nearest to `r`.
    private func axisIndex(_ r: SIMD2<Float>) -> Int {
        abs(r.x) >= abs(r.y) ? (r.x >= 0 ? 0 : 2) : (r.y >= 0 ? 1 : 3)
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
        // QPSK must also show its fourth-power line at zero offset (a BPSK signal Rs/4 off, where the
        // fourth-power loop aliases, does not) and no z² line there (BPSK data keeps one).
        case .bpsk where s2 > 0.5 && s4 < 0.06 && s4 < s2 / 8
                && line4AtZero >= Self.presenceOn && line2AtZero < Self.presenceOn:
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
        let squelch = path == .bpsk ? bpskSquelch : qpskSquelch
        // A character that started before the squelch opened must have started after the carrier was
        // found and settled: otherwise one begun in the noise before a transmission ends on its
        // preamble and gets out.
        c.passed = c.gated && squelch.isOpen && (c.start >= squelch.openedAt || settled(c))
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
        let meanPower = lines.meanPower
        guard meanPower > 1e-24 else { line2 = 0; line4 = 0; present = false; return }
        let scale = 1 / meanPower
        let range = ModeID.psk31.lockRangeHz + 3
        let side = Self.symbolRate

        let s2 = lines.scan(power: 2, scale: scale, inRangeHz: 2 * range, sidelineHz: side,
                            lineHeight: Self.sidelineParentHeight)
        let s4 = lines.scan(power: 4, scale: scale * scale, inRangeHz: 4 * range, sidelineHz: side,
                            lineHeight: Self.sidelineParentHeight)
        line2 = s2.height; line4 = s4.height
        line2AtZero = s2.nearZero; line4AtZero = s4.nearZero
        let on2 = s2.height >= Self.presenceOn, on4 = s4.height >= Self.presenceOn
        // BPSK (and any idle) squares to a clean line, and its fourth power then agrees. QPSK data has
        // only the fourth-power line and a weak, unreliable z² peak: use z⁴ when it clearly dominates.
        let agree = abs(s2.offsetHz / 2 - s4.offsetHz / 4) < 0.5
        let useFourth = on4 && (!on2 || (!agree && s4.height > 4 * s2.height))
        let offset = useFourth ? s4.offsetHz / 4 : s2.offsetHz / 2
        // A carrier beyond the lock range, with none at our own tuning, belongs to another decoder:
        // stay silent rather than lock onto one of its idle tones at the range edge.
        let limit = ModeID.psk31.lockRangeHz
        let carrierHere = s2.nearZero >= Self.presenceOn || s4.nearZero >= Self.presenceOn
        let outOfRange = (useFourth || on2) && abs(tunedHz + offset - originHz) > limit + 1 && !carrierHere
        let wasPresent = present
        defer { if wasPresent && !present { absentSince = symbolIndex } }
        if outOfRange {
            if present { bpskSquelch.forceClose(); qpskSquelch.forceClose() }
            present = false
        } else if !present && (on2 || on4) {
            present = true
            // The line flickers next to a strong neighbour or at low SNR: a carrier back within 2 s,
            // or one a path is still locked on, is the same transmission, not a new one.
            let brief = absentSince != Int.min && symbolIndex - absentSince < Self.flickerSymbols
            if !bpskSquelch.isOpen && !qpskSquelch.isOpen && !brief { markAcquired(since: signalStart()) }
        } else if present && s2.height < Self.presenceOff && s4.height < Self.presenceOff {
            present = false
        }
        guard present else {
            inconsistent2 = 0; inconsistent4 = 0
            candidateHz = .nan
            // Long without a carrier: go back to the assigned frequency (the tracker follows the signal).
            absentEstimates += 1
            if absentEstimates == Int(Self.returnAfterSeconds * basebandRate) / CarrierLineScanner.hop && tunedHz != originHz {
                tunedHz = originHz
                nco.setFrequency(-tunedHz, sampleRate: sampleRate)
                omega2 = 0; omega4 = 0
            }
            return
        }
        absentEstimates = 0

        // Each open path must see its own line at zero offset: z² for BPSK, z⁴ for QPSK. A loop
        // mistuned onto one idle tone, or a fourth-power loop aliased Rs/4 off, looks locked. (A lock
        // on one idle tone is also refused by the squelch's balance test: a tone has one sign.)
        // Only a line clearly absent at zero counts: a good lock's own line can read low there next
        // to a strong neighbour, and closing a good lock costs text.
        func misplaced(_ scan: CarrierLineScanner.LineScan) -> Bool {
            scan.nearZero < Self.absentLine && scan.global >= Self.presenceOn
        }
        // z⁴ of a BPSK idle Rs/4 off has a sideline at zero, so also trust a strong z² line elsewhere
        // (QPSK data has only a weak z² line; QPSK idle has its z² line at zero).
        let quadMisplaced = misplaced(s4)
            || (on2 && abs(s2.offsetHz / 2) >= 1.5 && s2.height >= s4.height)
        inconsistent2 = bpskSquelch.isOpen && misplaced(s2) ? inconsistent2 + 1 : 0
        inconsistent4 = qpskSquelch.isOpen && quadMisplaced ? inconsistent4 + 1 : 0
        if inconsistent2 >= Self.misplacedEstimates { bpskSquelch.forceClose(); omega2 = 0; inconsistent2 = 0 }
        if inconsistent4 >= Self.misplacedEstimates { qpskSquelch.forceClose(); omega4 = 0; inconsistent4 = 0 }
        // A path locked with its line at zero offset means the carrier is found (the BPSK path
        // closes on QPSK data, so either will do). A path open without its line there is not trusted.
        let bpskHolds = bpskSquelch.isOpen && !misplaced(s2)
        let qpskHolds = qpskSquelch.isOpen && !quadMisplaced
        guard !bpskHolds, !qpskHolds else { return }
        guard useFourth || on2 else { return }
        let residual = Float(offset * 2 * .pi / Self.symbolRate)
        guard abs(offset) >= Self.jumpMinHz else {
            // Close enough for the loops to pull in, but seed their frequency: on its own a loop
            // integrator that wandered on noise can sit in a false lock.
            omega2 = residual; omega4 = residual
            return
        }
        let target = min(max(tunedHz + offset, originHz - limit), originHz + limit)
        guard target != tunedHz else { return }
        // A noise peak rarely repeats at the same frequency: re-tune on two estimates that agree.
        defer { candidateHz = target }
        guard abs(target - candidateHz) < 1 else { return }
        tunedHz = target
        nco.setFrequency(-tunedHz, sampleRate: sampleRate)
        omega2 = 0; omega4 = 0
        markAcquired()
        // The window now mixes two tunings: wait for a full fresh one (plus the filters' delay).
        lines.invalidate(settleSamples: Int(basebandRate * 0.1))
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
        lines.reset()
        line2 = 0; line4 = 0; present = false; acquiredAt = Int.min
        line2AtZero = 0; line4AtZero = 0; inconsistent2 = 0; inconsistent4 = 0
        bpskBalance.reset(); qpskBalance.reset()
        viterbiInverted.reset(); qpskVaricodeInverted = VaricodeAssembler(); senseGain = 0; invertedGain = 0
        candidateHz = .nan; absentEstimates = 0; absentSince = Int.min
        bpsk = BPSKSequenceDetector()
        ampA = 0; isiC = 0
        for i in 0..<Self.historyRing { bpskFit[i] = 0; qpskFit[i] = 0; qpskOdd[i] = false }
        for i in zRing.indices { zRing[i] = .zero }
        bpskVaricode = VaricodeAssembler(); bpskSquelch = PSK31Squelch()
        viterbi.reset(); qpskVaricode = VaricodeAssembler(); qpskSquelch = PSK31Squelch(); ampA4 = 0; isiC4 = 0; cleanedPrev = .zero
        for i in r4History.indices { r4History[i] = .zero }
        mode = .bpsk
        for i in 0..<Self.modeWindow { dist2[i] = 0; dist4[i] = 0; zeroShift[i] = false }
        sum2 = 0; sum4 = 0; zeros = 0; modeFilled = 0; validRun = 0
        bpskHistory.removeAll(); qpskHistory.removeAll()
        lastEmittedEnd = Int.min; lastWasCR = false; pointCount = 0
    }
}

