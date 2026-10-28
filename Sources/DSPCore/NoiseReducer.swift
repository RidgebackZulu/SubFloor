import Foundation

/// The user's noise-reduction choice: off/on and how hard.
public struct NoiseReductionSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// 0 (Light) … 1 (Strong).
    public var strength: Double

    public init(enabled: Bool = false, strength: Double = 0.5) {
        self.enabled = enabled
        self.strength = strength
    }

    /// "Light" below a third, "Strong" above two thirds, else "Medium".
    public var label: String {
        strength < 1.0 / 3 ? "Light" : strength <= 2.0 / 3 ? "Medium" : "Strong"
    }

    /// Wideband FM is broadcast audio at full bandwidth; noise reduction is for the narrow modes.
    public static func isAvailable(for mode: DemodMode) -> Bool { mode != .wfm }
}

/// `SpectralNoiseReducer` with an on/off crossfade, strength ramps and a make-up gain that restores
/// the voice level the reduction took off (never the hiss level). `process` runs in place on a
/// real-time thread: nothing is allocated or locked after `init`.
public final class NoiseReducer {
    /// Crossfade and strength-ramp length: 30 ms.
    private let rampSamples: Int
    private let hop = SpectralNoiseReducer.hop
    private let reducer: SpectralNoiseReducer
    private let dry: UnsafeMutablePointer<Float>       // one hop of input, before the reducer

    private var settings = NoiseReductionSettings()
    /// 0 = all dry, 1 = all wet; moves 1/rampSamples per sample towards 1 when enabled, else 0.
    private var wetMix: Float = 0
    private var currentStrength: Double = 0.5
    private var strengthStep: Double = 0
    private var strengthRampLeft = 0
    private var rampTarget: Double = 0.5
    /// Smoothed linear make-up gain on the wet path (1 = 0 dB).
    private var makeup: Float = 1
    private let makeupCoefficient: Float

    public init(sampleRate: Double = 48_000) {
        rampSamples = max(1, Int((0.03 * sampleRate).rounded()))
        makeupCoefficient = Float(1 - exp(-1 / (0.2 * sampleRate)))
        reducer = SpectralNoiseReducer(sampleRate: sampleRate)
        dry = UnsafeMutablePointer<Float>.allocate(capacity: SpectralNoiseReducer.hop)
        dry.initialize(repeating: 0, count: SpectralNoiseReducer.hop)
        reducer.strength = currentStrength
    }

    deinit { dry.deallocate() }

    /// The make-up gain now applied to the wet path, in dB.
    public var makeupDb: Float { 20 * log10(makeup) }

    /// Call on the processing thread only.
    public func update(_ new: NoiseReductionSettings) {
        let target = min(max(new.strength, 0), 1)
        let idle = !settings.enabled && wetMix == 0
        if new.enabled && idle {
            // Coming on from idle: the reducer holds stale audio and a stale noise estimate.
            reducer.reset()
            makeup = 1
        }
        if idle {
            currentStrength = target                 // not running, nothing to ramp
            strengthRampLeft = 0
        } else if target != currentStrength {
            strengthStep = (target - currentStrength) / Double(rampSamples)
            strengthRampLeft = rampSamples
            rampTarget = target
        }
        reducer.strength = currentStrength
        settings = new
        settings.strength = target
    }

    /// In place, any count. Returns at once, untouched, when off and faded out.
    public func process(_ buffer: UnsafeMutableBufferPointer<Float>) {
        if !settings.enabled && wetMix == 0 { return }
        guard var p = buffer.baseAddress else { return }
        var remaining = buffer.count
        while remaining > 0 {
            let count = min(remaining, hop)
            processChunk(p, count)
            p += count
            remaining -= count
        }
    }

    /// Clears the reducer and the make-up gain; keeps the settings.
    public func reset() {
        reducer.reset()
        makeup = 1
    }

    private func processChunk(_ p: UnsafeMutablePointer<Float>, _ count: Int) {
        // Strength: stepped along the ramp once per chunk (at most one hop), so the reducer sees a
        // staircase of ≤ 256-sample steps.
        if strengthRampLeft > 0 {
            let n = min(count, strengthRampLeft)
            strengthRampLeft -= n
            currentStrength = strengthRampLeft == 0 ? rampTarget : currentStrength + strengthStep * Double(n)
            reducer.strength = currentStrength
        }

        dry.update(from: p, count: count)
        reducer.process(UnsafeMutableBufferPointer(start: p, count: count))

        let limit = max(0, -SpectralNoiseReducer.floorDb(strength: currentStrength) - 6)
        let targetDb = min(max(reducer.voiceLossDb, 0), limit)
        let target = Float(pow(10, Double(targetDb) / 20))
        let mixTarget: Float = settings.enabled ? 1 : 0
        let mixStep = 1 / Float(rampSamples)
        var g = makeup, m = wetMix
        for i in 0..<count {
            g += makeupCoefficient * (target - g)
            if m < mixTarget { m = min(m + mixStep, mixTarget) } else if m > mixTarget { m = max(m - mixStep, mixTarget) }
            p[i] = dry[i] + m * (p[i] * g - dry[i])
        }
        makeup = g
        wetMix = m
    }
}
