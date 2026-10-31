import Foundation
import Synchronization

/// What the recorder is capturing, for file names and SigMF metadata. For IQ, `frequencyHz` is the
/// capture centre and a change rolls the file (see `StreamRecorder.rollsOnContextChange`).
public struct RecordingContext: Equatable, Sendable {
    public var frequencyHz: Double
    /// "IQ", or the demodulation mode for audio.
    public var label: String
    public var hardware: String

    public init(frequencyHz: Double, label: String, hardware: String) {
        self.frequencyHz = frequencyHz
        self.label = label
        self.hardware = hardware
    }
}

public struct RecordingStatus: Equatable, Sendable {
    public var isRecording = false
    /// Started by the squelch (an auto session) rather than by hand; a manual start takes it over.
    public var isAuto = false
    /// The time of the first sample in the recording (the click minus the pre-roll).
    public var startedAt: Date?
    /// Across every file of this recording.
    public var framesWritten = 0
    public var bytesWritten = 0
    public var duration = 0.0
    /// The file being written (or the last one).
    public var url: URL?
    public var filesWritten = 0
    /// 0…1: how much of the pre-roll is primed.
    public var preRollFill = 0.0
    /// Bytes the writer could not keep up with (overwritten before they were written).
    public var overrunBytes = 0
    /// Why the last recording stopped on its own; cleared by the next start.
    public var error: String?

    public init() {}
}

/// The newest IQ the recorder's pre-roll ring holds, as floats, for analysis off the DSP thread.
public struct IQSnapshot: Sendable {
    /// Interleaved I, Q, in [-1, 1].
    public var samples: [Float]
    public var sampleRate: Double
    public var frames: Int { samples.count / 2 }
    /// When the last frame was heard.
    public var endTime: Date

    public init(samples: [Float], sampleRate: Double, endTime: Date) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.endTime = endTime
    }
}

public enum RecordingNames {
    /// `SubFloor_20261022_143000Z_14074000Hz_USB` — SDR#'s shape, so other software (and SubFloor's
    /// own IQ file source) read the frequency out of the name.
    public static func base(firstSample: Date, frequencyHz: Double, label: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd_HHmmss'Z'"
        return "SubFloor_\(f.string(from: firstSample))_\(Int(frequencyHz.rounded()))Hz_\(label)"
    }

    /// `base` with `_2`, `_3`… appended while a file of that name and extension exists.
    public static func unique(_ base: URL, extension ext: String) -> URL {
        var candidate = base, n = 1
        while FileManager.default.fileExists(atPath: candidate.appendingPathExtension(ext).path) {
            n += 1
            candidate = base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + "_\(n)")
        }
        return candidate
    }
}

/// Records one stream (IQ or audio) with a rolling pre-roll.
///
/// The DSP thread calls `push` with every block, always: samples are converted to the file's sample
/// format and kept in a `HistoryRing` sized for the pre-roll plus a write margin. `start` rewinds
/// into that history, so the file begins up to `preRollSeconds` before the click. A writer thread
/// drains the ring to the file in 1 MiB chunks, rolls WAV files near 4 GiB, and publishes `status`.
public final class StreamRecorder: @unchecked Sendable {
    public struct Setup: Equatable, Sendable {
        public var sampleRate: Double
        public var channels: Int
        public var fileFormat: FileFormat
        public var sampleFormat: SampleFormat
        public var preRollSeconds: Double
        /// Extra history the ring keeps beyond the pre-roll, so an auto session can hold its tail back
        /// (see `commit`) without the start of the file being overwritten.
        public var holdbackSeconds: Double
        /// The pre-roll the ring is planned for, when that differs from `preRollSeconds`: planned for the
        /// longest pre-roll, a change of `preRollSeconds` only changes how far a manual start rewinds and
        /// never rebuilds the ring (which would end a recording). nil: plan for `preRollSeconds`.
        public var ringPreRollSeconds: Double?
        public var memoryLimitBytes: Int
        public var folder: URL

        public init(sampleRate: Double, channels: Int, fileFormat: FileFormat, sampleFormat: SampleFormat,
                    preRollSeconds: Double, holdbackSeconds: Double = 0, ringPreRollSeconds: Double? = nil,
                    memoryLimitBytes: Int, folder: URL) {
            self.sampleRate = sampleRate
            self.channels = channels
            self.fileFormat = fileFormat
            self.sampleFormat = sampleFormat
            self.preRollSeconds = preRollSeconds
            self.holdbackSeconds = holdbackSeconds
            self.ringPreRollSeconds = ringPreRollSeconds
            self.memoryLimitBytes = memoryLimitBytes
            self.folder = folder
        }

        public var layout: StreamLayout { StreamLayout(sampleRate: sampleRate, channels: channels, sampleFormat: sampleFormat) }
    }

    /// How big the ring is and how much pre-roll it really gives.
    public struct RingPlan: Equatable, Sendable {
        public var capacityBytes: Int
        public var preRollBytes: Int
        public var effectivePreRollSeconds: Double
        public var marginSeconds: Double
    }

    /// The ring holds the pre-roll plus the holdback plus a margin (2 s or 10 % of the pre-roll) for
    /// the writer to lag behind. When the memory limit binds, the margin and the holdback are kept and
    /// the pre-roll shrinks.
    public static func plan(sampleRate: Double, bytesPerFrame: Int, preRollSeconds: Double, holdbackSeconds: Double = 0,
                            memoryLimitBytes: Int) -> RingPlan {
        let margin = max(2.0, preRollSeconds * 0.1)
        let holdback = max(0, holdbackSeconds)
        let wanted = Int(((preRollSeconds + holdback + margin) * sampleRate).rounded(.up))
        let frames = max(min(wanted, memoryLimitBytes / max(bytesPerFrame, 1)), 1)
        let effective = max(0, Double(frames) / sampleRate - margin - holdback)
        let preRollFrames = Int((effective * sampleRate).rounded(.down))
        return RingPlan(capacityBytes: frames * bytesPerFrame, preRollBytes: preRollFrames * bytesPerFrame,
                        effectivePreRollSeconds: effective, marginSeconds: margin)
    }

    public let kind: StreamKind
    /// IQ: a new capture centre means a new file and no pre-roll from before it.
    public let rollsOnContextChange: Bool
    /// Tests: roll WAV files at this many sample bytes instead of the format's limit.
    public var dataLimitOverride: Int? {
        get { producer.withLock { $0.dataLimitOverride } }
        set { producer.withLock { $0.dataLimitOverride = newValue } }
    }
    /// Tests: the clock the first-sample time is taken from.
    public var now: @Sendable () -> Date {
        get { producer.withLock { $0.now } }
        set { producer.withLock { $0.now = newValue } }
    }
    static let chunkBytes = 1 << 20
    static let checkpointInterval = 2.0

    private struct Producer {
        var setup: Setup?
        var plan: RingPlan?
        var converter: SampleConverter?
        var scratch: UnsafeMutableRawBufferPointer?
        var dataLimitOverride: Int?
        var now: @Sendable () -> Date = { Date() }
    }

    /// What kind of recording is open (or being opened). Read cheaply from any thread.
    public enum SessionKind: Int, Sendable { case none, auto, manual }

    private enum Command { case start, startAuto(byte: Int), stop, stopAuto(byte: Int), roll, quit }
    private enum Cut { case stop, roll }

    /// The writer thread's open recording.
    private final class Session {
        var file: any RecordingFile
        var layout: StreamLayout
        var fileFormat: FileFormat
        var folder: URL
        var context: RecordingContext
        /// Next ring byte to write.
        var position: Int
        /// First sample of the current file.
        var firstSample: Date
        var fileFrames = 0
        var lastCheckpoint: Date
        var dataLimit: Int?
        var cutAt: Int?
        var cut: Cut?
        /// An auto session writes only below the commit; a manual one writes up to the head.
        var isAuto: Bool
        /// The cut was set by `stop(atFrame:)`, so a manual takeover cancels it.
        var cutByFrame = false

        init(file: any RecordingFile, layout: StreamLayout, fileFormat: FileFormat, folder: URL, context: RecordingContext,
             position: Int, firstSample: Date, dataLimit: Int?, isAuto: Bool) {
            self.isAuto = isAuto
            self.file = file
            self.layout = layout
            self.fileFormat = fileFormat
            self.folder = folder
            self.context = context
            self.position = position
            self.firstSample = firstSample
            lastCheckpoint = firstSample
            self.dataLimit = dataLimit.map { ($0 / layout.bytesPerFrame) * layout.bytesPerFrame }
        }
    }

    private let ring = HistoryRing()
    private let producerLock = NSLock()
    private var producerState = Producer()   // guarded by `producerLock`
    private struct ProducerLock {
        unowned let owner: StreamRecorder
        func withLock<R>(_ body: (inout Producer) -> R) -> R {
            owner.producerLock.lock()
            defer { owner.producerLock.unlock() }
            return body(&owner.producerState)
        }
    }
    private var producer: ProducerLock { ProducerLock(owner: self) }
    private let context = Mutex<RecordingContext?>(nil)
    private let statusLock = Mutex(RecordingStatus())
    private let commands = Mutex<[Command]>([])
    private let wake = DispatchSemaphore(value: 0)
    private let recording = Atomic<Bool>(false)
    private let exited = DispatchSemaphore(value: 0)
    private let quitting = Atomic<Bool>(false)
    private let kindBox = Atomic<Int>(SessionKind.none.rawValue)
    /// Frames an auto session may write up to (exclusive); only grows within a session.
    private let committedFrames = Atomic<Int>(0)

    public init(kind: StreamKind, rollsOnContextChange: Bool) {
        self.kind = kind
        self.rollsOnContextChange = rollsOnContextChange
        let thread = Thread { [self] in run() }
        thread.name = "SubFloor \(kind.label) recorder"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    deinit { producerState.scratch?.deallocate() }

    // MARK: Caller side (main thread)

    /// Sets the stream and the file preferences. A change to the rate, channels, sample format,
    /// planned pre-roll or memory limit rebuilds the ring (the pre-roll starts over) and ends a recording
    /// in progress; a change of folder or container takes effect at the next start. With
    /// `ringPreRollSeconds` set, a change of `preRollSeconds` alone never rebuilds the ring.
    public func configure(_ setup: Setup) {
        let bpf = setup.layout.bytesPerFrame
        let plan = Self.plan(sampleRate: setup.sampleRate, bytesPerFrame: bpf,
                             preRollSeconds: setup.ringPreRollSeconds ?? setup.preRollSeconds,
                             holdbackSeconds: setup.holdbackSeconds, memoryLimitBytes: setup.memoryLimitBytes)
        producer.withLock { p in
            let old = p.setup
            let ringChanged = old == nil || old!.sampleRate != setup.sampleRate || old!.channels != setup.channels
                || old!.sampleFormat != setup.sampleFormat || plan != p.plan
            p.setup = setup
            guard ringChanged else { return }
            if recording.load(ordering: .relaxed) { enqueue(.stop) }
            ring.reset(capacity: plan.capacityBytes, bytesPerFrame: bpf)
            p.converter = SampleConverter(format: setup.sampleFormat)
            p.plan = plan
        }
    }

    public var setup: Setup? { producer.withLock { $0.setup } }
    /// The ring's plan. Its pre-roll is the planned one (`ringPreRollSeconds`, if set), not
    /// necessarily what a manual start rewinds: that is `effectivePreRollSeconds`.
    public var ringPlan: RingPlan? { producer.withLock { $0.plan } }
    public var effectivePreRollSeconds: Double { producer.withLock { p in p.setup.flatMap { setup in p.plan.map { Self.preRoll(setup, $0).seconds } } } ?? 0 }

    /// What a manual start rewinds: the plan's pre-roll, or `preRollSeconds` when the ring was planned
    /// for more (`ringPreRollSeconds`).
    private static func preRoll(_ setup: Setup, _ plan: RingPlan) -> (bytes: Int, seconds: Double) {
        guard setup.ringPreRollSeconds != nil else { return (plan.preRollBytes, plan.effectivePreRollSeconds) }
        let seconds = min(plan.effectivePreRollSeconds, max(0, setup.preRollSeconds))
        let bytes = min(plan.preRollBytes, Int((seconds * setup.sampleRate).rounded(.down)) * setup.layout.bytesPerFrame)
        return (bytes, seconds)
    }

    /// Forgets the pre-roll (a new run of the radio).
    public func clearHistory() { ring.clear() }

    /// Names the next file. With `rollsOnContextChange`, a change clears the pre-roll and, while
    /// recording, cuts to a new file there.
    public func setContext(_ new: RecordingContext) {
        let changed = context.withLock { c -> Bool in
            let had = c != nil, changed = c != new
            c = new
            return had && changed
        }
        guard changed, rollsOnContextChange else { return }
        ring.clear()
        if recording.load(ordering: .relaxed) { enqueue(.roll) }
    }

    /// The status says "recording" at once; the writer thread opens the file. While an auto session is
    /// open this turns it into a manual one (no commit limit) instead of starting a new file.
    public func start() {
        // One retrying claim, so a concurrent `start(fromFrame:)` can never slip between two attempts.
        var wasAuto = false
        var seen = kindBox.load(ordering: .acquiring)
        while seen != SessionKind.manual.rawValue {
            let (exchanged, original) = kindBox.compareExchange(expected: seen, desired: SessionKind.manual.rawValue,
                                                                ordering: .acquiringAndReleasing)
            if exchanged {
                wasAuto = seen == SessionKind.auto.rawValue
                break
            }
            seen = original
        }
        statusLock.withLock { s in
            if !s.isRecording {
                s = RecordingStatus()
                s.isRecording = true
            } else if wasAuto {
                s.isAuto = false
            }
        }
        recording.store(true, ordering: .releasing)
        enqueue(.start)
    }

    public var sessionKind: SessionKind { SessionKind(rawValue: kindBox.load(ordering: .acquiring)) ?? .none }

    /// Frames pushed since the last ring reset: the frame numbering `start(fromFrame:)`, `commit` and
    /// `stop(atFrame:)` use.
    public var headFrame: Int { ring.headFrames }

    /// Begins an auto session at `fromFrame` (clamped to the oldest frame the ring still holds). The
    /// writer sends nothing to the file until `commit(throughFrame:)` allows it. Ignored while any
    /// session is open.
    public func start(fromFrame: Int) {
        guard kindBox.compareExchange(expected: SessionKind.none.rawValue, desired: SessionKind.auto.rawValue,
                                      ordering: .acquiringAndReleasing).exchanged else { return }
        committedFrames.store(0, ordering: .releasing)
        let byte = ring.clamped(position: max(fromFrame, 0) * ring.bytesPerFrame)
        statusLock.withLock { s in
            s = RecordingStatus()
            s.isRecording = true
            s.isAuto = true
        }
        recording.store(true, ordering: .releasing)
        enqueue(.startAuto(byte: byte))
    }

    /// Lets an auto session write frames below `throughFrame`. Never moves backwards; one atomic
    /// store, cheap enough for every DSP block.
    public func commit(throughFrame: Int) {
        _ = committedFrames.max(throughFrame, ordering: .releasing)
    }

    /// How long `silence` fades out and back in, so neither edge of a silenced stretch clicks.
    static let silenceFadeSeconds = 0.01

    /// Makes frames `fromFrame` to `toFrame` silent in the history. With `fadeOut` the first 10 ms ramp
    /// down to silence instead of stopping dead; with `fadeIn` the 10 ms after `toFrame` ramp back up.
    /// Only frames an auto session has not committed are touched: the writer may be reading the ones
    /// below. Producer side (DSP thread).
    public func silence(fromFrame: Int, toFrame: Int, fadeOut: Bool, fadeIn: Bool) {
        producer.withLock { p in
            guard let setup = p.setup else { return }
            let bpf = ring.bytesPerFrame, format = setup.sampleFormat, channels = max(setup.channels, 1)
            let committed = committedFrames.load(ordering: .acquiring)
            let fade = max(1, Int(setup.sampleRate * Self.silenceFadeSeconds))
            // Frame f's gain: a ramp down over the fade-out, zero through `toFrame`, a ramp up after it.
            func gain(_ f: Int) -> Float {
                if f >= toFrame { return min(1, Float(f - toFrame + 1) / Float(fade + 1)) }
                if fadeOut, f - fromFrame < fade { return max(0, 1 - Float(f - fromFrame + 1) / Float(fade)) }
                return 0
            }
            let from = max(fromFrame, committed), to = fadeIn ? toFrame + fade : toFrame
            guard to > from else { return }
            ring.rewrite(from: from * bpf, to: to * bpf) { bytes, position in
                guard let base = bytes.baseAddress else { return }
                let first = position / bpf, count = bytes.count / bpf
                var i = 0
                while i < count {
                    let f = first + i
                    if gain(f) == 0, f + 1 < toFrame {
                        let run = min(count - i, toFrame - f)   // the zero stretch, in one go
                        format.scale(base + i * bpf, count: run * channels, by: 0)
                        i += run
                    } else {
                        format.scale(base + i * bpf, count: channels, by: gain(f))
                        i += 1
                    }
                }
            }
        }
    }

    /// Ends an auto session at `atFrame` (at the written position if that is already behind us, at the
    /// head if it is ahead). Ignored unless the session is an auto one.
    public func stop(atFrame: Int) {
        guard sessionKind == .auto else { return }
        enqueue(.stopAuto(byte: max(atFrame, 0) * ring.bytesPerFrame))
    }

    /// Ends the recording at the current head. With `wait`, returns once the file is finalised (or
    /// after `timeout`).
    public func stop(wait: Bool = false, timeout: TimeInterval = 5) {
        enqueue(.stop)
        guard wait else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while recording.load(ordering: .acquiring), Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
    }

    /// Ends any recording and the writer thread. The recorder is unusable afterwards.
    public func shutdown() {
        guard !quitting.exchange(true, ordering: .acquiringAndReleasing) else { return }
        enqueue(.quit)
        exited.wait()
    }

    public var status: RecordingStatus {
        var s = statusLock.withLock { $0 }
        let preRollBytes = producer.withLock { p in p.setup.flatMap { setup in p.plan.map { Self.preRoll(setup, $0).bytes } } } ?? 0
        if preRollBytes > 0 {
            s.preRollFill = min(1, Double(ring.available) / Double(preRollBytes))
        }
        return s
    }

    /// The newest frames, up to `lastSeconds`, never from before the last retune (`setContext`) or
    /// `clearHistory`. nil when the recorder is not set up for IQ or has heard nothing since. Any thread:
    /// it blocks `push` for one memcpy of what it takes, and converts after letting go.
    public func snapshot(lastSeconds: Double) -> IQSnapshot? {
        let (setup, plan) = producer.withLock { ($0.setup, $0.plan) }
        guard lastSeconds > 0, let setup, let plan, setup.channels == 2 else { return nil }
        let layout = setup.layout, format = layout.sampleFormat, bpf = layout.bytesPerFrame
        // Sized by what the ring holds now, so a long `lastSeconds` early on does not fault in a whole ring.
        let frames = Int(min(lastSeconds * setup.sampleRate, Double(ring.available / bpf)).rounded())
        guard frames > 0 else { return nil }
        var end = Date()
        /// Copies the newest frames into `out`, under the producer lock so a reconfigure cannot change
        /// what the bytes mean first. `out` must be faulted in already: a fresh allocation's page faults
        /// would otherwise run with `push` blocked (tens of ms for 16 s of 2 MS/s).
        func copy(into out: UnsafeMutableRawBufferPointer) -> Int {
            let (n, now) = producer.withLock { p -> (Int, @Sendable () -> Date) in
                guard p.setup?.layout == layout, p.plan == plan else { return (0, p.now) }
                return (ring.copyNewest(into: out), p.now)
            }
            end = now()
            return n
        }
        let samples: [Float]
        if format == .float32 {
            // Straight into the result: no second buffer.
            samples = [Float](unsafeUninitializedCapacity: frames * 2) { out, initialized in
                memset(out.baseAddress!, 0, out.count * 4)   // faults it in
                initialized = copy(into: UnsafeMutableRawBufferPointer(out)) / 4
            }
        } else {
            let bytes = UnsafeMutableRawBufferPointer.allocate(byteCount: frames * bpf, alignment: 16)
            defer { bytes.deallocate() }
            memset(bytes.baseAddress!, 0, bytes.count)   // faults it in
            let count = copy(into: bytes) / format.bytesPerSample
            samples = [Float](unsafeUninitializedCapacity: count) { out, initialized in
                if count > 0 { format.decode(bytes.baseAddress!, count: count, into: out.baseAddress!) }
                initialized = count
            }
        }
        guard !samples.isEmpty else { return nil }
        return IQSnapshot(samples: samples, sampleRate: setup.sampleRate, endTime: end)
    }

    private func enqueue(_ c: Command) {
        commands.withLock { $0.append(c) }
        wake.signal()
    }

    // MARK: Producer side (DSP thread)

    /// Interleaved floats in [-1, 1] (`channels` per frame), appended to the history.
    public func push(_ samples: UnsafeBufferPointer<Float>) {
        guard samples.count > 0 else { return }
        producer.withLock { p in
            guard let converter = p.converter, let setup = p.setup else { return }
            let bytes = samples.count * setup.sampleFormat.bytesPerSample
            if p.scratch == nil || p.scratch!.count < bytes {
                p.scratch?.deallocate()
                p.scratch = .allocate(byteCount: max(bytes, 1 << 16), alignment: 16)
            }
            let scratch = p.scratch!
            converter.convert(samples, into: scratch)
            ring.push(UnsafeRawBufferPointer(rebasing: scratch[0..<bytes]))
        }
        if recording.load(ordering: .relaxed) { wake.signal() }
    }

    // MARK: Writer thread

    private func run() {
        let chunk = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.chunkBytes, alignment: 16)
        defer { chunk.deallocate() }
        var session: Session?
        while true {
            _ = wake.wait(timeout: .now() + .milliseconds(250))
            let batch = commands.withLock { c -> [Command] in
                let b = c
                c.removeAll(keepingCapacity: true)
                return b
            }
            for command in batch {
                switch command {
                case .start:
                    if let s = session {
                        if s.isAuto {
                            // A manual start takes over: write to the head from here on, and drop an
                            // end that `stop(atFrame:)` had set.
                            s.isAuto = false
                            // Whatever order the claims landed in, the open session is a manual one now.
                            kindBox.store(SessionKind.manual.rawValue, ordering: .releasing)
                            statusLock.withLock { $0.isAuto = false }
                            if s.cutByFrame {
                                s.cutAt = nil
                                s.cut = nil
                                s.cutByFrame = false
                            }
                        }
                    } else {
                        session = begin(autoByte: nil)
                    }
                case .startAuto(let byte):
                    if session == nil { session = begin(autoByte: byte) }
                case .stop:
                    if let s = session, s.cut != .stop {
                        s.cutAt = cutPoint(s)
                        s.cut = .stop
                        s.cutByFrame = false
                    }
                case .stopAuto(let byte):
                    if let s = session, s.isAuto, s.cut != .stop {
                        s.cutAt = min(max(byte, s.position), ring.head)
                        s.cut = .stop
                        s.cutByFrame = true
                    }
                case .roll:
                    if let s = session, s.cut == nil {
                        s.cutAt = cutPoint(s)
                        s.cut = .roll
                    }
                case .quit:
                    if let s = session {
                        s.cutAt = cutPoint(s)
                        s.cut = .stop
                        drain(s, chunk: chunk, session: &session)
                        if let s = session { end(s, error: nil) }
                        session = nil
                    }
                    exited.signal()
                    return
                }
            }
            if let s = session { drain(s, chunk: chunk, session: &session) }
        }
    }

    /// Where a plain stop, roll or quit cuts: the head, or for an auto session only what is committed.
    private func cutPoint(_ s: Session) -> Int {
        let head = ring.head
        guard s.isAuto else { return head }
        return min(head, max(committedFrames.load(ordering: .acquiring) * s.layout.bytesPerFrame, s.position))
    }

    /// Marks the session over for `sessionKind`, unless a manual start has meanwhile claimed it.
    private func release(wasAuto: Bool) {
        let mine = (wasAuto ? SessionKind.auto : SessionKind.manual).rawValue
        _ = kindBox.compareExchange(expected: mine, desired: SessionKind.none.rawValue, ordering: .acquiringAndReleasing)
    }

    /// A recording that never opened: nothing is pending, whichever kind a takeover left it as.
    private func abandon() {
        kindBox.store(SessionKind.none.rawValue, ordering: .releasing)
        recording.store(false, ordering: .releasing)
    }

    /// Opens the first file of a recording: an auto session at `autoByte`, otherwise a manual one
    /// rewound by the pre-roll.
    private func begin(autoByte: Int?) -> Session? {
        let isAuto = autoByte != nil
        if !isAuto { kindBox.store(SessionKind.manual.rawValue, ordering: .releasing) }
        let (setup, plan, limitOverride, now) = producer.withLock { ($0.setup, $0.plan, $0.dataLimitOverride, $0.now) }
        guard let setup, let plan else {
            statusLock.withLock { $0 = RecordingStatus(); $0.error = "The \(kind.label) recorder is not set up." }
            abandon()
            return nil
        }
        let context = self.context.withLock { $0 } ?? RecordingContext(frequencyHz: 0, label: kind.label, hardware: "")
        // The ring may have moved on since the byte was chosen: never start behind what it holds.
        let position = autoByte.map { ring.clamped(position: $0) } ?? ring.rewind(bytes: Self.preRoll(setup, plan).bytes)
        let back = Double((ring.head - position) / setup.layout.bytesPerFrame) / setup.sampleRate
        let first = now().addingTimeInterval(-back)
        var status = RecordingStatus()
        status.isRecording = true
        status.isAuto = isAuto
        status.startedAt = first
        statusLock.withLock { $0 = status }
        recording.store(true, ordering: .releasing)
        do {
            let file = try open(setup.fileFormat, layout: setup.layout, folder: setup.folder, context: context, firstSample: first)
            statusLock.withLock { $0.url = file.url; $0.filesWritten = 1 }
            return Session(file: file, layout: setup.layout, fileFormat: setup.fileFormat, folder: setup.folder, context: context,
                           position: position, firstSample: first, dataLimit: limitOverride ?? setup.fileFormat.dataLimit,
                           isAuto: isAuto)
        } catch {
            statusLock.withLock { $0.isRecording = false; $0.error = "\(error)" }
            abandon()
            return nil
        }
    }

    private func open(_ format: FileFormat, layout: StreamLayout, folder: URL, context: RecordingContext, firstSample: Date) throws -> any RecordingFile {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = RecordingNames.base(firstSample: firstSample, frequencyHz: context.frequencyHz, label: context.label)
        let base = RecordingNames.unique(folder.appendingPathComponent(name), extension: format.fileExtension)
        let metadata = RecordingMetadata(frequencyHz: context.frequencyHz, firstSample: firstSample, hardware: context.hardware,
                                         description: "SubFloor \(kind.label) recording (\(context.label))")
        return try RecordingFiles.open(format, base: base, layout: layout, metadata: metadata)
    }

    /// Writes what the ring holds past the session's position, cutting and rolling files as needed.
    private func drain(_ s: Session, chunk: UnsafeMutableRawBufferPointer, session: inout Session?) {
        let bpf = s.layout.bytesPerFrame
        do {
            while true {
                let toCut = s.cutAt.map { $0 - s.position } ?? Int.max
                let inFile = s.dataLimit.map { $0 - s.file.bytesWritten } ?? Int.max
                let want = min(chunk.count, toCut, inFile)
                // An auto session holds back whatever is not committed, until a cut says where it ends.
                let held = s.isAuto && s.cutAt == nil
                    ? committedFrames.load(ordering: .acquiring) * bpf - s.position : Int.max
                if want > 0 && held <= 0 { break }
                if want <= 0 {
                    try s.file.finalize()
                    if toCut <= 0 && s.cut == .stop {
                        // The kind is released first, so whoever sees the recording end sees `.none`.
                        release(wasAuto: s.isAuto)
                        statusLock.withLock { $0.isRecording = false }
                        recording.store(false, ordering: .releasing)
                        session = nil
                        return
                    }
                    // A roll (new centre) or a full file: the next file starts where this one ended.
                    let next = s.firstSample.addingTimeInterval(Double(s.fileFrames) / s.layout.sampleRate)
                    if s.cut == .roll { s.context = context.withLock { $0 } ?? s.context }
                    s.file = try open(s.fileFormat, layout: s.layout, folder: s.folder, context: s.context, firstSample: next)
                    s.firstSample = next
                    s.fileFrames = 0
                    s.cutAt = nil
                    s.cut = nil
                    statusLock.withLock { $0.url = s.file.url; $0.filesWritten += 1 }
                    continue
                }
                let (n, skipped) = ring.read(from: &s.position, into: UnsafeMutableRawBufferPointer(rebasing: chunk[0..<min(want, held)]))
                if skipped > 0 { statusLock.withLock { $0.overrunBytes += skipped } }
                if n == 0 { break }
                try s.file.write(UnsafeRawBufferPointer(rebasing: chunk[0..<n]))
                s.fileFrames += n / bpf
                statusLock.withLock {
                    $0.framesWritten += n / bpf
                    $0.bytesWritten += n
                    $0.duration = Double($0.framesWritten) / s.layout.sampleRate
                }
            }
            let now = Date()
            if now.timeIntervalSince(s.lastCheckpoint) >= Self.checkpointInterval {
                try s.file.checkpoint()
                s.lastCheckpoint = now
            }
        } catch {
            end(s, error: "\(error)")
            session = nil
        }
    }

    private func end(_ s: Session, error: String?) {
        if error != nil { try? s.file.finalize() }
        release(wasAuto: s.isAuto)
        statusLock.withLock {
            $0.isRecording = false
            if let error { $0.error = error }
        }
        recording.store(false, ordering: .releasing)
    }
}
