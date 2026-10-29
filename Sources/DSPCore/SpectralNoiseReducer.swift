import Accelerate
import Foundation

/// Streaming spectral noise reducer for real audio: Ephraim–Malah log-spectral amplitude (MMSE-LSA)
/// gain with a decision-directed a-priori SNR and a minimum-statistics noise floor. It reproduces
/// `mmse_lsa` from docs/superpowers/research/2026-10-28-nr-spike.py, frame by frame.
///
/// Attenuates only: every bin's gain is between the strength's floor and 1. After `init`, `process`
/// does not allocate or lock, so it may run on a real-time thread.
public final class SpectralNoiseReducer {
    public static let frameSize = 1024          // at 48 kHz
    public static let hop = 256

    /// Gain floor: −8, −14, −20 dB at strength 0, 0.5, 1.
    public static func floorDb(strength: Double) -> Float { -(8 + 12 * Float(clamped(strength))) }
    /// Noise over-estimate β: 1, 1.5, 2 at strength 0, 0.5, 1.
    public static func overEstimate(strength: Double) -> Float { 1 + Float(clamped(strength)) }

    /// 0 Light … 1 Strong. Read at each frame.
    public var strength: Double = 0.5
    /// Samples by which the output lags the input.
    public var latency: Int { Self.frameSize }
    /// Smoothed (time constant about 1 s) level drop, in dB (≥ 0), that the reducer applied to the
    /// voice on speech frames, measured over the speech-band bins the voice dominates. 0 until a
    /// speech frame is seen.
    public private(set) var voiceLossDb: Float = 0

    // Noise tracker (the spike's): power smoothed per frame, its minimum over 1.5 s, × 1.8. The minimum
    // is Martin's (2001): `subWindows` stored sub-window minima plus the running one, so it spans
    // 281…315 frames and costs O(bins) per frame.
    private static let smoothing: Float = 0.85
    private static let subWindows = 8
    private static let subWindowFrames = 35
    private static let bias: Float = 1.8
    private static let noiseFloor: Float = 1e-12
    // Decision-directed a-priori SNR.
    private static let ddWeight: Float = 0.98
    private static let xiMin: Float = 0.003_162_277_7     // −25 dB
    /// Mean input power (−80 dBFS) below which a frame or hop is digital silence.
    private static let silence: Float = 1e-8
    /// Mean input power (+120 dBFS) above which, or NaN, a frame is not audio: it passes through
    /// untouched and updates no state, so one bad sample cannot poison the noise estimate or the
    /// a-priori SNR. Below it every intermediate stays finite.
    private static let overload: Float = 1e12
    /// Cap on E1's argument: its rational branch squares it, which overflows Float past ~1e19.
    private static let vMax: Float = 1e15
    /// Mean a-posteriori SNR over 300–3000 Hz above which a frame is speech (6 dB).
    private static let speechGamma: Float = 4
    /// A speech-band bin counts towards `voiceLossDb` when its a-posteriori SNR is above this (6 dB
    /// over the over-estimated noise): noise-only bins reach it with probability e⁻⁴ ≈ 2 % and
    /// carry little power, while bins the voice owns are far above it.
    private static let voiceBinGamma: Float = 4

    private let bins = frameSize / 2 + 1
    private let log2n = vDSP_Length(frameSize.trailingZeroBitCount)
    // E1 by Abramowitz & Stegun: 5.1.53's polynomial (highest power first), 5.1.56's rational.
    private let e1Small: [Float] = [0.001_078_57, -0.009_760_04, 0.055_199_68, -0.249_910_55, 0.999_991_93, -0.577_215_66]
    private let e1Numerator: [Float] = [1, 2.334_733, 0.250_621]
    private let e1Denominator: [Float] = [1, 3.330_657, 1.681_534]
    private let setup: FFTSetup
    private let speechBins: Range<Int>
    private let voiceLossKeep: Float

    private let analysis: UnsafeMutablePointer<Float>      // √Hann
    private let synthesis: UnsafeMutablePointer<Float>     // √Hann with FFT and overlap-add scaling
    private let passThrough: UnsafeMutablePointer<Float>   // analysis × synthesis, at unity gain
    private let input: UnsafeMutablePointer<Float>         // the last frameSize input samples
    private let accumulator: UnsafeMutablePointer<Float>   // overlap-add
    private let ready: UnsafeMutablePointer<Float>         // one hop of finished output
    private let work: UnsafeMutablePointer<Float>
    private let re: UnsafeMutablePointer<Float>
    private let im: UnsafeMutablePointer<Float>
    private let power: UnsafeMutablePointer<Float>
    private let smoothed: UnsafeMutablePointer<Float>
    private let runningMin: UnsafeMutablePointer<Float>
    private let storedMins: UnsafeMutablePointer<Float>    // subWindows × bins
    private let storedMin: UnsafeMutablePointer<Float>
    private let noise: UnsafeMutablePointer<Float>
    private let prevClean: UnsafeMutablePointer<Float>
    private let gamma: UnsafeMutablePointer<Float>
    private let ratio: UnsafeMutablePointer<Float>         // ξ / (1 + ξ)
    private let v: UnsafeMutablePointer<Float>
    private let e1: UnsafeMutablePointer<Float>
    private let t1: UnsafeMutablePointer<Float>
    private let t2: UnsafeMutablePointer<Float>
    private let t3: UnsafeMutablePointer<Float>
    private let gain: UnsafeMutablePointer<Float>
    private var buffers: [UnsafeMutablePointer<Float>] = []

    private var filled = 0
    /// One bit per hop in the current frame, newest in bit 0: set when that hop is digital silence.
    private var silentHops = 0
    private var trackerStarted = false
    private var subWindowCount = 0
    private var nextStored = 0
    private var storedCount = 0

    public init(sampleRate: Double = 48_000) {
        let n = Self.frameSize, h = Self.hop, bins = n / 2 + 1
        setup = vDSP_create_fftsetup(vDSP_Length(n.trailingZeroBitCount), FFTRadix(kFFTRadix2))!
        let binHz = sampleRate / Double(n)
        speechBins = Int((300 / binHz).rounded(.up))..<(Int((3000 / binHz).rounded(.down)) + 1)
        voiceLossKeep = Float(exp(-Double(h) / sampleRate))

        var all: [UnsafeMutablePointer<Float>] = []
        func buffer(_ count: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
            p.initialize(repeating: 0, count: count)
            all.append(p)
            return p
        }
        analysis = buffer(n); synthesis = buffer(n); passThrough = buffer(n)
        input = buffer(n); accumulator = buffer(n); ready = buffer(h); work = buffer(n)
        re = buffer(n / 2); im = buffer(n / 2)
        power = buffer(bins); smoothed = buffer(bins); runningMin = buffer(bins)
        storedMins = buffer(Self.subWindows * bins); storedMin = buffer(bins); noise = buffer(bins)
        prevClean = buffer(bins); gamma = buffer(bins); ratio = buffer(bins); v = buffer(bins)
        e1 = buffer(bins); t1 = buffer(bins); t2 = buffer(bins); t3 = buffer(bins); gain = buffer(bins)
        buffers = all

        // Periodic √Hann for analysis and synthesis. Their product, the Hann window, overlap-adds to a
        // constant at hop n/4; vDSP's real FFT round trip scales by 2n.
        for i in 0..<n { analysis[i] = Float(sin(Double.pi * Double(i) / Double(n))) }
        let overlap = stride(from: 0, to: n, by: h).reduce(Float(0)) { $0 + analysis[$1] * analysis[$1] }
        for i in 0..<n {
            synthesis[i] = analysis[i] / (2 * Float(n) * overlap)
            passThrough[i] = analysis[i] * analysis[i] / overlap
        }
        reset()
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        for p in buffers { p.deallocate() }
    }

    /// Clears all state; keeps `strength`.
    public func reset() {
        flushAudio()
        smoothed.update(repeating: 0, count: bins)
        noise.update(repeating: 0, count: bins)
        runningMin.update(repeating: .greatestFiniteMagnitude, count: bins)
        storedMin.update(repeating: .greatestFiniteMagnitude, count: bins)
        storedMins.update(repeating: .greatestFiniteMagnitude, count: Self.subWindows * bins)
        trackerStarted = false
        subWindowCount = 0
        nextStored = 0
        storedCount = 0
        voiceLossDb = 0
    }

    /// Clears the audio in flight (the input frame, the overlap-add, the decision-directed a-priori
    /// SNR) but keeps the noise estimate and `voiceLossDb`: for picking up again after a gap in the
    /// audio. As after `reset()`, the output is silence for `latency` samples. Does not allocate.
    public func flushAudio() {
        let n = Self.frameSize
        input.update(repeating: 0, count: n)
        accumulator.update(repeating: 0, count: n)
        ready.update(repeating: 0, count: Self.hop)
        prevClean.update(repeating: 0, count: bins)
        filled = 0
        silentHops = (1 << (n / Self.hop)) - 1     // before the first sample counts as silence
    }

    /// In place, any count; output delayed by `latency`.
    public func process(_ buffer: UnsafeMutableBufferPointer<Float>) {
        guard var p = buffer.baseAddress else { return }
        let n = Self.frameSize, h = Self.hop
        var remaining = buffer.count
        while remaining > 0 {
            let count = min(remaining, h - filled)
            (input + n - h + filled).update(from: p, count: count)
            p.update(from: ready + filled, count: count)
            filled += count
            p += count
            remaining -= count
            if filled == h {
                filled = 0
                processFrame()
            }
        }
    }

    private func processFrame() {
        let n = Self.frameSize, h = Self.hop
        var hopPower: Float = 0, framePower: Float = 0
        vDSP_measqv(input + n - h, 1, &hopPower, vDSP_Length(h))
        vDSP_measqv(input, 1, &framePower, vDSP_Length(n))
        silentHops = (silentHops << 1 | (hopPower < Self.silence ? 1 : 0)) & ((1 << (n / h)) - 1)
        let touchesSilence = silentHops != 0

        if framePower < Self.silence || !(framePower <= Self.overload) || (touchesSilence && !trackerStarted) {
            // Digital silence, NaN, infinity or overload (or no noise estimate yet): out as in, no
            // state updated.
            vDSP_vma(input, 1, passThrough, 1, accumulator, 1, accumulator, 1, vDSP_Length(n))
        } else {
            reduce(updatingTracker: !touchesSilence)
        }

        ready.update(from: accumulator, count: h)
        accumulator.update(from: accumulator + h, count: n - h)
        (accumulator + n - h).update(repeating: 0, count: h)
        input.update(from: input + h, count: n - h)
    }

    /// One STFT frame. A frame that straddles digital silence is reduced with the noise estimate it
    /// has but doesn't update it: its partial power would pull the minimum down.
    private func reduce(updatingTracker: Bool) {
        let n = Self.frameSize, half = n / 2, count = vDSP_Length(bins)
        var split = DSPSplitComplex(realp: re, imagp: im)
        vDSP_vmul(input, 1, analysis, 1, work, 1, vDSP_Length(n))
        work.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))

        // |rfft|² (vDSP's forward real FFT is 2× the DFT). Packed: DC in re[0], Nyquist in im[0].
        vDSP_zvmags(&split, 1, power, 1, vDSP_Length(half))
        power[0] = re[0] * re[0]
        power[half] = im[0] * im[0]
        var quarter: Float = 0.25
        vDSP_vsmul(power, 1, &quarter, power, 1, count)

        let settled = trackerSettled      // as of the noise estimate this frame uses
        if updatingTracker { trackNoise() }

        let beta = Self.overEstimate(strength: strength)
        let floorGain = Float(pow(10, Double(Self.floorDb(strength: strength)) / 20))
        for k in 0..<bins {
            let nb = noise[k] * beta
            let g = max(power[k] / nb, 1e-6)                                           // a posteriori
            let xi = max(Self.ddWeight * prevClean[k] / nb + (1 - Self.ddWeight) * max(g - 1, 0), Self.xiMin)
            let r = xi / (1 + xi)
            gamma[k] = g
            ratio[k] = r
            v[k] = min(max(r * g, 1e-8), Self.vMax)
        }
        exponentialIntegral()
        var halfScale: Float = 0.5
        var bins32 = Int32(bins)
        vDSP_vsmul(e1, 1, &halfScale, e1, 1, count)
        vvexpf(e1, e1, &bins32)
        for k in 0..<bins { gain[k] = min(max(ratio[k] * e1[k], floorGain), 1) }

        vDSP_vmul(gain, 1, gain, 1, prevClean, 1, count)
        vDSP_vmul(prevClean, 1, power, 1, prevClean, 1, count)     // G²·P

        var meanGamma: Float = 0
        vDSP_meanv(gamma + speechBins.lowerBound, 1, &meanGamma, vDSP_Length(speechBins.count))
        if settled && meanGamma > Self.speechGamma {
            // Voice loss: the level drop on the bins where the voice dominates, not the hiss the
            // reducer removed elsewhere (make-up built on that would lift the hiss back up).
            var inPower: Float = 0, outPower: Float = 0
            for k in speechBins where gamma[k] > Self.voiceBinGamma {
                inPower += power[k]
                outPower += prevClean[k]
            }
            if inPower > 0 {
                let loss = max(0, 10 * log10(inPower / max(outPower, .leastNormalMagnitude)))
                voiceLossDb = voiceLossKeep * voiceLossDb + (1 - voiceLossKeep) * loss
            }
        }

        re[0] *= gain[0]
        im[0] *= gain[half]
        vDSP_vmul(re + 1, 1, gain + 1, 1, re + 1, 1, vDSP_Length(half - 1))
        vDSP_vmul(im + 1, 1, gain + 1, 1, im + 1, 1, vDSP_Length(half - 1))
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
        work.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
        }
        vDSP_vma(work, 1, synthesis, 1, accumulator, 1, accumulator, 1, vDSP_Length(n))
    }

    /// The tracker starts from a single frame's power, so until that first sub-window leaves the
    /// minimum (1.7 s) some bins' noise estimates sit far too low and noise looks like speech.
    private var trackerSettled: Bool { storedCount > Self.subWindows }

    private func trackNoise() {
        let count = vDSP_Length(bins)
        if trackerStarted {
            var keep = Self.smoothing, take = 1 - Self.smoothing
            vDSP_vsmsma(smoothed, 1, &keep, power, 1, &take, smoothed, 1, count)
        } else {
            smoothed.update(from: power, count: bins)
            trackerStarted = true
        }
        vDSP_vmin(runningMin, 1, smoothed, 1, runningMin, 1, count)
        vDSP_vmin(runningMin, 1, storedMin, 1, noise, 1, count)
        var bias = Self.bias, floor = Self.noiseFloor
        vDSP_vsmul(noise, 1, &bias, noise, 1, count)
        vDSP_vthr(noise, 1, &floor, noise, 1, count)

        subWindowCount += 1
        if subWindowCount == Self.subWindowFrames {
            (storedMins + nextStored * bins).update(from: runningMin, count: bins)
            nextStored = (nextStored + 1) % Self.subWindows
            storedCount = min(storedCount + 1, Self.subWindows + 1)
            storedMin.update(from: storedMins, count: bins)
            for s in 1..<Self.subWindows {
                vDSP_vmin(storedMin, 1, storedMins + s * bins, 1, storedMin, 1, count)
            }
            runningMin.update(repeating: .greatestFiniteMagnitude, count: bins)
            subWindowCount = 0
        }
    }

    /// E1(v) into `e1`, as the spike: 5.1.53 for v < 1, 5.1.56 for v ≥ 1.
    private func exponentialIntegral() {
        let count = vDSP_Length(bins)
        var bins32 = Int32(bins)
        // Small branch: poly(v) − ln v.
        vvlogf(t1, v, &bins32)
        e1Small.withUnsafeBufferPointer { vDSP_vpoly($0.baseAddress!, 1, v, 1, e1, 1, count, 5) }
        vDSP_vsub(t1, 1, e1, 1, e1, 1, count)
        // Large branch on max(v, 1): e^−v / v · num(v) / den(v).
        var one: Float = 1
        vDSP_vthr(v, 1, &one, t1, 1, count)
        e1Numerator.withUnsafeBufferPointer { vDSP_vpoly($0.baseAddress!, 1, t1, 1, t2, 1, count, 2) }
        vDSP_vdiv(t1, 1, t2, 1, t2, 1, count)                      // num / v
        e1Denominator.withUnsafeBufferPointer { vDSP_vpoly($0.baseAddress!, 1, t1, 1, t3, 1, count, 2) }
        vDSP_vdiv(t3, 1, t2, 1, t2, 1, count)                    // num / (v·den)
        vDSP_vneg(t1, 1, t1, 1, count)
        vvexpf(t1, t1, &bins32)
        vDSP_vmul(t1, 1, t2, 1, t2, 1, count)
        for k in 0..<bins where v[k] >= 1 { e1[k] = t2[k] }
    }

    private static func clamped(_ s: Double) -> Double { min(max(s, 0), 1) }
}
