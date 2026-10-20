import Testing
import Foundation
import Accelerate
@testable import DSPCore

private func responseDB(_ h: [Float], at f: Double) -> Double {
    var re = 0.0, im = 0.0
    for (n, v) in h.enumerated() {
        re += Double(v) * cos(2 * .pi * f * Double(n))
        im -= Double(v) * sin(2 * .pi * f * Double(n))
    }
    return 10 * log10(re * re + im * im)
}

@Test func lowpassHasFlatPassbandAndDeepStopband() {
    let h = FIRDesign.lowpass(taps: 129, cutoff: 0.1)
    #expect(h.count == 129)
    #expect(abs(responseDB(h, at: 0)) < 0.01)
    #expect(abs(responseDB(h, at: 0.05)) < 0.1)
    #expect(responseDB(h, at: 0.2) < -60)
}

@Test func ncoShiftsToneToDC() {
    let fs = 1_000_000.0
    var x = TestSignals.tone(frequency: 100_000, sampleRate: fs, count: 4096)
    var nco = NCO(frequency: -100_000, sampleRate: fs)
    x.withUnsafeMutableBufferPointer { nco.mix($0) }
    #expect(x.allSatisfy { abs($0.real - 1) < 1e-3 && abs($0.imag) < 1e-3 })
}

@Test func decimatorIsBlockSizeIndependent() {
    let input = (0..<10_000).map { Float(sin(Double($0) * 0.0628)) + Float(sin(Double($0) * 1.9)) }
    let taps = FIRDesign.lowpass(taps: 65, cutoff: 0.1)
    var whole = [Float]()
    input.withUnsafeBufferPointer { FIRDecimator(taps: taps, factor: 4).process($0, into: &whole) }
    let chunked = FIRDecimator(taps: taps, factor: 4)
    var pieces = [Float]()
    var i = 0
    for size in [1, 7, 333, 1000, 17].cycled(until: input.count) {
        let end = min(input.count, i + size)
        input[i..<end].withUnsafeBufferPointer { chunked.process($0, into: &pieces) }
        i = end
        if i == input.count { break }
    }
    #expect(whole.count == pieces.count)
    #expect(zip(whole, pieces).allSatisfy { abs($0 - $1) < 1e-5 })
    #expect(abs(whole.count - input.count / 4) <= 16)
}

@Test func decimatorPassesLowToneAndRejectsHighTone() {
    let n = 20_000
    let low = (0..<n).map { Float(cos(2 * Double.pi * 0.01 * Double($0))) }
    let high = (0..<n).map { Float(cos(2 * Double.pi * 0.3 * Double($0))) }
    let taps = FIRDesign.lowpass(taps: 97, cutoff: 0.1)
    var outLow = [Float](), outHigh = [Float]()
    low.withUnsafeBufferPointer { FIRDecimator(taps: taps, factor: 4).process($0, into: &outLow) }
    high.withUnsafeBufferPointer { FIRDecimator(taps: taps, factor: 4).process($0, into: &outHigh) }
    #expect(abs((outLow[100..<4000].map { abs($0) }.max() ?? 0) - 1) < 0.01)
    #expect((outHigh[100..<4000].map { abs($0) }.max() ?? 1) < 0.001)
}

@Test func complexDecimatorKeepsInBandTone() {
    let fs = 1_000_000.0
    let x = TestSignals.tone(frequency: 10_000, sampleRate: fs, count: 40_000)
    let dec = ComplexDecimator(taps: FIRDesign.lowpass(taps: 129, cutoff: 0.05), factor: 8)
    var out = [DSPComplex]()
    x.withUnsafeBufferPointer { dec.process($0, into: &out) }
    #expect(abs(out.count - 5_000) <= 16)
    let mags = out[100..<4000].map { ($0.real * $0.real + $0.imag * $0.imag).squareRoot() }
    #expect(mags.allSatisfy { abs($0 - 1) < 0.01 })
}

@Test func decimationPlanStaysAboveMinimum() {
    #expect(DecimationPlan.stages(inputRate: 2_000_000, minimumRate: 24_000) == [8, 8])
    #expect(DecimationPlan.stages(inputRate: 10_000_000, minimumRate: 24_000) == [8, 8, 4])
    #expect(DecimationPlan.stages(inputRate: 2_000_000, minimumRate: 300_000) == [4])
    #expect(DecimationPlan.stages(inputRate: 48_000, minimumRate: 48_000) == [])
}

private extension Array {
    /// Repeats the array's elements until their running total reaches `limit`.
    func cycled(until limit: Int) -> [Element] where Element == Int {
        var out: [Int] = [], sum = 0, i = 0
        while sum < limit { out.append(self[i % count]); sum += self[i % count]; i += 1 }
        return out
    }
}
