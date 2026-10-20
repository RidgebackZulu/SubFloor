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
