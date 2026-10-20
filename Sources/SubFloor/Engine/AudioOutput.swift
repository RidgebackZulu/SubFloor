import AVFoundation
import DSPCore
import Synchronization

/// 48 kHz mono output fed from an SPSC ring. Re-primes to ~50 ms after an underrun.
final class AudioOutput: @unchecked Sendable {
    static let sampleRate = 48_000.0
    static let targetLatency = 2_400

    let underruns = Atomic<Int>(0)
    private let ring = SPSCRing<Float>(capacity: 48_000, fill: 0)
    private let primed = Atomic<Bool>(false)
    let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let format = AVAudioFormat(standardFormatWithSampleRate: AudioOutput.sampleRate, channels: 1)!
    private let wantsRunning = Atomic<Bool>(false)
    private let lifecycle = NSLock()
    private var configObserver: NSObjectProtocol?
    /// Called (on an arbitrary thread) when the engine could not be restarted after a device change.
    var onError: (@Sendable (String) -> Void)?

    init() {
        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let data = buffers[0].mData else { return noErr }
            render(UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(frameCount)))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        source = node
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in self?.handleConfigurationChange() }
    }

    deinit { if let configObserver { NotificationCenter.default.removeObserver(configObserver) } }

    /// The output device changed and AVAudioEngine stopped itself: rebuild the graph and restart if we should be running.
    private func handleConfigurationChange() {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard wantsRunning.load(ordering: .acquiring), let source else { return }
        engine.stop()
        engine.disconnectNodeOutput(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        primed.store(false, ordering: .releasing)
        do { try engine.start() } catch {
            onError?("Audio output stopped after a device change: \(error.localizedDescription)")
        }
    }

    private func render(_ out: UnsafeMutableBufferPointer<Float>) {
        if !primed.load(ordering: .acquiring) {
            guard ring.availableToRead >= max(Self.targetLatency, out.count) else {
                out.update(repeating: 0)
                return
            }
            primed.store(true, ordering: .releasing)
        }
        let n = ring.read(into: out)
        if n < out.count {
            UnsafeMutableBufferPointer(rebasing: out[n...]).update(repeating: 0)
            underruns.add(1, ordering: .relaxed)
            primed.store(false, ordering: .releasing)
        }
    }

    /// DSP thread. Drops a block when the buffer is already 4× the latency target, bounding drift.
    func push(_ samples: UnsafeBufferPointer<Float>) {
        guard ring.availableToRead < Self.targetLatency * 4 else { return }
        ring.write(samples)
    }

    func start() throws {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        wantsRunning.store(true, ordering: .releasing)
        if !engine.isRunning { try engine.start() }
    }

    func stop() {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        wantsRunning.store(false, ordering: .releasing)
        engine.stop()
        ring.drain()
        primed.store(false, ordering: .releasing)
    }
}
