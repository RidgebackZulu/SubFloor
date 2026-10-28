import Foundation

/// A stream's recent past, as bytes. One producer always writes (the oldest bytes are overwritten);
/// one consumer *rewinds* to a position behind the head when a recording starts and reads forward
/// from there. Positions count bytes since `reset`, so they never wrap.
///
/// The mutex guards memcpy-only sections; the producer never blocks on I/O.
public final class HistoryRing: @unchecked Sendable {
    private struct State {
        var storage: UnsafeMutableRawPointer?
        var capacity = 0
        var bytesPerFrame = 1
        /// Bytes ever pushed: the position of the next byte.
        var head = 0
        /// Rewinds never go behind this (`clear`); reads of older bytes still succeed while they exist.
        var barrier = 0
        var oldest: Int { max(head - capacity, 0) }
    }

    private let lock = NSLock()
    private var state = State()   // guarded by `lock`

    public init() {}
    deinit { state.storage?.deallocate() }

    private func withState<R>(_ body: (inout State) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    /// Reallocates for `capacity` bytes (rounded down to whole frames) and forgets everything.
    public func reset(capacity: Int, bytesPerFrame: Int) {
        let frames = max(capacity / max(bytesPerFrame, 1), 1)
        let c = frames * max(bytesPerFrame, 1)
        withState { s in
            if c != s.capacity {
                s.storage?.deallocate()
                s.storage = .allocate(byteCount: c, alignment: 16)
                s.capacity = c
            }
            s.bytesPerFrame = max(bytesPerFrame, 1)
            s.head = 0
            s.barrier = 0
        }
    }

    /// Nothing before now is pre-roll any more (the bytes stay readable for a consumer already past them).
    public func clear() { withState { $0.barrier = $0.head } }

    public var capacity: Int { withState { $0.capacity } }
    public var bytesPerFrame: Int { withState { $0.bytesPerFrame } }
    public var head: Int { withState { $0.head } }
    /// Whole frames ever pushed since `reset`.
    public var headFrames: Int { withState { $0.head / $0.bytesPerFrame } }
    /// Bytes behind the head a rewind may reach.
    public var available: Int { withState { $0.head - max($0.oldest, $0.barrier) } }

    /// Producer. Keeps the last `capacity` bytes of what was pushed.
    public func push(_ bytes: UnsafeRawBufferPointer) {
        guard let src = bytes.baseAddress, bytes.count > 0 else { return }
        withState { s in
            guard let storage = s.storage, s.capacity > 0 else { return }
            var n = bytes.count, from = src
            if n > s.capacity {
                from += n - s.capacity
                n = s.capacity
            }
            let start = (s.head + (bytes.count - n)) % s.capacity
            let first = min(n, s.capacity - start)
            (storage + start).copyMemory(from: from, byteCount: first)
            if n > first { storage.copyMemory(from: from + first, byteCount: n - first) }
            s.head += bytes.count
        }
    }

    /// Producer: hands `body` the bytes from `from` to `to` that are still held, in place, in at most
    /// two pieces (the ring wraps), each with its position. Positions are whole frames when the
    /// arguments are, since the capacity is.
    public func rewrite(from: Int, to: Int, _ body: (UnsafeMutableRawBufferPointer, Int) -> Void) {
        withState { s in
            guard let storage = s.storage, s.capacity > 0 else { return }
            var position = max(from, s.oldest)
            let end = min(to, s.head)
            while position < end {
                let start = position % s.capacity
                let n = min(end - position, s.capacity - start)
                body(UnsafeMutableRawBufferPointer(start: storage + start, count: n), position)
                position += n
            }
        }
    }

    /// The position `bytes` behind the head, no further back than what is available.
    public func rewind(bytes: Int) -> Int {
        withState { s in s.head - min(max(bytes, 0), s.head - max(s.oldest, s.barrier)) }
    }

    /// `position` limited to what a rewind may reach: no older than `rewind` goes, no newer than the head.
    public func clamped(position: Int) -> Int {
        withState { s in min(max(position, max(s.oldest, s.barrier)), s.head) }
    }

    /// Consumer: copies from `position` toward the head (at most `out.count` bytes, whole frames) and
    /// advances `position`. If the producer has already overwritten `position`, it is moved to the
    /// oldest byte still held and `skipped` says how many were lost.
    @discardableResult
    public func read(from position: inout Int, into out: UnsafeMutableRawBufferPointer) -> (read: Int, skipped: Int) {
        guard let dst = out.baseAddress, out.count > 0 else { return (0, 0) }
        return withState { s in
            guard let storage = s.storage, s.capacity > 0 else { return (0, 0) }
            var skipped = 0
            if position < s.oldest {
                skipped = s.oldest - position
                position = s.oldest
            }
            let frames = min(out.count, s.head - position) / s.bytesPerFrame
            let n = frames * s.bytesPerFrame
            guard n > 0 else { return (0, skipped) }
            let start = position % s.capacity
            let first = min(n, s.capacity - start)
            dst.copyMemory(from: storage + start, byteCount: first)
            if n > first { (dst + first).copyMemory(from: storage, byteCount: n - first) }
            position += n
            return (n, skipped)
        }
    }
}
