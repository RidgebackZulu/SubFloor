import Accelerate
import DSPCore
import Foundation

/// A test signal: a family with exact parameters. The named modes of the spec are static members
/// (`SynthSpec.rtty(baud:shiftHz:)`, `.ft8()`, `.dmr` …, see Synth/NamedModes.swift), and
/// `SynthSpec.catalogue` lists one or more specs for every row of the spec's mode tables.
///
/// The signal is centred on its occupied band: `offsetHz` in `SignalSynth.make` is the centre of the band
/// (the carrier for AM, FM and carriers; the middle of the tones for FSK; the middle of the passband for SSB).
public enum SynthSpec: Sendable, Hashable {
    /// Noise only. `snrDb` is ignored; the noise has unit power over the whole sample rate.
    case noise
    /// Unmodulated carrier.
    case carrier
    /// Morse at `wpm` (PARIS timing, random text, 15 ms raised-cosine key edges, half a dot above 40 WPM).
    case cw(wpm: Double)
    /// Double-sideband AM with full carrier; `depth` is the peak modulation (0…1).
    case am(Audio, depth: Double)
    /// Single sideband (suppressed carrier) voice: speech-like noise between `lowHz` and `highHz` of audio.
    case ssb(upper: Bool, lowHz: Double, highHz: Double)
    /// FM of a carrier by `Audio` (peak-normalised to ±1), with peak deviation `deviationHz`.
    case fm(Audio, deviationHz: Double)
    /// Continuous-phase n-FSK (also MFSK, MSK, GFSK, GMSK, C4FM-like).
    case fsk(FSK)
    /// M-PSK with a pulse shape.
    case psk(PSK)
    /// OFDM with a cyclic prefix.
    case ofdm(OFDM)
    /// The inner signal keyed on and off on a fixed schedule (TDMA bursts, FT8/FT4/WSPR slots).
    indirect case bursts(SynthSpec, Bursts)

    /// What modulates an AM or FM carrier. Every kind is peak-normalised to ±1.
    public enum Audio: Sendable, Hashable {
        /// Speech-like noise: −6 dB tilt across `lowHz…highHz`, steep edges, a syllabic envelope with pauses,
        /// driven to an rms of 0.45 of the peak as a transmitter's clipper does (on FM, after 6 dB/octave
        /// pre-emphasis).
        case voice(lowHz: Double, highHz: Double)
        /// Steady programme (music-like noise, flat in `lowHz…highHz`, slowly varying level). With
        /// `pilotHz`, a pilot tone at 10% of the peak is added and the programme takes the other 90% (WFM).
        case program(lowHz: Double, highHz: Double, pilotHz: Double?)
        /// A steady tone.
        case tone(Double)
        /// An FSK tone stream in the audio (AFSK, MSK audio) centred on `centreHz`.
        case afsk(centreHz: Double, FSK)
        /// WWV-like second ticks: 5 ms of 1000 Hz each second at full level, and a 600 Hz tone at half
        /// level silenced from 10 ms before to 30 ms after each tick.
        case timeTicks
        /// NOAA APT-like: a 2400 Hz subcarrier amplitude-modulated by 2 image lines per second, each
        /// starting with a 1040 Hz sync burst.
        case aptVideo
        /// HF fax video (−1 black … +1 white) at `linesPerMinute`, each line opening with a white margin,
        /// image detail up to about 400 Hz. Used as `.fm(.faxVideo(…), deviationHz: 400)`: 1500–2300 Hz on
        /// an SSB receiver tuned 1900 Hz below the centre.
        case faxVideo(linesPerMinute: Double)

        /// The highest audio frequency the kind carries, for the occupied-bandwidth rules. For the time
        /// signal it is the 600 Hz tone and its keying (the 5 ms ticks reach further at a far lower average
        /// level); for fax video, where most of the image's energy lies (detail reaches 400 Hz, weaker).
        public var highestHz: Double {
            switch self {
            case .voice(_, let high): high
            case .program(_, let high, let pilot): max(high, pilot ?? 0)
            case .tone(let hz): hz
            case .afsk(let centre, let fsk): centre + fsk.nominalBandwidthHz / 2
            case .timeTicks: 750
            case .aptVideo: 3500
            case .faxVideo: 60
            }
        }
    }

    /// Continuous-phase FSK. Tone i (0…tones−1) sits at (i − (tones−1)/2) × `spacingHz` from the centre.
    public struct FSK: Sendable, Hashable {
        public var tones: Int
        /// Symbols per second.
        public var rate: Double
        /// Between adjacent tones: the shift, for 2-FSK.
        public var spacingHz: Double
        /// Gaussian frequency pulse with this bandwidth-time product (GFSK, GMSK); nil is rectangular.
        public var gaussianBT: Double?

        public init(tones: Int, rate: Double, spacingHz: Double, gaussianBT: Double? = nil) {
            precondition(tones >= 2 && rate > 0 && spacingHz > 0)
            self.tones = tones
            self.rate = rate
            self.spacingHz = spacingHz
            self.gaussianBT = gaussianBT
        }

        /// (tones − 1) × spacing plus k × rate: rectangular k = 2 (0.9 for MSK-like spacing ≤ rate / 2);
        /// Gaussian k = 0.75 with BT ≤ 0.5, 1.25 with a wider BT.
        public var nominalBandwidthHz: Double {
            let k: Double = gaussianBT.map { $0 <= 0.5 ? 0.75 : 1.25 } ?? (spacingHz <= rate / 2 ? 0.9 : 2)
            return Double(tones - 1) * spacingHz + k * rate
        }
    }

    /// M-PSK: random symbols on the points e^{j2πk/M}.
    public struct PSK: Sendable, Hashable {
        public enum Shape: Sendable, Hashable {
            /// Root-raised-cosine pulses (span ±8 symbols) with this roll-off.
            case rootRaisedCosine(rolloff: Double)
            /// PSK31-style: raised-cosine pulses two symbols long, so the amplitude dips through zero on a
            /// phase reversal and stays steady between equal symbols.
            case cosine
        }

        /// 2, 4 or 8.
        public var order: Int
        public var rate: Double
        public var shape: Shape

        public init(order: Int, rate: Double, shape: Shape = .rootRaisedCosine(rolloff: 0.35)) {
            precondition([2, 4, 8].contains(order) && rate > 0)
            self.order = order
            self.rate = rate
            self.shape = shape
        }

        /// rate × (1 + roll-off) for RRC; 1.6 × rate for the cosine pulse.
        public var nominalBandwidthHz: Double {
            switch shape {
            case .rootRaisedCosine(let a): rate * (1 + a)
            case .cosine: 1.6 * rate
            }
        }
    }

    /// OFDM: QPSK on every carrier, symbols of 1/spacing plus a cyclic prefix of `cpFraction` of that.
    /// An even carrier count leaves the centre (DC) carrier empty, as DAB does.
    public struct OFDM: Sendable, Hashable {
        public var carriers: Int
        public var spacingHz: Double
        public var cpFraction: Double

        public init(carriers: Int, spacingHz: Double, cpFraction: Double = 0.25) {
            precondition(carriers >= 2 && spacingHz > 0 && cpFraction >= 0 && cpFraction < 1)
            self.carriers = carriers
            self.spacingHz = spacingHz
            self.cpFraction = cpFraction
        }

        /// Carriers × spacing (one more spacing for the empty centre of an even count).
        public var nominalBandwidthHz: Double {
            Double(carriers + (carriers.isMultiple(of: 2) ? 1 : 0)) * spacingHz
        }
    }

    /// An on/off schedule. Time 0 of the schedule is the start of a period; the capture's first sample is at
    /// `captureStartSeconds` on that clock. Each transmission is a fresh stretch of the inner signal.
    public struct Bursts: Sendable, Hashable {
        public var periodSeconds: Double
        /// Where the transmission starts within each period.
        public var startSeconds: Double
        public var onSeconds: Double
        public var captureStartSeconds: Double
        /// Raised-cosine ramp at each end of a transmission.
        public var rampSeconds: Double

        public init(periodSeconds: Double, onSeconds: Double, startSeconds: Double = 0,
                    captureStartSeconds: Double = 0, rampSeconds: Double? = nil) {
            precondition(periodSeconds > 0 && onSeconds > 0 && onSeconds <= periodSeconds)
            self.periodSeconds = periodSeconds
            self.onSeconds = onSeconds
            self.startSeconds = startSeconds
            self.captureStartSeconds = captureStartSeconds
            self.rampSeconds = rampSeconds ?? min(0.001, onSeconds / 10)
        }

        /// On time over period.
        public var duty: Double { onSeconds / periodSeconds }
    }

    /// The width the parameters imply, from conventional rules. It sets working and analysis rates; the
    /// ground truth for the SNR is `occupiedBandwidthHz`, measured on a render.
    /// - noise: 0; carrier: 10 Hz;
    /// - CW: 5 × the keying rate in units/s (ITU necessary bandwidth, K = 5), 4.17 × WPM, at least 60 Hz;
    /// - AM: 2 × the highest audio frequency; SSB: `highHz − lowHz`;
    /// - FM: Carson, 2 × (deviation + highest audio frequency);
    /// - FSK, PSK, OFDM: see their `nominalBandwidthHz`; bursts: the inner signal's.
    public var nominalBandwidthHz: Double {
        switch self {
        case .noise: 0
        case .carrier: 10
        case .cw(let wpm): max(60, 5 * wpm / 1.2)
        case .am(let audio, _): 2 * audio.highestHz
        case .ssb(_, let low, let high): high - low
        case .fm(let audio, let deviation): 2 * (deviation + audio.highestHz)
        case .fsk(let f): f.nominalBandwidthHz
        case .psk(let p): p.nominalBandwidthHz
        case .ofdm(let o): o.nominalBandwidthHz
        case .bursts(let inner, _): inner.nominalBandwidthHz
        }
    }

    /// The occupied (−20 dB) bandwidth: the ground truth the synthesiser scales its noise to and the tests
    /// compare measurements with. Rendered once per spec and cached (see
    /// `SignalSynth.occupiedBandwidthHz(for:)`).
    public var occupiedBandwidthHz: Double { SignalSynth.occupiedBandwidthHz(for: self) }

    /// The lowest capture rate that holds the signal comfortably (1.25 × its occupied bandwidth).
    public var minimumSampleRate: Double { max(1.25 * occupiedBandwidthHz, 100) }
}

/// Slow channel effects applied to the signal (not the noise).
public struct SynthImpairments: Sendable, Equatable {
    /// Linear frequency drift, centred so the mean frequency is the requested offset.
    public var driftHzPerSecond: Double
    /// Peak-to-trough depth of a slow, smooth fade (0 = none).
    public var fadeDepthDb: Double
    /// Typical rate of the fade.
    public var fadeRateHz: Double

    public init(driftHzPerSecond: Double = 0, fadeDepthDb: Double = 0, fadeRateHz: Double = 0.2) {
        self.driftHzPerSecond = driftHzPerSecond
        self.fadeDepthDb = fadeDepthDb
        self.fadeRateHz = fadeRateHz
    }

    public static let none = SynthImpairments()
}

/// Deterministic test-signal generator for Signal ID's tests (and the app's).
///
/// The signal is built at complex baseband at a working rate of at least 8 × its nominal bandwidth (and
/// 4 kHz), faded and drifted, normalised to unit mean power over the capture, interpolated to `sampleRate`
/// (polyphase windowed sinc), mixed to `offsetHz`, and joined by complex white Gaussian noise whose power
/// within `spec.occupiedBandwidthHz` is the signal's mean power / 10^(snrDb/10). The mean power is over
/// the whole capture, off-times included, which is what an averaged spectrum measures. `sampleRate` should
/// be at least `spec.minimumSampleRate` (and hold `offsetHz` ± half the bandwidth); nothing stops aliasing.
///
/// Everything random comes from `seed` (SplitMix64): the signal's content from one stream and the noise
/// from another, so the same seed and sample rate at another SNR carry the same signal. `snrDb = .infinity`
/// adds no noise.
public enum SignalSynth {
    /// Interleaved IQ (I, Q, I, Q …), `seconds × sampleRate` complex samples.
    public static func make(_ spec: SynthSpec, sampleRate: Double, seconds: Double, snrDb: Double,
                            offsetHz: Double = 0, seed: UInt64, impairments: SynthImpairments = .none) -> [Float] {
        if case .noise = spec {
            var out = [Float](repeating: 0, count: 2 * max(0, Int((seconds * sampleRate).rounded())))
            var noiseRandom = SynthRandom(seed: seed, stream: 1)
            SynthNoise.add(to: &out, power: 1, random: &noiseRandom)
            return out
        }
        var out = render(spec, sampleRate: sampleRate, seconds: seconds, offsetHz: offsetHz, seed: seed,
                         impairments: impairments)
        if snrDb.isFinite && !out.isEmpty {
            var noiseRandom = SynthRandom(seed: seed, stream: 1)
            let power = pow(10, -snrDb / 10) * sampleRate / max(occupiedBandwidthHz(for: spec), 1e-9)
            SynthNoise.add(to: &out, power: power, random: &noiseRandom)
        }
        return out
    }

    /// The noise-free signal at unit mean power.
    static func render(_ spec: SynthSpec, sampleRate: Double, seconds: Double, offsetHz: Double = 0, seed: UInt64,
                       impairments: SynthImpairments = .none) -> [Float] {
        precondition(sampleRate > 0 && seconds >= 0)
        let n = Int((seconds * sampleRate).rounded())
        var out = [Float](repeating: 0, count: 2 * n)
        guard n > 0 else { return out }
        if case .noise = spec { return out }
        let excursion = abs(impairments.driftHzPerSecond) * seconds
        let workingMinimum = max(8 * (spec.nominalBandwidthHz + excursion), 4000)
        let factor = max(1, Int(sampleRate / workingMinimum))
        let rate = sampleRate / Double(factor)
        let used = (n + factor - 1) / factor
        var random = SynthRandom(seed: seed, stream: 0)
        var x = SynthModulators.baseband(spec, rate: rate, count: used + SynthDSP.interpolatorHalfSpan + 1,
                                         random: &random)
        SynthDSP.impair(&x, impairments, rate: rate, seconds: Double(used) / rate, random: &random)
        x.normalisePower(over: used)
        SynthDSP.interpolate(x, factor: factor, into: &out, count: n)
        if offsetHz != 0 { SynthDSP.mix(&out, frequency: offsetHz, sampleRate: sampleRate) }
        return out
    }
}
