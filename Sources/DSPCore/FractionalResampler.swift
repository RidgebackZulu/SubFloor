import Accelerate
import Foundation

/// Arbitrary-ratio real resampler: polyphase windowed-sinc (Blackman-Harris), 256 phases,
/// linear interpolation between adjacent phases. Cutoff is 0.45 × min(inRate, outRate).
/// The fractional read position is carried across calls, so the output rate is exact on average.
public struct FractionalResampler: Sendable {
    public static let phaseCount = 256

    private let step: Double
    private let span: Int                  // kernel length in input samples (even)
    private let table: [Float]             // (phaseCount + 1) rows of `span` coefficients
    private var buffer: [Float]
    private var position: Double

    public init(inputRate: Double, outputRate: Double, taps: Int = 32) {
        step = inputRate / outputRate
        // When decimating the kernel must stretch so its transition stays proportional to the output rate.
        let scale = max(1, inputRate / outputRate)
        let span = max(4, Int((Double(taps) * scale).rounded(.up)) & ~1)
        self.span = span
        let cutoff = 0.45 * min(inputRate, outputRate) / inputRate      // cycles per input sample
        let phases = Self.phaseCount
        var table = [Float](repeating: 0, count: (phases + 1) * span)
        for p in 0...phases {
            let frac = Double(p) / Double(phases)
            var row = [Double](repeating: 0, count: span)
            for j in 0..<span {
                let t = Double(j - span / 2 + 1) - frac                  // sample time relative to the output instant
                let sinc = t == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * t) / (.pi * t)
                let u = (t + Double(span) / 2) / Double(span)            // 0…1 across the kernel
                let w = 0.35875 - 0.48829 * cos(2 * .pi * u) + 0.14128 * cos(4 * .pi * u) - 0.01168 * cos(6 * .pi * u)
                row[j] = sinc * max(w, 0)
            }
            let sum = row.reduce(0, +)
            for j in 0..<span { table[p * span + j] = Float(row[j] / sum) }
        }
        self.table = table
        buffer = [Float](repeating: 0, count: span)
        position = Double(span / 2)
    }

    public mutating func process(_ x: UnsafeBufferPointer<Float>, into out: inout [Float]) {
        guard x.count > 0 else { return }
        buffer.append(contentsOf: x)
        let span = self.span
        let half = span / 2
        let phases = Self.phaseCount
        var pos = position
        let count = buffer.count
        buffer.withUnsafeBufferPointer { b in
            table.withUnsafeBufferPointer { t in
                while Int(pos) + half < count {
                    let base = Int(pos)
                    let scaled = (pos - Double(base)) * Double(phases)
                    let p = Int(scaled)
                    let mix = Float(scaled - Double(p))
                    let src = b.baseAddress! + (base - half + 1)
                    var a: Float = 0, c: Float = 0
                    vDSP_dotpr(src, 1, t.baseAddress! + p * span, 1, &a, vDSP_Length(span))
                    vDSP_dotpr(src, 1, t.baseAddress! + (p + 1) * span, 1, &c, vDSP_Length(span))
                    out.append(a + (c - a) * mix)
                    pos += step
                }
            }
        }
        // Drop samples no future output needs.
        let drop = min(max(Int(pos) - half + 1, 0), buffer.count)
        if drop > 0 {
            buffer.removeSubrange(0..<drop)
            pos -= Double(drop)
        }
        position = pos
    }
}
