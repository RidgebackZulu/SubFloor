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
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!
        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let data = buffers[0].mData else { return noErr }
            render(UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(frameCount)))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        source = node
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
        if !engine.isRunning { try engine.start() }
    }

    func stop() {
        engine.stop()
        ring.drain()
        primed.store(false, ordering: .releasing)
    }
}
