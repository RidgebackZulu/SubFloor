import Accelerate
import Foundation

/// An interference comb across the capture: many narrow lines about `spacingHz` apart (something local, such as a
/// switching power supply or the receiver's own spurs).
public struct CombInfo: Codable, Sendable, Equatable {
    /// How far apart its lines lie, on average over the capture.
    public var spacingHz: Double
    /// How many places on its grid hold a line: a doubled line counts once.
    public var lineCount: Int

    public init(spacingHz: Double, lineCount: Int) {
        self.spacingHz = spacingHz
        self.lineCount = lineCount
    }
}

/// Finds an interference comb in an averaged spectrum of the whole capture (FFT-shifted, dB).
///
/// 1. **Lines:** local maxima standing `lineContrastDb` over the spectrum's local background (the median of blocks
///    `backgroundHz` wide, between their centres), no wider at `widthBelowPeakDb` under their peak than `maxLineWidthHz`
///    (or `maxLineWidthBins` at a coarse resolution). The capture's outer edges (`usableShare`) are filter skirts.
/// 2. **Spacing:** the line train's autocorrelation: the gaps from each line to its next `neighbours`, counted within the
///    tolerance on a fine scale of spacings; its peaks (as many gaps as a grid of `minimumLines` needs) are the candidate
///    spacings. Each is fitted as a grid (a phase and a spacing, by least squares over the lines nearest
///    each grid place): a line within `spacingTolerance` of the spacing from its place is on it, so a comb whose lines
///    wander by a few per cent (the owner's 14 MHz comb: steps of 18.98 to 20.05 kHz about 19.29) and lines doubled about
///    1 kHz apart both fit, and the spacing is the grid's own.
/// 3. **One source:** the lines on the grid are alike in width (within `widthRatio` of their median; others are other
///    signals), at least `minimumLines` places hold one, `minOccupancy` of the places between the outermost do, and
///    they lie at least `minSpacingWidths` of their width apart (packed stations, such as a sub-band's FT8 tracks, are
///    no comb).
/// 4. **Bare lines:** at least `minBareShare` of the lines that can be checked stand on noise: what lies from
///    `pedestalInnerHz` (or `pedestalInnerWidths` of the line's width) to `pedestalOuterHz` (or a third of the spacing)
///    either side is within `bareDb` of the quietest stretches (`floorShare`) within half a spacing. An AM station's
///    carrier stands on its own sidebands: a channelled broadcast band is a grid of modulated lines, never a comb.
/// 5. **No broadcast raster:** a spacing within `rasterTolerance` of a whole number (up to `rasterMultiples`) of a
///    broadcast band's channels (`broadcastRastersHz`: 9 kHz, and 5 kHz, which 10 kHz is twice) is no comb. A weak
///    station's sidebands lie under the noise, and its carrier alone is a bare line: only its raster says what it is.
///
/// Of the candidate grids that pass step 3, the one that holds the most places is the comb, the smallest spacing of equals
/// (half the spacing leaves half its places empty); steps 4 and 5 are asked of it alone, and when it fails them there is
/// no comb (a grid twice as wide holds half its lines, which stand where the others do).
///
/// It sees an average, so it can't tell a keyed line from a steady one: `SignalIdentifier` labels a line comb only
/// where the read shows it steady.
enum InterferenceComb {
    static let minimumLines = 8
    static let usableShare = 0.9
    static let backgroundHz = 2000.0
    static let lineContrastDb: Float = 10
    static let widthBelowPeakDb: Float = 6
    static let maxLineWidthHz = 300.0
    static let maxLineWidthBins = 6
    /// A peak must be the strongest within this many bins either side (a wandering line's own ripples are no lines).
    static let peakReachBins = 3
    static let widthRatio = 2.0
    static let spacingTolerance = 0.05
    static let minOccupancy = 0.6
    static let minSpacingWidths = 8.0
    /// How many lines above each one give its candidate spacings.
    static let neighbours = 6
    static let pedestalInnerHz = 300.0
    static let pedestalInnerWidths = 3.0
    static let pedestalOuterHz = 2000.0
    static let pedestalOuterShare = 1.0 / 3
    static let pedestalMinBins = 4
    static let floorShare = 0.1
    static let bareDb: Float = 3
    static let minBareShare = 0.5
    static let broadcastRastersHz = [9000.0, 5000]
    static let rasterMultiples = 4
    static let rasterTolerance = 0.005

    /// One narrow line: where it lies (Hz from the capture centre), its peak's bin, and its width.
    struct Line {
        var offsetHz: Double
        var bin: Int
        var widthHz: Double
    }

    /// The comb, if there is one, and the lines that lie on its grid (Hz from the capture centre, a doubled line's both).
    static func detect(spectrumDb: [Float], sampleRate: Double) -> (info: CombInfo, lineOffsetsHz: [Double])? {
        let n = spectrumDb.count
        guard n >= 64, sampleRate > 0 else { return nil }
        let binHz = sampleRate / Double(n)
        let lines = self.lines(spectrumDb, binHz: binHz)
        guard lines.count >= minimumLines else { return nil }
        let usableHz = usableShare * sampleRate
        let widest = usableHz / Double(minimumLines - 1)
        // The line train's autocorrelation: each line's gaps to its next few, counted within the tolerance of each
        // spacing on a fine geometric scale. Its peaks are the candidate spacings.
        let shortest = 4 * binHz
        var gaps: [Double] = []
        for i in lines.indices {
            for j in (i + 1)..<min(lines.count, i + 1 + neighbours) {
                let gap = lines[j].offsetHz - lines[i].offsetHz
                if gap >= shortest && gap <= widest { gaps.append(gap) }
            }
        }
        gaps.sort()
        func atMost(_ x: Double) -> Int {
            var low = 0, high = gaps.count
            while low < high {
                let mid = (low + high) / 2
                if gaps[mid] <= x { low = mid + 1 } else { high = mid }
            }
            return low
        }
        let step = 1 + spacingTolerance / 4
        var scale: [Double] = []
        var s = shortest
        while s <= widest {
            scale.append(s)
            s *= step
        }
        let counts = scale.map { atMost($0 * (1 + spacingTolerance / 2)) - atMost($0 * (1 - spacingTolerance / 2)) }
        // A grid of `minimumLines` places, `minOccupancy` of those it spans, has this many neighbours a spacing apart.
        let pairs = max(2, 2 * minimumLines - Int(Double(minimumLines) / minOccupancy))
        let candidates = scale.indices.filter { i in
            counts[i] >= pairs && (i == 0 || counts[i] >= counts[i - 1]) && (i == scale.count - 1 || counts[i] > counts[i + 1])
        }.map { scale[$0] }

        var best: (spacing: Double, places: Int, lines: [Line])?
        for candidate in candidates {
            guard let grid = fit(lines, spacing: candidate), grid.places > (best?.places ?? minimumLines - 1) else { continue }
            best = grid
        }
        // The grid that holds the most is the comb, or nothing is: one twice as wide holds half its lines, and those
        // stand where the others do.
        guard let best, !onBroadcastRaster(best.spacing),
              bare(best.lines, spacing: best.spacing, db: spectrumDb, binHz: binHz) else { return nil }
        return (CombInfo(spacingHz: best.spacing, lineCount: best.places), best.lines.map(\.offsetHz))
    }

    /// The narrow lines in the spectrum's usable part, by local contrast.
    static func lines(_ db: [Float], binHz: Double) -> [Line] {
        let n = db.count
        let background = self.background(db, block: max(8, Int((backgroundHz / binHz).rounded())))
        let edge = Int((1 - usableShare) / 2 * Double(n))
        let first = max(edge, peakReachBins), last = min(n - 1 - edge, n - 1 - peakReachBins)
        guard first < last else { return [] }
        let widestBins = max(Double(maxLineWidthBins), maxLineWidthHz / binHz)
        var out: [Line] = []
        var k = first
        while k <= last {
            defer { k += 1 }
            let peak = db[k]
            guard peak - background[k] >= lineContrastDb else { continue }
            guard ((k - peakReachBins)...(k + peakReachBins)).allSatisfy({ $0 == k || db[$0] < peak || ($0 > k && db[$0] == peak) })
            else { continue }
            var lower = k, upper = k
            while lower > 0 && db[lower - 1] >= peak - widthBelowPeakDb { lower -= 1 }
            while upper < n - 1 && db[upper + 1] >= peak - widthBelowPeakDb { upper += 1 }
            let width = Double(upper - lower + 1)
            guard width <= widestBins else { continue }
            // Where it lies: its power's centroid over that width.
            var weight = 0.0, sum = 0.0
            for j in lower...upper {
                let p = pow(10, Double(db[j]) / 10)
                weight += p
                sum += p * Double(j)
            }
            out.append(Line(offsetHz: (sum / weight - Double(n / 2)) * binHz, bin: k, widthHz: width * binHz))
            k = upper
        }
        return out
    }

    /// Each bin's local background: the median (in dB) of blocks `block` bins long, between their centres.
    static func background(_ db: [Float], block: Int) -> [Float] {
        let n = db.count
        let count = max(1, (n + block - 1) / block)
        var medians = [Float](repeating: 0, count: count)
        for b in 0..<count {
            var values = Array(db[(b * block)..<min(n, (b + 1) * block)])
            vDSP_vsort(&values, vDSP_Length(values.count), 1)
            medians[b] = values[values.count / 2]
        }
        // Flat before the first centre and after the last, straight between centres.
        var out = [Float](repeating: medians[count - 1], count: n)
        let half = block / 2
        for k in 0..<min(n, half) { out[k] = medians[0] }
        for b in 0..<(count - 1) {
            let start = b * block + half, step = (medians[b + 1] - medians[b]) / Float(block)
            for j in 0..<block where start + j < n { out[start + j] = medians[b] + Float(j) * step }
        }
        return out
    }

    /// `lines` as a grid of about `spacing`: the spacing and phase fitted to them, how many places hold a line, and the
    /// lines on it, or nil when that isn't one source's comb (step 3).
    static func fit(_ lines: [Line], spacing start: Double) -> (spacing: Double, places: Int, lines: [Line])? {
        var spacing = start
        // The phase where the most lines gather, within the tolerance.
        let tolerance = spacingTolerance
        let phases = lines.map { line -> Double in
            let r = line.offsetHz / spacing
            return r - r.rounded(.down)
        }.sorted()
        // A window 2 × the tolerance wide slid round the circle of phases (each phase also once more, a turn on).
        let around = phases + phases.map { $0 + 1 }
        var bestCount = 0, phase = 0.0
        var end = 0, sum = 0.0
        for start in phases.indices {
            while end < start + phases.count && around[end] - around[start] <= 2 * tolerance {
                sum += around[end]
                end += 1
            }
            if end - start > bestCount {
                bestCount = end - start
                phase = sum / Double(end - start) * spacing
            }
            sum -= around[start]
        }
        func places(_ spacing: Double, _ phase: Double) -> [Int: Line] {
            var nearest: [Int: (line: Line, off: Double)] = [:]
            for line in lines {
                let k = Int(((line.offsetHz - phase) / spacing).rounded())
                let off = abs(line.offsetHz - phase - Double(k) * spacing)
                guard off <= tolerance * spacing else { continue }
                if off < nearest[k]?.off ?? .infinity { nearest[k] = (line, off) }
            }
            return nearest.mapValues(\.line)
        }
        // Least squares over the line nearest each place, a few times over.
        for _ in 0..<3 {
            let held = places(spacing, phase)
            guard held.count >= 2 else { return nil }
            let ks = held.keys.map(Double.init), xs = held.keys.map { held[$0]!.offsetHz }
            let mk = ks.reduce(0, +) / Double(ks.count), mx = xs.reduce(0, +) / Double(xs.count)
            var sxy = 0.0, sxx = 0.0
            for (k, x) in zip(ks, xs) {
                sxy += (k - mk) * (x - mx)
                sxx += (k - mk) * (k - mk)
            }
            guard sxx > 0 else { return nil }
            let fitted = sxy / sxx
            guard fitted > 0, abs(fitted / spacing - 1) <= tolerance else { return nil }
            spacing = fitted
            phase = mx - mk * spacing
        }
        // Every line on the grid, a doubled line's both; alike in width.
        var on: [(k: Int, line: Line)] = []
        for line in lines {
            let k = Int(((line.offsetHz - phase) / spacing).rounded())
            if abs(line.offsetHz - phase - Double(k) * spacing) <= tolerance * spacing { on.append((k, line)) }
        }
        guard !on.isEmpty else { return nil }
        let widths = on.map(\.line.widthHz).sorted()
        let median = widths[widths.count / 2]
        on = on.filter { $0.line.widthHz <= widthRatio * median && $0.line.widthHz >= median / widthRatio }
        let ks = Set(on.map(\.k))
        guard ks.count >= minimumLines, let low = ks.min(), let high = ks.max(),
              Double(ks.count) >= minOccupancy * Double(high - low + 1),
              spacing >= minSpacingWidths * median else { return nil }
        return (spacing, ks.count, on.map(\.line))
    }

    /// Whether `spacing` is a broadcast band's channel raster, or a few times one (step 5).
    static func onBroadcastRaster(_ spacing: Double) -> Bool {
        broadcastRastersHz.contains { raster in
            (1...rasterMultiples).contains { abs(spacing / (Double($0) * raster) - 1) <= rasterTolerance }
        }
    }

    /// Whether enough of the comb's lines stand on noise, not on sidebands of their own (step 4). Lines too close together
    /// to show what lies beside them aren't counted either way.
    static func bare(_ lines: [Line], spacing: Double, db: [Float], binHz: Double) -> Bool {
        let n = db.count
        var checked = 0, bare = 0
        for line in lines {
            let inner = Int((max(pedestalInnerHz, pedestalInnerWidths * line.widthHz) / binHz).rounded(.up))
            let outer = Int((min(pedestalOuterHz, pedestalOuterShare * spacing) / binHz).rounded(.down))
            let half = Int((spacing / 2 / binHz).rounded(.down))
            guard outer - inner >= pedestalMinBins, line.bin - half >= 0, line.bin + half < n else { continue }
            var pedestal = Array(db[(line.bin - outer)...(line.bin - inner)]) + Array(db[(line.bin + inner)...(line.bin + outer)])
            vDSP_vsort(&pedestal, vDSP_Length(pedestal.count), 1)
            var around = Array(db[(line.bin - half)...(line.bin + half)])
            vDSP_vsort(&around, vDSP_Length(around.count), 1)
            let floor = around[Int(floorShare * Double(around.count))]
            checked += 1
            if pedestal[pedestal.count / 2] - floor <= bareDb { bare += 1 }
        }
        return checked == 0 || Double(bare) >= minBareShare * Double(checked)
    }
}

extension InterferenceComb {
    /// How near a trace's edges one of the comb's lines may lie and still be in it (a spectrum bin or so: where a line
    /// lies is its power's centroid).
    static let lineMatchHz = 32.0
    /// The share of a read a comb line is on for, or keeps step with another for.
    static let steadyShare = 0.9
    /// Another of the comb's lines, to keep step with, is on for this much of the read at least.
    static let partnerShare = 0.3

    /// Whether `trace` is one of the comb's lines, where a read shows it: one of `linesHz` (from the map's centre) lies in
    /// it, and it is steady as the comb is: on for `steadyShare` of the read, or on and off with another of the comb's
    /// lines in view (`partnerShare`) at all but `1 − steadyShare` of its moments. The owner's comb comes and goes with the
    /// receiver's gain, all its lines together; a keyed signal on the grid keys alone. (A slot mode's tones hop faster
    /// than the map can show: `SignalIdentifier` waits for them to be read.)
    static func isCombLine(_ trace: SignalTrace, view: NeighbourhoodView, map: TimeFrequencyMap, linesHz: [Double]) -> Bool {
        func onLine(_ t: SignalTrace) -> Bool { linesHz.contains { (t.lowerHz - lineMatchHz)...(t.upperHz + lineMatchHz) ~= $0 } }
        guard map.rows > 0, onLine(trace) else { return false }
        func on(_ t: SignalTrace) -> [Bool] {
            (0..<map.rows).map { r in
                let time = Double(r) * map.hopSeconds + map.frameSeconds / 2
                return t.onTimes.contains { $0 ~= time }
            }
        }
        let rows = Double(map.rows)
        let mine = on(trace)
        if Double(mine.filter { $0 }.count) >= steadyShare * rows { return true }
        return view.traces.contains { other in
            guard other != trace, onLine(other) else { return false }
            let theirs = on(other)
            guard Double(theirs.filter { $0 }.count) >= partnerShare * rows else { return false }
            return Double(zip(mine, theirs).filter { $0 != $1 }.count) <= (1 - steadyShare) * rows
        }
    }
}
