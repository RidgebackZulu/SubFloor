import Accelerate
import DSPCore
import Foundation

/// Where a signal lies in an averaged spectrum, and its SNR.
///
/// `spectrumDb` is an averaged power spectrum (as `PowerSpectrum.average` gives). From the strongest bin
/// within `searchBins` of `nearBin`, it climbs to the top of that hill and grows outwards while the level
/// stays at least 3 dB over the local noise. The local noise is the median of the bins within ±10 × the
/// signal's width, the signal's own bins left out; it starts from the spectrum's 10th percentile and is
/// found again after each growth until it settles. Levels are smoothed over 3 bins for the climbing, the
/// growing and the 6 dB test, but two raw bins in a row under noise + 3 dB still end the growth, so the
/// smoothing never joins neighbours. `lowerBin…upperBin` is inclusive; `peakBin` is its strongest
/// (unsmoothed) bin.
///
/// When the peak is a carrier line, growth also takes in sidebands that sit symmetrically about it (AM whose
/// audio has a low-cut leaves a gap beside the carrier). A line is told by its shape, whatever the
/// resolution: its strongest bin stands 15 dB over the bins 3 either side (a Blackman-Harris main lobe is
/// ≥ 22 dB down there even for a tone between bins; a signal several bins wide is not). The level mirrored
/// about the line, min(left, right) over 5 bins, must rise 6 dB over the noise beyond the line's own skirt
/// and within 10 line widths or 600 Hz of it; the extent runs out to where that mirrored level stays below
/// noise + 3 dB; and every bin of those sidebands, on either side, must sit at least 6 dB below the line
/// (AM's sidebands always do; neighbours of equal strength never do). A neighbour on one side only is never
/// taken in. Separate signals side by side are never merged otherwise: two equal tones (a wide-shift FSK)
/// are two extents here, and pairing them is the FSK measurement's job (the instantaneous-frequency
/// histogram).
///
/// It returns nil when:
/// - nothing within `searchBins` stands 6 dB above the local noise;
/// - the hill rises out of the search window and the window sits more than 20 dB below its top: the
///   pointer is on another signal's skirt (window leakage, splatter), not on a signal of its own.
///
/// SNR is the power over the noise in the extent's bins (each bin's level less the noise, summed) over the
/// noise power in the same bins. The window's equivalent noise bandwidth cancels in that ratio.
public enum Extent {
    static let detectDb = 6.0
    static let edgeDb = 3.0
    static let skirtDb = 20.0
    static let noiseWidths = 10
    static let lineContrastDb = 15.0
    static let lineShoulderBins = 3
    static let sidebandBelowLineDb = 6.0
    static let sidebandGapWidths = 10
    static let sidebandGapHz = 600.0
    static let mirrorSmoothing = 2

    public static func find(spectrumDb: [Float], binHz: Double, nearBin: Int,
                            searchBins: Int) -> (lowerBin: Int, upperBin: Int, peakBin: Int, snrDb: Double)? {
        let n = spectrumDb.count
        guard n >= 8, nearBin >= 0, nearBin < n, binHz > 0 else { return nil }
        let raw = spectrumDb.map { pow(10, Double($0) / 10) }
        let level = (0..<n).map { k in
            let lo = max(0, k - 1), hi = min(n - 1, k + 1)
            return raw[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
        let window = max(0, nearBin - max(searchBins, 0))...min(n - 1, nearBin + max(searchBins, 0))
        var best = window.lowerBound
        for k in window where level[k] > level[best] { best = k }

        // The hill the window's strongest bin stands on.
        var top = best
        while top > 0 && level[top - 1] > level[top] { top -= 1 }
        while top < n - 1 && level[top + 1] > level[top] { top += 1 }

        // First guess: the 10th percentile of the whole spectrum (robust while signals fill less than 90% of it).
        var noise = raw.sorted()[n / 10]
        var extent = top...top
        for _ in 0..<4 {
            guard noise > 0 else { return nil }
            let grown = grow(level, raw: raw, from: top, noise: noise, binHz: binHz)
            let width = grown.count
            let centre = (grown.lowerBound + grown.upperBound) / 2
            let next = median(raw, around: centre, halfWidth: noiseWidths * width, excluding: grown)
            let settled = grown == extent && abs(next / noise - 1) < 0.01
            extent = grown
            noise = next
            if settled { break }
        }
        guard noise > 0, level[best] >= noise * pow(10, detectDb / 10) else { return nil }
        if !window.contains(top) {
            // Climbed out of the window: on someone's skirt unless the window is within the signal's top 20 dB.
            guard extent.overlaps(window), level[best] >= level[top] * pow(10, -skirtDb / 10) else { return nil }
        }
        var peak = extent.lowerBound
        var signal = 0.0
        for k in extent {
            if raw[k] > raw[peak] { peak = k }
            signal += raw[k] - noise
        }
        let snr = 10 * log10(max(signal, 1e-30) / (noise * Double(extent.count)))
        return (extent.lowerBound, extent.upperBound, peak, snr)
    }

    // MARK: Growth

    /// The region around `top` at ≥ noise + 3 dB, and a line's symmetric sidebands.
    private static func grow(_ level: [Double], raw: [Double], from top: Int, noise: Double,
                             binHz: Double) -> ClosedRange<Int> {
        let edge = noise * pow(10, edgeDb / 10)
        let detect = noise * pow(10, detectDb / 10)
        let n = level.count
        let core = region(level, raw: raw, from: top, above: edge)
        // A line: the strongest raw bin near the top stands well over the raw bins 3 either side of it.
        let s = lineShoulderBins
        guard top - 1 - s >= 0, top + 1 + s < n else { return core }
        let peak = (top - 1...top + 1).max { raw[$0] < raw[$1] }!
        guard raw[peak] >= max(raw[peak - s], raw[peak + s]) * pow(10, lineContrastDb / 10) else { return core }
        // Mirrored about the line: both sides must carry signal at the same distance.
        let half = max(top - core.lowerBound, core.upperBound - top)
        let limit = min(top, n - 1 - top)
        guard limit > mirrorSmoothing + 1 else { return core }
        func mirrored(_ d: Int) -> Double {
            var left = 0.0, right = 0.0, count = 0
            for j in max(1, d - mirrorSmoothing)...min(limit, d + mirrorSmoothing) {
                left += level[top - j]
                right += level[top + j]
                count += 1
            }
            return min(left, right) / Double(max(count, 1))
        }
        let reach = half + max(sidebandGapWidths * core.count, Int(sidebandGapHz / binHz))
        // Sidebands start beyond the line's own skirt: its shoulders, the smoothing and the mirror's average.
        var d = max(half, lineShoulderBins + 1 + mirrorSmoothing) + 1
        var start: Int?
        while d + 1 <= min(reach, limit) {
            if mirrored(d) >= detect && mirrored(d + 1) >= detect { start = d; break }
            d += 1
        }
        guard let first = start else { return core }
        var outer = first
        // Out to where the mirrored level stays below noise + 3 dB (dips shorter than 3 bins or 10% bridged).
        var k = outer + 1
        while k <= limit {
            if mirrored(k) >= edge { outer = k; k += 1; continue }
            let tolerance = max(3, outer / 10)
            guard k - outer <= tolerance else { break }
            k += 1
        }
        // Sidebands sit well below their carrier; a neighbour as strong as the line is not a sideband.
        let ceiling = level[top] * pow(10, -sidebandBelowLineDb / 10)
        for d in first...outer {
            guard level[top - d] <= ceiling && level[top + d] <= ceiling else { return core }
        }
        return min(core.lowerBound, top - outer)...max(core.upperBound, top + outer)
    }

    /// The contiguous bins around `bin` whose smoothed level is at or above `threshold` (at least `bin`
    /// itself). Two raw bins in a row under it end the region even where the smoothing carries on, so
    /// smoothing never joins neighbours across a gap.
    private static func region(_ level: [Double], raw: [Double], from bin: Int,
                               above threshold: Double) -> ClosedRange<Int> {
        let n = level.count
        func gap(_ k: Int, _ step: Int) -> Bool {
            raw[k] < threshold && (k + step < 0 || k + step >= n || raw[k + step] < threshold)
        }
        var lo = bin, hi = bin
        while lo > 0 && level[lo - 1] >= threshold && !gap(lo - 1, -1) { lo -= 1 }
        while hi < n - 1 && level[hi + 1] >= threshold && !gap(hi + 1, 1) { hi += 1 }
        return lo...hi
    }

    /// Median of the bins within ±`halfWidth` of `centre`, leaving out `excluding` (the whole spectrum
    /// outside `excluding` when fewer than 16 bins remain).
    private static func median(_ raw: [Double], around centre: Int, halfWidth: Int,
                               excluding: ClosedRange<Int>) -> Double {
        let lo = max(0, centre - halfWidth), hi = min(raw.count - 1, centre + halfWidth)
        var values = (lo...hi).filter { !excluding.contains($0) }.map { raw[$0] }
        if values.count < 16 { values = raw.indices.filter { !excluding.contains($0) }.map { raw[$0] } }
        guard !values.isEmpty else { return 0 }
        values.sort()
        return values[values.count / 2]
    }
}

/// Averaged power spectra of IQ, as Signal ID reads them.
public enum PowerSpectrum {
    /// The average (in power) of windowed FFT frames of `size` (a power of two), in dB, FFT-shifted: index 0
    /// is −rate/2, `size / 2` is 0 Hz. A unit complex tone reads 0 dB. Frames start every `hop` samples
    /// (default `size`: no overlap); frames beyond `maxFrames` are skipped (spread evenly over the input).
    /// Fewer than `size` samples give a zero-padded single frame.
    public static func average(_ samples: [DSPComplex], size: Int, window: WindowKind = .blackmanHarris,
                               maxFrames: Int = 256, hop: Int? = nil) -> [Float] {
        decibels(averagePower(samples, size: size, window: window, maxFrames: maxFrames, hop: hop))
    }

    /// The same, from interleaved IQ: read where it lies (never copied: a 3 s read at 10 MS/s is 240 MB), and only
    /// the frames used.
    public static func average(_ iq: [Float], size: Int, window: WindowKind = .blackmanHarris,
                               maxFrames: Int = 256, hop: Int? = nil) -> [Float] {
        let n = iq.count / 2
        let power = iq.withUnsafeBufferPointer { raw -> [Float] in
            guard n > 0 else {
                return averagePower(UnsafeBufferPointer<DSPComplex>(start: nil, count: 0), size: size, window: window,
                                    maxFrames: maxFrames, hop: hop)
            }
            return raw.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n) {
                averagePower(UnsafeBufferPointer(start: $0, count: n), size: size, window: window,
                             maxFrames: maxFrames, hop: hop)
            }
        }
        return decibels(power)
    }

    /// Linear power to dB (floored at −300 dB).
    private static func decibels(_ power: [Float]) -> [Float] {
        var sum = power
        let size = sum.count
        var floor: Float = 1e-30
        vDSP_vthr(sum, 1, &floor, &sum, 1, vDSP_Length(size))
        var reference: Float = 1
        vDSP_vdbcon(sum, 1, &reference, &sum, 1, vDSP_Length(size), 0)
        return sum
    }

    /// `average` in linear power (not floored).
    static func averagePower(_ samples: [DSPComplex], size: Int, window: WindowKind = .blackmanHarris,
                             maxFrames: Int = 256, hop: Int? = nil) -> [Float] {
        samples.withUnsafeBufferPointer {
            averagePower($0, size: size, window: window, maxFrames: maxFrames, hop: hop)
        }
    }

    /// The same, from samples read in place: only an input shorter than one frame is copied (to pad it).
    static func averagePower(_ samples: UnsafeBufferPointer<DSPComplex>, size: Int,
                             window: WindowKind = .blackmanHarris, maxFrames: Int = 256, hop: Int? = nil) -> [Float] {
        guard samples.count >= size else {
            var padded = [DSPComplex](repeating: DSPComplex(real: 0, imag: 0), count: size)
            if let base = samples.baseAddress, !samples.isEmpty {
                padded.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: base, count: samples.count) }
            }
            return padded.withUnsafeBufferPointer {
                averagePower($0, size: size, window: window, maxFrames: maxFrames, hop: hop)
            }
        }
        let analyzer = SpectrumAnalyzer(size: size, window: window)
        var frame = [Float](repeating: 0, count: size)
        var sum = [Float](repeating: 0, count: size)
        let step = max(1, hop ?? size)
        let available = (samples.count - size) / step + 1
        let frames = min(available, max(1, maxFrames))
        var base = [Float](repeating: 10, count: size)
        for i in 0..<frames {
            let start = (i * available / frames) * step
            frame.withUnsafeMutableBufferPointer { f in
                analyzer.process(UnsafeBufferPointer(rebasing: samples[start..<(start + size)]), into: f)
                // Back to power to average.
                var count = Int32(size)
                var ten: Float = 0.1
                vDSP_vsmul(f.baseAddress!, 1, &ten, f.baseAddress!, 1, vDSP_Length(size))
                vvpowf(f.baseAddress!, f.baseAddress!, &base, &count)
            }
            vDSP_vadd(sum, 1, frame, 1, &sum, 1, vDSP_Length(size))
        }
        var scale = 1 / Float(frames)
        vDSP_vsmul(sum, 1, &scale, &sum, 1, vDSP_Length(size))
        return sum
    }
}
