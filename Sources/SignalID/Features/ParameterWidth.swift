import Foundation

/// The occupied (−20 dB) bandwidth from a signal's measured parameters, for families whose parameters fix it,
/// used where the measured −20 dB edges sit under the noise (ruling R16): a rectangular-keyed FSK's sinc skirts,
/// CW's keying sidebands and a narrow PSK's skirts reach −20 dB of the mean density only 10 dB under the noise
/// at 10 dB SNR, so the measured width reads narrow there.
///
/// The relations were calibrated on noise-free renders (seeds 1000–1004, the synthesiser's width definition):
/// - **Rectangular continuous-phase FSK** (n tones `spacing` apart at `rate`): (n − 1) × spacing + k(n, h) × rate,
///   h = spacing / rate, k from the table below (linear in log₂ n and log h between its points, clamped at its
///   ends). The shaping can't be read off the signal: the relation is used for wide shifts (h ≥ 1.5: RTTY,
///   NAVTEX, POCSAG, ALE, which are keyed so), and for a narrower one only when a named row says it is
///   rectangular (WSPR, MFSK16, `SignalIdentifier`). Other Gaussian-filtered FSK (GMSK, C4FM) keeps its measured
///   width, which its steep skirts keep close.
/// - **PSK under 300 Bd** (PSK31/PSK63's cosine-shaped reversals): 1.738 × rate. Faster PSK is root-raised-cosine
///   filtered (1.19–1.32 × rate for roll-offs 0.2–0.35), its steep edges measured as they are.
/// - **Gaussian-filtered FSK one symbol rate apart** (h = 1: FT8 at BT 2, FT4 and Olivia at BT 1), when a named
///   row gives its filter: (n − 1) × spacing + k(BT, n) × rate.
/// - **CW**: by keying speed, from the table below (Hann-shaped keying, 15 ms edges, half a dot above 40 WPM).
/// - **FM carrying one tone subcarrier** (NOAA APT): Carson's rule, 1.98 × (deviation + subcarrier).
/// - **A named time signal** (its ticks seen): at least its 1 kHz ticks' width, 2.07 kHz.
enum ParameterWidth {
    /// How a named row's FSK is keyed, when its shift doesn't say (`ModeRow.shaping`).
    enum Shaping: Sendable {
        case rectangular
        /// The Gaussian filter's BT by tone count (0: any count).
        case gaussian([Int: Double])
        /// At least this wide by its standard (a time signal's 1 kHz ticks of 5 ms: 2.07 kHz on noise-free renders,
        /// seeds 1000–1004): the measured width when that is wider (real WWV's voice announcements).
        case atLeast(Double)
    }

    static let note = "bandwidth from parameters"
    /// Edges within this factor of the noise per bin (3 dB) or under it count as under the noise.
    static let edgeNoiseFactor = 2.0
    static let minWideShift = 1.5
    static let maxKeyboardPSKRate = 300.0
    static let cosinePSK = 1.738

    static let rectangularTones: [Double] = [2, 4, 8, 16, 32]
    static let rectangularH: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8, 12, 17, 25]
    /// k(n, h): rows by tone count, columns by h.
    static let rectangularK: [[Double]] = [
        [1.635, 1.673, 1.639, 2.914, 2.738, 3.406, 4.727, 5.328, 6.713, 7.359, 9.197, 9.570, 10.817],
        [1.721, 2.950, 3.367, 3.572, 3.574, 5.225, 5.506, 7.206, 7.625, 8.744, 10.847, 13.263, 16.798],
        [3.004, 3.427, 4.208, 3.932, 5.027, 5.450, 6.420, 7.953, 9.356, 10.519, 13.153, 15.991, 18.870],
        [3.473, 3.760, 5.320, 5.372, 5.598, 6.400, 7.875, 9.266, 11.775, 12.294, 15.934, 20.873, 24.384],
        [4.180, 5.432, 5.764, 6.266, 6.926, 7.000, 9.719, 11.450, 13.456, 16.062, 23.622, 30.930, 43.278],
    ]
    /// Gaussian k at h = 1, by BT, over `gaussianTones`.
    static let gaussianTones: [Double] = [4, 8, 16, 32]
    static let gaussianK: [Double: [Double]] = [1: [1.615, 1.920, 2.139, 2.560], 2: [1.682, 1.830, 1.830, 1.830]]
    static let maxGaussianShiftError = 0.1
    static let toneCarson = 1.98
    static let cwWPM: [Double] = [5, 8, 10, 12, 15, 20, 25, 30, 35, 40, 45, 50]
    static let cwWidth: [Double] = [61.6, 75.5, 93.1, 92.3, 90.3, 118.6, 108.2, 127.9, 147.0, 108.1, 121.6, 135.1]

    /// The width the family's parameters give, or nil when they don't fix it (or the shaping is unknown).
    /// `shaping`: a named row's, for an FSK whose shift doesn't say how it is keyed.
    static func width(_ m: SignalMeasurement, shaping: Shaping? = nil) -> Double? {
        if case .atLeast(let width) = shaping { return width > m.occupiedBandwidthHz ? width : nil }
        switch m.family {
        case .fsk, .mfsk:
            guard let n = m.toneCount, let spacing = m.toneSpacingHz, let rate = m.symbolRate, rate > 0 else { return nil }
            let h = spacing / rate
            let span = Double(n - 1) * spacing
            switch shaping {
            case .atLeast:
                return nil
            case .gaussian(let bts):
                guard let bt = bts[n] ?? bts[0], let ks = gaussianK[bt], abs(h - 1) <= maxGaussianShiftError
                else { return nil }
                return span + interpolate(gaussianTones.map(log2), ks, at: log2(Double(n))) * rate
            case .rectangular:
                return span + rectangularK(tones: Double(n), h: h) * rate
            case nil:
                guard h >= minWideShift else { return nil }
                return span + rectangularK(tones: Double(n), h: h) * rate
            }
        case .psk:
            guard let rate = m.symbolRate, rate < maxKeyboardPSKRate else { return nil }
            return cosinePSK * rate
        case .ook:
            return m.cwWPM.map { interpolate(cwWPM, cwWidth, at: $0) }
        case .fm:
            let tones = m.subcarriersHz.filter { abs($0 - 19_000) > 200 }
            guard tones.count == 1, m.symbolRate == nil, let deviation = m.fmDeviationHz else { return nil }
            return toneCarson * (deviation + tones[0])
        default:
            return nil
        }
    }

    /// Replaces a measured width whose edges sit under the noise with the parameters' (and the SNR with the noise
    /// over that width; the signal's power outside the measured band is a few per cent at most), and notes it.
    static func apply(to m: inout SignalMeasurement, shaping: Shaping? = nil) {
        guard m.edgesUnderNoise, !m.notes.contains(where: { $0.hasSuffix(note) }), m.occupiedBandwidthHz > 0,
              let width = width(m, shaping: shaping) else { return }
        m.snrDb -= 10 * log10(width / m.occupiedBandwidthHz)
        m.notes.append(String(format: "Edges under the noise (measured %.0f Hz): %@", m.occupiedBandwidthHz, note))
        m.occupiedBandwidthHz = width
    }

    static func rectangularK(tones: Double, h: Double) -> Double {
        let row = fraction(rectangularTones.map(log2), log2(tones))
        let column = fraction(rectangularH.map(log), log(h))
        func k(_ r: Int, _ c: Int) -> Double { rectangularK[r][c] }
        let low = k(row.index, column.index) * (1 - column.t) + k(row.index, column.index + 1) * column.t
        let high = k(row.index + 1, column.index) * (1 - column.t) + k(row.index + 1, column.index + 1) * column.t
        return low * (1 - row.t) + high * row.t
    }

    /// Where `x` falls in the ascending `grid`: the cell's first index and the fraction across it (clamped).
    static func fraction(_ grid: [Double], _ x: Double) -> (index: Int, t: Double) {
        guard x > grid[0] else { return (0, 0) }
        guard x < grid[grid.count - 1] else { return (grid.count - 2, 1) }
        let i = grid.lastIndex { $0 <= x }!
        return (i, (x - grid[i]) / (grid[i + 1] - grid[i]))
    }

    static func interpolate(_ xs: [Double], _ ys: [Double], at x: Double) -> Double {
        let (i, t) = fraction(xs, x)
        return ys[i] * (1 - t) + ys[i + 1] * t
    }
}
