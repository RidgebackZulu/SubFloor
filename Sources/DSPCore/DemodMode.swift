public enum DemodMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case am, nfm, wfm, usb, lsb, cw

    public var id: String { rawValue }
    public var label: String { rawValue.uppercased() }

    public var defaultBandwidth: Double {
        switch self {
        case .am: 8_000
        case .nfm: 12_500
        case .wfm: 180_000
        case .usb, .lsb: 2_700
        case .cw: 500
        }
    }

    public var tuningStep: Double {
        switch self {
        case .am: 5_000
        case .nfm: 12_500
        case .wfm: 100_000
        case .usb, .lsb: 100
        case .cw: 10
        }
    }

    public var bandwidthStep: Double {
        switch self {
        case .am: 1_000
        case .nfm: 2_500
        case .wfm: 10_000
        case .usb, .lsb: 100
        case .cw: 50
        }
    }

    public var bandwidthRange: ClosedRange<Double> {
        switch self {
        case .am: 2_000...20_000
        case .nfm: 5_000...25_000
        case .wfm: 50_000...250_000
        case .usb, .lsb: 500...5_000
        case .cw: 50...3_000
        }
    }

    /// Lowest complex channel rate the receiver may decimate to for this mode.
    public var minimumChannelRate: Double { self == .wfm ? 300_000 : 24_000 }

    /// Offset from the VFO to the centre of the passband. SSB passbands start 100 Hz from the carrier.
    public func passbandOffset(bandwidth: Double) -> Double {
        switch self {
        case .usb: 100 + bandwidth / 2
        case .lsb: -(100 + bandwidth / 2)
        default: 0
        }
    }
}
