import AVFoundation
import Foundation
import Testing
@testable import Transcription

private let rate = 16_000

/// `seconds` of a 440 Hz tone at 16 kHz.
private func tone(_ seconds: Double, amplitude: Float = 0.3) -> [Float] {
    (0..<Int(seconds * Double(rate))).map { amplitude * sin(2 * .pi * 440 * Float($0) / Float(rate)) }
}

private func le16(_ d: Data, _ at: Int) -> Int { Int(d[at]) | Int(d[at + 1]) << 8 }
private func le32(_ d: Data, _ at: Int) -> Int { le16(d, at) | le16(d, at + 2) << 16 }

private func chunks(_ audio: PreparedAudio) throws -> [PreparedChunk] {
    guard case .chunks(let c) = audio else { throw Failure.notChunks(audio) }
    return c
}
private enum Failure: Error { case notChunks(PreparedAudio) }

@Suite struct TranscriptionAudioTests {
    @Test func wavHeaderIsPCM16Mono16k() {
        let samples = tone(0.25)
        let wav = TranscriptionAudio.wav(samples[...])
        #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: wav[12..<16], as: UTF8.self) == "fmt ")
        #expect(le16(wav, 20) == 1)            // PCM
        #expect(le16(wav, 22) == 1)            // channels
        #expect(le32(wav, 24) == 16_000)       // rate
        #expect(le32(wav, 28) == 32_000)       // byte rate
        #expect(le16(wav, 32) == 2)            // block align
        #expect(le16(wav, 34) == 16)           // bits
        #expect(String(decoding: wav[36..<40], as: UTF8.self) == "data")
        #expect(le32(wav, 40) == 2 * samples.count)
        #expect(le32(wav, 4) == 36 + 2 * samples.count)
        #expect(wav.count == 44 + 2 * samples.count)
    }

    @Test func wavClampsAndScales() {
        let wav = TranscriptionAudio.wav([2.0, -2.0, 0.5, 0][...])
        func sample(_ i: Int) -> Int { Int(Int16(bitPattern: UInt16(le16(wav, 44 + 2 * i)))) }
        #expect(sample(0) == 32_767)
        #expect(sample(1) == -32_767)
        #expect(abs(sample(2) - 16_384) <= 1)
        #expect(sample(3) == 0)
    }

    @Test func allZeroIsSilent() {
        #expect(TranscriptionAudio.prepare(samples: [Float](repeating: 0, count: 5 * rate)) == .silent)
    }

    @Test func silentWinsOverTooShort() {
        #expect(TranscriptionAudio.prepare(samples: [Float](repeating: 0, count: 100)) == .silent)
    }

    @Test func shortIsTooShort() {
        #expect(TranscriptionAudio.prepare(samples: tone(0.4)) == .tooShort(seconds: 0.4))
    }

    @Test func shortRecordingIsOneChunk() throws {
        let c = try chunks(TranscriptionAudio.prepare(samples: tone(30)))
        #expect(c.count == 1)
        #expect(c[0].offsetSeconds == 0)
        #expect(c[0].seconds == 30)
        #expect(c[0].wav.count == 44 + 2 * 30 * rate)
    }

    @Test func longRecordingChunksAtQuietPoint() throws {
        var s = tone(200)
        for i in (112 * rate)..<(112 * rate + 1_600) { s[i] = 0 }
        let c = try chunks(TranscriptionAudio.prepare(samples: s))
        #expect(c.count == 2)
        #expect(c[0].offsetSeconds == 0)
        #expect(c[0].seconds == 112.0)
        #expect(c[1].offsetSeconds == 112.0)
        #expect(c[1].seconds == 88.0)
    }

    @Test func noQuietPointStillCuts() throws {
        let c = try chunks(TranscriptionAudio.prepare(samples: tone(250)))
        #expect(c.count == 3)
        #expect(c.allSatisfy { $0.seconds <= 120 })
        #expect(c[0].offsetSeconds == 0)
        for (a, b) in zip(c, c.dropFirst()) { #expect(abs(a.offsetSeconds + a.seconds - b.offsetSeconds) < 1e-9) }
        let last = try #require(c.last)
        #expect(abs(last.offsetSeconds + last.seconds - 250) < 1.0 / 16_000)
        // each cut lands inside the search window before the limit
        #expect(c[1].offsetSeconds >= 105 && c[1].offsetSeconds < 120)
    }

    @Test func exactlyMaxLengthIsOneChunk() throws {
        let c = try chunks(TranscriptionAudio.prepare(samples: tone(120)))
        #expect(c.count == 1)
    }

    @Test func preparesRealFlac() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let flac = dir.appendingPathComponent("a.flac")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 48_000,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 24]
        do {
            let file = try AVAudioFile(forWriting: flac, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
            buffer.frameLength = 96_000
            for i in 0..<96_000 { buffer.floatChannelData![0][i] = 0.3 * sin(2 * .pi * 440 * Float(i) / 48_000) }
            try file.write(from: buffer)
        }
        let c = try chunks(try TranscriptionAudio.prepare(url: flac))
        #expect(c.count == 1)
        #expect(abs(c[0].seconds - 2.0) < 0.01)
        #expect(c[0].wav.count == 44 + 2 * Int((c[0].seconds * 16_000).rounded()))
    }
}
