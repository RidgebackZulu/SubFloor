import Accelerate
import DSPCore
import Foundation
import Modems
import Synchronization
import Testing
@testable import SubFloor

// MARK: - Support

private let fs = ModemWorker.sampleRate

/// Records every push with the name of the thread that made it, and whether two ever overlapped.
private final class RecordingSink: AudioSink, @unchecked Sendable {
    struct Push: Sendable {
        var producer: String
        var count: Int
    }

    private let log = Mutex<[Push]>([])
    private let inFlight = Atomic<Int>(0)
    private let classifier = Mutex<(@Sendable () -> String)?>(nil)
    let overlapped = Atomic<Bool>(false)

    /// Names the pushing thread (`Thread.name` is not reliable on every platform; identity is).
    func identify(worker: ModemWorker, engine: DSPEngine? = nil) {
        classifier.withLock {
            $0 = { [weak worker, weak engine] in
                if let t = worker?.thread, Thread.current === t { return modemThread }
                if let t = engine?.dspThread, Thread.current === t { return dspThread }
                return "other"
            }
        }
    }

    func push(_ samples: UnsafeBufferPointer<Float>) {
        if inFlight.add(1, ordering: .acquiringAndReleasing).newValue > 1 { overlapped.store(true, ordering: .relaxed) }
        let name = classifier.withLock { $0 }?() ?? "?"
        log.withLock { $0.append(Push(producer: name, count: samples.count)) }
        inFlight.subtract(1, ordering: .acquiringAndReleasing)
    }

    var pushes: [Push] { log.withLock { $0 } }
    var didOverlap: Bool { overlapped.load(ordering: .relaxed) }
    var total: Int { log.withLock { $0.reduce(0) { $0 + $1.count } } }

    func samples(from producer: String) -> Int {
        log.withLock { $0.filter { $0.producer == producer }.reduce(0) { $0 + $1.count } }
    }

    /// The producers in order, consecutive repeats collapsed.
    var runs: [String] {
        log.withLock { l in
            var out: [String] = []
            for p in l where out.last != p.producer { out.append(p.producer) }
            return out
        }
    }
}

private let dspThread = "SubFloor DSP"
private let modemThread = "SubFloor Modem"

/// A settable wall clock (Unix seconds).
private final class TestClock: Sendable {
    private let t: Mutex<Double>
    init(_ t: Double) { self.t = Mutex(t) }
    var seconds: Double {
        get { t.withLock { $0 } }
        set { t.withLock { $0 = newValue } }
    }
    func now() -> Date { Date(timeIntervalSince1970: seconds) }
}

/// Gaussian noise of standard deviation `sigma` (SplitMix64 + Box–Muller, deterministic).
private func noise(_ count: Int, sigma: Float, seed: UInt64) -> [Float] {
    var state = seed
    func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return (Double(z >> 11) + 0.5) / Double(1 << 53)
    }
    return (0..<count).map { _ in Float((-2 * log(next())).squareRoot() * cos(2 * .pi * next())) * sigma }
}

private func plus(_ a: [Float], _ b: [Float]) -> [Float] {
    var out = a
    for i in out.indices where i < b.count { out[i] += b[i] }
    return out
}

/// Noise at 20 dB below a 0.5-amplitude signal, in 2.5 kHz.
private let quietSigma = Float((0.125 / 100 * fs / 2 / 2_500).squareRoot())

/// Writes `audio` in `chunk`-sample blocks as the DSP thread would; with `clock`, each block is
/// written at the time of its last sample. Keeps at most ~2 s queued unless `wait` is false.
private func feed(_ worker: ModemWorker, _ audio: [Float], clock: TestClock? = nil, chunk: Int = 1_200, wait: Bool = true) {
    var i = 0
    while i < audio.count {
        let n = min(chunk, audio.count - i)
        if let clock { clock.seconds += Double(n) / fs }
        audio[i..<(i + n)].withUnsafeBufferPointer { worker.write($0) }
        i += n
        while wait, worker.queuedSamples > Int(2 * fs) { Thread.sleep(forTimeInterval: 0.002) }
    }
}

/// Drains `events` until `done` holds for the accumulated batches, or `timeout` passes.
private struct Collected {
    var batches: [ModemEventQueue.Batch] = []
    var text: String { batches.flatMap(\.text).map(\.text).joined() }
    var slotDecodes: [SlotDecode] { batches.flatMap(\.slotDecodes) }
    var lastSignals: [SignalSnapshot]? { batches.last { $0.signals != nil }?.signals }
}

private func collect(_ events: ModemEventQueue, into c: inout Collected, timeout: Double, until done: (Collected) -> Bool) {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        let b = events.drain()
        if !b.isEmpty { c.batches.append(b) }
        if done(c) { return }
        Thread.sleep(forTimeInterval: 0.02)
    }
}

private func waitUntil(_ timeout: Double, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}

/// How long to wait for a slot job's FT8 decode. A release build decodes a slot in well under a
/// second, but an unoptimised (debug) decode during a full parallel `swift test` run on the Mac took
/// over 10 s; the waits return as soon as the decode arrives.
private let slotDecodeTimeout = 120.0

/// A UTC slot boundary (a multiple of 120 s, so both FT8 and WSPR slots start there).
private let t0 = 1_800_000_000.0

// MARK: - Worker

@Suite(.serialized) struct ModemWorkerTests {
    private func worker(_ sink: RecordingSink, clock: TestClock? = nil, ringCapacity: Int = ModemWorker.ringCapacity,
                        settings: ModemSettings) -> ModemWorker {
        let w: ModemWorker
        if let clock {
            w = ModemWorker(audioSink: sink, ringCapacity: ringCapacity, now: { clock.now() })
        } else {
            w = ModemWorker(audioSink: sink, ringCapacity: ringCapacity)
        }
        sink.identify(worker: w)
        w.update(settings: settings)
        w.start(epoch: w.events.beginEpoch(at: Date()))
        return w
    }

    @Test func workerDecodesSyntheticPSK() {
        let sink = RecordingSink()
        let clock = TestClock(t0 - 1)
        let w = worker(sink, clock: clock, settings: ModemSettings(mode: .psk31))
        defer { w.stop() }
        w.grantAudio()
        let sent = "CQ CQ DE K1ABC K1ABC PSE K"
        let signal = PSK31Encoder.audio(text: sent + " " + sent, frequencyHz: 1_500, leadInSeconds: 1)
        let audio = plus(signal + [Float](repeating: 0, count: Int(fs)), noise(signal.count + Int(fs), sigma: quietSigma, seed: 11))
        #expect(audio.count < Int(20 * fs))
        feed(w, audio, clock: clock)
        var c = Collected()
        collect(w.events, into: &c, timeout: 10) { $0.text.contains("K1ABC PSE K") }
        #expect(c.text.contains("K1ABC"), "text: '\(c.text)'")
        #expect(c.lastSignals?.contains { abs($0.frequencyHz - 1_500) < 5 } == true)
        // Listen audio: everything, upsampled 4×, from the modem thread only.
        #expect(waitUntil(2) { sink.total >= 4 * audio.count - 256 }, "pushed \(sink.total) of \(4 * audio.count)")
        #expect(sink.total <= 4 * audio.count)
        #expect(sink.runs == [modemThread])
        #expect(w.droppedSamples.load(ordering: .relaxed) == 0)
    }

    /// Without the audio token the worker decodes but never pushes.
    @Test func noPushWithoutToken() {
        let sink = RecordingSink()
        let w = worker(sink, settings: ModemSettings(mode: .psk31))
        defer { w.stop() }
        feed(w, noise(Int(fs), sigma: quietSigma, seed: 3))
        #expect(waitUntil(2) { w.queuedSamples == 0 })
        Thread.sleep(forTimeInterval: 0.05)
        #expect(sink.total == 0)
        w.grantAudio()
        feed(w, noise(Int(fs), sigma: quietSigma, seed: 4))
        #expect(waitUntil(2) { sink.total > 0 })
        #expect(w.reclaimAudio() || waitUntil(1) { w.reclaimAudio() })
        let before = sink.total
        feed(w, noise(Int(fs), sigma: quietSigma, seed: 5))
        #expect(waitUntil(2) { w.queuedSamples == 0 })
        Thread.sleep(forTimeInterval: 0.05)
        #expect(sink.total == before)
    }

    /// Text and snapshots produced for the old box after a reset was asked for (the race between
    /// the main thread's new epoch and the modem thread reaching the reset in the audio) never
    /// reach the UI; audio queued before the reset is not decoded at all once the reset is known.
    @Test func staleEventsDroppedAfterReset() {
        let sink = RecordingSink()
        let w = worker(sink, settings: ModemSettings(mode: .psk31))
        defer { w.stop() }
        let old = "XYZZY XYZZY XYZZY XYZZY XYZZY XYZZY XYZZY XYZZY XYZZY XYZZY"
        let oldAudio = plus(PSK31Encoder.audio(text: old, frequencyHz: 1_000), noise(Int(16 * fs), sigma: quietSigma, seed: 21))
        // Old text is flowing.
        feed(w, Array(oldAudio[0..<Int(6 * fs)]))
        var before = Collected()
        collect(w.events, into: &before, timeout: 8) { $0.text.contains("XYZZY") }
        #expect(before.text.contains("XYZZY"))
        // More old audio queued, then the reset is asked for, but reaches the modem thread late.
        feed(w, Array(oldAudio[Int(6 * fs)...]), wait: false)
        let epoch = w.events.beginEpoch(at: Date())
        w.send(.lock(audioHz: 1_800), epoch: epoch)      // waits for the reset, then applies
        var during = Collected()
        collect(w.events, into: &during, timeout: 0.6) { _ in false }
        w.beginEpoch(epoch)
        let new = "CQ DE W9NEW W9NEW W9NEW K"
        feed(w, plus(PSK31Encoder.audio(text: new, frequencyHz: 1_800), noise(Int(12 * fs), sigma: quietSigma, seed: 22)))
        var after = Collected()
        collect(w.events, into: &after, timeout: 10) { $0.text.contains("W9NEW K") }

        #expect(during.batches.first?.clearedAt != nil, "the reset is reported")
        for c in [during, after] {
            #expect(!c.text.contains("XYZ") && !c.text.contains("ZZY"), "stale text: '\(c.text)'")
            #expect(c.batches.allSatisfy { $0.epoch == epoch })
            for b in c.batches {
                #expect(b.signals?.allSatisfy { abs($0.frequencyHz - 1_000) > 20 } ?? true, "stale track")
            }
        }
        #expect(after.text.contains("W9NEW"), "new text: '\(after.text)'")
        // The lock sent with the new epoch applied after the reset: the new signal is the cursor.
        #expect(after.lastSignals?.contains { $0.isCursor && abs($0.frequencyHz - 1_800) < 5 } == true)
    }

    @Test func slotJobsRunOffThread() throws {
        let sink = RecordingSink()
        let clock = TestClock(t0 - 1)
        let w = worker(sink, clock: clock, settings: ModemSettings(mode: .ft8))
        defer { w.stop() }
        let message = "CQ K1ABC FN42"
        let slot = try #require(FT8Encoder.audio(message: message, audioHz: 1_200))
        let lead = [Float](repeating: 0, count: Int(fs))
        let audio = plus(lead + slot + lead, noise(slot.count + 2 * lead.count, sigma: quietSigma, seed: 31))
        // Let the worker look at the slots once before the audio (it then follows the slot at t0).
        Thread.sleep(forTimeInterval: 0.1)
        w.slotQueue.suspend()
        feed(w, audio, clock: clock)
        #expect(waitUntil(5) { w.slotJobsDispatched.load(ordering: .relaxed) >= 1 })
        // The job waits on the (suspended) slot queue: nothing decoded on the modem thread.
        Thread.sleep(forTimeInterval: 0.2)
        #expect(w.events.drain().slotDecodes.isEmpty)
        #expect(w.slotJobsDecoded.load(ordering: .relaxed) == 0)
        w.slotQueue.resume()
        var c = Collected()
        collect(w.events, into: &c, timeout: slotDecodeTimeout) { !$0.slotDecodes.isEmpty }
        let d = try #require(c.slotDecodes.first)
        #expect(d.message == message)
        #expect(d.mode == .ft8)
        #expect(d.slotStart == Date(timeIntervalSince1970: t0))
        #expect(abs(d.frequencyHz - 1_200) < 3)
        #expect(abs(d.timeOffset) < 0.1, "stamps follow the sample clock: dt \(d.timeOffset)")
        #expect(w.slotJobsDispatched.load(ordering: .relaxed) == 1)
    }

    /// Slot decodes stay inside the decode band (the receiver's passband): a signal below it is not
    /// reported, one inside it is.
    @Test func slotDecodesStayInTheAudioBand() throws {
        let sink = RecordingSink()
        let clock = TestClock(t0 - 1)
        let w = worker(sink, clock: clock, settings: ModemSettings(mode: .ft8, audioBand: 1_500...3_000))
        defer { w.stop() }
        let outside = try #require(FT8Encoder.audio(message: "CQ K1ABC FN42", audioHz: 1_000))
        let inside = try #require(FT8Encoder.audio(message: "CQ W9XYZ EN37", audioHz: 2_000))
        let lead = [Float](repeating: 0, count: Int(fs))
        let both = zip(outside, inside).map { $0 + $1 }
        let audio = plus(lead + both + lead, noise(both.count + 2 * lead.count, sigma: quietSigma, seed: 33))
        Thread.sleep(forTimeInterval: 0.1)
        feed(w, audio, clock: clock)
        var c = Collected()
        collect(w.events, into: &c, timeout: slotDecodeTimeout) { !$0.slotDecodes.isEmpty }
        Thread.sleep(forTimeInterval: 0.3)
        c.batches.append(w.events.drain())
        #expect(c.slotDecodes.map(\.message) == ["CQ W9XYZ EN37"], "\(c.slotDecodes)")
    }

    /// A slot job started before a reset finishes afterwards; its decodes are dropped.
    @Test func staleSlotResultsDropped() throws {
        let sink = RecordingSink()
        let clock = TestClock(t0 - 1)
        let w = worker(sink, clock: clock, settings: ModemSettings(mode: .ft8))
        defer { w.stop() }
        let slot = try #require(FT8Encoder.audio(message: "CQ K1ABC FN42", audioHz: 1_200))
        let lead = [Float](repeating: 0, count: Int(fs))
        let audio = plus(lead + slot + lead, noise(slot.count + 2 * lead.count, sigma: quietSigma, seed: 41))
        Thread.sleep(forTimeInterval: 0.1)
        w.slotQueue.suspend()
        feed(w, audio, clock: clock)
        #expect(waitUntil(5) { w.slotJobsDispatched.load(ordering: .relaxed) >= 1 })
        let epoch = w.events.beginEpoch(at: clock.now())
        w.beginEpoch(epoch)
        w.slotQueue.resume()
        #expect(waitUntil(slotDecodeTimeout) { w.slotJobsDecoded.load(ordering: .relaxed) >= 1 })
        Thread.sleep(forTimeInterval: 0.05)
        let b = w.events.drain()
        #expect(b.slotDecodes.isEmpty, "\(b.slotDecodes)")
        #expect(b.clearedAt == Date(timeIntervalSince1970: clock.seconds - ModemEventQueue.cutoffMarginSeconds))
    }

    /// Review Focus 4: an overflow of the worker's ring inside a slot skips that slot; the next,
    /// complete slot decodes.
    @Test func ringOverflowSkipsSlot() throws {
        let sink = RecordingSink()
        let clock = TestClock(t0 - 1)
        let w = worker(sink, clock: clock, ringCapacity: 1 << 15, settings: ModemSettings(mode: .ft8))
        defer { w.stop() }
        let first = try #require(FT8Encoder.audio(message: "CQ K1ABC FN42", audioHz: 1_000))
        let second = try #require(FT8Encoder.audio(message: "CQ W9XYZ EN37", audioHz: 1_600))
        let lead = [Float](repeating: 0, count: Int(fs))
        let audio = plus(lead + first + second + lead, noise(2 * first.count + 2 * lead.count, sigma: quietSigma, seed: 51))
        Thread.sleep(forTimeInterval: 0.1)
        let s = { (seconds: Double) in Int(seconds * fs) }
        feed(w, Array(audio[0..<s(6)]), clock: clock)
        #expect(waitUntil(5) { w.queuedSamples == 0 })
        // 5 s while the worker is stalled: more than the 2.7 s ring holds.
        w.consumerPaused.store(true, ordering: .relaxed)
        feed(w, Array(audio[s(6)..<s(11)]), clock: clock, wait: false)
        #expect(w.droppedSamples.load(ordering: .relaxed) > s(2))
        w.consumerPaused.store(false, ordering: .relaxed)
        #expect(waitUntil(5) { w.queuedSamples == 0 })
        feed(w, Array(audio[s(11)...]), clock: clock, chunk: 1_200, wait: true)
        var c = Collected()
        collect(w.events, into: &c, timeout: slotDecodeTimeout) { !$0.slotDecodes.isEmpty }
        Thread.sleep(forTimeInterval: 0.5)
        c.batches.append(w.events.drain())
        #expect(c.slotDecodes.map(\.message) == ["CQ W9XYZ EN37"], "\(c.slotDecodes)")
        #expect(c.slotDecodes.first?.slotStart == Date(timeIntervalSince1970: t0 + 15))
    }

    /// Commands from an epoch the engine has left are dropped.
    @Test func staleCommandsDropped() {
        let sink = RecordingSink()
        let w = worker(sink, settings: ModemSettings(mode: .psk31))
        defer { w.stop() }
        let old = w.events.epoch
        let epoch = w.events.beginEpoch(at: Date())
        w.beginEpoch(epoch)
        w.send(.lock(audioHz: 1_000), epoch: old)
        let audio = plus(PSK31Encoder.audio(text: "CQ DE K1ABC K", frequencyHz: 1_000), noise(Int(8 * fs), sigma: quietSigma, seed: 61))
        feed(w, audio)
        var c = Collected()
        collect(w.events, into: &c, timeout: 6) { $0.lastSignals?.isEmpty == false }
        #expect(c.lastSignals?.isEmpty == false)
        #expect(c.lastSignals?.contains { $0.isCursor } == false)
    }
}

// MARK: - Stores

@Suite struct ModemStoresTests {
    @Test func eventQueueEpochs() {
        let q = ModemEventQueue()
        let e0 = q.epoch
        #expect(q.append(text: [DecodedText(trackID: 1, text: "A")], signals: nil, epoch: e0))
        let reset = Date(timeIntervalSince1970: t0)
        let e1 = q.beginEpoch(at: reset)
        #expect(e1 == e0 + 1)
        #expect(!q.append(text: [DecodedText(trackID: 1, text: "B")], signals: [], epoch: e0))
        let slot = SlotDecode(mode: .ft8, slotStart: reset, frequencyHz: 1_000, snrDb: 0, timeOffset: 0, message: "M")
        #expect(!q.append(slotDecodes: [slot], epoch: e0))
        var b = q.drain()
        #expect(b.epoch == e1 && b.text.isEmpty && b.signals == nil && b.slotDecodes.isEmpty)
        #expect(b.clearedAt == reset.addingTimeInterval(-ModemEventQueue.cutoffMarginSeconds))
        #expect(q.drain().isEmpty, "clearedAt is reported once")
        q.append(text: [DecodedText(trackID: 2, text: "C"), DecodedText(trackID: 2, text: "")], signals: [], epoch: e1)
        let s = SignalSnapshot(id: 2, frequencyHz: 1_500, snrDb: 10, mode: .psk31, submode: "", isQuiet: false, isCursor: false)
        q.append(text: [DecodedText(trackID: 2, text: "D")], signals: [s], epoch: e1)
        q.append(text: [], signals: nil, epoch: e1)
        q.append(slotDecodes: [slot], epoch: e1)
        b = q.drain()
        #expect(b.clearedAt == nil)
        #expect(b.text.map(\.text) == ["C", "D"])
        #expect(b.signals == [s], "the latest snapshot")
        #expect(b.slotDecodes == [slot])
        // Two resets between drains: one clear, at the later time.
        q.beginEpoch(at: reset.addingTimeInterval(10))
        let e3 = q.beginEpoch(at: reset.addingTimeInterval(20))
        b = q.drain()
        #expect(b.epoch == e3 && b.clearedAt == reset.addingTimeInterval(20 - ModemEventQueue.cutoffMarginSeconds))
    }

    /// The flow the main thread follows: a stale slot decode never reaches the log, a new one does,
    /// and the log's cutoff does not reject a new-box slot that started just before the reset time.
    @Test func eventQueueAndDecodeLogAgree() {
        let q = ModemEventQueue()
        var log = DecodeLog()
        let old = q.epoch
        let move = Date(timeIntervalSince1970: t0 + 30.02)
        let e = q.beginEpoch(at: move)
        let stale = SlotDecode(mode: .ft8, slotStart: Date(timeIntervalSince1970: t0 + 15), frequencyHz: 900, snrDb: 0,
                               timeOffset: 0, message: "OLD")
        let fresh = SlotDecode(mode: .ft8, slotStart: Date(timeIntervalSince1970: t0 + 30), frequencyHz: 1_000, snrDb: 0,
                               timeOffset: 0, message: "NEW")
        q.append(slotDecodes: [stale], epoch: old)
        q.append(slotDecodes: [fresh], epoch: e)
        let b = q.drain()
        if let cutoff = b.clearedAt { log.clear(at: cutoff) }
        log.apply(signals: b.signals, text: b.text, slotDecodes: b.slotDecodes, now: move.addingTimeInterval(20))
        #expect(log.slotRows.map(\.recentText) == ["NEW"])
    }

    @Test func cursorFrameStoreEpochs() {
        let store = CursorFrameStore()
        let frame = CursorFrame(waveform: [1], spectrumDb: [2], spectrumCenterHz: 1_000, iq: [], frequencyHz: 1_000,
                                snrDb: 3, submode: "", symbolRate: nil)
        #expect(store.read(after: 0) == nil)
        store.publish(frame, epoch: 1)
        let (seq, f) = try! #require(store.read(after: 0))
        #expect(seq == 1 && f.frequencyHz == 1_000)
        #expect(store.read(after: seq) == nil)
        store.discard(before: 2)
        #expect(store.read(after: seq) == nil)
        store.publish(frame, epoch: 1)
        #expect(store.read(after: seq) == nil, "stale frame ignored")
        store.publish(frame, epoch: 2)
        #expect(store.read(after: seq)?.0 == 2)
    }
}

// MARK: - Box audio clock

@Suite struct BoxAudioClockTests {
    /// Blocks of `block` samples, the k-th observed at its true end time plus `delay(k)`; the sample
    /// clock runs `ppm` fast against UTC. Returns the worst stamp error after `settleBlocks` and the
    /// anchor changes after the first window (steps beyond `SlotRecorder.gapToleranceSeconds`).
    private func run(blocks: Int, block: Int = 600, ppm: Double = 0, step: (at: Int, by: Double)? = nil,
                     delay: (Int) -> Double) -> (worst: Double, changes: Int, gaps: Int, clock: BoxAudioClock) {
        var clock = BoxAudioClock(sampleRate: fs)
        var worst = 0.0, changes = 0, gaps = 0
        let start = t0 + 0.123
        var lastStamp: Double?
        for k in 0..<blocks {
            let end = (k + 1) * block
            var trueEnd = start + Double(end) / fs * (1 - ppm * 1e-6)
            if let step, k >= step.at { trueEnd += step.by }
            let before = clock.time(at: end)
            if clock.observe(endIndex: end, now: trueEnd + delay(k)) {
                changes += 1
                if let b = before, let a = clock.time(at: end), abs(a - b) > SlotRecorder.gapToleranceSeconds { gaps += 1 }
            }
            let stamp = clock.time(at: end)!
            if k > 2 * Int(BoxAudioClock.windowSeconds * fs) / block {
                worst = max(worst, abs(stamp - trueEnd))
            }
            lastStamp = stamp
        }
        _ = lastStamp
        return (worst, changes, gaps, clock)
    }

    @Test func exactTimesNeverMove() {
        let r = run(blocks: 2_000) { _ in 0 }
        #expect(r.changes == 1, "only the first anchor")
        #expect(r.worst < 1e-6)
    }

    /// Scheduling delays of 0–30 ms (one-sided): the stamps settle on the earliest arrival.
    @Test func jitterIsFilteredByTheMinimum() {
        var rng: UInt64 = 7
        let r = run(blocks: 4_000) { k in
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let d = Double(rng >> 40) / Double(1 << 24) * 0.030
            return k == 0 ? 0.030 : d
        }
        // Bounded by the smallest delay in a window (40 blocks): a few ms at worst.
        #expect(r.worst < 0.005, "worst stamp error \(r.worst)")
        #expect(r.gaps <= 1, "only the first correction may be a step")
    }

    /// A 50 ppm sample clock is followed by slews, never by a gap.
    @Test func driftIsSlewed() {
        let r = run(blocks: 12_000, ppm: 50) { _ in 0.002 }   // 10 minutes
        #expect(r.worst < 0.008, "worst stamp error \(r.worst)")
        #expect(r.gaps == 0)
    }

    /// The wall clock set back 1 s is a step (a gap for the slot recorder), within one window.
    @Test func wallClockStepIsAStep() {
        let r = run(blocks: 3_000, step: (at: 1_500, by: -1)) { _ in 0 }
        #expect(r.gaps == 1)
        #expect(r.worst < 2.1, "until the step is corrected")
        let clock = r.clock
        let end = 3_000 * 600
        #expect(abs(clock.time(at: end)! - (t0 + 0.123 + Double(end) / fs - 1)) < 1e-6)
    }

    @Test func resetAndShift() {
        var clock = BoxAudioClock(sampleRate: fs)
        #expect(clock.time(at: 0) == nil)
        let anchored = clock.observe(endIndex: 1_200, now: t0)
        #expect(anchored)
        #expect(clock.time(at: 0) == t0 - 0.1)
        clock.shift(by: 0.25)
        #expect(abs(clock.time(at: 1_200)! - (t0 + 0.25)) < 1e-9)
        clock.reset()
        #expect(clock.time(at: 0) == nil)
        let changed = clock.observe(endIndex: 2_400, now: .nan)
        #expect(!changed)
    }
}

// MARK: - DSP engine routing

/// Delivers one burst of `burst` samples (more than the engine's IQ ring holds), then 10 ms blocks.
private final class BurstSource: IQSource, @unchecked Sendable {
    let name = "Burst"
    let sampleRate = 250_000.0
    let centerFrequency = 14_074_000.0
    private let burst: Int
    private let running = Atomic<Bool>(false)
    private var done: DispatchSemaphore?

    init(burst: Int) { self.burst = burst }

    func start(_ handler: @escaping @Sendable (UnsafeBufferPointer<DSPComplex>) -> Void) throws {
        stop()
        running.store(true, ordering: .releasing)
        let finished = DispatchSemaphore(value: 0)
        done = finished
        let burst = burst
        Thread { [self] in
            let big = [DSPComplex](repeating: DSPComplex(real: 0.001, imag: 0), count: burst)
            big.withUnsafeBufferPointer { handler($0) }
            let small = [DSPComplex](repeating: DSPComplex(real: 0.001, imag: 0), count: 2_500)
            while running.load(ordering: .acquiring) {
                small.withUnsafeBufferPointer { handler($0) }
                Thread.sleep(forTimeInterval: 0.01)
            }
            finished.signal()
        }.start()
    }

    func stop() {
        if running.exchange(false, ordering: .acquiringAndReleasing) { done?.wait() }
        done = nil
    }

    func setCenterFrequency(_ hz: Double) throws {}
}

/// A source whose only signal is a carrier `audioHz` above `center + boxOffset`.
private func source(center: Double = 14_074_000, boxOffset: Double = 20_000, audioHz: Double = 1_500) -> SyntheticSource {
    let s = SyntheticSource(sampleRate: 250_000, centerFrequency: center,
                            signals: [.init(frequency: center + boxOffset + audioHz, amplitude: 0.05, kind: .carrier)])
    s.noiseAmplitude = 0.0005
    return s
}

private let rx = Receiver.Config(inputRate: 250_000, offsetHz: 0, mode: .usb, bandwidthHz: 2_700)

@Suite(.serialized) struct ModemEngineRoutingTests {
    private func start(_ engine: DSPEngine, _ source: SyntheticSource) -> Bool {
        do {
            try engine.start(source: source, receiver: rx, spectrum: SpectrumSettings(fftSize: 2_048), volume: 0.1)
            return true
        } catch {
            print("engine start failed (tolerated, no audio device): \(error)")
            engine.stop()
            return false
        }
    }

    /// The Receiver's audio plays with the modem on as well as off (`DSPEngine.modemPlaysListenAudio`
    /// is off): the DSP thread is the only producer through modem toggles and a restart, the worker
    /// never pushes, and stop() joins both threads.
    @Test func receiverAudioStaysOnWithTheModem() {
        let sink = RecordingSink()
        let engine = DSPEngine(audioSink: sink)
        sink.identify(worker: engine.modemWorker, engine: engine)
        guard start(engine, source()) else { return }
        engine.update(modemBoxDialOffset: 20_000)
        #expect(waitUntil(3) { sink.samples(from: dspThread) > 0 })

        engine.update(modemSettings: ModemSettings(mode: .psk31))
        let worker = engine.modemWorker
        #expect(waitUntil(3) { worker.boxSamplesWritten.load(ordering: .relaxed) > 6_000 }, "the modem runs")
        let dspAtOn = sink.samples(from: dspThread)
        #expect(waitUntil(3) { sink.samples(from: dspThread) > dspAtOn + 4_800 }, "Receiver audio continues")
        engine.update(modemSettings: ModemSettings(mode: .ft8))
        let dspAtSwitch = sink.samples(from: dspThread)
        #expect(waitUntil(3) { sink.samples(from: dspThread) > dspAtSwitch + 4_800 }, "and across a mode change")
        engine.update(modemSettings: ModemSettings())
        let dspAtOff = sink.samples(from: dspThread)
        #expect(waitUntil(3) { sink.samples(from: dspThread) > dspAtOff + 4_800 })
        #expect(sink.samples(from: modemThread) == 0, "the worker never pushes")
        #expect(sink.runs == [dspThread], "\(sink.runs)")

        // stop() joins both threads: nothing pushes afterwards.
        engine.stop()
        #expect(!engine.modemWorker.isRunning)
        let stopped = sink.total
        Thread.sleep(forTimeInterval: 0.2)
        #expect(sink.total == stopped)

        // Restart with the modem on: still the Receiver's audio.
        engine.update(modemSettings: ModemSettings(mode: .cw))
        guard start(engine, source()) else { return }
        defer { engine.stop() }
        #expect(waitUntil(3) { sink.total > stopped + 4_800 })
        for _ in 0..<6 {
            engine.update(modemSettings: ModemSettings(mode: .psk31))
            Thread.sleep(forTimeInterval: 0.05)
            engine.update(modemSettings: ModemSettings())
            Thread.sleep(forTimeInterval: 0.05)
        }
        Thread.sleep(forTimeInterval: 0.2)
        #expect(sink.samples(from: modemThread) == 0)
        #expect(sink.runs == [dspThread], "\(sink.runs)")
        #expect(!sink.didOverlap, "two producers pushed at once")
    }

    @Test func boxOutsideSpanStopsChannel() {
        let sink = RecordingSink()
        let engine = DSPEngine(audioSink: sink)
        sink.identify(worker: engine.modemWorker, engine: engine)
        engine.update(modemSettings: ModemSettings(mode: .psk31))
        engine.update(modemBoxDialOffset: 20_000)
        guard start(engine, source()) else { return }
        defer { engine.stop() }
        let worker = engine.modemWorker
        #expect(waitUntil(3) { worker.boxSamplesWritten.load(ordering: .relaxed) > 6_000 })
        #expect(waitUntil(3) { sink.samples(from: dspThread) > 4_800 }, "Receiver audio plays with the modem on")

        let epoch = engine.modemEvents.epoch
        engine.update(modemBoxDialOffset: nil)
        Thread.sleep(forTimeInterval: 0.1)
        let stopped = worker.boxSamplesWritten.load(ordering: .relaxed)
        Thread.sleep(forTimeInterval: 0.4)
        #expect(worker.boxSamplesWritten.load(ordering: .relaxed) == stopped, "no box audio")
        let receiverNow = sink.samples(from: dspThread)
        #expect(waitUntil(3) { sink.samples(from: dspThread) > receiverNow + 4_800 }, "Receiver audio continues")
        #expect(engine.modemEvents.epoch == epoch, "leaving the span is not a reset")

        // Back in the span: box audio resumes in a new epoch.
        engine.update(modemBoxDialOffset: 20_000)
        #expect(engine.modemEvents.epoch == epoch + 1)
        #expect(waitUntil(3) { worker.boxSamplesWritten.load(ordering: .relaxed) > stopped + 6_000 })
    }

    /// The box audio carries the RF above the box's dial at its audio frequency, and the channel is
    /// built once, retuned for small moves, rebuilt on a reset and on an input-rate change.
    @Test func channelRetuneAndRebuild() {
        let sink = RecordingSink()
        let engine = DSPEngine(audioSink: sink)
        sink.identify(worker: engine.modemWorker, engine: engine)
        engine.update(modemSettings: ModemSettings(mode: .psk31))
        engine.update(modemBoxDialOffset: 20_000)
        guard start(engine, source(audioHz: 1_500)) else { return }
        defer { engine.stop() }
        var c = Collected()
        collect(engine.modemEvents, into: &c, timeout: 8) { $0.lastSignals?.contains { abs($0.frequencyHz - 1_500) < 3 } == true }
        #expect(c.lastSignals?.contains { abs($0.frequencyHz - 1_500) < 3 } == true, "\(String(describing: c.lastSignals))")
        #expect(engine.modemChannelBuilds.load(ordering: .relaxed) == 1)

        // 3 Hz, then 2 Hz more: retunes only (5 Hz from the reset point is not beyond the limit).
        let epoch = engine.modemEvents.epoch
        engine.update(modemBoxDialOffset: 20_003)
        engine.update(modemBoxDialOffset: 20_005)
        Thread.sleep(forTimeInterval: 0.2)
        #expect(engine.modemEvents.epoch == epoch)
        #expect(engine.modemChannelBuilds.load(ordering: .relaxed) == 1)
        c = Collected()
        collect(engine.modemEvents, into: &c, timeout: 3) { $0.lastSignals?.contains { abs($0.frequencyHz - 1_495) < 2 } == true }
        #expect(c.lastSignals?.contains { abs($0.frequencyHz - 1_495) < 2 } == true, "retuned: \(String(describing: c.lastSignals))")

        // A drag adding up past 5 Hz from the last reset: a reset, a new channel, the track re-found.
        engine.update(modemBoxDialOffset: 20_005.5)
        #expect(engine.modemEvents.epoch == epoch + 1)
        c = Collected()
        collect(engine.modemEvents, into: &c, timeout: 8) { $0.lastSignals?.contains { abs($0.frequencyHz - 1_494.5) < 3 } == true }
        #expect(c.batches.first?.clearedAt != nil)
        #expect(c.lastSignals?.contains { abs($0.frequencyHz - 1_494.5) < 3 } == true)
        #expect(engine.modemChannelBuilds.load(ordering: .relaxed) == 2)

        // An input-rate change rebuilds the channel without a reset.
        var faster = rx
        faster.inputRate = 500_000
        engine.update(receiver: faster)
        #expect(waitUntil(2) { engine.modemChannelBuilds.load(ordering: .relaxed) == 3 })
        #expect(engine.modemEvents.epoch == epoch + 1)
        let written = engine.modemWorker.boxSamplesWritten.load(ordering: .relaxed)
        #expect(waitUntil(2) { engine.modemWorker.boxSamplesWritten.load(ordering: .relaxed) > written + 1_200 })
    }

    /// IQ the callback could not fit in the ring is a gap in the box audio at exactly the point it
    /// was lost, sized at 12 kHz (Review Focus 4: the slot recorder then skips that slot).
    @Test func iqOverflowMarksGapWhereLost() {
        let sink = RecordingSink()
        let engine = DSPEngine(audioSink: sink)
        engine.update(modemSettings: ModemSettings(mode: .psk31))
        engine.update(modemBoxDialOffset: 20_000)
        let capacity = 1 << 22, burst = (1 << 22) + 300_000
        do {
            try engine.start(source: BurstSource(burst: burst), receiver: rx, spectrum: SpectrumSettings(fftSize: 2_048), volume: 0.1)
        } catch {
            print("engine start failed (tolerated, no audio device): \(error)")
            engine.stop()
            return
        }
        defer { engine.stop() }
        let worker = engine.modemWorker
        #expect(waitUntil(10) { !worker.gapLog.withLock { $0.isEmpty } })
        let gaps = worker.gapLog.withLock { $0 }
        let ratio = ModemChannel.outputRate / rx.inputRate
        if let g = gaps.first {
            #expect(abs(Double(g.atSample) - Double(capacity) * ratio) < 4, "gap at box sample \(g.atSample)")
            #expect(g.lost == Int((Double(burst - capacity) * ratio).rounded()))
        }
        // The small blocks that follow the burst are lost too if they arrive while the ring is still
        // full (a slow or loaded machine): each such loss is a real gap of its own, after the first.
        for (previous, next) in zip(gaps, gaps.dropFirst()) {
            #expect(next.atSample >= previous.atSample && next.lost > 0, "\(gaps)")
        }
    }

    /// Which requests begin a new epoch (no thread needs to run).
    @Test func boxResetRules() {
        let engine = DSPEngine(audioSink: RecordingSink())
        var e = engine.modemEvents.epoch
        engine.update(modemBoxDialOffset: 1_000)
        #expect(engine.modemEvents.epoch == e, "box without a mode: inactive")
        engine.update(modemSettings: ModemSettings(mode: .psk31))
        #expect(engine.modemEvents.epoch == e + 1, "turning on")
        e += 1
        engine.update(modemSettings: ModemSettings(mode: .cw))
        #expect(engine.modemEvents.epoch == e + 1, "a mode change starts from nothing")
        e += 1
        engine.update(modemSettings: ModemSettings(mode: .cw, audioBand: 500...2_500))
        #expect(engine.modemEvents.epoch == e, "a new passband is not a reset")
        engine.update(modemBoxDialOffset: 1_004)
        engine.update(modemBoxDialOffset: 996)
        #expect(engine.modemEvents.epoch == e, "within 5 Hz of the reset point")
        engine.update(modemBoxDialOffset: 1_005.1)
        #expect(engine.modemEvents.epoch == e + 1)
        e += 1
        engine.modemCommand(.lock(audioHz: 1_500))
        engine.modemCommand(.nudge(1))
        engine.modemCommand(.unlock)
        #expect(engine.modemEvents.epoch == e)
        engine.modemCommand(.resetBox)
        #expect(engine.modemEvents.epoch == e + 1)
        e += 1
        engine.update(modemBoxDialOffset: nil)
        #expect(engine.modemEvents.epoch == e)
        engine.update(modemBoxDialOffset: 1_005.1)
        #expect(engine.modemEvents.epoch == e + 1, "back in the span")
        e += 1
        engine.update(modemSettings: ModemSettings())
        #expect(engine.modemEvents.epoch == e + 1, "turning off drops the old mode's late results")
        e += 1
        engine.update(modemBoxDialOffset: 50_000)
        #expect(engine.modemEvents.epoch == e, "modem off: nothing to reset")
        engine.update(modemSettings: ModemSettings(mode: .ft8))
        #expect(engine.modemEvents.epoch == e + 1)
        #expect(engine.modemEvents.drain().clearedAt != nil)
    }
}
