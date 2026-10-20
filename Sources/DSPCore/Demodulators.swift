import Accelerate
import Foundation

public protocol Demodulator: AnyObject {
    /// Converts channel-rate complex samples into real audio at the same rate, appending to `output`.
    func demodulate(_ iq: UnsafeBufferPointer<DSPComplex>, into output: inout [Float])
}

/// Envelope detector with a DC-blocking high-pass.
public final class AMDemodulator: Demodulator {
    private var previousIn: Float = 0
    private var previousOut: Float = 0

    public init() {}

    public func demodulate(_ iq: UnsafeBufferPointer<DSPComplex>, into output: inout [Float]) {
        for s in iq {
            let m = (s.real * s.real + s.imag * s.imag).squareRoot()
            let y = m - previousIn + 0.999 * previousOut
            previousIn = m
            previousOut = y
            output.append(y)
        }
    }
}

/// Quadrature discriminator. Output 1.0 corresponds to `deviation` Hz.
public final class FMDemodulator: Demodulator {
    private let scale: Float
    private let deemphasis: Float?
    private var previous = DSPComplex(real: 1, imag: 0)
    private var deemphasisState: Float = 0

    public init(sampleRate: Double, deviation: Double, deemphasisTau: Double?) {
        scale = Float(sampleRate / (2 * .pi * deviation))
        deemphasis = deemphasisTau.map { Float(exp(-1 / (sampleRate * $0))) }
    }

    public func demodulate(_ iq: UnsafeBufferPointer<DSPComplex>, into output: inout [Float]) {
        for s in iq {
            let re = s.real * previous.real + s.imag * previous.imag
            let im = s.imag * previous.real - s.real * previous.imag
            previous = s
            var y = atan2(im, re) * scale
            if let a = deemphasis {
                deemphasisState = a * deemphasisState + (1 - a) * y
                y = deemphasisState
            }
            output.append(y)
        }
    }
}

/// SSB / CW product detector: Re{x · e^{+j2π·shift·t}}.
public final class SSBDemodulator: Demodulator {
    private var nco: NCO

    public init(sampleRate: Double, shiftHz: Double) {
        nco = NCO(frequency: shiftHz, sampleRate: sampleRate)
    }

    public func demodulate(_ iq: UnsafeBufferPointer<DSPComplex>, into output: inout [Float]) {
        nco.mixReal(iq, into: &output)
    }
}
