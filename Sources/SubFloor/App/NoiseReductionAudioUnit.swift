import AudioToolbox
import AVFoundation
import DSPCore
import Synchronization

/// The noise reducer as an in-process effect, so the Recordings window's player runs recordings through the
/// same `NoiseReducer` the live radio uses. One mono 48 kHz float bus in and one out: the reducer's frame and
/// tracker are sized for 48 kHz, so the player converts every file to that before the effect.
///
/// The settings reach the render thread through an atomic, read once per render; the reducer itself belongs to
/// the render thread. Nothing in the render block allocates, locks or touches Swift concurrency.
final class NoiseReductionAudioUnit: AUAudioUnit {
    /// `aufx` / `snrd` / `SubF`.
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x736E_7264,          // 'snrd'
        componentManufacturer: 0x5375_6246,     // 'SubF'
        componentFlags: 0,
        componentFlagsMask: 0)

    /// The one format of both busses.
    static let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    /// Registers the subclass with the process's component manager, once, before the first instance.
    static let registered: Void = {
        AUAudioUnit.registerSubclass(NoiseReductionAudioUnit.self, as: componentDescription,
                                     name: "SubFloor: Noise Reduction", version: 1)
    }()

    private let kernel = Kernel()
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let input = try AUAudioUnitBus(format: Self.format)
        input.maximumChannelCount = 1
        let output = try AUAudioUnitBus(format: Self.format)
        output.maximumChannelCount = 1
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [input])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [output])
        maximumFramesToRender = 4096
    }

    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    override var canProcessInPlace: Bool { true }

    /// What the effect is told to apply, from any thread; the render thread picks it up on its next cycle.
    var requested: NoiseReductionSettings {
        get { Kernel.decode(kernel.requested.load(ordering: .relaxed)) }
        set { kernel.requested.store(Kernel.encode(newValue), ordering: .relaxed) }
    }

    /// A fresh reducer: no noise estimate, nothing buffered from the last file, primed and faded in from the
    /// next audio if NR is on. Only while the engine is stopped, so it never races the render thread.
    func resetReducer() { kernel.replaceReducer() }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        kernel.allocate(frames: Int(maximumFramesToRender))
    }

    override func deallocateRenderResources() {
        kernel.deallocate()
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let kernel = kernel
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            kernel.render(timestamp: timestamp, frames: frameCount, output: outputData, pull: pullInputBlock)
        }
    }

    /// The render-thread half. `requested` is written from anywhere; everything else is touched by the render
    /// thread only, or (`replaceReducer`, `allocate`, `deallocate`) while it is not running.
    private final class Kernel: @unchecked Sendable {
        let requested = Atomic<UInt64>(encode(NoiseReductionSettings()))
        private var reducer = NoiseReducer()
        /// The `requested` value the reducer was last updated to; `.max` makes the next render update it.
        private var applied = UInt64.max
        private var scratch: UnsafeMutablePointer<Float>?
        private var capacity = 0

        deinit { deallocate() }

        /// Bit 32 the switch, the low bits the strength in millionths.
        static func encode(_ s: NoiseReductionSettings) -> UInt64 {
            let strength = s.strength.isFinite ? min(max(s.strength, 0), 1) : 0.5
            return (s.enabled ? 1 << 32 : 0) | UInt64((strength * 1_000_000).rounded())
        }

        static func decode(_ v: UInt64) -> NoiseReductionSettings {
            NoiseReductionSettings(enabled: v & (1 << 32) != 0, strength: Double(v & 0xFFFF_FFFF) / 1_000_000)
        }

        func replaceReducer() {
            reducer = NoiseReducer()
            applied = .max
        }

        func allocate(frames: Int) {
            guard frames > capacity else { return }
            deallocate()
            scratch = .allocate(capacity: frames)
            scratch?.initialize(repeating: 0, count: frames)
            capacity = frames
        }

        func deallocate() {
            scratch?.deallocate()
            scratch = nil
            capacity = 0
        }

        func render(timestamp: UnsafePointer<AudioTimeStamp>, frames: AUAudioFrameCount,
                    output: UnsafeMutablePointer<AudioBufferList>, pull: AURenderPullInputBlock?) -> AUAudioUnitStatus {
            guard let pull else { return kAudioUnitErr_NoConnection }
            let count = Int(frames)
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            for i in 0..<buffers.count {
                buffers[i].mDataByteSize = UInt32(count * MemoryLayout<Float>.size)
                if buffers[i].mData == nil {
                    // The host gave no buffer: pull into ours (mono, so one is enough).
                    guard let scratch, count <= capacity else { return kAudioUnitErr_TooManyFramesToProcess }
                    buffers[i].mData = UnsafeMutableRawPointer(scratch)
                }
            }
            var flags = AudioUnitRenderActionFlags()
            let status = pull(&flags, timestamp, frames, 0, output)
            guard status == noErr else { return status }

            let now = requested.load(ordering: .relaxed)
            if now != applied {
                reducer.update(Self.decode(now))
                applied = now
            }
            guard buffers.count > 0, let data = buffers[0].mData else { return noErr }
            reducer.process(UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
            return noErr
        }
    }
}
