import Accelerate
import DSPCore
import Foundation

/// One signal followed by `SignalTracker`.
public struct Track: Sendable, Equatable, Identifiable {
    /// Unique for the tracker's lifetime; never reused, even across `reset()`.
    public var id: Int
    /// Audio frequency of the signal's centre: the parabolic-refined carrier of a line, the
    /// midpoint of a PSK31 idle twin or an FSK mark/space pair, or the power centroid of a hump.
    public var frequencyHz: Double
    /// SNR in a 2.5 kHz noise bandwidth (WSJT convention), from the signal's integrated power.
    public var snrDb: Float
    /// Width where the averaged spectrum is within 20 dB of the signal's strongest bin (and at least
    /// 6 dB above the floor). Includes the analysis window's own main lobe, about 9 Hz for a pure tone.
    public var bandwidthHz: Double
    /// Sample index (in `SignalTracker.samplesSeen` units) at the end of the frame that first saw it.
    public var firstSeenSample: Int
    /// Sample index at the end of the last frame in which the signal carried energy.
    public var lastActiveSample: Int
    /// True after `SignalTracker.quietAfterSeconds` without energy.
    public var isQuiet: Bool
    /// Two lines 170 ± 15 Hz apart within 6 dB: an RTTY mark/space pair centred between them.
    public var isFSKPair: Bool
    /// Secondary spectral peaks relative to `frequencyHz`, ascending, for the classifier. A PSK31 idle
    /// twin reports about −15.6 and +15.6; a pure carrier reports none. Peaks within one bin of the
    /// centre are omitted.
    public var peakOffsetsHz: [Double]

    public init(id: Int, frequencyHz: Double, snrDb: Float, bandwidthHz: Double, firstSeenSample: Int,
                lastActiveSample: Int, isQuiet: Bool, isFSKPair: Bool, peakOffsetsHz: [Double]) {
        self.id = id
        self.frequencyHz = frequencyHz
        self.snrDb = snrDb
        self.bandwidthHz = bandwidthHz
        self.firstSeenSample = firstSeenSample
        self.lastActiveSample = lastActiveSample
        self.isQuiet = isQuiet
        self.isFSKPair = isFSKPair
        self.peakOffsetsHz = peakOffsetsHz
    }
}

/// Finds and follows every signal in the 12 kHz box audio.
///
/// Pipeline per frame (4096-point Hann FFT, 50% hop, ≈2.93 Hz bins):
/// 1. Power spectrum, exponentially averaged with α = 0.3.
/// 2. Noise floor: a 64-bin running median over the band's bins, excluding the bins the previous
///    frame attributed to signals, scaled from median to mean noise power per bin.
/// 3. Peaks: ≥ 6 dB over the floor and a local maximum within ±5 bins, refined by parabolic
///    interpolation. Sharper ±2-bin maxima are also kept as lines for PSK31 twins and FSK keying
///    lines, where neighbouring signals' lines sit closer than 5 bins.
/// 4. Grouping into signals, in this order:
///    - FSK pairs: lumps of a smoothed spectrum 170 ± 15 Hz apart within 6 dB, with nothing
///      independent between them and with anticorrelated mark/space energies. A pair absorbs its
///      tones within 1 baud, its skirt to 4 baud (stopping at any neighbour with its own lump), and
///      mirrored keying lines to 8 baud.
///    - PSK31 idle twins: two sharp lines 31.25 ± 1.5 Hz apart within 3 dB with a deep dip between,
///      paired across the band before any sideband merge.
///    - Sidebands: peaks within ±20 Hz of a stronger signal's main line, or a similar-level top up to
///      35 Hz away with only a shallow dip (a PSK31 data hump), then the no-valley merge.
/// 5. Association: nearest track within ±10 Hz, frequency EMA α = 0.3. A new signal must be seen
///    in 6 consecutive frames (about 1 s) before it becomes a track, which keeps noise from spawning
///    tracks; an idle track revives only on the same evidence.
///
/// Not thread-safe: confine an instance to one thread (the modem thread).
public final class SignalTracker {
    public static let quietAfterSeconds = 20.0
    public static let removeAfterSeconds = 120.0

    // MARK: Analysis constants

    static let fftSize = 4_096
    static let hopSize = fftSize / 2
    static let averagingAlpha: Float = 0.3
    /// Frames averaged before peaks are picked; the first frames use a running mean (α = 1/n).
    static let warmupFrames = 4
    static let floorWindowBins = 64
    /// Half-width of the wider noise window used as the SNR reference (±750 Hz).
    static let referenceHalfWidthBins = 256
    /// Mean/median ratio of a noise-only bin of the averaged spectrum (measured, see tests).
    static let floorMeanPerMedian: Float = 1.078
    static let peakThreshold: Float = 3.981_071_7          // 6 dB
    static let localMaxBins = 5
    /// Hann main-lobe half-width: lines this sharp are kept for twin pairing even when a neighbour
    /// within ±5 bins is stronger.
    static let lineLocalMaxBins = 2
    static let sidebandHz = 20.0
    static let twinSpacingHz = 31.25                        // BPSK31 idle: ±15.625 Hz
    /// Tight pass: real idle lines sit within 0.1 Hz of 31.25 Hz apart and about 1 dB of each other.
    static let twinTightToleranceHz = 1.5
    static let twinLevelDb: Float = 3
    /// Loose fallback for leftover lines (noisy low-SNR frames).
    static let twinToleranceHz = 4.0
    static let lineSteepDb: Float = 10
    /// Depth the suppressed-carrier gap of an idle twin must reach below the weaker line.
    static let twinDipDb: Float = 6
    static let pairLevelDb: Float = 6
    static let fskShiftHz = 170.0
    static let fskShiftToleranceHz = 15.0
    static let rttyBaud = 45.45
    /// Reach (beyond shift/2) of an FSK pair's skirt and of its mirrored keying lines.
    static let fskSplatterBauds = 4.0
    static let fskMirrorBauds = 8.0
    static let mirrorToleranceHz = 3.0
    static let mirrorLevelDb: Float = 6
    static let fskMirrorBelowToneDb: Float = 6
    /// Independent content between two tones this close to the weaker tone vetoes an FSK pair.
    static let fskMiddleDb: Float = 6
    /// Mark/space energy correlation at or below this marks a real FSK signal (with a full 2 s history).
    /// Measured over 80 PSK31 pairs and 20 carrier pairs 155-185 Hz apart: −0.17…+0.31; random
    /// RTTY at −10 dB: −0.54…−0.35, at −5 dB and up ≤ −0.73.
    static let fskMaxEnvelopeCorrelation: Float = -0.3
    static let fskStrictestCorrelation: Float = -0.6
    static let fskHistorySamples = 24_576                   // ≈ 2 s
    static let minFSKHistorySamples = 8_192
    static let envelopeDecimation = 8                       // 1.5 kHz
    static let envelopeBandpassSamples = 24                 // 16 ms boxcar at 1.5 kHz
    static let envelopeAverageSamples = 12                  // 8 ms
    static let envelopeSettleSamples = 300                  // 200 ms notch settling
    static let envelopeNotchRadius = 0.985                  // ≈ 7 Hz wide
    static let pskSymbolRateHz = 31.25
    static let envelopeHop = 6                              // 4 ms
    /// Gaussian smoothing (in bins) used to find FSK tone lumps, so keying lines merge into one lump.
    static let lumpSigmaBins = 5.0
    static let lumpRadiusBins = 15
    static let lumpLocalMaxBins = 10
    static let lumpThreshold: Float = 2                     // 3 dB
    static let lumpSupportHz = 25.0
    static let valleyDb: Float = 3
    static let regionThreshold: Float = 2                   // 3 dB
    static let regionBeyondMembersHz = 40.0
    static let lineBandwidthHz = 15.0
    static let associateHz = 10.0
    static let frequencyAlpha = 0.3
    /// A track idle for longer than this needs `confirmFrames` consecutive frames with energy to revive.
    static let continuitySeconds = 2.0
    /// Consecutive detections before a candidate becomes a track. Measured on 300 min of noise: 4 frames
    /// gave 11 false tracks, 5 and 6 gave none; 6 keeps a margin.
    static let confirmFrames = 6
    /// A frame carries energy when its raw in-signal excess power is at least this fraction of the
    /// averaged excess, so a signal that stopped is not kept alive by the decaying average.
    static let activityFraction: Float = 0.25
    static let noiseBandwidthHz = 2_500.0

    // MARK: Public state

    public let sampleRate: Double
    public let band: ClosedRange<Double>
    public var binHz: Double { sampleRate / Double(Self.fftSize) }
    public private(set) var samplesSeen = 0

    /// Confirmed tracks, quiet ones included, in ascending frequency.
    public var tracks: [Track] { confirmed }

    /// The averaged power spectrum in dB (0 dB = a full-scale sine), bins 0...fftSize/2, bin k at k·binHz.
    public var averagedSpectrumDb: [Float] {
        avg.map { 10 * log10(max($0, 1e-20)) }
    }

    /// The centre of the strongest signal detected in the latest frame within ±`within` Hz of `hz`,
    /// confirmed or not (ruling R8: cursor click-snap for signals younger than the confirmation).
    /// A line's centre is its interpolated peak; an idle PSK31 twin or FSK pair snaps to its centre,
    /// not to a sideband line. Nil when nothing qualifies.
    public func strongestPeak(near hz: Double, within: Double) -> Double? {
        latestDetections.filter { abs($0.hz - hz) <= within }.max { $0.snrDb < $1.snrDb }?.hz
    }

    /// Noise floor per bin (mean noise power, same units as the averaged spectrum). For tests.
    var noiseFloor: [Float] { floor }

    // MARK: Private state

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let window: [Float]
    private let powerScale: Float
    private let lowBin: Int
    private let highBin: Int
    private let gaussian: [Float]

    private var buffer: [Float]
    private var history: [Float]
    private var historyWrite = 0
    private var historyCount = 0
    private var latestDetections: [(hz: Double, snrDb: Float)] = []
    private var windowed: [Float]
    private var filled = 0
    private var frames = 0
    private var re: [Float]
    private var im: [Float]
    private var raw: [Float]
    private var avg: [Float]
    private var floor: [Float]
    private var smooth: [Float]
    private var excluded: [Bool]
    private var owner: [Int]

    private var confirmed: [Track] = []
    /// Consecutive matched frames with energy, per track id.
    private var streaks: [Int: Int] = [:]
    private var candidates: [Candidate] = []
    private var nextID = 1

    private struct Candidate {
        var frequencyHz: Double
        var hits: Int
        var firstSeenSample: Int
        var lastActiveSample: Int
        var detection: Detection
    }

    private struct Peak {
        var bin: Int
        var hz: Double
        var power: Float
        var db: Float
        /// A local maximum within ±5 bins (the brief's peak). Lines that are only ±2-bin maxima are
        /// kept for PSK31 twin pairing and FSK keying lines, where two signals' lines sit close together.
        var isPeak: Bool
    }

    private struct Lump {
        var bin: Int
        var hz: Double
        var db: Float
    }

    private enum Kind { case single, twin, fsk }

    private struct Group {
        var kind: Kind
        /// Indices into the frame's peaks. `members[0]` is the anchor (strongest) for single/twin.
        var members: [Int]
        var twin: Int?
        var fskCentreHz = 0.0
        var fskHalfShiftHz = 0.0
        var lumpBins: [Int] = []
    }

    private struct Detection {
        var centreHz: Double
        var snrDb: Float
        var bandwidthHz: Double
        var isFSK: Bool
        var offsetsHz: [Double]
        var active: Bool
    }

    public init(sampleRate: Double = 12_000, band: ClosedRange<Double> = 300...3300) {
        self.sampleRate = sampleRate
        self.band = band
        let n = Self.fftSize
        log2n = vDSP_Length(n.trailingZeroBitCount)
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = WindowKind.hann.coefficients(count: n)
        let sum = window.reduce(0, +)
        // vDSP_fft_zrip returns 2·X[k]; P = 4|X|²/(Σw)² makes a unit-amplitude sine read 1 (0 dB).
        powerScale = 1 / (sum * sum)
        let bins = n / 2 + 1
        let margin = Self.lumpRadiusBins + Self.lumpLocalMaxBins + 1
        let bin = sampleRate / Double(n)
        lowBin = max(margin, Int((band.lowerBound / bin).rounded(.up)))
        highBin = min(bins - 1 - margin, Int((band.upperBound / bin).rounded(.down)))
        precondition(highBin > lowBin + Self.floorWindowBins, "band too narrow for the tracker")
        let r = Self.lumpRadiusBins
        var g = (-r...r).map { Float(exp(-Double($0 * $0) / (2 * Self.lumpSigmaBins * Self.lumpSigmaBins))) }
        let gs = g.reduce(0, +)
        g = g.map { $0 / gs }
        gaussian = g
        buffer = .init(repeating: 0, count: n)
        history = .init(repeating: 0, count: Self.fskHistorySamples)
        windowed = .init(repeating: 0, count: n)
        re = .init(repeating: 0, count: n / 2)
        im = .init(repeating: 0, count: n / 2)
        raw = .init(repeating: 0, count: bins)
        avg = .init(repeating: 0, count: bins)
        floor = .init(repeating: 0, count: bins)
        smooth = .init(repeating: 0, count: bins)
        excluded = .init(repeating: false, count: bins)
        owner = .init(repeating: -1, count: bins)
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Clears audio history, the spectrum and every track. Track ids keep increasing.
    public func reset() {
        filled = 0
        frames = 0
        samplesSeen = 0
        historyWrite = 0
        historyCount = 0
        latestDetections.removeAll()
        for i in avg.indices { avg[i] = 0; raw[i] = 0; floor[i] = 0; excluded[i] = false }
        confirmed.removeAll()
        streaks.removeAll()
        candidates.removeAll()
    }

    /// Appends box audio at `sampleRate`. Runs one analysis frame per 2048 new samples; any chunk
    /// size gives the same result.
    public func process(_ audio: UnsafeBufferPointer<Float>) {
        var i = 0
        let n = Self.fftSize
        while i < audio.count {
            let take = min(n - filled, audio.count - i)
            buffer.withUnsafeMutableBufferPointer { b in
                (b.baseAddress! + filled).update(from: audio.baseAddress! + i, count: take)
            }
            for j in 0..<take {
                history[historyWrite] = audio[i + j]
                historyWrite += 1
                if historyWrite == history.count { historyWrite = 0 }
            }
            historyCount = min(history.count, historyCount + take)
            filled += take
            i += take
            samplesSeen += take
            if filled == n {
                analyzeFrame()
                buffer.withUnsafeMutableBufferPointer { b in
                    b.baseAddress!.update(from: b.baseAddress! + Self.hopSize, count: n - Self.hopSize)
                }
                filled = n - Self.hopSize
            }
        }
    }

    // MARK: - Frame analysis

    private func analyzeFrame() {
        computeSpectrum()
        frames += 1
        let alpha = max(Self.averagingAlpha, 1 / Float(frames))
        for k in avg.indices { avg[k] += alpha * (raw[k] - avg[k]) }
        guard frames >= Self.warmupFrames else { return }

        computeFloor()
        let peaks = findPeaks()
        let groups = groupPeaks(peaks)
        let detections = measure(groups, peaks)
        latestDetections = detections.map { ($0.centreHz, $0.snrDb) }
        associate(detections)
    }

    private func computeSpectrum() {
        let n = Self.fftSize
        let half = n / 2
        vDSP_vmul(buffer, 1, window, 1, &windowed, 1, vDSP_Length(n))
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
        raw[0] = re[0] * re[0] * powerScale
        raw[half] = im[0] * im[0] * powerScale
        for k in 1..<half { raw[k] = (re[k] * re[k] + im[k] * im[k]) * powerScale }
    }

    /// 64-bin running median over the band's non-signal bins, scaled to mean noise power.
    private func computeFloor() {
        var values: [Float] = []
        var positions: [Int] = []
        values.reserveCapacity(highBin - lowBin + 1)
        positions.reserveCapacity(highBin - lowBin + 1)
        for k in lowBin...highBin where !excluded[k] {
            values.append(avg[k])
            positions.append(k)
        }
        if values.count < Self.floorWindowBins {
            values = Array(avg[lowBin...highBin])
            positions = Array(lowBin...highBin)
        }
        let count = values.count
        let w = min(Self.floorWindowBins, count)
        var medians = [Float](repeating: 0, count: count)
        var sorted = Array(values[0..<w]).sorted()
        var start = 0
        for i in 0..<count {
            let s = min(max(i - w / 2, 0), count - w)
            while start < s {
                let old = values[start]
                if let idx = Self.lowerBound(sorted, old) { sorted.remove(at: idx) }
                let new = values[start + w]
                let ins = Self.lowerBound(sorted, new) ?? sorted.count
                sorted.insert(new, at: ins)
                start += 1
            }
            medians[i] = w % 2 == 0 ? (sorted[w / 2 - 1] + sorted[w / 2]) / 2 : sorted[w / 2]
        }
        var j = 0
        for k in lowBin...highBin {
            while j + 1 < count && abs(positions[j + 1] - k) <= abs(positions[j] - k) { j += 1 }
            floor[k] = Self.floorMeanPerMedian * medians[j]
        }
        for k in 0..<lowBin { floor[k] = floor[lowBin] }
        for k in (highBin + 1)..<floor.count { floor[k] = floor[highBin] }
    }

    /// Mean noise power per bin near `bin`: the median of the non-signal band bins within
    /// ±`referenceHalfWidthBins`, scaled from median to mean.
    private func noiseReference(aroundBin bin: Int) -> Float {
        let width = Self.referenceHalfWidthBins
        let lo = max(lowBin, min(bin - width, highBin - 2 * width))
        let hi = min(highBin, lo + 2 * width)
        var values: [Float] = []
        values.reserveCapacity(hi - lo + 1)
        for k in lo...hi where !excluded[k] { values.append(avg[k]) }
        if values.count < Self.floorWindowBins { values = Array(avg[lo...hi]) }
        values.sort()
        let m = values.count
        let median = m % 2 == 0 ? (values[m / 2 - 1] + values[m / 2]) / 2 : values[m / 2]
        return Self.floorMeanPerMedian * median
    }

    /// Index of the first element ≥ `value`, or nil when every element is smaller.
    private static func lowerBound(_ a: [Float], _ value: Float) -> Int? {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        return lo < a.count ? lo : nil
    }

    private func db(_ p: Float) -> Float { 10 * log10(max(p, 1e-30)) }

    private func isLocalMax(_ s: [Float], _ k: Int, radius: Int) -> Bool {
        let v = s[k]
        for d in 1...radius {
            if s[k - d] >= v || s[k + d] > v { return false }
        }
        return true
    }

    /// Parabolic refinement on dB values: (fractional bin offset, interpolated level in dB).
    private func interpolate(_ s: [Float], _ k: Int) -> (Double, Float) {
        let a = db(s[k - 1]), b = db(s[k]), c = db(s[k + 1])
        let denom = a - 2 * b + c
        guard denom < 0 else { return (0, b) }
        let delta = min(max(0.5 * (a - c) / denom, -0.5), 0.5)
        return (Double(delta), b - 0.25 * (a - c) * delta)
    }

    private func findPeaks() -> [Peak] {
        var lines: [Peak] = []
        for k in lowBin...highBin where avg[k] > Self.peakThreshold * floor[k] {
            guard isLocalMax(avg, k, radius: Self.lineLocalMaxBins) else { continue }
            let (delta, level) = interpolate(avg, k)
            lines.append(Peak(bin: k, hz: (Double(k) + delta) * binHz, power: pow(10, level / 10), db: level,
                              isPeak: isLocalMax(avg, k, radius: Self.localMaxBins)))
        }
        return lines
    }

    // MARK: - Grouping

    /// Groups the frame's lines into signals. Order matters: FSK pairs (validated), then PSK31 idle
    /// twins paired globally with a tight tolerance, then sidebands, then the no-valley merge.
    private func groupPeaks(_ lines: [Peak]) -> [Group] {
        var groups: [Group] = []
        var assigned = [Bool](repeating: false, count: lines.count)

        // 1. FSK pairs, found on a Gaussian-smoothed spectrum so each tone's keying lines form one lump.
        let lumps = findLumps(lines)
        var lumpUsed = [Bool](repeating: false, count: lumps.count)
        let order = lumps.indices.sorted { lumps[$0].db > lumps[$1].db }
        func insideFSK(_ hz: Double) -> Bool {
            groups.contains { $0.kind == .fsk && abs(hz - $0.fskCentreHz) <= $0.fskHalfShiftHz + Self.rttyBaud }
        }
        for li in order where !lumpUsed[li] && !insideFSK(lumps[li].hz) {
            for mi in order where mi != li && !lumpUsed[mi] && !insideFSK(lumps[mi].hz) {
                let spacing = abs(lumps[mi].hz - lumps[li].hz)
                guard abs(spacing - Self.fskShiftHz) <= Self.fskShiftToleranceHz,
                      abs(lumps[mi].db - lumps[li].db) <= Self.pairLevelDb else { continue }
                let (low, high) = lumps[li].hz < lumps[mi].hz ? (lumps[li], lumps[mi]) : (lumps[mi], lumps[li])
                guard isFSK(low: low, high: high, lines: lines, lumps: lumps) else { continue }
                lumpUsed[li] = true
                lumpUsed[mi] = true
                groups.append(Group(kind: .fsk, members: [], twin: nil, fskCentreHz: (low.hz + high.hz) / 2,
                                    fskHalfShiftHz: (high.hz - low.hz) / 2, lumpBins: [low.bin, high.bin]))
                break
            }
        }
        // Absorb each FSK pair's tones and keying lines. Within 1 baud outside a tone everything is
        // taken; beyond that only lines that are evidently the pair's own (see below), so weak
        // neighbours beside an RTTY signal stay separate.
        for gi in groups.indices {
            let g = groups[gi]
            let weakerTone = toneLevels(g.lumpBins.map { Double($0) * binHz }, lines).min() ?? -300
            let inner = g.fskHalfShiftHz + Self.rttyBaud
            let outer = g.fskHalfShiftHz + Self.fskSplatterBauds * Self.rttyBaud
            let toneHz = g.lumpBins.map { Double($0) * binHz }
            let mirrorReach = g.fskHalfShiftHz + Self.fskMirrorBauds * Self.rttyBaud
            // Independent neighbours: smoothed-spectrum lumps outside the inner zone that are not the
            // pair's tones. The pair never reaches past the nearest one on either side.
            let neighbours = lumps.filter { lump in
                abs(lump.hz - g.fskCentreHz) > inner && !toneHz.contains { abs($0 - lump.hz) <= Self.lumpSupportHz }
            }
            let upperStop = neighbours.filter { $0.hz > g.fskCentreHz }.map { $0.hz - Self.lumpSupportHz }.min() ?? .infinity
            let lowerStop = neighbours.filter { $0.hz < g.fskCentreHz }.map { $0.hz + Self.lumpSupportHz }.max() ?? -.infinity
            for li in lines.indices where !assigned[li] {
                let line = lines[li]
                let off = abs(line.hz - g.fskCentreHz)
                var take = off <= inner
                if !take && off <= mirrorReach {
                    // Mirrored keying lines: periodic keying and the CPFSK skirt are symmetric about
                    // the centre, a neighbour is not.
                    let mirror = 2 * g.fskCentreHz - line.hz
                    take = line.db <= weakerTone - Self.fskMirrorBelowToneDb && lines.contains {
                        abs($0.hz - mirror) <= Self.mirrorToleranceHz && abs($0.db - line.db) <= Self.mirrorLevelDb
                    }
                    // Skirt within 4 baud, short of any neighbour: keying skirt bumps vanish in the
                    // smoothed spectrum, while a neighbour keeps a lump of its own (and stops the reach).
                    if !take && off <= outer { take = line.hz < upperStop && line.hz > lowerStop }
                }
                if take {
                    groups[gi].members.append(li)
                    assigned[li] = true
                }
            }
        }

        // 2. PSK31 idle twins, paired across the whole band before any sideband merge: two lines
        //    31.25 ± 1.5 Hz apart, within 3 dB, with a deep dip between them. Left to right, so a chain
        //    of lines from neighbouring signals pairs signal by signal.
        let byFrequency = lines.indices.filter { !assigned[$0] }.sorted { lines[$0].hz < lines[$1].hz }
        for (n, i) in byFrequency.enumerated() where !assigned[i] {
            var best: Int?
            var bestError = Double.infinity
            for j in byFrequency[(n + 1)...] where !assigned[j] {
                let d = lines[j].hz - lines[i].hz
                if d > Self.twinSpacingHz + Self.twinTightToleranceHz { break }
                let error = abs(d - Self.twinSpacingHz)
                guard error <= Self.twinTightToleranceHz, abs(lines[i].db - lines[j].db) <= Self.twinLevelDb,
                      error < bestError, isLineLike(lines[i]), isLineLike(lines[j]),
                      hasCentreDip(lines[i], lines[j]) else { continue }
                best = j
                bestError = error
            }
            guard let j = best else { continue }
            let (anchor, partner) = lines[i].power >= lines[j].power ? (i, j) : (j, i)
            groups.append(Group(kind: .twin, members: [anchor, partner], twin: partner))
            assigned[i] = true
            assigned[j] = true
        }

        // 3. Remaining brief peaks (±5-bin maxima), strongest first.
        let byPower = lines.indices.filter { !assigned[$0] && lines[$0].isPeak }
            .sorted { lines[$0].power > lines[$1].power }
        for pi in byPower {
            let p = lines[pi]
            // a. Sideband: within ±20 Hz of a stronger signal's main line.
            var bestGroup: Int?
            var bestDistance = Double.infinity
            for (gi, g) in groups.enumerated() where g.kind != .fsk {
                let mains = [g.members[0]] + (g.twin.map { [$0] } ?? [])
                for l in mains {
                    let d = abs(lines[l].hz - p.hz)
                    if d <= Self.sidebandHz && d < bestDistance { bestDistance = d; bestGroup = gi }
                }
            }
            if let gi = bestGroup {
                groups[gi].members.append(pi)
                continue
            }
            // a2. Hump structure: a similar-level peak up to 31.25 + 4 Hz from a stronger single's
            //     anchor with only a shallow dip between belongs to it (a PSK31 data spectrum often
            //     shows two tops ±10-16 Hz from its carrier). Two signals 40 Hz apart are not affected.
            bestDistance = .infinity
            for (gi, g) in groups.enumerated() where g.kind == .single {
                let a = lines[g.members[0]]
                let d = abs(a.hz - p.hz)
                if d <= Self.twinSpacingHz + Self.twinToleranceHz && a.db - p.db <= Self.twinLevelDb
                    && !hasCentreDip(a, p) && d < bestDistance {
                    bestDistance = d
                    bestGroup = gi
                }
            }
            if let gi = bestGroup {
                groups[gi].members.append(pi)
                continue
            }
            // b. Looser twin for a line the tight pass missed (noise at low SNR), still with a dip.
            bestDistance = .infinity
            for (gi, g) in groups.enumerated() where g.kind == .single {
                let a = lines[g.members[0]]
                let d = abs(a.hz - p.hz)
                if abs(d - Self.twinSpacingHz) <= Self.twinToleranceHz && a.db - p.db <= Self.pairLevelDb
                    && d < bestDistance && isLineLike(a) && isLineLike(p) && hasCentreDip(a, p) {
                    bestDistance = d
                    bestGroup = gi
                }
            }
            if let gi = bestGroup {
                groups[gi].kind = .twin
                groups[gi].twin = pi
                groups[gi].members.append(pi)
                continue
            }
            // c. No valley: joined to the nearest stronger line without dipping 3 dB below this one.
            var nearest: (group: Int, line: Int)?
            var nearestDistance = Int.max
            for (gi, g) in groups.enumerated() {
                for m in g.members where abs(lines[m].bin - p.bin) < nearestDistance {
                    nearestDistance = abs(lines[m].bin - p.bin)
                    nearest = (gi, m)
                }
            }
            if let (gi, m) = nearest {
                let lo = min(lines[m].bin, p.bin), hi = max(lines[m].bin, p.bin)
                var dip = Float.infinity
                if hi - lo > 1 { for k in (lo + 1)..<hi { dip = min(dip, avg[k]) } }
                if dip >= p.power * pow(10, -Self.valleyDb / 10) {
                    groups[gi].members.append(pi)
                    continue
                }
            }
            groups.append(Group(kind: .single, members: [pi], twin: nil))
        }
        return groups
    }

    /// A pure tone through the Hann window: the bin two away falls at least 10 dB on one side or the
    /// other (the near side may hold a neighbouring line 3 bins away). A PSK31 data hump's top is flat.
    private func isLineLike(_ line: Peak) -> Bool {
        let k = line.bin
        let left = db(avg[k]) - db(avg[k - 2]), right = db(avg[k]) - db(avg[k + 2])
        return max(left, right) >= Self.lineSteepDb
    }

    /// True when the spectrum between two lines dips at least `twinDipDb` below the weaker one, as it
    /// does at the suppressed carrier of a PSK31 idle (and not on a data hump).
    private func hasCentreDip(_ a: Peak, _ b: Peak) -> Bool {
        let lo = min(a.bin, b.bin), hi = max(a.bin, b.bin)
        guard hi - lo > 1 else { return false }
        var dip = Float.infinity
        for k in (lo + 1)..<hi { dip = min(dip, avg[k]) }
        return dip <= min(a.power, b.power) * pow(10, -Self.twinDipDb / 10)
    }

    /// Level (dB) of the strongest brief peak within `lumpSupportHz` of each frequency.
    private func toneLevels(_ hz: [Double], _ lines: [Peak]) -> [Float] {
        hz.map { f in lines.filter { $0.isPeak && abs($0.hz - f) <= Self.lumpSupportHz }.map(\.db).max() ?? -300 }
    }

    /// Validates a lump pair as one FSK signal rather than two independent signals ~170 Hz apart.
    /// 1. Nothing independent between the tones: no peak or lump in the middle (more than
    ///    `lumpSupportHz` from both tones) within `fskMiddleDb` of the weaker tone.
    /// 2. Mark and space are mutually exclusive in time: their short-time energies over the last
    ///    2 s of audio must be anticorrelated. A 31.25 Hz notch on the energies stops two PSK31
    ///    signals' symbol-rate ripples from faking the anticorrelation.
    private func isFSK(low: Lump, high: Lump, lines: [Peak], lumps: [Lump]) -> Bool {
        let tones = toneLevels([low.hz, high.hz], lines)
        let weakerTone = tones.min() ?? -300
        let middle = (low.hz + Self.lumpSupportHz)...(high.hz - Self.lumpSupportHz)
        guard !middle.isEmpty else { return false }
        if lines.contains(where: { $0.isPeak && middle.contains($0.hz) && $0.db > weakerTone - Self.fskMiddleDb }) {
            return false
        }
        let weakerLump = min(low.db, high.db)
        if lumps.contains(where: { middle.contains($0.hz) && $0.db > weakerLump - Self.fskMiddleDb }) { return false }
        guard let correlation = envelopeCorrelation(low.hz, high.hz) else { return false }
        // Stricter while the history is short and the estimate noisier (sd ∝ 1/√length).
        let threshold = max(Self.fskStrictestCorrelation,
                            Self.fskMaxEnvelopeCorrelation
                                * Float((Double(Self.fskHistorySamples) / Double(historyCount)).squareRoot()))
        return correlation <= threshold
    }

    /// Pearson correlation of the short-time energies at two audio frequencies over the audio history.
    func envelopeCorrelation(_ hz1: Double, _ hz2: Double) -> Float? {
        let cap = history.count
        let n = historyCount
        guard n >= Self.minFSKHistorySamples else { return nil }
        let d = Self.envelopeDecimation
        let m = n / d
        let start = (historyWrite - n + cap) % cap
        // Per tone: mix to baseband, decimate by block sums, a 16 ms boxcar band-pass (−21 dB at the
        // other tone), band power, a narrow notch at 31.25 Hz that removes PSK31's symbol-rate power
        // ripple (the only periodic component two independent PSK31 signals can share), then an
        // 8 ms average. RTTY keying (≤ 22.7 Hz) passes almost untouched.
        let bandpass = Self.envelopeBandpassSamples, average = Self.envelopeAverageSamples
        func energies(_ hz: Double) -> [Double] {
            var zr = [Double](repeating: 0, count: m), zi = [Double](repeating: 0, count: m)
            let w = 2 * Double.pi * hz / sampleRate
            let cw = cos(w), sw = sin(w)
            var c = 1.0, s = 0.0
            var idx = start
            for k in 0..<(m * d) {
                let x = Double(history[idx])
                idx += 1
                if idx == cap { idx = 0 }
                zr[k / d] += x * c
                zi[k / d] -= x * s
                let nc = c * cw - s * sw
                s = s * cw + c * sw
                c = nc
                if k & 1_023 == 1_023 {
                    let r = (c * c + s * s).squareRoot()
                    c /= r
                    s /= r
                }
            }
            guard m > bandpass + Self.envelopeSettleSamples + average else { return [] }
            // Band power after a 16 ms boxcar band-pass, then a notch at 31.25 Hz on the power.
            var power = [Double](repeating: 0, count: m - bandpass + 1)
            var ar = zr[0..<bandpass].reduce(0, +), ai = zi[0..<bandpass].reduce(0, +)
            for j in power.indices {
                if j > 0 {
                    ar += zr[j + bandpass - 1] - zr[j - 1]
                    ai += zi[j + bandpass - 1] - zi[j - 1]
                }
                power[j] = ar * ar + ai * ai
            }
            let w0 = 2 * Double.pi * Self.pskSymbolRateHz / (sampleRate / Double(d))
            let r = Self.envelopeNotchRadius
            let b1 = -2 * cos(w0), a1 = -2 * r * cos(w0), a2 = r * r
            var x1 = power[0], x2 = power[0], y1 = 0.0, y2 = 0.0
            var notched = [Double](repeating: 0, count: power.count)
            for j in power.indices {
                let y = power[j] + b1 * x1 + x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = power[j]; y2 = y1; y1 = y
                notched[j] = y
            }
            var out: [Double] = []
            var sum = notched[Self.envelopeSettleSamples..<(Self.envelopeSettleSamples + average)].reduce(0, +)
            var j = Self.envelopeSettleSamples
            while j + average <= notched.count {
                if (j - Self.envelopeSettleSamples) % Self.envelopeHop == 0 { out.append(sum) }
                if j + average < notched.count { sum += notched[j + average] - notched[j] }
                j += 1
            }
            return out
        }
        let e1 = energies(hz1), e2 = energies(hz2)
        let count = Double(e1.count)
        guard e1.count >= 8 else { return nil }
        let m1 = e1.reduce(0, +) / count, m2 = e2.reduce(0, +) / count
        var cov = 0.0, v1 = 0.0, v2 = 0.0
        for i in e1.indices {
            let a = e1[i] - m1, b = e2[i] - m2
            cov += a * b
            v1 += a * a
            v2 += b * b
        }
        guard v1 > 0, v2 > 0 else { return nil }
        return Float(cov / (v1 * v2).squareRoot())
    }

    private func findLumps(_ lines: [Peak]) -> [Lump] {
        let r = Self.lumpRadiusBins
        let lo = lowBin - Self.lumpLocalMaxBins, hi = highBin + Self.lumpLocalMaxBins
        for k in lo...hi {
            var s: Float = 0
            for j in -r...r { s += gaussian[j + r] * avg[k + j] }
            smooth[k] = s
        }
        var lumps: [Lump] = []
        for k in lowBin...highBin where smooth[k] > Self.lumpThreshold * floor[k] {
            guard isLocalMax(smooth, k, radius: Self.lumpLocalMaxBins) else { continue }
            let (delta, level) = interpolate(smooth, k)
            let hz = (Double(k) + delta) * binHz
            guard lines.contains(where: { $0.isPeak && abs($0.hz - hz) <= Self.lumpSupportHz }) else { continue }
            lumps.append(Lump(bin: k, hz: hz, db: level))
        }
        return lumps
    }

    // MARK: - Measurement

    private func measure(_ groups: [Group], _ peaks: [Peak]) -> [Detection] {
        for k in owner.indices { owner[k] = -1 }
        var nextExcluded = [Bool](repeating: false, count: excluded.count)
        // Expansion limits: never across the deepest point between neighbouring signals.
        let memberBins: [[Int]] = groups.map { g in g.members.map { peaks[$0].bin } + g.lumpBins }
        let order = groups.indices.sorted { (memberBins[$0].min() ?? 0) < (memberBins[$1].min() ?? 0) }
        var lowLimit = [Int](repeating: lowBin, count: groups.count)
        var highLimit = [Int](repeating: highBin, count: groups.count)
        for (a, b) in zip(order, order.dropFirst()) {
            let left = memberBins[a].max() ?? 0, right = memberBins[b].min() ?? 0
            guard right - left > 1 else {
                highLimit[a] = left
                lowLimit[b] = right
                continue
            }
            var cut = left + 1
            for k in (left + 1)..<right where avg[k] < avg[cut] { cut = k }
            highLimit[a] = cut
            lowLimit[b] = cut + 1
        }

        var detections: [Detection] = []
        for gi in groups.indices {
            let g = groups[gi]
            let bins = memberBins[gi]
            guard !bins.isEmpty else { continue }
            var lo = max(lowLimit[gi], lowBin), hi = min(highLimit[gi], highBin)
            if g.kind == .fsk {
                let reach = g.fskHalfShiftHz + Self.fskSplatterBauds * Self.rttyBaud
                lo = max(lo, Int(((g.fskCentreHz - reach) / binHz).rounded(.down)))
                hi = min(hi, Int(((g.fskCentreHz + reach) / binHz).rounded(.up)))
            } else {
                let reach = Int((Self.regionBeyondMembersHz / binHz).rounded())
                lo = max(lo, bins.min()! - reach)
                hi = min(hi, bins.max()! + reach)
            }
            // Walk out from each member line while the spectrum stays 3 dB over the floor, then take
            // the hull so noisy dips inside a spread signal (PSK data, RTTY keying) still count.
            var runLow = Int.max, runHigh = Int.min
            for m in bins where m >= lo && m <= hi {
                var k = m
                while k - 1 >= lo && avg[k - 1] > Self.regionThreshold * floor[k - 1] { k -= 1 }
                runLow = min(runLow, max(k - 1, lo))
                k = m
                while k + 1 <= hi && avg[k + 1] > Self.regionThreshold * floor[k + 1] { k += 1 }
                runHigh = max(runHigh, min(k + 1, hi))
            }
            if g.kind == .fsk {
                let inner = g.fskHalfShiftHz + Self.rttyBaud
                runLow = min(runLow, max(lo, Int(((g.fskCentreHz - inner) / binHz).rounded(.down))))
                runHigh = max(runHigh, min(hi, Int(((g.fskCentreHz + inner) / binHz).rounded(.up))))
            }
            guard runLow <= runHigh else { continue }
            var region: [Int] = []
            for k in runLow...runHigh where owner[k] == -1 {
                owner[k] = gi
                region.append(k)
            }
            guard !region.isEmpty else { continue }

            // Noise reference for SNR: a wide median of non-signal bins, far steadier than the local floor.
            let floorMean = Double(noiseReference(aroundBin: (runLow + runHigh) / 2))
            let fRef = Float(floorMean)
            var excess = 0.0, rawExcess = 0.0, peakPower: Float = 0
            for k in region {
                excess += Double(avg[k] - fRef)
                rawExcess += Double(raw[k] - fRef)
                peakPower = max(peakPower, avg[k])
            }
            let snr = 10 * log10(max(excess, 1e-30) / (floorMean * Self.noiseBandwidthHz / binHz))

            // Bandwidth at max(peak − 20 dB, floor + 6 dB), edges interpolated in dB.
            let level = max(peakPower * 0.01, Self.peakThreshold * Float(floorMean))
            var bandwidth = binHz
            if let first = region.first(where: { avg[$0] >= level }),
               let last = region.last(where: { avg[$0] >= level }) {
                func fraction(_ inside: Int, _ outside: Int) -> Double {
                    let a = db(avg[inside]), b = db(avg[outside]), t = db(level)
                    guard a > b else { return 0 }
                    return Double(min(max((a - t) / (a - b), 0), 1))
                }
                let left = Double(first) - fraction(first, first - 1)
                let right = Double(last) + fraction(last, last + 1)
                bandwidth = max(right - left, 1) * binHz
            }

            let centre: Double
            switch g.kind {
            case .fsk:
                centre = g.fskCentreHz
            case .twin:
                centre = (peaks[g.members[0]].hz + peaks[g.twin!].hz) / 2
            case .single:
                if bandwidth <= Self.lineBandwidthHz {
                    centre = peaks[g.members[0]].hz
                } else {
                    var wsum = 0.0, fsum = 0.0
                    for k in region {
                        let w = Double(max(avg[k] - fRef, 0))
                        wsum += w
                        fsum += w * Double(k)
                    }
                    centre = wsum > 0 ? fsum / wsum * binHz : peaks[g.members[0]].hz
                }
            }
            let offsets = g.members.map { peaks[$0].hz - centre }.filter { abs($0) >= binHz }.sorted()
            let active = excess > 0 && Float(rawExcess) >= Self.activityFraction * Float(excess)
            detections.append(Detection(centreHz: centre, snrDb: Float(snr), bandwidthHz: bandwidth,
                                        isFSK: g.kind == .fsk, offsetsHz: offsets, active: active))
            // Keep the whole signal (plus a guard) out of the next frame's floor estimate.
            for k in max(runLow - 3, 0)...min(runHigh + 3, nextExcluded.count - 1) { nextExcluded[k] = true }
        }
        excluded = nextExcluded
        return detections
    }

    // MARK: - Association and lifecycle

    /// Greedy nearest-first matching of detections to frequencies within ±10 Hz.
    private func match(_ frequencies: [Double], _ detections: [Detection], available: [Bool]) -> [(Int, Int)] {
        var pairs: [(Double, Int, Int)] = []
        for (fi, f) in frequencies.enumerated() {
            for (di, d) in detections.enumerated() where available[di] {
                let distance = abs(d.centreHz - f)
                if distance <= Self.associateHz { pairs.append((distance, fi, di)) }
            }
        }
        pairs.sort { $0.0 < $1.0 }
        var usedF = Set<Int>(), usedD = Set<Int>()
        var result: [(Int, Int)] = []
        for (_, fi, di) in pairs where !usedF.contains(fi) && !usedD.contains(di) {
            usedF.insert(fi)
            usedD.insert(di)
            result.append((fi, di))
        }
        return result
    }

    private func associate(_ detections: [Detection]) {
        let now = samplesSeen
        var available = [Bool](repeating: true, count: detections.count)
        let alpha = Self.frequencyAlpha

        let continuitySamples = Int(Self.continuitySeconds * sampleRate)
        var matchedTracks = Set<Int>()
        for (ti, di) in match(confirmed.map(\.frequencyHz), detections, available: available) {
            available[di] = false
            let d = detections[di]
            let id = confirmed[ti].id
            matchedTracks.insert(id)
            let streak = d.active ? (streaks[id] ?? 0) + 1 : 0
            streaks[id] = streak
            // A track that has been idle only revives on sustained energy, exactly like a new
            // candidate, so isolated noise peaks near a quiet track neither move it nor keep it alive.
            let live = now - confirmed[ti].lastActiveSample <= continuitySamples
            guard live || streak >= Self.confirmFrames else { continue }
            confirmed[ti].frequencyHz += alpha * (d.centreHz - confirmed[ti].frequencyHz)
            confirmed[ti].snrDb = d.snrDb
            confirmed[ti].bandwidthHz = d.bandwidthHz
            confirmed[ti].isFSKPair = d.isFSK
            confirmed[ti].peakOffsetsHz = d.offsetsHz
            if d.active { confirmed[ti].lastActiveSample = now }
        }
        for t in confirmed where !matchedTracks.contains(t.id) { streaks[t.id] = 0 }

        var matchedCandidates = Set<Int>()
        for (ci, di) in match(candidates.map(\.frequencyHz), detections, available: available) {
            available[di] = false
            matchedCandidates.insert(ci)
            let d = detections[di]
            candidates[ci].frequencyHz += alpha * (d.centreHz - candidates[ci].frequencyHz)
            candidates[ci].hits += 1
            candidates[ci].detection = d
            if d.active { candidates[ci].lastActiveSample = now }
        }
        // Candidates must be seen in consecutive frames.
        var survivors: [Candidate] = []
        for (ci, c) in candidates.enumerated() where matchedCandidates.contains(ci) {
            if c.hits >= Self.confirmFrames {
                let d = c.detection
                confirmed.append(Track(id: nextID, frequencyHz: c.frequencyHz, snrDb: d.snrDb,
                                       bandwidthHz: d.bandwidthHz, firstSeenSample: c.firstSeenSample,
                                       lastActiveSample: c.lastActiveSample, isQuiet: false,
                                       isFSKPair: d.isFSK, peakOffsetsHz: d.offsetsHz))
                nextID += 1
            } else {
                survivors.append(c)
            }
        }
        for (di, d) in detections.enumerated() where available[di] {
            survivors.append(Candidate(frequencyHz: d.centreHz, hits: 1, firstSeenSample: now,
                                       lastActiveSample: now, detection: d))
        }
        candidates = survivors

        // Tracks that converged onto one signal merge into the older id.
        confirmed.sort { $0.id < $1.id }
        var merged: [Track] = []
        for t in confirmed {
            if let i = merged.firstIndex(where: { abs($0.frequencyHz - t.frequencyHz) < Self.associateHz }) {
                merged[i].lastActiveSample = max(merged[i].lastActiveSample, t.lastActiveSample)
                merged[i].firstSeenSample = min(merged[i].firstSeenSample, t.firstSeenSample)
                streaks[t.id] = nil
            } else {
                merged.append(t)
            }
        }

        let quietSamples = Int(Self.quietAfterSeconds * sampleRate)
        let removeSamples = Int(Self.removeAfterSeconds * sampleRate)
        confirmed = merged.compactMap { t in
            let idle = now - t.lastActiveSample
            guard idle <= removeSamples else { streaks[t.id] = nil; return nil }
            var t = t
            t.isQuiet = idle > quietSamples
            return t
        }
        confirmed.sort { $0.frequencyHz < $1.frequencyHz }
    }
}
