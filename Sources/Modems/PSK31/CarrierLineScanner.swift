import Accelerate
import Foundation
import simd

/// The acquisition FFT of the PSK31 decoder: a ring of the last `fftSize` baseband samples and the
/// spectrum of their square (or fourth power), searched for carrier lines.
final class CarrierLineScanner {
    static let fftSize = 512
    static let hop = 128
    /// Half-width, in bins, of the local background a carrier line is measured against.
    static let backgroundBins = 12

    let basebandRate: Double
    private let dft: vDSP_DFT_Setup
    private var ring: [SIMD2<Float>]
    private var head = 0
    private var sinceScan = 0
    /// Samples since the window was last invalidated (negative: also wait for the filters).
    private var fresh = 0
    private let window: [Float]
    private var inRe: [Float], inIm: [Float], outRe: [Float], outIm: [Float]
    private var power: [Float]
    private var prefix: [Double] = []

    init(basebandRate: Double) {
        self.basebandRate = basebandRate
        let n = Self.fftSize
        dft = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD)!
        ring = [SIMD2<Float>](repeating: .zero, count: n)
        window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
        inRe = [Float](repeating: 0, count: n)
        inIm = inRe; outRe = inRe; outIm = inRe; power = inRe
    }

    deinit { vDSP_DFT_DestroySetup(dft) }

    /// Adds a sample; true when a scan is due (every `hop` samples, once the window is fresh).
    func push(_ z: SIMD2<Float>) -> Bool {
        ring[head] = z
        head = (head + 1) & (Self.fftSize - 1)
        fresh += 1
        sinceScan += 1
        guard sinceScan >= Self.hop else { return false }
        sinceScan = 0
        return fresh >= Self.fftSize
    }

    /// The window now mixes two tunings: wait for a full fresh one plus `settleSamples`.
    func invalidate(settleSamples: Int) { fresh = -settleSamples }

    var meanPower: Float {
        var sum: Float = 0
        for z in ring { sum += simd_length_squared(z) }
        return sum / Float(ring.count)
    }

    func reset() {
        for i in ring.indices { ring[i] = .zero }
        head = 0; sinceScan = 0; fresh = 0
    }

    struct LineScan {
        /// Height (over the median bin) and frequency of the accepted in-range carrier line.
        var height: Float
        var offsetHz: Double
        /// Height of the strongest line anywhere in the extended range, and of the bins at zero offset.
        var global: Float
        var nearZero: Float
    }

    /// Spectrum of z^power over the last FFT window, searched for carrier lines.
    /// `lineHeight`: the height a peak needs to count as a line when deciding whether an in-range
    /// peak is only its idle sideline.
    func scan(power m: Int, scale: Float, inRangeHz: Double, sidelineHz: Double, lineHeight: Float) -> LineScan {
        let n = Self.fftSize
        let binHz = basebandRate / Double(n)
        for i in 0..<n {
            let z = ring[(head + i) & (n - 1)]
            var w = z
            for _ in 1..<m { w = cmul(w, z) }
            inRe[i] = w.x * scale * window[i]
            inIm[i] = w.y * scale * window[i]
        }
        vDSP_DFT_Execute(dft, inRe, inIm, &outRe, &outIm)
        for i in 0..<n { power[i] = outRe[i] * outRe[i] + outIm[i] * outIm[i] }
        func pw(_ b: Int) -> Float { power[(b % n + n) % n] }

        let inRange = Int(inRangeHz / binHz)
        let sideBins = Int((sidelineHz / binHz).rounded())
        // z^m of an idle signal has lines at multiples of the symbol rate around its carrier line.
        let extended = min(inRange + (m / 2) * sideBins + 3, n / 2 - 1 - Self.backgroundBins)

        // Height of a bin over its local background: the mean of the bins within ±backgroundBins,
        // leaving out its own ±3, scaled by ln 2 so pure noise reads like peak/median. A carrier
        // line is narrow; the cross-terms of a strong neighbour are broad humps and stay low.
        let reach = extended + Self.backgroundBins
        prefix.removeAll(keepingCapacity: true)
        prefix.append(0)
        for b in -reach...reach { prefix.append(prefix[prefix.count - 1] + Double(pw(b))) }
        func sum(_ lo: Int, _ hi: Int) -> Double { prefix[hi + reach + 1] - prefix[lo + reach] }
        func height(_ b: Int) -> Float {
            let w = Self.backgroundBins
            let total = sum(b - w, b + w) - sum(b - 3, b + 3)
            let mean = total / Double(2 * w - 6)
            return Float(Double(pw(b)) / max(mean * 0.693, 1e-30))
        }

        var global: Float = 0
        for b in -extended...extended { global = max(global, height(b)) }

        // Highest in-range line that is not a sideline of a stronger line (up to three tries).
        var masked: [Int] = []
        var best = 0
        var bestHeight: Float = 0
        for _ in 0..<3 {
            best = 0; bestHeight = -1
            for b in -inRange...inRange where !masked.contains(where: { abs($0 - b) <= 3 }) {
                let h = height(b)
                if h > bestHeight { bestHeight = h; best = b }
            }
            var isSideline = false
            for k in 1...max(1, m / 2) {
                for sign in [-1, 1] {
                    // The parent must be stronger and a narrow line: a strong neighbour's broad
                    // cross-terms are stronger per bin than a weak signal's line, but not narrow.
                    let c = best + sign * k * sideBins
                    let parent = max(pw(c - 1), pw(c), pw(c + 1))
                    let narrow = max(height(c - 1), height(c), height(c + 1)) >= lineHeight
                    if parent >= 2 * pw(best) && narrow { isSideline = true }
                }
            }
            if !isSideline { break }
            masked.append(best)
            bestHeight = 0
        }

        // Prefer a line nearer zero offset when it is at least half as high: noise can tip a weak
        // idle's sideline over its carrier line, and a jump to it costs seconds. A real offset
        // carrier's own sideline near zero is a quarter of it, so it is not taken.
        let inner = abs(best) - 4
        if inner >= 0 {
            var closer = 0, closerHeight: Float = -1
            for b in -inner...inner where !masked.contains(where: { abs($0 - b) <= 3 }) {
                let h = height(b)
                if h > closerHeight { closerHeight = h; closer = b }
            }
            if closerHeight >= 0.5 * bestHeight {
                // One sideline spacing apart, one of the two is the other's sideline. An idle carrier
                // line has a sideline on both sides; a sideline has the carrier on one side only.
                func flanks(_ b: Int) -> Float {
                    min(max(pw(b - sideBins - 1), pw(b - sideBins), pw(b - sideBins + 1)),
                        max(pw(b + sideBins - 1), pw(b + sideBins), pw(b + sideBins + 1)))
                }
                let related = abs(abs(best - closer) - sideBins) <= 3
                if !related || flanks(closer) >= flanks(best) { best = closer; bestHeight = closerHeight }
            }
        }

        var nearZero: Float = 0
        let zeroBins = max(2, Int(Double(m) * 1.5 / binHz))
        for b in -zeroBins...zeroBins { nearZero = max(nearZero, height(b)) }

        // Parabolic interpolation on magnitude.
        let l = pw(best - 1).squareRoot(), c = pw(best).squareRoot(), r = pw(best + 1).squareRoot()
        let denom = l - 2 * c + r
        let delta = denom < 0 ? Double(0.5 * (l - r) / denom) : 0
        return LineScan(height: max(bestHeight, 0), offsetHz: (Double(best) + max(min(delta, 0.5), -0.5)) * binHz,
                        global: global, nearZero: nearZero)
    }
}
