import Foundation
import Recording

/// What the dial scrubs. nil anywhere means the dial tunes.
struct DialScrubTarget: Equatable {
    var file: String
    var title: String              // "11.175 MHz USB"
    var startSecondOfDay: Double   // UTC seconds since midnight of the recording's start
    var length: Double
    var position: Double
    var playing: Bool
    var jump: Double

    /// The scrub-mode condition: the Recordings window is key and the selected recording is playable (loaded in the
    /// player without a load error, longer than 0 s, not in progress, not marked unplayable by the window).
    static func make(windowIsKey: Bool, unplayableFile: String?, playerFile: String?, loadError: String?,
                     duration: Double, position: Double, playing: Bool, jump: Double,
                     recording: CatalogRecording?) -> DialScrubTarget? {
        guard windowIsKey, let recording, !recording.inProgress,
              playerFile == recording.file, unplayableFile != recording.file,
              loadError == nil, duration > 0 else { return nil }
        let second = recording.start.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400)
        return DialScrubTarget(
            file: recording.file,
            title: RecordingsCatalog.laneTitle(frequencyHz: recording.frequencyHz, mode: recording.mode),
            startSecondOfDay: second < 0 ? second + 86_400 : second,
            length: duration, position: position, playing: playing, jump: jump)
    }
}

/// Turns successive targets into the lines that keep the dial's scrub screen right. `now` is monotonic seconds.
struct DialScrubSync {
    /// The file the dial is scrubbing (nil: it is tuning, as far as SubFloor knows).
    private var file: String?
    /// What the dial was last told: the position at `sentTime`, the play state and the jump.
    private var sentPosition = 0.0
    private var sentTime = 0.0
    private var sentPlaying = false
    private var sentJump = 0.0
    private var length = 0.0

    /// A position that differs from the dial's extrapolation by more than this is sent.
    private static let drift = 0.3
    /// While playing, the position is re-sent at least this often.
    private static let resync = 5.0

    /// Lines to send for this target (nil: tune).
    mutating func lines(for target: DialScrubTarget?, now: Double) -> [String] {
        guard let target else {
            guard file != nil else { return [] }
            file = nil
            return [DialProtocol.scrubOff]
        }
        guard file == target.file else {
            file = target.file
            length = target.length
            sentJump = target.jump
            sentPlaying = target.playing
            sentPosition = target.position
            sentTime = now
            return [DialProtocol.scrubOn(startSecondOfDay: target.startSecondOfDay, length: target.length,
                                         position: target.position, playing: target.playing, jump: target.jump,
                                         title: target.title)]
        }
        length = target.length
        var lines: [String] = []
        if target.jump != sentJump {
            sentJump = target.jump
            lines.append(DialProtocol.jump(target.jump))
        }
        if target.playing != sentPlaying {
            sentPlaying = target.playing
            lines.append(DialProtocol.playing(target.playing))
            lines.append(sendPosition(target.position, now: now))
        } else if abs(target.position - expected(at: now)) > Self.drift
                    || (target.playing && now - sentTime >= Self.resync) {
            lines.append(sendPosition(target.position, now: now))
        }
        return lines
    }

    /// The answer to the dial's `J <seq> …`, after the player has moved.
    mutating func answer(position: Double, seq: Int, now: Double) -> String {
        sentPosition = position
        sentTime = now
        return DialProtocol.position(position, seq: seq)
    }

    /// The dial took this jump size itself (`JUMP` from the dial): don't echo it back.
    mutating func dialChose(jump: Double) { sentJump = jump }

    /// After any `HELLO`: the dial has forgotten scrub mode.
    mutating func reset() { file = nil }

    private mutating func sendPosition(_ position: Double, now: Double) -> String {
        sentPosition = position
        sentTime = now
        return DialProtocol.position(position)
    }

    /// Where the dial believes the playhead is: the last sent position, advancing in real time while playing.
    private func expected(at now: Double) -> Double {
        sentPlaying ? min(sentPosition + max(now - sentTime, 0), length) : sentPosition
    }
}
