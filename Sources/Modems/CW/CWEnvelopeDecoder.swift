import DSPCore
import Foundation

/// Morse decoder for a narrow-band envelope that may be only a few dB above the noise.
///
/// `CWDecoderCore` assumes a steady tone level and takes its speed from single elements. Neither
/// holds when the envelope is Rayleigh/Rician noise, so this type keeps its own statistics:
/// - Two envelopes arrive per 5 ms block: `coarse` (smoothed, drives the floor, peak and SNR gate) and
///   `fine` (lightly smoothed, drives the keying segmentation).
/// - The key state is a Viterbi segmentation of `fine` into on and off runs (Rician against Rayleigh
///   likelihoods), decided `lookahead` blocks late, so the gate has already seen the first mark.
/// - Speed comes from clustering the recent run lengths, never from the segmentation's own output
///   alone: at high SNR the minimum run length is a fixed 10 ms, so a wrong speed estimate cannot
///   merge elements and keep itself wrong. Only when the SNR is low does the minimum grow towards a
///   fraction of a dot, to suppress noise glitches.
///
/// Not thread-safe; owned by one thread at a time.
final class CWEnvelopeDecoder {
    let blockMs: Double
    let lookahead: Int
    /// Current estimate of one dot, in ms.
    private(set) var dotMs = 60.0
    private(set) var level: Float = 0

    // Tuning.
    private let minPeakToFloor = 4.0
    private static let peakAttack = 0.15
    private static let minMarkFraction = 0.55
    private static let minMarkPeak: Float = 0.5
    private static let switchPenalty = 2.5
    private static let evidenceScale = 0.3
    /// Longest run that can be Morse; anything longer is a carrier or idle time.
    private let maxElementMs = 1_500.0
    /// Fraction of a dot used as minimum run length at low SNR, falling to `fixedDwellMs` at high SNR.
    private static let lowSNRDwellDots = 0.85
    private let fixedDwellMs = 10.0

    private static let warmupBlocks = 20

    // Level tracking.
    private var pending: [(coarse: Double, fine: Double)] = []
    private var warmupCount = 0
    private var warmupValues: [Double] = []
    private var noiseFloor = 0.0
    private var peak = 0.0
    private var floorUpdates = 0
    private var inputCount = 0
    private var fineWarm = 0.0
    /// Noise power per quadrature component of the fine envelope.
    private var fineVariance = 0.0

    // Segmentation.
    private var viterbi: KeyingViterbi
    private var decided: [Bool] = []

    // Keying state machine.
    private var keyDown = false
    private var runBlocks = 0
    private var gapBefore = 0
    private var markPeak: Float = 0
    /// Durations of the marks of the character in progress; dit/dah is decided when it ends, with
    /// the speed estimate as it stands then.
    private var marks: [Double] = []
    private var charPending = false
    private var wordPending = false

    // Speed estimation.
    private var runs: [Double] = []
    private static let runWindow = 14
    /// False until enough runs have been seen to estimate the speed (at the start, and again after
    /// a mark too long to be Morse at the current speed). Text is held back, not guessed, meanwhile.
    private var speedKnown = false
    private var held: [(gap: Double, mark: Double)] = []
    private static let minRunsForSpeed = 6

    var wpm: Double { 1_200 / dotMs }
    /// True once the tracked peak stands clear of the key-up floor.
    var signalPresent: Bool { warmupCount >= Self.warmupBlocks && peak > noiseFloor * minPeakToFloor }

    init(blockMs: Double, lookahead: Int = 24) {
        precondition(lookahead >= 1)
        self.blockMs = blockMs
        self.lookahead = lookahead
        viterbi = KeyingViterbi(lag: lookahead)
    }

    func reset() {
        pending.removeAll(); decided.removeAll(); warmupValues.removeAll(); runs.removeAll()
        warmupCount = 0; noiseFloor = 0; peak = 0; floorUpdates = 0; inputCount = 0
        fineWarm = 0; fineVariance = 0; level = 0
        viterbi = KeyingViterbi(lag: lookahead)
        keyDown = false; runBlocks = 0; gapBefore = 0; markPeak = 0
        marks.removeAll(); charPending = false; wordPending = false
        speedKnown = false; held.removeAll()
        dotMs = 60
    }

    /// Feeds one coarse and one fine magnitude per block; returns any newly decoded text.
    func process(coarse: UnsafeBufferPointer<Float>, fine: UnsafeBufferPointer<Float>) -> String {
        precondition(coarse.count == fine.count)
        var out = ""
        for i in coarse.indices {
            let m = Double(coarse[i]), f = Double(fine[i])
            pending.append((m, f))
            // The level tracker and the segmentation see the newest block now; the keying state
            // machine sees it `lookahead` blocks later.
            if warmupCount >= Self.warmupBlocks, m > peak { peak += (m - peak) * Self.peakAttack }
            pushSegmentation(fine: f)
            if pending.count > lookahead {
                let s = pending.removeFirst()
                step(coarse: s.coarse, fine: s.fine, keyed: decided.isEmpty ? false : decided.removeFirst(), out: &out)
            }
        }
        return out
    }

    // MARK: Segmentation

    private func pushSegmentation(fine f: Double) {
        inputCount += 1
        if inputCount <= Self.warmupBlocks {
            fineWarm += f * f
            fineVariance = fineWarm / (2 * Double(inputCount))
        }
        let sigma2 = max(fineVariance, 1e-12)
        // Amplitude of the "on" hypothesis. With no signal known yet it must stand well clear of the
        // noise: if it sat at the noise level, on and off would score alike for blocks just before a
        // mark whose strength is not yet visible, and the mark's start would drift early.
        let amplitude = max(peak, (signalPresent ? 1.8 : 3.0) * sigma2.squareRoot())
        let llr = Self.evidenceScale * (Self.logI0(f * amplitude / sigma2) - amplitude * amplitude / (2 * sigma2))
        if let state = viterbi.push(llr: llr, minDwell: minDwellBlocks(), switchPenalty: Self.switchPenalty) {
            decided.append(state)
        }
    }

    /// Shortest on or off run, in blocks. A fixed 10 ms (enough for 50 WPM) once the signal is
    /// strong; up to `lowSNRDwellDots` of a dot when it is within a few dB of the noise, where
    /// it keeps noise from fragmenting marks. In between it is interpolated on the peak-to-floor ratio.
    private func minDwellBlocks() -> Int {
        let fixed = fixedDwellMs / blockMs
        let lowSNR = Self.lowSNRDwellDots * min(max(dotMs, 20), 150) / blockMs
        return max(2, Int((lowSNR + (fixed - lowSNR) * strength()).rounded()))
    }

    /// 0 when the signal is within a few dB of the noise (peak/floor <= 8), rising to 1 when it is
    /// strong (>= 32), on a log scale.
    private func strength() -> Double {
        let ratio = noiseFloor > 0 ? max(peak / noiseFloor, 1) : 1
        return min(max((log(ratio) - log(8.0)) / (log(32.0) - log(8.0)), 0), 1)
    }

    /// log I₀(z), Abramowitz & Stegun 9.8.1 / 9.8.2.
    static func logI0(_ z: Double) -> Double {
        let a = abs(z)
        if a < 3.75 {
            let t = (a / 3.75) * (a / 3.75)
            let i0 = 1 + t * (3.5156229 + t * (3.0899424 + t * (1.2067492 + t * (0.2659732 + t * (0.0360768 + t * 0.0045813)))))
            return log(i0)
        }
        let t = 3.75 / a
        let poly = 0.39894228 + t * (0.01328592 + t * (0.00225319 + t * (-0.00157565 + t * (0.00916281
            + t * (-0.02057706 + t * (0.02635537 + t * (-0.01647633 + t * 0.00392377)))))))
        return a - 0.5 * log(a) + log(poly)
    }

    // MARK: Keying state machine

    private func step(coarse m: Double, fine: Double, keyed: Bool, out: inout String) {
        if warmupCount < Self.warmupBlocks {
            warmupCount += 1
            warmupValues.append(m)
            if warmupCount == Self.warmupBlocks {
                // 100 ms of smoothed noise is only a couple of independent samples, so the estimate
                // is rough. The median ignores a mark inside the warm-up, and the 1.5 margin errs
                // high: a floor that is too high relaxes quickly, one that is too low would lock
                // out its own correction. The peak starts at the floor, so only a real signal
                // can open the gate.
                noiseFloor = warmupValues.sorted()[Self.warmupBlocks / 2] * 1.5
                peak = noiseFloor
                warmupValues.removeAll()
            }
            return
        }
        peak += (max(noiseFloor, 0) - peak) * 0.002
        if !keyDown {
            // Only learn the floor from well-separated key-up time: the smoothing skirts either
            // side of a mark (including the one still waiting in the lookahead) are not noise.
            let clear = Double(runBlocks) * blockMs >= dotMs && !pending.contains { $0.coarse > noiseFloor * 2.5 }
            if clear {
                floorUpdates += 1
                let rate = max(0.02, 1 / Double(floorUpdates + 10))
                noiseFloor += (min(m, noiseFloor * 2.5) - noiseFloor) * rate
                fineVariance += (min(fine * fine / 2, fineVariance * 6) - fineVariance) * rate
            }
        }
        let span = peak - noiseFloor
        level = Float(min(1, max(0, (m - noiseFloor) / max(span, 1e-12))))
        let down = keyed && peak > noiseFloor * minPeakToFloor

        if down == keyDown {
            runBlocks += 1
            if keyDown { markPeak = max(markPeak, level) } else { checkGap(out: &out) }
            return
        }
        if keyDown {
            let ms = Double(runBlocks) * blockMs
            if ms > maxElementMs {
                // A carrier, not Morse: drop whatever character was in progress.
                marks.removeAll(); charPending = false; wordPending = false
                runBlocks = 1
            } else if markPeak >= Self.minMarkPeak && ms >= minMarkMs() {
                let gapMs = Double(gapBefore) * blockMs
                if speedKnown && ms > dotMs * 5 {
                    // Too long for a dah at this speed: the speed dropped, or this is a carrier.
                    // Finish what was in progress and learn the speed again.
                    if charPending { endCharacter(out: &out) }
                    speedKnown = false
                    runs.removeAll()
                }
                let wasKnown = speedKnown
                noteRun(gapMs)
                noteRun(ms)
                if !wasKnown && speedKnown { flushHeld(out: &out) }
                place(gap: gapMs, mark: ms, out: &out)
                runBlocks = 1
            } else {
                // Never rose clear of the noise: not a mark. Rejoin the gaps on either side.
                runBlocks += gapBefore + 1
            }
        } else {
            gapBefore = runBlocks
            markPeak = level
            runBlocks = 1
        }
        keyDown = down
    }

    /// Shortest mark kept: a fraction of a dot at low SNR (where noise makes blips), 10 ms when strong.
    private func minMarkMs() -> Double {
        let t = strength()
        return fixedDwellMs + (dotMs * Self.minMarkFraction - fixedDwellMs) * (1 - t)
    }

    private func checkGap(out: inout String) {
        let ms = Double(runBlocks) * blockMs
        guard speedKnown else {
            // Never learned the speed and the line has gone quiet: use the guess rather than hold forever.
            if ms > maxElementMs { flushHeld(out: &out); endCharacter(out: &out); endWord(out: &out) }
            return
        }
        if charPending && ms > dotMs * 2 { endCharacter(out: &out) }
        if wordPending && ms > dotMs * 5 { endWord(out: &out) }
    }

    /// Adds a mark that followed a gap of `gap` ms. Held back until the speed is known.
    private func place(gap: Double, mark: Double, out: inout String) {
        guard speedKnown else { held.append((gap, mark)); return }
        if mark > dotMs * 5 {
            marks.removeAll(); charPending = false; wordPending = false
            return
        }
        if charPending && gap > dotMs * 2 { endCharacter(out: &out) }
        if wordPending && gap > dotMs * 5 { endWord(out: &out) }
        marks.append(mark)
        charPending = true
        wordPending = true
    }

    private func flushHeld(out: inout String) {
        let pairs = held
        held.removeAll()
        let known = speedKnown
        speedKnown = true
        for pair in pairs { place(gap: pair.gap, mark: pair.mark, out: &out) }
        speedKnown = known
    }

    private func endCharacter(out: inout String) {
        let symbol = String(marks.map { $0 < dotMs * 2 ? "." : "-" })
        if !symbol.isEmpty { out.append(MorseCode.reverse[symbol] ?? "*") }
        marks.removeAll()
        charPending = false
    }

    private func endWord(out: inout String) {
        out.append(" ")
        wordPending = false
    }

    // MARK: Speed

    /// Records a completed run (mark or gap) and re-estimates the dot from the recent ones.
    private func noteRun(_ ms: Double) {
        guard ms >= blockMs, ms <= maxElementMs else { return }
        runs.append(ms)
        if runs.count > Self.runWindow { runs.removeFirst() }
        guard runs.count >= Self.minRunsForSpeed, let estimate = Self.shortCluster(of: runs) else { return }
        // Large disagreement means the speed changed (or the estimate was wrong): jump. Otherwise smooth.
        let jump = !speedKnown || abs(log(estimate / dotMs)) > 0.3
        speedKnown = true
        dotMs += (estimate - dotMs) * (jump ? 0.7 : 0.25)
        dotMs = min(max(dotMs, 20), 240)
    }

    /// Splits the run lengths into a short and a long cluster (1-D two-means on the logarithm, since
    /// Morse runs are 1, 3 and 7 dots) and returns the median of the short one: the dot. Returns nil
    /// when there is no clear short/long structure (all runs alike, or the clusters are less than 2x apart).
    static func shortCluster(of runs: [Double]) -> Double? {
        let sorted = runs.sorted()
        let logs = sorted.map { log($0) }
        var best: (split: Int, cost: Double)?
        for split in 2...(sorted.count - 2) {
            let cost = sumOfSquares(logs[..<split]) + sumOfSquares(logs[split...])
            if best == nil || cost < best!.cost { best = (split, cost) }
        }
        guard let split = best?.split else { return nil }
        let low = Array(sorted[..<split]), high = Array(sorted[split...])
        let lowMedian = low[low.count / 2], highMedian = high[high.count / 2]
        guard highMedian / lowMedian >= 2 else { return nil }
        return lowMedian
    }

    private static func sumOfSquares(_ values: ArraySlice<Double>) -> Double {
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
    }
}

/// Online two-state Viterbi segmentation of a keyed envelope into off and on runs.
///
/// State `(v, k)` means "keyed state `v`, `k` blocks into this run", `k` saturating at `cap`.
/// A run may end only once `k` has reached the minimum dwell, and every change costs a fixed
/// penalty. The "on" state earns each block's log-likelihood ratio; "off" earns nothing.
/// `push` returns the decided state of the block `lag` blocks ago. Storage is allocated once.
struct KeyingViterbi {
    static let cap = 30
    private let lag: Int
    private var score: [Double]
    private var next: [Double]
    /// Back-pointers for the last `lag + 1` blocks, ring-indexed.
    private var back: [UInt8]
    private var head = 0
    private var filled = 0

    init(lag: Int) {
        self.lag = lag
        score = [Double](repeating: -1e9, count: 2 * Self.cap)
        score[Self.cap - 1] = 0   // off, long since started
        next = score
        back = [UInt8](repeating: 0, count: (lag + 1) * 2 * Self.cap)
    }

    mutating func push(llr: Double, minDwell: Int, switchPenalty: Double) -> Bool? {
        let cap = Self.cap
        let width = 2 * cap
        let dwell = min(max(minDwell, 1), cap)
        let base = head * width
        for v in 0..<2 {
            let emission = v == 1 ? llr : 0
            for k in 1...cap {
                let s = v * cap + k - 1
                var best = -Double.infinity
                var source = s
                if k == 1 {
                    for kk in dwell...cap {
                        let c = score[(1 - v) * cap + kk - 1] - switchPenalty
                        if c > best { best = c; source = (1 - v) * cap + kk - 1 }
                    }
                } else {
                    best = score[s - 1]; source = s - 1
                    if k == cap, score[s] > best { best = score[s]; source = s }
                }
                next[s] = best + emission
                back[base + s] = UInt8(source)
            }
        }
        var top = -Double.infinity
        var topIndex = 0
        for i in 0..<width where next[i] > top { top = next[i]; topIndex = i }
        for i in 0..<width { score[i] = max(next[i] - top, -1e9) }
        let newest = head
        head = (head + 1) % (lag + 1)
        filled = min(filled + 1, lag + 1)
        guard filled == lag + 1 else { return nil }
        // Walk back `lag` steps from the best current state to the oldest stored block.
        var state = topIndex
        var row = newest
        for _ in 0..<lag {
            state = Int(back[row * width + state])
            row = (row + lag) % (lag + 1)
        }
        return state >= cap
    }
}
