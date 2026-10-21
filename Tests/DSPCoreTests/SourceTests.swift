import Testing
import Foundation
import Accelerate
@testable import DSPCore

@Test func morseTimelineUsesParisTiming() {
    let t = MorseCode.timeline(for: "E T")
    #expect(t.map(\.on) == [true, false, true])
    #expect(t.map(\.units) == [1, 7, 3])
    #expect(MorseCode.reverse[".-"] == "A")
    #expect(abs(MorseCode.dotSeconds(wpm: 20) - 0.06) < 1e-9)
}

@Test func syntheticCarrierAppearsAtOffset() {
    let source = SyntheticSource(sampleRate: 1_024_000, centerFrequency: 10_000_000,
                                 signals: [.init(frequency: 10_128_000, amplitude: 0.5, kind: .carrier)])
    source.noiseAmplitude = 0
    let block = source.makeBlock(count: 1024)
    let analyzer = SpectrumAnalyzer(size: 1024)
    var db = [Float](repeating: 0, count: 1024)
    block.withUnsafeBufferPointer { b in db.withUnsafeMutableBufferPointer { analyzer.process(b, into: $0) } }
    #expect(db.indices.max { db[$0] < db[$1] }! == 512 + 128)
}

@Test func syntheticAntennaOffsetModelsUpconverter() {
    let source = SyntheticSource(sampleRate: 1_024_000, centerFrequency: 135_000_000,
                                 signals: [.init(frequency: 10_128_000, amplitude: 0.5, kind: .carrier)])
    source.noiseAmplitude = 0
    source.antennaOffset = 125_000_000
    let block = source.makeBlock(count: 1024)
    #expect(block.contains { abs($0.real) > 0.1 })
}

@Test func wavHeaderAndSamplesParse() throws {
    let frames = 1000
    var data = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + frames * 4))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2); u32(250_000); u32(250_000 * 4); u16(4); u16(16)
    data.append(contentsOf: Array("data".utf8)); u32(UInt32(frames * 4))
    for i in 0..<frames { u16(UInt16(bitPattern: Int16(i))); u16(UInt16(bitPattern: Int16(-i))) }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("subfloor-test-\(UUID()).wav")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let source = try IQFileSource(url: url, centerFrequency: 7_100_000)
    #expect(source.sampleRate == 250_000)
    #expect(source.frameCount == frames)
    let block = source.readFrames(at: 10, count: 2)
    #expect(abs(block[0].real - 10 / 32768) < 1e-7 && abs(block[0].imag + 10 / 32768) < 1e-7)
}

@Test func wavRejectsGarbage() {
    #expect(throws: IQFileError.self) { try IQFileSource.parseWAVHeader(Data("not a wav file at all....".utf8)) }
}

/// Builds a WAV header with a 16-byte stereo PCM fmt chunk and a data chunk of `dataFrames` frames.
private func wavBytes(dataFrames: Int) -> Data {
    var data = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataFrames * 4))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2); u32(250_000); u32(250_000 * 4); u16(4); u16(16)
    data.append(contentsOf: Array("data".utf8)); u32(UInt32(dataFrames * 4))
    for i in 0..<dataFrames { u16(UInt16(bitPattern: Int16(i))); u16(UInt16(bitPattern: Int16(-i))) }
    return data
}

@Test func wavTruncatedFmtChunkThrows() {
    // Cut the file six bytes into the 16-byte fmt body, so the declared fmt size runs past the end.
    let full = wavBytes(dataFrames: 0)
    let truncated = full.prefix(12 + 8 + 6)
    #expect(throws: IQFileError.self) { try IQFileSource.parseWAVHeader(Data(truncated)) }
}

@Test func wavEmptyDataChunkThrows() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("subfloor-test-\(UUID()).wav")
    try wavBytes(dataFrames: 0).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: IQFileError.self) { try IQFileSource(url: url, centerFrequency: 7_100_000) }
}

/// Thread-safe counter for blocks delivered by a source's handler.
final class BlockCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}

@Test func syntheticStopIsABarrier() async throws {
    let source = SyntheticSource(sampleRate: 1_024_000, centerFrequency: 14_100_000, signals: [])
    let counter = BlockCounter()
    try source.start { _ in counter.increment() }
    try await Task.sleep(for: .milliseconds(50))
    source.stop()
    let atStop = counter.count
    #expect(atStop > 0)
    try await Task.sleep(for: .milliseconds(50))
    #expect(counter.count == atStop)
}

@Test func floatWavNonFiniteSamplesBecomeZero() throws {
    var data = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func f32(_ v: Float) { u32(v.bitPattern) }
    let frames = 4
    data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + frames * 8))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(3); u16(2); u32(250_000); u32(250_000 * 8); u16(8); u16(32)
    data.append(contentsOf: Array("data".utf8)); u32(UInt32(frames * 8))
    f32(0.5); f32(-0.25)
    f32(.nan); f32(.infinity)
    f32(-.infinity); f32(0.125)
    f32(0.75); f32(.nan)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("subfloor-test-\(UUID()).wav")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try IQFileSource(url: url, centerFrequency: 7_100_000)
    let block = source.readFrames(at: 0, count: 4)
    #expect(block.allSatisfy { $0.real.isFinite && $0.imag.isFinite })
    #expect(block[0].real == 0.5 && block[1].real == 0 && block[1].imag == 0 && block[2].imag == 0.125 && block[3].imag == 0)
}

/// The phasor generator against the direct formula it replaced (per-sample `cos`/`sin` of the
/// accumulated carrier phase plus the modulation), noise off, over consecutive blocks.
@Test(arguments: [
    SyntheticSource.Signal(frequency: 14_075_500, amplitude: 0.004, kind: .carrier),
    SyntheticSource.Signal(frequency: 14_200_000, amplitude: 0.01, kind: .ssbTone(audioHz: 1_000)),
    SyntheticSource.Signal(frequency: 13_990_000, amplitude: 0.01, kind: .ssbTone(audioHz: -800)),
    SyntheticSource.Signal(frequency: 13_650_000, amplitude: 0.05, kind: .am(toneHz: 600)),
    SyntheticSource.Signal(frequency: 14_500_000, amplitude: 0.02, kind: .fm(toneHz: 1_000, deviation: 3_000)),
    SyntheticSource.Signal(frequency: 14_300_000, amplitude: 0.1, kind: .fm(toneHz: 440, deviation: 60_000)),
    SyntheticSource.Signal(frequency: 14_030_000, amplitude: 0.02, kind: .cw(text: "CQ DE K", wpm: 20)),
])
func phasorGeneratorMatchesDirectFormula(_ signal: SyntheticSource.Signal) {
    let fs = 2_000_000.0, center = 14_100_000.0, count = 20_000
    let source = SyntheticSource(sampleRate: fs, centerFrequency: center, signals: [signal])
    source.noiseAmplitude = 0
    var pattern: [Bool] = []
    if case .cw(let text, _) = signal.kind {
        for e in MorseCode.timeline(for: text) { pattern += Array(repeating: e.on, count: e.units) }
        pattern += Array(repeating: false, count: 21)
    }
    var phase = 0.0, env: Float = 0, index = 0, worst: Float = 0
    for _ in 0..<3 {
        let block = source.makeBlock(count: count)
        let w = 2 * Double.pi * (signal.frequency - center) / fs
        for k in 0..<count {
            let t = Double(index + k) / fs
            var amp = signal.amplitude
            var ph = phase
            switch signal.kind {
            case .carrier: break
            case .am(let tone): amp *= Float(1 + 0.6 * sin(2 * .pi * tone * t))
            case .fm(let tone, let deviation): ph += deviation / tone * sin(2 * .pi * tone * t)
            case .ssbTone(let audio): ph += 2 * .pi * audio * t
            case .cw(_, let wpm):
                let unit = Int(t / MorseCode.dotSeconds(wpm: wpm)) % pattern.count
                env += ((pattern[unit] ? 1 : 0) - env) * 0.002
                amp *= env
            }
            worst = max(worst, abs(block[k].real - amp * Float(cos(ph))), abs(block[k].imag - amp * Float(sin(ph))))
            phase += w
        }
        phase = phase.truncatingRemainder(dividingBy: 2 * .pi)
        index += count
    }
    // Float rounding (about 1e-7 of the amplitude), except FM, whose table interpolation is about
    // 5e-5 at broadcast deviation (β = 136).
    let tolerance: Float = if case .fm = signal.kind { 1e-4 } else { 1e-6 }
    #expect(worst <= tolerance * signal.amplitude, "worst error \(worst / signal.amplitude) of the amplitude")
}
