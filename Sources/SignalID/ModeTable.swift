import Foundation

/// One row of the spec's mode tables ("Modes it names") as data: the families it is measured as, the parameter
/// sets it may have, and its frequency hints in display Hz.
///
/// A row's parameter score (`ModeTable.score`) is the weighted mean of its features' matches, each from −1 (a
/// mismatch) to +1, the family counting with weight 2; a row with several variants (FT8 and FT4, NXDN's two
/// speeds) takes its best. Hints never name a signal on their own: `SignalIdentifier` adds them afterwards.
public struct ModeRow: Sendable {
    public let name: String
    /// The families it is measured as.
    let families: Set<SignalFamily>
    /// Families that neither confirm nor rule it out, and the match they count as (HF fax measured `unknown`:
    /// a constant envelope with discrete frequencies, as its black and white levels make it).
    let partialFamilies: [SignalFamily: Double]
    /// Its parameter sets; any one may fit.
    let variants: [[ModeFeature]]
    let hints: [ModeHint]
    /// Slots, fax lines or ticks: a candidate asks for the longer read (the spec's slow-signal rule).
    let needsTiming: Bool
    /// Transmits in slots with silence between (FT8, FT4): the longer read measures one transmission.
    let slotted: Bool
    /// Its longest transmission (FT8's 79 symbols, 12.64 s): a shorter read can't show all of one.
    let slotSeconds: Double
    /// How its FSK is keyed by its standard (WSPR and MFSK16 rectangular, FT8/FT4 and Olivia Gaussian): when
    /// named, its width comes from its parameters where the edges sit under the noise (`ParameterWidth`, R16).
    let shaping: ParameterWidth.Shaping?

    init(_ name: String, _ families: Set<SignalFamily>, partial: [SignalFamily: Double] = [:],
         _ variants: [[ModeFeature]], hints: [ModeHint] = [], needsTiming: Bool = false, slotted: Bool = false,
         slotSeconds: Double = 0, shaping: ParameterWidth.Shaping? = nil) {
        self.name = name
        self.families = families
        self.partialFamilies = partial
        self.variants = variants
        self.hints = hints
        self.needsTiming = needsTiming
        self.slotted = slotted
        self.slotSeconds = slotSeconds
        self.shaping = shaping
    }

    /// Each variant's width from its parameters, (n − 1) × spacing + 2 × rate (a slotted row's: its transmissions').
    var slotWidthsHz: [Double] {
        variants.compactMap { features in
            var n: Int?, rate: Double?, spacing: Double?
            for f in features {
                switch f.kind {
                case .toneCount(let v): n = v.first
                case .symbolRate(let v, _): rate = v.first
                case .spacing(let v, _): spacing = v.first
                default: break
                }
            }
            guard let n, let rate, let spacing else { return nil }
            return Double(n - 1) * spacing + 2 * rate
        }
    }

    /// Whether `rfHz` lies in any of the row's hint ranges.
    func hinted(_ rfHz: Double) -> Bool { hints.contains { $0.contains(rfHz) } }
}

/// A parameter or feature a row looks for, with its weight in the row's score.
struct ModeFeature: Sendable {
    enum Kind: Sendable {
        /// The measured value within `tolerance` (relative) of one of these: +1; at twice the tolerance or more
        /// away: −1; linear between. A missing value: −0.5.
        case symbolRate([Double], tolerance: Double)
        case shift([Double], tolerance: Double)
        case spacing([Double], tolerance: Double)
        case ofdmSpacing([Double], tolerance: Double)
        /// Exactly one of these.
        case toneCount([Int])
        case pskOrder([Int])
        /// Inside the range: +1; `softness` (relative) outside it or more: −1; linear between.
        case bandwidth(ClosedRange<Double>, softness: Double)
        case deviation(ClosedRange<Double>, softness: Double)
        case wpm(ClosedRange<Double>, softness: Double)
        case envelope([EnvelopeKind])
        /// An FM signal's demodulated audio: speech (`voice`) or steady.
        case audio(EnvelopeKind)
        /// Not in bursts.
        case continuous
        /// Bursts at this period and duty: +1; continuous: 0 (a repeater sends both slots); other bursts: −1.
        case bursts(period: ClosedRange<Double>, duty: ClosedRange<Double>)
        /// Subcarriers at these frequencies, each within `tolerance` (relative); none, or another count: −1.
        case subcarriers([Double], tolerance: Double)
        case noSubcarrier
        /// A pilot among the subcarriers: +1; none: 0 (mono).
        case pilot(Double)
        /// A period in the demodulated signal (`modulationPeriodSeconds`). Before a long enough read has
        /// looked for it, it neither counts for nor against (0); a long read without it: −1.
        case period([Double], tolerance: Double)
        /// No period in the demodulated signal (a time signal's ticks are another row's).
        case noPeriod
        /// Inside these display-Hz ranges: +1; outside: −1. Not a hint: it rules a variant out (a steady AM
        /// outside the broadcast bands isn't broadcast) but never adds to a match that has nothing else.
        case inside([ClosedRange<Double>])
        /// Tone spacing equal to the symbol rate within 5% (Olivia's tones are one symbol rate apart).
        case spacingIsRate
        /// Olivia's tone counts and widths (tones × spacing), without MFSK16's 16 tones in 250 Hz, which it
        /// can't be told from: that is named MFSK16, the commoner.
        case oliviaConfiguration
    }

    let kind: Kind
    let weight: Double

    init(_ kind: Kind, weight: Double = 1) {
        self.kind = kind
        self.weight = weight
    }
}

/// A frequency hint: inside any of `ranges` (display Hz) a match gains `inside`; a row may also lose `outside`
/// when the signal lies outside every one (modes that live only there). With `families`, it applies only to a
/// signal measured as one of them (LSB below 10 MHz, USB above).
struct ModeHint: Sendable {
    let name: String
    let ranges: [ClosedRange<Double>]
    let families: Set<SignalFamily>?
    let inside: Double
    let outside: Double

    init(_ name: String, _ ranges: [ClosedRange<Double>], families: Set<SignalFamily>? = nil, inside: Double = 0.15,
         outside: Double = 0) {
        self.name = name
        self.ranges = ranges
        self.families = families
        self.inside = inside
        self.outside = outside
    }

    func contains(_ hz: Double) -> Bool { ranges.contains { $0.contains(hz) } }
}

/// The spec's mode tables. Frequencies are display Hz; parameter ranges follow the published parameters with room
/// for what the measurer is known to read (NXDN 2400's spacing 5–10% low at 10 dB, DMR's duty 0.435 for 0.458 from
/// its ramps, C4FM and GMSK spacing from equiprobable symbols, CW's −20 dB width narrowed under the noise).
public enum ModeTable {
    static func mhz(_ low: Double, _ high: Double) -> ClosedRange<Double> { (low * 1e6)...(high * 1e6) }
    static func khz(_ centre: Double, _ halfWidth: Double) -> ClosedRange<Double> {
        ((centre - halfWidth) * 1e3)...((centre + halfWidth) * 1e3)
    }
    /// From each dial frequency (MHz) to `low…high` Hz above it (USB audio).
    static func dials(_ mhz: [Double], _ low: Double, _ high: Double) -> [ClosedRange<Double>] {
        mhz.map { ($0 * 1e6 + low)...($0 * 1e6 + high) }
    }

    // MARK: Band plans

    static let amateurBelow10MHz = [mhz(1.8, 2.0), mhz(3.5, 4.0), mhz(5.3305, 5.4065), mhz(7.0, 7.3)]
    static let amateurAbove10MHz = [mhz(14.0, 14.35), mhz(18.068, 18.168), mhz(21.0, 21.45), mhz(24.89, 24.99),
                                    mhz(28.0, 29.7), mhz(50.0, 54.0)]
    /// LW, MW and the HF broadcast bands.
    static let broadcast = [mhz(0.1485, 0.2835), mhz(0.5265, 1.7055), mhz(2.3, 2.495), mhz(3.2, 3.4), mhz(3.9, 4.0),
                            mhz(4.75, 5.06), mhz(5.9, 6.2), mhz(7.2, 7.45), mhz(9.4, 9.9), mhz(11.6, 12.1),
                            mhz(13.57, 13.87), mhz(15.1, 15.8), mhz(17.48, 17.9), mhz(18.9, 19.02),
                            mhz(21.45, 21.85), mhz(25.67, 26.1)]
    static let cwSubBands = [mhz(1.8, 1.84), mhz(3.5, 3.57), mhz(7.0, 7.04), mhz(10.1, 10.13), mhz(14.0, 14.07),
                             mhz(18.068, 18.095), mhz(21.0, 21.07), mhz(24.89, 24.915), mhz(28.0, 28.07),
                             mhz(50.0, 50.1)]
    static let rttySegments = [mhz(3.58, 3.6), mhz(7.04, 7.05), mhz(7.08, 7.1), mhz(10.14, 10.15), mhz(14.08, 14.099),
                               mhz(18.1, 18.11), mhz(21.08, 21.11), mhz(24.92, 24.93), mhz(28.08, 28.15)]
    static let pskSegments = [mhz(3.58, 3.59), mhz(7.035, 7.045), mhz(7.07, 7.08), mhz(10.14, 10.15),
                              mhz(14.07, 14.074), mhz(18.1, 18.106), mhz(21.07, 21.074), mhz(24.92, 24.925),
                              mhz(28.12, 28.125)]
    static let navtex = [khz(490, 1), khz(518, 1), khz(4209.5, 1)]
    static let ft8Dials = [1.84, 3.573, 5.357, 7.074, 10.136, 14.074, 18.1, 21.074, 24.915, 28.074, 50.313, 144.174]
    static let ft4Dials = [3.5755, 7.0475, 10.14, 14.08, 18.104, 21.14, 24.919, 28.18, 50.318]
    static let wsprDials = [0.1375, 0.4742, 1.8366, 3.5686, 5.2872, 7.0386, 10.1387, 14.0956, 18.1046, 21.0946,
                            24.9246, 28.1246, 50.293, 144.489]
    /// HF fax stations' assigned frequencies (kHz), from 1 kHz below to 2.5 kHz above (centre or USB dial
    /// conventions both fall inside).
    static let fax = [2618.5, 3855, 4235, 4298, 4317.9, 4346, 4610, 6340.5, 6453, 7880, 8040, 8459, 8503.9, 8682, 9110,
                      9982.5, 10536, 11090, 12390, 12412.5, 12750, 12786, 12789.9, 13882.5, 16135, 17146.4, 17151.2,
                      22527].map { ($0 - 1) * 1e3...($0 + 2.5) * 1e3 }
    /// WWV/WWVH, CHU, and BPM and RWM on neighbouring frequencies.
    static let timeSignals = [2500.0, 3330, 4996, 5000, 7850, 9996, 10_000, 14_670, 14_996, 15_000, 20_000, 25_000]
        .map { khz($0, 5) }

    // MARK: Rows

    static func rate(_ values: [Double], _ tolerance: Double = 0.02, weight: Double = 2) -> ModeFeature {
        ModeFeature(.symbolRate(values, tolerance: tolerance), weight: weight)
    }
    static func tones(_ values: [Int], weight: Double = 1) -> ModeFeature { ModeFeature(.toneCount(values), weight: weight) }
    static func width(_ range: ClosedRange<Double>, softness: Double = 0.25, weight: Double = 1) -> ModeFeature {
        ModeFeature(.bandwidth(range, softness: softness), weight: weight)
    }

    /// Every row of the spec's two tables, in the spec's order.
    public static let rows: [ModeRow] = [
        // HF
        ModeRow("SSB voice (USB/LSB)", [.usb, .lsb], [[width(1800...3600), ModeFeature(.envelope([.voice]))]],
                hints: [ModeHint("amateur LSB below 10 MHz", amateurBelow10MHz, families: [.lsb], inside: 0.1),
                        ModeHint("amateur USB above 10 MHz", amateurAbove10MHz, families: [.usb], inside: 0.1)]),
        // Voice anywhere; a steady programme only in the broadcast bands (a steady AM elsewhere is data or a
        // time signal, not broadcast).
        ModeRow("AM voice/broadcast", [.am],
                [[width(3000...12_000, weight: 2), ModeFeature(.noSubcarrier), ModeFeature(.noPeriod),
                  ModeFeature(.envelope([.voice]), weight: 2)],
                 [width(3000...12_000, weight: 2), ModeFeature(.noSubcarrier), ModeFeature(.noPeriod),
                  ModeFeature(.envelope([.steady])), ModeFeature(.inside(broadcast), weight: 3)]],
                hints: [ModeHint("broadcast band", broadcast)]),
        ModeRow("CW", [.ook], [[ModeFeature(.wpm(5...50, softness: 0.3)), width(20...300, softness: 0.5)]],
                hints: [ModeHint("CW sub-band", cwSubBands, inside: 0.1)]),
        ModeRow("RTTY", [.fsk], [[tones([2]), rate([45.45, 50, 75]), ModeFeature(.shift([170, 425, 850], tolerance: 0.04),
                                                                                  weight: 2)]],
                hints: [ModeHint("amateur RTTY segment", rttySegments, inside: 0.1)]),
        ModeRow("NAVTEX / SITOR-B", [.fsk], [[tones([2]), rate([100]), ModeFeature(.shift([170], tolerance: 0.04),
                                                                                    weight: 2)]],
                hints: [ModeHint("NAVTEX frequency", navtex)]),
        ModeRow("PSK31 / PSK63", [.psk], [[ModeFeature(.pskOrder([2, 4])), rate([31.25, 62.5]), width(25...160)]],
                hints: [ModeHint("digital sub-band", pskSegments, inside: 0.1)]),
        ModeRow("FT8 / FT4", [.fsk],
                [[tones([8]), rate([6.25], 0.03), ModeFeature(.spacing([6.25], tolerance: 0.05))],
                 [tones([4]), rate([12_000 / 576], 0.03), ModeFeature(.spacing([12_000 / 576], tolerance: 0.05))]],
                hints: [ModeHint("FT8/FT4 frequency", dials(ft8Dials, 0, 3200) + dials(ft4Dials, 0, 3200),
                                 outside: 0.05)],
                needsTiming: true, slotted: true, slotSeconds: 79 / 6.25, shaping: .gaussian([8: 2, 4: 1])),
        ModeRow("WSPR", [.fsk],
                [[tones([4]), rate([12_000 / 8192], 0.03), ModeFeature(.spacing([12_000 / 8192], tolerance: 0.06)),
                  width(3...15, softness: 0.5)]],
                hints: [ModeHint("WSPR frequency", dials(wsprDials, 1350, 1650), outside: 0.1)], needsTiming: true,
                shaping: .rectangular),
        ModeRow("Olivia", [.fsk, .mfsk],
                [[tones([4, 8, 16, 32, 64]), ModeFeature(.spacingIsRate), ModeFeature(.oliviaConfiguration, weight: 2)]],
                shaping: .gaussian([0: 1])),
        ModeRow("MFSK16", [.mfsk, .fsk],
                [[tones([16]), rate([15.625]), ModeFeature(.spacing([15.625], tolerance: 0.04))]],
                shaping: .rectangular),
        ModeRow("ALE (MIL-STD-188-141)", [.fsk],
                [[tones([8]), rate([125]), ModeFeature(.spacing([250], tolerance: 0.04))]]),
        ModeRow("STANAG 4285", [.psk], [[ModeFeature(.pskOrder([8])), rate([2400]), width(2200...3400)]]),
        ModeRow("HF fax", [.fm], partial: [.unknown: 0.5],
                [[width(700...1300), ModeFeature(.envelope([.steady]), weight: 0.5),
                  ModeFeature(.period([0.25, 0.5, 60 / 90.0, 1], tolerance: 0.02), weight: 3)]],
                hints: [ModeHint("fax frequency", fax, inside: 0.1)], needsTiming: true),
        ModeRow("DRM", [.ofdm],
                [[ModeFeature(.ofdmSpacing([1000 / 24.0, 46.875, 750 / 11.0, 750 / 7.0], tolerance: 0.02), weight: 2),
                  width(4500...20_000)]],
                hints: [ModeHint("broadcast band", broadcast, inside: 0.1)]),
        ModeRow("HFDL", [.psk], [[ModeFeature(.pskOrder([2, 4, 8]), weight: 0.5), rate([1800]), width(1800...3000)]]),
        ModeRow("Time signal (WWV/WWVH/CHU)", [.am],
                [[ModeFeature(.period([1], tolerance: 0.02), weight: 3), width(500...12_000, weight: 0.5)]],
                hints: [ModeHint("time signal frequency", timeSignals)], needsTiming: true),

        // VHF and above
        ModeRow("NFM voice", [.fm],
                [[ModeFeature(.audio(.voice), weight: 2), ModeFeature(.deviation(1500...6500, softness: 0.3)),
                  width(4000...18_000), ModeFeature(.noSubcarrier)]]),
        ModeRow("WFM broadcast", [.wfm],
                [[width(100_000...300_000), ModeFeature(.pilot(19_000)),
                  ModeFeature(.deviation(40_000...110_000, softness: 0.3), weight: 0.5)]],
                hints: [ModeHint("FM broadcast band", [mhz(87.5, 108)])]),
        ModeRow("AM airband", [.am],
                [[width(3000...12_000, weight: 2), ModeFeature(.noSubcarrier), ModeFeature(.noPeriod),
                  ModeFeature(.envelope([.voice]), weight: 2)]],
                hints: [ModeHint("airband", [mhz(118, 137)], outside: 0.15)]),
        ModeRow("APRS / AX.25", [.fm],
                [[ModeFeature(.subcarriers([1200, 2200], tolerance: 0.04), weight: 2), rate([1200])]],
                hints: [ModeHint("APRS frequency", [khz(144_390, 10), khz(144_800, 10)], inside: 0.1)]),
        ModeRow("POCSAG", [.fsk],
                [[tones([2]), rate([512, 1200, 2400]), ModeFeature(.shift([9000], tolerance: 0.1), weight: 2)]]),
        ModeRow("DMR", [.fsk],
                [[tones([4]), rate([4800], weight: 1), ModeFeature(.spacing([1296], tolerance: 0.025), weight: 2),
                  ModeFeature(.bursts(period: 0.055...0.065, duty: 0.3...0.6))]]),
        ModeRow("P25 Phase 1", [.fsk],
                [[tones([4]), rate([4800], weight: 1), ModeFeature(.spacing([1200], tolerance: 0.025), weight: 2),
                  ModeFeature(.continuous)]]),
        ModeRow("NXDN", [.fsk],
                [[tones([4]), rate([2400], weight: 1), ModeFeature(.spacing([700], tolerance: 0.12), weight: 2)],
                 [tones([4]), rate([4800], weight: 1), ModeFeature(.spacing([1600], tolerance: 0.025), weight: 2)]]),
        ModeRow("D-STAR", [.fsk], [[tones([2]), rate([4800]), ModeFeature(.shift([2400], tolerance: 0.08))]]),
        ModeRow("YSF (C4FM)", [.fsk],
                [[tones([4]), rate([4800], weight: 1), ModeFeature(.spacing([1800], tolerance: 0.025), weight: 2)]]),
        ModeRow("AIS", [.fsk], [[tones([2]), rate([9600]), ModeFeature(.shift([4800], tolerance: 0.08))]],
                hints: [ModeHint("AIS channel", [khz(161_975, 12.5), khz(162_025, 12.5)], outside: 0.15)]),
        ModeRow("ACARS", [.am],
                [[ModeFeature(.subcarriers([1200, 2400], tolerance: 0.04), weight: 2), rate([2400])]],
                hints: [ModeHint("ACARS band", [mhz(129, 137)], inside: 0.1)]),
        ModeRow("NOAA APT", [.fm],
                [[ModeFeature(.subcarriers([2400], tolerance: 0.02), weight: 2), width(20_000...50_000)]],
                hints: [ModeHint("NOAA APT band", [mhz(137.1, 137.9)], outside: 0.1)]),
        ModeRow("DAB", [.ofdm],
                [[ModeFeature(.ofdmSpacing([1000, 2000, 4000, 8000], tolerance: 0.02), weight: 2),
                  width(1_300_000...1_700_000)]],
                hints: [ModeHint("DAB band", [mhz(174, 240)], outside: 0.1)]),
    ]

    /// The row named `name`.
    public static func row(_ name: String) -> ModeRow? { rows.first { $0.name == name } }

    // MARK: Scoring

    /// The row's parameter score (−1…1, before hints) for `m` at `rfHz`, and the evidence for it. Nil when the
    /// family rules it out.
    static func score(_ row: ModeRow, _ m: SignalMeasurement, rfHz: Double) -> (score: Double, evidence: [String])? {
        let family: Double
        if row.families.contains(m.family) {
            family = 1
        } else if let partial = row.partialFamilies[m.family] {
            family = partial
        } else {
            return nil
        }
        var best: (score: Double, evidence: [String])?
        for variant in row.variants {
            var sum = 2 * family, weights = 2.0
            var evidence = [String(format: "%@ %@", familyName(m), family == 1 ? "fits" : "may fit")]
            for feature in variant {
                let (match, text) = evaluate(feature.kind, m, rfHz: rfHz)
                sum += feature.weight * match
                weights += feature.weight
                if let text { evidence.append(text) }
            }
            let score = sum / weights
            if score > (best?.score ?? -.infinity) { best = (score, evidence) }
        }
        return best
    }

    /// −1…1 for one feature, and a line of evidence.
    static func evaluate(_ kind: ModeFeature.Kind, _ m: SignalMeasurement, rfHz: Double) -> (Double, String?) {
        switch kind {
        case .symbolRate(let values, let tolerance):
            return numeric(m.symbolRate, values, tolerance, "rate", unit: "Bd")
        case .shift(let values, let tolerance):
            return numeric(m.fskShiftHz, values, tolerance, "shift", unit: "Hz")
        case .spacing(let values, let tolerance):
            return numeric(m.toneSpacingHz, values, tolerance, "tone spacing", unit: "Hz")
        case .ofdmSpacing(let values, let tolerance):
            return numeric(m.ofdmSpacingHz, values, tolerance, "carrier spacing", unit: "Hz")
        case .toneCount(let values):
            guard let n = m.toneCount else { return (-0.5, "tone count not measured") }
            return values.contains(n) ? (1, "\(n) tones") : (-1, "\(n) tones, not \(list(values.map(Double.init)))")
        case .pskOrder(let values):
            guard let n = m.pskOrder else { return (-0.5, "PSK order not measured") }
            return values.contains(n) ? (1, "\(n)-PSK") : (-1, "\(n)-PSK, not \(list(values.map(Double.init)))")
        case .bandwidth(let range, let softness):
            return ranged(m.occupiedBandwidthHz, range, softness, "\(SignalIdentity.hz(m.occupiedBandwidthHz)) wide",
                          expected: "\(SignalIdentity.hz(range.lowerBound))–\(SignalIdentity.hz(range.upperBound))")
        case .deviation(let range, let softness):
            guard let deviation = m.fmDeviationHz else { return (-0.5, "deviation not measured") }
            return ranged(deviation, range, softness, "±\(SignalIdentity.hz(deviation)) deviation",
                          expected: "±\(SignalIdentity.hz(range.lowerBound))–\(SignalIdentity.hz(range.upperBound))")
        case .wpm(let range, let softness):
            guard let wpm = m.cwWPM else { return (-0.5, "keying not Morse") }
            return ranged(wpm, range, softness, String(format: "%.0f WPM", wpm),
                          expected: String(format: "%.0f–%.0f WPM", range.lowerBound, range.upperBound))
        case .envelope(let kinds):
            return kinds.contains(m.envelope) ? (1, "\(m.envelope.rawValue) envelope")
                : (-1, "\(m.envelope.rawValue) envelope, not \(kinds.map(\.rawValue).joined(separator: "/"))")
        case .audio(let kind):
            guard let audio = m.audioEnvelope else { return (-0.5, "audio not measured") }
            return audio == kind ? (1, "\(audio.rawValue) audio") : (-1, "\(audio.rawValue) audio, not \(kind.rawValue)")
        case .continuous:
            return m.envelope == .bursty ? (-1, "in bursts, not continuous") : (1, "continuous")
        case .bursts(let period, let duty):
            guard m.envelope == .bursty, let p = m.burstPeriodSeconds else { return (0, "continuous (both slots?)") }
            let fits = period.contains(p) && duty.contains(m.burstDuty ?? 0)
            return (fits ? 1 : -1, String(format: "bursts every %.0f ms, %.0f%% on", 1000 * p, 100 * (m.burstDuty ?? 0)))
        case .subcarriers(let tones, let tolerance):
            let found = m.subcarriersHz.filter { abs($0 - 19_000) > 200 }
            guard found.count == tones.count else {
                return (-1, found.isEmpty ? "no subcarrier" : "subcarriers \(list(found)) Hz, not \(list(tones))")
            }
            let worst = zip(found.sorted(), tones.sorted()).map { graded(abs($0 / $1 - 1), tolerance) }.min() ?? -1
            return (worst, "subcarrier \(list(found)) Hz" + (worst > 0 ? "" : ", not \(list(tones))"))
        case .noSubcarrier:
            let found = m.subcarriersHz.filter { abs($0 - 19_000) > 200 }
            return found.isEmpty ? (1, nil) : (-1, "carries a subcarrier (\(list(found)) Hz): data")
        case .pilot(let hz):
            return m.subcarriersHz.contains { abs($0 - hz) <= 200 } ? (1, String(format: "%.0f Hz pilot", hz)) : (0, "no pilot (mono?)")
        case .period(let values, let tolerance):
            guard let p = m.modulationPeriodSeconds else {
                return m.seconds >= ModulationPeriod.minSeconds ? (-1, "no repeating structure in the longer read")
                    : (0, "timing needs a longer read")
            }
            let (match, _) = numeric(p, values, tolerance, "period", unit: "s")
            return (match, String(format: "repeats every %.3f s", p))
        case .noPeriod:
            return m.modulationPeriodSeconds == nil ? (1, nil)
                : (-1, String(format: "repeats every %.2f s", m.modulationPeriodSeconds!))
        case .inside(let ranges):
            return ranges.contains { $0.contains(rfHz) } ? (1, nil) : (-1, "outside the bands it lives in")
        case .spacingIsRate:
            guard let rate = m.symbolRate, let spacing = m.toneSpacingHz else { return (-0.5, nil) }
            return (graded(abs(spacing / rate - 1), 0.05), nil)
        case .oliviaConfiguration:
            guard let n = m.toneCount, let spacing = m.toneSpacingHz else { return (-0.5, nil) }
            let span = Double(n) * spacing
            let widths = [125.0, 250, 500, 1000, 2000]
            let error = widths.map { abs(span / $0 - 1) }.min()!
            if n == 16 && abs(span / 250 - 1) <= 0.08 { return (-1, "16 tones in 250 Hz: MFSK16's shape") }
            return (graded(error, 0.06), String(format: "%d tones across %.0f Hz", n, span))
        }
    }

    /// +1 within `tolerance`, −1 at twice it or beyond, linear between.
    static func graded(_ error: Double, _ tolerance: Double) -> Double {
        error <= tolerance ? 1 : error >= 2 * tolerance ? -1 : 1 - 2 * (error - tolerance) / tolerance
    }

    static func numeric(_ value: Double?, _ values: [Double], _ tolerance: Double, _ what: String,
                        unit: String) -> (Double, String?) {
        guard let value else { return (-0.5, "\(what) not measured") }
        let error = values.map { abs(value / $0 - 1) }.min() ?? 1
        let match = graded(error, tolerance)
        let shown = "\(what) \(SignalIdentity.number(value)) \(unit)"
        return (match, match > 0 ? shown : shown + ", not \(list(values))")
    }

    static func ranged(_ value: Double, _ range: ClosedRange<Double>, _ softness: Double, _ shown: String,
                       expected: String) -> (Double, String?) {
        if range.contains(value) { return (1, shown) }
        let distance = value < range.lowerBound ? (range.lowerBound - value) / range.lowerBound
            : (value - range.upperBound) / range.upperBound
        return (max(-1, 1 - 2 * distance / softness), shown + ", not \(expected)")
    }

    static func list(_ values: [Double]) -> String { values.map { SignalIdentity.number($0) }.joined(separator: "/") }

    static func familyName(_ m: SignalMeasurement) -> String { SignalIdentity.familyName(m) }
}
