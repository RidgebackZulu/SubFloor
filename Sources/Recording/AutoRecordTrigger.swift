import Foundation

/// How long the squelch must stay open to start a recording, and how long it must stay shut to end one.
public struct AutoRecordTiming: Equatable, Sendable, Codable {
    /// Seconds of open squelch (within bridged gaps) before a recording starts.
    public var startAfter = 2.0
    /// Seconds the squelch must stay shut before the recording ends.
    public var stopAfter = 30.0
    /// Inside a recording, a squelch gap up to this long keeps its real audio, so the pauses between
    /// words sound as they did on air. A longer gap keeps `tail` after the last word and `lead` before
    /// the next, and is silent in between.
    public var keepGapsUpTo = 8.0

    /// A gap this short or shorter does not break a run: speech has syllable gaps.
    public static let bridge = 1.5
    /// Audio kept from before the run began, so the first word is not clipped.
    public static let lead = 0.5
    /// Audio kept after the last open frame, so the last word is not clipped.
    public static let tail = 2.0
    public static let startAfterRange = 0.5...10.0
    public static let stopAfterChoices: [Double] = [5, 10, 15, 30, 45, 60, 90, 120, 180, 300, 600]
    public static let keepGapsUpToChoices: [Double] = [1, 2, 3, 5, 8, 10, 15, 20, 30]
    /// The most the audio ring must hold behind the head for any timing: the longest Stop after, the
    /// longest Start after, the bridge and the lead.
    public static let maxHoldbackSeconds = 600 + 10 + bridge + lead   // 612

    public init(startAfter: Double = 2.0, stopAfter: Double = 30.0, keepGapsUpTo: Double = 8.0) {
        self.startAfter = startAfter
        self.stopAfter = stopAfter
        self.keepGapsUpTo = keepGapsUpTo
    }

    private enum CodingKeys: String, CodingKey { case startAfter, stopAfter, keepGapsUpTo }

    /// Every key is optional and a missing one keeps its default, so a timing saved by another
    /// SubFloor (with a field added or gone) still decodes instead of losing the whole session.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AutoRecordTiming()
        self = AutoRecordTiming(startAfter: try c.decodeIfPresent(Double.self, forKey: .startAfter) ?? d.startAfter,
                                stopAfter: try c.decodeIfPresent(Double.self, forKey: .stopAfter) ?? d.stopAfter,
                                keepGapsUpTo: try c.decodeIfPresent(Double.self, forKey: .keepGapsUpTo) ?? d.keepGapsUpTo).normalized()
    }

    /// Clamps Start after into its range and snaps Stop after and Keep gaps up to to their nearest
    /// choices (the lower on a tie).
    public func normalized() -> AutoRecordTiming {
        let start = min(max(startAfter, Self.startAfterRange.lowerBound), Self.startAfterRange.upperBound)
        let stop = Self.stopAfterChoices.min { abs($0 - stopAfter) < abs($1 - stopAfter) } ?? 30
        let keep = Self.keepGapsUpToChoices.min { abs($0 - keepGapsUpTo) < abs($1 - keepGapsUpTo) } ?? 8
        return AutoRecordTiming(startAfter: start, stopAfter: stop, keepGapsUpTo: keep)
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
        /// Part of a squelch gap longer than Keep gaps up to: these frames, not yet committed, are written
        /// silent. A long gap is silenced as it goes, block by block, so the pieces follow on from each
        /// other: the first fades out at its start, and the last, sent when the squelch reopens, fades the
        /// audio back in just after its end.
        case silence(fromFrame: Int, toFrame: Int, fadeOut: Bool, fadeIn: Bool)
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
    /// Inside a long gap: silenced up to here so far. nil when no gap is being silenced.
    private var silencedThrough: Int?

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
            if gateOpen {
                if let done = silencedThrough {
                    // Reopened after a long gap: the rest of it up to the lead, then fade the audio back in.
                    events.append(.silence(fromFrame: done, toFrame: max(done, previous - frames(AutoRecordTiming.lead)),
                                           fadeOut: false, fadeIn: true))
                    silencedThrough = nil
                }
            } else if head - lastOpenEnd > frames(timing.keepGapsUpTo) {
                // A long gap: silence it as it goes, keeping the tail after the last word and, at the head, a
                // lead's worth for the next one (any frame further back is at least that far before a reopen).
                // Only up to the tail is committed during a gap, so these frames are still ours.
                let from = silencedThrough ?? lastOpenEnd + frames(AutoRecordTiming.tail)
                let to = head - frames(AutoRecordTiming.lead)
                if to > from {
                    events.append(.silence(fromFrame: from, toFrame: to, fadeOut: silencedThrough == nil, fadeIn: false))
                    silencedThrough = to
                }
            }
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
        silencedThrough = nil
        phase = .idle
        isRecording = false
        openFrames = 0
        committed = 0
    }
}
