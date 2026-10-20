import Foundation

public enum FrequencyParser {
    /// Accepts "14.074", "7074k", "144.39m", "1.2g", "125000000", "14.074.000", "7.074 MHz".
    /// Without a suffix: < 3000 → MHz, < 3 000 000 → kHz, otherwise Hz.
    public static func parse(_ text: String) -> Double? {
        var s = text.lowercased().filter { !" ,_".contains($0) }
        var explicitHz = false
        if s.hasSuffix("hz") {
            s.removeLast(2)
            explicitHz = true
        }
        var multiplier: Double?
        if let last = s.last, let m = ["k": 1e3, "m": 1e6, "g": 1e9][last] {
            multiplier = m
            s.removeLast()
        }
        guard !s.isEmpty else { return nil }
        if s.filter({ $0 == "." }).count > 1 {
            guard multiplier == nil else { return nil }
            s.removeAll { $0 == "." }
            multiplier = 1
        }
        guard s.allSatisfy({ $0.isNumber || $0 == "." }), let v = Double(s), v > 0, v.isFinite else { return nil }
        // An explicit "Hz" with no k/m/g prefix means the value is already in Hz.
        if multiplier == nil && explicitHz { multiplier = 1 }
        let hz: Double
        if let multiplier { hz = v * multiplier }
        else if v < 3_000 { hz = v * 1e6 }
        else if v < 3_000_000 { hz = v * 1e3 }
        else { hz = v }
        return hz.rounded()
    }
}

public enum FrequencyFormatter {
    /// Dot-grouped whole Hz: 14074000 → "14.074.000".
    public static func grouped(_ hz: Double) -> String {
        let digits = String(Int(max(0, hz).rounded()))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(".") }
            out.append(ch)
        }
        return out
    }

    /// Ten zero-padded digits (GHz … Hz) for the big readout.
    public static func readoutDigits(_ hz: Double) -> [Int] {
        var v = Int(max(0, min(hz, 9_999_999_999)).rounded())
        var out = [Int](repeating: 0, count: 10)
        for i in stride(from: 9, through: 0, by: -1) {
            out[i] = v % 10
            v /= 10
        }
        return out
    }

    public static func short(_ hz: Double) -> String {
        func g(_ v: Double) -> String { String(format: "%.7g", v) }
        switch abs(hz) {
        case 1e9...: return "\(g(hz / 1e9)) GHz"
        case 1e6...: return "\(g(hz / 1e6)) MHz"
        case 1e3...: return "\(g(hz / 1e3)) kHz"
        default: return "\(g(hz)) Hz"
        }
    }

    public static func rate(_ sps: Double) -> String {
        sps >= 1e6 ? String(format: "%.3f MSPS", sps / 1e6) : String(format: "%.1f kSPS", sps / 1e3)
    }
}

/// HamItUp-style upconverter: the radio is tuned LO Hz above the antenna (display) frequency.
public struct Upconverter: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var loHz: Double

    public init(enabled: Bool = false, loHz: Double = 125_000_000) {
        self.enabled = enabled
        self.loHz = loHz
    }

    public func hardware(fromDisplay hz: Double) -> Double { enabled ? hz + loHz : hz }
    public func display(fromHardware hz: Double) -> Double { enabled ? hz - loHz : hz }
}

public enum TuningPlanner {
    /// How far from centre (as a fraction of the sample rate) the VFO may go before the radio retunes.
    public static let usableFraction = 0.45

    /// After a retune the VFO sits this far above centre, away from the zero-IF DC spike.
    public static func dcOffset(sampleRate: Double) -> Double { sampleRate * 0.05 }

    public static func center(forVFO vfo: Double, sampleRate: Double) -> Double {
        vfo - dcOffset(sampleRate: sampleRate)
    }

    /// A new centre when `vfo` has left the usable span around `center`; otherwise nil.
    public static func retuneIfNeeded(vfo: Double, center: Double, sampleRate: Double) -> Double? {
        abs(vfo - center) > sampleRate * usableFraction ? self.center(forVFO: vfo, sampleRate: sampleRate) : nil
    }
}

public enum RSP1B {
    public static let frequencyRange: ClosedRange<Double> = 1_000...2_000_000_000
    public static let sampleRates: [Double] = [2e6, 3e6, 4e6, 5e6, 6e6, 7e6, 8e6, 9e6, 10e6]
    public static let decimations = [1, 2, 4, 8, 16, 32]
    public static let ifGainReductionRange = 20...59

    public static func lnaStateCount(forHz hz: Double) -> Int {
        switch hz {
        case ..<60e6: 7
        case ..<1_000e6: 10
        default: 9
        }
    }

    /// Largest analogue IF filter (kHz, matching `sdrplay_api_Bw_MHzT`) that fits the output rate.
    public static func ifBandwidthKHz(sampleRate: Double, decimation: Int) -> Int {
        let out = sampleRate / Double(decimation)
        return [8000, 7000, 6000, 5000, 1536, 600, 300, 200].first { Double($0) * 1_000 <= out } ?? 200
    }

    public static func clampHardware(_ hz: Double) -> Double {
        min(max(hz, frequencyRange.lowerBound), frequencyRange.upperBound)
    }
}
