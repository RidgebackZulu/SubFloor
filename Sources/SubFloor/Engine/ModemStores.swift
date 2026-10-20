import Foundation
import Modems
import Synchronization

/// The modem engine's output for the main thread: a Mutex-guarded batch that the modem thread (text
/// and signal snapshots) and the slot queue (FT8/WSPR decodes) append to, and the main thread
/// drains at 10 Hz.
///
/// **Epochs.** Everything is tagged with the *epoch* it was produced in. `beginEpoch(at:)` starts a
/// new one (the box moved or was reset, the modem turned on, the engine started) and discards the
/// batch; from then on anything tagged with an older epoch is dropped on arrival. The epoch is begun
/// on the thread that asks for the reset, *before* the reset reaches the modem thread, so text,
/// snapshots and slot decodes that were still being produced for the old box (queued audio, a slot
/// job already running) can never reach the UI afterwards.
///
/// **What the main thread does** (Task 15) on each drain:
/// ```
/// let batch = engine.modemEvents.drain()
/// if let cutoff = batch.clearedAt { decodeLog.clear(at: cutoff) }
/// decodeLog.apply(signals: batch.signals, text: batch.text, slotDecodes: batch.slotDecodes, now: utcNow)
/// ```
/// `clearedAt` is set when an epoch began since the previous drain (several resets collapse into
/// one). It is the reset's UTC time less `cutoffMarginSeconds`, so `DecodeLog`'s own slot cutoff (no
/// decode of a slot that started before the clear) is a backstop that can never reject a slot of
/// the new box, whose first sample is stamped at most the pipeline latency before the reset; the
/// epoch is what actually keeps the old box's decodes out. Clear the log only from a batch, never
/// directly when asking for a reset, so the log and the queue always agree.
///
/// **Batching.** Text accumulates in arrival order; only the latest signal snapshot is kept (each
/// lists every signal, and `DecodeLog` buffers text for keys it has not seen yet). If nothing drains
/// for long, the oldest text entries beyond `maxPendingText` and slot decodes beyond
/// `maxPendingSlotDecodes` are dropped.
final class ModemEventQueue: Sendable {
    static let cutoffMarginSeconds = 1.0
    static let maxPendingText = 8_192
    static let maxPendingSlotDecodes = 1_024

    struct Batch: Sendable {
        /// The epoch the batch belongs to.
        var epoch: UInt64
        /// Set when the box was reset since the previous drain: pass it to `DecodeLog.clear(at:)`.
        var clearedAt: Date?
        /// The latest snapshot (nil: none since the previous drain).
        var signals: [SignalSnapshot]?
        var text: [DecodedText]
        var slotDecodes: [SlotDecode]

        var isEmpty: Bool { clearedAt == nil && signals == nil && text.isEmpty && slotDecodes.isEmpty }
    }

    private struct State {
        var epoch: UInt64 = 0
        var clearedAt: Date?
        var signals: [SignalSnapshot]?
        var text: [DecodedText] = []
        var slotDecodes: [SlotDecode] = []
    }

    private let state = Mutex(State())

    /// The current epoch.
    var epoch: UInt64 { state.withLock { $0.epoch } }

    /// Starts a new epoch at UTC `time`, discarding everything queued; returns it.
    @discardableResult
    func beginEpoch(at time: Date) -> UInt64 {
        state.withLock { s in
            s.epoch &+= 1
            s.clearedAt = time.addingTimeInterval(-Self.cutoffMarginSeconds)
            s.signals = nil
            s.text.removeAll()
            s.slotDecodes.removeAll()
            return s.epoch
        }
    }

    /// Modem thread: one engine output. Returns false (and drops it) when `epoch` is stale.
    @discardableResult
    func append(text: [DecodedText], signals: [SignalSnapshot]?, epoch: UInt64) -> Bool {
        state.withLock { s in
            guard epoch == s.epoch else { return false }
            if let signals { s.signals = signals }
            for t in text where !t.text.isEmpty { s.text.append(t) }
            if s.text.count > Self.maxPendingText { s.text.removeFirst(s.text.count - Self.maxPendingText) }
            return true
        }
    }

    /// Slot queue: one slot's decodes. Returns false (and drops them) when `epoch` is stale.
    @discardableResult
    func append(slotDecodes: [SlotDecode], epoch: UInt64) -> Bool {
        state.withLock { s in
            guard epoch == s.epoch else { return false }
            s.slotDecodes.append(contentsOf: slotDecodes)
            if s.slotDecodes.count > Self.maxPendingSlotDecodes {
                s.slotDecodes.removeFirst(s.slotDecodes.count - Self.maxPendingSlotDecodes)
            }
            return true
        }
    }

    /// Returns everything queued since the previous drain and empties the queue.
    func drain() -> Batch {
        state.withLock { s in
            let batch = Batch(epoch: s.epoch, clearedAt: s.clearedAt, signals: s.signals, text: s.text,
                              slotDecodes: s.slotDecodes)
            s.clearedAt = nil
            s.signals = nil
            s.text = []
            s.slotDecodes = []
            return batch
        }
    }
}

/// The latest cursor bench frame, published by the modem thread at up to 30 Hz and read by the
/// bench view (the `SpectrumFrameStore` pattern; frames are values, so publishing hands over the
/// engine's arrays without copying).
///
/// Frames carry the epoch they were produced in: `discard(before:)` (called with each new epoch)
/// drops the stored frame and ignores later frames from older epochs, so the bench never shows the
/// old box's signal after a reset.
final class CursorFrameStore: Sendable {
    private struct State {
        var sequence: UInt64 = 0
        var frame: CursorFrame?
        var minimumEpoch: UInt64 = 0
    }

    private let state = Mutex(State())

    /// Stores `frame` unless `epoch` is older than the last `discard(before:)`.
    func publish(_ frame: CursorFrame, epoch: UInt64) {
        state.withLock { s in
            guard epoch >= s.minimumEpoch else { return }
            s.frame = frame
            s.sequence &+= 1
        }
    }

    /// The latest frame if it is newer than `sequence`, with its sequence number.
    func read(after sequence: UInt64) -> (UInt64, CursorFrame)? {
        state.withLock { s in
            guard s.sequence != sequence, let f = s.frame else { return nil }
            return (s.sequence, f)
        }
    }

    /// Whether a frame is stored (false after `discard(before:)` until the next one).
    var hasFrame: Bool { state.withLock { $0.frame != nil } }

    /// Drops the stored frame and every later frame from an epoch before `epoch`.
    func discard(before epoch: UInt64) {
        state.withLock { s in
            s.minimumEpoch = max(s.minimumEpoch, epoch)
            s.frame = nil
        }
    }
}
