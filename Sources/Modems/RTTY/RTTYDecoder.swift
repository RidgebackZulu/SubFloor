import Accelerate
import DSPCore
import Foundation
import simd

/// Multi-signal RTTY decoder (45.45 Bd, 170 Hz shift): each instance decodes one signal at its own
/// centre frequency (midway between mark and space) from 12 kHz box audio.
public enum RTTYModem: StreamingModem {
    public static let id: ModeID = .rtty

    public static func makeDecoder(frequencyHz: Double, sampleRate: Double) -> any SignalDecoder {
        RTTYSignalDecoder(frequencyHz: frequencyHz, sampleRate: sampleRate)
    }
}

/// One RTTY signal.
///
/// Signal chain:
/// 1. NCO mix of the centre to baseband and one decimating low-pass stage to 1 kHz (−6 dB at
///    ±450 Hz, transition 200…700 Hz, so nothing aliases within ±300 Hz of the centre). The audio is
///    taken in fixed blocks of 32 baseband samples, so the output does not depend on how the caller
///    chunks it, and the NCO retunes only between blocks.
/// 2. Mark and space matched filters: the baseband mixed by ∓85 Hz and summed over one bit (a
///    complex boxcar, kept as two running half-bit sums; nulls every 45.45 Hz, the other tone 24 dB
///    down). Their magnitudes are the mark and space envelopes.
/// 3. ATC (automatic threshold correction, after W7AY): each envelope's high and low levels (its mean
///    while its own tone wins and while it loses) are tracked separately, and the decision variable is
///    `(m − s) − λ·(mMid − sMid)`, the envelopes clipped to their floor…peak (fast-attack trackers).
///    λ is 0 while the two tones' ranges are within 3 dB (then it is `m − s`, the optimum in noise,
///    which an estimated threshold only adds noise to) and 1 from 6 dB apart, where each envelope is
///    judged against its own mid-level and the stronger tone keys the decision when the other is
///    faded. Measured at 0 dB with the upper tone 10 dB down: 0.85 accuracy against 0.25 for `m − s`;
///    an upper tone fading to −20 dB and back every 6 s at +5 dB: 0.996 against 0.75. An abrupt deep
///    notch (faster than the levels adapt, about 0.35 s) still costs the characters inside it, and a
///    tone more than about 12 dB down for good looks like a single keyed carrier to the squelch.
/// 4. Framing, run twice on the same decision variable, once per polarity: a mark→space edge starts a
///    frame, or the end of the previous character predicts it (back-to-back characters keep their
///    timing). The start bit, five data bits and the stop bit are read at bit ends (where the boxcar
///    holds exactly one bit), with the timing refined ±3 ms to where the decisions are firmest. The
///    frame is rejected unless the start bit is space and the stop bit is mark over more than half of
///    its first bit time.
/// 5. Baudot (ITA2, US figures) with LTRS/FIGS and unshift on space, per polarity path.
///
/// Polarity: the path in use switches when more than 30% of its frames failed over the last 2 s
/// while the other path's frames were clean (at most 10% failed). For these statistics a frame also
/// fails unless its start and stop bits are firm (0.3 of a clean bit): in the wrong polarity,
/// alternating text (RYRY...) frames fairly often, but with a stop bit that is barely mark. The path
/// in use also holds its text back while the other path is clean and fails 15 points less often.
/// Characters the new path decoded before a switch are recovered from its history.
///
/// AFC: on the bits of firm frames, the phase advance between the two halves of each bit (in the
/// filter of the tone that was sent) measures the frequency error, unambiguous to ±45 Hz; a quarter-
/// bit estimate (±100 Hz) resolves which turn of phase it is. About every 4 characters the NCO moves
/// most of the way, within ±30 Hz (`ModeID.rtty.lockRangeHz`) of the assigned frequency. A signal
/// measured outside that range (twice in a row) belongs to another decoder: the squelch stays shut and
/// the NCO stays. After 5 s without a signal the NCO returns to the assigned frequency. `frequencyHz`
/// is the tracked centre.
///
/// Squelch: a signal is present when both tones show mark/space contrast, `(high − low)/(high + low)`
/// of each envelope's levels: about 0.27 on noise (never above 0.34 in 8 minutes), about 0 for the
/// silent tone of a single keyed carrier, and about 0.44 (−8 dB) to 0.51 (−5 dB) for RTTY. Text is
/// emitted only while a signal is present, in range (confirmed by the AFC since it appeared), the path
/// in use is healthy (at most 30% failed frames over 2 s), and its current run of consecutive good
/// frames is at least 3 long. Each character's frame must also be firm, judged against the signal's
/// current level: decisions 0.6 of a clean bit on average, the start bit 0.3, and every bit's winning
/// tone at least 0.4 of that tone's level at the bit decisions of the run's frames read with the
/// signal on (half its high level while there are none), if it was read with no signal present and
/// in range for over 3 s (a frame begun in the noise just before a transmission fails this; frames
/// within a transmission are spared it, since a faded tone would fail it too). The run's own frames
/// carry the signal's level at once, where the high levels take a few tenths of a second to rise to
/// it after the transmission starts. When those hold, the run's earlier characters are emitted too.
/// The squelch stays shut for the first 32 bits, while the levels (which start at zero) settle: a
/// spurious opening then would count the noise before a transmission as part of one.
///
/// `constellation()`: mark and space envelope pairs `(upper tone, lower tone)` at the bit decisions of
/// recent firm frames, each normalised by its tone's level at its own bits, so a mark bit sits near
/// (1, 0) and a space bit near (0, 1) (the classic X-Y tuning display, as points; a mistuned or faded
/// tone pulls its cluster in).
///
/// Not thread-safe; owned by one thread at a time (see `SignalDecoder`).
public final class RTTYSignalDecoder: SignalDecoder {
    /// The tracked centre, midway between mark and space.
    public var frequencyHz: Double { tunedHz }
    public var submode: String { "RTTY 45" }
    /// The reverse-polarity path (mark the lower tone) is in use.
    var isReversed: Bool { active == 1 }

    // MARK: Constants

    static let baud = 45.45
    static let shiftHz = 170.0
    private static let basebandTarget = 1_000.0
    private static let channelCutoffHz = 450.0
    private static let channelTransitionHz = 500.0
    /// Baseband samples per internal processing block.
    private static let blockOutputs = 32
    private static let ringSize = 512
    private static let ringMask = ringSize - 1

    /// Squelch: open above, close below, on the weaker tone's contrast.
    private static let contrastOpen: Float = 0.36
    private static let contrastClose: Float = 0.33
    /// ATC: the tones' ranges this far apart (dB) start to move the threshold, and this far apart
    /// move it fully.
    private static let imbalanceStartDb: Float = 3
    private static let imbalanceFullDb: Float = 6
    /// Envelope levels average over this many bits.
    private static let levelBits: Float = 16
    /// The squelch stays shut for this many bits after the start (or a reset), while the levels,
    /// which start at zero, settle.
    private static let levelWarmupBits: Float = 32
    /// A run must be this many consecutive good frames before it is emitted.
    private static let minRun = 3
    /// Minimum mean decision firmness of a character's frame, and of its start bit, against the
    /// signal's current level (a clean bit is 1).
    private static let charFit: Float = 0.6
    private static let startFit: Float = 0.3
    /// Each bit's winning tone must reach this fraction of that tone's current high level.
    private static let bitLevel: Float = 0.5
    /// The same against the tone's level in the run's frames read with the signal on (taken at the
    /// bit decisions, where the envelope is highest, so about 1.25 times the high level).
    private static let runBitLevel: Float = 0.4
    /// A frame counts as clean (for polarity and health) when its start and stop bits are this firm.
    private static let framingFirmness: Float = 0.3
    /// Timing search around the edge, in baseband samples.
    private static let timingSearch = 3
    /// Polarity and health statistics: attempts within this window, while a signal is present.
    private static let statsSeconds = 2.0
    private static let unhealthyFailures = 0.3
    private static let cleanFailures = 0.1
    private static let minCleanAttempts = 6
    /// Emission is held while the other path has framed at least this many attempts cleanly and the
    /// active path's failure rate is this much higher.
    private static let minCompareAttempts = 4
    private static let polarityMargin = 0.15
    /// AFC: bits per estimate, gain, and how far a signal may sit beyond the lock range and still
    /// count as ours.
    private static let afcBits = 28
    private static let afcGain = 0.7
    private static let afcStepLimitHz = 15.0
    private static let rangeMarginHz = 3.0
    /// Two out-of-range estimates must agree this closely.
    private static let rangeAgreementHz = 10.0
    /// A gap in presence shorter than this is a fade within a transmission.
    private static let gapSeconds = 3.0
    /// The in-range confirmation survives a gap in presence this long.
    private static let confirmHoldSeconds = 1.0
    /// Without a signal for this long, return to the assigned frequency.
    private static let returnAfterSeconds = 5.0
    /// Characters older than this are never recovered.
    private static let recoverSeconds = 4.0
    private static let historyLimit = 32
    private static let attemptLimit = 64

    // MARK: State

    private let sampleRate: Double
    private let originHz: Double
    private var tunedHz: Double
    private var nco: NCO
    private var decimator: ComplexDecimator
    private let factor: Int
    private let basebandRate: Double
    /// Samples per bit at the baseband rate, and the boxcar (two halves of `half` samples).
    private let samplesPerBit: Double
    private let half: Int
    private let length: Int
    private let quarter: Int
    /// Baseband phasor step of the ±85 Hz tone mixers.
    private let toneStep: SIMD2<Float>

    private var pending: [DSPComplex]
    private var pendingCount = 0
    private var baseband: [DSPComplex] = []

    private var sampleIndex = 0
    private var tone = SIMD2<Float>(1, 0)
    /// Rings of the tone-mixed baseband, their half-bit running sums, the envelopes and the decision.
    private var ringM: [SIMD2<Float>], ringS: [SIMD2<Float>]
    private var halfRingM: [SIMD2<Float>], halfRingS: [SIMD2<Float>]
    private var envM: [Float], envS: [Float], decision: [Float]
    private var halfM = SIMD2<Float>.zero, halfS = SIMD2<Float>.zero

    // ATC: clip bounds (fast-attack peak and floor trackers) and each envelope's high and low levels.
    private var markPeak: Float = 0, markFloor: Float = 0, spacePeak: Float = 0, spaceFloor: Float = 0
    private let attack: Float, peakDecay: Float, floorDecay: Float
    private var markHigh: Float = 0, markLow: Float = 0, spaceHigh: Float = 0, spaceLow: Float = 0
    private let levelAlpha: Float
    /// Samples before the squelch may first open.
    private let levelWarmup: Int
    private var imbalanceWeight: Float = 0

    // Squelch.
    private var present = false
    private var absentSince = 0
    /// A signal has been present and in range, and when it last was.
    private var heardSignal = false
    private var lastSignal = 0
    /// Envelope levels at bit decisions, for the constellation.
    private var markBitLevel: Float = 0, spaceBitLevel: Float = 0

    // Framing.
    private var framers = [Framer(sign: 1), Framer(sign: -1)]
    private var active = 0

    // AFC.
    private var fineAcc = SIMD2<Double>.zero, coarseAcc = SIMD2<Double>.zero
    private var afcCount = 0
    private var outOfRange = false
    private var lastOutOfRangeHz = Double.nan
    private var inRangeConfirmed = false

    // Output.
    private var lastEmittedEnd = Int.min
    private var lastWasCR = false
    private var output = ""
    private var points = [SIMD2<Float>](repeating: .zero, count: 128)
    private var pointCount = 0
    private var bitEnds = [Int](repeating: 0, count: 7)

    /// One framed character.
    struct Frame {
        var character: Character?
        /// Baseband sample index of the stop-bit decision.
        var end: Int
        /// |decision| at the 7 bit decisions (start, 5 data, stop); lane 7 unused.
        var firmness: SIMD8<Float>
        /// Envelope of the winning tone at each bit decision, and which bits the upper tone won.
        var envelopes: SIMD8<Float>
        var upper: UInt8
        /// Read while no signal was present (none present and in range yet, or none for a while): its
        /// bits must carry the signal's level when it is emitted.
        var checkLevels: Bool
        var run: Int
    }

    /// Framing state of one polarity path. `sign` multiplies the decision variable (+1: mark is the
    /// upper tone).
    struct Framer {
        let sign: Float
        /// Next sample to examine for an edge.
        var scan = 1
        var pendingEdge: Double?
        /// Where to rescan from if the pending frame fails.
        var crossingScan = 1
        /// Where the next start edge falls if characters follow back to back.
        var predictedEdge = -Double.infinity
        var baudot = Baudot.Decoder()
        var runID = 0
        var runLength = 0
        var history: [Frame] = []
        /// Recent attempts made while a signal was present: (sample index, failed).
        var attempts: [(at: Int, failed: Bool)] = []

        init(sign: Float) {
            self.sign = sign
            history.reserveCapacity(RTTYSignalDecoder.historyLimit + 1)
            attempts.reserveCapacity(RTTYSignalDecoder.attemptLimit + 1)
        }

        func stats(since: Int) -> (attempts: Int, failures: Int) {
            var n = 0, f = 0
            for a in attempts where a.at >= since {
                n += 1
                if a.failed { f += 1 }
            }
            return (n, f)
        }
    }

    public init(frequencyHz: Double, sampleRate: Double = 12_000) {
        self.sampleRate = sampleRate
        originHz = frequencyHz
        tunedHz = frequencyHz
        nco = NCO(frequency: -frequencyHz, sampleRate: sampleRate)
        factor = max(1, Int((sampleRate / Self.basebandTarget).rounded()))
        basebandRate = sampleRate / Double(factor)
        decimator = Self.makeDecimator(sampleRate: sampleRate, factor: factor)
        samplesPerBit = basebandRate / Self.baud
        half = max(2, Int((samplesPerBit / 2).rounded()))
        length = 2 * half
        quarter = max(1, half / 2)
        let w = 2 * Double.pi * (Self.shiftHz / 2) / basebandRate
        toneStep = SIMD2(Float(cos(w)), Float(sin(w)))
        pending = .init(repeating: DSPComplex(real: 0, imag: 0), count: factor * Self.blockOutputs)
        ringM = .init(repeating: .zero, count: Self.ringSize)
        ringS = ringM; halfRingM = ringM; halfRingS = ringM
        envM = .init(repeating: 0, count: Self.ringSize)
        envS = envM; decision = envM
        let bit = Float(length)
        attack = min(1, 4 / bit)
        peakDecay = 1 / (16 * bit)
        floorDecay = 1 / (48 * bit)
        levelAlpha = 1 / (Self.levelBits * bit)
        levelWarmup = Int(Self.levelWarmupBits * bit)
        baseband.reserveCapacity(Self.blockOutputs + 1)
    }

    private static func makeDecimator(sampleRate: Double, factor: Int) -> ComplexDecimator {
        let taps = FIRDesign.tapCount(transition: channelTransitionHz / sampleRate)
        return ComplexDecimator(taps: FIRDesign.lowpass(taps: max(taps, factor), cutoff: channelCutoffHz / sampleRate),
                                factor: factor)
    }

    // MARK: Processing

    public func process(_ audio: UnsafeBufferPointer<Float>) -> String {
        output.removeAll(keepingCapacity: true)
        var i = 0
        let block = pending.count
        while i < audio.count {
            let n = min(block - pendingCount, audio.count - i)
            for k in 0..<n { pending[pendingCount + k] = DSPComplex(real: audio[i + k], imag: 0) }
            pendingCount += n
            i += n
            if pendingCount == block {
                processBlock()
                pendingCount = 0
            }
        }
        return output
    }

    private func processBlock() {
        pending.withUnsafeMutableBufferPointer { nco.mix($0) }
        baseband.removeAll(keepingCapacity: true)
        pending.withUnsafeBufferPointer { decimator.process($0, into: &baseband) }
        updateImbalanceWeight()
        for z in baseband { basebandSample(SIMD2(z.real, z.imag)) }
    }

    private func basebandSample(_ z: SIMD2<Float>) {
        let n = sampleIndex
        sampleIndex += 1
        let mask = Self.ringMask
        let slot = n & mask

        // Mark (upper tone, +85 Hz) and space (−85 Hz) to DC.
        let zm = cmul(z, SIMD2(tone.x, -tone.y))
        let zs = cmul(z, tone)
        tone = cmul(tone, toneStep)
        ringM[slot] = zm
        ringS[slot] = zs
        let leaving = (n - half) & mask
        if n & 1_023 == 0 {
            // Now and then: renormalise the phasor and rebuild the running sums, so rounding cannot
            // accumulate.
            tone /= simd_length(tone)
            halfM = .zero; halfS = .zero
            for back in 0..<half {
                halfM += ringM[(n - back) & mask]
                halfS += ringS[(n - back) & mask]
            }
        } else {
            halfM += zm - ringM[leaving]
            halfS += zs - ringS[leaving]
        }
        halfRingM[slot] = halfM
        halfRingS[slot] = halfS
        let scale = 1 / Float(length)
        let m = simd_length(halfM + halfRingM[leaving]) * scale
        let s = simd_length(halfS + halfRingS[leaving]) * scale
        envM[slot] = m
        envS[slot] = s

        // ATC.
        Self.track(peak: &markPeak, floor: &markFloor, m, attack: attack, peakDecay: peakDecay, floorDecay: floorDecay)
        Self.track(peak: &spacePeak, floor: &spaceFloor, s, attack: attack, peakDecay: peakDecay, floorDecay: floorDecay)
        let mc = min(max(m, markFloor), markPeak), sc = min(max(s, spaceFloor), spacePeak)
        let v = (mc - sc) - imbalanceWeight * 0.5 * ((markHigh + markLow) - (spaceHigh + spaceLow))
        decision[slot] = v
        let a = levelAlpha
        if v > 0 {
            markHigh += (m - markHigh) * a
            spaceLow += (s - spaceLow) * a
        } else {
            markLow += (m - markLow) * a
            spaceHigh += (s - spaceHigh) * a
        }

        updatePresence(n: n)
        if present && inRangeConfirmed {
            heardSignal = true
            lastSignal = n
        }
        advance(framer: 0, upTo: n)
        advance(framer: 1, upTo: n)
    }

    /// Clip bounds of one envelope: each follows it quickly towards its own extreme and relaxes
    /// slowly back.
    @inline(__always)
    private static func track(peak: inout Float, floor: inout Float, _ x: Float, attack: Float, peakDecay: Float,
                              floorDecay: Float) {
        peak += (x - peak) * (x > peak ? attack : peakDecay)
        floor += (x - floor) * (x < floor ? attack : floorDecay)
    }

    /// How far the threshold follows the tones' mid-levels: 0 while their ranges are within 3 dB of
    /// each other (then the decision is `m − s`, which an estimated threshold would only add noise
    /// to), rising to 1 at 6 dB apart. Updated once per block (the levels move slowly).
    private func updateImbalanceWeight() {
        let rm = markHigh - markLow, rs = spaceHigh - spaceLow
        guard rm > 0, rs > 0 else { imbalanceWeight = 0; return }
        let db = abs(20 * log10(rm / rs))
        imbalanceWeight = min(max((db - Self.imbalanceStartDb) / (Self.imbalanceFullDb - Self.imbalanceStartDb), 0), 1)
    }

    /// |decision| of a clean bit: half the mean of both tones' high-to-low ranges, summed.
    private var decisionScale: Float { 0.5 * ((markHigh - markLow) + (spaceHigh - spaceLow)) }

    // MARK: Squelch

    private func updatePresence(n: Int) {
        let contrast = min(Self.contrast(markHigh, markLow), Self.contrast(spaceHigh, spaceLow))
        if present {
            if contrast < Self.contrastClose {
                present = false
                absentSince = n
            }
            return
        }
        if contrast > Self.contrastOpen && n >= levelWarmup {
            present = true
            return
        }
        let absent = n - absentSince
        if absent == Int(Self.confirmHoldSeconds * basebandRate) {
            inRangeConfirmed = false
            fineAcc = .zero; coarseAcc = .zero; afcCount = 0
        } else if absent == Int(Self.returnAfterSeconds * basebandRate) {
            // Long without a signal: go back to the assigned frequency (the tracker follows the signal).
            outOfRange = false
            lastOutOfRangeHz = .nan
            if tunedHz != originHz { retune(to: originHz) }
        }
    }

    private static func contrast(_ high: Float, _ low: Float) -> Float {
        (high - low) / max(high + low, 1e-30)
    }

    // MARK: Framing

    /// Scans for start edges up to sample `n` and evaluates each frame once all its samples are in.
    private func advance(framer index: Int, upTo n: Int) {
        let bit = samplesPerBit
        while true {
            if let e = framers[index].pendingEdge {
                // The stop-bit decision plus the timing search and interpolation must be in the ring.
                let last = Int((e + 6.5 * bit).rounded(.up)) + Self.timingSearch + 1
                guard last <= n else { return }
                framers[index].pendingEdge = nil
                let valid = evaluateFrame(framer: index, edge: e)
                if !valid {
                    framers[index].scan = framers[index].crossingScan
                    framers[index].predictedEdge = -.infinity
                }
                continue
            }
            let k = framers[index].scan
            guard k <= n else { return }
            framers[index].scan = k + 1
            let sign = framers[index].sign
            let a = sign * decision[(k - 1) & Self.ringMask], b = sign * decision[k & Self.ringMask]
            guard a > 0 && b <= 0 else { continue }
            let crossing = Double(k - 1) + Double(a / (a - b))
            let predicted = framers[index].predictedEdge
            // Back-to-back characters: the previous frame's timing is better than a noisy crossing.
            let usePrediction = abs(crossing - predicted) <= 0.5 * bit
            framers[index].pendingEdge = usePrediction ? predicted : crossing
            // A failed prediction rescans from this crossing (so it gets its own try); a failed
            // crossing from just after it.
            framers[index].crossingScan = usePrediction ? k : k + 1
        }
    }

    private func decisionAt(_ t: Double) -> Float {
        let i = Int(t.rounded(.down))
        let f = Float(t - Double(i))
        let a = decision[i & Self.ringMask], b = decision[(i + 1) & Self.ringMask]
        return a + f * (b - a)
    }

    /// Reads the frame whose start edge is at `e`; true when it framed (start space, stop mark).
    private func evaluateFrame(framer index: Int, edge e: Double) -> Bool {
        let bit = samplesPerBit
        let sign = framers[index].sign
        // Bit k ends (the boxcar holds exactly bit k) half a bit after the edge plus k bits. Search the
        // timing nearest first, so a tie keeps the edge.
        var bestOffset = 0.0
        var bestScore: Float = -1
        for step in 0...(2 * Self.timingSearch) {
            let d = Double(step % 2 == 0 ? step / 2 : -(step + 1) / 2)
            var score: Float = 0
            for k in 0...6 { score += abs(decisionAt(e + 0.5 * bit + Double(k) * bit + d)) }
            if score > bestScore * 1.0001 { bestScore = score; bestOffset = d }
        }
        let first = e + 0.5 * bit + bestOffset
        var values = SIMD8<Float>.zero
        for k in 0...6 { values[k] = sign * decisionAt(first + Double(k) * bit) }
        let valid = values[0] < 0 && values[6] > 0

        // For the polarity and health statistics a frame must also be firmly framed: in the wrong
        // polarity, alternating text (RYRY...) frames with a stop bit that is barely mark.
        let firm = min(-values[0], values[6]) >= Self.framingFirmness * decisionScale
        if present {
            framers[index].attempts.append((sampleIndex, !(valid && firm)))
            if framers[index].attempts.count > Self.attemptLimit { framers[index].attempts.removeFirst() }
        }
        guard valid else {
            framers[index].runID += 1
            framers[index].runLength = 0
            decidePolarity()
            return false
        }
        var code: UInt8 = 0
        for k in 1...5 where values[k] > 0 { code |= 1 << UInt8(k - 1) }
        let character = framers[index].baudot.decode(code)
        let end = Int((first + 6 * bit).rounded())
        framers[index].runLength += 1
        framers[index].scan = Int((first + 6 * bit).rounded(.up)) + 1
        framers[index].predictedEdge = e + bestOffset + 7.5 * bit
        var envelopes = SIMD8<Float>.zero
        var upper: UInt8 = 0
        for k in 0...6 {
            let slot = Int((first + Double(k) * bit).rounded()) & Self.ringMask
            let isUpper = (values[k] > 0) == (sign > 0)
            envelopes[k] = isUpper ? envM[slot] : envS[slot]
            if isUpper { upper |= 1 << UInt8(k) }
        }
        let frame = Frame(character: character, end: end, firmness: values.replacing(with: -values, where: values .< 0),
                          envelopes: envelopes, upper: upper, checkLevels: beforeSignal, run: framers[index].runID)
        framers[index].history.append(frame)
        if framers[index].history.count > Self.historyLimit { framers[index].history.removeFirst() }

        if index == active && present && fit(frame) >= Self.charFit {
            for k in 0...6 { bitEnds[k] = Int((first + Double(k) * bit).rounded()) }
            measureFrequency()
            addPoints()
        }
        decidePolarity()
        flush()
        return true
    }

    /// No signal is present, and none was present and in range for a while (a short gap is a fade, not
    /// the noise before a transmission; a squelch opening that the AFC never confirmed was noise).
    private var beforeSignal: Bool {
        !present && (!heardSignal || sampleIndex - lastSignal > Int(Self.gapSeconds * basebandRate))
    }

    /// Mean firmness of a frame's decisions against the signal's current level, 0…1. `levels`, when
    /// known, is each tone's level at the bit decisions of the frames read with the signal on.
    private func fit(_ frame: Frame, levels: SIMD2<Float>? = nil) -> Float {
        let scale = max(decisionScale, 1e-30)
        // The start bit must be firm. A frame begun in the noise just before a signal is partly noise:
        // every bit must carry the signal (a faded tone during a transmission would fail this, so
        // frames read while a signal was on, or in a short gap, are spared).
        guard frame.firmness[0] >= Self.startFit * scale else { return 0 }
        if frame.checkLevels {
            for k in 0...6 {
                let isUpper = frame.upper & (1 << UInt8(k)) != 0
                let least = levels.map { Self.runBitLevel * (isUpper ? $0.x : $0.y) }
                    ?? Self.bitLevel * (isUpper ? markHigh : spaceHigh)
                if frame.envelopes[k] < least { return 0 }
            }
        }
        var sum: Float = 0
        for k in 0...6 { sum += min(frame.firmness[k] / scale, 1) }
        return sum / 7
    }

    // MARK: Polarity and output

    private func decidePolarity() {
        guard present else { return }
        let since = sampleIndex - Int(Self.statsSeconds * basebandRate)
        let mine = framers[active].stats(since: since), other = framers[1 - active].stats(since: since)
        let unhealthy = mine.attempts >= 4 && Double(mine.failures) > Self.unhealthyFailures * Double(mine.attempts)
        let clean = other.attempts >= Self.minCleanAttempts
            && Double(other.failures) <= Self.cleanFailures * Double(other.attempts)
        guard unhealthy && clean else { return }
        active = 1 - active
        pointCount = 0
        flush()
    }

    /// Emits the characters of the active path's current run that have not been emitted, when the
    /// squelch allows.
    private func flush() {
        guard present, inRangeConfirmed, !outOfRange else { return }
        let framer = framers[active]
        guard framer.runLength >= Self.minRun else { return }
        let since = sampleIndex - Int(Self.statsSeconds * basebandRate)
        let mine = framer.stats(since: since), other = framers[1 - active].stats(since: since)
        let rate = Double(mine.failures) / Double(max(mine.attempts, 1))
        let otherRate = Double(other.failures) / Double(max(other.attempts, 1))
        guard rate <= Self.unhealthyFailures else { return }
        // Some texts (RYRY...) frame fairly well in the wrong polarity too: hold back while the other
        // path frames clearly better; its characters are recovered if it takes over.
        let otherClean = other.attempts >= Self.minCompareAttempts && otherRate <= Self.cleanFailures
        guard !(otherClean && rate >= otherRate + Self.polarityMargin) else { return }
        let oldest = sampleIndex - Int(Self.recoverSeconds * basebandRate)
        let levels = runLevels(framer)
        for frame in framer.history where frame.run == framer.runID && frame.end > lastEmittedEnd
            && frame.end >= oldest && fit(frame, levels: levels) >= Self.charFit {
            emit(frame)
        }
    }

    /// Each tone's mean envelope (upper, lower) at the bit decisions of the current run's frames that
    /// were read with the signal on; nil when there are none. The tones' high levels average over
    /// 16 bits, so for a few tenths of a second after a transmission starts they still sit well
    /// below it; these frames carry its level at once.
    private func runLevels(_ framer: Framer) -> SIMD2<Float>? {
        var sum = SIMD2<Float>.zero, count = SIMD2<Float>.zero
        for frame in framer.history where frame.run == framer.runID && !frame.checkLevels {
            for k in 0...6 {
                let lane = frame.upper & (1 << UInt8(k)) != 0 ? 0 : 1
                sum[lane] += frame.envelopes[k]
                count[lane] += 1
            }
        }
        guard count.x > 0, count.y > 0 else { return nil }
        return sum / count
    }

    private func emit(_ frame: Frame) {
        lastEmittedEnd = frame.end
        guard let c = frame.character else { return }
        if c == "\r" || c == "\n" {
            // CR, LF or CR LF: one line break.
            if !(c == "\n" && lastWasCR) { output.append("\n") }
            lastWasCR = c == "\r"
            return
        }
        lastWasCR = false
        output.append(c)
    }

    // MARK: AFC

    /// Accumulates the half-bit and quarter-bit phase advance over the bits in `bitEnds`, in the
    /// filter of the tone each bit was sent on, and retunes every `afcBits` bits.
    private func measureFrequency() {
        let mask = Self.ringMask
        for t in bitEnds {
            let v = decision[t & mask]
            guard abs(v) >= 0.5 * decisionScale else { continue }
            let start = t - length + 1
            let upper = v > 0
            // Quarter-bit sums: successive pairs give the coarse phase advance.
            var previous = SIMD2<Float>.zero
            for q in 0..<(length / quarter) {
                var sum = SIMD2<Float>.zero
                for i in 0..<quarter {
                    let j = (start + q * quarter + i) & mask
                    sum += upper ? ringM[j] : ringS[j]
                }
                if q > 0 {
                    let p = cmul(sum, SIMD2(previous.x, -previous.y))
                    coarseAcc += SIMD2(Double(p.x), Double(p.y))
                }
                previous = sum
            }
            // Half-bit sums: the fine phase advance.
            var h0 = SIMD2<Float>.zero, h1 = SIMD2<Float>.zero
            for i in 0..<half {
                let j0 = (start + i) & mask, j1 = (start + half + i) & mask
                h0 += upper ? ringM[j0] : ringS[j0]
                h1 += upper ? ringM[j1] : ringS[j1]
            }
            let p = cmul(h1, SIMD2(h0.x, -h0.y))
            fineAcc += SIMD2(Double(p.x), Double(p.y))
            afcCount += 1
        }
        guard afcCount >= Self.afcBits else { return }
        defer { fineAcc = .zero; coarseAcc = .zero; afcCount = 0 }
        var offset = atan2(fineAcc.y, fineAcc.x) / (2 * .pi) * basebandRate / Double(half)
        let coarse = atan2(coarseAcc.y, coarseAcc.x) / (2 * .pi) * basebandRate / Double(quarter)
        let ambiguity = basebandRate / Double(half)
        offset += ((coarse - offset) / ambiguity).rounded() * ambiguity
        let limit = ModeID.rtty.lockRangeHz
        let estimate = tunedHz + offset
        guard abs(estimate - originHz) <= limit + Self.rangeMarginHz else {
            // One estimate can take the wrong turn of phase at low SNR: two must agree.
            if abs(estimate - lastOutOfRangeHz) <= Self.rangeAgreementHz {
                outOfRange = true
                inRangeConfirmed = false
            }
            lastOutOfRangeHz = estimate
            return
        }
        lastOutOfRangeHz = .nan
        outOfRange = false
        inRangeConfirmed = true
        let step = min(max(offset * Self.afcGain, -Self.afcStepLimitHz), Self.afcStepLimitHz)
        let target = min(max(tunedHz + step, originHz - limit), originHz + limit)
        if target != tunedHz { retune(to: target) }
        flush()
    }

    private func retune(to hz: Double) {
        tunedHz = hz
        nco.setFrequency(-hz, sampleRate: sampleRate)
    }

    // MARK: Constellation

    private func addPoints() {
        let mask = Self.ringMask
        for t in bitEnds {
            let m = envM[t & mask], s = envS[t & mask]
            // Each tone's level at its own bit decisions.
            if decision[t & mask] > 0 {
                markBitLevel += (m - markBitLevel) * (markBitLevel == 0 ? 1 : 0.1)
            } else {
                spaceBitLevel += (s - spaceBitLevel) * (spaceBitLevel == 0 ? 1 : 0.1)
            }
            guard markBitLevel > 0, spaceBitLevel > 0 else { continue }
            points[pointCount % points.count] = SIMD2(m / markBitLevel, s / spaceBitLevel)
            pointCount += 1
        }
    }

    public func constellation() -> [SIMD2<Float>] {
        let n = min(pointCount, points.count)
        return (0..<n).map { points[(pointCount - n + $0) % points.count] }
    }

    // MARK: Reset

    public func reset() {
        tunedHz = originHz
        nco = NCO(frequency: -originHz, sampleRate: sampleRate)
        decimator = Self.makeDecimator(sampleRate: sampleRate, factor: factor)
        pendingCount = 0
        sampleIndex = 0
        tone = SIMD2(1, 0)
        for i in 0..<Self.ringSize {
            ringM[i] = .zero; ringS[i] = .zero; halfRingM[i] = .zero; halfRingS[i] = .zero
            envM[i] = 0; envS[i] = 0; decision[i] = 0
        }
        halfM = .zero; halfS = .zero
        markPeak = 0; markFloor = 0; spacePeak = 0; spaceFloor = 0
        markHigh = 0; markLow = 0; spaceHigh = 0; spaceLow = 0; imbalanceWeight = 0
        present = false; absentSince = 0; heardSignal = false; lastSignal = 0
        markBitLevel = 0; spaceBitLevel = 0
        framers = [Framer(sign: 1), Framer(sign: -1)]
        active = 0
        fineAcc = .zero; coarseAcc = .zero; afcCount = 0
        outOfRange = false; lastOutOfRangeHz = .nan; inRangeConfirmed = false
        lastEmittedEnd = Int.min; lastWasCR = false; pointCount = 0
    }
}
