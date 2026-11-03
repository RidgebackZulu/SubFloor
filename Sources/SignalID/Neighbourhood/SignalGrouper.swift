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
/// Over 3 s, 492 pairs of independently keyed carriers (8 and 12 Bd, Morse from 8 to 25 WPM) reach past the first in 9
/// cases, and −0.36 on the second, and none passes both (`independentPairsNeverJoin`; three times as many reach −0.38).
///
/// Lines more than `turnsWithinDb` apart in level aren't an FSK's: a tone-keyed FM's carrier and sideband can take turns
/// too. Steady carriers need no rule of their own: a pair's beat runs with them on this map (120 to 420 Hz apart, 3 s, the
/// lowest either correlation reaches is +0.35), and lines in one or two bins don't turn against each other.
enum SignalGrouper {
    /// Under what independent lines at a fast key reach (±0.14 in one segment, less in a median of them), over the real
    /// FSK's −0.55. A slow key gets past this: `overallCorrelation` is what stops it.
    static let turnsCorrelation: Float = -0.4
    /// Between the −0.36 independent keys reach and the real FSK's −0.50.
    static let overallCorrelation: Float = -0.43
    static let maxShiftHz = 1_500.0
    /// A span narrower than this has no room for two tones this map can part, so it needs no map.
    static let minShiftHz = 120.0
    /// Far enough to let one tone fade this far under the other, and no further (`fmCarrierAndSidebandAreNotTones`).
    static let turnsWithinDb = 20.0
    /// How far under a span's strongest hump a line is still tried.
    static let toneRangeDb = 20.0
    /// A station's power where its nearest tone is off, over the noise a skirt shows there (`TurnStates`).
    static let stationOverSkirt = 2.0
    /// Moments off that it takes to tell.
    static let minSettledRows = 20
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
    /// span's middle hundreds of Hz from its tone): so each span is tried at its peaks on `lines` (`peaks`), not at its
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
            let signal = signals[index]
            guard let lines, let average else {
                return [Tone(hz: (signal.lowerHz + signal.upperHz) / 2, levelDb: spans[index].levelDb, signal: index,
                             lowerHz: signal.lowerHz, upperHz: signal.upperHz)]
            }
            return peaks(signal.lowerHz...signal.upperHz, average: average, lines: lines).map {
                Tone(hz: $0.hz, levelDb: $0.levelDb, signal: index, lowerHz: $0.lowerHz, upperHz: $0.upperHz)
            }
        }

        // Groups, strongest line first. A sinc lobe can stand as tall as a tone and takes turns with the other tone just as
        // the tone does, only less firmly: so a line's partner is what it runs against hardest, and the pair is that partner's
        // own hardest. Any more lines must take turns with every line already there, which a tone's lobe, following that tone,
        // doesn't.
        var series: [Int: Series] = [:]
        func seriesAt(_ hz: Double) -> Series? {
            let bin = map.bin(hz)
            guard (0..<map.bins).contains(bin) else { return nil }
            if let known = series[bin] { return known }
            let made = Series(bin: bin, map: map)
            series[bin] = made
            return made
        }
        /// The correlation of two lines over the read, when they take turns.
        func turns(_ a: Tone, _ b: Tone) -> Float? {
            guard abs(a.hz - b.hz) <= maxShiftHz, abs(a.levelDb - b.levelDb) <= turnsWithinDb,
                  let x = seriesAt(a.hz), let y = seriesAt(b.hz) else { return nil }
            return x.turns(with: y)
        }
        var taken = Set<Int>()
        func partner(of k: Int) -> Int? {
            tones.indices.filter { $0 != k && !taken.contains($0) }
                .compactMap { other in turns(tones[k], tones[other]).map { (other, $0) } }
                .min { $0.1 < $1.1 }?.0
        }
        var groups: [[Int]] = []
        let byLevel = tones.indices.sorted { tones[$0].levelDb > tones[$1].levelDb }
        for first in byLevel where !taken.contains(first) {
            guard let one = partner(of: first), let other = partner(of: one) else { continue }
            var members = [other, one]
            for more in byLevel where !taken.contains(more) && !members.contains(more)
                && members.allSatisfy({ turns(tones[$0], tones[more]) != nil }) {
                members.append(more)
            }
            taken.formUnion(members)
            groups.append(members)
            // What else was seen is a tone's skirt, tried no further, or a line that holds power of its own.
            let states = TurnStates(members.compactMap { seriesAt(tones[$0].hz) }, hz: members.map { tones[$0].hz })
            for k in tones.indices where !taken.contains(k) {
                guard let at = seriesAt(tones[k].hz), states.holdsPower(at, hz: map.offsetHz(Double(map.bin(tones[k].hz)))) else {
                    taken.insert(k)
                    continue
                }
            }
        }

        // A group of lines is one signal, whatever spans it was seen in. A station in those spans stands on its own.
        let consumed = Set(groups.flatMap { $0.map { tones[$0].signal } })
        var out = groups.map { members -> SignalCandidate in
            let own = Set(members.map { tones[$0].signal }).sorted()
            return SignalCandidate(kind: .fsk(tones: members.map { tones[$0].hz }.sorted()),
                                   lowerHz: own.map { signals[$0].lowerHz }.min() ?? 0,
                                   upperHz: own.map { signals[$0].upperHz }.max() ?? 0,
                                   traces: own.flatMap { signals[$0].traces })
        }
        out += tones.indices.filter { !taken.contains($0) && consumed.contains(tones[$0].signal) }.map { k in
            let line = SignalTrace(lowerHz: tones[k].lowerHz, upperHz: tones[k].upperHz, snrDb: tones[k].levelDb, onTimes: [], steady: false)
            return SignalCandidate(kind: .single, lowerHz: line.lowerHz, upperHz: line.upperHz, traces: [line])
        }
        out += signals.indices.filter { !consumed.contains($0) }.map { signals[$0] }
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
        var signal: Int
        /// Where its hump stands.
        var lowerHz, upperHz: Double
    }

    /// The humps in a stretch of the read's average, each `TraceFinder.valleyDb` over the valleys beside it, within
    /// `toneRangeDb` of the strongest: at least its strongest point. Each stands where it stays within `TraceFinder.valleyDb`
    /// of its own top.
    static func peaks(_ band: ClosedRange<Double>, average: [Float], lines: TimeFrequencyMap)
        -> [(hz: Double, levelDb: Double, lowerHz: Double, upperHz: Double)] {
        let low = max(0, lines.bin(band.lowerBound)), high = min(average.count - 1, lines.bin(band.upperBound))
        guard low <= high else { return [] }
        let pieces = TraceFinder.split(low...high, fine: average, top: .infinity).compactMap { piece in
            piece.max { average[$0] < average[$1] }.map { (piece: piece, top: $0) }
        }
        let strongest = pieces.map { average[$0.top] }.max() ?? 0
        var out: [(hz: Double, levelDb: Double, lowerHz: Double, upperHz: Double)] = []
        for (piece, top) in pieces where average[top] >= strongest / TraceFinder.linear(toneRangeDb) {
            let edge: Float = average[top] / TraceFinder.linear(TraceFinder.valleyDb)
            var lower = top, upper = top
            while lower > piece.lowerBound, average[lower - 1] >= edge { lower -= 1 }
            while upper < piece.upperBound, average[upper + 1] >= edge { upper += 1 }
            let level = 10 * log10(max(Double(average[top]), 1e-6))
            out.append((lines.offsetHz(Double(top)), level, lines.offsetHz(Double(lower)), lines.offsetHz(Double(upper))))
        }
        return out
    }

    /// Which of a group's tones is on, moment by moment, and whether another line in its span holds power of its own.
    ///
    /// A tone's skirt lives on that tone's changes: it follows the tone and is gone once the tone is off. So a line is
    /// looked at where its nearest tone has been off for a whole frame, another tone on: a skirt reads the noise, and a
    /// station reads itself (`stationOverSkirt` times that).
    struct TurnStates {
        /// Row by row, the tone that is settled on, or nil around a change.
        let settled: [Int?]
        let series: [Series]
        let hz: [Double]

        init(_ series: [Series], hz: [Double]) {
            self.series = series
            self.hz = hz
            let rows = series.first?.levelled.count ?? 0
            var winner = [Int](repeating: 0, count: rows)
            for r in 0..<rows {
                var strongest: Float = -1
                for t in series.indices where series[t].levelled[r] > strongest {
                    strongest = series[t].levelled[r]
                    winner[r] = t
                }
            }
            var states = [Int?](repeating: nil, count: rows)
            for r in 0..<rows where r > 0 && r + 1 < rows && winner[r - 1] == winner[r] && winner[r + 1] == winner[r] {
                states[r] = winner[r]
            }
            settled = states
        }

        func holdsPower(_ line: Series, hz lineHz: Double) -> Bool {
            let nearest = hz.indices.min { abs(hz[$0] - lineHz) < abs(hz[$1] - lineHz) } ?? 0
            var level = 0.0, moments = 0
            for (r, tone) in settled.enumerated() where r < line.relative.count {
                guard let tone, tone != nearest else { continue }
                level += Double(line.relative[r])
                moments += 1
            }
            guard moments >= minSettledRows else { return false }
            return level >= stationOverSkirt * Double(moments)
        }
    }

    /// One frequency's power over time on a turns map, and what is worked out once per frequency however many lines it is
    /// tried against.
    struct Series {
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

        /// The median over the segments where both show.
        func medianCorrelation(with other: Series) -> Float? {
            var correlations: [Float] = []
            for s in shows.indices where shows[s] && other.shows[s] {
                let range = (s * length)..<((s + 1) * length)
                correlations.append(SignalGrouper.correlation(levelled[range], other.levelled[range]))
            }
            return correlations.count >= minSegments ? TraceFinder.median(correlations) : nil
        }

        /// The correlation over every moment of the segments where either shows.
        func overallCorrelation(with other: Series) -> Float {
            var a: [Float] = [], b: [Float] = []
            for s in shows.indices where shows[s] || other.shows[s] {
                let range = (s * length)..<((s + 1) * length)
                a += levelled[range]
                b += other.levelled[range]
            }
            return a.isEmpty ? 0 : SignalGrouper.correlation(a[...], b[...])
        }

        /// The correlation over the read, when the line takes turns with `other`.
        func turns(with other: Series) -> Float? {
            guard let median = medianCorrelation(with: other), median <= turnsCorrelation else { return nil }
            let overall = overallCorrelation(with: other)
            return overall <= SignalGrouper.overallCorrelation ? overall : nil
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
            for r in 0..<rows { out[r] = db[r * bins + bin] }
        }
        var tenth: Float = 0.1
        vDSP_vsmul(out, 1, &tenth, &out, 1, vDSP_Length(rows))
        let base = [Float](repeating: 10, count: rows)
        var count = Int32(rows)
        out.withUnsafeMutableBufferPointer { p in vvpowf(p.baseAddress!, UnsafePointer(p.baseAddress!), base, &count) }
        return out
    }
}
