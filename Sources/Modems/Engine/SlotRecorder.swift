import Foundation

/// One slot of box audio for a slot modem to decode, off the modem thread.
///
/// `@unchecked Sendable`: every field is an immutable value except `mode`, a metatype whose
/// conformance has only static, stateless requirements; it is safe to send across threads.
public struct SlotJob: @unchecked Sendable {
    public let mode: any SlotModem.Type
    /// Exactly `mode.slotSeconds × sampleRate` samples, the first at `slotStart`.
    public let samples: [Float]
    public let slotStart: Date
    public let sampleRate: Double

    public init(mode: any SlotModem.Type, samples: [Float], slotStart: Date, sampleRate: Double) {
        self.mode = mode
        self.samples = samples
        self.slotStart = slotStart
        self.sampleRate = sampleRate
    }

    /// Runs the mode's decoder on the slot (heavy: call it on a background queue).
    public func decode(audioBand: ClosedRange<Double>) -> [SlotDecode] {
        mode.decode(samples: samples, sampleRate: sampleRate, slotStart: slotStart, audioBand: audioBand)
    }
}

/// Keeps the last `retainSeconds` of box audio stamped with UTC wall-clock time and cuts it into the
/// UTC-aligned slots of the slot modes (FT8: 15 s from :00/:15/:30/:45; WSPR: 2 min from even
/// minutes; generally `floor(t / slotSeconds) · slotSeconds` since the Unix epoch).
///
/// **Time.** Each appended block carries the UTC time of its first sample. A block that starts
/// within 20 ms of where the previous one ended continues it (the stamps' jitter is followed: a
/// sample's time is that of its own block plus its offset in it); a larger jump either way, a
/// `markGap()`, or a `reset()` is a gap.
///
/// **Slots.** A slot is due once `now ≥ slotStart + slotSeconds + 0.5 s` and the audio up to its end
/// has arrived. Its job holds exactly `slotSeconds × sampleRate` samples, the first being the sample
/// at the slot boundary (to the nearest sample). A slot is skipped, never decoded partially, when any
/// sample of it is missing: a gap inside it, audio starting after its start (a slot straddling the
/// recorder's start or a reset), or audio already dropped from the buffer. Each slot of each mode
/// is returned at most once. A mode that was not requested by the previous `dueSlots` call starts
/// afresh with the slot in progress (at `now` − 0.5 s), so no backlog of old slots is ever returned.
///
/// Memory is a fixed ring of `retainSeconds × sampleRate` samples plus one small record per
/// discontinuity in the stamps. Not thread-safe: confine an instance to one thread (the modem thread).
public final class SlotRecorder {
    /// A slot is due this long after its end.
    public static let dueMarginSeconds = 0.5
    /// Timestamp discontinuities up to this are stamp jitter, not lost audio.
    public static let gapToleranceSeconds = 0.020
    /// A block stamped within this of where its run predicts extends the run (floating-point rounding
    /// of sample-accurate stamps); any larger deviation starts a new, continuous run.
    static let mergeToleranceSeconds = 1e-6

    public let sampleRate: Double
    public let retainSeconds: Double

    /// A run of samples whose stamps are continuous: sample `index + k` is at `time + k / sampleRate`.
    private struct Anchor {
        /// Absolute index of its first sample (counted from the recorder's creation).
        var index: Int
        var time: Double
        var count: Int
        /// Audio before this run is missing (or was never recorded).
        var gapBefore: Bool
    }

    private var ring: [Float]
    /// Absolute index one past the newest sample.
    private var endIndex = 0
    /// Oldest absolute index still retained.
    private var startIndex = 0
    private var anchors: [Anchor] = []
    private var gapPending = true
    /// Per mode, the start (Unix seconds) of the next slot to return.
    private var nextSlot: [ModeID: Double] = [:]

    public init(sampleRate: Double = 12_000, retainSeconds: Double = 150) {
        precondition(sampleRate > 0 && retainSeconds > 0)
        self.sampleRate = sampleRate
        self.retainSeconds = retainSeconds
        ring = .init(repeating: 0, count: Int((retainSeconds * sampleRate).rounded(.up)))
    }

    /// The start of the slot containing `time`.
    public static func slotStart(for time: Date, slotSeconds: Double) -> Date {
        Date(timeIntervalSince1970: slotStart(for: time.timeIntervalSince1970, slotSeconds: slotSeconds))
    }

    static func slotStart(for t: Double, slotSeconds: Double) -> Double {
        (t / slotSeconds).rounded(.down) * slotSeconds
    }

    // MARK: Recording

    /// Records `audio`, whose first sample was taken at `firstSampleTime` (UTC).
    public func append(_ audio: UnsafeBufferPointer<Float>, firstSampleTime: Date) {
        guard !audio.isEmpty else { return }
        let t = firstSampleTime.timeIntervalSince1970
        guard t.isFinite else {
            markGap()
            return
        }
        if !gapPending, var last = anchors.last {
            // The run's own prediction for this block, so merging never accumulates error.
            let expected = last.time + Double(last.count) / sampleRate
            if abs(t - expected) <= Self.mergeToleranceSeconds {
                last.count += audio.count
                anchors[anchors.count - 1] = last
            } else {
                let continuous = abs(t - expected) <= Self.gapToleranceSeconds
                anchors.append(Anchor(index: endIndex, time: t, count: audio.count, gapBefore: !continuous))
            }
        } else {
            anchors.append(Anchor(index: endIndex, time: t, count: audio.count, gapBefore: true))
        }
        gapPending = false

        var w = endIndex % ring.count
        for x in audio {
            ring[w] = x
            w += 1
            if w == ring.count { w = 0 }
        }
        endIndex += audio.count
        startIndex = max(startIndex, endIndex - ring.count)
        // Drop runs that ended before the retained audio (keeping at least the newest).
        let firstKept = anchors.firstIndex { $0.index + $0.count > startIndex } ?? anchors.count - 1
        if firstKept > 0 { anchors.removeFirst(firstKept) }
    }

    /// Audio is missing before the next appended block (the caller lost or could not time some).
    public func markGap() {
        gapPending = true
    }

    /// Forgets all audio (the box moved): no slot that started before the next appended block is
    /// ever returned.
    public func reset() {
        anchors.removeAll()
        startIndex = endIndex
        gapPending = true
        nextSlot.removeAll()
    }

    // MARK: Slots

    /// The slots of `modes` that are due at `now` and complete, in mode order then time order. Slots
    /// that turned out incomplete are skipped for good.
    public func dueSlots(modes: [any SlotModem.Type], now: Date) -> [SlotJob] {
        let now = now.timeIntervalSince1970
        var jobs: [SlotJob] = []
        var next: [ModeID: Double] = [:]
        for mode in modes where next[mode.id] == nil {
            let length = mode.slotSeconds
            guard length > 0 else { continue }
            var start = nextSlot[mode.id] ?? Self.slotStart(for: now - Self.dueMarginSeconds, slotSeconds: length)
            scan: while start + length + Self.dueMarginSeconds <= now {
                switch status(slotStart: start, length: length) {
                case .ready(let first):
                    jobs.append(SlotJob(mode: mode, samples: samples(from: first, count: slotSampleCount(length)),
                                        slotStart: Date(timeIntervalSince1970: start), sampleRate: sampleRate))
                case .missing:
                    break
                case .pending:
                    break scan
                }
                start += length
            }
            next[mode.id] = start
        }
        nextSlot = next
        return jobs
    }

    private enum SlotStatus {
        /// Complete; its first sample is at this absolute index.
        case ready(Int)
        /// Some of its audio is missing: skip it.
        case missing
        /// Its audio has not all arrived yet.
        case pending
    }

    private func slotSampleCount(_ length: Double) -> Int { Int((length * sampleRate).rounded()) }

    private func status(slotStart s: Double, length: Double) -> SlotStatus {
        let count = slotSampleCount(length)
        // The run holding the boundary: the last one that starts at or before it.
        guard let a = anchors.lastIndex(where: { $0.time <= s }) else {
            // Nothing recorded at or before the boundary: missing, unless nothing has come since either.
            return anchors.isEmpty ? .pending : .missing
        }
        let first = anchors[a].index + Int(((s - anchors[a].time) * sampleRate).rounded())
        if first >= endIndex { return a == anchors.count - 1 ? .pending : .missing }
        guard first >= startIndex else { return .missing }
        // Past its own run's end, the boundary must fall where the next run (continuous, within the
        // tolerance) puts it.
        if first >= anchors[a].index + anchors[a].count {
            guard let c = anchors.lastIndex(where: { $0.index <= first }) else { return .missing }
            let t = anchors[c].time + Double(first - anchors[c].index) / sampleRate
            if abs(t - s) > Self.gapToleranceSeconds { return .missing }
        }
        let end = first + count
        for r in anchors where r.gapBefore && r.index > first && r.index < end { return .missing }
        return end <= endIndex ? .ready(first) : .pending
    }

    private func samples(from first: Int, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        var k = 0
        var r = first % ring.count
        while k < count {
            let n = min(count - k, ring.count - r)
            for j in 0..<n { out[k + j] = ring[r + j] }
            k += n
            r = 0
        }
        return out
    }

    // MARK: Test access

    var retainedSampleCount: Int { endIndex - startIndex }
    var anchorCount: Int { anchors.count }
    var bufferCapacity: Int { ring.count }
}
