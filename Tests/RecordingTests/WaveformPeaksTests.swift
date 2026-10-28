import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import Recording

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WaveformPeaksTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Writes a 48 kHz mono float WAV whose sample `i` is `sample(i)`, one second at a time so a long file never sits in memory.
private func writeWAV(_ url: URL, seconds: Int, sample: (Int) -> Float) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
    buffer.frameLength = 48_000
    for s in 0..<seconds {
        let out = buffer.floatChannelData![0]
        for i in 0..<48_000 { out[i] = sample(s * 48_000 + i) }
        try file.write(from: buffer)
    }
}

/// A 48 kHz mono 16-bit WAV of silence, as a header and a sparse file: it takes no time or disk to make, however long.
private func writeSilentWAV(_ url: URL, seconds: Int) throws {
    let dataBytes = UInt32(seconds * 48_000 * 2)
    var header = Data("RIFF".utf8)
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
    u32(36 + dataBytes); header.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16)
    u16(1); u16(1); u32(48_000); u32(96_000); u16(2); u16(16)       // PCM, mono, 48 kHz, 16-bit
    header.append(contentsOf: Array("data".utf8)); u32(dataBytes)
    try header.write(to: url)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(header.count) + UInt64(dataBytes))
    try handle.close()
}

/// 1 s of a 0.5-amplitude 1 kHz sine, then 1 s of zeros.
private func writeToneThenSilence(_ url: URL) throws {
    try writeWAV(url, seconds: 2) { i in i < 48_000 ? 0.5 * sin(2 * .pi * 1_000 * Float(i) / 48_000) : 0 }
}

@Suite struct WaveformPeaksTests {
    @Test func toneThenSilence() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("a.wav")
        try writeToneThenSilence(wav)
        let p = try await WaveformPeaks.load(audioFile: wav, cacheFolder: dir.appendingPathComponent("cache"))
        #expect(p.peaks.count == 200); #expect(abs(p.duration - 2) < 1e-9)
        #expect(p.sampleRate == 48_000); #expect(p.frames == 96_000)
        #expect(p.peaks[0..<100].allSatisfy { abs(Int($0) - 128) <= 2 })
        #expect(p.peaks[100..<200].allSatisfy { $0 == 0 })
    }

    @Test func readsFLAC() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let flac = dir.appendingPathComponent("a.flac")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 24]
        do {
            let file = try AVAudioFile(forWriting: flac, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
            buffer.frameLength = 48_000
            for i in 0..<48_000 { buffer.floatChannelData![0][i] = i < 24_000 ? 0.25 : 0 }
            try file.write(from: buffer)
        }
        let p = try await WaveformPeaks.load(audioFile: flac, cacheFolder: dir.appendingPathComponent("cache"))
        #expect(p.peaks.count == 100); #expect(p.frames == 48_000)
        #expect(p.peaks[0..<50].allSatisfy { abs(Int($0) - 64) <= 1 })
        #expect(p.peaks[50..<100].allSatisfy { $0 == 0 })
    }

    @Test func secondLoadUsesTheCache() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("a.wav"), cache = dir.appendingPathComponent("cache")
        try writeToneThenSilence(wav)
        let first = try await WaveformPeaks.load(audioFile: wav, cacheFolder: cache)
        let cacheFile = cache.appendingPathComponent("a.wav.peaks")
        var bytes = try Data(contentsOf: cacheFile)
        #expect(bytes.count == 40 + first.peaks.count)
        bytes.replaceSubrange(40..., with: [UInt8](repeating: 7, count: first.peaks.count))
        try bytes.write(to: cacheFile)
        let second = try await WaveformPeaks.load(audioFile: wav, cacheFolder: cache)
        #expect(second.peaks == [UInt8](repeating: 7, count: 200))
        #expect(second.frames == first.frames); #expect(second.sampleRate == first.sampleRate)
    }

    @Test func aChangedFileIsRecomputed() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("a.wav"), cache = dir.appendingPathComponent("cache")
        try writeToneThenSilence(wav)
        #expect(try await WaveformPeaks.load(audioFile: wav, cacheFolder: cache).peaks.count == 200)
        try writeWAV(wav, seconds: 3) { _ in 0.25 }
        let p = try await WaveformPeaks.load(audioFile: wav, cacheFolder: cache)
        #expect(p.peaks.count == 300)
        #expect(p.peaks.allSatisfy { abs(Int($0) - 64) <= 2 })
    }

    @Test func aDamagedCacheIsRecomputed() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("a.wav"), cache = dir.appendingPathComponent("cache")
        try writeToneThenSilence(wav)
        _ = try await WaveformPeaks.load(audioFile: wav, cacheFolder: cache)
        let cacheFile = cache.appendingPathComponent("a.wav.peaks")
        try Data(contentsOf: cacheFile).prefix(60).write(to: cacheFile)       // truncated: peaks missing
        let p = try await WaveformPeaks.load(audioFile: wav, cacheFolder: cache)
        #expect(p.peaks.count == 200); #expect(p.peaks[100..<200].allSatisfy { $0 == 0 })
        try Data("junk".utf8).write(to: cacheFile)
        #expect(try await WaveformPeaks.load(audioFile: wav, cacheFolder: cache).peaks.count == 200)
    }

    @Test func aCacheThatCannotBeWrittenStillReturnsPeaks() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("a.wav")
        try writeToneThenSilence(wav)
        let blocker = dir.appendingPathComponent("cache")
        try Data("a file where the folder should be".utf8).write(to: blocker)
        let p = try await WaveformPeaks.load(audioFile: wav, cacheFolder: blocker)
        #expect(p.peaks.count == 200)
    }

    @Test func unreadableFileThrows() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let junk = dir.appendingPathComponent("bad.flac")
        try Data(repeating: 0x5A, count: 100).write(to: junk)
        await #expect(throws: (any Error).self) {
            _ = try await WaveformPeaks.load(audioFile: junk, cacheFolder: dir.appendingPathComponent("cache"))
        }
        await #expect(throws: (any Error).self) {
            _ = try await WaveformPeaks.load(audioFile: dir.appendingPathComponent("missing.wav"), cacheFolder: dir)
        }
    }

    @Test func aTaskCancelledBeforeTheLoadStartsStillStops() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("a.wav")
        try writeToneThenSilence(wav)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WaveformPeaks.load(audioFile: wav, cacheFolder: dir.appendingPathComponent("cache"))
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("cache").path))
    }

    @Test func cancellationStopsPromptly() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("long.wav")
        try writeSilentWAV(wav, seconds: 12 * 3600)        // far more than 50 ms of work
        let startedAt = Mutex<ContinuousClock.Instant?>(nil), exitedAt = Mutex<ContinuousClock.Instant?>(nil)
        let task = Task {
            try await WaveformPeaks.load(audioFile: wav, cacheFolder: dir.appendingPathComponent("cache")) { event in
                switch event {
                case .started: startedAt.withLock { $0 = .now }
                case .exited: exitedAt.withLock { $0 = .now }
                }
            }
        }
        // A thread of its own, not Task.sleep or a dispatch timer: other suites can keep the cooperative and dispatch
        // pools busy for seconds, and a late cancel would find the load already finished.
        let cancelledAt = Mutex<ContinuousClock.Instant?>(nil)
        let timer = Thread {
            Thread.sleep(forTimeInterval: 0.05)
            cancelledAt.withLock { $0 = .now }
            task.cancel()
        }
        timer.qualityOfService = .userInteractive
        timer.start()
        do { _ = try await task.value; Issue.record("load finished instead of being cancelled") }
        catch is CancellationError {}
        catch { Issue.record("expected CancellationError, got \(error)") }
        // What is timed is the reading stopping, on its own thread, from the cancel or from when the worker began,
        // whichever came later: within a chunk of a second of audio (tens of µs here; ~1.4 s to read this file
        // uncancelled). The task that starts the worker, and the one awaiting it, need the cooperative pool, which
        // the other suites can keep busy for minutes, so neither wait is timed.
        let cancelled = try #require(cancelledAt.withLock { $0 })
        let started = try #require(startedAt.withLock { $0 }), exited = try #require(exitedAt.withLock { $0 })
        #expect(exited - max(cancelled, started) < .seconds(1))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("cache/long.wav.peaks").path))
    }

    @Test func aCacheWithAnAbsurdHeaderIsRecomputedWithoutTrapping() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("a.wav"), cache = dir.appendingPathComponent("cache")
        try writeToneThenSilence(wav)
        _ = try await WaveformPeaks.load(audioFile: wav, cacheFolder: cache)
        let cacheFile = cache.appendingPathComponent("a.wav.peaks")
        let good = try Data(contentsOf: cacheFile)
        func header(rate: Double, frames: Int64) -> Data {
            var bytes = good
            withUnsafeBytes(of: rate.bitPattern.littleEndian) { bytes.replaceSubrange(24..<32, with: $0) }
            withUnsafeBytes(of: frames.littleEndian) { bytes.replaceSubrange(32..<40, with: $0) }
            return bytes
        }
        for (rate, frames) in [(Double.leastNonzeroMagnitude, Int64(96_000)), (1, Int64.max), (.infinity, 96_000),
                               (.nan, 96_000), (-48_000, 96_000), (48_000, -1), (1e300, Int64.max)] {
            try header(rate: rate, frames: frames).write(to: cacheFile)
            let p = try await WaveformPeaks.load(audioFile: wav, cacheFolder: cache)
            #expect(p.peaks.count == 200, "rate \(rate), frames \(frames)")
            #expect(p.sampleRate == 48_000)
        }
    }
}
