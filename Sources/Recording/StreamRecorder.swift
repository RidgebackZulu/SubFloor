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
        public var memoryLimitBytes: Int
        public var folder: URL

        public init(sampleRate: Double, channels: Int, fileFormat: FileFormat, sampleFormat: SampleFormat,
                    preRollSeconds: Double, memoryLimitBytes: Int, folder: URL) {
            self.sampleRate = sampleRate
            self.channels = channels
            self.fileFormat = fileFormat
            self.sampleFormat = sampleFormat
            self.preRollSeconds = preRollSeconds
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

    /// The ring holds the pre-roll plus a margin (2 s or 10 %) for the writer to lag behind. When the
    /// memory limit binds, the margin is kept and the pre-roll shrinks.
    public static func plan(sampleRate: Double, bytesPerFrame: Int, preRollSeconds: Double, memoryLimitBytes: Int) -> RingPlan {
        let margin = max(2.0, preRollSeconds * 0.1)
        let wanted = Int(((preRollSeconds + margin) * sampleRate).rounded(.up))
        let frames = max(min(wanted, memoryLimitBytes / max(bytesPerFrame, 1)), 1)
        let effective = max(0, Double(frames) / sampleRate - margin)
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

    private enum Command { case start, stop, roll, quit }
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

        init(file: any RecordingFile, layout: StreamLayout, fileFormat: FileFormat, folder: URL, context: RecordingContext,
             position: Int, firstSample: Date, dataLimit: Int?) {
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
    /// pre-roll or memory limit rebuilds the ring (the pre-roll starts over) and ends a recording in
    /// progress; a change of folder or container takes effect at the next start.
    public func configure(_ setup: Setup) {
        let bpf = setup.layout.bytesPerFrame
        let plan = Self.plan(sampleRate: setup.sampleRate, bytesPerFrame: bpf, preRollSeconds: setup.preRollSeconds,
                             memoryLimitBytes: setup.memoryLimitBytes)
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
    public var ringPlan: RingPlan? { producer.withLock { $0.plan } }
    public var effectivePreRollSeconds: Double { ringPlan?.effectivePreRollSeconds ?? 0 }

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

    /// The status says "recording" at once; the writer thread opens the file.
    public func start() {
        statusLock.withLock { s in
            if !s.isRecording {
                s = RecordingStatus()
                s.isRecording = true
            }
        }
        recording.store(true, ordering: .releasing)
        enqueue(.start)
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
        if let plan = ringPlan, plan.preRollBytes > 0 {
            s.preRollFill = min(1, Double(ring.available) / Double(plan.preRollBytes))
        }
        return s
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
                    if session == nil { session = begin() }
                case .stop:
                    if let s = session, s.cut != .stop {
                        s.cutAt = ring.head
                        s.cut = .stop
                    }
                case .roll:
                    if let s = session, s.cut == nil {
                        s.cutAt = ring.head
                        s.cut = .roll
                    }
                case .quit:
                    if let s = session {
                        s.cutAt = ring.head
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

    /// Opens the first file of a recording, rewound by the pre-roll.
    private func begin() -> Session? {
        let (setup, plan, limitOverride, now) = producer.withLock { ($0.setup, $0.plan, $0.dataLimitOverride, $0.now) }
        guard let setup, let plan else {
            statusLock.withLock { $0 = RecordingStatus(); $0.error = "The \(kind.label) recorder is not set up." }
            return nil
        }
        let context = self.context.withLock { $0 } ?? RecordingContext(frequencyHz: 0, label: kind.label, hardware: "")
        let position = ring.rewind(bytes: plan.preRollBytes)
        let back = Double((ring.head - position) / setup.layout.bytesPerFrame) / setup.sampleRate
        let first = now().addingTimeInterval(-back)
        var status = RecordingStatus()
        status.isRecording = true
        status.startedAt = first
        statusLock.withLock { $0 = status }
        recording.store(true, ordering: .releasing)
        do {
            let file = try open(setup.fileFormat, layout: setup.layout, folder: setup.folder, context: context, firstSample: first)
            statusLock.withLock { $0.url = file.url; $0.filesWritten = 1 }
            return Session(file: file, layout: setup.layout, fileFormat: setup.fileFormat, folder: setup.folder, context: context,
                           position: position, firstSample: first, dataLimit: limitOverride ?? setup.fileFormat.dataLimit)
        } catch {
            statusLock.withLock { $0.isRecording = false; $0.error = "\(error)" }
            recording.store(false, ordering: .releasing)
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
                if want <= 0 {
                    try s.file.finalize()
                    if toCut <= 0 && s.cut == .stop {
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
                let (n, skipped) = ring.read(from: &s.position, into: UnsafeMutableRawBufferPointer(rebasing: chunk[0..<want]))
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
        statusLock.withLock {
            $0.isRecording = false
            if let error { $0.error = error }
        }
        recording.store(false, ordering: .releasing)
    }
}
