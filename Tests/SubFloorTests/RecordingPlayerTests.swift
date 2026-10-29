import AVFoundation
import DSPCore
import Foundation
import Recording
import SubFloorCore
import Testing
@testable import Recording
@testable import SubFloor

/// The player that opens a recording from the Recordings window, and the live radio going quiet while it
/// plays. The tests that play through the real output device use WAVs of silence, so they make no sound, and
/// they wait on bounded conditions, never on real-time pacing (one position check has a tolerance). The tests
/// that need sound (noise, tones) render the player's engine offline.
@MainActor
@Suite(.serialized)
struct RecordingPlayerTests {
    private static let base = Date(timeIntervalSince1970: 1_792_074_600)

    private func tempFolder() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorPlayerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func name(_ offset: Double, ext: String = "wav", mode: String = "NFM") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return "SubFloor_\(f.string(from: Self.base.addingTimeInterval(offset)))Z_146520000Hz_\(mode).\(ext)"
    }

    /// A mono 16-bit PCM WAV of silence, or of white noise at about −15 dBFS RMS.
    private func writeWAV(_ url: URL, seconds: Double, rate: Int = 48_000, noise: Bool = false) throws {
        let frames = Int(seconds * Double(rate))
        var data = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + frames * 2)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(frames * 2)
        if noise {
            var generator = SystemRandomNumberGenerator()
            for _ in 0..<frames {
                withUnsafeBytes(of: Int16.random(in: -10_000...10_000, using: &generator).littleEndian) { data.append(contentsOf: $0) }
            }
        } else {
            data.append(Data(count: frames * 2))
        }
        try data.write(to: url)
    }

    /// A mono WAV of tone (a quiet 1 kHz sine) and digital silence in the given order, and the peaks a waveform
    /// read of it gives (10 ms bins, 128 where there is tone).
    private func writePattern(_ url: URL, _ pattern: [(seconds: Double, tone: Bool)], rate: Int = 48_000) throws {
        var samples: [Int16] = []
        for part in pattern {
            let frames = Int(part.seconds * Double(rate))
            for i in 0..<frames {
                samples.append(part.tone ? Int16(8_000 * sin(2 * Double.pi * 1_000 * Double(i) / Double(rate))) : 0)
            }
        }
        var data = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + samples.count * 2)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(samples.count * 2)
        for v in samples { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        try data.write(to: url)
    }

    private func patternPeaks(_ pattern: [(seconds: Double, tone: Bool)]) -> WaveformPeaks {
        var bins: [UInt8] = []
        for part in pattern { bins += Array(repeating: part.tone ? 128 : 0, count: Int((part.seconds * 100).rounded())) }
        return WaveformPeaks(sampleRate: 48_000, frames: bins.count * 480, peaks: bins)
    }

    private final class Muted { var values: [Bool] = [] }

    private struct Rig {
        let folder: URL, library: RecordingsLibrary, player: RecordingPlayer, muted: Muted, files: [String]
    }

    /// A folder of `count` recordings (three seconds of silence unless asked otherwise), each with a `recording`
    /// line so it is unheard, and a player over the library once it has read them.
    private func rig(count: Int = 1, seconds: Double = 3, mode: String = "NFM", noise: Bool = false,
                     pattern: [(seconds: Double, tone: Bool)]? = nil) async throws -> Rig {
        let folder = tempFolder()
        let files = (0..<count).map { name(Double($0) * 60, mode: mode) }
        let seconds = pattern.map { $0.reduce(0) { $0 + $1.seconds } } ?? seconds
        for file in files {
            if let pattern { try writePattern(folder.appendingPathComponent(file), pattern) }
            else { try writeWAV(folder.appendingPathComponent(file), seconds: seconds, noise: noise) }
        }
        try RecordingLog(folder: folder).append(files.enumerated().map { i, file in
            .recording(file: file, start: Self.base.addingTimeInterval(Double(i) * 60), seconds: seconds, frequencyHz: 146_520_000, mode: mode, auto: true)
        })
        let library = RecordingsLibrary(folder: folder)
        await library.reload()
        let muted = Muted()
        let player = RecordingPlayer(library: library, setLiveMuted: { muted.values.append($0) })
        player.volume = 0
        return Rig(folder: folder, library: library, player: player, muted: muted, files: files)
    }

    private func recording(_ rig: Rig, _ index: Int = 0) throws -> CatalogRecording {
        try #require(rig.library.catalog.recording(rig.files[index]))
    }

    @discardableResult
    private func wait(upTo timeout: Double, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() {
            if Date() >= end { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }

    @Test func playMarksHeardAndMutesLive() async throws {
        let r = try await rig()
        #expect(r.library.unheardCount == 1)
        r.player.load(try recording(r))
        #expect(r.player.file == r.files[0])
        #expect(abs(r.player.duration - 3) < 0.05)
        #expect(r.player.position == 0)
        #expect(r.player.start == Self.base)
        r.player.play()
        #expect(r.player.isPlaying)
        #expect(r.muted.values.last == true)
        #expect(r.library.unheardCount == 0)
        r.player.unload()
    }

    @Test func pauseUnmutes() async throws {
        let r = try await rig()
        r.player.load(try recording(r))
        r.player.play()
        r.player.pause()
        #expect(!r.player.isPlaying)
        #expect(r.muted.values.last == false)
        r.player.unload()
    }

    @Test func seekClampsAndMoveUsesTheJump() async throws {
        let r = try await rig()
        let p = r.player
        p.load(try recording(r))
        p.seek(to: -1)
        #expect(p.position == 0)
        p.seek(to: 99)
        #expect(abs(p.position - p.duration) < 0.001)
        #expect(abs(p.duration - 3) < 0.05)
        p.jump = 0.5
        p.seek(to: 1)
        p.move(jumps: 2)
        #expect(abs(p.position - 2) < 0.001)
        p.move(jumps: -9)
        #expect(p.position == 0)
        #expect(p.playheadTime == Self.base)
        p.unload()
    }

    @Test func playingToTheEndStopsAndUnmutes() async throws {
        let r = try await rig()
        let p = r.player
        p.load(try recording(r))
        p.seek(to: 2.9)
        p.play()
        // Bounded, not paced: under a full test run (other suites starting and stopping audio, a busy main
        // thread) the last 0.1 s, and the end's delegate call or poll, can come seconds late.
        #expect(wait(upTo: 180) { !p.isPlaying })   // 28 s and 40 s seen in full runs
        #expect(abs(p.position - p.duration) < 0.001)
        #expect(abs(p.duration - 3) < 0.05)
        #expect(r.muted.values.last == false)
        p.unload()
    }

    @Test func anEngineThatStopsUnmutes() async throws {
        let r = try await rig()
        let p = r.player
        p.load(try recording(r))
        p.seek(to: 1)
        p.play()
        #expect(r.muted.values.last == true)
        let stoppedAt = p.position
        p.engine.stop()   // behind the player's back, as when an output device goes away
        #expect(wait(upTo: 10) { !p.isPlaying })
        #expect(r.muted.values.last == false)
        #expect(abs(p.position - stoppedAt) < 0.001)   // where it stopped, inside the file
        #expect(p.position > 0 && p.position < p.duration)
        p.play()   // the engine starts again
        #expect(p.isPlaying)
        #expect(wait(upTo: 5) { p.position > stoppedAt + 0.05 })
        p.unload()
    }

    @Test func unreadableFileShowsAnError() async throws {
        let folder = tempFolder()
        let file = name(0, ext: "flac")
        try Data("not audio".utf8).write(to: folder.appendingPathComponent(file))
        try RecordingLog(folder: folder).append([
            .recording(file: file, start: Self.base, seconds: 3, frequencyHz: 146_520_000, mode: "NFM", auto: true)])
        let library = RecordingsLibrary(folder: folder)
        await library.reload()
        let muted = Muted()
        let p = RecordingPlayer(library: library, setLiveMuted: { muted.values.append($0) })
        p.load(try #require(library.catalog.recording(file)))
        #expect(p.loadError == "Can't play this file")
        p.play()
        #expect(!p.isPlaying)
        #expect(!muted.values.contains(true))
        #expect(library.unheardCount == 1)   // not heard: nothing was played
        p.unload()
        #expect(p.loadError == nil)
    }

    @Test func inProgressRecordingsCannotLoad() async throws {
        let r = try await rig()
        let live = CatalogRecording(file: r.files[0], start: Self.base, seconds: 1, frequencyHz: 146_520_000, mode: "NFM",
                                    auto: true, heard: false, inProgress: true, laneID: "146520000 NFM")
        r.player.load(live)
        #expect(r.player.file == nil)
        r.player.play()
        #expect(!r.player.isPlaying)
    }

    @Test func loadingAnotherFileStopsTheFirst() async throws {
        let r = try await rig(count: 2)
        r.player.load(try recording(r, 0))
        r.player.play()
        r.player.load(try recording(r, 1))
        #expect(r.player.file == r.files[1])
        #expect(!r.player.isPlaying)
        #expect(r.player.position == 0)
        #expect(r.muted.values.last == false)
        r.player.unload()
    }

    @Test func deletedFileUnloads() async throws {
        let r = try await rig()
        r.player.load(try recording(r))
        r.player.play()
        try FileManager.default.removeItem(at: r.folder.appendingPathComponent(r.files[0]))
        await r.library.refreshFiles()
        r.player.reconcile(with: r.library.catalog)
        #expect(r.player.file == nil)
        #expect(!r.player.isPlaying)
        #expect(r.muted.values.last == false)
    }

    @Test func positionAdvancesWhilePlaying() async throws {
        let r = try await rig()
        r.player.load(try recording(r))
        r.player.play()
        #expect(wait(upTo: 5) { r.player.position > 0.05 })
        r.player.pause()
        let held = r.player.position
        wait(upTo: 0.2) { false }
        #expect(r.player.position == held)   // the timer stops with the playback
        r.player.unload()
    }

    @Test func liveVolumeIsZeroWhileMuted() throws {
        let dir = tempFolder()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let m = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")), defaults: defaults)
        m.volume = 0.4
        #expect(m.effectiveVolume == 0.4)
        m.liveAudioMuted = true
        #expect(m.effectiveVolume == 0)
        #expect(m.volume == 0.4)   // the knob keeps its position, and so does the saved session
        m.liveAudioMuted = false
        #expect(m.effectiveVolume == 0.4)
        m.liveAudioMuted = true
        m.shutdown()   // saves the session
        let data = try #require(defaults.data(forKey: "session"))
        let saved = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((saved["volume"] as? NSNumber)?.floatValue == 0.4)
    }

    @Test func liveAudioIsSilentWhileTheRecordingsWindowIsOpen() {
        let dir = tempFolder()
        let m = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                         defaults: UserDefaults(suiteName: UUID().uuidString)!)
        m.volume = 0.4
        m.recordingsWindowOpen = true
        #expect(m.effectiveVolume == 0)
        m.liveAudioMuted = true
        m.liveAudioMuted = false   // playback stopped: still silent while the window is up
        #expect(m.effectiveVolume == 0)
        m.recordingsWindowOpen = false
        #expect(m.effectiveVolume == 0.4)
        #expect(m.volume == 0.4)
    }

    @Test func thePlayerFollowsTheVolumeKnob() async throws {
        let dir = tempFolder()
        let m = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                         defaults: UserDefaults(suiteName: UUID().uuidString)!)
        m.volume = 0.3
        #expect(m.player.volume == 0.3)
        m.shutdown()
    }

    @Test func folderChangeUnloadsThePlayer() async throws {
        let dir = tempFolder()
        let m = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                         defaults: UserDefaults(suiteName: UUID().uuidString)!)
        defer { m.shutdown() }
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        for folder in [a, b] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let file = name(0)
        try writeWAV(a.appendingPathComponent(file), seconds: 3)
        try RecordingLog(folder: a).append([
            .recording(file: file, start: Self.base, seconds: 3, frequencyHz: 146_520_000, mode: "NFM", auto: true)])
        // The same name in B, so only the folder tells the two apart.
        try writeWAV(b.appendingPathComponent(file), seconds: 3)
        m.library.setFolder(a)
        await m.library.reload()
        m.player.volume = 0
        m.player.load(try #require(m.library.catalog.recording(file)))
        m.player.play()
        #expect(m.player.isPlaying)
        #expect(m.liveAudioMuted)
        m.library.setFolder(b)
        await m.library.reload()
        #expect(m.player.file == nil)
        #expect(!m.player.isPlaying)
        #expect(!m.liveAudioMuted)
    }

    @Test func seekingWhilePlayingKeepsPlaying() async throws {
        let r = try await rig()
        let p = r.player
        p.load(try recording(r))
        p.play()
        #expect(wait(upTo: 5) { p.position > 0.05 })
        p.seek(to: p.duration / 2)
        #expect(p.isPlaying)
        wait(upTo: 0.2) { false }
        #expect(p.isPlaying)
        #expect(p.position >= p.duration / 2)
        #expect(p.position < p.duration)
        #expect(r.muted.values.last == true)
        p.unload()
    }

    @Test func positionFollowsAFileOfKnownLength() async throws {
        let r = try await rig(seconds: 2)
        let p = r.player
        p.load(try recording(r))
        #expect(abs(p.duration - 2) < 0.001)
        p.play()
        wait(upTo: 0.5) { false }
        #expect(p.isPlaying)
        print("position \(p.position) s after 0.5 s of playing")
        #expect(abs(p.position - 0.5) <= 0.15, "position \(p.position) s after 0.5 s")
        p.unload()
    }

    @Test func nrSettingReachesTheEffect() async throws {
        let usb = try await rig(mode: "USB")
        let p = usb.player
        #expect(!p.noiseReductionAvailable)   // nothing loaded
        p.load(try recording(usb))
        #expect(p.noiseReductionAvailable)
        p.noiseReduction = NoiseReductionSettings(enabled: true, strength: 0.7)
        let unit = try #require(p.noiseReductionUnit)
        #expect(unit.requested.enabled)
        #expect(abs(unit.requested.strength - 0.7) < 1e-6)
        p.noiseReduction.enabled = false
        #expect(!unit.requested.enabled)
        p.unload()
        #expect(!p.noiseReductionAvailable)

        let wfm = try await rig(mode: "WFM")
        wfm.player.noiseReduction = NoiseReductionSettings(enabled: true, strength: 0.7)
        wfm.player.load(try recording(wfm))
        #expect(!wfm.player.noiseReductionAvailable)
        #expect(wfm.player.noiseReductionUnit?.requested.enabled != true)
        wfm.player.unload()

        let unknown = try await rig(mode: "DRM")
        unknown.player.noiseReduction = NoiseReductionSettings(enabled: true, strength: 0.7)
        unknown.player.load(try recording(unknown))
        #expect(!unknown.player.noiseReductionAvailable)
        #expect(unknown.player.noiseReductionUnit?.requested.enabled != true)
        unknown.player.unload()
    }

    @Test func appModelHandsThePlayerItsNRSetting() {
        let dir = tempFolder()
        let m = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                         defaults: UserDefaults(suiteName: UUID().uuidString)!)
        defer { m.shutdown() }
        #expect(m.player.noiseReduction == m.noiseReduction)
        m.noiseReduction = NoiseReductionSettings(enabled: true, strength: 0.9)
        #expect(m.player.noiseReduction == NoiseReductionSettings(enabled: true, strength: 0.9))
    }

    /// Offline, through the engine's manual rendering: three seconds of white noise, the last second measured.
    @Test func playbackThroughNRIsQuieterOnNoise() async throws {
        let off = try await lastSecondRMS(nr: false)
        let on = try await lastSecondRMS(nr: true)
        #expect(off > 0.01)
        let db = 20 * log10(Double(on) / Double(off))
        print("NR on vs off over the last second of white noise: \(db) dB")
        #expect(db <= -10, "NR on is \(db) dB against off")
    }

    /// WAV at another rate and in stereo, FLAC and M4A: each opens with its length, and plays through the
    /// effect (converted to 48 kHz mono on the way) at about the level it was written. NR is off: a steady
    /// tone is exactly what the reducer learns as noise.
    @Test func otherFormatsPlayThroughTheEffect() async throws {
        let cases: [(ext: String, format: AudioFormatID, rate: Double, channels: Int)] = [
            ("wav", kAudioFormatLinearPCM, 44_100, 2), ("flac", kAudioFormatFLAC, 48_000, 1),
            ("m4a", kAudioFormatMPEG4AAC, 44_100, 2), ("wav", kAudioFormatLinearPCM, 24_000, 1)]
        for c in cases {
            let folder = tempFolder()
            let file = name(0, ext: c.ext, mode: "USB")
            try writeTone(folder.appendingPathComponent(file), format: c.format, rate: c.rate, channels: c.channels, seconds: 2)
            try RecordingLog(folder: folder).append([
                .recording(file: file, start: Self.base, seconds: 2, frequencyHz: 146_520_000, mode: "USB", auto: true)])
            let library = RecordingsLibrary(folder: folder)
            await library.reload()
            let p = RecordingPlayer(library: library, setLiveMuted: { _ in })
            p.volume = 1
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            try p.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            p.load(try #require(library.catalog.recording(file)))
            #expect(p.loadError == nil, "\(c)")
            #expect(abs(p.duration - 2) < 0.05, "\(c): \(p.duration) s")
            #expect(p.noiseReductionAvailable)
            p.play()
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
            var rendered: [Float] = []
            while rendered.count < 48_000 * 3 / 2 {
                guard try p.engine.renderOffline(4096, to: buffer) == .success else { break }
                rendered += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            }
            p.unload()
            let middle = rendered[24_000..<min(rendered.count, 72_000)]
            let rms = (middle.reduce(0) { $0 + $1 * $1 } / Float(max(middle.count, 1))).squareRoot()
            print("\(c): rendered RMS \(20 * log10(rms)) dBFS (tone written at −15 dBFS RMS per channel)")
            #expect(abs(20 * log10(rms) + 15) < 4, "\(c): RMS \(rms)")
        }
    }

    /// A 1 kHz sine at 0.25 peak on every channel.
    // MARK: Skip silence

    /// One second of tone, two of silence, one of tone: the silence is 1.0 ..< 3.0, a skip lands at 2.8.
    private static let gap: [(seconds: Double, tone: Bool)] = [(1, true), (2, false), (1, true)]
    /// One second of tone, then two of silence to the end.
    private static let trailing: [(seconds: Double, tone: Bool)] = [(1, true), (2, false)]

    @Test func skipSilenceJumpsAGapWhilePlaying() async throws {
        let r = try await rig(pattern: Self.gap)
        let p = r.player
        p.load(try recording(r))
        p.setPeaks(patternPeaks(Self.gap), for: r.files[0])
        p.skipSilence = true
        p.seek(to: 0.9)
        p.play()
        // Position changes only in `tick`, which skips in the same call, so no sample between the ticks ever
        // sees the silence's middle, however late a tick is.
        var inTheMiddle = false
        let landed = wait(upTo: 60) {
            if p.position > 1.3 && p.position < 2.7 { inTheMiddle = true }
            return p.position >= 2.75
        }
        #expect(landed)
        #expect(!inTheMiddle)
        p.unload()
    }

    @Test func pausedSeeksIntoSilenceStay() async throws {
        let r = try await rig(pattern: Self.gap)
        let p = r.player
        p.load(try recording(r))
        p.setPeaks(patternPeaks(Self.gap), for: r.files[0])
        p.seek(to: 1.5)
        for _ in 0..<9 { p.tick() }
        wait(upTo: 0.3) { false }
        #expect(p.position == 1.5)
        p.move(jumps: 1)       // the arrow keys and the Dial go through `seek` too
        #expect(abs(p.position - 2.5) < 0.001)
        p.unload()
    }

    @Test func playInSilenceJumpsAhead() async throws {
        let r = try await rig(pattern: Self.gap)
        let p = r.player
        p.load(try recording(r))
        p.setPeaks(patternPeaks(Self.gap), for: r.files[0])
        p.seek(to: 1.5)
        p.play()
        #expect(abs(p.position - 2.8) < 0.001)
        #expect(p.isPlaying)
        p.unload()
    }

    @Test func trailingSilenceEndsPlayback() async throws {
        let r = try await rig(pattern: Self.trailing)
        let p = r.player
        p.load(try recording(r))
        p.setPeaks(patternPeaks(Self.trailing), for: r.files[0])
        p.seek(to: 1.2)
        p.play()
        #expect(!p.isPlaying)
        #expect(p.position == p.duration)
        #expect(r.muted.values.last != true)        // the live radio is never left muted
        #expect(r.library.unheardCount == 0)        // and it counts as played
        // The same when it is found while playing: the tone's end is crossed, the rest is skipped.
        p.seek(to: 0.9)
        p.play()
        #expect(wait(upTo: 60) { !p.isPlaying })
        #expect(p.position == p.duration)
        #expect(r.muted.values.last == false)
        p.unload()
    }

    @Test func skipOffPlaysThroughSilence() async throws {
        let r = try await rig(pattern: Self.gap)
        let p = r.player
        p.load(try recording(r))
        p.setPeaks(patternPeaks(Self.gap), for: r.files[0])
        p.skipSilence = false
        p.seek(to: 1.5)
        p.play()
        #expect(abs(p.position - 1.5) < 0.001)       // no jump on Play
        #expect(wait(upTo: 60) { p.position > 2.0 })
        #expect(p.position < 2.7)                    // and none while it plays: 0.5 s on, not 1.3
        p.unload()
    }

    @Test func peaksForAnotherFileOrNoneSkipNothing() async throws {
        let r = try await rig(pattern: Self.gap)
        let p = r.player
        p.load(try recording(r))
        p.seek(to: 1.5)
        p.play()                                      // no map yet: the peaks are still loading
        #expect(abs(p.position - 1.5) < 0.001)
        p.pause()
        p.setPeaks(patternPeaks(Self.gap), for: "SubFloor_other.wav")
        p.seek(to: 1.5)
        p.play()
        #expect(abs(p.position - 1.5) < 0.001)
        p.pause()
        p.setPeaks(patternPeaks(Self.gap), for: r.files[0])
        p.unload()
        p.load(try recording(r))                      // unload cleared the map
        p.seek(to: 1.5)
        p.play()
        #expect(abs(p.position - 1.5) < 0.001)
        p.unload()
    }

    @Test func appModelHandsThePlayerItsSkipSilenceSetting() {
        let dir = tempFolder()
        let m = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                         defaults: UserDefaults(suiteName: UUID().uuidString)!)
        defer { m.shutdown() }
        #expect(m.player.skipSilence)
        m.skipSilence = false
        #expect(!m.player.skipSilence)
    }

    private func writeTone(_ url: URL, format: AudioFormatID, rate: Double, channels: Int, seconds: Double) throws {
        var settings: [String: Any] = [AVFormatIDKey: format, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels]
        if format == kAudioFormatLinearPCM { settings[AVLinearPCMBitDepthKey] = 16 }
        if format == kAudioFormatFLAC { settings[AVLinearPCMBitDepthKey] = 24 }
        let out = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        for ch in 0..<channels {
            let data = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) { data[i] = 0.25 * sin(2 * .pi * 1_000 * Float(i) / Float(rate)) }
        }
        try out.write(from: buffer)
    }

    private func lastSecondRMS(nr: Bool) async throws -> Float {
        let r = try await rig(mode: "USB", noise: true)
        let p = r.player
        p.volume = 1
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        try p.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        p.noiseReduction = NoiseReductionSettings(enabled: nr, strength: 1)
        p.load(try recording(r))
        p.play()
        #expect(p.isPlaying)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        var rendered: [Float] = []
        while rendered.count < 3 * 48_000 {
            guard try p.engine.renderOffline(4096, to: buffer) == .success else { break }
            rendered += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        p.unload()
        #expect(rendered.count >= 3 * 48_000)
        let last = rendered.suffix(48_000)
        return (last.reduce(0) { $0 + $1 * $1 } / Float(max(last.count, 1))).squareRoot()
    }
}
