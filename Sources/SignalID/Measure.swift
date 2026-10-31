import Accelerate
import DSPCore
import Foundation

/// Measures one signal in a capture: its extent, occupied bandwidth, SNR, envelope, family and the family's
/// parameters. Pure and thread-safe.
///
/// `iq` is interleaved IQ (the IQ snapshot format); the newest `seconds` of it are analysed. `offsetHz` and
/// `bandwidthHz` place the signal relative to the capture centre (from `Extent.find` or an agent).
///
/// **Window.** That extent is only a seed: at 10 dB an AM signal's extent is just its carrier, and an FM
/// signal's skirts lie under the noise. The measurer cuts a window 3 × the seed wide (at least 40 kHz: the
/// widest AM it names with room for noise beside neighbours 9 kHz either side; at most 80% of the capture
/// and not past its edge) and finds the signal's extent there:
/// - an averaged spectrum (2048 bins across the window, 75%-overlapped Blackman-Harris frames) gives the noise:
///   anchored on the 10th percentile of the bins (first all of them, then those outside the signal), so a
///   crowded band's neighbours don't lift it (`SpectrumView.estimateNoise`);
/// - the signal is the bins of the seed standing 4 σ over the noise (σ: a noise bin's spread, smoothed over
///   5 bins), grown outwards while they stay there; nothing in the seed 5 σ over the noise (summed over its
///   bins) is noise;
/// - when its strongest bin is a carrier line (15 dB over the bins 3 either side), it also takes in
///   sidebands that sit symmetrically about the line: min(left, right), smoothed over ±100 Hz, 4 σ over the
///   noise, starting within 10 widths or 5 kHz of the line (AM audio reaches 4.5 kHz) and running out to
///   where they end. Every bin of them must sit at least 5 dB under the line (a 100% sine AM's sit 6 dB
///   under). Where something stronger appears on both sides, beyond 5 kHz it is other stations (a crowded
///   band) and the sidebands end halfway to them, with no margin beyond; on one side only, the sidebands
///   end short of it. The growth itself also stops halfway to other lines as strong as this one 5 kHz or
///   more away, and the margin the measurement adds stops short of the next other signal;
/// - a symmetric pair within 5 kHz, beyond the strongest bin's skirt, no more than 5 dB under it (stronger
///   than any AM's sidebands) makes that bin one of a comb, an FM tone's Bessel lines (APT seen on its
///   centre line): if the measurement finds a line there, it is never `am` or `carrier`.
///
/// **Bandwidth and SNR.** On a second spectrum about 64 bins across the signal (zoomed in on narrow ones,
/// coarser for wide ones, at least 4 / seconds), the noise is subtracted and:
/// - `occupiedBandwidthHz` is `OccupiedWidth.fixedPoint`, the definition the synthesiser's ground truth uses:
///   −20 dB relative to the signal's mean density over the width, never the extent's span; where that level
///   lies under the noise's scatter, the width is what stands out of the noise (narrower at low SNR);
/// - `bandwidth6dBHz` is the span of the bins at or above −6 dB relative to the same reference, the signal's
///   mean density over its occupied width (total power / occupied width), levels averaged over ±1% of it;
/// - `offsetHz` is the carrier line when there is one in the middle of the band (AM, CW, a carrier, FM with
///   pauses), otherwise the middle of the occupied band;
/// - `snrDb` is the signal's power within the occupied band over the noise power there (for bursty signals the
///   mean over the capture, as the averaged spectrum sees it).
///
/// **Family.** The signal is cut out at 1.25 × its occupied width (`Channel.extract`, centred as above, from
/// at most the newest 2²¹ samples of the view: about 1 s of a WFM signal at 2 MS/s, plenty) and its
/// envelope (`EnvelopeFeatures`, `Keying`), instantaneous frequency (`FrequencyFeatures`), carrier line
/// (`Line`) and sidebands (`SidebandFeatures`) measured. The rules, in order (each feature's score is 0.5 at
/// its threshold and 1 at its "solid" level; a family's confidence is the least of its rule's scores):
/// 1. **noise:** see the window.
/// 2. **ook:** a two-level envelope (`Keying`) with a carrier line holding ≥ 20% of the power; `cwWPM` =
///    1.2 / the Morse unit. Not when another tone within ±max(3 kHz, 10 widths), no more than 10 dB weaker,
///    is keyed in turn with it (envelopes correlated ≤ −0.3): that is one tone of an FSK whose extent took
///    only this tone, left `unknown`. Two-level without a line is someone else's (envelope `bursty`; the
///    burst rules are Task 4's).
/// 3. **am:** a carrier line (15 dB over the continuum beside it) holding ≥ 50% of the power (a 100% sine
///    AM's holds 2/3), sidebands holding ≥ 2%, and modulation in phase with the carrier: `inPhase` (in-phase
///    over quadrature variance, less one) ≥ 0.25. Not a line of a comb.
/// 4. **carrier:** a line holding ≥ 97% of the power (FM with long pauses holds about 90%), not of a comb.
/// 5. **fm / wfm:** a constant envelope (20 ms block CV within 2 × what noise alone gives, + 0.1, and
///    E|s|⁴/(E|s|²)² ≤ 1.1 with the noise taken out), a frequency spread ≥ 0.15 of half the occupied width,
///    and width × seconds ≥ 1000 independent samples. A distribution with separate peaks or a kurtosis
///    under 2.5 is discrete frequencies, FSK's, and is left `unknown`. WFM when ≥ 100 kHz wide, or ≥ 60 kHz
///    with the 19 kHz stereo pilot in the demodulated baseband (then in `subcarriersHz`); `fmDeviationHz`
///    either way.
/// 6. **usb / lsb:** no line (< 10%), a voice envelope (block CV ≥ 0.5 with ≥ 5% pauses), the passband's
///    power ≥ 15 dB over its mirror about the carrier side, and a tilt of at least 1 dB towards the carrier
///    side (voice is strongest at low audio frequencies): USB when the lower edge is the stronger.
/// 7. Otherwise `unknown`.
///
/// **Envelope:** `keyed` (OOK), `bursty` (two-level without a line), `voice` (block CV ≥ 0.5 with pauses;
/// for AM, of its in-phase modulation), `steady` otherwise; `none` for noise.
///
/// Thresholds were tuned on synthesiser seeds ≥ 1000, kept apart from the asserting tests (seeds 1–50).
///
/// Cost for 3 s (release build, Apple Silicon): 10–30 ms for an HF signal in a 48 kHz capture, about 55 ms
/// for a 12.5 kHz signal in a 2 MS/s capture, about 80 ms for WFM in a 1 MS/s capture.
public enum SignalMeasurer {
    static let minimumSeconds = 0.2
    static let windowFactor = 3.0
    static let minimumWindowHz = 40_000.0
    static let coarseBins = 2048.0
    static let measureBins = 64.0
    static let detectSigma = 5.0
    static let edgeSigma = 4.0
    static let lineContrastDb = 15.0
    static let sidebandBelowLineDb = 5.0
    static let sidebandSearchHz = 5000.0
    static let channelFactor = 1.25
    static let mirrorSmoothingHz = 100.0
    static let maxConstantM4 = 1.1
    static let minInPhase = 0.25
    static let minSidebandFraction = 0.02
    static let minAMCarrierFraction = 0.5
    static let minSpread = 0.15
    static let minKurtosis = 2.5
    static let minTiltDb = 1.0
    static let minCarrierFraction = 0.97
    static let minFMSamples = 1000.0
    static let maxFeatureSamples = 1 << 21
    static let twinSearchHz = 3000.0
    static let combMaxHz = 5000.0
    static let combBelowLineDb = 5.0
    static let twinBelowDb = 10.0
    static let maxTwinCorrelation = -0.3

    public static func measure(_ iq: [Float], sampleRate: Double, offsetHz: Double, bandwidthHz: Double,
                               seconds: Double) -> SignalMeasurement {
        let available = iq.count / 2
        let n = min(available, Int((max(seconds, 0) * sampleRate).rounded()))
        var result = SignalMeasurement(offsetHz: offsetHz, seconds: sampleRate > 0 ? Double(n) / sampleRate : 0)
        guard sampleRate > 0, result.seconds >= minimumSeconds else {
            result.notes.append("Too little IQ to measure (\(String(format: "%.2f", result.seconds)) s)")
            return result
        }
        let recent = n == available ? iq : Array(iq[(2 * (available - n))...])

        // The window: wide enough for the families' plausible widths, inside the capture.
        let seed = max(bandwidthHz, 1)
        let edgeRoom = 2 * (sampleRate / 2 - abs(offsetHz))
        let windowHz = max(min(max(windowFactor * seed, minimumWindowHz), 0.8 * sampleRate, edgeRoom),
                           min(seed, 0.8 * sampleRate))
        let window = Channel.extract(recent, sampleRate: sampleRate, offsetHz: offsetHz, bandwidthHz: windowHz,
                                     sharp: false)
        let duration = Double(window.samples.count) / window.rate

        var coarse = SpectrumView(window.samples, rate: window.rate, binHz: windowHz / coarseBins,
                                  usableHz: windowHz)
        let seedBins = coarse.bin(-seed / 2)...coarse.bin(seed / 2)
        coarse.estimateNoise(excluding: nil)
        var found: Region?
        for _ in 0..<3 {
            found = region(coarse, seed: seedBins)
            guard let r = found else { break }
            coarse.estimateNoise(excluding: widened(r.bins, by: 0.1, in: coarse))
        }
        found = region(coarse, seed: seedBins)
        guard let signalRegion = found else {
            result.family = .noise
            result.familyConfidence = 0.8
            result.notes.append("Nothing stands above the noise")
            return result
        }

        // The measurement spectrum: about 64 bins across the signal.
        let regionHz = Double(signalRegion.bins.count) * coarse.binHz
        let regionCentre = coarse.hz(Double(signalRegion.bins.lowerBound + signalRegion.bins.upperBound) / 2)
        let target = max(regionHz / measureBins, 4 / duration)
        var view = coarse
        var viewCentre = 0.0
        var viewSamples = window
        if target < coarse.binHz / 1.5 {
            let zoomHz = min(windowHz, max(8 * regionHz, 400))
            viewSamples = Channel.extract(interleaved(window.samples), sampleRate: window.rate,
                                          offsetHz: regionCentre, bandwidthHz: zoomHz)
            viewCentre = regionCentre
            view = SpectrumView(viewSamples.samples, rate: viewSamples.rate, binHz: target, usableHz: zoomHz)
        } else if target > 1.5 * coarse.binHz {
            // Coarser for a wide signal: more frames, less scatter in the noise.
            view = SpectrumView(window.samples, rate: window.rate, binHz: target, usableHz: windowHz)
        }
        let mapped = view.bin(coarse.hz(Double(signalRegion.bins.lowerBound)) - viewCentre)...view.bin(
            coarse.hz(Double(signalRegion.bins.upperBound)) - viewCentre)
        view.estimateNoise(excluding: widened(mapped, by: 0.1, in: view))
        // The margin beyond the signal stops short of anything else.
        let room = view.bin(coarse.hz(Double(signalRegion.room.lowerBound)) - viewCentre)...view.bin(
            coarse.hz(Double(signalRegion.room.upperBound)) - viewCentre)
        let margin = max(3, mapped.count * 15 / 100)
        let sliceLow = max(0, room.lowerBound + 1, mapped.lowerBound - margin)
        let sliceHigh = min(view.count - 1, room.upperBound - 1, mapped.upperBound + margin)
        let slice = sliceLow <= sliceHigh ? sliceLow...sliceHigh : mapped
        let signal = view.signal(slice)
        let width = OccupiedWidth.fixedPoint(signal, binHz: view.binHz, start: regionHz,
                                             noiseSigma: view.noise * view.spread)
        let total = signal.reduce(0, +)
        guard let occupiedLocal = width.bins, total > 0 else {
            result.family = .noise
            result.familyConfidence = 0.6
            result.notes.append("Nothing stands above the noise")
            return result
        }
        let occupied = (slice.lowerBound + occupiedLocal.lowerBound)...(slice.lowerBound + occupiedLocal.upperBound)
        let occupiedHz = Double(occupied.count) * view.binHz
        let inBand = view.signal(occupied).reduce(0, +)
        let line = Line(view, occupied: occupied, total: inBand)
        // A carrier line in the middle of the band is its centre (and the channel's, so the in-phase test
        // isn't spoiled by a residual offset).
        let middleHz = viewCentre + view.hz(Double(occupied.lowerBound + occupied.upperBound) / 2)
        let lineHz = viewCentre + view.hz(line.position)
        let centred = line.isLine && line.fraction >= 0.2 && abs(lineHz - middleHz) <= 0.1 * occupiedHz
        let centreHz = centred ? lineHz : middleHz
        let reach = max(1, Int((0.01 * occupiedHz / view.binHz).rounded()))
        let six = OccupiedWidth.span(OccupiedWidth.prefixSums(signal), reach: reach,
                                     threshold: total / Double(occupied.count) / 4)
        let signalPower = inBand / SpectrumView.enbw
        let noiseDensity = view.noise / (SpectrumView.enbw * view.binHz)
        result.offsetHz = offsetHz + centreHz
        result.occupiedBandwidthHz = occupiedHz
        result.bandwidth6dBHz = Double(six?.count ?? 0) * view.binHz
        result.snrDb = 10 * log10(signalPower / (noiseDensity * occupiedHz))

        // The signal's own channel, from at most the newest `maxFeatureSamples` of the view.
        let channelHz = max(channelFactor * occupiedHz, Double(mapped.count) * view.binHz, 20)
        let channel = Channel.extract(interleaved(Array(viewSamples.samples.suffix(maxFeatureSamples))),
                                      sampleRate: viewSamples.rate, offsetHz: centreHz - viewCentre,
                                      bandwidthHz: channelHz)
        let channelNoise = noiseDensity * Channel.noiseBandwidthHz(sampleRate: viewSamples.rate,
                                                                   bandwidthHz: channelHz)
        let envelope = EnvelopeFeatures(channel.samples, rate: channel.rate, bandwidthHz: channelHz,
                                        noisePower: channelNoise)
        let frequency = FrequencyFeatures(channel.samples, rate: channel.rate, occupiedHz: occupiedHz,
                                          channelHz: channelHz, noiseDensity: noiseDensity,
                                          signalPower: signalPower,
                                          lineSearchHz: occupiedHz >= 40_000 ? [19_000] : [])
        let sidebands = SidebandFeatures(view, occupied: occupied)
        let twin = envelope.keying == nil ? nil
            : keyedTwin(window, coarse, region: signalRegion.bins, centreHz: centreHz, channelHz: channelHz,
                        occupiedHz: occupiedHz)
        classify(&result, line: line, envelope: envelope, frequency: frequency, sidebands: sidebands,
                 keyedTwinHz: twin, comb: signalRegion.comb)
        return result
    }

    // MARK: Decision

    static func classify(_ m: inout SignalMeasurement, line: Line, envelope: EnvelopeFeatures,
                         frequency: FrequencyFeatures, sidebands: SidebandFeatures, keyedTwinHz: Double? = nil,
                         comb: Bool = false) {
        let steady = envelope.blockCV <= 2 * envelope.steadyCV + 0.1
        let constant = envelope.amplitudeM4 <= maxConstantM4
        let voice = envelope.blockCV >= 0.5 && envelope.pauseFraction >= 0.05 && envelope.keying == nil
        let amVoice = envelope.modulationCV >= 0.5 && envelope.modulationPauseFraction >= 0.05
        m.envelope = voice ? .voice : .steady

        // 2. On/off keying (1, noise, was decided by the extent).
        if let keying = envelope.keying {
            if let twin = keyedTwinHz {
                m.envelope = .steady
                m.notes.append(String(format: "Keyed in turn with a tone %+.0f Hz away: one tone of an FSK", twin))
                return
            }
            if line.fraction >= 0.2 {
                m.family = .ook
                m.envelope = .keyed
                m.familyConfidence = min(score(Keying.maxOffRatio - keying.offLevel / keying.onLevel, 0, 0.2),
                                         score(line.fraction, 0.2, 0.35))
                if let unit = keying.morseUnit() {
                    m.cwWPM = 1.2 / unit
                    m.notes.append(String(format: "Keyed carrier, dot %.0f ms", unit * 1000))
                } else {
                    m.notes.append("Keyed carrier, timing not Morse")
                }
                return
            }
            m.envelope = .bursty
            m.notes.append("On/off envelope without a carrier line")
        }
        // A line of a comb is part of a wider signal (an FM tone, APT): neither AM nor a carrier.
        if comb && line.isLine { m.notes.append("A line among equally strong lines: part of a wider signal") }
        // 3. AM.
        if !comb && line.isLine && line.fraction >= minAMCarrierFraction && line.sidebandFraction >= minSidebandFraction
            && envelope.inPhase >= minInPhase {
            m.family = .am
            m.envelope = amVoice ? .voice : .steady
            m.familyConfidence = min(score(envelope.inPhase, minInPhase, 1),
                                     score(line.sidebandFraction, minSidebandFraction, 0.04))
            m.notes.append(String(format: "Carrier with symmetric sidebands (%.0f%% of the power)",
                                  100 * line.sidebandFraction))
            return
        }
        // 4. Carrier.
        if !comb && line.isLine && line.fraction >= minCarrierFraction {
            m.family = .carrier
            m.envelope = .steady
            m.familyConfidence = score(line.fraction, minCarrierFraction, 0.99)
            m.notes.append("Unmodulated carrier")
            return
        }
        // 5. FM.
        if steady && constant && frequency.spread >= minSpread
            && m.occupiedBandwidthHz * m.seconds >= minFMSamples {
            guard !frequency.tonal && frequency.kurtosis >= minKurtosis else {
                m.notes.append("Constant envelope with discrete frequencies (FSK-like)")
                return
            }
            let pilot = frequency.lines.first { abs($0 - 19_000) < 200 }
            m.fmDeviationHz = frequency.deviationHz
            m.envelope = .steady
            if let pilot { m.subcarriersHz.append(pilot) }
            let shape = min(score(frequency.spread, minSpread, 0.25), score(frequency.kurtosis, minKurtosis, 3.5),
                            score(maxConstantM4 - envelope.amplitudeM4, 0, 0.1))
            if m.occupiedBandwidthHz >= 100_000 || (pilot != nil && m.occupiedBandwidthHz >= 60_000) {
                m.family = .wfm
                m.familyConfidence = min(shape, pilot != nil ? 1 : score(m.occupiedBandwidthHz, 100_000, 150_000))
                m.notes.append(pilot != nil ? "Wide FM with a 19 kHz stereo pilot" : "Wide FM")
            } else {
                m.family = .fm
                m.familyConfidence = shape
                m.notes.append("Constant envelope, frequency modulated")
            }
            return
        }
        // 6. SSB.
        if voice && line.fraction < 0.1 && sidebands.asymmetryDb >= 15 && abs(sidebands.tiltDb) >= minTiltDb {
            m.family = sidebands.tiltDb < 0 ? .usb : .lsb
            m.envelope = .voice
            m.familyConfidence = min(score(sidebands.asymmetryDb, 15, 25),
                                     score(abs(sidebands.tiltDb), minTiltDb, 3), score(envelope.blockCV, 0.5, 0.8))
            m.notes.append(String(format: "One sideband, %.0f dB over its mirror; tilted %.1f dB",
                                  sidebands.asymmetryDb, sidebands.tiltDb))
            return
        }
    }

    /// 0.5 at `threshold`, 1 at `solid` and beyond, linear between (0 below the threshold).
    static func score(_ value: Double, _ threshold: Double, _ solid: Double) -> Float {
        guard value >= threshold else { return 0 }
        guard solid > threshold else { return 1 }
        return Float(min(1, 0.5 + 0.5 * (value - threshold) / (solid - threshold)))
    }

    // MARK: Extent

    struct Region {
        var bins: ClosedRange<Int>
        /// The line is one of a comb: lines at ±Δ (Δ < 5 kHz) as strong as it (an FM tone's Bessel lines).
        var comb = false
        /// How far the signal may reach: up to the next other signal beyond a gap, or the region itself when
        /// it was cut halfway to its neighbours (a crowded band).
        var room: ClosedRange<Int>
    }

    /// The signal around `seed` in the coarse view (see the type's notes), or nil when nothing there stands
    /// above the noise.
    static func region(_ view: SpectrumView, seed: ClosedRange<Int>) -> Region? {
        let smoothing = 2
        let es = view.smoothedExcess(reach: smoothing)
        // Neighbouring bins share leakage and frames overlap: about half as many independent ones.
        let sigma = view.spread * (2 / Double(2 * smoothing + 1)).squareRoot()
        let edge = max(edgeSigma * sigma, 0.02)
        let total = seed.reduce(0) { $0 + view.excess($1) }
        guard total >= detectSigma * view.spread * (2 * Double(seed.count)).squareRoot(),
              let first = seed.first(where: { es[$0] >= edge }),
              let last = seed.last(where: { es[$0] >= edge }) else { return nil }
        var lo = first, hi = last
        while lo > 0 && (es[lo - 1] >= edge || (lo > 1 && es[lo - 2] >= edge)) { lo -= 1 }
        while hi < view.count - 1 && (es[hi + 1] >= edge || (hi < view.count - 2 && es[hi + 2] >= edge)) { hi += 1 }
        var bins = lo...hi
        // Up to the next other signal (standing clearly out: 2 × the edge level) beyond a gap, short of its
        // smoothed skirt.
        func room(_ bins: ClosedRange<Int>) -> ClosedRange<Int> {
            var a = bins.lowerBound, b = bins.upperBound
            while a > 0 && es[a - 1] < 2 * edge { a -= 1 }
            while b < view.count - 1 && es[b + 1] < 2 * edge { b += 1 }
            if a > 0 { a = min(bins.lowerBound, a + smoothing + 1) }
            if b < view.count - 1 { b = max(bins.upperBound, b - smoothing - 1) }
            return a...b
        }

        // A carrier line (the seed's own peak): symmetric sidebands about it belong to it.
        let top = seed.clamped(to: bins).max { view.power[$0] < view.power[$1] }!
        let s = 3
        guard top - s >= 0, top + s < view.count,
              view.power[top] >= max(view.power[top - s], view.power[top + s]) * pow(10, lineContrastDb / 10)
        else { return Region(bins: bins, comb: isComb(view, line: top), room: room(bins)) }
        let limit = min(top, view.count - 1 - top)
        // Other lines as strong as this one (within 5 dB) 5 kHz or more away are other stations (MW at 9 or
        // 10 kHz, airband 8.33, HF 5): the growth stops halfway to them. Nearer ones stay (an FSK's tones; a
        // comb is caught below).
        let strong = view.power[top] * pow(10, -sidebandBelowLineDb / 10)
        func isStrongLine(_ k: Int) -> Bool {
            k - s >= 0 && k + s < view.count && view.power[k] >= strong
                && view.power[k] >= max(view.power[k - s], view.power[k + s]) * pow(10, lineContrastDb / 10)
        }
        let near = Int(combMaxHz / view.binHz)
        if let left = stride(from: top - near, through: bins.lowerBound, by: -1).first(where: isStrongLine) {
            bins = max(bins.lowerBound, (left + top + 1) / 2)...bins.upperBound
        }
        if let right = stride(from: top + near, through: bins.upperBound, by: 1).first(where: isStrongLine) {
            bins = bins.lowerBound...min(bins.upperBound, (right + top) / 2)
        }
        // Mirrored about the line, smoothed over ±100 Hz (at least the 5 bins above) for weak, wide sidebands.
        let wide = max(smoothing, Int(mirrorSmoothingHz / view.binHz))
        let ew = view.smoothedExcess(reach: wide)
        let mirrorEdge = max(edgeSigma * view.spread * (2 / Double(2 * wide + 1)).squareRoot(), 0.02)
        func mirrored(_ d: Int) -> Double { min(ew[top - d], ew[top + d]) }
        let half = max(top - bins.lowerBound, bins.upperBound - top)
        let reach = min(limit, half + max(10 * bins.count, Int(sidebandSearchHz / view.binHz)))
        // Sidebands start beyond the line's own skirt (its shoulders and the smoothing).
        var d = s + wide + 1
        var start: Int?
        while d + 1 <= reach {
            if mirrored(d) >= mirrorEdge && mirrored(d + 1) >= mirrorEdge { start = d; break }
            d += 1
        }
        guard let sidebandStart = start else {
            return Region(bins: bins, comb: isComb(view, line: top), room: room(bins))
        }
        var outer = sidebandStart
        var k = outer + 1
        while k <= limit {
            if mirrored(k) >= mirrorEdge { outer = k; k += 1; continue }
            guard k - outer <= max(3, outer / 10) else { break }
            k += 1
        }
        // Strong symmetric neighbours: within 5 kHz, an FM tone's comb; farther out, other stations, so
        // this one's sidebands end halfway to them. A neighbour on one side only ends them short of it.
        let ceiling = view.power[top] * pow(10, -sidebandBelowLineDb / 10)
        for d in sidebandStart...outer where view.power[top - d] > ceiling || view.power[top + d] > ceiling {
            let left = (d - 2...d + 2).map { view.power[top - min($0, limit)] }.max()!
            let right = (d - 2...d + 2).map { view.power[top + min($0, limit)] }.max()!
            guard min(left, right) > ceiling else {
                outer = d - s - wide - 1
                break
            }
            if Double(d) * view.binHz < combMaxHz { return Region(bins: bins, comb: true, room: room(bins)) }
            outer = d / 2
            bins = min(bins.lowerBound, top - outer)...max(bins.upperBound, top + outer)
            return Region(bins: bins, room: bins)
        }
        guard outer >= sidebandStart else { return Region(bins: bins, comb: isComb(view, line: top), room: room(bins)) }
        bins = min(bins.lowerBound, top - outer)...max(bins.upperBound, top + outer)
        return Region(bins: bins, comb: isComb(view, line: top), room: room(bins))
    }

    /// A line with a symmetric pair of components within `combMaxHz`, beyond its skirt (8 bins out or more),
    /// each at most `combBelowLineDb` under it: stronger than any AM's sidebands (a 100% sine's are 6 dB
    /// under the carrier), so the line is one of a comb, an FM tone's Bessel lines. Powers are summed over
    /// ±2 bins.
    static func isComb(_ view: SpectrumView, line top: Int) -> Bool {
        func lobe(_ k: Int) -> Double { (k - 2...k + 2).reduce(0) { $0 + max(0, view.power[$1] - view.noise) } }
        let limit = min(top, view.count - 1 - top) - 2
        let first = 8, last = min(limit, Int(combMaxHz / view.binHz))
        guard first <= last else { return false }
        let floor = lobe(top) * pow(10, -combBelowLineDb / 10)
        return (first...last).contains { min(lobe(top - $0), lobe(top + $0)) >= floor }
    }

    /// A keyed signal's FSK twin: the strongest other signal in the window within ±max(3 kHz, 10 widths),
    /// no more than 10 dB under this one, whose envelope (1 ms steps, smoothed over ~1 / bandwidth) runs
    /// against this one's (correlation ≤ −0.3): it is on while this is off. Its offset from this one, or nil.
    static func keyedTwin(_ window: (samples: [DSPComplex], rate: Double), _ coarse: SpectrumView,
                          region: ClosedRange<Int>, centreHz: Double, channelHz: Double,
                          occupiedHz: Double) -> Double? {
        let reachHz = max(twinSearchHz, 10 * occupiedHz)
        let guardBins = region.count
        let peak = region.map { coarse.power[$0] }.max() ?? 0
        let candidates = (coarse.bin(centreHz - reachHz)...coarse.bin(centreHz + reachHz)).filter {
            $0 < region.lowerBound - guardBins || $0 > region.upperBound + guardBins
        }
        guard let best = candidates.max(by: { coarse.power[$0] < coarse.power[$1] }),
              coarse.power[best] >= peak * pow(10, -twinBelowDb / 10) else { return nil }
        let twinHz = coarse.hz(Double(best))
        let samples = interleaved(window.samples)
        func envelope(_ hz: Double) -> [Double] {
            let z = Channel.extract(samples, sampleRate: window.rate, offsetHz: hz, bandwidthHz: channelHz)
            let step = max(1, Int((0.001 * z.rate).rounded()))
            let power = z.samples.map { $0.real * $0.real + $0.imag * $0.imag }
            return EnvelopeFeatures.blockMeans(power, length: step).map(Double.init)
        }
        let a = envelope(centreHz), b = envelope(twinHz)
        let n = min(a.count, b.count)
        guard n > 100 else { return nil }
        let ma = a[0..<n].reduce(0, +) / Double(n), mb = b[0..<n].reduce(0, +) / Double(n)
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for k in 0..<n {
            sab += (a[k] - ma) * (b[k] - mb)
            saa += (a[k] - ma) * (a[k] - ma)
            sbb += (b[k] - mb) * (b[k] - mb)
        }
        guard saa > 0, sbb > 0, sab / (saa * sbb).squareRoot() <= maxTwinCorrelation else { return nil }
        return twinHz - centreHz
    }

    static func widened(_ bins: ClosedRange<Int>, by fraction: Double, in view: SpectrumView) -> ClosedRange<Int> {
        let extra = max(2, Int(Double(bins.count) * fraction))
        return max(0, bins.lowerBound - extra)...min(view.count - 1, bins.upperBound + extra)
    }

    static func interleaved(_ z: [DSPComplex]) -> [Float] {
        z.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: Float.self, capacity: 2 * z.count) {
                Array(UnsafeBufferPointer(start: $0, count: 2 * z.count))
            }
        }
    }
}

/// The strongest bin of the occupied band as a carrier line: its power over the continuum just past a
/// window main lobe (the mean of the bins 3 and 4 either side, less the noise and twice its scatter),
/// summed over its main lobe (±2 bins), as a share of the signal's power in the occupied band (`total`).
/// A peaked spectrum a few bins wide (PSK31 at fine resolution) has its own skirt there, so it isn't taken
/// for a line.
struct Line {
    /// The line's share of the signal's power.
    var fraction = 0.0
    /// The rest: the sidebands' (or the modulation's) share.
    var sidebandFraction = 1.0
    /// Peak over the continuum, in dB.
    var contrastDb = 0.0
    /// The line's bin, interpolated (log-parabola through the peak and its neighbours).
    var position = 0.0
    var isLine: Bool { contrastDb >= SignalMeasurer.lineContrastDb }

    init(_ view: SpectrumView, occupied: ClosedRange<Int>, total: Double) {
        guard total > 0 else { return }
        let top = occupied.max { view.power[$0] < view.power[$1] }!
        position = Double(top)
        if top > 0 && top < view.count - 1 {
            let a = log(max(view.power[top - 1], 1e-30)), b = log(max(view.power[top], 1e-30))
            let c = log(max(view.power[top + 1], 1e-30))
            let curvature = a - 2 * b + c
            if curvature < 0 { position += min(0.5, max(-0.5, 0.5 * (a - c) / curvature)) }
        }
        let beside = [top - 4, top - 3, top + 3, top + 4].filter { $0 >= 0 && $0 < view.count }
        // Above the noise only by more than twice the scatter of that mean (four bins, in two correlated pairs).
        let scatter = 2 * view.noise * view.spread / 2.0.squareRoot()
        let continuum = max(0, beside.reduce(0) { $0 + view.power[$1] } / Double(max(beside.count, 1))
                            - view.noise - scatter)
        let lobe = max(0, top - 2)...min(view.count - 1, top + 2)
        let power = lobe.reduce(0) { $0 + max(0, view.power[$1] - view.noise - continuum) }
        fraction = min(1, power / total)
        sidebandFraction = 1 - fraction
        contrastDb = 10 * log10(max(view.power[top] - view.noise, 1e-30)
                                / max(continuum, view.noise * view.spread, 1e-30))
    }
}
