import Accelerate
import DSPCore
import Foundation

/// Multi-signal CW decoder: each instance decodes one signal at its own audio frequency from
/// 12 kHz box audio.
public enum CWModem: StreamingModem {
    public static let id: ModeID = .cw

    public static func makeDecoder(frequencyHz: Double, sampleRate: Double) -> any SignalDecoder {
        CWSignalDecoder(frequencyHz: frequencyHz, sampleRate: sampleRate)
    }
}

/// One CW signal: NCO mix to baseband, complex low-pass decimation to 1 kHz, 5 ms envelope blocks,
/// then `CWDecoderCore`. A slow AFC follows the carrier from the baseband phase slope during key-down.
///
/// Not thread-safe; owned by one thread at a time (see `SignalDecoder`).
public final class CWSignalDecoder: SignalDecoder {
    public var frequencyHz: Double { tunedHz }
    public var submode: String { "CW \(Int(core.wpm.rounded()))WPM" }

    private let sampleRate: Double
    private let originHz: Double
    private var tunedHz: Double
    private var nco: NCO
    private var decimator: ComplexDecimator
    private let core: CWDecoderCore

    private static let basebandRate = 1_000.0
    /// Baseband low-pass cutoff. Narrow enough to cost the noise very little, wide enough for
    /// keying up to about 35 WPM.
    private static let cutoffHz = 40.0
    /// Moving-average length of the detection envelope, as a fraction of the current dot.
    private static let smoothDots = 1.0
    /// Blocks the keying state machine runs behind the level tracker (120 ms).
    private static let lookahead = 24
    /// A key-down run must be at least this long, in dots, to count as a mark.
    private static let minMark = 0.55
    private static let minPeakToFloor = 4.0
    private static let minDwellDots = 0.85
    private static let switchPenalty = 2.0
    private static let evidenceScale = 0.5
    private static let dotAdaptation = 0.1
    private static let minMarkPeak: Float = 0.5
    private static let blockSamples = 5
    private static let afcStepLimitHz = 2.0
    private static let afcGain = 0.5

    private var scratch: [DSPComplex] = []
    private var baseband: [DSPComplex] = []
    private var blockSum: Float = 0
    private var blockCount = 0
    private var envelope: [Float] = []
    private var fineEnvelope: [Float] = []
    private var fineSum: Float = 0
    private var ring = [DSPComplex](repeating: DSPComplex(real: 0, imag: 0), count: 256)
    private var ringHead = 0
    private var magRing = [Float](repeating: 0, count: 256)
    private static let settleSamples = 100
    private var settle = settleSamples

    // AFC state: Σ z[n]·conj(z[n-1]) over key-down samples, in the current 1 s window.
    private var previous = DSPComplex(real: 0, imag: 0)
    private var lagRe: Double = 0
    private var lagIm: Double = 0
    private var lagCount = 0
    private var windowSamples = 0
    private var envPeak: Float = 0

    public init(frequencyHz: Double, sampleRate: Double = 12_000) {
        self.sampleRate = sampleRate
        originHz = frequencyHz
        tunedHz = frequencyHz
        nco = NCO(frequency: -frequencyHz, sampleRate: sampleRate)
        decimator = Self.makeDecimator(sampleRate: sampleRate)
        core = CWDecoderCore(sampleRate: Self.basebandRate, pitchHz: frequencyHz)
        core.noisyEnvelope = true
        core.minPeakToFloor = Self.minPeakToFloor
        core.lookaheadBlocks = Self.lookahead
        core.minMarkFraction = Self.minMark
        core.minMarkPeak = Self.minMarkPeak
        core.dotAdaptation = Self.dotAdaptation
        core.minDwellDots = Self.minDwellDots
        core.switchPenalty = Self.switchPenalty
        core.evidenceScale = Self.evidenceScale
    }

    private static func makeDecimator(sampleRate: Double) -> ComplexDecimator {
        let factor = max(1, Int((sampleRate / basebandRate).rounded()))
        // Blackman-Harris transition ≈ 6/N cycles/sample: here twice the cutoff, so the pass-band edge
        // and the stop band are 3 × cutoff apart at most.
        let taps = FIRDesign.tapCount(transition: 2 * cutoffHz / sampleRate)
        return ComplexDecimator(taps: FIRDesign.lowpass(taps: taps, cutoff: cutoffHz / sampleRate), factor: factor)
    }

    public func process(_ audio: UnsafeBufferPointer<Float>) -> String {
        guard !audio.isEmpty else { return "" }
        if scratch.count < audio.count { scratch = .init(repeating: DSPComplex(real: 0, imag: 0), count: audio.count) }
        for i in 0..<audio.count { scratch[i] = DSPComplex(real: audio[i], imag: 0) }
        scratch.withUnsafeMutableBufferPointer { s in
            nco.mix(UnsafeMutableBufferPointer(rebasing: s[0..<audio.count]))
        }
        baseband.removeAll(keepingCapacity: true)
        scratch.withUnsafeBufferPointer { s in
            decimator.process(UnsafeBufferPointer(rebasing: s[0..<audio.count]), into: &baseband)
        }

        envelope.removeAll(keepingCapacity: true)
        fineEnvelope.removeAll(keepingCapacity: true)
        for z in baseband {
            // The FIR and the smoothing ring start empty; their ramp would corrupt the noise floor.
            if settle > 0 { settle -= 1; _ = smooth(z); previous = z; continue }
            let mag = (z.real * z.real + z.imag * z.imag).squareRoot()
            let sm = smooth(z)
            blockSum += sm.coarse
            fineSum += sm.fine
            blockCount += 1
            if blockCount == Self.blockSamples {
                envelope.append(blockSum / Float(Self.blockSamples))
                fineEnvelope.append(fineSum / Float(Self.blockSamples))
                blockSum = 0; fineSum = 0
                blockCount = 0
            }
            accumulateAFC(z, mag: mag)
        }
        let blockMs = Double(Self.blockSamples) / Self.basebandRate * 1_000
        let text = envelope.withUnsafeBufferPointer { coarse in
            fineEnvelope.withUnsafeBufferPointer { fine in
                core.process(envelope: coarse, fine: fine, blockMs: blockMs)
            }
        }
        return text
    }

    /// Smooths the complex baseband with a moving average about as long as a dot, which narrows the
    /// noise bandwidth to roughly the keying bandwidth. Returns the smoothed magnitude and the
    /// unsmoothed magnitude from the middle of that window, so the two line up in time.
    private func smooth(_ z: DSPComplex) -> (coarse: Float, fine: Float) {
        ring[ringHead] = z
        magRing[ringHead] = (z.real * z.real + z.imag * z.imag).squareRoot()
        ringHead = (ringHead + 1) % ring.count
        let length = min(max(Int(core.dotMs * Self.smoothDots * Self.basebandRate / 1_000), 4), ring.count)
        var re: Float = 0, im: Float = 0
        var idx = ringHead
        for _ in 0..<length {
            idx = (idx + ring.count - 1) % ring.count
            re += ring[idx].real
            im += ring[idx].imag
        }
        let inv = 1 / Float(length)
        let mid = (ringHead + ring.count - 1 - (length - 1) / 2) % ring.count
        return (((re * inv) * (re * inv) + (im * inv) * (im * inv)).squareRoot(), magRing[mid])
    }

    /// Gathers the lag-1 product during key-down and, once per second, nudges the NCO.
    private func accumulateAFC(_ z: DSPComplex, mag: Float) {
        if mag > envPeak { envPeak = mag } else { envPeak *= 0.9995 }
        if mag > envPeak * 0.6 && previous.real * previous.real + previous.imag * previous.imag > 0 {
            // z[n] · conj(z[n-1])
            lagRe += Double(z.real * previous.real + z.imag * previous.imag)
            lagIm += Double(z.imag * previous.real - z.real * previous.imag)
            lagCount += 1
        }
        previous = z
        windowSamples += 1
        guard windowSamples >= Int(Self.basebandRate) else { return }
        if lagCount >= 100 && core.signalPresent {
            let offsetHz = atan2(lagIm, lagRe) / (2 * .pi) * Self.basebandRate
            let step = min(max(offsetHz * Self.afcGain, -Self.afcStepLimitHz), Self.afcStepLimitHz)
            let limit = ModeID.cw.lockRangeHz
            tunedHz = min(max(tunedHz + step, originHz - limit), originHz + limit)
            nco.setFrequency(-tunedHz, sampleRate: sampleRate)
        }
        lagRe = 0; lagIm = 0; lagCount = 0; windowSamples = 0
    }

    public func constellation() -> [SIMD2<Float>] { [] }

    public func reset() {
        tunedHz = originHz
        nco = NCO(frequency: -originHz, sampleRate: sampleRate)
        decimator = Self.makeDecimator(sampleRate: sampleRate)
        core.reset()
        ring = [DSPComplex](repeating: DSPComplex(real: 0, imag: 0), count: ring.count); ringHead = 0; settle = Self.settleSamples
        magRing = [Float](repeating: 0, count: magRing.count)
        blockSum = 0; fineSum = 0; blockCount = 0
        previous = DSPComplex(real: 0, imag: 0)
        lagRe = 0; lagIm = 0; lagCount = 0; windowSamples = 0; envPeak = 0
    }
}
