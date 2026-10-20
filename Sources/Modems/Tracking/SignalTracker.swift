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
///    interpolation.
/// 4. Grouping into signals: FSK pairs (lumps 170 ± 15 Hz apart within 6 dB) absorb their keying
///    lines; then remaining peaks within ±20 Hz of a stronger signal's line, or joined to it with no
///    3 dB valley, are its sidebands; a PSK31 idle twin (two lines 31.25 ± 4 Hz apart within 6 dB) is one
///    signal centred between them.
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
    static let sidebandHz = 20.0
    static let twinSpacingHz = 31.25                        // BPSK31 idle: ±15.625 Hz
    static let twinToleranceHz = 4.0
    static let pairLevelDb: Float = 6
    static let fskShiftHz = 170.0
    static let fskShiftToleranceHz = 15.0
    static let rttyBaud = 45.45
    /// Keying lines beyond shift/2 + 1 baud are absorbed only when this far below the weaker tone.
    static let fskSplatterDb: Float = 12
    static let fskSplatterBauds = 4.0
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
        var peaks: [Peak] = []
        for k in lowBin...highBin where avg[k] > Self.peakThreshold * floor[k] {
            guard isLocalMax(avg, k, radius: Self.localMaxBins) else { continue }
            let (delta, level) = interpolate(avg, k)
            peaks.append(Peak(bin: k, hz: (Double(k) + delta) * binHz, power: pow(10, level / 10), db: level))
        }
        return peaks
    }

    // MARK: - Grouping

    private func groupPeaks(_ peaks: [Peak]) -> [Group] {
        var groups: [Group] = []
        var assigned = [Bool](repeating: false, count: peaks.count)

        // 1. FSK pairs, found on a Gaussian-smoothed spectrum so each tone's keying lines form one lump.
        let lumps = findLumps(peaks)
        var lumpUsed = [Bool](repeating: false, count: lumps.count)
        let order = lumps.indices.sorted { lumps[$0].db > lumps[$1].db }
        func insideFSK(_ hz: Double) -> Bool {
            groups.contains { $0.kind == .fsk && abs(hz - $0.fskCentreHz) <= $0.fskHalfShiftHz + Self.rttyBaud }
        }
        for li in order where !lumpUsed[li] && !insideFSK(lumps[li].hz) {
            var best: Int?
            for mi in order where mi != li && !lumpUsed[mi] && !insideFSK(lumps[mi].hz) {
                let spacing = abs(lumps[mi].hz - lumps[li].hz)
                guard abs(spacing - Self.fskShiftHz) <= Self.fskShiftToleranceHz,
                      abs(lumps[mi].db - lumps[li].db) <= Self.pairLevelDb else { continue }
                if best == nil || lumps[mi].db > lumps[best!].db { best = mi }
            }
            guard let mi = best else { continue }
            lumpUsed[li] = true
            lumpUsed[mi] = true
            let lo = min(lumps[li].hz, lumps[mi].hz), hi = max(lumps[li].hz, lumps[mi].hz)
            groups.append(Group(kind: .fsk, members: [], twin: nil, fskCentreHz: (lo + hi) / 2,
                                fskHalfShiftHz: (hi - lo) / 2, lumpBins: [lumps[li].bin, lumps[mi].bin]))
        }
        // Absorb each FSK pair's tone and keying lines.
        for gi in groups.indices {
            let g = groups[gi]
            let toneDb = g.lumpBins.map { lb -> Float in
                let hz = Double(lb) * binHz
                return peaks.filter { abs($0.hz - hz) <= Self.lumpSupportHz }.map(\.db).max() ?? -300
            }
            let weakerTone = toneDb.min() ?? -300
            for pi in peaks.indices where !assigned[pi] {
                let off = abs(peaks[pi].hz - g.fskCentreHz)
                let inner = off <= g.fskHalfShiftHz + Self.rttyBaud
                let splatter = off <= g.fskHalfShiftHz + Self.fskSplatterBauds * Self.rttyBaud
                    && peaks[pi].db <= weakerTone - Self.fskSplatterDb
                if inner || splatter {
                    groups[gi].members.append(pi)
                    assigned[pi] = true
                }
            }
        }

        // 2. Remaining peaks, strongest first.
        let byPower = peaks.indices.filter { !assigned[$0] }.sorted { peaks[$0].power > peaks[$1].power }
        for pi in byPower {
            let p = peaks[pi]
            // a. Sideband: within ±20 Hz of a stronger signal's main line.
            var bestGroup: Int?
            var bestDistance = Double.infinity
            for (gi, g) in groups.enumerated() where g.kind != .fsk {
                let lines = [g.members[0]] + (g.twin.map { [$0] } ?? [])
                for l in lines {
                    let d = abs(peaks[l].hz - p.hz)
                    if d <= Self.sidebandHz && d < bestDistance { bestDistance = d; bestGroup = gi }
                }
            }
            if let gi = bestGroup {
                groups[gi].members.append(pi)
                continue
            }
            // b. PSK31 idle twin: a line 31.25 ± 4 Hz from a similar-level anchor.
            bestDistance = .infinity
            for (gi, g) in groups.enumerated() where g.kind == .single {
                let a = peaks[g.members[0]]
                let d = abs(a.hz - p.hz)
                if abs(d - Self.twinSpacingHz) <= Self.twinToleranceHz && a.db - p.db <= Self.pairLevelDb
                    && d < bestDistance {
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
            // c. No valley: joined to the nearest stronger peak without dipping 3 dB below this one.
            var nearest: (group: Int, peak: Int)?
            var nearestDistance = Int.max
            for (gi, g) in groups.enumerated() {
                for m in g.members where abs(peaks[m].bin - p.bin) < nearestDistance {
                    nearestDistance = abs(peaks[m].bin - p.bin)
                    nearest = (gi, m)
                }
            }
            if let (gi, m) = nearest {
                let lo = min(peaks[m].bin, p.bin), hi = max(peaks[m].bin, p.bin)
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

    private func findLumps(_ peaks: [Peak]) -> [Lump] {
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
            guard peaks.contains(where: { abs($0.hz - hz) <= Self.lumpSupportHz }) else { continue }
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
