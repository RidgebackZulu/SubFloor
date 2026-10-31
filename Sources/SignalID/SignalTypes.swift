import Foundation

/// The broad kind of a signal, before it is matched against the named modes.
public enum SignalFamily: String, Codable, Sendable, CaseIterable {
    case noise, carrier, am, usb, lsb, fm, wfm, ook, fsk, mfsk, psk, ofdm, unknown
}

/// How a signal's amplitude behaves over the analysed span.
public enum EnvelopeKind: String, Codable, Sendable {
    /// Constant (a carrier, FM, FSK).
    case steady
    /// On/off keying (CW, OOK).
    case keyed
    /// Syllabic: bursts and pauses at speech rates.
    case voice
    /// Regular or irregular transmissions with silence between (TDMA, slots, packets).
    case bursty
    /// No signal to judge.
    case none
}

/// What Signal ID measured about one signal. Frequencies are in Hz; parameters a family doesn't have are nil.
public struct SignalMeasurement: Codable, Sendable, Equatable {
    /// Centre of the occupied band, relative to the capture centre.
    public var offsetHz: Double
    /// Width at −20 dB.
    public var occupiedBandwidthHz: Double
    /// Width at −6 dB.
    public var bandwidth6dBHz: Double
    /// Signal power over noise power, both within the occupied bandwidth.
    public var snrDb: Double
    public var envelope: EnvelopeKind
    public var family: SignalFamily
    /// 0…1.
    public var familyConfidence: Float
    /// Symbols per second (FSK, PSK, MFSK).
    public var symbolRate: Double?
    /// Spacing of the two tones of a 2-FSK.
    public var fskShiftHz: Double?
    public var toneCount: Int?
    public var toneSpacingHz: Double?
    /// 2, 4 or 8.
    public var pskOrder: Int?
    public var ofdmSpacingHz: Double?
    /// Peak deviation of an FM signal.
    public var fmDeviationHz: Double?
    public var cwWPM: Double?
    public var burstPeriodSeconds: Double?
    /// Fraction of each burst period that is on (0…1).
    public var burstDuty: Double?
    /// Subcarriers found inside the demodulated signal (AFSK tones, the APT 2400 Hz, ACARS MSK).
    public var subcarriersHz: [Double]
    /// Length of IQ analysed.
    public var seconds: Double
    /// Evidence and caveats, for the ID card.
    public var notes: [String]

    public init(offsetHz: Double = 0, occupiedBandwidthHz: Double = 0, bandwidth6dBHz: Double = 0, snrDb: Double = 0,
                envelope: EnvelopeKind = .none, family: SignalFamily = .unknown, familyConfidence: Float = 0,
                symbolRate: Double? = nil, fskShiftHz: Double? = nil, toneCount: Int? = nil,
                toneSpacingHz: Double? = nil, pskOrder: Int? = nil, ofdmSpacingHz: Double? = nil,
                fmDeviationHz: Double? = nil, cwWPM: Double? = nil, burstPeriodSeconds: Double? = nil,
                burstDuty: Double? = nil, subcarriersHz: [Double] = [], seconds: Double = 0, notes: [String] = []) {
        self.offsetHz = offsetHz
        self.occupiedBandwidthHz = occupiedBandwidthHz
        self.bandwidth6dBHz = bandwidth6dBHz
        self.snrDb = snrDb
        self.envelope = envelope
        self.family = family
        self.familyConfidence = familyConfidence
        self.symbolRate = symbolRate
        self.fskShiftHz = fskShiftHz
        self.toneCount = toneCount
        self.toneSpacingHz = toneSpacingHz
        self.pskOrder = pskOrder
        self.ofdmSpacingHz = ofdmSpacingHz
        self.fmDeviationHz = fmDeviationHz
        self.cwWPM = cwWPM
        self.burstPeriodSeconds = burstPeriodSeconds
        self.burstDuty = burstDuty
        self.subcarriersHz = subcarriersHz
        self.seconds = seconds
        self.notes = notes
    }
}
