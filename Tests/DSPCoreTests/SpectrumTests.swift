import Testing
import Accelerate
@testable import DSPCore

private func spectrum(_ iq: [DSPComplex], size: Int) -> [Float] {
    let analyzer = SpectrumAnalyzer(size: size)
    var db = [Float](repeating: 0, count: size)
    iq.withUnsafeBufferPointer { src in db.withUnsafeMutableBufferPointer { analyzer.process(src, into: $0) } }
    return db
}

@Test func positiveToneLandsInExpectedBinAtZeroDB() {
    let n = 1024, fs = 1_000_000.0
    let db = spectrum(TestSignals.tone(frequency: fs / 8, sampleRate: fs, count: n), size: n)
    let peak = db.indices.max { db[$0] < db[$1] }!
    #expect(peak == n / 2 + n / 8)
    #expect(abs(db[peak]) < 0.5)
}

@Test func negativeToneLandsBelowDC() {
    let n = 2048, fs = 2_000_000.0
    let db = spectrum(TestSignals.tone(frequency: -fs / 4, sampleRate: fs, count: n), size: n)
    #expect(db.indices.max { db[$0] < db[$1] }! == n / 2 - n / 4)
}

@Test func windowsAreSymmetricAndPeakAtCentre() {
    for kind in WindowKind.allCases {
        let w = kind.coefficients(count: 65)
        #expect(abs(w[0] - w[64]) < 1e-6)
        #expect(w[32] == w.max())
    }
}

@Test func averagerSmoothsAndHoldsPeak() {
    let avg = SpectrumAverager(size: 2, alpha: 0.5)
    [Float(0), 0].withUnsafeBufferPointer { avg.add($0) }
    [Float(10), -10].withUnsafeBufferPointer { avg.add($0) }
    #expect(avg.average == [5, -5])
    #expect(avg.peak == [10, 0])
    avg.resetPeak()
    #expect(avg.peak == avg.average)
}
