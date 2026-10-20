import Accelerate
import DSPCore
import Foundation
import Modems
import SubFloorCore
import Synchronization

/// Where engine audio goes: the `AudioOutput`, or a recorder in tests. `push` is called by one
/// producer at a time (see `ModemWorker`'s **Speaker audio**).
protocol AudioSink: AnyObject, Sendable {
    func push(_ samples: UnsafeBufferPointer<Float>)
}

extension AudioOutput: AudioSink {}

/// What the main thread asks of the modem (through `DSPEngine.modemCommand`).
enum ModemCommand: Sendable, Equatable {
    case lock(audioHz: Double)
    case unlock
    case nudge(Int)
    /// Clears tracks, decoders, rows and slot audio (a new epoch; see `ModemEventQueue`).
    case resetBox
}

/// UTC time of box-audio samples, from a monotonic sample count anchored to the wall clock.
///
/// A sample's time is `anchorTime + (index − anchorIndex) / sampleRate`, so stamps follow the
/// sample clock exactly and never jitter. Each block is observed with the UTC time it left the
/// channel; the measured error (that time less the predicted time of the block's end) is one-sided
/// (scheduling only ever delays a block), so the anchor is steered by the *minimum* error over each
/// `windowSeconds` of audio:
/// - the first window after anchoring corrects it fully (the first block may have been late);
/// - an error beyond `stepSeconds` (the wall clock was set, or audio was lost unannounced) steps it;
/// - otherwise it slews by at most `slewSeconds` per window, ignoring errors within
///   `deadbandSeconds`. That follows the sample clock's drift against UTC (tens of ppm) with
///   steps far inside `SlotRecorder.gapToleranceSeconds`, so a slew is never a gap there, while a
///   step (or the first correction, when large) is.
///
/// The stamps are when the audio left the channel, so they run late by the channel's group delay
/// and the IQ path's latency (tens of ms), well inside FT8's and WSPR's time tolerance.
struct BoxAudioClock: Sendable {
    static let windowSeconds = 2.0
    static let stepSeconds = 0.25
    static let slewSeconds = 0.005
    static let deadbandSeconds = 0.001

    let sampleRate: Double
    private(set) var anchorIndex = 0
    /// NaN while unanchored.
    private(set) var anchorTime = Double.nan
    private var settled = false
    private var windowEnd = 0
    private var windowMin = Double.infinity

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    var isAnchored: Bool { !anchorTime.isNaN }

    /// UTC (Unix seconds) of sample `index`, or nil while unanchored.
    func time(at index: Int) -> Double? {
        isAnchored ? anchorTime + Double(index - anchorIndex) / sampleRate : nil
    }

    /// Forgets the anchor: the next observed block anchors afresh.
    mutating func reset() {
        anchorTime = .nan
        settled = false
        windowMin = .infinity
    }

    /// Moves every later stamp by `seconds` at once (the clock offset changed).
    mutating func shift(by seconds: Double) {
        guard isAnchored, seconds.isFinite else { return }
        anchorTime += seconds
    }

    /// Observes a block whose last sample is `endIndex − 1`, leaving the channel at UTC `now`.
    /// Returns true when the anchor changed (the caller re-publishes the time).
    mutating func observe(endIndex: Int, now: Double) -> Bool {
        guard now.isFinite else { return false }
        let windowSamples = Int(Self.windowSeconds * sampleRate)
        guard isAnchored else {
            anchorIndex = endIndex
            anchorTime = now
            settled = false
            windowMin = .infinity
            windowEnd = endIndex + windowSamples
            return true
        }
        let predicted = anchorTime + Double(endIndex - anchorIndex) / sampleRate
        windowMin = min(windowMin, now - predicted)
        guard endIndex >= windowEnd else { return false }
        let error = windowMin
        windowMin = .infinity
        windowEnd = endIndex + windowSamples
        let correction: Double
        if !settled || abs(error) > Self.stepSeconds {
            correction = error
        } else if abs(error) > Self.deadbandSeconds {
            correction = min(max(error, -Self.slewSeconds), Self.slewSeconds)
        } else {
            correction = 0
        }
        settled = true
        guard correction != 0 else { return false }
        anchorTime = predicted + correction
        anchorIndex = endIndex
        return true
    }
}

/// The modem thread: runs a `ModemEngine` on the 12 kHz box audio the DSP thread produces, publishes
/// its output to `events` and `cursorFrames`, plays its listen audio, and hands complete FT8/WSPR
/// slots to `slotQueue`.
///
/// **Producer side** (`write`, `beginEpoch`, `markGap`, `grantAudio`, `reclaimAudio`): one thread
/// only, the DSP thread (a test, standalone), and only while the worker runs. Box audio goes
/// through an `SPSCRing` (capacity `ringCapacity`, about 22 s). Each sample has a *stream index*
/// that counts every sample produced, dropped ones included; the producer stamps the stream with a
/// `BoxAudioClock` (wall clock plus the `clockOffset`). Changes of epoch, index or time travel in a
/// second ring as *marks*, each pinned to a position in the audio ring:
/// - a full audio ring drops the samples that do not fit (counted in `droppedSamples`) and the next
///   mark jumps the stream index past them, so the engine sees the gap and the slot recorder skips
///   the slot (never decodes a partial one). A full mark ring drops audio until the mark fits.
/// - `markGap` (IQ lost upstream, channel rebuilt) jumps the index the same way.
/// - `beginEpoch` resets the engine exactly at that point in the audio; audio queued before it is
///   the old box's and is skipped unprocessed once the mark is known.
///
/// **Consumer side** (the worker's own thread): every `ModemEngine` call. Settings and commands
/// arrive through a Mutex pending struct like `DSPEngine.Pending`. Commands carry the epoch they
/// were issued in: one from an older epoch is dropped, one from a newer epoch waits until the
/// engine reaches that epoch's mark (a lock sent right after a reset applies after the reset).
///
/// **Outputs** are tagged with the epoch the engine was in, and slot jobs with the epoch they were
/// cut in (see `ModemEventQueue`).
///
/// **Speaker audio.** The listen audio is resampled 12 → 48 kHz, scaled by the volume and soft-
/// clipped like the Receiver's, and pushed to the sink only while the worker holds the audio token.
/// The DSP thread grants it (`grantAudio`, after its own last push) when it stops pushing Receiver
/// audio, and takes it back with `reclaimAudio`, which fails while the worker is mid-push (the DSP
/// thread then skips that block's Receiver audio and retries with the next). The token's
/// acquire/release orderings also hand the sink's single-producer side from one thread to the
/// other, so exactly one thread ever pushes.
final class ModemWorker: @unchecked Sendable {
    static let ringCapacity = 1 << 18
    static let markCapacity = 1_024
    /// Audio per engine call at most (170 ms), bounding listen-audio bursts.
    static let maxChunk = 2_048
    static let slotCheckSeconds = 0.25
    static let sampleRate = ModemChannel.outputRate

    private static let tokenReceiver: UInt8 = 0
    private static let tokenGranted: UInt8 = 1
    private static let tokenPushing: UInt8 = 2

    let events: ModemEventQueue
    let cursorFrames: CursorFrameStore
    let slotQueue = DispatchQueue(label: "subfloor.slots", qos: .utility)

    // MARK: Test hooks

    /// Box samples offered to `write`, dropped ones included.
    let boxSamplesWritten = Atomic<Int>(0)
    /// Box samples dropped because the audio ring (or the mark ring) was full.
    let droppedSamples = Atomic<Int>(0)
    /// Slot jobs handed to `slotQueue`, and decoded there.
    let slotJobsDispatched = Atomic<Int>(0)
    let slotJobsDecoded = Atomic<Int>(0)
    /// Every `markGap`: the box samples written before it, and the samples it says were lost.
    let gapLog = Mutex<[(atSample: Int, lost: Int)]>([])
    /// While set, the consumer reads nothing (tests fill the ring with it).
    let consumerPaused = Atomic<Bool>(false)

    var isRunning: Bool { running.load(ordering: .acquiring) }
    /// The modem thread while it runs (set before it starts).
    private(set) var thread: Thread?
    /// Box audio queued for the modem thread.
    var queuedSamples: Int { ring.availableToRead }

    // MARK: Private state

    /// A change in the box-audio stream, effective from audio-ring position `ringIndex`.
    private struct Mark {
        var ringIndex = 0
        var epoch: UInt64 = 0
        /// Stream index of the sample at `ringIndex`.
        var streamIndex = 0
        /// Its UTC time (Unix seconds), NaN when untimed.
        var time = Double.nan
    }

    private struct Command {
        var epoch: UInt64
        var command: ModemCommand
    }

    private struct Control {
        var settings = ModemSettings()
        var settingsChanged = false
        var commands: [Command] = []
    }

    /// DSP-thread (producer) state; reset by `start` while no thread runs.
    private struct Producer {
        var epoch: UInt64 = 0
        /// Samples written into the audio ring since `start`.
        var ringWritten = 0
        var streamIndex = 0
        var clock = BoxAudioClock(sampleRate: ModemWorker.sampleRate)
        var offset = 0.0
        var pendingMark: Mark?
    }

    private let sink: any AudioSink
    private let now: @Sendable () -> Date
    private let ring: SPSCRing<Float>
    private let marks = SPSCRing<Mark>(capacity: ModemWorker.markCapacity, fill: Mark())
    private let wake = DispatchSemaphore(value: 0)
    private let running = Atomic<Bool>(false)
    private var exited: DispatchSemaphore?
    private let control = Mutex(Control())
    private let volumeBits = Atomic<UInt32>(Float(0.5).bitPattern)
    private let offsetBits = Atomic<UInt64>(0.0.bitPattern)
    private let audioToken = Atomic<UInt8>(ModemWorker.tokenReceiver)
    private var producer = Producer()

    /// `now` is the wall clock (tests inject one); `ringCapacity` is for tests.
    init(audioSink: any AudioSink, events: ModemEventQueue = ModemEventQueue(),
         cursorFrames: CursorFrameStore = CursorFrameStore(), ringCapacity: Int = ModemWorker.ringCapacity,
         now: @escaping @Sendable () -> Date = { Date() }) {
        sink = audioSink
        self.events = events
        self.cursorFrames = cursorFrames
        self.now = now
        ring = SPSCRing(capacity: ringCapacity, fill: 0)
    }

    deinit { stop() }

    // MARK: Lifecycle

    /// Starts the modem thread with a fresh engine in `epoch` (the producer's epoch too).
    func start(epoch: UInt64) {
        stop()
        ring.drain()
        marks.drain()
        producer = Producer()
        producer.epoch = epoch
        producer.offset = clockOffset
        audioToken.store(Self.tokenReceiver, ordering: .releasing)
        let settings = control.withLock { c in
            c.commands.removeAll()
            c.settingsChanged = false
            return c.settings
        }
        let done = DispatchSemaphore(value: 0)
        exited = done
        running.store(true, ordering: .releasing)
        let thread = Thread { [unowned self] in
            run(epoch: epoch, settings: settings)
            done.signal()
        }
        thread.name = "SubFloor Modem"
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
    }

    /// Stops and joins the modem thread. Slot jobs already queued still finish (their results are
    /// tagged with their epoch).
    func stop() {
        if running.exchange(false, ordering: .acquiringAndReleasing) {
            wake.signal()
            exited?.wait()
        }
        exited = nil
        thread = nil
    }

    // MARK: Control (any thread)

    func update(settings: ModemSettings) {
        control.withLock { c in
            c.settings = settings
            c.settingsChanged = true
        }
    }

    /// Queues `command` (not `.resetBox`, which is an epoch) for the engine, issued in `epoch`.
    func send(_ command: ModemCommand, epoch: UInt64) {
        guard command != .resetBox else { return }
        control.withLock { $0.commands.append(Command(epoch: epoch, command: command)) }
    }

    func update(volume: Float) { volumeBits.store(volume.bitPattern, ordering: .relaxed) }

    /// Seconds to add to the wall clock for UTC (`ClockCheck`); nil uses the wall clock as is.
    func update(clockOffset: Double?) {
        let offset = clockOffset.flatMap { $0.isFinite ? $0 : nil } ?? 0
        offsetBits.store(offset.bitPattern, ordering: .relaxed)
    }

    var clockOffset: Double { Double(bitPattern: offsetBits.load(ordering: .relaxed)) }

    /// The current UTC time: the wall clock plus the clock offset.
    func utcNow() -> Date { now().addingTimeInterval(clockOffset) }

    // MARK: Producer (DSP thread)

    /// The producer's current epoch.
    var producerEpoch: UInt64 { producer.epoch }

    /// Starts `epoch` at the current point of the box-audio stream, and re-anchors its time.
    func beginEpoch(_ epoch: UInt64) {
        producer.epoch = epoch
        producer.clock.reset()
        queueMark()
        _ = flushMark()
        wake.signal()
    }

    /// Box audio was lost or broken before the next block (`lostSamples` at 12 kHz, at least one is
    /// counted so the engine sees a gap). `reanchor` also re-times the stream.
    func markGap(lostSamples: Int, reanchor: Bool) {
        let at = boxSamplesWritten.load(ordering: .relaxed)
        gapLog.withLock { $0.append((at, lostSamples)) }
        producer.streamIndex += max(1, lostSamples)
        if reanchor { producer.clock.reset() }
        queueMark()
        _ = flushMark()
    }

    /// Box audio, 12 kHz, the block that just left the channel.
    func write(_ audio: UnsafeBufferPointer<Float>) {
        let n = audio.count
        guard n > 0 else { return }
        boxSamplesWritten.add(n, ordering: .relaxed)
        let offset = clockOffset
        if offset != producer.offset {
            let anchored = producer.clock.isAnchored
            producer.clock.shift(by: offset - producer.offset)
            producer.offset = offset
            if anchored { queueMark() }
        }
        let t = now().timeIntervalSince1970 + offset
        if producer.clock.observe(endIndex: producer.streamIndex + n, now: t) { queueMark() }
        guard flushMark() else {
            producer.streamIndex += n
            droppedSamples.add(n, ordering: .relaxed)
            queueMark()
            return
        }
        let written = ring.write(audio)
        producer.ringWritten += written
        producer.streamIndex += n
        if written < n {
            droppedSamples.add(n - written, ordering: .relaxed)
            queueMark()
            _ = flushMark()
        }
        wake.signal()
    }

    /// Hands the speakers to the worker. Call after the producer thread's last push of its own.
    func grantAudio() {
        if audioToken.load(ordering: .acquiring) == Self.tokenReceiver {
            audioToken.store(Self.tokenGranted, ordering: .releasing)
        }
    }

    /// Takes the speakers back; true when the producer thread may push (false: the worker is mid-
    /// push, try again with the next block).
    func reclaimAudio() -> Bool {
        switch audioToken.load(ordering: .acquiring) {
        case Self.tokenReceiver:
            return true
        case Self.tokenGranted:
            return audioToken.compareExchange(expected: Self.tokenGranted, desired: Self.tokenReceiver,
                                              ordering: .acquiringAndReleasing).exchanged
        default:
            return false
        }
    }

    /// Records a mark at the current ring position (replacing one not yet sent: nothing has been
    /// written since, so it is at the same position and supersedes it).
    private func queueMark() {
        producer.pendingMark = Mark(ringIndex: producer.ringWritten, epoch: producer.epoch,
                                    streamIndex: producer.streamIndex,
                                    time: producer.clock.time(at: producer.streamIndex) ?? .nan)
    }

    /// Sends the pending mark; false when the mark ring is full (audio must wait).
    private func flushMark() -> Bool {
        guard let m = producer.pendingMark else { return true }
        let sent = withUnsafePointer(to: m) { marks.write(UnsafeBufferPointer(start: $0, count: 1)) }
        guard sent == 1 else { return false }
        producer.pendingMark = nil
        return true
    }

    // MARK: Consumer (modem thread)

    private func run(epoch startEpoch: UInt64, settings: ModemSettings) {
        let rate = Self.sampleRate
        let engine = ModemEngine(sampleRate: rate)
        engine.settings = settings
        var epoch = startEpoch
        var consumed = 0
        var streamIndex = 0
        var anchorIndex = 0
        var anchorTime = Double.nan
        var chunk = [Float](repeating: 0, count: Self.maxChunk)
        var markBuffer = [Mark](repeating: Mark(), count: 64)
        var known: [Mark] = []
        known.reserveCapacity(Self.markCapacity)
        var head = 0
        var commands: [Command] = []
        commands.reserveCapacity(64)
        var resampler = FractionalResampler(inputRate: rate, outputRate: AudioOutput.sampleRate)
        var speaker: [Float] = []
        speaker.reserveCapacity(Self.maxChunk * 4 + 64)
        var lastSlotCheck = -Double.infinity
        var lastSlotCheckAudio = 0
        let band = ModemBox.audioLow...ModemBox.audioHigh

        while running.load(ordering: .acquiring) {
            let newSettings = control.withLock { c -> ModemSettings? in
                commands.append(contentsOf: c.commands)
                c.commands.removeAll(keepingCapacity: true)
                defer { c.settingsChanged = false }
                return c.settingsChanged ? c.settings : nil
            }
            if let s = newSettings { engine.settings = s }

            if consumerPaused.load(ordering: .relaxed) {
                _ = wake.wait(timeout: .now() + .milliseconds(5))
                continue
            }

            // Audio available now; every mark before it is visible once it is (marks are sent first).
            let available = ring.availableToRead
            let m = markBuffer.withUnsafeMutableBufferPointer { marks.read(into: $0) }
            if m > 0 {
                if head == known.count {
                    known.removeAll(keepingCapacity: true)
                    head = 0
                }
                known.append(contentsOf: markBuffer[0..<m])
            }
            while head < known.count, known[head].ringIndex <= consumed {
                let mark = known[head]
                head += 1
                if mark.epoch != epoch {
                    engine.resetForBoxMove()
                    epoch = mark.epoch
                }
                streamIndex = mark.streamIndex
                anchorIndex = mark.streamIndex
                anchorTime = mark.time
            }
            if head >= 256 {
                known.removeFirst(head)
                head = 0
            }

            var k = 0
            while k < commands.count, commands[k].epoch <= epoch {
                if commands[k].epoch == epoch {
                    switch commands[k].command {
                    case .lock(let hz): engine.lockCursor(atAudioHz: hz)
                    case .unlock: engine.unlockCursor()
                    case .nudge(let d): engine.nudgeCursor(d)
                    case .resetBox: break
                    }
                }
                k += 1
            }
            if k > 0 { commands.removeFirst(k) }

            var count = min(available, Self.maxChunk)
            let nextMark = head < known.count ? known[head] : nil
            if let nextMark { count = min(count, nextMark.ringIndex - consumed) }
            if count > 0 {
                let n = chunk.withUnsafeMutableBufferPointer { ring.read(into: UnsafeMutableBufferPointer(rebasing: $0[0..<count])) }
                // Audio before a mark of a newer epoch belongs to the old box: skip it.
                if nextMark.map({ $0.epoch == epoch }) ?? true {
                    let time = anchorTime.isNaN ? nil
                        : Date(timeIntervalSince1970: anchorTime + Double(streamIndex - anchorIndex) / rate)
                    let out = chunk.withUnsafeBufferPointer {
                        engine.process(UnsafeBufferPointer(rebasing: $0[0..<n]), sampleIndex: streamIndex, firstSampleTime: time)
                    }
                    if !out.text.isEmpty || out.signals != nil {
                        events.append(text: out.text, signals: out.signals, epoch: epoch)
                    }
                    if let c = out.cursor { cursorFrames.publish(c, epoch: epoch) }
                    speaker.removeAll(keepingCapacity: true)
                    out.listenAudio.withUnsafeBufferPointer { resampler.process($0, into: &speaker) }
                    play(&speaker)
                }
                consumed += n
                streamIndex += n
            }

            // Slots: every `slotCheckSeconds` of wall time, and of audio (the audio may lag the clock).
            let t = utcNow().timeIntervalSince1970
            if t - lastSlotCheck >= Self.slotCheckSeconds || t < lastSlotCheck
                || consumed - lastSlotCheckAudio >= Int(Self.slotCheckSeconds * rate) {
                lastSlotCheck = t
                lastSlotCheckAudio = consumed
                for job in engine.dueSlotJobs(now: Date(timeIntervalSince1970: t)) { dispatch(job, epoch: epoch, band: band) }
            }

            if count == 0 { _ = wake.wait(timeout: .now() + .milliseconds(20)) }
        }
    }

    /// Volume, soft clip, and push if the worker holds the speakers.
    private func play(_ audio: inout [Float]) {
        guard !audio.isEmpty else { return }
        audio.withUnsafeMutableBufferPointer { a in
            var gain = Float(bitPattern: volumeBits.load(ordering: .relaxed))
            vDSP_vsmul(a.baseAddress!, 1, &gain, a.baseAddress!, 1, vDSP_Length(a.count))
            var count = Int32(a.count)
            vvtanhf(a.baseAddress!, a.baseAddress!, &count)
        }
        guard audioToken.compareExchange(expected: Self.tokenGranted, desired: Self.tokenPushing,
                                         ordering: .acquiring).exchanged else { return }
        audio.withUnsafeBufferPointer { sink.push($0) }
        audioToken.store(Self.tokenGranted, ordering: .releasing)
    }

    private func dispatch(_ job: SlotJob, epoch: UInt64, band: ClosedRange<Double>) {
        let events = events
        slotJobsDispatched.add(1, ordering: .relaxed)
        slotQueue.async { [weak self] in
            let decodes = job.decode(audioBand: band)
            self?.slotJobsDecoded.add(1, ordering: .relaxed)
            events.append(slotDecodes: decodes, epoch: epoch)
        }
    }
}
