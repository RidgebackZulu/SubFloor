import Accelerate
import DSPCore
import Foundation
import simd

/// One update of the cursor bench: what the locked signal looks like right now.
public struct CursorFrame: Sendable {
    /// Up to 480 samples (40 ms) of the narrow-filtered cursor audio, starting on a rising zero
    /// crossing (interpolated, so `waveform[0]` is 0 and the trace stands still from frame to frame).
    public var waveform: [Float]
    /// 401 bins of averaged power in dB (0 dB = a full-scale sine), 0.5 Hz apart, covering
    /// `spectrumCenterHz` ± 100 Hz; bin 200 is the centre.
    public var spectrumDb: [Float]
    public var spectrumCenterHz: Double
    /// Up to 128 points, oldest first: the decoder's constellation (PSK31 symbols, RTTY mark/space
    /// pairs), or for a decoder without one (CW, or no decoder) a decimated baseband IQ trail
    /// normalised to unit RMS.
    public var iq: [SIMD2<Float>]
    public var frequencyHz: Double
    public var snrDb: Float
    public var submode: String
    /// Symbol (baud) rate of the cursor's mode, when it has a fixed one.
    public var symbolRate: Double?

    public init(waveform: [Float], spectrumDb: [Float], spectrumCenterHz: Double, iq: [SIMD2<Float>],
                frequencyHz: Double, snrDb: Float, submode: String, symbolRate: Double?) {
        self.waveform = waveform
        self.spectrumDb = spectrumDb
        self.spectrumCenterHz = spectrumCenterHz
        self.iq = iq
        self.frequencyHz = frequencyHz
        self.snrDb = snrDb
        self.submode = submode
        self.symbolRate = symbolRate
    }
}

/// Bench analysis of the cursor signal, on the modem thread.
///
/// - Micro spectrum: the box audio is mixed down at the cursor frequency and decimated to complex
///   baseband at 500 Hz (±100 Hz flat, nothing aliasing within ±250 Hz). Each frame transforms the
///   last 2 s (1000 samples, Hann window, zero-padded to a 2048-point FFT, so 0.24 Hz bins over a
///   0.5 Hz resolution) and samples the ±100 Hz slice at 401 points 0.5 Hz apart by linear
///   interpolation in power. Frames are averaged exponentially (α = 0.3) in power. This is the same
///   2 s window and 0.5 Hz bins as a 24 000-point FFT of the 12 kHz audio, at a fraction of the cost.
/// - Waveform: the last 480 samples of the narrow-filtered audio before a rising zero crossing that
///   leaves 480 samples after it, resampled to start exactly on the crossing.
/// - IQ trail (when the decoder has no constellation): every 4th baseband sample (125 Hz).
///
/// A retune by more than 5 Hz (a new cursor signal) restarts the baseband history and the averaging;
/// smaller retunes (AFC) keep them.
///
/// Not thread-safe: confine an instance to one thread (the modem thread).
public final class CursorAnalyzer {
    public static let spectrumBins = 401
    public static let spectrumHalfSpanHz = 100.0
    public static let waveformSamples = 480
    public static let maxIQPoints = 128

    static let basebandRate = 500.0
    static let windowSamples = 1_000
    static let fftLog2 = 11
    static let averagingAlpha: Float = 0.3
    static let restartHz = 5.0
    static let trailDecimation = 4
    /// Narrow-audio history searched for a trigger: the waveform plus up to 1250 samples (over 20
    /// cycles of a 200 Hz tone) before it.
    static let narrowHistory = 2_048

    public let sampleRate: Double
    public private(set) var centerHz: Double = 0

    private var nco = NCO()
    private var decimator: ComplexDecimator
    private let factor: Int
    private let rate: Double
    private var mixScratch: [DSPComplex]
    private var baseband: [DSPComplex] = []

    private var ring: [SIMD2<Float>]
    private var ringCount = 0
    private var narrow: [Float]
    private var narrowCount = 0

    private let fftSetup: FFTSetup
    private let window: [Float]
    private let powerScale: Float
    private var re: [Float]
    private var im: [Float]
    private var power: [Float]
    private var average: [Float]
    private var averaged = false
    private var linear: [Float]

    public init(sampleRate: Double = 12_000) {
        self.sampleRate = sampleRate
        factor = max(1, Int((sampleRate / Self.basebandRate).rounded()))
        rate = sampleRate / Double(factor)
        decimator = Self.makeDecimator(sampleRate: sampleRate, factor: factor)
        mixScratch = .init(repeating: DSPComplex(real: 0, imag: 0), count: 4_096)
        ring = .init(repeating: .zero, count: Self.windowSamples)
        narrow = .init(repeating: 0, count: Self.narrowHistory)
        fftSetup = vDSP_create_fftsetup(vDSP_Length(Self.fftLog2), FFTRadix(kFFTRadix2))!
        window = WindowKind.hann.coefficients(count: Self.windowSamples)
        let sum = window.reduce(0, +)
        // A real sine of amplitude A is A/2 at baseband: 4/(Σw)² makes a full-scale sine read 0 dB.
        powerScale = 4 / (sum * sum)
        let n = 1 << Self.fftLog2
        re = .init(repeating: 0, count: n)
        im = .init(repeating: 0, count: n)
        power = .init(repeating: 0, count: n)
        average = .init(repeating: 0, count: Self.spectrumBins)
        linear = .init(repeating: 0, count: Self.spectrumBins)
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    private static func makeDecimator(sampleRate: Double, factor: Int) -> ComplexDecimator {
        // Flat to ±100 Hz, stopped by about ±230 Hz: nothing folds into the ±100 Hz slice.
        let taps = FIRDesign.tapCount(transition: 100 / sampleRate)
        return ComplexDecimator(taps: FIRDesign.lowpass(taps: max(taps, factor), cutoff: 150 / sampleRate), factor: factor)
    }

    /// Follows the cursor. A move of more than 5 Hz starts the analysis afresh.
    public func retune(_ hz: Double) {
        if abs(hz - centerHz) > Self.restartHz { restart() }
        centerHz = hz
        nco.setFrequency(-hz, sampleRate: sampleRate)
    }

    /// Clears all history.
    public func reset() {
        restart()
        narrowCount = 0
        for i in narrow.indices { narrow[i] = 0 }
    }

    private func restart() {
        decimator = Self.makeDecimator(sampleRate: sampleRate, factor: factor)
        nco = NCO(frequency: -centerHz, sampleRate: sampleRate)
        ringCount = 0
        averaged = false
    }

    /// Consumes one block of box audio and the matching block of narrow-filtered cursor audio.
    public func process(box: UnsafeBufferPointer<Float>, narrow audio: UnsafeBufferPointer<Float>) {
        var start = 0
        while start < box.count {
            let n = min(mixScratch.count, box.count - start)
            for i in 0..<n { mixScratch[i] = DSPComplex(real: box[start + i], imag: 0) }
            mixScratch.withUnsafeMutableBufferPointer { nco.mix(UnsafeMutableBufferPointer(rebasing: $0[0..<n])) }
            baseband.removeAll(keepingCapacity: true)
            mixScratch.withUnsafeBufferPointer { decimator.process(UnsafeBufferPointer(rebasing: $0[0..<n]), into: &baseband) }
            for z in baseband {
                ring[ringCount % ring.count] = SIMD2(z.real, z.imag)
                ringCount += 1
            }
            start += n
        }
        for x in audio {
            narrow[narrowCount % narrow.count] = x
            narrowCount += 1
        }
    }

    /// Builds a frame. `constellation` is the decoder's (empty when it has none, or no decoder).
    public func frame(frequencyHz: Double, snrDb: Float, submode: String, symbolRate: Double?,
                      constellation: [SIMD2<Float>]) -> CursorFrame {
        updateSpectrum()
        let db = average.map { 10 * log10(max($0, 1e-20)) }
        let iq = constellation.isEmpty ? trail() : Array(constellation.suffix(Self.maxIQPoints))
        return CursorFrame(waveform: waveform(), spectrumDb: db, spectrumCenterHz: centerHz, iq: iq,
                           frequencyHz: frequencyHz, snrDb: snrDb, submode: submode, symbolRate: symbolRate)
    }

    // MARK: Spectrum

    private func updateSpectrum() {
        let n = 1 << Self.fftLog2
        let have = min(ringCount, ring.count)
        guard have > 0 else {
            for i in average.indices { average[i] = 0 }
            return
        }
        // The last `have` samples, oldest first, windowed (a short history uses the window's tail
        // half-open: still a taper at the start, so the spectrum stays clean while it fills).
        let offset = Self.windowSamples - have
        for i in 0..<n { re[i] = 0; im[i] = 0 }
        for k in 0..<have {
            let z = ring[(ringCount - have + k) % ring.count]
            let w = window[offset + k]
            re[k] = z.x * w
            im[k] = z.y * w
        }
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                power.withUnsafeMutableBufferPointer { pp in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zip(fftSetup, &split, 1, vDSP_Length(Self.fftLog2), FFTDirection(kFFTDirection_Forward))
                    vDSP_zvmags(&split, 1, pp.baseAddress!, 1, vDSP_Length(n))
                }
            }
        }
        let binHz = rate / Double(n)
        let step = 2 * Self.spectrumHalfSpanHz / Double(Self.spectrumBins - 1)
        for j in 0..<Self.spectrumBins {
            let f = -Self.spectrumHalfSpanHz + Double(j) * step
            let x = f / binHz
            let k0 = Int(x.rounded(.down))
            let t = Float(x - Double(k0))
            let a = power[(k0 % n + n) % n], b = power[((k0 + 1) % n + n) % n]
            linear[j] = (a + t * (b - a)) * powerScale
        }
        if averaged {
            for j in average.indices { average[j] += Self.averagingAlpha * (linear[j] - average[j]) }
        } else {
            for j in average.indices { average[j] = linear[j] }
            averaged = true
        }
    }

    // MARK: Waveform

    private func waveform() -> [Float] {
        let size = narrow.count
        let have = min(narrowCount, size)
        let length = min(Self.waveformSamples, have)
        guard length > 1 else { return Array(repeating: 0, count: length) }
        func sample(_ i: Int) -> Float { narrow[(narrowCount - have + i) % size] }
        // The latest rising crossing with a whole waveform after it.
        var j = have - length
        while j >= 1 {
            let a = sample(j - 1), b = sample(j)
            if a < 0 && b >= 0 {
                let t0 = Double(j - 1) + Double(a / (a - b))
                return (0..<length).map { k in
                    let x = t0 + Double(k)
                    let i = Int(x.rounded(.down))
                    let f = Float(x - Double(i))
                    let lo = sample(i), hi = i + 1 < have ? sample(i + 1) : lo
                    return k == 0 ? 0 : lo + f * (hi - lo)
                }
            }
            j -= 1
        }
        return (0..<length).map { sample(have - length + $0) }
    }

    // MARK: IQ trail

    private func trail() -> [SIMD2<Float>] {
        let have = min(ringCount, ring.count)
        let count = min(Self.maxIQPoints, have / Self.trailDecimation)
        guard count > 0 else { return [] }
        var points = (0..<count).map { k -> SIMD2<Float> in
            let back = (count - 1 - k) * Self.trailDecimation
            return ring[(ringCount - 1 - back) % ring.count]
        }
        let rms = (points.reduce(Float(0)) { $0 + simd_length_squared($1) } / Float(count)).squareRoot()
        if rms > 0 { points = points.map { $0 / rms } }
        return points
    }
}
