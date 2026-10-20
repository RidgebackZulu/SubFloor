import Accelerate
import Foundation

/// IQ in, 12 kHz real USB audio out for one 3 kHz modem box (audio 300…3300 Hz above the dial).
/// Linear: there is deliberately no AGC, so levels stay valid for SNR estimates.
///
/// Thread contract: not thread-safe. `process` and `setDialOffset` mutate the same NCO state
/// (a multi-word phase step), so every call must come from the single thread that calls `process`
/// (the DSP thread). A write from another thread could tear the step and NaN-poison the NCO.
public final class ModemChannel: @unchecked Sendable {
    public static let outputRate = 12_000.0
    /// Audio centre of the 300…3300 Hz box.
    private static let centerHz = 1_800.0
    /// Low-pass cutoff of the complex channel filter (Hz, at the -6 dB point).
    private static let channelCutoffHz = 1_900.0
    /// Low-pass transition width (Hz). The response is flat to about +-1700 Hz and reaches
    /// roughly -57 dB by -2100 Hz, so audio from about 100 to 3500 Hz passes and the opposite
    /// sideband is rejected.
    private static let channelTransitionHz = 400.0

    public let inputRate: Double
    public private(set) var channelRate: Double = 0

    private var nco: NCO
    private var audioNCO: NCO
    private var stages: [ComplexDecimator]
    private var channelFilter: ComplexDecimator
    private var resampler: FractionalResampler
    private var work: [DSPComplex] = []
    private var work2: [DSPComplex] = []
    private var realAudio: [Float] = []

    /// `dialOffsetHz` is the box dial minus the capture centre.
    public init(inputRate: Double, dialOffsetHz: Double) {
        self.inputRate = inputRate

        var rate = inputRate
        stages = DecimationPlan.stages(inputRate: rate, minimumRate: Self.outputRate).map { f in
            let df = Double(f)
            rate /= df
            let taps = FIRDesign.lowpass(taps: FIRDesign.tapCount(transition: 0.38 / df, max: 255), cutoff: 0.45 / df)
            return ComplexDecimator(taps: taps, factor: f)
        }
        channelRate = rate
        let channelTaps = FIRDesign.lowpass(
            taps: FIRDesign.tapCount(transition: Self.channelTransitionHz / rate, max: 1023),
            cutoff: Self.channelCutoffHz / rate)
        channelFilter = ComplexDecimator(taps: channelTaps, factor: 1)
        audioNCO = NCO(frequency: Self.centerHz, sampleRate: rate)
        resampler = FractionalResampler(inputRate: rate, outputRate: Self.outputRate)
        nco = NCO()
        setDialOffset(dialOffsetHz)
    }

    /// Retunes the box by moving the NCO only; no filter or resampler state is touched.
    /// Must be called from the same thread as `process` (see the class thread contract).
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
