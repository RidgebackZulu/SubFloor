import Accelerate
import Foundation

public enum FIRDesign {
    /// Windowed-sinc low-pass with unity DC gain. `cutoff` is in cycles/sample (0…0.5).
    /// `taps` is forced odd so the filter is symmetric with integer delay.
    public static func lowpass(taps: Int, cutoff: Double, window: WindowKind = .blackmanHarris) -> [Float] {
        let n = taps | 1
        let w = window.coefficients(count: n)
        let mid = Double(n - 1) / 2
        let h = (0..<n).map { i -> Double in
            let x = Double(i) - mid
            let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            return sinc * Double(w[i])
        }
        let sum = h.reduce(0, +)
        return h.map { Float($0 / sum) }
    }

    /// Taps for a transition band of `transition` cycles/sample (Blackman-Harris ≈ 6/N), odd, capped.
    public static func tapCount(transition: Double, max: Int = 1023) -> Int {
        Swift.min(max, Int((6.0 / transition).rounded(.up))) | 1
    }
}

/// Stateful decimating FIR for real samples, built on vDSP_desamp.
public final class FIRDecimator {
    public let factor: Int
    public let taps: [Float]
    private var buffer: [Float]
    private var filled: Int

    public init(taps: [Float], factor: Int) {
        precondition(!taps.isEmpty && factor >= 1 && taps.count >= factor)
        self.taps = taps
        self.factor = factor
        filled = taps.count - 1
        buffer = .init(repeating: 0, count: Swift.max(filled, 1))
    }

    public func process(_ input: UnsafeBufferPointer<Float>, into output: inout [Float]) {
        let p = taps.count
        let needed = filled + input.count
        if buffer.count < needed {
            buffer.append(contentsOf: repeatElement(0, count: needed - buffer.count))
        }
        let start = filled
        buffer.withUnsafeMutableBufferPointer { b in
            if let src = input.baseAddress { (b.baseAddress! + start).update(from: src, count: input.count) }
        }
        filled = needed
        let positions = filled - (p - 1)
        guard positions > 0 else { return }
        let outCount = (positions + factor - 1) / factor
        let outStart = output.count
        output.append(contentsOf: repeatElement(0, count: outCount))
        let factor = self.factor
        buffer.withUnsafeBufferPointer { b in
            taps.withUnsafeBufferPointer { t in
                output.withUnsafeMutableBufferPointer { o in
                    vDSP_desamp(b.baseAddress!, factor, t.baseAddress!, o.baseAddress! + outStart,
                                vDSP_Length(outCount), vDSP_Length(p))
                }
            }
        }
        let consumed = outCount * factor
        let remaining = filled - consumed
        buffer.withUnsafeMutableBufferPointer { b in
            memmove(b.baseAddress!, b.baseAddress! + consumed, remaining * MemoryLayout<Float>.stride)
        }
        filled = remaining
    }
}

/// Decimating FIR for complex samples (real taps applied to I and Q independently).
public final class ComplexDecimator {
    public var factor: Int { real.factor }
    private let real: FIRDecimator
    private let imag: FIRDecimator
    private var inRe: [Float] = []
    private var inIm: [Float] = []
    private var outRe: [Float] = []
    private var outIm: [Float] = []

    public init(taps: [Float], factor: Int) {
        real = FIRDecimator(taps: taps, factor: factor)
        imag = FIRDecimator(taps: taps, factor: factor)
    }

    public func process(_ input: UnsafeBufferPointer<DSPComplex>, into output: inout [DSPComplex]) {
        let n = input.count
        guard n > 0 else { return }
        if inRe.count < n {
            inRe = .init(repeating: 0, count: n)
            inIm = .init(repeating: 0, count: n)
        }
        inRe.withUnsafeMutableBufferPointer { re in
            inIm.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                vDSP_ctoz(input.baseAddress!, 2, &split, 1, vDSP_Length(n))
            }
        }
        outRe.removeAll(keepingCapacity: true)
        outIm.removeAll(keepingCapacity: true)
        inRe.withUnsafeBufferPointer { real.process(UnsafeBufferPointer(rebasing: $0[0..<n]), into: &outRe) }
        inIm.withUnsafeBufferPointer { imag.process(UnsafeBufferPointer(rebasing: $0[0..<n]), into: &outIm) }
        let m = outRe.count
        guard m > 0 else { return }
        let start = output.count
        output.append(contentsOf: repeatElement(DSPComplex(real: 0, imag: 0), count: m))
        outRe.withUnsafeMutableBufferPointer { re in
            outIm.withUnsafeMutableBufferPointer { im in
                output.withUnsafeMutableBufferPointer { out in
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    vDSP_ztoc(&split, 1, out.baseAddress! + start, 2, vDSP_Length(m))
                }
            }
        }
    }
}

public enum DecimationPlan {
    /// Integer stage factors (8, 4 or 2) that bring `inputRate` as low as possible while staying ≥ `minimumRate`.
    public static func stages(inputRate: Double, minimumRate: Double) -> [Int] {
        var rate = inputRate
        var out: [Int] = []
        while rate / 2 >= minimumRate {
            let f = rate / 8 >= minimumRate ? 8 : (rate / 4 >= minimumRate ? 4 : 2)
            out.append(f)
            rate /= Double(f)
        }
        return out
    }
}
