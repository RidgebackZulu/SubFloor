import CSDRplay

public enum HardwareAGC: String, CaseIterable, Codable, Sendable {
    case off, hz5, hz50, hz100

    public var label: String {
        switch self {
        case .off: "Off"
        case .hz5: "5 Hz"
        case .hz50: "50 Hz"
        case .hz100: "100 Hz"
        }
    }

    var api: sdrplay_api_AgcControlT {
        switch self {
        case .off: sdrplay_api_AGC_DISABLE
        case .hz5: sdrplay_api_AGC_5HZ
        case .hz50: sdrplay_api_AGC_50HZ
        case .hz100: sdrplay_api_AGC_100HZ
        }
    }
}

public struct SDRplaySettings: Codable, Equatable, Sendable {
    public var sampleRate: Double = 2_000_000
    public var decimation: Int = 1
    public var ifBandwidthKHz: Int = 1536
    public var lnaState: Int = 3
    public var ifGainReductionDb: Int = 40
    public var agc: HardwareAGC = .off
    public var biasT = false
    public var rfNotch = false
    public var dabNotch = false
    public var ppm: Double = 0

    public init() {}

    public var outputRate: Double { sampleRate / Double(decimation) }
}

public enum SDRplayEvent: Sendable, Equatable {
    case overload(detected: Bool)
    case deviceRemoved
    case deviceFailure
    case gainChanged(Double)
}
