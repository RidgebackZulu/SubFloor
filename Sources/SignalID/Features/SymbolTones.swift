import Accelerate
import DSPCore
import Foundation

/// What `SymbolTones` reads of a narrow MFSK.
struct SymbolTonesReading: Equatable {
    var baud: Double
    var toneCount: Int
    /// The rate: the tones were seen that far apart, within `SymbolTones.spacingTolerance`.
    var spacingHz: Double
    /// How far apart the symbols' own frequencies put the tones. Gaussian keying pulls them together (FT4's by 3–7%).
    var tonesSpacingHz: Double
    /// Distinct tones its symbols were seen on.
    var tonesSeen: Int
    /// The middle of its tones, in Hz from the channel's 0.
    var centreHz: Double
    /// The symbols' alignment line over the median of all the lengths tried (`SymbolTones.minContrast`).
    var contrast: Double
    /// The share of symbols on a tone of the grid.
    var onGrid: Double
    var symbols: Int

    /// (tones − 1) × spacing + 2 × rate, as a slot row's width.
    var widthHz: Double { Double(toneCount - 1) * spacingHz + 2 * baud }
}

/// An MFSK whose tones lie closer together than the neighbourhood map resolves (FT8's 6.25 Hz, FT4's 20.8 Hz), read
/// symbol by symbol. Its tones are orthogonal: one symbol long, a frame holds exactly one tone, and a spectrum of it
/// puts all its power in one bin. A frame across a symbol boundary splits it over two.
///
/// Thresholds were chosen on synthetic FT8, FT4, PSK31/63, CW, pulses, carriers, 2-FSK and WSPR (seeds ≥ 1000) and the
/// corpus's tuning part only.
///
/// - **The symbol length.** The signal is cut to its own channel (`widthHz`) and decimated to about 8 × that. For each
///   length T tried (2% apart, from `minLengthWidths` / width up to the read over `minSymbols`, at most `maxLengthSeconds`),
///   frames T long are laid end to end at 8 starting points across T. Each frame's *concentration* is its spectrum's
///   peak over all its power (1 for a single steady tone, whatever its level), and counts by how far the signal stands
///   over the noise then (`Presence`: so a moment it is off, or a receiver's gain step, counts for nothing). At the
///   symbol length, frames on the boundaries hold one tone each and frames between them two, so the mean concentration
///   rises and falls once across the 8 starts; at any other length the boundaries drift through the frames and it
///   doesn't. Its first harmonic is the *swing*.
///   - Over a read of L seconds the swing's peak is only about T / L wide (FT4's 1% over 5 s), narrower than the scan's
///     step. So the likeliest few lengths are found by the swing of each `segmentSymbols` symbols on their own (a peak
///     several steps wide), and looked at closely there, a quarter of the peak's width apart.
///   - The strongest swing is the symbol's, when it stands `minContrast` times over the median swing of all the lengths
///     tried. Noise alone reaches 3.7, PSK31 5.7 and a CW key 6.0 (seeds ≥ 1000); FT4 at 4 dB 4.7–8.5 and FT8 over 3 s
///     at 2 dB 6–10, and real FT8 on the tuning part 7.5–24. The checks below are what keep the others out.
/// - **The tones.** Frames on the boundaries give one frequency a symbol: the peak of the spectrum of its middle 80%
///   (Gaussian keying spills into its ends), 8 times finer than a bin, with a parabola in dB. The tone grid is the
///   spacing within `spacingTolerance` of the rate whose grid they sit on best (`grid`). The count is the next power of
///   two over the span of the grid positions used, a stray position at either end left out, and a lone symbol that takes
///   the span one past a power of two too.
/// - **Orthogonal or nothing.** Its symbols must sit on a grid spaced by the rate within `spacingTolerance`, with two
///   positions used at least. Then it is an MFSK only when every `Check` holds; otherwise nil, and the signal is measured
///   as before. Each check alone stops a case the others let through (`SymbolTonesTests.eachCheckStopsWhatOnlyItCan`):
///   - `contrast`: a CW key at 10 dB;
///   - `exclusivity`: one tone at a time, the strongest of its tones `minExclusivity` times over the rest in each symbol.
///     An interference comb's lines, all there at once with its pulses a symbol apart, read 5.1 on the tuning part (noise
///     alone about 3.3); FT4 at 4 dB 6.4–7.4, FT8 9 or more;
///   - `toneShare`, `spanFill`, `emptyTone`: none holding more than `maxToneShare` of the symbols, the tones filling
///     `minSpanFill` of their span, and with `symbolsPerTone` symbols a position, none between the outermost unused (a
///     line pulsing at FT8's rate, two CW keys 40 Hz apart, a 2-FSK 85 Hz wide);
///   - `pairs`: neighbouring symbols don't keep their tone in pairs. An 8-FSK at 3.125 Bd read at twice its rate on 3 s
///     does (0.71; true MFSKs 0.14 at most).
///   A test of how far the symbols sit from the grid (`onGrid`) stopped nothing the others didn't, over 27 kinds of
///   signal and the tuning part, so it only scales the reading's confidence.
///
/// The tones' own spacing reads a little narrow (Gaussian keying pulls them together: FT4's by 2–5%), so within
/// `rateSpacingTolerance` of the rate the spacing given is the rate; further off, what they read
/// (`SymbolTonesReading.tonesSpacingHz` keeps it either way).
enum SymbolTones {
    /// Samples per Hz of the channel's width after decimation.
    static let ratePerWidth = 8.0
    static let offsets = 8
    static let lengthStep = 1.02
    /// The scan's best few peaks are looked at closely, out to its neighbouring steps, in steps no finer than this.
    static let closerLooks = 3
    static let closeStepFloor = 0.001
    /// The segments whose swings find where to look closely.
    static let segmentSymbols = 16.0
    /// The shortest length tried, in 1 / width: an orthogonal 2-FSK is 3 / T wide.
    static let minLengthWidths = 2.5
    static let maxLengthSeconds = 1.0
    static let minSymbols = 16.0
    static let minContrast = 4.0
    static let solidContrast = 10.0
    /// Symbols that place a tone, at least: 3 s of FT8 leaves about 13 once the weak ones are set aside.
    static let minToneSymbols = 10
    /// The grid's spacings are tried this far apart (a share of the rate).
    static let gridStep = 0.005
    /// The grid's concentration at least, and at least `chanceConcentrations` / √n for n symbols (`grid`).
    static let minConcentration = 0.3
    static let chanceConcentrations = 2.5
    static let spacingTolerance = 0.1
    /// Tones read within this of the rate are given the rate as their spacing (Gaussian keying pulls them together by
    /// up to 5%); further off, what they read.
    static let rateSpacingTolerance = 0.05
    /// How much more often neighbouring symbols keep their tone when the first of them is even than when it is odd (or
    /// the reverse), at most; each parity needs `minPairs` pairs to count.
    static let maxPairing = 0.5
    static let minPairs = 4
    /// The share of symbols on the grid a reading is half sure at (`confidence`).
    static let minOnGrid = 0.6
    static let solidOnGrid = 0.9
    /// In a symbol, its tone's power over the mean of the others', at least (the median over symbols).
    static let minExclusivity = 6.0
    /// An MFSK's symbols change tone: one position holding more than this share of them is a line (an interference comb's
    /// pulses, 33 ms apart, on the corpus's tuning part), whatever strays lie beside it.
    static let maxToneShare = 0.6
    /// Its tones fill at least this share of the positions between its outermost two: a 2-FSK 170 Hz wide isn't an MFSK
    /// of 8 tones 21 Hz apart with 6 never used.
    static let minSpanFill = 0.5
    /// With this many symbols a position, an empty one among an MFSK's tones would be chance once in 50: a 2-FSK read on
    /// half-symbol frames sits on two positions with an empty one between.
    static let symbolsPerTone = 4
    /// Frames this weak (concentration, or presence, under this share of the median, or of the 90th percentile) hold too
    /// little of the signal to place a tone.
    static let weakFrameShare = 0.5
    static let peakPadding = 8
    /// The part of a symbol its frequency is read from.
    static let symbolMiddle = 0.1...0.9
    /// At most this many tones: Olivia's largest alphabet.
    static let maxTones = 64

    /// How far the signal stands over the noise from moment to moment. A frame counts by e / (1 + e), e its excess: a
    /// moment it is off, or under the noise (a receiver's gain stepped down), counts for nothing, and one well up for no
    /// more than another.
    struct Presence {
        /// The signal's power over the noise, less 1, at each step.
        var excess: [Double]
        var hopSeconds: Double
        /// The first step's middle, in seconds into the IQ read.
        var firstSeconds: Double

        /// The weight of a frame over `from…to` (seconds into the IQ): from the mean excess of the steps within it, or of
        /// the nearest one.
        func weight(from: Double, to: Double) -> Double {
            guard !excess.isEmpty else { return 1 }
            let a = Int(((from - firstSeconds) / hopSeconds).rounded(.up))
            let b = Int(((to - firstSeconds) / hopSeconds).rounded(.down))
            let lower = max(0, a), upper = min(excess.count - 1, b)
            let e: Double
            if lower <= upper {
                e = excess[lower...upper].reduce(0, +) / Double(upper - lower + 1)
            } else {
                e = excess[min(excess.count - 1, max(0, Int((((from + to) / 2 - firstSeconds) / hopSeconds).rounded())))]
            }
            return max(0, e) / (1 + max(0, e))
        }
    }

    /// The checks a reading must pass (see the type's notes). All of them, but a test may leave one out to show what it
    /// alone stops.
    enum Check: CaseIterable, Hashable {
        /// The swing stands `minContrast` over the median.
        case contrast
        /// No tone holds more than `maxToneShare` of the symbols.
        case toneShare
        /// The tones fill `minSpanFill` of their span.
        case spanFill
        /// With `symbolsPerTone` symbols a position, none between the outermost unused.
        case emptyTone
        /// One tone at a time (`minExclusivity`).
        case exclusivity
        /// Neighbouring symbols don't keep their tone in pairs (`maxPairing`): a slower MFSK read on half its symbols
        /// holds each tone for two of them.
        case pairs
    }

    /// Reads the signal in `iq` (interleaved, at `sampleRate`) at `offsetHz`, `widthHz` wide, each frame counting by
    /// `presence` (nil: alike). Nil when it isn't an orthogonal MFSK this read can show (see the type's notes).
    static func read(_ iq: [Float], sampleRate: Double, offsetHz: Double, widthHz: Double, presence: Presence? = nil,
                     checks: Set<Check> = Set(Check.allCases)) -> SymbolTonesReading? {
        guard widthHz > 0, sampleRate > 0, iq.count >= 2 else { return nil }
        let (z, rate) = channel(iq, sampleRate: sampleRate, offsetHz: offsetHz, widthHz: widthHz)
        let ffts = Transforms()
        guard let symbol = symbolLength(z, rate: rate, widthHz: widthHz, presence: presence, ffts: ffts),
              !checks.contains(.contrast) || symbol.contrast >= minContrast,
              let tones = tones(z, rate: rate, symbol: symbol, presence: presence, ffts: ffts),
              rejection(tones, checks: checks) == nil else { return nil }
        var count = 2
        while count < tones.last - tones.first + 1 { count *= 2 }
        guard count <= maxTones else { return nil }
        // The rate, when the tones are spaced by it as closely as Gaussian keying lets them read; otherwise what they read.
        let spacing = abs(tones.grid.spacing * symbol.length - 1) <= rateSpacingTolerance ? 1 / symbol.length
            : tones.grid.spacing
        return SymbolTonesReading(baud: 1 / symbol.length, toneCount: count, spacingHz: spacing,
                                  tonesSpacingHz: tones.grid.spacing, tonesSeen: tones.seen,
                                  centreHz: tones.grid.offset + Double(tones.first + tones.last) / 2 * tones.grid.spacing,
                                  contrast: symbol.contrast, onGrid: tones.onGrid, symbols: tones.values.count)
    }

    /// The symbol length found, the phase of its swing (where its boundaries fall), and its contrast.
    struct SymbolLength {
        var length: Double
        var phase: Double
        var contrast: Double
    }

    /// The length whose swing is strongest (see the type's notes), whatever its contrast. Nil when the read can't hold
    /// enough lengths to judge.
    static func symbolLength(_ z: [DSPComplex], rate: Double, widthHz: Double, presence: Presence?,
                             ffts: Transforms) -> SymbolLength? {
        let seconds = Double(z.count) / rate
        let shortest = max(minLengthWidths / widthHz, 8 / rate)
        let longest = min(seconds / minSymbols, maxLengthSeconds)
        guard longest > shortest * lengthStep * lengthStep else { return nil }
        var lengths: [Double] = []
        var swings: [Swing] = []
        var length = shortest
        while length <= longest {
            if Task.isCancelled { return nil }
            lengths.append(length)
            swings.append(swing(z, rate: rate, length: length, presence: presence, ffts: ffts))
            length *= lengthStep
        }
        guard swings.count >= 8 else { return nil }
        let amplitudes = swings.map(\.amplitude), segmented = swings.map(\.segments)
        let median = amplitudes.sorted()[amplitudes.count / 2]
        guard median > 0 else { return nil }
        // The likeliest few lengths, by their segments' swing (a peak several steps wide), looked at closely: over a long
        // read the whole swing's peak is narrower than the scan's step (FT4's over 5 s is 1% wide).
        let peaks = segmented.indices.filter { k in
            (k == 0 || segmented[k] >= segmented[k - 1]) && (k == segmented.count - 1 || segmented[k] >= segmented[k + 1])
        }.sorted { segmented[$0] > segmented[$1] }.prefix(closerLooks)
        var best: (length: Double, swing: Swing)?
        for k in peaks {
            // Steps a quarter of the whole swing's peak (its length over the read's) apart, across the scan's step.
            let fine = max(closeStepFloor, lengths[k] / (4 * seconds))
            let steps = Int((log(lengthStep) / log(1 + fine)).rounded(.up))
            for step in -steps...steps {
                if Task.isCancelled { return nil }
                let tried = lengths[k] * pow(1 + fine, Double(step))
                guard tried >= shortest, tried <= longest else { continue }
                let s = step == 0 ? swings[k] : swing(z, rate: rate, length: tried, presence: presence, ffts: ffts)
                if s.amplitude > (best?.swing.amplitude ?? 0) { best = (tried, s) }
            }
        }
        guard let best else { return nil }
        return SymbolLength(length: best.length, phase: best.swing.phase, contrast: best.swing.amplitude / median)
    }

    /// A length's swing: over the whole read (its first harmonic across the starting points, and its phase), and the
    /// mean of each `segmentSymbols` symbols' own, which a length a little off doesn't cancel.
    struct Swing {
        var amplitude: Double
        var phase: Double
        var segments: Double
    }

    static func swing(_ z: [DSPComplex], rate: Double, length: Double, presence: Presence?, ffts: Transforms) -> Swing {
        let segment = max(1, Int(segmentSymbols))
        let parts = Int(Double(z.count) / rate / length) / segment + 2
        // Each segment's weighted concentration and weight at each starting point, row by row.
        var sums = [Double](repeating: 0, count: parts * offsets), weights = sums
        for j in 0..<offsets {
            let f = frames(z, rate: rate, length: length, start: Double(j) / Double(offsets), presence: presence,
                           ffts: ffts)
            for (i, k) in f.frames.enumerated() {
                let cell = min(parts - 1, k / segment) * offsets + j
                sums[cell] += f.concentrations[i] * f.weights[i]
                weights[cell] += f.weights[i]
            }
        }
        func harmonic(_ row: Range<Int>) -> (amplitude: Double, phase: Double, weight: Double) {
            var re = 0.0, im = 0.0, weight = 0.0
            for j in 0..<offsets where weights[row.lowerBound + j] > 0 {
                let c = sums[row.lowerBound + j] / weights[row.lowerBound + j]
                let angle = 2 * Double.pi * Double(j) / Double(offsets)
                re += c * cos(angle)
                im += c * sin(angle)
                weight += weights[row.lowerBound + j]
            }
            return (2 * (re * re + im * im).squareRoot() / Double(offsets), atan2(im, re), weight / Double(offsets))
        }
        var wholeSums = [Double](repeating: 0, count: offsets), wholeWeights = wholeSums
        var inParts = 0.0, partWeight = 0.0
        for p in 0..<parts {
            for j in 0..<offsets {
                wholeSums[j] += sums[p * offsets + j]
                wholeWeights[j] += weights[p * offsets + j]
            }
            let h = harmonic((p * offsets)..<((p + 1) * offsets))
            inParts += h.amplitude * h.weight
            partWeight += h.weight
        }
        var re = 0.0, im = 0.0
        for j in 0..<offsets where wholeWeights[j] > 0 {
            let c = wholeSums[j] / wholeWeights[j], angle = 2 * Double.pi * Double(j) / Double(offsets)
            re += c * cos(angle)
            im += c * sin(angle)
        }
        return Swing(amplitude: 2 * (re * re + im * im).squareRoot() / Double(offsets), phase: atan2(im, re),
                     segments: partWeight > 0 ? inParts / partWeight : 0)
    }

    /// What the symbols, read on their boundaries, show of the tones: what `rejection` judges.
    struct Tones {
        /// Each symbol's frequency, in Hz from the channel's 0.
        var values: [Double]
        var grid: (spacing: Double, offset: Double, concentration: Double)
        /// Symbols on each grid position, and how many sit on one.
        var counts: [Int: Int]
        var placed: Int
        /// The outermost positions in use, strays left out, and how many positions between are used.
        var first: Int
        var last: Int
        var seen: Int
        var onGrid: Double
        /// The median over symbols of its tone's power over the mean of the others'.
        var exclusivity: Double
        /// How much more often neighbouring symbols keep their tone from an even symbol than from an odd one, or the
        /// reverse (0 when either parity has too few pairs).
        var pairing: Double
    }

    /// The symbols on the boundaries of `symbol` and what they show (see `Tones`). Nil when too few place a tone, or no
    /// grid near the rate holds them.
    static func tones(_ z: [DSPComplex], rate: Double, symbol: SymbolLength, presence: Presence?,
                      ffts: Transforms) -> Tones? {
        // The frames on the boundaries: where the concentration's swing peaks.
        let start = (symbol.phase / (2 * .pi)).truncatingRemainder(dividingBy: 1) + 1
        let aligned = frames(z, rate: rate, length: symbol.length, start: start.truncatingRemainder(dividingBy: 1),
                             presence: presence, ffts: ffts, padding: peakPadding)
        guard !aligned.concentrations.isEmpty else { return nil }
        // The frames that hold the signal: well concentrated, and from a moment it stands well up.
        let strong = aligned.concentrations.sorted()[aligned.concentrations.count / 2] * weakFrameShare
        let heard = aligned.weights.sorted()[aligned.weights.count * 9 / 10] * weakFrameShare
        let kept = aligned.peaksHz.indices.filter { aligned.concentrations[$0] >= strong && aligned.weights[$0] >= heard }
        let values = kept.map { aligned.peaksHz[$0] }
        guard values.count >= minToneSymbols, let grid = grid(values, near: 1 / symbol.length) else { return nil }
        var counts: [Int: Int] = [:]
        var placed = 0
        var positions: [Int: Int] = [:]   // by frame number
        for (v, i) in zip(values, kept) {
            let position = ((v - grid.offset) / grid.spacing).rounded()
            guard abs(v - grid.offset - position * grid.spacing) <= FSKFeatures.maxResidual * grid.spacing else { continue }
            counts[Int(position), default: 0] += 1
            placed += 1
            positions[aligned.frames[i]] = Int(position)
        }
        // Neighbours that keep their tone, by the parity of the first.
        var kept2 = [0, 0], pairs = [0, 0]
        for (frame, position) in positions {
            guard let next = positions[frame + 1] else { continue }
            pairs[frame % 2] += 1
            if next == position { kept2[frame % 2] += 1 }
        }
        let pairing = pairs.allSatisfy { $0 >= minPairs }
            ? abs(Double(kept2[0]) / Double(pairs[0]) - Double(kept2[1]) / Double(pairs[1])) : 0
        var seen = counts.keys.sorted()
        guard seen.count >= 2 else { return nil }
        // An isolated stray position at either end (one symbol, two or more empty positions away).
        while seen.count > 2, counts[seen[0]] == 1, seen[1] - seen[0] > 2 { seen.removeFirst() }
        while seen.count > 2, counts[seen[seen.count - 1]] == 1, seen[seen.count - 1] - seen[seen.count - 2] > 2 {
            seen.removeLast()
        }
        // A lone symbol at an end that takes the span one past a power of two is a stray too (9 positions are 8 tones and
        // a stray, not 16 tones).
        for _ in 0..<2 where seen.count > 2 {
            let span = seen[seen.count - 1] - seen[0] + 1
            guard span > 2, span & (span - 1) != 0 else { break }
            if counts[seen[0]] == 1, seen[seen.count - 1] - seen[1] + 1 <= Self.powerOfTwo(below: span) {
                seen.removeFirst()
            } else if counts[seen[seen.count - 1]] == 1, seen[seen.count - 2] - seen[0] + 1 <= Self.powerOfTwo(below: span) {
                seen.removeLast()
            }
        }
        let first = seen[0], last = seen[seen.count - 1]
        let exclusivity = middleValue(kept.map { i -> Double in
            let spectrum = aligned.spectra[i]
            let powers = (first...last).map { position -> Double in
                let hz = grid.offset + Double(position) * grid.spacing
                let bin = Int((hz / aligned.binHz).rounded())
                return Double(spectrum[((bin % spectrum.count) + spectrum.count) % spectrum.count])
            }
            let top = powers.max() ?? 0, rest = (powers.reduce(0, +) - top) / Double(max(1, powers.count - 1))
            return top / max(rest, 1e-30)
        })
        return Tones(values: values, grid: grid, counts: counts, placed: placed, first: first, last: last,
                     seen: seen.count, onGrid: Double(placed) / Double(values.count), exclusivity: exclusivity,
                     pairing: pairing)
    }

    /// The first of `checks` the tones fail, or nil when they pass them all (see `Check`).
    static func rejection(_ t: Tones, checks: Set<Check> = Set(Check.allCases)) -> Check? {
        let span = t.last - t.first + 1
        let failed: [Check: Bool] = [
            .toneShare: Double(t.counts.values.max() ?? 0) > maxToneShare * Double(t.placed),
            .spanFill: Double(t.seen) < minSpanFill * Double(span),
            // With symbols enough for every tone several times over, none between the outermost goes unused.
            .emptyTone: t.placed >= symbolsPerTone * span && (t.first...t.last).contains { t.counts[$0] == nil },
            // One tone at a time: in each symbol the strongest of the tones stands well over the rest. Lines that are all
            // there at once (an interference comb's, its pulses a symbol apart) share each frame alike.
            .exclusivity: t.exclusivity < minExclusivity,
            .pairs: t.pairing > maxPairing,
        ]
        return Check.allCases.first { checks.contains($0) && failed[$0] == true }
    }

    /// The median.
    static func middleValue(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }


    /// The largest power of two under `n`.
    static func powerOfTwo(below n: Int) -> Int {
        var p = 1
        while 2 * p < n { p *= 2 }
        return p
    }

    /// The tone grid of `values` with a spacing within `spacingTolerance` of `spacing` (an orthogonal MFSK's tones are a
    /// symbol rate apart): the spacing whose grid they sit on best (`gridStep` apart, then a parabola), its offset (a grid
    /// position) and how well they sit there, |mean e^{j2πf/s}|. Nil under `minConcentration`, or `chanceConcentrations`
    /// over √n for n values: values that fall anywhere reach about 1 / √n, and real FT8's symbols scatter by a quarter
    /// of a spacing (its Gaussian keying), which brings 50 of them to 0.6–0.7.
    static func grid(_ values: [Double], near spacing: Double) -> (spacing: Double, offset: Double, concentration: Double)? {
        func fit(_ s: Double) -> (offset: Double, concentration: Double) {
            var re = 0.0, im = 0.0
            for v in values {
                re += cos(2 * .pi * v / s)
                im += sin(2 * .pi * v / s)
            }
            return (atan2(im, re) / (2 * .pi) * s, (re * re + im * im).squareRoot() / Double(values.count))
        }
        let steps = Int((spacingTolerance / gridStep).rounded())
        let tried = (-steps...steps).map { spacing * (1 + Double($0) * gridStep) }
        let fits = tried.map { fit($0).concentration }
        guard let top = fits.indices.max(by: { fits[$0] < fits[$1] }) else { return nil }
        var best = tried[top]
        if top > 0, top < fits.count - 1 {
            let (a, b, c) = (fits[top - 1], fits[top], fits[top + 1])
            let curvature = a - 2 * b + c
            if curvature < 0 { best += min(0.5, max(-0.5, 0.5 * (a - c) / curvature)) * spacing * gridStep }
        }
        let found = fit(best)
        guard found.concentration >= max(minConcentration, chanceConcentrations / Double(values.count).squareRoot())
        else { return nil }
        return (best, found.offset, found.concentration)
    }

    /// How sure the reading is: 0.5 at the least contrast and grid share it is given at, 1 at their solid levels.
    static func confidence(_ r: SymbolTonesReading) -> Float {
        min(SignalMeasurer.score(r.contrast, minContrast, solidContrast),
            SignalMeasurer.score(r.onGrid, minOnGrid, solidOnGrid))
    }

    /// The signal's channel, decimated by block means to about `ratePerWidth` × its width (the channel filter has
    /// already band-limited it).
    static func channel(_ iq: [Float], sampleRate: Double, offsetHz: Double, widthHz: Double) -> ([DSPComplex], Double) {
        let cut = Channel.extract(iq, sampleRate: sampleRate, offsetHz: offsetHz, bandwidthHz: widthHz)
        let factor = max(1, Int(cut.rate / (ratePerWidth * widthHz)))
        guard factor > 1 else { return (cut.samples, cut.rate) }
        let count = cut.samples.count / factor
        var out = [DSPComplex](repeating: DSPComplex(real: 0, imag: 0), count: count)
        let scale = 1 / Float(factor)
        cut.samples.withUnsafeBufferPointer { s in
            s.baseAddress!.withMemoryRebound(to: Float.self, capacity: 2 * s.count) { f in
                for j in 0..<count {
                    var re: Float = 0, im: Float = 0
                    vDSP_sve(f + 2 * j * factor, 2, &re, vDSP_Length(factor))
                    vDSP_sve(f + 2 * j * factor + 1, 2, &im, vDSP_Length(factor))
                    out[j] = DSPComplex(real: re * scale, imag: im * scale)
                }
            }
        }
        return (out, cut.rate / Double(factor))
    }

    /// FFT setups by size, made once per read.
    final class Transforms {
        private var setups: [Int: FFTSetup] = [:]
        func setup(_ size: Int) -> FFTSetup? {
            if let s = setups[size] { return s }
            guard let s = vDSP_create_fftsetup(vDSP_Length(size.trailingZeroBitCount), FFTRadix(kFFTRadix2)) else { return nil }
            setups[size] = s
            return s
        }
        deinit { for s in setups.values { vDSP_destroy_fftsetup(s) } }
    }

    /// What `frames` gives: each frame's concentration and weight, their weighted mean, and (with peaks asked for) the
    /// frequency of each symbol's middle 80%, and its place in the run.
    struct Frames {
        var meanConcentration = 0.0
        var concentrations: [Double] = []
        var weights: [Double] = []
        var peaksHz: [Double] = []
        /// Each symbol's middle's power spectrum (with peaks asked for), `binHz` apart from 0 Hz, wrapping.
        var spectra: [[Float]] = []
        var binHz = 0.0
        var frames: [Int] = []
    }

    /// Frames `length` seconds long laid end to end from `start` (a share of `length`) on (see `Frames`).
    static func frames(_ z: [DSPComplex], rate: Double, length: Double, start: Double, presence: Presence?,
                       ffts: Transforms, padding: Int = 4) -> Frames {
        let n = max(8, Int((length * rate).rounded()))
        let size = FFT.size(atLeast: padding * n)
        var out = Frames()
        out.binHz = rate / Double(size)
        guard let setup = ffts.setup(size) else { return out }
        let log2n = vDSP_Length(size.trailingZeroBitCount)
        var re = [Float](repeating: 0, count: size), im = re, power = re
        /// `power` of `count` samples from `from`, zero-padded to `size`.
        func spectrum(_ from: Int, _ count: Int) {
            z.withUnsafeBufferPointer { samples in
                re.withUnsafeMutableBufferPointer { rp in
                    im.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        vDSP_vclr(rp.baseAddress!, 1, vDSP_Length(size))
                        vDSP_vclr(ip.baseAddress!, 1, vDSP_Length(size))
                        vDSP_ctoz(samples.baseAddress! + from, 2, &split, 1, vDSP_Length(count))
                        vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(size))
                    }
                }
            }
        }
        /// The frequency of `count` samples from `from`: their spectrum's peak, a parabola through it and its neighbours in
        /// dB (exact for a Gaussian-shaped lobe).
        func peakHz(_ from: Int, _ count: Int) -> Double {
            spectrum(from, count)
            var top: Float = 0, index: vDSP_Length = 0
            vDSP_maxvi(power, 1, &top, &index, vDSP_Length(size))
            let i = Int(index)
            let (a, b, c) = (log(max(Double(power[(i - 1 + size) % size]), 1e-30)), log(max(Double(top), 1e-30)),
                             log(max(Double(power[(i + 1) % size]), 1e-30)))
            let curvature = a - 2 * b + c
            let shift = curvature < 0 ? min(0.5, max(-0.5, 0.5 * (a - c) / curvature)) : 0
            return (Double(i < size / 2 ? i : i - size) + shift) * rate / Double(size)
        }
        func samples(_ share: Double) -> Int { Int((share * Double(n)).rounded()) }
        var k = 0
        while true {
            let from = Int(((start + Double(k)) * length * rate).rounded())
            guard from + n <= z.count else { break }
            k += 1
            let weight = presence?.weight(from: Double(from) / rate, to: Double(from + n) / rate) ?? 1
            guard weight > 0 else { continue }
            spectrum(from, n)
            var top: Float = 0, index: vDSP_Length = 0, total: Float = 0
            vDSP_maxvi(power, 1, &top, &index, vDSP_Length(size))
            vDSP_sve(power, 1, &total, vDSP_Length(size))
            // Parseval: the bins sum to size × the frame's energy; a lone tone's peak is n × that energy.
            guard total > 0 else { continue }
            out.concentrations.append(Double(top) * Double(size) / (Double(n) * Double(total)))
            out.weights.append(weight)
            out.frames.append(k - 1)
            if padding > 4 {
                // The symbol's middle: its neighbours' keying spills into its ends (Gaussian keying most), and would pull
                // its frequency towards theirs.
                let middle = samples(symbolMiddle.lowerBound), count = max(4, samples(symbolMiddle.upperBound) - middle)
                out.peaksHz.append(peakHz(from + middle, count))
                out.spectra.append(power)
            }
        }
        let sum = out.weights.reduce(0, +)
        out.meanConcentration = sum > 0 ? zip(out.concentrations, out.weights).reduce(0) { $0 + $1.0 * $1.1 } / sum : 0
        return out
    }
}
