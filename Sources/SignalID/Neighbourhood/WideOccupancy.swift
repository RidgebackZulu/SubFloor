import Accelerate
import DSPCore
import Foundation

/// Positive evidence for a signal too wide for the neighbourhood to show its edges. A receiver's own passband fills a
/// capture with noise and looks like one signal hundreds of kHz wide, so being above the floor says nothing. Around the
/// point the capture's spectrum (smoothed over 0.5% of it) must make a stretch within 6 dB of the point's level, at
/// least 24 kHz wide (the neighbourhood is 48: wider than half of it can blind the map's noise level) with nothing in
/// it standing 10 dB over that level: a strong line in the stretch isn't flat-topped occupancy, and proves nothing about
/// the point. Then one of these must hold:
/// - **flat-topped with sharp edges:** it falls at least 15 dB within 2% of its width on each side, or on one if it
///   runs off the capture on the other (DAB at a good SNR). A real passband takes many times that to fall 10 dB;
/// - **a constant envelope:** the channel over everything above the floor there, at most 400 kHz wide (any FM broadcast;
///   a passband is far wider), holds a signal whose power doesn't vary like noise (E|s|⁴/(E|s|²)² under 1.6, where noise
///   gives 2), with no few bins holding most of it (WFM, whose bell-shaped spectrum never has sharp edges);
/// - **a cyclic prefix:** edges of at least 6 dB within that 2%, not enough on their own (DAB at 10 dB has only 10 dB
///   to fall), with OFDM's prefix seen in the channel.
enum WideOccupancy {
    static let flatDb = 6.0
    static let fallDb = 15.0
    static let edgeShare = 0.02
    static let minWidthHz = 24_000.0
    static let smoothingShare = 400
    static let captureEdgeShare = 100
    static let peakOverFlatDb = 10.0
    static let floorAboveDb = 3.0
    static let minContrastDb = 6.0
    static let maxEnvelopeWidthHz = 400_000.0
    static let maxConstantM4 = 1.6
    static let minStretchShare = 0.25
    /// The strongest this share of the channel's bins may hold at most half its power.
    static let lineBinShare = 0.01
    static let maxLinePower = 0.5
    static let shallowFallDb = 6.0
    /// How much of the newest IQ the envelope and the prefix are read from.
    static let evidenceSeconds = 0.25

    static func find(_ db: [Float], iq: [Float], sampleRate: Double,
                     pointHz: Double) -> (offsetHz: Double, widthHz: Double)? {
        let n = db.count
        guard n >= 64, sampleRate > minWidthHz else { return nil }
        let binHz = sampleRate / Double(n)
        let near = n / 2 + Int((pointHz / binHz).rounded())
        guard near >= 0, near < n else { return nil }
        let raw = db.map { Float(pow(10, Double($0) / 10)) }
        let power = TraceFinder.smoothed(raw, reach: max(1, n / smoothingShare))
        let level = power.map { 10 * log10(max(Double($0), 1e-30)) }
        let reach = max(2, Int(SignalIdentifier.localWindowHz / 2 / binHz))
        let around = level[max(0, near - reach)...min(n - 1, near + reach)].sorted()
        let top = around[around.count / 2]
        func stretch(above threshold: Double) -> ClosedRange<Int> {
            var low = near, high = near
            while low > 0 && level[low - 1] >= threshold { low -= 1 }
            while high < n - 1 && level[high + 1] >= threshold { high += 1 }
            return low...high
        }
        let flat = stretch(above: top - flatDb)
        guard Double(flat.count) * binHz >= minWidthHz,
              (level[flat].max() ?? top) <= top + peakOverFlatDb else { return nil }
        func answer(_ bins: ClosedRange<Int>) -> (offsetHz: Double, widthHz: Double) {
            ((Double(bins.lowerBound + bins.upperBound) / 2 - Double(n / 2)) * binHz, Double(bins.count) * binHz)
        }

        // The edges: the level a step past each, where the capture goes on that far.
        let step = max(1, Int(edgeShare * Double(flat.count)))
        let margin = n / captureEdgeShare
        let offLow = flat.lowerBound <= margin, offHigh = flat.upperBound >= n - 1 - margin
        func falls(_ k: Int, by db: Double) -> Bool { k >= 0 && k < n && level[k] <= top - db }
        func edges(fall db: Double) -> Bool {
            !(offLow && offHigh) && (offLow || falls(flat.lowerBound - step, by: db))
                && (offHigh || falls(flat.upperBound + step, by: db))
        }
        if edges(fall: fallDb) { return answer(flat) }

        // What the channel holds.
        let floor = level.sorted()[n / 20]
        guard top - floor >= minContrastDb else { return nil }
        let frames = min(iq.count / 2, Int(evidenceSeconds * sampleRate))
        guard frames > 0 else { return nil }
        let recent = iq.count / 2 == frames ? iq : Array(iq.suffix(2 * frames))
        if edges(fall: shallowFallDb) {
            let (centre, width) = answer(flat)
            let channel = Channel.extract(recent, sampleRate: sampleRate, offsetHz: centre, bandwidthHz: width)
            if OFDMFeatures(channel.samples, rate: channel.rate, occupiedHz: width)?.isOFDM == true { return answer(flat) }
        }
        let whole = stretch(above: floor + floorAboveDb)
        guard Double(whole.count) * binHz <= maxEnvelopeWidthHz else { return nil }
        let inFlat = flat.reduce(0.0) { $0 + Double(power[$1]) }, inWhole = whole.reduce(0.0) { $0 + Double(power[$1]) }
        guard inFlat >= minStretchShare * inWhole, !heldByLines(raw[whole]) else { return nil }
        let (centre, width) = answer(whole)
        let channel = Channel.extract(recent, sampleRate: sampleRate, offsetHz: centre, bandwidthHz: width)
        guard momentRatio(channel.samples) < maxConstantM4 else { return nil }
        return answer(whole)
    }

    /// A few bins hold most of the power: a carrier's constant envelope, not a wide signal's.
    static func heldByLines(_ bins: ArraySlice<Float>) -> Bool {
        let sorted = bins.sorted(by: >)
        let top = max(1, Int(lineBinShare * Double(sorted.count)))
        let held = sorted.prefix(top).reduce(0.0) { $0 + Double($1) }
        let total = sorted.reduce(0.0) { $0 + Double($1) }
        return total > 0 && held > maxLinePower * total
    }

    /// E|s|⁴ / (E|s|²)².
    static func momentRatio(_ z: [DSPComplex]) -> Double {
        var m2 = 0.0, m4 = 0.0
        for s in z {
            let p = Double(s.real * s.real + s.imag * s.imag)
            m2 += p
            m4 += p * p
        }
        guard !z.isEmpty, m2 > 0 else { return .infinity }
        m2 /= Double(z.count)
        return m4 / Double(z.count) / (m2 * m2)
    }
}
