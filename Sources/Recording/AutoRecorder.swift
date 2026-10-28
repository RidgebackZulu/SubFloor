import Foundation
import Synchronization

/// A run of squelch activity that never lasted long enough to be recorded.
public struct IgnoredPop: Equatable, Sendable {
    /// When the pop began.
    public var at: Date
    /// From its first open moment to its last.
    public var seconds: Double

    public init(at: Date, seconds: Double) {
        self.at = at
        self.seconds = seconds
    }
}

/// Drives an audio `StreamRecorder` from the squelch gate: the DSP thread hands it each block of
/// demodulated audio and whether the gate was open over it, and it starts, extends and ends an auto
/// session through `AutoRecordTrigger`. Runs of gate activity too short to record are queued as pops.
///
/// `configure`, `cut`, `reset` and `drainPops` may be called from any thread. Everything else is the
/// DSP thread's.
public final class AutoRecorder: @unchecked Sendable {
    public struct Config: Equatable, Sendable {
        public var enabled: Bool
        public var timing: AutoRecordTiming

        public init(enabled: Bool = false, timing: AutoRecordTiming = AutoRecordTiming()) {
            self.enabled = enabled
            self.timing = timing
        }
    }

    /// The most pops kept between drains; the oldest go first.
    static let popCapacity = 10_000

    public let recorder: StreamRecorder

    /// What other threads have asked for, picked up by the next `process`.
    private struct Pending {
        var config: Config?
        var cut = false
        var reset = false
    }

    private let configBox = Mutex(Config())
    private let pending = Mutex(Pending())
    private let hasPending = Atomic<Bool>(false)
    private let pops = Mutex<[IgnoredPop]>([])
    private let cutRequests = Atomic<Int>(0)

    // DSP thread only.
    private var applied = Config()
    private var trigger: AutoRecordTrigger?
    private var triggerRate = 0.0
    /// The head when the last cut was applied: an auto recording never starts before it, so its lead
    /// never reaches back into audio from before a retune.
    private var startFloor = 0
    /// Reused every block so the steady state allocates nothing.
    private var events: [AutoRecordTrigger.Event] = []

    public init(recorder: StreamRecorder) {
        self.recorder = recorder
        events.reserveCapacity(8)
        // Room for every pop the queue may hold, so the DSP thread's append never allocates.
        pops.withLock { $0.reserveCapacity(Self.popCapacity + 1) }
    }

    // MARK: Any thread

    /// The last value given to `configure`.
    public var config: Config { configBox.withLock { $0 } }

    /// Takes effect from the next block.
    public func configure(_ config: Config) {
        configBox.withLock { $0 = config }
        pending.withLock { $0.config = config }
        hasPending.store(true, ordering: .releasing)
    }

    /// The radio was retuned or changed mode: ends a recording in progress and drops an undecided run.
    /// Counted when requested, whether or not the DSP thread is running to apply it.
    public func cut() {
        _ = cutRequests.add(1, ordering: .relaxed)
        pending.withLock { $0.cut = true }
        hasPending.store(true, ordering: .releasing)
    }

    /// A new run of the radio: the next block is a fresh baseline, and a recording in progress ends.
    public func reset() {
        pending.withLock { $0.reset = true }
        hasPending.store(true, ordering: .releasing)
    }

    /// The pops logged since the last call, oldest first. They are copied out into an array of the
    /// caller's, so the queue keeps its storage and the DSP thread's next pop allocates nothing.
    public func drainPops() -> [IgnoredPop] {
        pops.withLock { queue in
            guard !queue.isEmpty else { return [] }
            var drained: [IgnoredPop] = []
            drained.reserveCapacity(queue.count)
            drained.append(contentsOf: queue)
            queue.removeAll(keepingCapacity: true)
            return drained
        }
    }

    /// Test hook: the pop queue's capacity.
    var popQueueCapacity: Int { pops.withLock { $0.capacity } }

    /// Test hook: how many times `cut()` has been called.
    public var cuts: Int { cutRequests.load(ordering: .relaxed) }

    // MARK: DSP thread

    /// One block of mono audio and whether the squelch gate was open over it. The audio always goes to
    /// the recorder's history first, so the trigger sees the head after it.
    public func process(_ audio: UnsafeBufferPointer<Float>, gateOpen: Bool) {
        recorder.push(audio)
        applyPending()

        guard applied.enabled else {
            cutTrigger()
            trigger = nil     // when Auto comes back on, the first block is a fresh baseline
            return
        }
        guard recorder.sessionKind != .manual else {
            trigger = nil     // a manual recording owns the recorder; the trigger starts over after it
            return
        }
        guard let rate = recorder.setup?.sampleRate, rate > 0 else {
            trigger = nil
            return
        }
        if trigger == nil || triggerRate != rate {
            trigger = AutoRecordTrigger(sampleRate: rate, timing: applied.timing.normalized())
            triggerRate = rate
        } else if trigger?.isRecording == true, recorder.sessionKind == .none {
            // The session ended behind the trigger's back (stopped by hand, or the writer failed).
            trigger = AutoRecordTrigger(sampleRate: rate, timing: applied.timing.normalized())
        }

        events.removeAll(keepingCapacity: true)
        let head = recorder.headFrame
        if startFloor > head { startFloor = 0 }   // the ring was rebuilt; its frames count from 0 again
        trigger?.advance(to: head, gateOpen: gateOpen, into: &events)
        apply(events, head: head, rate: rate)
    }

    private func applyPending() {
        guard hasPending.exchange(false, ordering: .acquiringAndReleasing) else { return }
        let request = pending.withLock { p in
            let copy = p
            p = Pending()
            return copy
        }
        if let config = request.config {
            applied = config
            trigger?.timing = config.timing.normalized()
        }
        if request.cut { startFloor = recorder.headFrame }
        if request.cut || request.reset {
            cutTrigger()
            if request.reset { trigger = nil }
        }
    }

    /// Ends the recording in progress, if any, and drops an undecided run.
    private func cutTrigger() {
        guard trigger != nil else { return }
        events.removeAll(keepingCapacity: true)
        trigger?.cut(into: &events)
        apply(events, head: recorder.headFrame, rate: triggerRate)
    }

    private func apply(_ events: [AutoRecordTrigger.Event], head: Int, rate: Double) {
        for event in events {
            switch event {
            case .start(let frame):
                recorder.start(fromFrame: max(frame, startFloor))
            case .commit(let frame):
                recorder.commit(throughFrame: frame)
            case .stop(let frame):
                recorder.stop(atFrame: frame)
            case .pop(let frame, let frames):
                let at = recorder.now().addingTimeInterval(-Double(head - frame) / rate)
                log(IgnoredPop(at: at, seconds: Double(frames) / rate))
            }
        }
    }

    private func log(_ pop: IgnoredPop) {
        pops.withLock { queue in
            queue.append(pop)
            if queue.count > Self.popCapacity { queue.removeFirst(queue.count - Self.popCapacity) }
        }
    }
}
