import Foundation
import Recording
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
        #expect(sync.lines(for: target(pos: 7.6, playing: true), now: 7.1) == [DialProtocol.position(7.6)])
        #expect(DialProtocol.position(7.6) == "POS 7.60")
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
