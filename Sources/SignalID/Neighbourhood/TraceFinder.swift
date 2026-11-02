import Accelerate
import Foundation

/// One narrow line around the point (or a few close tones that hop, such as FT8's), and when it is on.
struct SignalTrace: Equatable {
    /// Relative to the capture centre.
    var lowerHz: Double
    var upperHz: Double
    /// Its power over the noise in its own width.
    var snrDb: Double
    /// Seconds within the read.
    var onTimes: [ClosedRange<Double>]
    /// A line that neither keys nor hops: narrow, and on for the whole read.
    var steady: Bool
}

/// A wider occupied stretch (voice, AM, OFDM, FM): only its edges mean anything.
struct OccupiedArea: Equatable {
    /// Relative to the capture centre.
    var lowerHz: Double
    var upperHz: Double
    var snrDb: Double
    var onTimes: [ClosedRange<Double>]
}

/// What lies around the point.
struct NeighbourhoodView {
    var traces: [SignalTrace]
    var areas: [OccupiedArea]
    /// The noise level over the read, in dB relative to 1 per Hz.
    var noiseDb: Double
}

/// Reads a `TimeFrequencyMap`: which frequencies hold something, and whether that is a narrow line or a wider area.
///
/// Each bin's power is averaged over the read (noise averages 0 dB in every bin, whatever the receiver's gain did; in a
/// view too crowded for that, `quietLevel` puts it right).
/// **Areas** come from that smoothed over about 100 Hz: at least 500 Hz above 3 dB and 6 dB somewhere. A stretch of
/// separate lines in deep valleys that holds its power steady from moment to moment isn't one (a band of FT8 stations):
/// a voice's power comes in syllables, and a wideband mode has no valleys. **Traces** are the rest, from the average
/// smoothed over about 40 Hz: above 3 dB, and either a bin 8 dB up or, for one wide enough not to be a single line,
/// 4.5 dB up smoothed. So the faint steady lines a real band holds (real lines, but 6.4 dB at most at this resolution
/// on the corpus's tuning part, and 3.6 dB smoothed) aren't reported.
///
/// What the read's few noisy seconds can't show (a weak trace, a voice 3 dB over the noise) simply isn't here: the
/// answer for it is `Too weak` or `No signal`.
enum TraceFinder {
    /// Averaged bins smoothed over this many bins each side, for traces (with 8 Hz bins, 40 Hz in all).
    static let traceReachHz = 16.0
    /// For areas (about 100 Hz in all).
    static let areaReachHz = 48.0
    static let quietShare = 0.05
    static let quietBelowDb = 3.0
    static let edgeDb = 3.0
    static let lineDb = 8.0
    static let plateauDb = 4.5
    /// A trace's own width counts for `plateauDb` from this many Hz.
    static let plateauMinHz = 32.0
    static let areaMinHz = 500.0
    static let areaDetectDb = 6.0
    /// A trace's edges: where its bins fall to this far under its strongest.
    static let edgeBelowPeakDb = 15.0
    /// Two peaks with a valley this deep under the weaker of them are two signals.
    static let valleyDb = 6.0
    static let valleyTopDb = 6.0
    /// Two neighbouring traces' power correlated at this or under takes turns, as far apart as this. A clean FSK's
    /// measure −0.9; separate stations on the corpus's tuning part stayed over −0.46.
    static let turnsCorrelation = -0.5
    static let turnsReachHz = 1500.0
    /// An FSK's tones stand about alike. (FM's carrier and sidebands take turns too, far apart in level.)
    static let turnsWithinDb = 10.0
    /// How alike the two sides of a signal's sidebands are, in where they lie and how wide.
    static let sidebandMatch = 0.1
    /// An area's sidebands stand this far under it; a line's, when they are lines too, as AM's by a tone do.
    static let sidebandUnderAreaDb = 3.0
    static let lineSidebandBelowDb = 5.0
    /// A line's sidebands start this near it and, when wider than lines, stand this far under it (`hasSidebands`).
    static let sidebandReachHz = 1000.0
    static let sidebandBelowLineDb = 15.0
    static let lineSidebandHz = 16.0
    static let lineSidebandMatchDb = 3.0
    static let wideSidebandHz = 40.0
    static let wideSidebandShare = 0.3
    static let wideSidebandWidths = 2.2
    /// A trace this far up isn't a weak signal's (`isClear`).
    static let clearDb = 10.0
    /// A stretch of at least this many separated lines, with steady power, is a band of them.
    static let bandMinLines = 3
    /// How evenly an MFSK's tones are spaced, and how much of each step a tone fills.
    static let toneGridTolerance = 0.1
    static let toneMinFill = 0.5
    /// A line this far under the strongest is no tone of theirs.
    static let toneRangeDb = 10.0
    /// The median change in a band's power between moments that don't overlap, under which it counts as steady.
    static let steadyChangeDb = 1.0
    /// As wide as a line reads: the main lobe of a Hann window 125 ms long.
    static let steadyMaxHz = 32.0
    static let steadyOnShare = 0.9
    /// On-time under this is a click, not a signal.
    static let minOnSeconds = 0.3
    /// On-time: a band's moments over the geometric mean of its low and high levels, gaps of this many rows bridged;
    /// when those levels stand under this ratio it is on or off as a whole.
    static let onContrast = 4.0
    static let bridgeRows = 2

    static func find(_ map: TimeFrequencyMap) -> NeighbourhoodView {
        let noise = median(map.noiseDbPerHz)
        guard map.rows > 0, map.bins >= 16 else { return NeighbourhoodView(traces: [], areas: [], noiseDb: Double(noise)) }
        var power = map.meanPower()
        let areaReach = Int((areaReachHz / map.binHz).rounded())
        let quiet = quietLevel(smoothed(power, reach: areaReach))
        if quiet != 1 { power = power.map { $0 / quiet } }
        let fine = smoothed(power, reach: Int((traceReachHz / map.binHz).rounded()))
        let coarse = smoothed(power, reach: areaReach)
        let edge = linear(edgeDb)

        var areas: [OccupiedArea] = []
        var taken: [ClosedRange<Int>] = []
        for run in runs(coarse, above: edge) where Double(run.count) * map.binHz >= areaMinHz {
            guard run.map({ coarse[$0] }).max()! >= linear(areaDetectDb) else { continue }
            guard !isBandOfLines(run, map: map, power: power, fine: fine) else { continue }
            let onTimes = self.onTimes(run, map: map, quiet: quiet)
            guard total(onTimes) >= minOnSeconds else { continue }
            areas.append(OccupiedArea(lowerHz: map.offsetHz(Double(run.lowerBound)), upperHz: map.offsetHz(Double(run.upperBound)),
                                      snrDb: snr(power, run), onTimes: onTimes))
            taken.append(run)
        }

        var traces: [SignalTrace] = []
        for run in runs(fine, above: edge) where !taken.contains(where: { $0.overlaps(run) }) {
            for piece in split(run, fine: fine) {
                guard let bins = traceBins(piece, power: power, fine: fine, map: map) else { continue }
                let onTimes = self.onTimes(bins, map: map, quiet: quiet)
                guard total(onTimes) >= minOnSeconds else { continue }
                let width = Double(bins.count - 1) * map.binHz
                let seconds = map.frameSeconds + Double(map.rows - 1) * map.hopSeconds
                traces.append(SignalTrace(lowerHz: map.offsetHz(Double(bins.lowerBound)),
                                          upperHz: map.offsetHz(Double(bins.upperBound)), snrDb: snr(power, bins),
                                          onTimes: onTimes,
                                          steady: width <= steadyMaxHz && total(onTimes) >= steadyOnShare * seconds))
            }
        }
        return NeighbourhoodView(traces: traces, areas: joiningSidebands(areas),
                                 noiseDb: Double(noise) + 10 * log10(Double(quiet)))
    }

    // MARK: Pieces

    /// What the map's quietest stretches read, when that is well under its noise level: a view so crowded that even a
    /// row's 20th percentile lies among signals (stations 10 kHz apart with 2 kHz gaps) has its true noise in those gaps.
    /// 1 otherwise: a real band's ripple is a dB or so.
    static func quietLevel(_ coarse: [Float]) -> Float {
        var sorted = coarse
        vDSP_vsort(&sorted, vDSP_Length(sorted.count), 1)
        let quiet = sorted[Int(quietShare * Double(sorted.count))]
        return quiet < linear(-quietBelowDb) ? max(quiet, 1e-6) : 1
    }

    /// Whether two traces' power runs against each other from moment to moment: one signal's tones.
    static func takeTurns(_ a: SignalTrace, _ b: SignalTrace, map: TimeFrequencyMap) -> Bool {
        correlation(a.lowerHz...a.upperHz, b.lowerHz...b.upperHz, map: map) <= turnsCorrelation
    }

    /// The correlation of two bands' power over the rows.
    static func correlation(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>, map: TimeFrequencyMap) -> Double {
        func band(_ hz: ClosedRange<Double>) -> ClosedRange<Int>? {
            let low = max(0, map.bin(hz.lowerBound)), high = min(map.bins - 1, map.bin(hz.upperBound))
            return low <= high ? low...high : nil
        }
        guard let bandA = band(a), let bandB = band(b), map.rows >= 8 else { return 0 }
        let x = map.bandPower(bandA), y = map.bandPower(bandB)
        var meanX: Float = 0, meanY: Float = 0
        vDSP_meanv(x, 1, &meanX, vDSP_Length(x.count))
        vDSP_meanv(y, 1, &meanY, vDSP_Length(y.count))
        var xy = 0.0, xx = 0.0, yy = 0.0
        for k in x.indices {
            let dx = Double(x[k] - meanX), dy = Double(y[k] - meanY)
            xy += dx * dy
            xx += dx * dx
            yy += dy * dy
        }
        return xx > 0 && yy > 0 ? xy / (xx * yy).squareRoot() : 0
    }

    /// A trace that says plainly it is its own signal, in `tooWeak`'s window: as narrow as a line, or well up. What is
    /// left of a weak voice reads as pieces wider and fainter than that.
    static func isClear(_ trace: SignalTrace) -> Bool {
        trace.upperHz - trace.lowerHz <= steadyMaxHz || trace.snrDb >= clearDb
    }

    /// Something the view holds besides a given line.
    struct Neighbour {
        var lower, upper, snrDb: Double
        var isLine: Bool { upper - lower <= steadyMaxHz }
    }

    /// Whether two neighbours, `down` and `up` Hz from a line, could be its sidebands: mirror images about it.
    /// - Lines (AM by a steady tone): at the same distance to within two map bins and the same strength to within 3 dB.
    ///   Only by construction do separate stations line up so closely.
    /// - Anything wider (voice on narrow FM, data on AM): at the same distance to within `wideSidebandShare` or five map
    ///   bins, and as wide as each other to within twice. Their edges are where a fading level crosses a threshold.
    static func mirror(_ a: Neighbour, down: Double, _ b: Neighbour, up: Double) -> Bool {
        guard a.isLine == b.isLine else { return false }
        if a.isLine { return abs(down - up) <= lineSidebandHz && abs(a.snrDb - b.snrDb) <= lineSidebandMatchDb }
        let widthA = a.upper - a.lower, widthB = b.upper - b.lower
        return abs(down - up) <= max(wideSidebandHz, wideSidebandShare * max(down, up))
            && max(widthA, widthB) <= wideSidebandWidths * min(widthA, widthB)
    }

    /// Everything in the view but `line`, and when a line is given, without what it has for sidebands: from the line
    /// outwards, each pair that mirrors. The first thing with no mirror image is another signal, and so is all beyond it.
    static func beside(_ view: NeighbourhoodView, line: SignalTrace?) -> [Neighbour] {
        var all = view.traces.filter { $0 != line }.map { Neighbour(lower: $0.lowerHz, upper: $0.upperHz, snrDb: $0.snrDb) }
            + view.areas.map { Neighbour(lower: $0.lowerHz, upper: $0.upperHz, snrDb: $0.snrDb) }
        guard let line else { return all }
        let centre = (line.lowerHz + line.upperHz) / 2
        while let below = all.filter({ $0.upper < line.lowerHz }).max(by: { $0.upper < $1.upper }),
              let above = all.filter({ $0.lower > line.upperHz }).min(by: { $0.lower < $1.lower }),
              max(below.snrDb, above.snrDb) <= line.snrDb - lineSidebandBelowDb,
              mirror(below, down: centre - below.upper, above, up: above.lower - centre) {
            all.removeAll { $0.lower == below.lower || $0.lower == above.lower }
        }
        return all
    }

    /// Whether what lies next to a line, on each side, is its sidebands: under it, near it, and mirrored. Wider than lines
    /// they must stand well under it (voice on narrow FM, weak and broken up at 10 dB).
    static func hasSidebands(_ line: SignalTrace, _ view: NeighbourhoodView) -> Bool {
        let all = beside(view, line: nil), centre = (line.lowerHz + line.upperHz) / 2
        let rest = all.filter { $0.lower != line.lowerHz || $0.upper != line.upperHz }
        guard let below = rest.filter({ $0.upper < line.lowerHz }).max(by: { $0.upper < $1.upper }),
              let above = rest.filter({ $0.lower > line.upperHz }).min(by: { $0.lower < $1.lower }) else { return false }
        let down = centre - below.upper, up = above.lower - centre
        let under = line.snrDb - max(below.snrDb, above.snrDb)
        guard max(down, up) <= sidebandReachHz, mirror(below, down: down, above, up: up) else { return false }
        return below.isLine && above.isLine ? under >= lineSidebandBelowDb : under >= sidebandBelowLineDb
    }

    /// An area with a weaker one at the same distance each side holds its sidebands (FM carrying AFSK): one area.
    static func joiningSidebands(_ areas: [OccupiedArea]) -> [OccupiedArea] {
        var out = areas
        var k = 1
        while k < out.count - 1 {
            let low = out[k - 1], middle = out[k], high = out[k + 1]
            let centre = (middle.lowerHz + middle.upperHz) / 2
            let below = centre - low.upperHz, above = high.lowerHz - centre
            let widthLow = low.upperHz - low.lowerHz, widthHigh = high.upperHz - high.lowerHz
            guard abs(below - above) <= sidebandMatch * max(below, above),
                  abs(widthLow - widthHigh) <= sidebandMatch * max(widthLow, widthHigh),
                  max(low.snrDb, high.snrDb) <= middle.snrDb - sidebandUnderAreaDb else {
                k += 1
                continue
            }
            out.replaceSubrange((k - 1)...(k + 1), with: [
                OccupiedArea(lowerHz: low.lowerHz, upperHz: high.upperHz, snrDb: middle.snrDb, onTimes: middle.onTimes),
            ])
        }
        return out
    }

    static func linear(_ db: Double) -> Float { Float(pow(10, db / 10)) }

    static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        var sorted = values
        vDSP_vsort(&sorted, vDSP_Length(sorted.count), 1)
        return sorted[sorted.count / 2]
    }

    /// Each value the mean of those within `reach` of it.
    static func smoothed(_ x: [Float], reach: Int) -> [Float] {
        var sums = [Double](repeating: 0, count: x.count + 1)
        for k in x.indices { sums[k + 1] = sums[k] + Double(x[k]) }
        return x.indices.map { k in
            let lo = max(0, k - reach), hi = min(x.count - 1, k + reach)
            return Float((sums[hi + 1] - sums[lo]) / Double(hi - lo + 1))
        }
    }

    /// The contiguous stretches at or above `level`.
    static func runs(_ x: [Float], above level: Float) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        var start: Int?
        for k in x.indices {
            if x[k] >= level {
                if start == nil { start = k }
            } else if let s = start {
                out.append(s...(k - 1))
                start = nil
            }
        }
        if let s = start { out.append(s...(x.count - 1)) }
        return out
    }

    /// `run` cut at each valley `valleyDb` under the peaks either side that comes down near the noise (at most
    /// `valleyTopDb` over it). A valley still well up (an FSK's tones 170 Hz apart, each spilling towards the other) may
    /// be one signal's: that is for its measurement to say.
    static func split(_ run: ClosedRange<Int>, fine: [Float]) -> [ClosedRange<Int>] {
        let depth = linear(valleyDb), top = linear(valleyTopDb)
        var pieces: [ClosedRange<Int>] = []
        var start = run.lowerBound, peak = fine[start], valley = start
        for k in run.dropFirst() {
            if fine[k] < fine[valley] { valley = k }
            if valley > start, fine[valley] <= top, peak >= depth * fine[valley], fine[k] >= depth * fine[valley] {
                pieces.append(start...valley)
                start = valley
                peak = fine[k]
                valley = k
            } else if fine[k] > peak {
                peak = fine[k]
                valley = k
            }
        }
        pieces.append(start...run.upperBound)
        return pieces
    }

    /// The bins of a trace within `piece`, or nil when nothing in it stands out enough: tightened to where the raw
    /// average falls `edgeBelowPeakDb` under its strongest (the smoothing's own width left out).
    static func traceBins(_ piece: ClosedRange<Int>, power: [Float], fine: [Float],
                          map: TimeFrequencyMap) -> ClosedRange<Int>? {
        let top = piece.map { power[$0] }.max() ?? 0
        let edge = max(linear(edgeDb), top / linear(edgeBelowPeakDb))
        guard let lo = piece.first(where: { power[$0] >= edge }),
              let hi = piece.last(where: { power[$0] >= edge }) else { return nil }
        let wide = Double(hi - lo) * map.binHz >= plateauMinHz
        let plateau = piece.map { fine[$0] }.max() ?? 0
        guard top >= linear(lineDb) || (wide && plateau >= linear(plateauDb)) else { return nil }
        return lo...hi
    }

    /// Separate narrow lines (`split`), not the tones of one signal, whose total power holds steady.
    static func isBandOfLines(_ run: ClosedRange<Int>, map: TimeFrequencyMap, power: [Float], fine: [Float]) -> Bool {
        let lines = runs(Array(fine[run]), above: linear(edgeDb)).flatMap { piece -> [ClosedRange<Int>] in
            split((piece.lowerBound + run.lowerBound)...(piece.upperBound + run.lowerBound), fine: fine)
        }
        let tight = lines.compactMap { traceBins($0, power: power, fine: fine, map: map) }
        guard lines.count >= bandMinLines, !areTonesOfOneSignal(tight, power: power),
              tight.allSatisfy({ Double($0.count) * map.binHz < areaMinHz }) else { return false }
        return medianChangeDb(run, map: map) <= steadyChangeDb
    }

    /// An MFSK's tones (ALE's eight, 250 Hz apart at 125 Bd): evenly spaced, about as wide as the spaces they leave
    /// are not. Separate stations aren't so regular, and a slot mode's tracks are far narrower than their spacing.
    static func areTonesOfOneSignal(_ lines: [ClosedRange<Int>], power: [Float]) -> Bool {
        func strength(_ line: ClosedRange<Int>) -> Float { line.map { power[$0] }.max() ?? 0 }
        let strongest = lines.map(strength).max() ?? 0
        let tones = lines.filter { strength($0) >= strongest / linear(toneRangeDb) }
        guard tones.count >= bandMinLines else { return false }
        let centres = tones.map { Double($0.lowerBound + $0.upperBound) / 2 }
        let steps = zip(centres, centres.dropFirst()).map { $1 - $0 }
        let step = steps.reduce(0, +) / Double(steps.count)
        let width = tones.reduce(0.0) { $0 + Double($1.count) } / Double(tones.count)
        return steps.allSatisfy { abs($0 / step - 1) <= toneGridTolerance } && width >= toneMinFill * step
    }

    /// The median change of the band's power between moments a frame apart (so not sharing samples), in dB.
    static func medianChangeDb(_ band: ClosedRange<Int>, map: TimeFrequencyMap) -> Double {
        let levels = map.bandPower(band).map { 10 * log10(max($0, 1e-12)) }
        let apart = max(1, Int((map.frameSeconds / map.hopSeconds).rounded()))
        guard levels.count > apart else { return .infinity }
        let changes = (apart..<levels.count).map { abs(levels[$0] - levels[$0 - apart]) }
        return Double(median(changes))
    }

    static func snr(_ power: [Float], _ bins: ClosedRange<Int>) -> Double {
        let excess = bins.reduce(0.0) { $0 + Double(power[$1]) - 1 } / Double(bins.count)
        return 10 * log10(max(excess, 1e-6))
    }

    static func total(_ times: [ClosedRange<Double>]) -> Double { times.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }

    /// When `band` is on, in seconds within the read, with the map's noise taken to read `quiet`.
    static func onTimes(_ band: ClosedRange<Int>, map: TimeFrequencyMap, quiet: Float) -> [ClosedRange<Double>] {
        let levels = map.bandPower(band).map { $0 / quiet }
        guard !levels.isEmpty else { return [] }
        let sorted = levels.sorted()
        let low = max(sorted[levels.count / 10], 1), high = sorted[levels.count * 9 / 10]
        let threshold = high >= Float(onContrast) * low ? (low * high).squareRoot() : 1 + 0.5 * (low - 1)
        var out: [ClosedRange<Int>] = []
        var start: Int?, last = -1
        for (r, level) in levels.enumerated() where level >= threshold {
            if let s = start, r - last - 1 > bridgeRows {
                out.append(s...last)
                start = r
            } else if start == nil {
                start = r
            }
            last = r
        }
        if let s = start { out.append(s...last) }
        return out.map { Double($0.lowerBound) * map.hopSeconds...(Double($0.upperBound) * map.hopSeconds + map.frameSeconds) }
    }
}

extension TimeFrequencyMap {
    /// Each bin's mean power over the rows, as a share of the noise. `levelWeighted`: each row counted by its own noise
    /// level, so the loudest moments count most, as in an averaged spectrum.
    func meanPower(levelWeighted: Bool = false) -> [Float] {
        var sum = [Float](repeating: 0, count: bins)
        var row = [Float](repeating: 0, count: bins)
        let base = [Float](repeating: 10, count: bins)
        var tenth: Float = 0.1
        var count = Int32(bins)
        var weights = [Float](repeating: 1, count: rows)
        if levelWeighted, let top = noiseDbPerHz.max() {
            weights = noiseDbPerHz.map { pow(10, ($0 - top) / 10) }
        }
        relativeDb.withUnsafeBufferPointer { db in
            for r in 0..<rows {
                vDSP_vsmul(db.baseAddress! + r * bins, 1, &tenth, &row, 1, vDSP_Length(bins))
                row.withUnsafeMutableBufferPointer { out in
                    vvpowf(out.baseAddress!, UnsafePointer(out.baseAddress!), base, &count)
                }
                var weight = weights[r]
                vDSP_vsma(row, 1, &weight, sum, 1, &sum, 1, vDSP_Length(bins))
            }
        }
        var scale = 1 / max(weights.reduce(0, +), 1e-12)
        vDSP_vsmul(sum, 1, &scale, &sum, 1, vDSP_Length(bins))
        return sum
    }

    /// The band's mean power in each row, as a share of the noise.
    func bandPower(_ band: ClosedRange<Int>) -> [Float] {
        let count = band.count
        var row = [Float](repeating: 0, count: count)
        let base = [Float](repeating: 10, count: count)
        var tenth: Float = 0.1
        var length = Int32(count)
        return relativeDb.withUnsafeBufferPointer { db in
            (0..<rows).map { r in
                vDSP_vsmul(db.baseAddress! + r * bins + band.lowerBound, 1, &tenth, &row, 1, vDSP_Length(count))
                row.withUnsafeMutableBufferPointer { out in
                    vvpowf(out.baseAddress!, UnsafePointer(out.baseAddress!), base, &length)
                }
                var mean: Float = 0
                vDSP_meanv(row, 1, &mean, vDSP_Length(count))
                return mean
            }
        }
    }
}
