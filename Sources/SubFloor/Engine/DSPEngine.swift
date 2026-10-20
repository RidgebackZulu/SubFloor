import Accelerate
import DSPCore
import Foundation
import Modems
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

/// Owns the IQ ring and the DSP thread: spectrum frames, receiver audio, modem feed.
final class DSPEngine: @unchecked Sendable {
    let frames = SpectrumFrameStore()
    let audio = AudioOutput()
    let modems = ModemHost()
    let stats = Mutex(EngineStats())

    private struct Pending {
        var receiver: Receiver.Config?
        var spectrum: SpectrumSettings?
        var volume: Float?
        var resetPeak = false
    }

    private let ring = SPSCRing<DSPComplex>(capacity: 1 << 22, fill: DSPComplex(real: 0, imag: 0))
    private let wake = DispatchSemaphore(value: 0)
    private let running = Atomic<Bool>(false)
    private let pending = Mutex(Pending())
    private let dropped = Atomic<Int>(0)
    private var exited: DispatchSemaphore?
    private var source: (any IQSource)?

    deinit { stop() }

    func start(source: any IQSource, receiver: Receiver.Config, spectrum: SpectrumSettings, volume: Float) throws {
        stop()
        ring.drain()
        pending.withLock { $0 = Pending() }
        dropped.store(0, ordering: .relaxed)
        self.source = source
        let done = DispatchSemaphore(value: 0)
        exited = done
        running.store(true, ordering: .releasing)
        let thread = Thread { [unowned self] in
            run(receiver: receiver, spectrum: spectrum, volume: volume)
            done.signal()
        }
        thread.name = "SubFloor DSP"
        thread.qualityOfService = .userInteractive
        thread.start()
        let ring = ring, wake = wake
        do {
            try audio.start()
            try source.start { [unowned self] block in
                let written = ring.write(block)
                if written < block.count { self.dropped.add(block.count - written, ordering: .relaxed) }
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
        audio.stop()
    }

    func update(receiver: Receiver.Config) { pending.withLock { $0.receiver = receiver } }
    func update(spectrum: SpectrumSettings) { pending.withLock { $0.spectrum = spectrum } }
    func update(volume: Float) { pending.withLock { $0.volume = volume } }
    func resetPeak() { pending.withLock { $0.resetPeak = true } }

    private func run(receiver config: Receiver.Config, spectrum initial: SpectrumSettings, volume initialVolume: Float) {
        let sampleRate = config.inputRate
        let receiver = Receiver(config: config)
        let modems = modems
        // Context is the start-time config; refresh when IQ modems arrive.
        receiver.channelTap = { iq, rate in
            modems.process(iq: iq, context: ModemContext(sampleRate: rate, mode: config.mode,
                                                         bandwidthHz: config.bandwidthHz, cwPitchHz: config.cwPitchHz))
        }
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

            let n = block.withUnsafeMutableBufferPointer { ring.read(into: $0) }
            if n == 0 {
                _ = wake.wait(timeout: .now() + .milliseconds(20))
                continue
            }

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
            let rx = receiver.config
            let context = ModemContext(sampleRate: Receiver.audioRate, mode: rx.mode, bandwidthHz: rx.bandwidthHz, cwPitchHz: rx.cwPitchHz)
            audioOut.withUnsafeBufferPointer { modems.process(audio: $0, context: context) }
            audioOut.withUnsafeMutableBufferPointer { a in
                var gain = volume
                vDSP_vsmul(a.baseAddress!, 1, &gain, a.baseAddress!, 1, vDSP_Length(a.count))
                var count = Int32(a.count)
                vvtanhf(a.baseAddress!, a.baseAddress!, &count)
            }
            audioOut.withUnsafeBufferPointer { audio.push($0) }
            let signal = receiver.signalDb
            let lost = dropped.load(ordering: .relaxed)
            stats.withLock { $0.signalDb = signal; $0.droppedSamples = lost }
        }
    }
}
