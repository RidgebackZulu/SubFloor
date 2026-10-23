import Accelerate
import DSPCore
import Foundation
import Modems
import Recording
import Synchronization

struct SpectrumSettings: Codable, Equatable, Sendable {
    var fftSize = 8192
    var window: WindowKind = .blackmanHarris
    var framesPerSecond = 30.0
    var averaging: Float = 0.5
}

struct EngineStats: Sendable {
    var signalDb: Float = -200
    var droppedSamples = 0
}

/// Latest averaged + peak spectrum, copied in by the DSP thread and out by the renderer.
final class SpectrumFrameStore: @unchecked Sendable {
    private struct Frame {
        var sequence: UInt64 = 0
        var average: [Float] = []
        var peak: [Float] = []
    }

    private let state = Mutex(Frame())

    func publish(average: [Float], peak: [Float]) {
        state.withLock { f in
            if f.average.count != average.count {
                f.average = average
                f.peak = peak
            } else {
                f.average.withUnsafeMutableBufferPointer { d in average.withUnsafeBufferPointer { d.baseAddress!.update(from: $0.baseAddress!, count: $0.count) } }
                f.peak.withUnsafeMutableBufferPointer { d in peak.withUnsafeBufferPointer { d.baseAddress!.update(from: $0.baseAddress!, count: $0.count) } }
            }
            f.sequence &+= 1
        }
    }

    /// Copies the latest frame if it is newer than `sequence`; returns its sequence number.
    func read(after sequence: UInt64, average: inout [Float], peak: inout [Float]) -> UInt64? {
        state.withLock { f in
            guard f.sequence != sequence, !f.average.isEmpty else { return nil }
            if average.count != f.average.count {
                average = f.average
                peak = f.peak
            } else {
                average.withUnsafeMutableBufferPointer { d in f.average.withUnsafeBufferPointer { d.baseAddress!.update(from: $0.baseAddress!, count: $0.count) } }
                peak.withUnsafeMutableBufferPointer { d in f.peak.withUnsafeBufferPointer { d.baseAddress!.update(from: $0.baseAddress!, count: $0.count) } }
            }
            return f.sequence
        }
    }
}

/// Owns the IQ ring and the DSP thread (spectrum frames, receiver audio, modem box channel) and the
/// modem thread (`ModemWorker`).
///
/// **Modem box.** While the modem is on (`modemSettings.mode != nil`) and a box is present
/// (`update(modemBoxDialOffset:)` non-nil), the DSP thread runs a `ModemChannel` on the IQ and feeds
/// its 12 kHz audio to the worker. The Receiver's audio keeps playing (`modemPlaysListenAudio` is
/// off); with it on, the worker would become the speakers' single producer, switched only in the DSP
/// loop's pending-config handling, through the worker's audio token (see `ModemWorker`).
///
/// **Box resets.** The box is reset (a new epoch, see `ModemEventQueue`) when it becomes active
/// (modem turned on with a box, or a box appearing while on), when the mode changes (so nothing of
/// the old mode carries over), when its dial offset has moved more than `boxResetHz` from where it was
/// at the last reset (so a slow drag still resets once it adds up), on `modemCommand(.resetBox)`, and on `start`. A retune of the capture centre moves the
/// offset too and is a reset: the IQ around a hardware retune is discontinuous, and audio from the
/// old centre must not seed tracks at the new one. A smaller move only retunes the channel. The
/// epoch is begun on the calling thread at once; the DSP thread rebuilds the channel and marks the
/// point in the box audio where the worker resets. The channel is also rebuilt (as a gap, not a
/// reset) when the input rate changes.
final class DSPEngine: @unchecked Sendable {
    /// A box dial-offset change beyond this (from the offset at the last reset) resets the box.
    static let boxResetHz = 5.0
    /// Whether the modem's listen audio (the cursor's signal through its mode's filter, or the whole
    /// box) replaces the Receiver's while the modem is on. Off: the Receiver's audio always plays,
    /// and the box follows the receiver's passband, so you hear what is decoded. The hand-over code
    /// (`ModemWorker`'s audio token) is kept for a listen mode later.
    static let modemPlaysListenAudio = false

    let frames = SpectrumFrameStore()
    let audio: AudioOutput
    let stats = Mutex(EngineStats())
    let modemEvents: ModemEventQueue
    let cursorFrames: CursorFrameStore

    /// Test hook: ModemChannels built by the DSP thread.
    let modemChannelBuilds = Atomic<Int>(0)
    let modemWorker: ModemWorker
    /// The recorders, fed on the DSP thread with every block: the IQ as it arrives, and the
    /// Receiver's audio before the volume knob and the limiter. Their pre-roll rings run whenever
    /// the engine does; a new run starts them over (`start`), and `stop` finalises any open file.
    let iqRecorder = StreamRecorder(kind: .iq, rollsOnContextChange: true)
    let audioRecorder = StreamRecorder(kind: .audio, rollsOnContextChange: false)

    /// What the DSP thread should do with the box.
    struct ModemBoxState: Equatable, Sendable {
        var offset: Double?
        var active: Bool
        var epoch: UInt64
    }

    /// The caller-side modem state (any thread; the DSP thread sees it as `Pending.modemBox`).
    private struct ModemRequest {
        var offset: Double?
        var settings = ModemSettings()
        /// The offset at the last box reset.
        var resetOffset: Double?
        var epoch: UInt64 = 0

        var isActive: Bool { settings.mode != nil && offset != nil }
        var box: ModemBoxState { ModemBoxState(offset: offset, active: isActive, epoch: epoch) }
    }

    private struct Pending {
        var receiver: Receiver.Config?
        var spectrum: SpectrumSettings?
        var volume: Float?
        var resetPeak = false
        var modemBox: ModemBoxState?
    }

    private let ring = SPSCRing<DSPComplex>(capacity: 1 << 22, fill: DSPComplex(real: 0, imag: 0))
    private let wake = DispatchSemaphore(value: 0)
    private let running = Atomic<Bool>(false)
    private let pending = Mutex(Pending())
    private let dropped = Atomic<Int>(0)
    /// IQ the source callback dropped (ring full): `count` samples were lost just before ring-stream
    /// position `position` (samples written into the ring since `start`). The DSP thread marks the
    /// gap in the box audio at exactly that point.
    private struct IQLoss {
        var position = 0
        var count = 0
    }
    private let losses = SPSCRing<IQLoss>(capacity: 256, fill: IQLoss())
    /// Callback thread only: samples written into the ring since `start`.
    private let iqWritten = Atomic<Int>(0)
    /// A loss record did not fit in `losses`; the DSP thread marks a gap where it notices.
    private let lossesOverflowed = Atomic<Bool>(false)
    private var exited: DispatchSemaphore?
    /// Test hook: the DSP thread while it runs (set before it starts).
    private(set) var dspThread: Thread?
    private var source: (any IQSource)?
    private let sink: any AudioSink
    private let modemRequest = Mutex(ModemRequest())

    /// `audioSink` replaces the `AudioOutput` as the destination of all speaker audio (tests); the
    /// `AudioOutput` is still started and stopped. `now` is the modem's wall clock (tests).
    init(audioSink: (any AudioSink)? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        let output = AudioOutput()
        audio = output
        sink = audioSink ?? output
        modemEvents = ModemEventQueue()
        cursorFrames = CursorFrameStore()
        modemWorker = ModemWorker(audioSink: sink, events: modemEvents, cursorFrames: cursorFrames, now: now)
    }

    deinit {
        stop()
        iqRecorder.shutdown()
        audioRecorder.shutdown()
    }

    func start(source: any IQSource, receiver: Receiver.Config, spectrum: SpectrumSettings, volume: Float) throws {
        stop()
        ring.drain()
        iqRecorder.clearHistory()
        audioRecorder.clearHistory()
        pending.withLock { $0 = Pending() }
        dropped.store(0, ordering: .relaxed)
        losses.drain()
        iqWritten.store(0, ordering: .relaxed)
        lossesOverflowed.store(false, ordering: .relaxed)
        self.source = source
        // A fresh engine: a new epoch, and the DSP thread starts from the current box request.
        let epoch = modemRequest.withLock { r in
            beginBoxEpoch(&r)
            pending.withLock { $0.modemBox = r.box }
            return r.epoch
        }
        modemWorker.update(volume: volume)
        modemWorker.start(epoch: epoch)
        let done = DispatchSemaphore(value: 0)
        exited = done
        running.store(true, ordering: .releasing)
        let thread = Thread { [unowned self] in
            run(receiver: receiver, spectrum: spectrum, volume: volume, epoch: epoch)
            done.signal()
        }
        thread.name = "SubFloor DSP"
        thread.qualityOfService = .userInteractive
        dspThread = thread
        thread.start()
        let ring = ring, wake = wake
        do {
            try audio.start()
            try source.start { [unowned self] block in
                let written = ring.write(block)
                let position = self.iqWritten.load(ordering: .relaxed) + written
                self.iqWritten.store(position, ordering: .relaxed)
                if written < block.count {
                    let lost = block.count - written
                    self.dropped.add(lost, ordering: .relaxed)
                    let loss = IQLoss(position: position, count: lost)
                    let recorded = withUnsafePointer(to: loss) { self.losses.write(UnsafeBufferPointer(start: $0, count: 1)) }
                    if recorded == 0 { self.lossesOverflowed.store(true, ordering: .relaxed) }
                }
                wake.signal()
            }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        source?.stop()
        source = nil
        if running.exchange(false, ordering: .acquiringAndReleasing) {
            wake.signal()
            exited?.wait()
        }
        exited = nil
        dspThread = nil
        // After the DSP thread: every block it pushed is in the files.
        iqRecorder.stop(wait: true)
        audioRecorder.stop(wait: true)
        modemWorker.stop()
        audio.stop()
    }

    func update(receiver: Receiver.Config) { pending.withLock { $0.receiver = receiver } }
    func update(spectrum: SpectrumSettings) { pending.withLock { $0.spectrum = spectrum } }
    func update(volume: Float) {
        pending.withLock { $0.volume = volume }
        modemWorker.update(volume: volume)
    }
    func resetPeak() { pending.withLock { $0.resetPeak = true } }

    // MARK: Modem

    /// The box's dial minus the capture centre; nil when there is no box or it is outside the span
    /// (box audio stops). See **Box resets**.
    func update(modemBoxDialOffset offset: Double?) {
        let offset = offset.flatMap { $0.isFinite ? $0 : nil }
        modemRequest.withLock { r in
            let wasActive = r.isActive
            r.offset = offset
            if r.isActive, let o = offset {
                if !wasActive || abs(o - (r.resetOffset ?? o)) > Self.boxResetHz { beginBoxEpoch(&r) }
            }
            pending.withLock { $0.modemBox = r.box }
        }
    }

    func update(modemSettings settings: ModemSettings) {
        modemRequest.withLock { r in
            let wasActive = r.isActive, oldMode = r.settings.mode
            r.settings = settings
            // A new mode starts from nothing: the old mode's tracks, decoders, rows, cursor, partly
            // recorded slots and in-flight slot results all go (an epoch). Turning on is a new mode.
            if settings.mode != oldMode || (r.isActive && !wasActive) { beginBoxEpoch(&r) }
            modemWorker.update(settings: settings)
            pending.withLock { $0.modemBox = r.box }
        }
    }

    func modemCommand(_ command: ModemCommand) {
        modemRequest.withLock { r in
            if command == .resetBox {
                beginBoxEpoch(&r)
                pending.withLock { $0.modemBox = r.box }
            } else {
                modemWorker.send(command, epoch: r.epoch)
            }
        }
    }

    /// Seconds to add to the system clock for UTC (from `ClockCheck`), or nil for the system clock.
    func update(clockOffset: Double?) { modemWorker.update(clockOffset: clockOffset) }

    /// Begins a new epoch for the box (caller side, under `modemRequest`).
    private func beginBoxEpoch(_ r: inout ModemRequest) {
        r.epoch = modemEvents.beginEpoch(at: modemWorker.utcNow())
        cursorFrames.discard(before: r.epoch)
        r.resetOffset = r.offset
    }

    private func run(receiver config: Receiver.Config, spectrum initial: SpectrumSettings, volume initialVolume: Float,
                     epoch: UInt64) {
        let sampleRate = config.inputRate
        let receiver = Receiver(config: config)
        var settings = initial
        var volume = initialVolume
        var analyzer = SpectrumAnalyzer(size: settings.fftSize, window: settings.window)
        var averager = SpectrumAverager(size: settings.fftSize, alpha: settings.averaging)
        var history = [DSPComplex](repeating: DSPComplex(real: 0, imag: 0), count: settings.fftSize)
        var linear = history
        var db = [Float](repeating: -200, count: settings.fftSize)
        var historyPos = 0
        var sinceFrame = 0
        var block = [DSPComplex](repeating: DSPComplex(real: 0, imag: 0), count: 1 << 16)
        var audioOut = [Float]()
        audioOut.reserveCapacity(1 << 15)
        let worker = modemWorker
        var box = ModemBoxState(offset: nil, active: false, epoch: epoch)
        var channel: ModemChannel?
        var channelOffset = 0.0
        var boxAudio = [Float]()
        boxAudio.reserveCapacity(1 << 14)
        var iqRead = 0
        var nextLoss: IQLoss?
        var lossScratch = IQLoss()

        while running.load(ordering: .acquiring) {
            let changes = pending.withLock { p -> Pending in
                let c = p
                p = Pending()
                return c
            }
            if let r = changes.receiver { receiver.update(r) }
            if let v = changes.volume { volume = v }
            if let s = changes.spectrum, s != settings {
                if s.fftSize != settings.fftSize || s.window != settings.window {
                    analyzer = SpectrumAnalyzer(size: s.fftSize, window: s.window)
                    averager = SpectrumAverager(size: s.fftSize, alpha: s.averaging)
                    history = .init(repeating: DSPComplex(real: 0, imag: 0), count: s.fftSize)
                    linear = history
                    db = .init(repeating: -200, count: s.fftSize)
                    historyPos = 0
                    sinceFrame = 0
                }
                averager.alpha = s.averaging
                settings = s
            }
            if changes.resetPeak { averager.resetPeak() }

            // Modem box: the only place the speakers change hands.
            if let b = changes.modemBox {
                if b.epoch != worker.producerEpoch {
                    worker.beginEpoch(b.epoch)
                    channel = nil
                }
                if !b.active { channel = nil }
                // Receiver audio stops here; its last push is behind us (only while the modem plays its
                // own listen audio, which it does not: see `modemPlaysListenAudio`).
                if Self.modemPlaysListenAudio, b.active, !box.active { worker.grantAudio() }
                box = b
            }
            if box.active, let offset = box.offset {
                let rate = receiver.config.inputRate
                if let c = channel, c.inputRate == rate {
                    if offset != channelOffset {
                        c.setDialOffset(offset)
                        channelOffset = offset
                    }
                } else {
                    // A rate change breaks the stream; after a reset the epoch mark already did.
                    if channel != nil { worker.markGap(lostSamples: 1, reanchor: true) }
                    channel = ModemChannel(inputRate: rate, dialOffsetHz: offset)
                    channelOffset = offset
                    modemChannelBuilds.add(1, ordering: .relaxed)
                }
            }

            let n = block.withUnsafeMutableBufferPointer { ring.read(into: $0) }
            if n == 0 {
                _ = wake.wait(timeout: .now() + .milliseconds(20))
                continue
            }

            block.withUnsafeBufferPointer { b in
                b.withMemoryRebound(to: Float.self) { iqRecorder.push(UnsafeBufferPointer(rebasing: $0[0..<(2 * n)])) }
            }

            // Box audio, with a gap wherever the callback dropped IQ inside this block.
            var done = 0
            while true {
                if nextLoss == nil, withUnsafeMutablePointer(to: &lossScratch, {
                    losses.read(into: UnsafeMutableBufferPointer(start: $0, count: 1))
                }) == 1 {
                    nextLoss = lossScratch
                }
                guard let loss = nextLoss, loss.position <= iqRead + n else { break }
                let cut = min(max(loss.position - iqRead, done), n)
                if let channel {
                    feedBox(channel, block, done..<cut, into: &boxAudio)
                    let lost = Double(loss.count) * ModemChannel.outputRate / receiver.config.inputRate
                    worker.markGap(lostSamples: Int(lost.rounded()), reanchor: false)
                }
                done = cut
                nextLoss = nil
            }
            if let channel {
                if lossesOverflowed.exchange(false, ordering: .relaxed) { worker.markGap(lostSamples: 1, reanchor: true) }
                feedBox(channel, block, done..<n, into: &boxAudio)
            }
            iqRead += n

            // Spectrum: keep the most recent fftSize samples; emit frames at framesPerSecond.
            let size = settings.fftSize
            block.withUnsafeBufferPointer { b in
                history.withUnsafeMutableBufferPointer { h in
                    var i = max(0, n - size)
                    while i < n {
                        let k = min(n - i, size - historyPos)
                        (h.baseAddress! + historyPos).update(from: b.baseAddress! + i, count: k)
                        historyPos = (historyPos + k) % size
                        i += k
                    }
                }
            }
            sinceFrame += n
            if sinceFrame >= max(size, Int(sampleRate / max(1, settings.framesPerSecond.isFinite ? settings.framesPerSecond : 1))) {
                sinceFrame = 0
                linear.withUnsafeMutableBufferPointer { l in
                    history.withUnsafeBufferPointer { h in
                        let tail = size - historyPos
                        l.baseAddress!.update(from: h.baseAddress! + historyPos, count: tail)
                        (l.baseAddress! + tail).update(from: h.baseAddress!, count: historyPos)
                    }
                }
                linear.withUnsafeBufferPointer { src in db.withUnsafeMutableBufferPointer { analyzer.process(src, into: $0) } }
                db.withUnsafeBufferPointer { averager.add($0) }
                frames.publish(average: averager.average, peak: averager.peak)
            }

            // Audio.
            audioOut.removeAll(keepingCapacity: true)
            block.withUnsafeBufferPointer { receiver.process(UnsafeBufferPointer(rebasing: $0[0..<n]), audio: &audioOut) }
            guard !audioOut.isEmpty else { continue }
            audioOut.withUnsafeBufferPointer { audioRecorder.push($0) }
            audioOut.withUnsafeMutableBufferPointer { a in
                var gain = volume
                vDSP_vsmul(a.baseAddress!, 1, &gain, a.baseAddress!, 1, vDSP_Length(a.count))
                var count = Int32(a.count)
                vvtanhf(a.baseAddress!, a.baseAddress!, &count)
            }
            // While the worker owns the speakers (only with `modemPlaysListenAudio`), it pushes instead;
            // after it, wait for the token.
            if !(Self.modemPlaysListenAudio && box.active), worker.reclaimAudio() {
                audioOut.withUnsafeBufferPointer { sink.push($0) }
            }
            let signal = receiver.signalDb
            let lost = dropped.load(ordering: .relaxed)
            stats.withLock { $0.signalDb = signal; $0.droppedSamples = lost }
        }
    }

    /// DSP thread: box audio for `block[range]` to the modem worker.
    private func feedBox(_ channel: ModemChannel, _ block: [DSPComplex], _ range: Range<Int>, into boxAudio: inout [Float]) {
        guard !range.isEmpty else { return }
        boxAudio.removeAll(keepingCapacity: true)
        block.withUnsafeBufferPointer { channel.process(UnsafeBufferPointer(rebasing: $0[range]), audio: &boxAudio) }
        boxAudio.withUnsafeBufferPointer { modemWorker.write($0) }
    }
}
