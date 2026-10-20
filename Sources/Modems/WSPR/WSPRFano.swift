import Foundation

/// Fano sequential decoder for the WSPR K = 32, rate-1/2 convolutional code (`WSPRCodec.convolve`).
///
/// Written from the textbook algorithm (R. M. Fano, "A heuristic discussion of probabilistic
/// decoding", IEEE Trans. IT-9, 1963; S. Lin and D. J. Costello, "Error Control Coding", the Fano
/// algorithm flowchart), not from any program's source.
///
/// The decoder walks the code tree one information bit at a time, keeping a running threshold T:
/// - **Look forward** along the best untried branch of the current node. If the path metric there is
///   at least T, move forward; on a node's first visit (its parent's metric was below T + Δ), raise T
///   by steps of Δ while the new metric is still at least T + Δ.
/// - Otherwise **look back**. If the parent's metric is at least T, move back to it and try its
///   other branch; if the branch just left was already its second, keep looking back. If the parent
///   is below T (or this is the root), lower T by Δ and look forward again from the best branch.
/// - The last K − 1 = 31 levels are the zero tail, so those nodes have one branch only.
///
/// Branch metrics are the Fano metric `log2(p(r|c) / p(r)) − R` per code bit, from a Gaussian model of
/// the soft symbols at a nominal Eb/N0, scaled to integers; the threshold step is Δ = 60 in those
/// units.
public enum WSPRFano {
    /// Threshold step Δ in integer metric units.
    public static let thresholdStep: Int32 = 60
    /// The Eb/N0 (rate-1/2 convention) of the Gaussian channel model behind the metric table.
    static let nominalEbN0Db = 3.0
    /// Integer metric units per bit of Fano metric.
    static let metricScale = 10.0
    /// Soft inputs are normalised to unit RMS and quantised over ±`softRange`.
    static let softRange: Float = 3.5
    static let levels = 256

    /// The Fano metric of code bit 0 (`[0..<256]`) and code bit 1 (`[256..<512]`) for each
    /// quantisation level, from low (strong 0) to high (strong 1).
    static let metricTable: [Int32] = makeMetricTable(ebN0Db: nominalEbN0Db, scale: metricScale)

    /// Result of a successful decode.
    struct Decoded: Equatable {
        /// The 50 message bits as 7 bytes, last 6 bits zero.
        var bytes: [UInt8]
        /// Path metric of the decoded path, in integer metric units.
        var metric: Int32
        /// Look-forward steps taken.
        var cycles: Int
    }

    /// Decodes 162 soft code-bit metrics, in code order (deinterleaved): positive means a 1, negative
    /// a 0, any scale. Returns the 7 message bytes, or nil if the input is malformed or the search
    /// takes more than `maxCycles` look-forward steps per information bit (81 bits).
    public static func decode(softSymbols: [Float], maxCycles: Int = 10_000) -> [UInt8]? {
        decodeDetailed(softSymbols: softSymbols, maxCycles: maxCycles)?.bytes
    }

    static func decodeDetailed(softSymbols: [Float], maxCycles: Int = 10_000,
                               table: [Int32] = metricTable, step: Int32 = thresholdStep) -> Decoded? {
        guard softSymbols.count == WSPRCodec.symbolCount, maxCycles > 0,
              let q = quantise(softSymbols) else { return nil }
        let n = WSPRCodec.encodedBits
        let message = WSPRCodec.messageBits
        let p1 = WSPRCodec.poly1, p2 = WSPRCodec.poly2

        // Per depth d (0…n): the encoder register on arriving at d, the path metric, and for the
        // node's branches: the better and worse metrics, the better branch's bit, and which one is
        // being explored (0 = better, 1 = worse).
        var register = [UInt32](repeating: 0, count: n + 1)
        var pathMetric = [Int32](repeating: 0, count: n + 1)
        var bestGain = [Int32](repeating: 0, count: n)
        var worstGain = [Int32](repeating: 0, count: n)
        var bestBit = [UInt32](repeating: 0, count: n)
        var tried = [UInt8](repeating: 0, count: n)
        var bits = [UInt32](repeating: 0, count: n)

        return table.withUnsafeBufferPointer { m -> Decoded? in
            func gain(_ reg: UInt32, _ d: Int) -> Int32 {
                let a = Int(WSPRCodec.parity(reg & p1)), b = Int(WSPRCodec.parity(reg & p2))
                return m[a * levels + Int(q[2 * d])] + m[b * levels + Int(q[2 * d + 1])]
            }
            /// Fills the branch metrics of node d.
            func expand(_ d: Int) {
                let zero = register[d] << 1
                let g0 = gain(zero, d)
                guard d < message else {
                    bestGain[d] = g0; bestBit[d] = 0; tried[d] = 0
                    return
                }
                let g1 = gain(zero | 1, d)
                if g1 > g0 {
                    bestGain[d] = g1; worstGain[d] = g0; bestBit[d] = 1
                } else {
                    bestGain[d] = g0; worstGain[d] = g1; bestBit[d] = 0
                }
                tried[d] = 0
            }

            var d = 0
            var threshold: Int32 = 0
            expand(0)
            let budget = maxCycles.multipliedReportingOverflow(by: n)
            let limit = budget.overflow ? Int.max : budget.partialValue
            var cycles = 0
            while cycles < limit {
                cycles += 1
                // Look forward.
                let second = tried[d] == 1
                let forward = pathMetric[d] + (second ? worstGain[d] : bestGain[d])
                if forward >= threshold {
                    let bit = second ? 1 - bestBit[d] : bestBit[d]
                    bits[d] = bit
                    register[d + 1] = register[d] << 1 | bit
                    pathMetric[d + 1] = forward
                    let firstVisit = pathMetric[d] < threshold + step
                    d += 1
                    if d == n {
                        return Decoded(bytes: pack(bits, count: message), metric: forward, cycles: cycles)
                    }
                    if firstVisit {
                        while forward >= threshold + step { threshold += step }
                    }
                    expand(d)
                    continue
                }
                // Look back.
                while true {
                    if d == 0 || pathMetric[d - 1] < threshold {
                        threshold -= step
                        tried[d] = 0
                        break
                    }
                    d -= 1
                    if tried[d] == 0 && d < message {
                        tried[d] = 1
                        break
                    }
                }
            }
            return nil
        }
    }

    /// Packs the first `count` bits (MSB first) into 7 bytes.
    private static func pack(_ bits: [UInt32], count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 7)
        for i in 0..<count where bits[i] != 0 { out[i / 8] |= 0x80 >> UInt8(i % 8) }
        return out
    }

    /// Normalises to unit RMS and maps ±`softRange` onto 0…255. Nil for non-finite or all-zero input.
    static func quantise(_ soft: [Float]) -> [UInt8]? {
        var sum = 0.0
        for s in soft {
            guard s.isFinite else { return nil }
            sum += Double(s) * Double(s)
        }
        let rms = (sum / Double(soft.count)).squareRoot()
        guard rms > 0, rms.isFinite else { return nil }
        let k = Float(Double(levels - 1) / (2 * Double(softRange) * rms))
        let mid = Float(levels - 1) / 2
        return soft.map { UInt8(min(Float(levels - 1), max(0, ($0 * k + mid).rounded()))) }
    }

    /// The Fano metric table for BPSK in Gaussian noise. With unit-RMS soft values r = ±a + noise,
    /// a² + σ² = 1 and Es/N0 = a²/(2σ²) = R·Eb/N0 for R = 1/2. For code bit 1,
    /// `log2(p(r|1) / p(r)) = log2(2 / (1 + exp(−2ar/σ²)))`; bit 0 mirrors it. Each entry subtracts R
    /// and is scaled by `scale` and rounded.
    static func makeMetricTable(ebN0Db: Double, scale: Double) -> [Int32] {
        let rate = 0.5
        let esN0 = rate * pow(10, ebN0Db / 10)
        // a² = 2σ²·Es/N0 and a² + σ² = 1.
        let sigma2 = 1 / (1 + 2 * esN0)
        let a = (1 - sigma2).squareRoot()
        let ln2 = log(2.0)
        var table = [Int32](repeating: 0, count: 2 * levels)
        for level in 0..<levels {
            let r = (Double(level) / Double(levels - 1) * 2 - 1) * Double(softRange)
            let llr = 2 * a * r / sigma2  // ln p(r|1)/p(r|0)
            // log2(2 / (1 + e^(∓llr))), written to stay finite for large |llr|.
            func bitMetric(_ x: Double) -> Double {
                x > 0 ? 1 - log1p(exp(-x)) / ln2 : 1 - (log1p(exp(x)) - x) / ln2
            }
            table[level] = Int32(((bitMetric(-llr) - rate) * scale).rounded())
            table[levels + level] = Int32(((bitMetric(llr) - rate) * scale).rounded())
        }
        return table
    }
}
