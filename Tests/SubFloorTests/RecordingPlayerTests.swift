import AVFoundation
import Foundation
import Recording
import SubFloorCore
import Testing
@testable import SubFloor

/// The player that opens a recording from the Recordings window, and the live radio going quiet while it
/// plays. The WAVs are three seconds of silence: the tests play through the real output device, so they make
/// no sound, and they wait on bounded conditions, never on real-time pacing.
@MainActor
@Suite(.serialized)
struct RecordingPlayerTests {
    private static let base = Date(timeIntervalSince1970: 1_792_074_600)

    private func tempFolder() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorPlayerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func name(_ offset: Double, ext: String = "wav") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return "SubFloor_\(f.string(from: Self.base.addingTimeInterval(offset)))Z_146520000Hz_NFM.\(ext)"
    }

    /// A mono 16-bit PCM WAV of silence.
    private func writeWAV(_ url: URL, seconds: Double, rate: Int = 48_000) throws {
        let frames = Int(seconds * Double(rate))
        var data = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + frames * 2)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(frames * 2)
        data.append(Data(count: frames * 2))
        try data.write(to: url)
    }

    private final class Muted { var values: [Bool] = [] }

    private struct Rig {
        let folder: URL, library: RecordingsLibrary, player: RecordingPlayer, muted: Muted, files: [String]
    }

    /// A folder of `count` three-second recordings, each with a `recording` line so it is unheard, and a
    /// player over the library once it has read them.
    private func rig(count: Int = 1) async throws -> Rig {
        let folder = tempFolder()
        let files = (0..<count).map { name(Double($0) * 60) }
        for file in files { try writeWAV(folder.appendingPathComponent(file), seconds: 3) }
        try RecordingLog(folder: folder).append(files.enumerated().map { i, file in
            .recording(file: file, start: Self.base.addingTimeInterval(Double(i) * 60), seconds: 3, frequencyHz: 146_520_000, mode: "NFM", auto: true)
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
        #expect(wait(upTo: 5) { !p.isPlaying })
        #expect(abs(p.position - p.duration) < 0.001)
        #expect(abs(p.duration - 3) < 0.05)
        #expect(r.muted.values.last == false)
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
}
