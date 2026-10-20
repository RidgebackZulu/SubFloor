import DSPCore
import Foundation

/// Goertzel tone detector + adaptive threshold + timing classifier.
/// Tracks speed from element lengths; emits characters on 2-dot gaps and spaces on 5-dot gaps.
///
/// Two ways in:
/// - `process(_:)`: audio at the core's sample rate, Goertzel at `pitchHz` (phase 1, unchanged).
/// - `process(envelope:blockMs:)`: one pre-computed tone magnitude per block, for callers that
///   have already isolated the signal. With `noisyEnvelope` set, this path adds statistics and
///   edge timing suited to a narrow-band envelope that is only a few dB above the noise.
public final class CWDecoderCore {
    public var pitchHz: Double { didSet { configure() } }
    public let sampleRate: Double
    public private(set) var wpm: Double = 20
    public private(set) var level: Float = 0

    /// Minimum ratio of the tracked peak to the key-up floor before any key-down is declared.
    /// The phase-1 Goertzel path keeps the default; envelope callers may lower it.
    public var minPeakToFloor = 4.0

    // MARK: Low-SNR envelope tuning (only used with `noisyEnvelope`)

    /// Statistics and segmentation suited to a noisy envelope (Rayleigh/Rician fluctuation) instead
    /// of the near-constant Goertzel level. When set:
    /// - the key-up floor is a symmetric mean, learned only from key-up time clear of any mark;
    /// - the peak rises by a fast average (`peakAttack`) instead of jumping to each noise spike;
    /// - the keying state machine runs `lookaheadBlocks` (at least 1) behind the level tracker, so the SNR gate
    ///   already reflects the first element of a transmission when it is classified;
    /// - key state comes from a Viterbi segmentation of the `fine` envelope into on and off runs
    ///   (Rician against Rayleigh likelihoods, a minimum dwell of `minDwellDots` of a dot and a
    ///   `switchPenalty` per change), decided `lookaheadBlocks` late. That places edges on the data
    ///   rather than on a noisy threshold crossing and cannot fragment a mark;
    /// - the SNR gate (`minPeakToFloor`, on the smoothed envelope) still has to pass.
    /// The default keeps the phase-1 behaviour exactly.
    public var noisyEnvelope = false
    public var peakAttack = 0.15
    public var lookaheadBlocks = 24
    /// Marks shorter than this fraction of a dot are discarded as glitches.
    public var minMarkFraction = 0.3
    /// A key-down run whose smoothed level never reached this fraction of the floor-to-peak span
    /// is a noise glitch, not a mark.
    public var minMarkPeak: Float = 0.5
    /// How fast the dot-length estimate follows each classified element.
    public var dotAdaptation = 0.1
    /// Shortest on or off run the segmentation may use, as a fraction of a dot.
    public var minDwellDots = 0.45
    /// Log-likelihood cost, in nats, of each key change.
    public var switchPenalty = 2.0
    /// Scales per-block log-likelihoods to allow for neighbouring blocks being correlated.
    public var evidenceScale = 0.5

    /// True once the tracked peak stands clear of the key-up floor by `minPeakToFloor`.
    public var signalPresent: Bool { warmupCount >= Self.warmupBlocks && peak > noiseFloor * minPeakToFloor }

    private let blockSize: Int
    private var coefficient = 0.0
    private var s1 = 0.0, s2 = 0.0, filled = 0
    private static let warmupBlocks = 20
    private var warmupCount = 0
    private var warmupSum = 0.0
    private var warmupMax = 0.0
    private var noiseFloor = 0.0
    private var peak = 0.0
    private var keyDown = false
    private var runBlocks = 0
    /// Current estimate of one dot, in ms.
    public private(set) var dotMs = 60.0
    private var symbol = ""
    private var charPending = false
    private var wordPending = false

    // Low-SNR state.
    private var pending: [(coarse: Double, fine: Double)] = []
    private var floorUpdates = 0
    private var gapBefore = 0
    private var warmupValues: [Double] = []
    private var marksSeen = 0
    private var markPeak: Float = 0
    private var inputCount = 0
    private var fineWarm = 0.0
    /// Noise power per quadrature component of the fine envelope (mean of x²/2 while key-up).
    private var fineVariance = 0.0
    private var viterbi = KeyingViterbi()
    private var decided: [Bool] = []

    public init(sampleRate: Double = 48_000, pitchHz: Double = 700) {
        self.sampleRate = sampleRate
        self.pitchHz = pitchHz
        blockSize = Int(sampleRate * 0.005)
        configure()
    }

    private func configure() { coefficient = 2 * cos(2 * .pi * pitchHz / sampleRate) }

    /// Duration of one magnitude block in ms; the Goertzel path fixes it, `process(envelope:blockMs:)` sets it.
    private lazy var blockMs: Double = Double(blockSize) / sampleRate * 1_000

    public func reset() {
        s1 = 0; s2 = 0; filled = 0
        warmupCount = 0; warmupSum = 0; warmupMax = 0
        noiseFloor = 0; peak = 0; level = 0
        keyDown = false; runBlocks = 0; dotMs = 60; wpm = 20
        symbol = ""; charPending = false; wordPending = false
        pending.removeAll(); decided.removeAll()
        warmupValues.removeAll(); floorUpdates = 0; marksSeen = 0; gapBefore = 0; markPeak = 0; inputCount = 0; fineWarm = 0; fineVariance = 0; viterbi = KeyingViterbi()
    }

    /// Feeds audio and returns any newly decoded text.
    public func process(_ x: UnsafeBufferPointer<Float>) -> String {
        var out = ""
        for v in x {
            let s0 = Double(v) + coefficient * s1 - s2
            s2 = s1
            s1 = s0
            filled += 1
            if filled == blockSize {
                let power = max(0, s1 * s1 + s2 * s2 - coefficient * s1 * s2)
                step(magnitude: power.squareRoot() / Double(blockSize), fine: 0, keyed: true, out: &out)
                s1 = 0; s2 = 0; filled = 0
            }
        }
        return out
    }

    /// Feeds one pre-computed magnitude per block (each block `blockMs` long) and returns any newly
    /// decoded text. Use this instead of `process(_:)` when the caller already has an envelope.
    public func process(envelope magnitudes: UnsafeBufferPointer<Float>, blockMs: Double) -> String {
        process(envelope: magnitudes, fine: magnitudes, blockMs: blockMs)
    }

    /// As `process(envelope:blockMs:)`, with a second, less smoothed envelope of the same length.
    /// `envelope` drives detection; `fine` only locates edges (when `noisyEnvelope` is set).
    public func process(envelope magnitudes: UnsafeBufferPointer<Float>, fine: UnsafeBufferPointer<Float>,
                        blockMs: Double) -> String {
        precondition(magnitudes.count == fine.count, "envelope and fine must have one value per block")
        self.blockMs = blockMs
        var out = ""
        for i in magnitudes.indices {
            let m = Double(magnitudes[i]), f = Double(fine[i])
            guard noisyEnvelope else {
                step(magnitude: m, fine: f, keyed: true, out: &out)
                continue
            }
            // The level tracker and the segmentation see the newest block now; the keying state
            // machine sees it `lookaheadBlocks` later.
            pending.append((m, f))
            if warmupCount >= Self.warmupBlocks, m > peak { peak += (m - peak) * peakAttack }
            pushSegmentation(fine: f)
            if pending.count > max(lookaheadBlocks, 1) {
                let s = pending.removeFirst()
                step(magnitude: s.coarse, fine: s.fine, keyed: decided.isEmpty ? false : decided.removeFirst(), out: &out)
            }
        }
        return out
    }

    private func pushSegmentation(fine f: Double) {
        inputCount += 1
        if inputCount <= Self.warmupBlocks {
            fineWarm += f * f
            fineVariance = fineWarm / (2 * Double(inputCount))
        }
        let sigma2 = max(fineVariance, 1e-12)
        let amplitude = max(peak, 1.8 * sigma2.squareRoot())
        let llr = evidenceScale * (Self.logI0(f * amplitude / sigma2) - amplitude * amplitude / (2 * sigma2))
        let dwell = max(2, Int((dotMs * minDwellDots / blockMs).rounded()))
        if let state = viterbi.push(llr: llr, minDwell: dwell, switchPenalty: switchPenalty, lag: max(lookaheadBlocks, 1)) {
            decided.append(state)
        }
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

    private func step(magnitude m: Double, fine: Double, keyed: Bool, out: inout String) {
        if warmupCount < Self.warmupBlocks {
            warmupCount += 1
            warmupSum += m
            warmupMax = max(warmupMax, m)
            if noisyEnvelope { warmupValues.append(m) }
            if warmupCount == Self.warmupBlocks {
                if noisyEnvelope {
                    // 100 ms of smoothed noise is only a couple of independent samples, so the estimate
                    // is rough. The median ignores a mark inside the warm-up, and the 1.5 margin errs
                    // high: a floor that is too high relaxes quickly, one that is too low would lock
                    // out its own correction. The peak starts at the floor, so only a real signal
                    // can open the gate.
                    noiseFloor = warmupValues.sorted()[Self.warmupBlocks / 2] * 1.5
                    peak = noiseFloor
                    warmupValues.removeAll()
                } else {
                    noiseFloor = warmupSum / Double(Self.warmupBlocks)
                    peak = warmupMax
                }
            }
            return
        }
        if m > peak && !noisyEnvelope {
            peak = m
        } else {
            peak += (max(noiseFloor, 0) - peak) * 0.002
        }
        if !keyDown {
            if noisyEnvelope {
                // Only learn the floor from well-separated key-up time: the smoothing skirts either
                // side of a mark (including the one still waiting in the lookahead) are not noise.
                let clear = Double(runBlocks) * blockMs >= dotMs && !pending.contains { $0.coarse > noiseFloor * 2.5 }
                if clear {
                    // Settle quickly from the short warm-up estimate, then average slowly.
                    floorUpdates += 1
                    let rate = max(0.02, 1 / Double(floorUpdates + 10))
                    noiseFloor += (min(m, noiseFloor * 2.5) - noiseFloor) * rate
                    fineVariance += (min(fine * fine / 2, fineVariance * 6) - fineVariance) * rate
                }
            } else {
                noiseFloor += (m - noiseFloor) * (m < noiseFloor ? 0.1 : 0.01)
            }
        }
        let span = peak - noiseFloor
        let gate = peak > noiseFloor * minPeakToFloor
        let down: Bool
        if noisyEnvelope {
            down = keyed && gate
        } else {
            down = m > noiseFloor + span * (keyDown ? 0.4 : 0.6) && gate
        }
        level = Float(min(1, max(0, (m - noiseFloor) / max(span, 1e-12))))

        if down == keyDown {
            runBlocks += 1
            if keyDown { markPeak = max(markPeak, level) } else { checkGap(out: &out) }
            return
        }
        if keyDown {
            if !noisyEnvelope || markPeak >= minMarkPeak {
                classifyMark(Double(runBlocks) * blockMs)
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

    private func classifyMark(_ ms: Double) {
        guard ms >= dotMs * (noisyEnvelope ? minMarkFraction : 0.3) else { return }
        // Noisy envelopes: jitter in single elements must not swing the dot estimate, but the first
        // few elements may move it quickly.
        marksSeen += 1
        let rate = noisyEnvelope ? max(dotAdaptation, 1 / Double(marksSeen + 2)) : 0.3
        if ms < dotMs * 2 {
            symbol += "."
            dotMs += (ms - dotMs) * rate
        } else {
            symbol += "-"
            dotMs += (ms / 3 - dotMs) * rate
        }
        dotMs = min(max(dotMs, 20), 240)
        wpm = 1_200 / dotMs
        charPending = true
        wordPending = true
    }

    private func checkGap(out: inout String) {
        let ms = Double(runBlocks) * blockMs
        if charPending && ms > dotMs * 2 {
            if !symbol.isEmpty { out.append(MorseCode.reverse[symbol] ?? "*") }
            symbol = ""
            charPending = false
        }
        if wordPending && ms > dotMs * 5 {
            out.append(" ")
            wordPending = false
        }
    }
}

/// Online two-state Viterbi segmentation of a keyed envelope into off and on runs.
///
/// State `(v, k)` means "keyed state `v`, `k` blocks into this run", `k` saturating at `cap`.
/// A run may end only once `k` has reached the minimum dwell, and every change costs a fixed
/// penalty. The "on" state earns each block's log-likelihood ratio; "off" earns nothing.
/// `push` returns the decided state of the block `lag` blocks ago.
struct KeyingViterbi {
    private static let cap = 24
    private var score: [Double]
    private var back: [[UInt8]] = []

    init() {
        score = [Double](repeating: -1e9, count: 2 * Self.cap)
        score[Self.cap - 1] = 0   // off, long since started
    }

    mutating func push(llr: Double, minDwell: Int, switchPenalty: Double, lag: Int) -> Bool? {
        let cap = Self.cap
        let dwell = min(max(minDwell, 1), cap)
        var next = [Double](repeating: -1e9, count: 2 * cap)
        var from = [UInt8](repeating: 0, count: 2 * cap)
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
                from[s] = UInt8(source)
            }
        }
        let top = next.max() ?? 0
        for i in next.indices { next[i] = max(next[i] - top, -1e9) }
        score = next
        back.append(from)
        if back.count > lag + 1 { back.removeFirst(back.count - lag - 1) }
        guard back.count == lag + 1 else { return nil }
        var state = score.firstIndex(of: 0) ?? 0
        for step in stride(from: back.count - 1, to: 0, by: -1) { state = Int(back[step][state]) }
        return state >= cap
    }
}
