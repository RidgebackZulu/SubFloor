import Accelerate
import DSPCore
import Foundation

/// What an FSK's own tones show.
struct FSKReading: Equatable {
    var toneCount: Int
    /// Between the two tones of a 2-FSK.
    var shiftHz: Double?
    /// Between adjacent tones.
    var spacingHz: Double?
    /// Nil when the tone runs and the keying line don't agree on one.
    var baud: Double?
    /// 0…1; 0 without a speed.
    var baudConfidence: Float
    /// The signal's power over the noise in its own width (`DirectFSK.widthHz`).
    var snrDb: Double
    /// The middle of the tones, in Hz from the channel's 0.
    var centreHz: Double = 0
    /// How many times the tone changed. Many, and still no speed: these may not be tones at all.
    var changes: Int = 0
}

/// An FSK measured from its tones, when the signal's lines are known (`SignalGrouper`) and so no spectrum need say
/// where it is.
///
/// Each tone goes through its own short filter, and the tones' power over time gives which tone is on:
/// - **The speed** comes from two things, which must agree. The *keying line* is the strongest periodicity in the times
///   the tone changes. The *tone runs* are how long each tone stays on: a rate fits when at least `minRunFit` of them
///   last a whole number of symbols, and at least `minUnitRuns` last just one (a line at twice the speed passes the
///   first and not the second, half the speed the second and not the first). A start-stop signal's 1.5 stop bits
///   (amateur RTTY's) put its edges on a half-symbol grid and cancel its line at the speed, leaving the line at twice it
///   and the character rate's harmonics (7/7.5 of the speed among them): so a line at twice a rate speaks for that rate
///   too, and there the run holding each stop bit, a half-symbol longer than whole, fits as well, when those runs are
///   all on one tone (the mark's: `stopBitShare`), as a stop bit's are and a signal read at half its speed's never are.
/// - **The tones** are put right from the phase each one turns through while it is on, so the shift doesn't depend on
///   where the map's bins fall.
/// - **The SNR** is the power in the tones' band, less the noise there, over the noise in the signal's width. The noise
///   is given (the map's), so nothing has to be left beside the signal to measure it.
///
/// Filters are tried long to short, the longest first because it is the cleanest (on the corpus's tuning part a 10 ms one
/// hears 75 Bd with 0.7 to 0.87 of its changes on the line, 5 ms 0.46 to 0.66). None is shorter than `minFilterShifts` /
/// the spacing, or a tone would hear its neighbour: the nulls of a Hann filter of 2 / shift lie on the other tone.
enum DirectFSK {
    static let filterSeconds = [0.01, 0.005, 0.0025]
    static let minFilterShifts = 1.9
    /// A tone's filter output, sampled this many times a filter.
    static let stepsPerFilter = 8
    /// Which tone is on only changes for one this many times as strong (each over its own top).
    static let switchRatio: Float = 1.5
    /// On at all: a tone this many times the noise in its filter.
    static let onOverNoise: Float = 3
    /// A tone's top: this share of its filter's output lies under it.
    static let topShare = 0.95
    /// A run shorter than this share of the filter is a glitch of the noise.
    static let shortestRunShare = 0.5
    static let minChanges = 16
    static let minToneShare = 0.05
    /// The tones' filters must between them hear this share of the signal's power. FM between two frequencies isn't on
    /// either for long.
    static let minTonalShare = 0.4
    /// The keying line over the median of the changes' spectrum.
    static let minLineContrast = 4.0
    static let solidLineContrast = 10.0
    static let lowestBaud = 10.0
    /// The fastest a filter's output can follow, in symbols per filter.
    static let fastestSymbolsPerFilter = 1.5
    static let spectrumPadding = 4
    static let maxLines = 8
    static let minRunFit = 0.7
    static let solidRunFit = 0.9
    static let runTolerance = 0.25
    static let minUnitRuns = 0.12
    /// On the half-symbol grid's line, runs a half-symbol longer than whole count when at least this share of them are
    /// on one tone (a start-stop signal's stop bits, all mark).
    static let stopBitShare = 0.9
    static let longestRunSymbols = 16.0
    static let settledConfidence: Float = 0.9
    /// Agreement this faint is no speed: keying with no clock behind it reaches 0.55, the real FSK's tuning part falls to 0.63,
    /// and a clean synthetic reading to 0.6.
    static let minConfidence: Float = 0.58
    /// The tones' band reaches this far beyond them, in symbols (or `plainGuardHz` without a speed).
    static let guardSymbols = 2.0
    static let plainGuardHz = 100.0
    static let minSeconds = 0.25

    /// `z` at `rate`, `tonesHz` from its 0 Hz, `noiseDb` its noise density (dB relative to 1 per Hz). Nil when these
    /// aren't tones taking turns: one of them barely on, or the signal mostly between them.
    static func measure(_ z: [DSPComplex], rate: Double, tonesHz: [Double], noiseDb: Double) -> FSKReading? {
        let given = tonesHz.sorted()
        let gaps = zip(given, given.dropFirst()).map { $1 - $0 }
        guard given.count >= 2, let closest = gaps.min(), closest > 0, Double(z.count) / rate >= minSeconds else { return nil }
        let density = pow(10, noiseDb / 10)
        let shortest = minFilterShifts / closest
        let tried = filterSeconds.filter { $0 >= shortest }
        var best: ToneRuns?
        for span in tried.isEmpty ? [shortest] : tried {
            guard let runs = ToneRuns(z, rate: rate, tones: given, filterSeconds: span, density: density) else { continue }
            if runs.confidence > (best?.confidence ?? -1) { best = runs }
            if runs.confidence >= settledConfidence { break }
        }
        guard let best else { return nil }

        // The correction only puts a tone right: one that moved far, or past another, heard something else.
        let tones = best.tones
        guard zip(tones, tones.dropFirst()).allSatisfy({ $1 - $0 >= closest / 2 }),
              zip(tones, given).allSatisfy({ abs($0 - $1) <= closest / 2 }) else { return nil }
        let fullSpan = tones[tones.count - 1] - tones[0]
        let spacing = tones.count == 2 ? fullSpan : median(zip(tones, tones.dropFirst()).map { $1 - $0 })
        var count = tones.count
        if count > 2 {
            // Alphabets carry whole bits: tones it didn't happen to show still count.
            count = 2
            while count < Int((fullSpan / spacing).rounded()) + 1 { count *= 2 }
        }
        var reading = FSKReading(toneCount: count, shiftHz: count == 2 ? spacing : nil, spacingHz: spacing, baud: best.baud,
                                 baudConfidence: best.baud == nil ? 0 : best.confidence, snrDb: 0,
                                 centreHz: (tones[0] + tones[tones.count - 1]) / 2, changes: best.changes)
        let reach = best.baud.map { guardSymbols * $0 } ?? plainGuardHz
        let band = power(z, rate: rate, within: (tones[0] - reach)...(tones[tones.count - 1] + reach))
        let bandNoise = density * (fullSpan + 2 * reach)
        let signal = max(band - bandNoise, 1e-20)
        guard best.tonePower >= minTonalShare * signal else { return nil }
        reading.snrDb = 10 * log10(signal / (density * widthHz(reading)))
        return reading
    }

    /// How wide the reading's signal is: from its parameters where they fix it (`ParameterWidth`), and otherwise the
    /// tones and a symbol's width each side of them.
    static func widthHz(_ reading: FSKReading) -> Double {
        let spacing = reading.spacingHz ?? 0
        let span = Double(reading.toneCount - 1) * spacing
        guard let baud = reading.baud else { return span + 2 * plainGuardHz }
        let m = SignalMeasurement(family: reading.toneCount > 8 ? .mfsk : .fsk, symbolRate: baud,
                                  fskShiftHz: reading.shiftHz, toneCount: reading.toneCount, toneSpacingHz: spacing)
        return ParameterWidth.width(m) ?? (span + 2 * baud)
    }

    /// An FSK's tones, ready to read from any samples that hold them, with what else the view holds taken out.
    struct Tones {
        let tonesHz: [Double]
        let othersHz: [ClosedRange<Double>]
        let noiseDb: Double

        init?(_ fsk: SignalCandidate, signals: [SignalCandidate], noiseDb: Double) {
            guard let tones = fsk.tones else { return nil }
            tonesHz = tones
            // Not what lies on a tone: that much of it would go too. It is the tone's own skirt, as often as not.
            othersHz = signals.filter { $0 != fsk }.map { $0.lowerHz...$0.upperHz }.filter { other in
                !tones.contains { ((other.lowerBound - notchRoomHz)...(other.upperBound + notchRoomHz)).contains($0) }
            }
            self.noiseDb = noiseDb
        }

        struct Read: Equatable {
            var reading: FSKReading
            /// The middle of its tones, from the capture centre.
            var offsetHz: Double

            func measurement(seconds: Double) -> SignalMeasurement {
                SignalMeasurer.measurement(reading, offsetHz: offsetHz, seconds: seconds)
            }
        }

        /// What interleaved `iq` at `rate`, its 0 Hz `zeroHz` from the capture centre, shows of them.
        func reading(_ iq: [Float], rate: Double, zeroHz: Double) -> Read? {
            let cut = DirectFSK.channel(iq, rate: rate, tonesHz: tonesHz.map { $0 - zeroHz },
                                        neighboursHz: othersHz.map { ($0.lowerBound - zeroHz)...($0.upperBound - zeroHz) })
            guard let reading = DirectFSK.measure(cut.samples, rate: cut.rate, tonesHz: cut.tonesHz, noiseDb: noiseDb) else { return nil }
            return Read(reading: reading, offsetHz: (tonesHz[0] + tonesHz[tonesHz.count - 1]) / 2 + reading.centreHz)
        }
    }

    /// A channel for `measure`: interleaved `iq` at `rate` around `tonesHz` (in Hz from its 0), holding noise beside them,
    /// with what lies in `neighboursHz` taken out. Tones in the channel's terms come back with it.
    static func channel(_ iq: [Float], rate: Double, tonesHz: [Double], neighboursHz: [ClosedRange<Double>])
        -> (samples: [DSPComplex], rate: Double, tonesHz: [Double]) {
        let lowest = tonesHz.min() ?? 0, highest = tonesHz.max() ?? 0
        let centre = (lowest + highest) / 2
        let cut = Channel.extract(iq, sampleRate: rate, offsetHz: centre, bandwidthHz: highest - lowest + 2 * channelRoomHz)
        let notched = self.notched(cut.samples, rate: cut.rate, ranges: neighboursHz.map {
            ($0.lowerBound - centre - notchRoomHz)...($0.upperBound - centre + notchRoomHz)
        })
        return (notched, cut.rate, tonesHz.map { $0 - centre })
    }

    static let channelRoomHz = 1000.0
    /// A neighbour's skirts, beyond where the finder drew its edges.
    static let notchRoomHz = 40.0

    /// `z` with `ranges` (Hz) cleared.
    static func notched(_ z: [DSPComplex], rate: Double, ranges: [ClosedRange<Double>]) -> [DSPComplex] {
        let nyquist = rate / 2
        let inside = ranges.filter { $0.lowerBound < nyquist && $0.upperBound > -nyquist }
        guard !inside.isEmpty, !z.isEmpty else { return z }
        let size = FFT.size(atLeast: z.count)
        var re = [Float](repeating: 0, count: size), im = re
        for k in z.indices {
            re[k] = z[k].real
            im[k] = z[k].imag
        }
        FFT.transform(&re, &im)
        let binHz = rate / Double(size)
        for range in inside {
            let low = Int((max(range.lowerBound, -nyquist) / binHz).rounded(.down))
            let high = Int((min(range.upperBound, nyquist) / binHz).rounded(.up))
            guard low <= high else { continue }
            for k in low...high {
                re[(k + size) % size] = 0
                im[(k + size) % size] = 0
            }
        }
        FFT.transform(&re, &im, inverse: true)
        let scale = 1 / Float(size)
        return z.indices.map { DSPComplex(real: re[$0] * scale, imag: im[$0] * scale) }
    }

    /// The mean power of `z` within `band` (Hz).
    static func power(_ z: [DSPComplex], rate: Double, within band: ClosedRange<Double>) -> Double {
        let size = FFT.size(atLeast: z.count)
        var re = [Float](repeating: 0, count: size), im = re
        for k in z.indices {
            re[k] = z[k].real
            im[k] = z[k].imag
        }
        FFT.transform(&re, &im)
        let binHz = rate / Double(size)
        let low = max(Int((band.lowerBound / binHz).rounded()), -size / 2)
        let high = min(Int((band.upperBound / binHz).rounded()), size / 2 - 1)
        guard low <= high else { return 0 }
        var sum = 0.0
        for k in low...high {
            let b = (k + size) % size
            sum += Double(re[b] * re[b] + im[b] * im[b])
        }
        return sum / (Double(size) * Double(z.count))
    }

    static func median(_ x: [Double]) -> Double {
        let sorted = x.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    /// One filter length's view of the tones: which is on when, and what that says.
    struct ToneRuns {
        /// The tones, put right.
        var tones: [Double]
        var baud: Double?
        var confidence: Float = 0
        /// What the tones' filters heard, less their noise.
        var tonePower: Double
        var changes = 0

        init?(_ z: [DSPComplex], rate: Double, tones: [Double], filterSeconds: Double, density: Double) {
            let length = max(4, Int((filterSeconds * rate).rounded()))
            let step = max(1, length / DirectFSK.stepsPerFilter)
            let dt = Double(step) / rate
            guard z.count > length + 16 * step else { return nil }
            let filter = ToneFilter(length: length, step: step)
            let outputs = tones.map { filter.output(z, rate: rate, toneHz: $0) }
            let noise = Float(density * rate * filter.noiseGain)
            let count = outputs[0].power.count
            let tops = outputs.map { Self.top($0.power) }
            guard tops.allSatisfy({ $0 > 1.5 * noise }) else { return nil }
            self.tonePower = outputs.reduce(0.0) { sum, tone in
                var mean: Float = 0
                vDSP_meanv(tone.power, 1, &mean, vDSP_Length(count))
                return sum + Double(max(mean - noise, 0))
            }
            self.tones = tones

            let runs = Self.runs(outputs.map(\.power), tops: tops, noise: noise, filterSteps: length / step)
            changes = runs.filter(\.joined).count
            let onSteps = runs.reduce(0) { $0 + $1.steps.count }
            guard onSteps > 0 else { return nil }
            for t in tones.indices {
                let share = runs.filter { $0.tone == t }.reduce(0) { $0 + $1.steps.count }
                guard Double(share) >= DirectFSK.minToneShare * Double(onSteps) / Double(max(1, tones.count - 1)) else { return nil }
            }
            // The phase each tone turns through while it's on.
            for t in tones.indices {
                var re = 0.0, im = 0.0
                let (a, b) = (outputs[t].re, outputs[t].im)
                for run in runs where run.tone == t {
                    let settle = length / step / 2
                    guard run.steps.count > 2 * settle + 1 else { continue }
                    for k in (run.steps.lowerBound + settle + 1)..<(run.steps.upperBound - settle) {
                        re += Double(a[k] * a[k - 1] + b[k] * b[k - 1])
                        im += Double(b[k] * a[k - 1] - a[k] * b[k - 1])
                    }
                }
                if re != 0 || im != 0 { self.tones[t] += atan2(im, re) / (2 * .pi * dt) }
            }
            if let speed = Self.speed(runs, dt: dt, filterSeconds: filterSeconds) {
                baud = speed.baud
                confidence = speed.confidence
            }
        }

        /// The level at `topShare` of a tone's output.
        static func top(_ p: [Float]) -> Float {
            var sorted = p
            vDSP_vsort(&sorted, vDSP_Length(sorted.count), 1)
            return sorted[min(sorted.count - 1, Int(DirectFSK.topShare * Double(sorted.count)))]
        }

        struct Run {
            var tone: Int
            var steps: Range<Int>
            /// It changes straight from another tone, at its start.
            var joined: Bool
        }

        /// Which tone is on, step by step: each tone over its own top, so a tone that stands lower still has its turn.
        /// A stretch as long as the filter with nothing on ends a run; so no change is counted across it.
        static func runs(_ powers: [[Float]], tops: [Float], noise: Float, filterSteps: Int) -> [Run] {
            let on = DirectFSK.onOverNoise * noise
            var out: [Run] = []
            var state: Int?, start = 0, joined = false, quiet = 0, lastOn = 0
            for k in powers[0].indices {
                var strongest = 0, best: Float = -1, loud = false
                for t in powers.indices {
                    let level = powers[t][k] / tops[t]
                    if level > best { best = level; strongest = t }
                    if powers[t][k] >= on { loud = true }
                }
                guard loud else {
                    quiet += 1
                    if quiet >= filterSteps, let s = state {
                        out.append(Run(tone: s, steps: start..<(lastOn + 1), joined: joined))
                        state = nil
                    }
                    continue
                }
                quiet = 0
                lastOn = k
                guard let s = state else {
                    state = strongest
                    start = k
                    joined = false
                    continue
                }
                if strongest != s, powers[strongest][k] >= on, best > DirectFSK.switchRatio * powers[s][k] / tops[s] {
                    out.append(Run(tone: s, steps: start..<k, joined: joined))
                    state = strongest
                    start = k
                    joined = true
                }
            }
            if let s = state { out.append(Run(tone: s, steps: start..<(lastOn + 1), joined: joined)) }
            return merged(out, shortest: max(1, Int((DirectFSK.shortestRunShare * Double(filterSteps)).rounded())))
        }

        /// `runs` with the glitches taken out: a run too short to be real, between two others, goes to the one before it.
        static func merged(_ runs: [Run], shortest: Int) -> [Run] {
            var out: [Run] = []
            var k = 0
            while k < runs.count {
                var run = runs[k]
                if run.steps.count < shortest, run.joined, k + 1 < runs.count, runs[k + 1].joined, !out.isEmpty {
                    out[out.count - 1].steps = out[out.count - 1].steps.lowerBound..<runs[k + 1].steps.lowerBound
                    k += 1
                    continue
                }
                if let last = out.last, last.tone == run.tone, run.joined {
                    run.steps = last.steps.lowerBound..<run.steps.upperBound
                    run.joined = last.joined
                    out.removeLast()
                }
                out.append(run)
                k += 1
            }
            return out
        }

        /// The speed the keying line and the tone runs agree on.
        static func speed(_ runs: [Run], dt: Double, filterSeconds: Double) -> (baud: Double, confidence: Float)? {
            let changes = runs.filter(\.joined).map(\.steps.lowerBound)
            guard changes.count >= DirectFSK.minChanges, let last = changes.last else { return nil }
            let durations = zip(runs, runs.dropFirst()).filter { $1.joined && $0.joined }
                .map { (seconds: Double($0.0.steps.count) * dt, tone: $0.0.tone) }
            guard !durations.isEmpty else { return nil }
            let size = FFT.size(atLeast: DirectFSK.spectrumPadding * (last + 1))
            var re = [Float](repeating: 0, count: size), im = re
            for k in changes { re[k] += 1 }
            FFT.transform(&re, &im)
            let binHz = 1 / (dt * Double(size))
            let lowest = max(1, Int(DirectFSK.lowestBaud / binHz))
            let highest = min(size / 2 - 2, Int(DirectFSK.fastestSymbolsPerFilter / filterSeconds / binHz))
            guard lowest + 2 < highest else { return nil }
            let line = (0...highest).map { (re[$0] * re[$0] + im[$0] * im[$0]).squareRoot() }
            let typical = TraceFinder.median(Array(line[lowest...highest]))
            guard typical > 0 else { return nil }
            var peaks = ((lowest + 1)..<highest).filter { line[$0] > line[$0 - 1] && line[$0] >= line[$0 + 1] }
                .filter { Double(line[$0] / typical) >= DirectFSK.minLineContrast }
            peaks.sort { line[$0] > line[$1] }
            for peak in peaks.prefix(DirectFSK.maxLines) {
                let (a, b, c) = (Double(line[peak - 1]), Double(line[peak]), Double(line[peak + 1]))
                let curve = a - 2 * b + c
                let hz = (Double(peak) + (curve < 0 ? 0.5 * (a - c) / curve : 0)) * binHz
                let contrast = b / Double(typical)
                // The line's own rate first; then half of it, the line being the half-symbol grid's (a start-stop
                // signal's, its stop bits' runs a half-symbol longer than whole).
                for baud in [hz, hz / 2] where baud >= DirectFSK.lowestBaud {
                    guard let fit = fit(durations, baud: baud, halfGrid: baud != hz) else { continue }
                    let confidence = min(SignalMeasurer.score(contrast, DirectFSK.minLineContrast, DirectFSK.solidLineContrast),
                                         SignalMeasurer.score(fit, DirectFSK.minRunFit, DirectFSK.solidRunFit))
                    // (A line at a rate the runs barely fit is a harmonic of something else, and is told by the rest.)
                    guard baud != hz || confidence >= DirectFSK.minConfidence else { continue }
                    return (baud, confidence)
                }
            }
            return nil
        }

        /// How much of `durations` (each run's length and tone) lasts a whole number of symbols at `baud`, when enough of
        /// them last just one. With `halfGrid` (the line is at twice `baud`: the half-symbol grid), a run a half-symbol
        /// longer than whole counts too, when `stopBitShare` of such runs are on one tone: a start-stop signal's stop bits.
        static func fit(_ durations: [(seconds: Double, tone: Int)], baud: Double, halfGrid: Bool = false) -> Double? {
            var whole = 0, unit = 0
            var halves: [Int: Int] = [:]   // by tone
            for d in durations {
                let symbols = d.seconds * baud
                let nearest = symbols.rounded()
                if nearest >= 1, nearest <= DirectFSK.longestRunSymbols, abs(symbols - nearest) <= DirectFSK.runTolerance {
                    whole += 1
                    if nearest == 1 { unit += 1 }
                } else if halfGrid {
                    let half = (symbols - 0.5).rounded() + 0.5
                    if half >= 1.5, half <= DirectFSK.longestRunSymbols, abs(symbols - half) <= DirectFSK.runTolerance {
                        halves[d.tone, default: 0] += 1
                    }
                }
            }
            if let most = halves.values.max(), Double(most) >= DirectFSK.stopBitShare * Double(halves.values.reduce(0, +)) {
                whole += most
            }
            let total = Double(durations.count)
            guard Double(whole) >= DirectFSK.minRunFit * total, Double(unit) >= DirectFSK.minUnitRuns * total else { return nil }
            return Double(whole) / total
        }
    }

    /// A Hann filter of unit gain at its centre frequency, decimating.
    struct ToneFilter {
        let window: [Float]
        let step: Int
        /// What white noise's power comes out at, for unit power in.
        let noiseGain: Double

        init(length: Int, step: Int) {
            var w = (0..<length).map { Float(0.5 - 0.5 * cos(2 * Double.pi * (Double($0) + 0.5) / Double(length))) }
            var sum: Float = 0
            vDSP_sve(w, 1, &sum, vDSP_Length(length))
            var scale = 1 / sum
            vDSP_vsmul(w, 1, &scale, &w, 1, vDSP_Length(length))
            var squares: Float = 0
            vDSP_svesq(w, 1, &squares, vDSP_Length(length))
            window = w
            self.step = step
            noiseGain = Double(squares)
        }

        func output(_ z: [DSPComplex], rate: Double, toneHz: Double) -> (re: [Float], im: [Float], power: [Float]) {
            var mixed = z
            var mixer = BlockMixer(frequency: -toneHz, sampleRate: rate)
            mixed.withUnsafeMutableBufferPointer { samples in
                var start = 0
                while start < samples.count {
                    let count = min(BlockMixer.blockSize, samples.count - start)
                    mixer.mix(samples.baseAddress! + start, count: count)
                    start += count
                }
            }
            let n = mixed.count
            var inRe = [Float](repeating: 0, count: n), inIm = inRe
            inRe.withUnsafeMutableBufferPointer { rp in
                inIm.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    mixed.withUnsafeBufferPointer { vDSP_ctoz($0.baseAddress!, 2, &split, 1, vDSP_Length(n)) }
                }
            }
            let outputs = (n - window.count) / step + 1
            var re = [Float](repeating: 0, count: outputs), im = re, power = re
            vDSP_desamp(inRe, step, window, &re, vDSP_Length(outputs), vDSP_Length(window.count))
            vDSP_desamp(inIm, step, window, &im, vDSP_Length(outputs), vDSP_Length(window.count))
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(outputs))
                }
            }
            return (re, im, power)
        }
    }
}
