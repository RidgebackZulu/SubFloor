import Accelerate
import Foundation

/// One demodulated channel: NCO → decimating stages → channel filter → demod → audio filter → 48 kHz → AGC → squelch.
public final class Receiver: @unchecked Sendable {
    public struct Config: Equatable, Sendable {
        public var inputRate: Double
        public var offsetHz: Double
        public var mode: DemodMode
        public var bandwidthHz: Double
        public var cwPitchHz: Double
        public var squelchDb: Float?
        public var agc: AGCSpeed

        public init(inputRate: Double, offsetHz: Double, mode: DemodMode, bandwidthHz: Double,
                    cwPitchHz: Double = 700, squelchDb: Float? = nil, agc: AGCSpeed = .medium) {
            self.inputRate = inputRate
            self.offsetHz = offsetHz
            self.mode = mode
            self.bandwidthHz = bandwidthHz
            self.cwPitchHz = cwPitchHz
            self.squelchDb = squelchDb
            self.agc = agc
        }
    }

    public static let audioRate = 48_000.0

    /// Squelch timing. The level is the channel power over the last `levelSeconds` (one block is
    /// too few samples: on noise it jitters by more than the hysteresis, and the gate chatters);
    /// the gate stays open `hangSeconds` after the level falls below the threshold, and its gain
    /// ramps over `fadeSeconds` rather than stepping.
    static let squelchLevelSeconds = 0.03
    static let squelchHangSeconds = 0.15
    static let squelchFadeSeconds = 0.005
    static let squelchHysteresisDb: Float = 2

    public private(set) var config: Config
    public private(set) var channelRate: Double = 0
    /// Channel power in dBFS over the last `squelchLevelSeconds`.
    public private(set) var signalDb: Float = -200
    /// Whether the squelch gate is open after the last block: true when no squelch is set. The audio
    /// of that block was gated by it.
    public var isSquelchOpen: Bool { squelchOpen }
    /// The last block's audio as it was before the squelch gate: what an auto recording keeps through
    /// the short gaps between words. Reused from block to block, so it allocates nothing once warm.
    public private(set) var ungatedAudio: [Float] = []

    private var nco = NCO()
    private var stages: [ComplexDecimator] = []
    private var channelFilter = ComplexDecimator(taps: [1], factor: 1)
    private var demod: any Demodulator = AMDemodulator()
    private var audioFilter = FIRDecimator(taps: [1], factor: 1)
    private var resampler = LinearResampler(inputRate: 48_000, outputRate: 48_000)
    private var agc = AGC(speed: .medium, sampleRate: 48_000)
    private var squelchOpen = false       // starts shut: audio fades in from the first block
    private var squelchHang = 0.0         // seconds left before an open gate may close
    private var squelchGain: Float = 0    // ramps towards 1 (open) or 0 (shut)
    private var level = MovingPower(window: 1)
    private var work: [DSPComplex] = []
    private var work2: [DSPComplex] = []
    private var demodOut: [Float] = []
    private var filtered: [Float] = []

    public init(config: Config) {
        self.config = config
        rebuild()
    }

    public func update(_ new: Config) {
        let rebuildNeeded = new.inputRate != config.inputRate || new.mode != config.mode
            || new.bandwidthHz != config.bandwidthHz || new.cwPitchHz != config.cwPitchHz
        config = new
        if rebuildNeeded {
            rebuild()
        } else {
            retune()
            agc.speed = new.agc
        }
    }

    private func retune() {
        let shift = config.offsetHz + config.mode.passbandOffset(bandwidth: config.bandwidthHz)
        nco.setFrequency(-shift, sampleRate: config.inputRate)
    }

    private func rebuild() {
        let mode = config.mode
        let bw = config.bandwidthHz
        let minimumRate = max(mode.minimumChannelRate, bw * (mode == .wfm ? 1.25 : 3))
        var rate = config.inputRate
        stages = DecimationPlan.stages(inputRate: rate, minimumRate: minimumRate).map { f in
            let df = Double(f)
            rate /= df
            let taps = FIRDesign.lowpass(taps: FIRDesign.tapCount(transition: 0.38 / df, max: 255), cutoff: 0.45 / df)
            return ComplexDecimator(taps: taps, factor: f)
        }
        channelRate = rate

        let half = bw / 2
        let channelTaps = FIRDesign.lowpass(
            taps: FIRDesign.tapCount(transition: max(half * 0.25, 200) / rate, max: 511),
            cutoff: half / rate)
        channelFilter = ComplexDecimator(taps: channelTaps, factor: 1)

        var audioCutoff: Double
        switch mode {
        case .am:
            demod = AMDemodulator()
            audioCutoff = half
        case .nfm:
            demod = FMDemodulator(sampleRate: rate, deviation: 5_000, deemphasisTau: nil)
            audioCutoff = 4_000
        case .wfm:
            demod = FMDemodulator(sampleRate: rate, deviation: 75_000, deemphasisTau: 75e-6)
            audioCutoff = 15_000
        case .usb, .lsb:
            let shift = mode.passbandOffset(bandwidth: bw)
            demod = SSBDemodulator(sampleRate: rate, shiftHz: shift)
            audioCutoff = abs(shift) + half
        case .cw:
            demod = SSBDemodulator(sampleRate: rate, shiftHz: config.cwPitchHz)
            audioCutoff = config.cwPitchHz + half
        }
        audioCutoff = min(audioCutoff, 20_000)
        let audioFactor = max(1, Int(rate / Self.audioRate))
        let audioTaps = FIRDesign.lowpass(
            taps: max(FIRDesign.tapCount(transition: max(500, audioCutoff * 0.2) / rate, max: 511), audioFactor | 1),
            cutoff: audioCutoff / rate)
        audioFilter = FIRDecimator(taps: audioTaps, factor: audioFactor)
        resampler = LinearResampler(inputRate: rate / Double(audioFactor), outputRate: Self.audioRate)
        agc.reconfigure(speed: config.agc, sampleRate: Self.audioRate)   // keeps the envelope: no pop on rebuild
        level = MovingPower(window: Int(rate * Self.squelchLevelSeconds))   // the gate keeps its state
        retune()
    }

    public func process(_ input: UnsafeBufferPointer<DSPComplex>, audio: inout [Float]) {
        work.removeAll(keepingCapacity: true)
        work.append(contentsOf: input)
        work.withUnsafeMutableBufferPointer { nco.mix($0) }
        for stage in stages {
            work2.removeAll(keepingCapacity: true)
            work.withUnsafeBufferPointer { stage.process($0, into: &work2) }
            swap(&work, &work2)
        }
        work2.removeAll(keepingCapacity: true)
        work.withUnsafeBufferPointer { channelFilter.process($0, into: &work2) }
        guard !work2.isEmpty else { return }

        let seconds = Double(input.count) / config.inputRate
        work2.withUnsafeBufferPointer { level.add($0) }
        signalDb = 10 * log10(max(level.mean, 1e-20))
        if let threshold = config.squelchDb {
            if signalDb > threshold || (squelchOpen && signalDb > threshold - Self.squelchHysteresisDb) {
                squelchOpen = true
                squelchHang = Self.squelchHangSeconds
            } else if squelchOpen {
                squelchHang -= seconds
                if squelchHang <= 0 { squelchOpen = false }
            }
        } else {
            squelchOpen = true
            squelchHang = 0
        }

        demodOut.removeAll(keepingCapacity: true)
        work2.withUnsafeBufferPointer { demod.demodulate($0, into: &demodOut) }
        filtered.removeAll(keepingCapacity: true)
        demodOut.withUnsafeBufferPointer { audioFilter.process($0, into: &filtered) }
        let start = audio.count
        filtered.withUnsafeBufferPointer { resampler.process($0, into: &audio) }
        agc.process(&audio, from: start)
        ungatedAudio.removeAll(keepingCapacity: true)
        ungatedAudio.append(contentsOf: audio[start...])
        applySquelchGain(&audio, from: start)
    }

    /// Ramps the gate gain towards open or shut, sample by sample, so the gate never steps.
    private func applySquelchGain(_ audio: inout [Float], from start: Int) {
        let target: Float = squelchOpen ? 1 : 0
        let step = Float(1 / (Self.squelchFadeSeconds * Self.audioRate))
        var gain = squelchGain
        if gain == 1, target == 1 { return }
        for k in start..<audio.count {
            if gain != target { gain = target > gain ? min(target, gain + step) : max(target, gain - step) }
            audio[k] *= gain
        }
        squelchGain = gain
    }
}
