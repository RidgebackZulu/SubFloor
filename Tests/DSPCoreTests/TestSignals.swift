import Foundation
import Accelerate
@testable import DSPCore

enum TestSignals {
    static func tone(frequency: Double, sampleRate: Double, count: Int, amplitude: Float = 1) -> [DSPComplex] {
        (0..<count).map { i in
            let p = 2 * Double.pi * frequency * Double(i) / sampleRate
            return DSPComplex(real: amplitude * Float(cos(p)), imag: amplitude * Float(sin(p)))
        }
    }

    /// Complex baseband built from an (amplitude, phase) function of time in seconds.
    static func modulated(sampleRate: Double, seconds: Double, _ f: (Double) -> (amp: Double, phase: Double)) -> [DSPComplex] {
        (0..<Int(sampleRate * seconds)).map { i in
            let (a, p) = f(Double(i) / sampleRate)
            return DSPComplex(real: Float(a * cos(p)), imag: Float(a * sin(p)))
        }
    }

    /// Goertzel power of a real signal at `frequency`, normalised by length².
    static func power(of x: ArraySlice<Float>, at frequency: Double, sampleRate: Double) -> Double {
        let c = 2 * cos(2 * Double.pi * frequency / sampleRate)
        var s1 = 0.0, s2 = 0.0
        for v in x {
            let s0 = Double(v) + c * s1 - s2
            s2 = s1
            s1 = s0
        }
        return (s1 * s1 + s2 * s2 - c * s1 * s2) / Double(x.count * x.count)
    }

    static func dominates(_ x: ArraySlice<Float>, at f: Double, sampleRate: Double, over others: [Double], by ratio: Double = 10) -> Bool {
        let p = power(of: x, at: f, sampleRate: sampleRate)
        return p > 0 && others.allSatisfy { power(of: x, at: $0, sampleRate: sampleRate) * ratio < p }
    }
}
