import Foundation

/// How long the squelch must stay open to start a recording, and how long it must stay shut to end one.
public struct AutoRecordTiming: Equatable, Sendable, Codable {
    /// Seconds of open squelch (within bridged gaps) before a recording starts.
    public var startAfter = 2.0
    /// Seconds the squelch must stay shut before the recording ends.
    public var stopAfter = 30.0

    /// A gap this short or shorter does not break a run: speech has syllable gaps.
    public static let bridge = 1.5
    /// Audio kept from before the run began, so the first word is not clipped.
    public static let lead = 0.5
    /// Audio kept after the last open frame, so the last word is not clipped.
    public static let tail = 2.0
    public static let startAfterRange = 0.5...10.0
    public static let stopAfterChoices: [Double] = [5, 10, 15, 30, 45, 60, 90, 120, 180, 300, 600]
    /// The most the audio ring must hold behind the head for any timing: the longest Stop after, the
    /// longest Start after, the bridge and the lead.
    public static let maxHoldbackSeconds = 600 + 10 + bridge + lead   // 612

    public init(startAfter: Double = 2.0, stopAfter: Double = 30.0) {
        self.startAfter = startAfter
        self.stopAfter = stopAfter
    }

    /// Clamps Start after into its range and snaps Stop after to the nearest choice (the lower on a tie).
    public func normalized() -> AutoRecordTiming {
        let start = min(max(startAfter, Self.startAfterRange.lowerBound), Self.startAfterRange.upperBound)
        let stop = Self.stopAfterChoices.min { abs($0 - stopAfter) < abs($1 - stopAfter) } ?? 30
        return AutoRecordTiming(startAfter: start, stopAfter: stop)
    }
}

/// Turns the squelch gate's open/shut history into recordings and ignored pops. Pure: it sees only
/// the recorder's frame count and whether the gate was open over each block, so the DSP thread can
/// drive it and tests can replay it. Frames are the audio recorder's, counted from its start.
public struct AutoRecordTrigger: Sendable {
    public enum Event: Equatable, Sendable {
        /// The file's first frame.
        case start(atFrame: Int)
        /// The writer may write frames before this one.
        case commit(throughFrame: Int)
        /// The file ends before this frame.
        case stop(atFrame: Int)
        /// A run of gate activity that never reached Start after: its first open frame and the span from
        /// there to its last open frame (bridged gaps included), which the timeline shows as a length of time.
        case pop(atFrame: Int, frames: Int)
    }

    private enum Phase: Sendable { case idle, run, recording }

    /// Settable at any time; takes effect from the next block.
    public var timing: AutoRecordTiming
    public private(set) var isRecording = false

    private let sampleRate: Double
    private var phase = Phase.idle
    /// The head after the previous call; nil until the baseline call.
    private var lastHead: Int?
    private var runStart = 0
    /// Open frames in the current run, summed across bridged gaps.
    private var openFrames = 0
    /// The end of the most recent open block.
    private var lastOpenEnd = 0
    private var committed = 0

    public init(sampleRate: Double, timing: AutoRecordTiming) {
        self.sampleRate = sampleRate
        self.timing = timing
    }

    private func frames(_ seconds: Double) -> Int { Int((seconds * sampleRate).rounded()) }

    /// `head` is the recorder's frame count after this block; `gateOpen` applies to the frames since the
    /// last call. Appends to the caller's array so a reused one makes this allocation-free.
    public mutating func advance(to head: Int, gateOpen: Bool, into events: inout [Event]) {
        guard let previous = lastHead else { lastHead = head; return }   // frames before Auto was on don't count
        guard head >= previous else {                                    // the ring was rebuilt
            reset()
            lastHead = head
            return
        }
        lastHead = head
        guard head > previous else { return }

        if gateOpen {
            if phase == .idle {
                phase = .run
                runStart = previous
                openFrames = 0
            }
            lastOpenEnd = head
            if phase == .run { openFrames += head - previous }
        }

        switch phase {
        case .idle:
            break
        case .run:
            if openFrames >= frames(timing.startAfter) {
                phase = .recording
                isRecording = true
                events.append(.start(atFrame: max(0, runStart - frames(AutoRecordTiming.lead))))
                committed = head
                events.append(.commit(throughFrame: head))
            } else if !gateOpen && head - lastOpenEnd > frames(AutoRecordTiming.bridge) {
                events.append(.pop(atFrame: runStart, frames: lastOpenEnd - runStart))
                phase = .idle
            }
        case .recording:
            let through = min(head, lastOpenEnd + frames(AutoRecordTiming.tail))
            if through > committed {
                committed = through
                events.append(.commit(throughFrame: through))
            }
            if head - lastOpenEnd >= frames(timing.stopAfter) {
                events.append(.stop(atFrame: through))
                reset()
            }
        }
    }

    /// Retune, squelch off, Auto off: ends a recording at min(head, last open + tail); discards an
    /// undecided run without logging it as a pop, since it was cut rather than judged.
    public mutating func cut(into events: inout [Event]) {
        if phase == .recording, let head = lastHead {
            events.append(.stop(atFrame: min(head, lastOpenEnd + frames(AutoRecordTiming.tail))))
        }
        reset()
    }

    private mutating func reset() {
        phase = .idle
        isRecording = false
        openFrames = 0
        committed = 0
    }
}
