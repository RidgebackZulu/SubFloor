import DSPCore
import Synchronization

/// The last `seconds` of the receiver's audio before the squelch gate, and how long the gate was open, for an
/// agent's `listen`. The DSP thread pushes every block (`push`); a reader takes a `mark()` and later asks for
/// what came after it. The ring is allocated once, so a push never allocates; it copies under a lock that a
/// reader holds only while it copies out.
///
/// The counts only grow, across `clear()` too: a mark taken before a clear sees only what came after the clear.
final class AudioTap: @unchecked Sendable {
    /// A point in the stream: the samples pushed before it, and how many of them came with the gate open.
    struct Mark: Equatable, Sendable {
        let total: Int
        let open: Int
    }

    let rate: Double
    /// The most a reader gets back, in samples.
    let capacity: Int
    /// Written only under `state`'s lock. Never read beyond what has been written since it was allocated.
    private let ring: UnsafeMutablePointer<Float>

    private struct State {
        var total = 0
        var open = 0
        /// The last `clear()`: nothing before it is returned.
        var cleared = Mark(total: 0, open: 0)
    }
    private let state = Mutex(State())

    init(seconds: Double = 60, rate: Double = Receiver.audioRate) {
        self.rate = rate
        capacity = max(1, Int((seconds * rate).rounded()))
        ring = .allocate(capacity: capacity)
    }

    deinit { ring.deallocate() }

    /// DSP thread: one block of audio, and whether the gate was open for it.
    func push(_ audio: UnsafeBufferPointer<Float>, gateOpen: Bool) {
        guard let src = audio.baseAddress, audio.count > 0 else { return }
        state.withLock { s in
            // A block longer than the ring keeps only its end.
            let skip = max(0, audio.count - capacity)
            var at = (s.total + skip) % capacity, from = skip
            while from < audio.count {
                let n = min(audio.count - from, capacity - at)
                (ring + at).update(from: src + from, count: n)
                from += n
                at = (at + n) % capacity
            }
            s.total += audio.count
            if gateOpen { s.open += audio.count }
        }
    }

    func mark() -> Mark { state.withLock { Mark(total: $0.total, open: $0.open) } }

    /// The samples pushed since `mark` (and since the last clear), at most the last `capacity` of them.
    func samples(since mark: Mark) -> [Float] {
        state.withLock { s in
            let first = max(mark.total, s.cleared.total, s.total - capacity)
            let count = s.total - first
            guard count > 0 else { return [] }
            return [Float](unsafeUninitializedCapacity: count) { out, initialized in
                var at = first % capacity, done = 0
                while done < count {
                    let n = min(count - done, capacity - at)
                    (out.baseAddress! + done).initialize(from: ring + at, count: n)
                    done += n
                    at = (at + n) % capacity
                }
                initialized = count
            }
        }
    }

    /// Seconds of audio pushed with the gate open since `mark` (and since the last clear).
    func openSeconds(since mark: Mark) -> Double {
        state.withLock { s in
            let base = mark.total >= s.cleared.total ? mark.open : s.cleared.open
            return Double(max(0, s.open - base)) / rate
        }
    }

    /// Forgets what has been pushed (a new run of the engine).
    func clear() {
        state.withLock { $0.cleared = Mark(total: $0.total, open: $0.open) }
    }
}
