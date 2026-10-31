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
/// growing and the 6 dB test. `lowerBin…upperBin` is inclusive; `peakBin` is its strongest (unsmoothed) bin.
///
/// Growth also bridges a gap to a further region of signal (two contiguous bins 6 dB over the noise) in two
/// cases: a twin (peak within 6 dB and width within 2× of the region beside the gap, across no more than
/// 12 of its widths: the tones of a wide-shift FSK), and the sidebands of a carrier (the peak's own region
/// is a narrow line, at most 30 Hz or 12 bins, and the gap at most 10 of its widths or 600 Hz: AM with a
/// low-cut audio filter).
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
    static let twinLevelDb = 6.0
    static let twinWidthRatio = 2.0
    static let twinGapWidths = 12
    static let lineMaxHz = 30.0
    static let lineMaxBins = 12
    static let lineGapWidths = 10
    static let lineGapHz = 600.0

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
            let grown = grow(level, from: top, noise: noise, binHz: binHz)
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

    /// The region around `top` at ≥ noise + 3 dB, bridged across gaps to twins and to a carrier's sidebands.
    private static func grow(_ level: [Double], from top: Int, noise: Double, binHz: Double) -> ClosedRange<Int> {
        let edge = noise * pow(10, edgeDb / 10)
        let detect = noise * pow(10, detectDb / 10)
        let n = level.count
        let core = region(level, from: top, above: edge)
        let isLine = Double(core.count) * binHz <= max(lineMaxHz, Double(lineMaxBins) * binHz)
        var lower = core.lowerBound, upper = core.upperBound
        for direction in [-1, 1] {
            var adjacent = core
            while true {
                let edgeBin = direction < 0 ? lower : upper
                let width = adjacent.count
                let fromLine = isLine && adjacent == core
                let reach = fromLine ? max(lineGapWidths * width, Int(lineGapHz / binHz)) : twinGapWidths * width
                // Further regions start with two contiguous bins 6 dB up. A carrier takes the nearest; a
                // region takes the nearest twin, passing over smaller bumps in between.
                let nearPeak = adjacent.map { level[$0] }.max()!
                var accepted: ClosedRange<Int>?
                var k = edgeBin + direction
                while accepted == nil, abs(k - edgeBin) <= reach + 1, k + direction >= 0, k + direction < n {
                    guard level[k] >= detect && level[k + direction] >= detect else { k += direction; continue }
                    let far = region(level, from: k, above: edge)
                    let gap = direction < 0 ? edgeBin - far.upperBound - 1 : far.lowerBound - edgeBin - 1
                    guard gap <= reach else { break }
                    let farPeak = far.map { level[$0] }.max()!
                    let twin = abs(10 * log10(farPeak / nearPeak)) <= twinLevelDb
                        && Double(min(far.count, width)) / Double(max(far.count, width)) >= 1 / twinWidthRatio
                    if fromLine || twin { accepted = far }
                    k = (direction < 0 ? far.lowerBound : far.upperBound) + direction
                }
                guard let far = accepted else { break }
                if direction < 0 { lower = far.lowerBound } else { upper = far.upperBound }
                adjacent = far
            }
        }
        return lower...upper
    }

    /// The contiguous bins around `bin` at or above `threshold` (at least `bin` itself).
    private static func region(_ level: [Double], from bin: Int, above threshold: Double) -> ClosedRange<Int> {
        var lo = bin, hi = bin
        while lo > 0 && level[lo - 1] >= threshold { lo -= 1 }
        while hi < level.count - 1 && level[hi + 1] >= threshold { hi += 1 }
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
    /// The average (in power) of non-overlapping windowed FFT frames of `size` (a power of two), in dB,
    /// FFT-shifted: index 0 is −rate/2, `size / 2` is 0 Hz. A unit complex tone reads 0 dB.
    /// Frames beyond `maxFrames` are skipped (spread evenly over the input). Fewer than `size` samples
    /// give a zero-padded single frame.
    public static func average(_ samples: [DSPComplex], size: Int, window: WindowKind = .blackmanHarris,
                               maxFrames: Int = 256) -> [Float] {
        let analyzer = SpectrumAnalyzer(size: size, window: window)
        var frame = [Float](repeating: 0, count: size)
        var sum = [Float](repeating: 0, count: size)
        var input = samples
        if input.count < size {
            input += [DSPComplex](repeating: DSPComplex(real: 0, imag: 0), count: size - input.count)
        }
        let available = input.count / size
        let frames = min(available, max(1, maxFrames))
        input.withUnsafeBufferPointer { x in
            for i in 0..<frames {
                let start = (i * available / frames) * size
                frame.withUnsafeMutableBufferPointer { f in
                    analyzer.process(UnsafeBufferPointer(rebasing: x[start..<(start + size)]), into: f)
                    // Back to power to average.
                    var count = Int32(size)
                    var ten: Float = 0.1
                    vDSP_vsmul(f.baseAddress!, 1, &ten, f.baseAddress!, 1, vDSP_Length(size))
                    var base = [Float](repeating: 10, count: size)
                    vvpowf(f.baseAddress!, f.baseAddress!, &base, &count)
                }
                vDSP_vadd(sum, 1, frame, 1, &sum, 1, vDSP_Length(size))
            }
        }
        var scale = 1 / Float(frames)
        vDSP_vsmul(sum, 1, &scale, &sum, 1, vDSP_Length(size))
        var floor: Float = 1e-30
        vDSP_vthr(sum, 1, &floor, &sum, 1, vDSP_Length(size))
        var reference: Float = 1
        vDSP_vdbcon(sum, 1, &reference, &sum, 1, vDSP_Length(size), 0)
        return sum
    }

    /// The same, from interleaved IQ.
    public static func average(_ iq: [Float], size: Int, window: WindowKind = .blackmanHarris,
                               maxFrames: Int = 256) -> [Float] {
        let n = iq.count / 2
        guard n > 0 else { return average([DSPComplex](), size: size, window: window, maxFrames: maxFrames) }
        let samples = iq.withUnsafeBufferPointer { raw in
            raw.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n) {
                Array(UnsafeBufferPointer(start: $0, count: n))
            }
        }
        return average(samples, size: size, window: window, maxFrames: maxFrames)
    }
}
