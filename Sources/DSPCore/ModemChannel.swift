import Accelerate
import Foundation

/// IQ in, 12 kHz real USB audio out for one 3 kHz modem box (audio 300…3300 Hz above the dial).
/// Linear: there is deliberately no AGC, so levels stay valid for SNR estimates.
public final class ModemChannel: @unchecked Sendable {
    public static let outputRate = 12_000.0
    /// Audio centre of the 300…3300 Hz box.
    private static let centerHz = 1_800.0
    private static let channelHalfBandwidth = 1_700.0

    public let inputRate: Double
    public private(set) var channelRate: Double = 0

    private var nco: NCO
    private var audioNCO = NCO()
    private var stages: [ComplexDecimator] = []
    private var channelFilter = ComplexDecimator(taps: [1], factor: 1)
    private var resampler: FractionalResampler
    private var work: [DSPComplex] = []
    private var work2: [DSPComplex] = []
    private var realAudio: [Float] = []

    /// `dialOffsetHz` is the box dial minus the capture centre.
    public init(inputRate: Double, dialOffsetHz: Double) {
        self.inputRate = inputRate
        nco = NCO()
        resampler = FractionalResampler(inputRate: Self.outputRate, outputRate: Self.outputRate)

        var rate = inputRate
        stages = DecimationPlan.stages(inputRate: rate, minimumRate: Self.outputRate).map { f in
            let df = Double(f)
            rate /= df
            let taps = FIRDesign.lowpass(taps: FIRDesign.tapCount(transition: 0.38 / df, max: 255), cutoff: 0.45 / df)
            return ComplexDecimator(taps: taps, factor: f)
        }
        channelRate = rate
        // ±1700 Hz box filter: flat through ±1500 (audio 300/3300), >60 dB down by the time
        // the opposite sideband (audio -300 → baseband -2100 and beyond) is reached.
        let channelTaps = FIRDesign.lowpass(
            taps: FIRDesign.tapCount(transition: 400 / rate, max: 1023),
            cutoff: (Self.channelHalfBandwidth + 200) / rate)
        channelFilter = ComplexDecimator(taps: channelTaps, factor: 1)
        audioNCO.setFrequency(Self.centerHz, sampleRate: rate)
        resampler = FractionalResampler(inputRate: rate, outputRate: Self.outputRate)
        setDialOffset(dialOffsetHz)
    }

    /// Retunes the box by moving the NCO only; no filter or resampler state is touched.
    public func setDialOffset(_ hz: Double) {
        nco.setFrequency(-(hz + Self.centerHz), sampleRate: inputRate)
    }

    /// Appends 12 kHz audio for `iq` to `audio`.
    public func process(_ iq: UnsafeBufferPointer<DSPComplex>, audio: inout [Float]) {
        work.removeAll(keepingCapacity: true)
        work.append(contentsOf: iq)
        work.withUnsafeMutableBufferPointer { nco.mix($0) }
        for stage in stages {
            work2.removeAll(keepingCapacity: true)
            work.withUnsafeBufferPointer { stage.process($0, into: &work2) }
            swap(&work, &work2)
        }
        work2.removeAll(keepingCapacity: true)
        work.withUnsafeBufferPointer { channelFilter.process($0, into: &work2) }
        guard !work2.isEmpty else { return }
        realAudio.removeAll(keepingCapacity: true)
        work2.withUnsafeBufferPointer { audioNCO.mixReal($0, into: &realAudio) }
        realAudio.withUnsafeBufferPointer { resampler.process($0, into: &audio) }
    }
}
