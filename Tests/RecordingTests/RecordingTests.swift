import AudioToolbox
import DSPCore
import Foundation
import Testing
@testable import Recording

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func bytes<T>(_ values: [T]) -> [UInt8] { values.withUnsafeBytes { Array($0) } }

// MARK: HistoryRing

@Suite struct HistoryRingTests {
    @Test func keepsTheLastCapacityBytesAndRewindsIntoThem() {
        let ring = HistoryRing()
        ring.reset(capacity: 10, bytesPerFrame: 2)
        let data: [UInt8] = Array(0..<14)
        data.withUnsafeBytes { ring.push($0) }
        #expect(ring.head == 14)
        #expect(ring.available == 10)
        var position = ring.rewind(bytes: 100)   // more than exists: clamps to the oldest
        #expect(position == 4)
        var out = [UInt8](repeating: 0, count: 20)
        let r = out.withUnsafeMutableBytes { ring.read(from: &position, into: $0) }
        #expect(r == (10, 0))
        #expect(Array(out[0..<10]) == Array(4..<14))
        #expect(position == 14)
    }

    @Test func pushLargerThanCapacityKeepsTheTail() {
        let ring = HistoryRing()
        ring.reset(capacity: 4, bytesPerFrame: 1)
        Array<UInt8>(0..<9).withUnsafeBytes { ring.push($0) }
        var position = ring.rewind(bytes: 4)
        var out = [UInt8](repeating: 0, count: 4)
        out.withUnsafeMutableBytes { _ = ring.read(from: &position, into: $0) }
        #expect(out == [5, 6, 7, 8])
    }

    @Test func overwrittenPositionIsSkippedAndCounted() {
        let ring = HistoryRing()
        ring.reset(capacity: 8, bytesPerFrame: 1)
        Array<UInt8>(0..<8).withUnsafeBytes { ring.push($0) }
        var position = 0
        Array<UInt8>(8..<13).withUnsafeBytes { ring.push($0) }   // bytes 0..<5 are gone
        var out = [UInt8](repeating: 0, count: 3)
        let r = out.withUnsafeMutableBytes { ring.read(from: &position, into: $0) }
        #expect(r == (3, 5))
        #expect(out == [5, 6, 7])
    }

    @Test func clearBlocksRewindButNotReadsInProgress() {
        let ring = HistoryRing()
        ring.reset(capacity: 16, bytesPerFrame: 1)
        Array<UInt8>(0..<8).withUnsafeBytes { ring.push($0) }
        var position = 0
        ring.clear()
        #expect(ring.available == 0)
        #expect(ring.rewind(bytes: 8) == 8)
        var out = [UInt8](repeating: 0, count: 8)
        let r = out.withUnsafeMutableBytes { ring.read(from: &position, into: $0) }
        #expect(r == (8, 0))
        Array<UInt8>(8..<10).withUnsafeBytes { ring.push($0) }
        #expect(ring.available == 2)
    }

    @Test func readsWholeFramesOnly() {
        let ring = HistoryRing()
        ring.reset(capacity: 15, bytesPerFrame: 4)
        #expect(ring.capacity == 12)
        Array<UInt8>(0..<10).withUnsafeBytes { ring.push($0) }
        var position = 0
        var out = [UInt8](repeating: 0, count: 10)
        let r = out.withUnsafeMutableBytes { ring.read(from: &position, into: $0) }
        #expect(r.read == 8)
    }
}

// MARK: Formats

@Suite struct FormatTests {
    @Test func int16ConversionRoundsAndClips() {
        let c = SampleConverter(format: .int16)
        let input: [Float] = [0, 1, -1, 2, -2, 0.5, 1.0 / 32767]
        var out = [Int16](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { i in out.withUnsafeMutableBytes { c.convert(i, into: $0) } }
        #expect(out == [0, 32767, -32767, 32767, -32767, 16384, 1])
    }

    @Test func int24ConversionPacksLittleEndian() {
        let c = SampleConverter(format: .int24)
        let input: [Float] = [1, -1, 1.0 / 8_388_607, -2.0 / 8_388_607]
        var out = [UInt8](repeating: 0, count: 12)
        input.withUnsafeBufferPointer { i in out.withUnsafeMutableBytes { c.convert(i, into: $0) } }
        #expect(out == [0xFF, 0xFF, 0x7F, 0x01, 0x00, 0x80, 0x01, 0x00, 0x00, 0xFE, 0xFF, 0xFF])
    }

    @Test func float32ConversionIsACopy() {
        let c = SampleConverter(format: .float32)
        let input: [Float] = [0.25, -3, .pi]
        var out = [Float](repeating: 0, count: 3)
        input.withUnsafeBufferPointer { i in out.withUnsafeMutableBytes { c.convert(i, into: $0) } }
        #expect(out == input)
    }

    @Test func settingsNormalizeToValidCombinations() {
        var s = RecordingSettings()
        s.audioFormat = .flac
        s.audioSampleFormat = .float32
        s.iqFormat = .sigmf
        s.iqSampleFormat = .int24
        s.preRollSeconds = 1000
        s.iqMemoryLimitBytes = 12345
        let n = s.normalized()
        #expect(n.audioSampleFormat == .int24)
        #expect(n.iqSampleFormat == .int16)
        #expect(n.preRollSeconds == 120)
        #expect(n.iqMemoryLimitBytes == 2 << 30)
        #expect(RecordingSettings().normalized() == RecordingSettings())
    }

    @Test func iqNeverOffers24Bit() {
        #expect(StreamKind.iq.sampleFormats(for: .wav) == [.int16, .float32])
        #expect(StreamKind.audio.sampleFormats(for: .wav) == [.int16, .int24, .float32])
        #expect(StreamKind.audio.sampleFormats(for: .flac) == [.int16, .int24])
    }

    @Test func ringPlanKeepsTheMarginWhenMemoryBinds() {
        let free = StreamRecorder.plan(sampleRate: 48_000, bytesPerFrame: 4, preRollSeconds: 30, memoryLimitBytes: 1 << 30)
        #expect(free.effectivePreRollSeconds == 30)
        #expect(free.capacityBytes == 33 * 48_000 * 4)
        #expect(free.preRollBytes == 30 * 48_000 * 4)
        let bound = StreamRecorder.plan(sampleRate: 10_000_000, bytesPerFrame: 4, preRollSeconds: 120, memoryLimitBytes: 2 << 30)
        #expect(bound.capacityBytes == 2 << 30)
        let expectedSeconds = Double(2 << 30) / 4 / 10_000_000 - 12
        #expect(abs(bound.effectivePreRollSeconds - expectedSeconds) < 1e-6)
        #expect(bound.marginSeconds == 12)
    }

    @Test func namesFollowTheSDRSharpShape() {
        let t = Date(timeIntervalSince1970: 1_792_000_000)   // 2026-10-14 17:46:40 UTC
        #expect(RecordingNames.base(firstSample: t, frequencyHz: 14_074_000, label: "USB") == "SubFloor_20261014_174640Z_14074000Hz_USB")
        #expect(AppStyleName.centerFrequency(fromFileName: RecordingNames.base(firstSample: t, frequencyHz: 7_074_000, label: "IQ") + ".wav") == 7_074_000)
    }

    @Test func uniqueNamesAppendACounter() throws {
        let dir = tempDir()
        let base = dir.appendingPathComponent("SubFloor_x")
        try Data().write(to: base.appendingPathExtension("wav"))
        #expect(RecordingNames.unique(base, extension: "wav").lastPathComponent == "SubFloor_x_2")
        #expect(RecordingNames.unique(base, extension: "flac").lastPathComponent == "SubFloor_x")
    }
}

/// The app's own file-name parser, copied here so the Recording module stays free of the app.
private enum AppStyleName {
    static func centerFrequency(fromFileName name: String) -> Double? {
        guard let match = name.firstMatch(of: /(\d{4,})Hz/) else { return nil }
        return Double(match.1)
    }
}

// MARK: Files

@Suite struct RecordingFileTests {
    @Test func wavIsReadBySubFloorsIQFileSource() throws {
        let dir = tempDir()
        let layout = StreamLayout(sampleRate: 2_000_000, channels: 2, sampleFormat: .int16)
        let file = try WAVFile(url: dir.appendingPathComponent("iq.wav"), layout: layout)
        let samples: [Int16] = [1, -1, 32767, -32768, 0, 7]
        try samples.withUnsafeBytes { try file.write($0) }
        try file.finalize()
        let data = try Data(contentsOf: file.url)
        #expect(data.count == 44 + 12)
        let parsed = try IQFileSource.parseWAVHeader(data)
        #expect(parsed.sampleRate == 2_000_000 && !parsed.isFloat && parsed.dataOffset == 44 && parsed.dataLength == 12)
        let source = try IQFileSource(url: file.url, centerFrequency: 1)
        #expect(source.frameCount == 3)
    }

    @Test func wavHeaderCarriesFloatAnd24BitFormats() {
        let f = WAVFile.header(layout: StreamLayout(sampleRate: 48_000, channels: 1, sampleFormat: .float32), dataBytes: 400)
        #expect(f[20] == 3 && f[34] == 32)   // IEEE float, 32 bits
        #expect(Array(f[40..<44]) == bytes([UInt32(400).littleEndian]))
        #expect(Array(f[4..<8]) == bytes([UInt32(436).littleEndian]))
        let i = WAVFile.header(layout: StreamLayout(sampleRate: 48_000, channels: 1, sampleFormat: .int24), dataBytes: 0)
        #expect(i[20] == 1 && i[34] == 24 && i[32] == 3)   // PCM, 24 bits, 3 bytes per frame
        #expect(Array(i[28..<32]) == bytes([UInt32(144_000).littleEndian]))
    }

    @Test func wavCheckpointLeavesAValidHeaderMidRecording() throws {
        let dir = tempDir()
        let file = try WAVFile(url: dir.appendingPathComponent("a.wav"), layout: StreamLayout(sampleRate: 8_000, channels: 1, sampleFormat: .int16))
        try [Int16](repeating: 3, count: 100).withUnsafeBytes { try file.write($0) }
        try file.checkpoint()
        let data = try Data(contentsOf: file.url)
        #expect(data.count == 244)
        #expect(data[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } == 200)
        try file.finalize()
    }

    @Test func sigmfWritesDataAndMeta() throws {
        let dir = tempDir()
        let layout = StreamLayout(sampleRate: 2_000_000, channels: 2, sampleFormat: .int16)
        let when = Date(timeIntervalSince1970: 1_792_000_000.25)
        let meta = RecordingMetadata(frequencyHz: 14_100_000, firstSample: when, hardware: "RSP1B")
        let file = try RecordingFiles.open(.sigmf, base: dir.appendingPathComponent("cap"), layout: layout, metadata: meta)
        try [Int16](repeating: 1, count: 4).withUnsafeBytes { try file.write($0) }
        try file.finalize()
        #expect(file.url.lastPathComponent == "cap.sigmf-data")
        #expect(try Data(contentsOf: file.url).count == 8)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("cap.sigmf-meta"))) as! [String: Any]
        let global = json["global"] as! [String: Any]
        #expect(global["core:datatype"] as? String == "ci16_le")
        #expect(global["core:sample_rate"] as? Double == 2_000_000)
        #expect(global["core:hw"] as? String == "RSP1B")
        let capture = (json["captures"] as! [[String: Any]])[0]
        #expect(capture["core:frequency"] as? Double == 14_100_000)
        #expect(capture["core:datetime"] as? String == "2026-10-14T17:46:40.250Z")
        #expect(SigMFFile.datatype(StreamLayout(sampleRate: 1, channels: 2, sampleFormat: .float32)) == "cf32_le")
        #expect(SigMFFile.datatype(StreamLayout(sampleRate: 1, channels: 1, sampleFormat: .int16)) == "ri16_le")
    }

    /// Decodes `url` to floats with ExtAudioFile.
    private func decode(_ url: URL, channels: Int) throws -> [Float] {
        var ref: ExtAudioFileRef?
        #expect(ExtAudioFileOpenURL(url as CFURL, &ref) == noErr)
        guard let ref else { return [] }
        defer { ExtAudioFileDispose(ref) }
        var client = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
                                                 mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        #expect(ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.size(ofValue: client)), &client) == noErr)
        var out: [Float] = []
        var buffer = [Float](repeating: 0, count: 4096 * channels)
        while true {
            var frames: UInt32 = 4096
            let got: UInt32 = buffer.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                #expect(ExtAudioFileRead(ref, &frames, &list) == noErr)
                return frames
            }
            if got == 0 { break }
            out += buffer[0..<Int(got) * channels]
        }
        return out
    }

    @Test(arguments: [FileFormat.flac, .alac], [SampleFormat.int16, .int24])
    func losslessEncodersRoundTripExactly(format: FileFormat, sampleFormat: SampleFormat) throws {
        let dir = tempDir()
        let layout = StreamLayout(sampleRate: 48_000, channels: 1, sampleFormat: sampleFormat)
        let fullScale = sampleFormat == .int16 ? 32_767 : 8_388_607
        var rng = SystemRandomNumberGenerator()
        let ints = (0..<20_000).map { _ in Int32.random(in: -Int32(fullScale)...Int32(fullScale), using: &rng) }
        let floats = ints.map { Float($0) / Float(fullScale) }
        let converter = SampleConverter(format: sampleFormat)
        var raw = [UInt8](repeating: 0, count: floats.count * sampleFormat.bytesPerSample)
        floats.withUnsafeBufferPointer { f in raw.withUnsafeMutableBytes { converter.convert(f, into: $0) } }
        let file = try RecordingFiles.open(format, base: dir.appendingPathComponent("tone"), layout: layout,
                                           metadata: RecordingMetadata(frequencyHz: 0, firstSample: Date(), hardware: ""))
        try raw.withUnsafeBytes { try file.write($0) }
        try file.finalize()
        #expect(file.url.pathExtension == format.fileExtension)
        let decoded = try decode(file.url, channels: 1)
        #expect(decoded.count == ints.count)
        // CoreAudio scales integers by 2^(bits-1) on the way to float.
        let scale = Float(fullScale + 1)
        let mismatches = zip(decoded, ints).filter { Int32(($0.0 * scale).rounded()) != $0.1 }.count
        #expect(mismatches == 0)
    }

    @Test func floatRefusedByIntegerOnlyFormats() {
        let dir = tempDir()
        #expect(throws: RecordingError.self) {
            try RecordingFiles.open(.flac, base: dir.appendingPathComponent("x"), layout: StreamLayout(sampleRate: 48_000, channels: 1, sampleFormat: .float32),
                                    metadata: RecordingMetadata(frequencyHz: 0, firstSample: Date(), hardware: ""))
        }
    }
}

// MARK: StreamRecorder

@Suite struct StreamRecorderTests {
    static let rate = 10_000.0

    /// A recorder of mono float frames whose value is the frame index, so a file's contents say
    /// exactly which samples it holds.
    private func makeRecorder(kind: StreamKind = .audio, format: FileFormat = .wav, preRoll: Double = 5, folder: URL, rolls: Bool = false) -> StreamRecorder {
        let r = StreamRecorder(kind: kind, rollsOnContextChange: rolls)
        r.configure(StreamRecorder.Setup(sampleRate: Self.rate, channels: kind.channels, fileFormat: format, sampleFormat: .float32,
                                         preRollSeconds: preRoll, memoryLimitBytes: 1 << 30, folder: folder))
        return r
    }

    private func push(_ r: StreamRecorder, frames: Range<Int>, channels: Int = 1) {
        var block: [Float] = []
        for k in frames { for _ in 0..<channels { block.append(Float(k)) } }
        block.withUnsafeBufferPointer { r.push($0) }
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return true
    }

    private func wavFrames(_ url: URL, channels: Int = 1) throws -> [Float] {
        let data = try Data(contentsOf: url)
        let n = (data.count - 44) / 4
        return data[44...].withUnsafeBytes { raw in (0..<n).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) } }
    }

    private func wavs(in dir: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test func recordingStartsPreRollBeforeTheClickAndIsContiguous() throws {
        let dir = tempDir()
        let r = makeRecorder(folder: dir)
        defer { r.shutdown() }
        let click = Date(timeIntervalSince1970: 1_792_000_000)
        r.now = { click }
        r.setContext(RecordingContext(frequencyHz: 7_074_000, label: "USB", hardware: "test"))
        for b in stride(from: 0, to: 100_000, by: 1_000) { push(r, frames: b..<(b + 1_000)) }
        #expect(r.status.preRollFill == 1)
        r.start()
        #expect(waitUntil { r.status.url != nil })
        for b in stride(from: 100_000, to: 120_000, by: 1_000) { push(r, frames: b..<(b + 1_000)) }
        r.stop(wait: true)
        let status = r.status
        #expect(!status.isRecording)
        #expect(status.error == nil)
        #expect(status.startedAt == click.addingTimeInterval(-5))
        #expect(status.framesWritten == 70_000)
        #expect(status.duration == 7)
        #expect(status.filesWritten == 1)
        #expect(status.url?.lastPathComponent == "SubFloor_20261014_174635Z_7074000Hz_USB.wav")
        let frames = try wavFrames(status.url!)
        #expect(frames.count == 70_000)
        #expect(frames.first == 50_000 && frames.last == 119_999)
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $1 == $0 + 1 })
        let data = try Data(contentsOf: status.url!)
        #expect(data[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } == 280_000)
    }

    @Test func preRollIsOnlyWhatHasBeenHeard() throws {
        let dir = tempDir()
        let r = makeRecorder(folder: dir)
        defer { r.shutdown() }
        push(r, frames: 0..<2_000)
        #expect(abs(r.status.preRollFill - 0.04) < 1e-9)
        r.start()
        #expect(waitUntil { r.status.url != nil })
        r.stop(wait: true)
        let frames = try wavFrames(r.status.url!)
        #expect(frames.first == 0 && frames.count == 2_000)
    }

    @Test func wavRollsAtTheDataLimitWithoutLosingAFrame() throws {
        let dir = tempDir()
        let r = makeRecorder(preRoll: 5, folder: dir)
        defer { r.shutdown() }
        r.dataLimitOverride = 30_000 * 4
        r.now = { Date(timeIntervalSince1970: 1_792_000_000) }
        push(r, frames: 0..<10_000)
        r.start()
        #expect(waitUntil { r.status.url != nil })
        for b in stride(from: 10_000, to: 70_000, by: 1_000) { push(r, frames: b..<(b + 1_000)) }
        r.stop(wait: true)
        #expect(r.status.filesWritten == 3)
        let files = try wavs(in: dir)
        #expect(files.count == 3)
        #expect(files.map(\.lastPathComponent) == ["SubFloor_20261014_174639Z_0Hz_Audio.wav", "SubFloor_20261014_174642Z_0Hz_Audio.wav", "SubFloor_20261014_174645Z_0Hz_Audio.wav"])
        let all = try files.flatMap { try wavFrames($0) }
        #expect(all.count == 70_000 && all.first == 0 && all.last == 69_999)
        #expect(zip(all, all.dropFirst()).allSatisfy { $1 == $0 + 1 })
        #expect(try wavFrames(files[0]).count == 30_000)
    }

    @Test func retuneCutsToANewFileAndClearsThePreRoll() throws {
        let dir = tempDir()
        let r = makeRecorder(kind: .iq, folder: dir, rolls: true)
        defer { r.shutdown() }
        r.setContext(RecordingContext(frequencyHz: 14_100_000, label: "IQ", hardware: "demo"))
        push(r, frames: 0..<20_000, channels: 2)
        r.start()
        #expect(waitUntil { r.status.url != nil })
        push(r, frames: 20_000..<30_000, channels: 2)
        r.setContext(RecordingContext(frequencyHz: 7_100_000, label: "IQ", hardware: "demo"))
        #expect(r.status.preRollFill == 0)
        push(r, frames: 30_000..<40_000, channels: 2)
        r.stop(wait: true)
        #expect(r.status.filesWritten == 2)
        let files = try wavs(in: dir)
        #expect(files.count == 2)
        #expect(files.contains { $0.lastPathComponent.contains("14100000Hz") } && files.contains { $0.lastPathComponent.contains("7100000Hz") })
        let all = try files.sorted { $0.lastPathComponent.contains("14100000Hz") && !$1.lastPathComponent.contains("14100000Hz") }
            .flatMap { try wavFrames($0) }
        #expect(all.count == 2 * 40_000)
        #expect(stride(from: 0, to: all.count, by: 2).allSatisfy { all[$0] == Float($0 / 2) && all[$0 + 1] == Float($0 / 2) })
    }

    @Test func audioContextChangesNeitherRollNorClear() throws {
        let dir = tempDir()
        let r = makeRecorder(folder: dir)
        defer { r.shutdown() }
        r.setContext(RecordingContext(frequencyHz: 1, label: "USB", hardware: ""))
        push(r, frames: 0..<10_000)
        r.setContext(RecordingContext(frequencyHz: 2, label: "LSB", hardware: ""))
        #expect(r.status.preRollFill > 0)
        r.start()
        #expect(waitUntil { r.status.url != nil })
        r.setContext(RecordingContext(frequencyHz: 3, label: "AM", hardware: ""))
        push(r, frames: 10_000..<11_000)
        r.stop(wait: true)
        #expect(r.status.filesWritten == 1)
        #expect(r.status.url?.lastPathComponent.contains("2Hz_LSB") == true)
    }

    @Test func unwritableFolderReportsAnError() throws {
        let dir = tempDir()
        let blocker = dir.appendingPathComponent("file")
        try Data().write(to: blocker)
        let r = makeRecorder(folder: blocker.appendingPathComponent("inside"))
        defer { r.shutdown() }
        push(r, frames: 0..<1_000)
        r.start()
        #expect(waitUntil { r.status.error != nil })
        #expect(!r.status.isRecording)
    }

    @Test func reconfiguringTheRingStopsARecordingAndStartsThePreRollOver() throws {
        let dir = tempDir()
        let r = makeRecorder(folder: dir)
        defer { r.shutdown() }
        push(r, frames: 0..<10_000)
        r.start()
        #expect(waitUntil { r.status.url != nil })
        r.configure(StreamRecorder.Setup(sampleRate: Self.rate, channels: 1, fileFormat: .wav, sampleFormat: .int16,
                                         preRollSeconds: 5, memoryLimitBytes: 1 << 30, folder: dir))
        #expect(waitUntil { !r.status.isRecording })
        #expect(r.status.preRollFill == 0)
        #expect(r.effectivePreRollSeconds == 5)
    }

    @Test func flacRecordingThroughTheRecorder() throws {
        let dir = tempDir()
        let r = StreamRecorder(kind: .audio, rollsOnContextChange: false)
        defer { r.shutdown() }
        r.configure(StreamRecorder.Setup(sampleRate: 48_000, channels: 1, fileFormat: .flac, sampleFormat: .int24,
                                         preRollSeconds: 5, memoryLimitBytes: 1 << 30, folder: dir))
        var tone = [Float](repeating: 0, count: 48_000)
        for k in tone.indices { tone[k] = 0.5 * sinf(Float(k) * 2 * .pi * 440 / 48_000) }
        tone.withUnsafeBufferPointer { r.push($0) }
        r.start()
        #expect(waitUntil { r.status.url != nil })
        r.stop(wait: true)
        #expect(r.status.error == nil)
        #expect(r.status.url?.pathExtension == "flac")
        #expect(r.status.framesWritten == 48_000)
        let size = try FileManager.default.attributesOfItem(atPath: r.status.url!.path)[.size] as! Int
        #expect(size > 10_000 && size < 48_000 * 3)   // compressed, but not empty
    }
}

@Suite struct RecordingFormatTests {
    @Test func elapsedTimes() {
        #expect(RecordingFormat.elapsed(0) == "0:00")
        #expect(RecordingFormat.elapsed(7.9) == "0:07")
        #expect(RecordingFormat.elapsed(754) == "12:34")
        #expect(RecordingFormat.elapsed(3723) == "1:02:03")
    }
}
