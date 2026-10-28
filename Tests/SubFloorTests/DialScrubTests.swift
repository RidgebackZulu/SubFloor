import Foundation
import Recording
import SubFloorCore
import Testing
@testable import SubFloor

struct DialScrubTests {
    let rec = CatalogRecording(file: "a.flac", start: Date(timeIntervalSince1970: 1_792_000_000 + 0.4), seconds: 312,
                               frequencyHz: 11_175_000, mode: "USB", auto: true, heard: false, inProgress: false,
                               laneID: "11175000 USB")

    func target(pos: Double = 0, playing: Bool = false, jump: Double = 1) -> DialScrubTarget? {
        .make(windowIsKey: true, unplayableFile: nil, playerFile: "a.flac", loadError: nil, duration: 312,
              position: pos, playing: playing, jump: jump, recording: rec)
    }

    /// The `SCRUB on` line for `rec` with the given state.
    func scrubOn(pos: Double = 0, playing: Bool = false, jump: Double = 1) -> String {
        DialProtocol.scrubOn(startSecondOfDay: startSecondOfDay, length: 312, position: pos, playing: playing,
                             jump: jump, title: "11.175 MHz USB")
    }

    var startSecondOfDay: Double {
        let s = 1_792_000_000.4.truncatingRemainder(dividingBy: 86_400)
        return s < 0 ? s + 86_400 : s
    }

    @Test func targetNeedsAKeyWindowAndAPlayableRecording() {
        let t = target(pos: 5, playing: true, jump: 30)
        #expect(t == DialScrubTarget(file: "a.flac", title: "11.175 MHz USB", startSecondOfDay: startSecondOfDay,
                                     length: 312, position: 5, playing: true, jump: 30))
        #expect(abs((t?.startSecondOfDay ?? 0) - 1_792_000_000.4.truncatingRemainder(dividingBy: 86_400)) < 1e-6)

        func make(windowIsKey: Bool = true, unplayableFile: String? = nil, playerFile: String? = "a.flac",
                  loadError: String? = nil, duration: Double = 312,
                  recording: CatalogRecording?) -> DialScrubTarget? {
            .make(windowIsKey: windowIsKey, unplayableFile: unplayableFile, playerFile: playerFile,
                  loadError: loadError, duration: duration, position: 0, playing: false, jump: 1,
                  recording: recording)
        }
        var inProgress = rec
        inProgress.inProgress = true
        #expect(make(recording: rec) != nil)
        #expect(make(windowIsKey: false, recording: rec) == nil)
        #expect(make(unplayableFile: "a.flac", recording: rec) == nil)
        #expect(make(unplayableFile: "other.flac", recording: rec) != nil)
        #expect(make(playerFile: nil, recording: rec) == nil)
        #expect(make(playerFile: "b.flac", recording: rec) == nil)
        #expect(make(loadError: "unreadable", recording: rec) == nil)
        #expect(make(duration: 0, recording: rec) == nil)
        #expect(make(recording: inProgress) == nil)
        #expect(make(recording: nil) == nil)
    }

    @Test func turningOnSendsScrubOnOnce() {
        var sync = DialScrubSync()
        #expect(sync.lines(for: target(), now: 0) == [scrubOn()])
        #expect(sync.lines(for: target(), now: 0.1) == [])
    }

    @Test func targetGoneSendsScrubOff() {
        var sync = DialScrubSync()
        _ = sync.lines(for: target(), now: 0)
        #expect(sync.lines(for: nil, now: 1) == [DialProtocol.scrubOff])
        #expect(sync.lines(for: nil, now: 2) == [])
    }

    @Test func anotherFileSendsScrubOnAgain() {
        var sync = DialScrubSync()
        _ = sync.lines(for: target(), now: 0)
        var other = target(pos: 7, playing: true, jump: 5)!
        other.file = "b.flac"
        #expect(sync.lines(for: other, now: 1)
                == [DialProtocol.scrubOn(startSecondOfDay: startSecondOfDay, length: 312, position: 7, playing: true,
                                         jump: 5, title: "11.175 MHz USB")])
    }

    @Test func jumpAndPlayChangesSendTheirLines() {
        var sync = DialScrubSync()
        _ = sync.lines(for: target(), now: 0)
        #expect(sync.lines(for: target(jump: 30), now: 1) == [DialProtocol.jump(30)])
        #expect(sync.lines(for: target(jump: 30), now: 1.1) == [])
        #expect(sync.lines(for: target(pos: 3, playing: true, jump: 30), now: 2)
                == [DialProtocol.playing(true), DialProtocol.position(3)])
        #expect(DialProtocol.jump(30) == "JUMP 30")
        #expect(DialProtocol.playing(true) == "PLAY 1")
        #expect(DialProtocol.position(3) == "POS 3.00")
    }

    @Test func endOfPlaybackSendsPlayAndPosition() {
        var sync = DialScrubSync()
        #expect(sync.lines(for: target(pos: 310, playing: true), now: 0)
                == [scrubOn(pos: 310, playing: true)])
        #expect(sync.lines(for: target(pos: 312, playing: false), now: 2)
                == [DialProtocol.playing(false), DialProtocol.position(312)])
        #expect(DialProtocol.position(312) == "POS 312.00")
    }

    @Test func playingSendsPositionOnlyOnDriftOrEveryFiveSeconds() {
        var sync = DialScrubSync()
        _ = sync.lines(for: target(pos: 0, playing: true), now: 0)
        #expect(sync.lines(for: target(pos: 1.1, playing: true), now: 1) == [])
        #expect(sync.lines(for: target(pos: 2.6, playing: true), now: 2) == [DialProtocol.position(2.6)])
        #expect(DialProtocol.position(2.6) == "POS 2.60")
        // The resync carries the play state too.
        #expect(sync.lines(for: target(pos: 7.6, playing: true), now: 7.1)
                == [DialProtocol.playing(true), DialProtocol.position(7.6)])
        #expect(DialProtocol.position(7.6) == "POS 7.60")
    }

    @Test func pausedResyncsEveryFiveSecondsToo() {
        // A plain POS the dial dropped (the knob had just moved) is put right within 5 s, paused or not.
        var sync = DialScrubSync()
        _ = sync.lines(for: target(pos: 10), now: 0)
        #expect(sync.lines(for: target(pos: 40), now: 1) == [DialProtocol.position(40)])
        #expect(sync.lines(for: target(pos: 40), now: 5.9) == [])
        #expect(sync.lines(for: target(pos: 40), now: 6) == [DialProtocol.playing(false), DialProtocol.position(40)])
        #expect(sync.lines(for: target(pos: 40), now: 6.1) == [])
    }

    @Test func aTapOnTheDialAlwaysAnswersThePlayState() {
        // The window paused the player just before the dial's tap played it again: the state did not change since
        // it was last sent, but the dial predicted a toggle, so it is told anyway.
        var sync = DialScrubSync()
        _ = sync.lines(for: target(pos: 4, playing: true), now: 0)
        #expect(sync.lines(for: target(pos: 4.5, playing: true), now: 0.5, playToggled: true)
                == [DialProtocol.playing(true), DialProtocol.position(4.5)])
        #expect(sync.lines(for: target(pos: 4.6, playing: true), now: 0.6) == [])
    }

    @Test func jumpAndPlayInOneCall() {
        var sync = DialScrubSync()
        _ = sync.lines(for: target(), now: 0)
        #expect(sync.lines(for: target(pos: 2, playing: true, jump: 5), now: 1)
                == [DialProtocol.jump(5), DialProtocol.playing(true), DialProtocol.position(2)])
    }

    @Test func aSeekInTheWindowSendsPosition() {
        var sync = DialScrubSync()
        _ = sync.lines(for: target(pos: 10), now: 0)
        #expect(sync.lines(for: target(pos: 40), now: 1) == [DialProtocol.position(40)])
        #expect(sync.lines(for: target(pos: 40), now: 1.1) == [])
    }

    @Test func seekBeyondTheEndAnswersTheClampedPosition() {
        var sync = DialScrubSync()
        _ = sync.lines(for: target(pos: 300), now: 0)
        #expect(sync.answer(position: 312, seq: 9, now: 1) == DialProtocol.position(312, seq: 9))
        #expect(DialProtocol.position(312, seq: 9) == "POS 312.00 9")
        #expect(sync.lines(for: target(pos: 312), now: 1.05) == [])
    }

    @Test func dialChosenJumpIsNotEchoed() {
        var sync = DialScrubSync()
        _ = sync.lines(for: target(), now: 0)
        sync.dialChose(jump: 5)
        #expect(sync.lines(for: target(jump: 5), now: 1) == [])
    }

    @Test func helloResendsScrubOn() {
        var sync = DialScrubSync()
        _ = sync.lines(for: target(), now: 0)
        sync.reset()
        #expect(sync.lines(for: target(), now: 1) == [scrubOn()])
        sync.reset()
        #expect(sync.lines(for: nil, now: 2) == [])
    }

    @Test func syncSendsNothingToOldFirmware() {
        // The controller passes nil for firmware before 1.1.0.
        var sync = DialScrubSync()
        #expect(sync.lines(for: nil, now: 0) == [])
        #expect(sync.lines(for: nil, now: 1) == [])
    }
}

extension DialScrubTests {
    /// The controller between the dial's lines and the player, on a hermetic model with a real three-second
    /// recording loaded. Lines go in through `receive` and come out through `sentLinesForTesting` (no link is open).
    @MainActor
    @Suite(.serialized)
    struct Controller {
        private final class Sent { var lines: [String] = [] }

        private struct Rig {
            let model: AppModel, controller: DialController, sent: Sent
            @MainActor var player: RecordingPlayer { model.player }
        }

        private static let start = Date(timeIntervalSince1970: 1_792_074_600.456)

        /// A model whose recordings folder holds one three-second WAV with its log line, loaded in the player, and a
        /// controller whose sent lines are captured.
        private func rig(windowIsKey: Bool = true) async throws -> Rig {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorDialTests-\(UUID().uuidString)",
                                                                                    isDirectory: true)
            let folder = dir.appendingPathComponent("rec", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = "SubFloor_20261015_143000Z_146520000Hz_NFM.wav"
            try writeWAV(folder.appendingPathComponent(file), seconds: 3)
            try RecordingLog(folder: folder).append([
                .recording(file: file, start: Self.start, seconds: 3, frequencyHz: 146_520_000, mode: "NFM", auto: true),
            ])
            let model = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                                 defaults: UserDefaults(suiteName: UUID().uuidString)!)
            model.recording.folderPath = folder.path
            await model.library.reload()
            model.player.volume = 0
            model.player.load(try #require(model.library.catalog.recording(file)))
            try #require(model.player.loadError == nil && model.player.duration > 0)
            model.recordingsWindowIsKey = windowIsKey
            let controller = DialController(model: model, defaults: UserDefaults(suiteName: UUID().uuidString)!)
            let sent = Sent()
            controller.sentLinesForTesting = { sent.lines.append($0) }
            return Rig(model: model, controller: controller, sent: sent)
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

        /// Feeds the dial's line and returns what the controller sent in reply.
        @discardableResult
        private func receive(_ rig: Rig, _ line: String) -> [String] {
            rig.sent.lines = []
            rig.controller.receive(line, on: .usb)
            return rig.sent.lines
        }

        private func isScrubLine(_ line: String) -> Bool {
            ["SCRUB", "POS", "PLAY", "JUMP"].contains { line.hasPrefix($0 + " ") }
        }

        @Test func helloFromNewFirmwareStartsScrubAtOnce() async throws {
            let r = try await rig()
            defer { r.player.unload() }
            let lines = receive(r, "HELLO SubFloorDial 1.1.0 step=100 knob=tune")
            // Straight after the state, not on the next tick: a turn right after a link change must be a J, not a T.
            #expect(lines.count == 3)
            #expect(lines.first?.hasPrefix("S f=") == true)
            #expect(lines.last == DialProtocol.scrubOn(startSecondOfDay: 52_200.456, length: r.player.duration,
                                                       position: 0, playing: false, jump: 1, title: "146.520 MHz NFM"))
            #expect(lines.last?.hasPrefix("SCRUB on t0=52200.456 len=3.00 pos=0.00 play=0 jump=1 title=") == true)
        }

        @Test func aTurnSeeksThePlayerAndAnswersItsPosition() async throws {
            let r = try await rig()
            defer { r.player.unload() }
            receive(r, "HELLO SubFloorDial 1.1.0 step=100 knob=tune")
            #expect(receive(r, "J 1 2 1") == ["POS 2.00 1"])
            #expect(abs(r.player.position - 2) < 1e-9)
            #expect(receive(r, "J 2 -5 0.1") == ["POS 1.50 2"])
            #expect(abs(r.player.position - 1.5) < 1e-9)
            // Past the end: the player clamps, and the answer is the clamped position.
            #expect(receive(r, "J 3 4 1") == ["POS 3.00 3"])
            #expect(r.player.position == r.player.duration)
        }

        @Test func aJumpFromTheDialSetsThePlayersJump() async throws {
            let r = try await rig()
            defer { r.player.unload() }
            receive(r, "HELLO SubFloorDial 1.1.0 step=100 knob=tune")
            #expect(receive(r, "JUMP 5") == [], "not echoed")
            #expect(r.player.jump == 5)
            #expect(receive(r, "JUMP 7") == [])
            #expect(r.player.jump == 5, "not a jump size")
        }

        @Test func aTapTogglesPlayAndAnswersThePlayState() async throws {
            let r = try await rig()
            defer { r.player.unload() }
            receive(r, "HELLO SubFloorDial 1.1.0 step=100 knob=tune")
            #expect(receive(r, "PLAY") == ["PLAY 1", "POS 0.00"])
            #expect(r.player.isPlaying)
            let paused = receive(r, "PLAY")
            #expect(!r.player.isPlaying)
            #expect(paused.first == "PLAY 0")
            #expect(paused.count == 2 && paused[1].hasPrefix("POS "))
        }

        @Test func oldFirmwareGetsNoScrubLines() async throws {
            let r = try await rig()
            defer { r.player.unload() }
            let hello = receive(r, "HELLO SubFloorDial 1.0.0 step=100 knob=tune")
            #expect(!hello.isEmpty && !hello.contains(where: isScrubLine))
            #expect(receive(r, "J 1 2 1") == [])
            #expect(receive(r, "JUMP 5") == [])
            #expect(receive(r, "PLAY") == [])
            #expect(r.player.position == 0 && r.player.jump == 1 && !r.player.isPlaying)
        }

        @Test func noKeyWindowNoScrub() async throws {
            let r = try await rig(windowIsKey: false)
            defer { r.player.unload() }
            let hello = receive(r, "HELLO SubFloorDial 1.1.0 step=100 knob=tune")
            #expect(!hello.isEmpty && !hello.contains(where: isScrubLine))
            #expect(r.controller.scrubTarget == nil)
            #expect(receive(r, "J 1 2 1") == [])
            #expect(receive(r, "JUMP 5") == [])
            #expect(receive(r, "PLAY") == [])
            #expect(r.player.position == 0 && r.player.jump == 1 && !r.player.isPlaying)
        }
    }
}
