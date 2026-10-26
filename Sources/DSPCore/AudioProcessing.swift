import Accelerate
import Foundation

public enum AGCSpeed: String, CaseIterable, Codable, Sendable {
    case off, fast, medium, slow

    public var label: String { rawValue.capitalized }

    var decaySeconds: Double? {
        switch self {
        case .off: nil
        case .fast: 0.1
        case .medium: 0.5
        case .slow: 2.0
        }
    }
}

/// Peak-envelope audio AGC. With `.off` a fixed ×10 gain is applied.
public struct AGC: Sendable {
    public var speed: AGCSpeed {
        didSet { configure() }
    }
    public var target: Float = 0.25
    public var maxGain: Float = 10_000
    private var sampleRate: Double
    private var envelope: Float = 1e-4
    private var attack: Float = 0
    private var decay: Float = 0

    public init(speed: AGCSpeed, sampleRate: Double) {
        self.speed = speed
        self.sampleRate = sampleRate
        configure()
    }

    /// Re-targets the AGC at a new speed/rate while keeping the current envelope, so a rebuild causes no gain jump.
    public mutating func reconfigure(speed newSpeed: AGCSpeed, sampleRate newRate: Double) {
        sampleRate = newRate
        speed = newSpeed   // didSet recomputes attack/decay
        configure()
    }

    private mutating func configure() {
        attack = Float(1 - exp(-1 / (0.002 * sampleRate)))
        decay = Float(exp(-1 / ((speed.decaySeconds ?? 1) * sampleRate)))
    }

    public mutating func process(_ x: inout [Float], from start: Int) {
        guard start < x.count else { return }
        guard speed != .off else {
            for k in start..<x.count { x[k] *= 10 }
            return
        }
        var env = envelope
        for k in start..<x.count {
            let a = abs(x[k])
            env = a > env ? env + attack * (a - env) : env * decay
            x[k] *= min(maxGain, target / max(env, 1e-9))
        }
        envelope = env
    }
}

/// Mean power of a complex stream over a sliding window of the last `window` samples (fewer
/// until that many have arrived), whatever size the blocks come in.
struct MovingPower: Sendable {
    private var squares: [Float]
    private var next = 0
    private var filled = 0
    private var sum = 0.0

    init(window: Int) {
        squares = [Float](repeating: 0, count: max(1, window))
    }

    mutating func add(_ x: UnsafeBufferPointer<DSPComplex>) {
        let n = squares.count
        for v in x {
            let p = v.real * v.real + v.imag * v.imag
            sum += Double(p) - Double(squares[next])
            squares[next] = p
            filled = min(filled + 1, n)
            next += 1
            if next == n {
                next = 0
                sum = squares.reduce(0) { $0 + Double($1) }   // once per window: no drift
            }
        }
    }

    var mean: Float { filled == 0 ? 0 : Float(max(sum, 0) / Double(filled)) }
}

/// Streaming linear-interpolation resampler for band-limited audio.
public struct LinearResampler: Sendable {
    public let step: Double
    private var position: Double = 0
    private var previous: Float = 0

    public init(inputRate: Double, outputRate: Double) {
        step = inputRate / outputRate
    }

    public mutating func process(_ x: UnsafeBufferPointer<Float>, into output: inout [Float]) {
        let n = x.count
        guard n > 0 else { return }
        var pos = position
        while pos < Double(n) {
            let idx = Int(pos)
            let frac = Float(pos - Double(idx))
            let a = idx == 0 ? previous : x[idx - 1]
            output.append(a + (x[idx] - a) * frac)
            pos += step
        }
        position = pos - Double(n)
        previous = x[n - 1]
    }
}
