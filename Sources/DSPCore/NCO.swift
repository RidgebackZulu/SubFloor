import Accelerate

/// Numerically controlled oscillator. Mixing multiplies by e^{+j2πft};
/// use a negative frequency to shift a signal at +f down to DC.
public struct NCO: Sendable {
    private var re: Float = 1
    private var im: Float = 0
    private var stepRe: Float = 1
    private var stepIm: Float = 0

    public init(frequency: Double = 0, sampleRate: Double = 1) {
        setFrequency(frequency, sampleRate: sampleRate)
    }

    public mutating func setFrequency(_ hz: Double, sampleRate: Double) {
        let w = 2 * Double.pi * hz / sampleRate
        stepRe = Float(cos(w))
        stepIm = Float(sin(w))
    }

    public mutating func mix(_ x: UnsafeMutableBufferPointer<DSPComplex>) {
        var r = re, i = im
        let sr = stepRe, si = stepIm
        for k in x.indices {
            let s = x[k]
            x[k] = DSPComplex(real: s.real * r - s.imag * i, imag: s.real * i + s.imag * r)
            let nr = r * sr - i * si
            i = r * si + i * sr
            r = nr
        }
        renormalize(r, i)
    }

    /// Appends Re{x · e^{+j2πft}} to `output`.
    public mutating func mixReal(_ x: UnsafeBufferPointer<DSPComplex>, into output: inout [Float]) {
        var r = re, i = im
        let sr = stepRe, si = stepIm
        for s in x {
            output.append(s.real * r - s.imag * i)
            let nr = r * sr - i * si
            i = r * si + i * sr
            r = nr
        }
        renormalize(r, i)
    }

    private mutating func renormalize(_ r: Float, _ i: Float) {
        let mag = (r * r + i * i).squareRoot()
        re = r / mag
        im = i / mag
    }
}
