import Accelerate
import DSPCore
import Foundation

/// One signal as the view's lines and areas add up to it.
struct SignalCandidate: Equatable {
    var kind: Kind
    /// Relative to the capture centre.
    var lowerHz, upperHz: Double
    var traces: [SignalTrace]

    enum Kind: Equatable {
        case single
        /// Lines that take turns. Tones in Hz from the capture centre, lowest first.
        case fsk(tones: [Double])
        case area
    }

    var tones: [Double]? {
        if case .fsk(let tones) = kind { return tones }
        return nil
    }
}

/// Which of the lines around the point are one signal.
///
/// Lines whose power takes turns are one FSK, however far apart within a plausible shift; lines that ignore each other
/// stay apart, however close. It takes a picture finer than the symbols to see it (`turnsMap`): on `TraceFinder`'s map,
/// whose frames are 125 ms, an FSK's tones are both on in nearly every frame.
///
/// **Taking turns** is judged moment by moment, in segments of `segmentSeconds`, each line's power as a share of its own
/// level in that segment, so a slow fade on one tone doesn't matter:
/// - where both lines show (`activeDb`), the median of the segments' correlations, `turnsCorrelation` or under. So
///   stations that alternate slowly don't count: inside a segment one is simply on and the other off;
/// - where either shows, the correlation over all those moments together, `overallCorrelation` or under. Inside any one
///   segment a slow key's correlation is large, either way, by chance, but two keys that ignore each other don't run
///   against each other for a whole read.
///
/// On the corpus's tuning part, in 3 s reads every 0.25 s, the real FSK's tones reach −0.55 and −0.50 at their weakest.
/// Over 3 s, 240 pairs of independently keyed carriers (12 to 75 Bd, Morse from 8 to 25 WPM) reach −0.50 and −0.36, and
/// none passes both.
///
/// Two lines both steady (`SignalTrace.steady`) are never tones: a pair of carriers beat, and their beat can correlate
/// at anything. Lines more than `turnsWithinDb` apart in level aren't an FSK's either (FM's carrier and sidebands take
/// turns too), nor are lines under `minShiftHz` apart, which a frame short enough for the symbols can't part.
enum SignalGrouper {
    /// Under what independent lines at a fast key reach (±0.14 in one segment, less in a median of them), over the real
    /// FSK's −0.55. A slow key gets past this: `overallCorrelation` is what stops it.
    static let turnsCorrelation: Float = -0.4
    /// Between the −0.36 independent keys reach and the real FSK's −0.50.
    static let overallCorrelation: Float = -0.43
    static let maxShiftHz = 1_500.0
    static let minShiftHz = 120.0
    static let turnsWithinDb = 10.0
    /// A 10 ms Hann frame: half its weight lies within 5 ms, under a 100 Bd symbol, and its nulls ±200 Hz away keep an
    /// FSK's other tone out at 170 Hz and more.
    static let turnsBinHz = 100.0
    static let turnsHopSeconds = 0.005
    static let segmentSeconds = 0.25
    /// Each line's strongest moments (90th percentile) in a segment that counts, over the noise.
    static let activeDb = 6.0
    static let minSegments = 3
    /// Frames longer than this can't show a symbol's turn: nothing groups.
    static let longestFrameSeconds = 0.02

    /// The picture to judge turns from, of `z` at `rate`, its 0 Hz `centerOffsetHz` from the capture centre.
    static func turnsMap(_ z: [DSPComplex], rate: Double, centerOffsetHz: Double, halfSpanHz: Double) -> TimeFrequencyMap {
        TimeFrequencyMap.build(z, rate: rate, centerOffsetHz: centerOffsetHz, binHz: turnsBinHz,
                               hopSeconds: turnsHopSeconds, halfSpanHz: halfSpanHz)
    }

    /// The view as signals, lowest first. `map` is `turnsMap`: what lies outside it isn't tried.
    ///
    /// `lines` is the map the view was read from. Its traces and areas are spans of a read's average, and a strong FSK's
    /// sinc skirts fill them in whichever way the noise leaves them (one trace over both tones, an area either side, a
    /// span's middle hundreds of Hz from its tone): so each span is tried at its peaks on `lines` (`tones`), not at its
    /// middle. Without it, at its middle.
    static func group(_ view: NeighbourhoodView, map: TimeFrequencyMap, lines: TimeFrequencyMap? = nil) -> [SignalCandidate] {
        let spans = (view.traces.map { (signal: SignalCandidate(kind: .single, lowerHz: $0.lowerHz, upperHz: $0.upperHz, traces: [$0]),
                                        levelDb: $0.snrDb) }
            + view.areas.map { (signal: SignalCandidate(kind: .area, lowerHz: $0.lowerHz, upperHz: $0.upperHz, traces: []),
                                levelDb: $0.snrDb) }).sorted { $0.signal.lowerHz < $1.signal.lowerHz }
        let signals = spans.map(\.signal)
        guard map.rows > 0, map.frameSeconds <= longestFrameSeconds else { return signals }

        // Every line to try, with the signal it is on.
        let reach = map.offsetHz(0)...map.offsetHz(Double(map.bins - 1))
        let inReach = signals.indices.filter { reach.overlaps(signals[$0].lowerHz...signals[$0].upperHz) }
        let average = inReach.isEmpty ? nil : lines.map(smoothedAverage)
        let tones = inReach.flatMap { index -> [Tone] in
            let signal = signals[index], steady = signal.traces.first?.steady ?? false
            guard let lines, let average else {
                return [Tone(hz: (signal.lowerHz + signal.upperHz) / 2, levelDb: spans[index].levelDb, steady: steady, signal: index)]
            }
            return peaks(signal.lowerHz...signal.upperHz, average: average, lines: lines).map {
                Tone(hz: $0.hz, levelDb: $0.levelDb, steady: steady, signal: index)
            }
        }

        // Each line's group: the lowest it takes turns with, directly or through another.
        var root = Array(tones.indices)
        func find(_ k: Int) -> Int { root[k] == k ? k : find(root[k]) }
        var series: [Int: Series] = [:]
        func seriesAt(_ hz: Double) -> Series? {
            let bin = map.bin(hz)
            guard (0..<map.bins).contains(bin) else { return nil }
            if let known = series[bin] { return known }
            let made = Series(bin: bin, map: map)
            series[bin] = made
            return made
        }
        for a in tones.indices {
            for b in tones.indices where b > a && find(a) != find(b) {
                let apart = abs(tones[a].hz - tones[b].hz)
                guard apart >= minShiftHz, apart <= maxShiftHz, !(tones[a].steady && tones[b].steady),
                      abs(tones[a].levelDb - tones[b].levelDb) <= turnsWithinDb,
                      let x = seriesAt(tones[a].hz), let y = seriesAt(tones[b].hz), let turns = x.turns(with: y),
                      turns.correlation <= turnsCorrelation, turns.overall <= overallCorrelation else { continue }
                root[find(b)] = find(a)
            }
        }

        // A group of lines is one signal, whatever spans it was seen in.
        var joined = Set<Int>()
        var out: [SignalCandidate] = []
        for k in tones.indices where find(k) == k {
            let members = tones.indices.filter { find($0) == k }
            guard members.count > 1 else { continue }
            let own = Set(members.map { tones[$0].signal }).sorted()
            joined.formUnion(own)
            out.append(SignalCandidate(kind: .fsk(tones: members.map { tones[$0].hz }.sorted()),
                                       lowerHz: own.map { signals[$0].lowerHz }.min() ?? 0,
                                       upperHz: own.map { signals[$0].upperHz }.max() ?? 0,
                                       traces: own.flatMap { signals[$0].traces }))
        }
        out += signals.indices.filter { !joined.contains($0) }.map { signals[$0] }
        return out.sorted { $0.lowerHz < $1.lowerHz }
    }

    /// Whether `band` holds two lines that could take turns, the view's spans read at their peaks on `lines`: if not,
    /// there is no need for a turns map.
    static func mayHoldTones(_ view: NeighbourhoodView, band: ClosedRange<Double>, lines: TimeFrequencyMap) -> Bool {
        let traces = view.traces.filter { band.overlaps($0.lowerHz...$0.upperHz) }
        let areas = view.areas.filter { band.overlaps($0.lowerHz...$0.upperHz) }
        let wide = traces.contains { $0.upperHz - $0.lowerHz >= minShiftHz }
        guard !areas.isEmpty || wide || (traces.count >= 2 && traces.contains { !$0.steady }) else { return false }
        if traces.count + areas.count >= 2 { return true }
        // One span: tones only if it has humps.
        let span = areas.first.map { $0.lowerHz...$0.upperHz } ?? traces.first.map { $0.lowerHz...$0.upperHz } ?? band
        return peaks(span, average: smoothedAverage(lines), lines: lines).count >= 2
    }

    private static func smoothedAverage(_ lines: TimeFrequencyMap) -> [Float] {
        TraceFinder.smoothed(lines.meanPower(), reach: Int((TraceFinder.traceReachHz / lines.binHz).rounded()))
    }

    /// A line to try, on the `signal`th span.
    private struct Tone {
        var hz: Double
        var levelDb: Double
        var steady: Bool
        var signal: Int
    }

    /// The humps in a stretch of the read's average, each `TraceFinder.valleyDb` over the valleys beside it, within
    /// `TraceFinder.toneRangeDb` of the strongest: at least its strongest point.
    static func peaks(_ band: ClosedRange<Double>, average: [Float], lines: TimeFrequencyMap) -> [(hz: Double, levelDb: Double)] {
        let low = max(0, lines.bin(band.lowerBound)), high = min(average.count - 1, lines.bin(band.upperBound))
        guard low <= high else { return [] }
        let tops = TraceFinder.split(low...high, fine: average, top: .infinity).compactMap { piece in
            piece.max { average[$0] < average[$1] }
        }
        let strongest = tops.map { average[$0] }.max() ?? 0
        return tops.filter { average[$0] >= strongest / TraceFinder.linear(TraceFinder.toneRangeDb) }.map {
            (lines.offsetHz(Double($0)), 10 * log10(max(Double(average[$0]), 1e-6)))
        }
    }

    /// The two frequencies' turns on `map`, in the segments where both show. Nil when too few do, or the map can't tell.
    static func turns(_ aHz: Double, _ bHz: Double, map: TimeFrequencyMap) -> (correlation: Float, overall: Float)? {
        let binA = map.bin(aHz), binB = map.bin(bHz)
        guard map.frameSeconds <= longestFrameSeconds, map.rows > 0, (0..<map.bins).contains(binA), (0..<map.bins).contains(binB)
        else { return nil }
        return Series(bin: binA, map: map).turns(with: Series(bin: binB, map: map))
    }

    /// One frequency's power over time on a turns map, and what is worked out once per frequency however many lines it is
    /// tried against.
    private struct Series {
        /// As a share of each row's noise.
        let relative: [Float]
        /// As a share of the line's own level in its segment, its top clipped so a moment's noise doesn't lead. Where the
        /// line doesn't show, of a quarter of the level it usually shows at.
        let levelled: [Float]
        /// Whether it shows in each segment.
        let shows: [Bool]
        let length: Int

        init(bin: Int, map: TimeFrequencyMap) {
            let power = map.power(bin: bin)
            let segment = max(8, Int((segmentSeconds / map.hopSeconds).rounded()))
            let active = TraceFinder.linear(activeDb)
            // Each segment's strongest moments.
            let tops = stride(from: 0, through: map.rows - segment, by: segment).map { start -> Float in
                var sorted = Array(power[start..<(start + segment)])
                vDSP_vsort(&sorted, vDSP_Length(sorted.count), 1)
                return sorted[sorted.count * 9 / 10]
            }
            let usual = TraceFinder.median(tops.filter { $0 >= active })
            var out = [Float](repeating: 0, count: tops.count * segment)
            for (s, top) in tops.enumerated() {
                let level = max(top, usual / 4, active / 4)
                for r in (s * segment)..<((s + 1) * segment) { out[r] = min(power[r] / level, 1) }
            }
            relative = power
            levelled = out
            shows = tops.map { $0 >= active }
            length = segment
        }

        func turns(with other: Series) -> (correlation: Float, overall: Float)? {
            var correlations: [Float] = []
            var a: [Float] = [], b: [Float] = []
            for s in shows.indices where shows[s] || other.shows[s] {
                let range = (s * length)..<((s + 1) * length)
                a += levelled[range]
                b += other.levelled[range]
                if shows[s], other.shows[s] {
                    correlations.append(SignalGrouper.correlation(levelled[range], other.levelled[range]))
                }
            }
            guard correlations.count >= minSegments else { return nil }
            return (TraceFinder.median(correlations), SignalGrouper.correlation(a[...], b[...]))
        }
    }

    private static func correlation(_ x: ArraySlice<Float>, _ y: ArraySlice<Float>) -> Float {
        let count = vDSP_Length(x.count)
        return x.withUnsafeBufferPointer { px in
            y.withUnsafeBufferPointer { py in
                var meanX: Float = 0, meanY: Float = 0, xy: Float = 0, xx: Float = 0, yy: Float = 0
                vDSP_meanv(px.baseAddress!, 1, &meanX, count)
                vDSP_meanv(py.baseAddress!, 1, &meanY, count)
                vDSP_dotpr(px.baseAddress!, 1, py.baseAddress!, 1, &xy, count)
                vDSP_svesq(px.baseAddress!, 1, &xx, count)
                vDSP_svesq(py.baseAddress!, 1, &yy, count)
                let n = Float(x.count)
                let cross = xy - n * meanX * meanY, a = xx - n * meanX * meanX, b = yy - n * meanY * meanY
                return a > 0 && b > 0 ? cross / (a * b).squareRoot() : 0
            }
        }
    }
}

extension TimeFrequencyMap {
    /// A map of nothing: where no picture was needed.
    static let empty = TimeFrequencyMap(binHz: 1, hopSeconds: 1, lowerOffsetHz: 0, rows: 0, bins: 0, relativeDb: [], noiseDbPerHz: [])

    /// One bin's power in each row, as a share of that row's noise.
    func power(bin: Int) -> [Float] {
        var out = [Float](repeating: 0, count: rows)
        guard rows > 0 else { return out }
        relativeDb.withUnsafeBufferPointer { db in
            cblas_scopy(Int32(rows), db.baseAddress! + bin, Int32(bins), &out, 1)
        }
        var tenth: Float = 0.1
        vDSP_vsmul(out, 1, &tenth, &out, 1, vDSP_Length(rows))
        let base = [Float](repeating: 10, count: rows)
        var count = Int32(rows)
        out.withUnsafeMutableBufferPointer { p in vvpowf(p.baseAddress!, UnsafePointer(p.baseAddress!), base, &count) }
        return out
    }
}
