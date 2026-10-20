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
/// then `CWEnvelopeDecoder` (floor/peak statistics, Viterbi keying segmentation, speed clustering).
/// A slow AFC follows the carrier from the baseband phase slope during key-down.
///
/// Speed range: 5 to about 40 WPM at +10 dB (see the tests); at -8 dB, 20 WPM.
///
/// Not thread-safe; owned by one thread at a time (see `SignalDecoder`).
public final class CWSignalDecoder: SignalDecoder {
    public var frequencyHz: Double { tunedHz }
    public var submode: String { "CW \(Int(decoder.wpm.rounded()))WPM" }

    private let sampleRate: Double
    private let originHz: Double
    private var tunedHz: Double
    private var nco: NCO
    private var decimator: ComplexDecimator
    private let decoder: CWEnvelopeDecoder

    private static let basebandRate = 1_000.0
    /// Baseband low-pass cutoff, Hz.
    private static let cutoffHz = 40.0
    /// Moving-average length of the detection envelope, in dots of the current speed estimate,
    /// bounded so a wrong estimate cannot run the smoothing away.
    private static let smoothDots = 1.0
    private static let smoothBoundsMs = 24.0...150.0
    /// Moving-average length of the segmentation envelope, in dots.
    private static let fineDots = 0.4
    private static let blockSamples = 5
    private static let settleSamples = 100
    private static let afcStepLimitHz = 2.0
    private static let afcGain = 0.5

    private var scratch: [DSPComplex] = []
    private var baseband: [DSPComplex] = []
    private var coarseEnvelope: [Float] = []
    private var fineEnvelope: [Float] = []
    private var coarseSum: Float = 0
    private var fineSum: Float = 0
    private var blockCount = 0
    private var settle = settleSamples

    // Smoothing: running sum of the last `smoothLength` baseband samples.
    private static let ringSize = 256
    private var ring = [DSPComplex](repeating: DSPComplex(real: 0, imag: 0), count: ringSize)
    private var ringHead = 0
    private var coarse = Window()
    private var fine = Window()
    private var sinceRecompute = 0

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
        decoder = CWEnvelopeDecoder(blockMs: Double(Self.blockSamples) / Self.basebandRate * 1_000)
    }

    private static func makeDecimator(sampleRate: Double) -> ComplexDecimator {
        let factor = max(1, Int((sampleRate / basebandRate).rounded()))
        // Blackman-Harris transition ≈ 6/N cycles/sample, so a transition band of twice the cutoff.
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

        coarseEnvelope.removeAll(keepingCapacity: true)
        fineEnvelope.removeAll(keepingCapacity: true)
        for z in baseband {
            let sm = smooth(z)
            // The FIR and the smoothing ring start empty; their ramp would corrupt the noise floor.
            if settle > 0 { settle -= 1; previous = z; continue }
            coarseSum += sm.coarse
            fineSum += sm.fine
            blockCount += 1
            if blockCount == Self.blockSamples {
                coarseEnvelope.append(coarseSum / Float(Self.blockSamples))
                fineEnvelope.append(fineSum / Float(Self.blockSamples))
                coarseSum = 0; fineSum = 0; blockCount = 0
            }
            accumulateAFC(z)
        }
        return coarseEnvelope.withUnsafeBufferPointer { coarse in
            fineEnvelope.withUnsafeBufferPointer { fine in
                decoder.process(coarse: coarse, fine: fine)
            }
        }
    }

    /// Moving average of the complex baseband over `length` samples ending `delay` samples before the
    /// newest, kept as a running sum. Rebuilt from the ring whenever its shape changes.
    private struct Window {
        var length = 0, delay = 0
        var re = 0.0, im = 0.0

        mutating func advance(ring: [DSPComplex], newest: Int, length wanted: Int, delay wantedDelay: Int, rebuild: Bool) {
            let size = ring.count
            if rebuild || wanted != length || wantedDelay != delay {
                length = wanted; delay = wantedDelay
                re = 0; im = 0
                for back in 0..<length {
                    let v = ring[(newest + size - delay - back) % size]
                    re += Double(v.real); im += Double(v.imag)
                }
                return
            }
            let entering = ring[(newest + size - delay) % size]
            let leaving = ring[(newest + size - delay - length) % size]
            re += Double(entering.real) - Double(leaving.real)
            im += Double(entering.imag) - Double(leaving.imag)
        }

        var magnitude: Float { Float((re * re + im * im).squareRoot() / Double(max(length, 1))) }
    }

    /// Smooths the complex baseband before taking the magnitude, which narrows the noise bandwidth.
    /// `coarse` averages about a dot and drives detection. `fine` averages a fraction of a dot and
    /// drives the keying segmentation. Both windows are centred on the same instant.
    private func smooth(_ z: DSPComplex) -> (coarse: Float, fine: Float) {
        let size = Self.ringSize
        let dot = min(max(decoder.dotMs * Self.smoothDots, Self.smoothBoundsMs.lowerBound), Self.smoothBoundsMs.upperBound)
        var coarseLength = Int(dot * Self.basebandRate / 1_000)
        var fineLength = max(1, Int(dot * Self.fineDots * Self.basebandRate / 1_000))
        // Hysteresis: only change a window's shape when the target has moved by 2 samples.
        if abs(coarseLength - coarse.length) < 2 && coarse.length > 0 { coarseLength = coarse.length }
        if abs(fineLength - fine.length) < 2 && fine.length > 0 { fineLength = fine.length }
        let newest = ringHead
        ring[newest] = z
        ringHead = (ringHead + 1) % size
        sinceRecompute += 1
        let rebuild = sinceRecompute >= 4_096
        if rebuild { sinceRecompute = 0 }
        coarse.advance(ring: ring, newest: newest, length: coarseLength, delay: 0, rebuild: rebuild)
        // The fine window ends later in time than the coarse one starts: centre it on the coarse centre.
        fine.advance(ring: ring, newest: newest, length: fineLength,
                     delay: max(0, (coarseLength - fineLength) / 2), rebuild: rebuild)
        return (coarse.magnitude, fine.magnitude)
    }

    /// Gathers the lag-1 product during key-down and, once per second, nudges the NCO.
    private func accumulateAFC(_ z: DSPComplex) {
        let mag = (z.real * z.real + z.imag * z.imag).squareRoot()
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
        if lagCount >= 100 && decoder.signalPresent {
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
        decoder.reset()
        ring = [DSPComplex](repeating: DSPComplex(real: 0, imag: 0), count: Self.ringSize)
        ringHead = 0; coarse = Window(); fine = Window(); sinceRecompute = 0
        settle = Self.settleSamples
        coarseSum = 0; fineSum = 0; blockCount = 0
        previous = DSPComplex(real: 0, imag: 0)
        lagRe = 0; lagIm = 0; lagCount = 0; windowSamples = 0; envPeak = 0
    }
}
