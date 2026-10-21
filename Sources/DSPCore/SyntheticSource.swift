import Accelerate
import Foundation

/// Generates a band of test signals in real time, so the app works without hardware.
/// Signal frequencies are antenna frequencies; `antennaOffset` models an upconverter LO.
public final class SyntheticSource: IQSource, @unchecked Sendable {
    public struct Signal: Sendable {
        public enum Kind: Sendable {
            case carrier
            case am(toneHz: Double)
            case fm(toneHz: Double, deviation: Double)
            case ssbTone(audioHz: Double)
            case cw(text: String, wpm: Double)
        }
        public var frequency: Double
        public var amplitude: Float
        public var kind: Kind
        public init(frequency: Double, amplitude: Float, kind: Kind) {
            self.frequency = frequency
            self.amplitude = amplitude
            self.kind = kind
        }
    }

    public static let demoSignals: [Signal] = [
        .init(frequency: 14_030_000, amplitude: 0.02, kind: .cw(text: "CQ CQ DE SUBFLOOR K", wpm: 20)),
        .init(frequency: 14_074_000 + 1_500, amplitude: 0.004, kind: .carrier),
        .init(frequency: 14_200_000, amplitude: 0.01, kind: .ssbTone(audioHz: 1_000)),
        .init(frequency: 13_650_000, amplitude: 0.05, kind: .am(toneHz: 600)),
        .init(frequency: 14_500_000, amplitude: 0.02, kind: .fm(toneHz: 1_000, deviation: 3_000)),
        .init(frequency: 10_000_000, amplitude: 0.05, kind: .am(toneHz: 1_000)),
        .init(frequency: 7_200_000, amplitude: 0.01, kind: .ssbTone(audioHz: -800)),
        .init(frequency: 144_390_000, amplitude: 0.03, kind: .fm(toneHz: 1_200, deviation: 3_500)),
        .init(frequency: 98_100_000, amplitude: 0.1, kind: .fm(toneHz: 440, deviation: 60_000)),
    ]

    public let name = "Demo signal"
    public var noiseAmplitude: Float = 0.001
    public var antennaOffset: Double {
        get { lock.withLock { _antennaOffset } }
        set { lock.withLock { _antennaOffset = newValue } }
    }
    public var sampleRate: Double { lock.withLock { _sampleRate } }
    public var centerFrequency: Double { lock.withLock { _center } }

    private let signals: [Signal]
    private let lock = NSLock()
    private var _sampleRate: Double
    private var _center: Double
    private var _antennaOffset: Double = 0
    private let queue = DispatchQueue(label: "subfloor.synthetic", qos: .userInteractive)
    private var timer: DispatchSourceTimer?   // guarded by `lock`
    private var sampleIndex = 0
    private var phases: [Double]
    private var envelopes: [Float]
    private var keyPatterns: [[Bool]]
    /// Per FM signal, `e^{iβs}` sampled over s ∈ [−1, 1] (β = deviation / tone), for linear
    /// interpolation; empty for other kinds.
    private var fmTables: [[(re: Double, im: Double)]]
    private var rng: UInt64 = 0x9E37_79B9_7F4A_7C15

    public init(sampleRate: Double = 2_000_000, centerFrequency: Double = 14_100_000, signals: [Signal] = demoSignals) {
        _sampleRate = sampleRate
        _center = centerFrequency
        self.signals = signals
        phases = .init(repeating: 0, count: signals.count)
        envelopes = .init(repeating: 0, count: signals.count)
        keyPatterns = signals.map { signal in
            guard case .cw(let text, _) = signal.kind else { return [] }
            var units: [Bool] = []
            for e in MorseCode.timeline(for: text) { units += Array(repeating: e.on, count: e.units) }
            return units + Array(repeating: false, count: 21)   // 3-word gap before repeating
        }
        fmTables = signals.map { signal in
            guard case .fm(let tone, let deviation) = signal.kind, tone > 0 else { return [] }
            let beta = deviation / tone
            // Spacing in phase β·Δs ≤ 0.02 rad: interpolation error about 5e-5 of the amplitude.
            let n = max(1_024, Int((2 * beta / 0.02).rounded(.up)))
            return (0...n).map { i in
                let phase = beta * (2 * Double(i) / Double(n) - 1)
                return (cos(phase), sin(phase))
            }
        }
    }

    public func setSampleRate(_ hz: Double) { lock.withLock { _sampleRate = hz } }
    public func setCenterFrequency(_ hz: Double) throws { lock.withLock { _center = hz } }

    public func start(_ handler: @escaping @Sendable (UnsafeBufferPointer<DSPComplex>) -> Void) throws {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let block = self.makeBlock(count: Int(self.sampleRate / 100))
            block.withUnsafeBufferPointer { handler($0) }
        }
        lock.withLock { timer = t }
        t.resume()
    }

    /// Hard barrier: when this returns, no handler is running or will run again.
    /// Must not be called from the source's own queue (the `queue.sync` below would deadlock).
    public func stop() {
        let old = lock.withLock { () -> DispatchSourceTimer? in
            let t = timer
            timer = nil
            return t
        }
        old?.cancel()
        queue.sync {}   // lock is not held here
    }

    deinit { timer?.cancel() }

    private func noise() -> Float {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        let a = Float(rng & 0xFFFF) / 65_535
        let b = Float((rng >> 16) & 0xFFFF) / 65_535
        return (a + b - 1) * noiseAmplitude
    }

    /// The next `count` samples. Each signal is a rotating phasor (one complex multiply per sample),
    /// re-seeded from its exact phase at every block so nothing drifts; the modulation tones are
    /// phasors too, and FM's `e^{iβ·sin θ}` comes from a table. Matches the direct per-sample
    /// `cos`/`sin` formula to Float rounding (about 1e-7 of the amplitude; FM, through its table, about
    /// 5e-5 at broadcast deviation; see the tests).
    func makeBlock(count: Int) -> [DSPComplex] {
        let (fs, center) = lock.withLock { (_sampleRate, _center - _antennaOffset) }
        var block = (0..<count).map { _ in DSPComplex(real: noise(), imag: noise()) }
        let t0 = Double(sampleIndex) / fs
        block.withUnsafeMutableBufferPointer { out in
            for (si, signal) in signals.enumerated() {
                let offset = signal.frequency - center
                guard abs(offset) < fs / 2 else { continue }
                let w = 2 * Double.pi * offset / fs
                let phase = phases[si]
                var env = envelopes[si]
                // The carrier (with SSB's audio offset folded in) and the modulating tone, at t0.
                var carrierPhase = phase, step = w
                var tone = (re: 1.0, im: 0.0), toneStep = (re: 1.0, im: 0.0)
                switch signal.kind {
                case .ssbTone(let audio):
                    carrierPhase += 2 * .pi * audio * t0
                    step += 2 * .pi * audio / fs
                case .am(let hz), .fm(let hz, _):
                    tone = (cos(2 * .pi * hz * t0), sin(2 * .pi * hz * t0))
                    toneStep = (cos(2 * .pi * hz / fs), sin(2 * .pi * hz / fs))
                case .carrier, .cw:
                    break
                }
                var c = (re: cos(carrierPhase), im: sin(carrierPhase))
                let r = (re: cos(step), im: sin(step))
                let amplitude = signal.amplitude
                // One tight loop per kind: the kind, its tables and constants are fixed for the block.
                switch signal.kind {
                case .carrier, .ssbTone:
                    for k in 0..<count {
                        out[k].real += amplitude * Float(c.re)
                        out[k].imag += amplitude * Float(c.im)
                        c = (c.re * r.re - c.im * r.im, c.re * r.im + c.im * r.re)
                    }
                case .am:
                    for k in 0..<count {
                        let amp = amplitude * Float(1 + 0.6 * tone.im)
                        out[k].real += amp * Float(c.re)
                        out[k].imag += amp * Float(c.im)
                        c = (c.re * r.re - c.im * r.im, c.re * r.im + c.im * r.re)
                        tone = (tone.re * toneStep.re - tone.im * toneStep.im, tone.re * toneStep.im + tone.im * toneStep.re)
                    }
                case .fm:
                    // e^{iβ·sin θ} by linear interpolation in the table over sin θ ∈ [−1, 1].
                    let table = fmTables[si]
                    let last = table.count - 1
                    let scale = Double(last) / 2
                    for k in 0..<count {
                        let x = (min(max(tone.im, -1), 1) + 1) * scale
                        let i = min(Int(x), last - 1)
                        let f = x - Double(i)
                        let a = table[i], b = table[i + 1]
                        let m = (re: a.re + f * (b.re - a.re), im: a.im + f * (b.im - a.im))
                        out[k].real += amplitude * Float(c.re * m.re - c.im * m.im)
                        out[k].imag += amplitude * Float(c.re * m.im + c.im * m.re)
                        c = (c.re * r.re - c.im * r.im, c.re * r.im + c.im * r.re)
                        tone = (tone.re * toneStep.re - tone.im * toneStep.im, tone.re * toneStep.im + tone.im * toneStep.re)
                    }
                case .cw(_, let wpm):
                    let pattern = keyPatterns[si]
                    let dot = MorseCode.dotSeconds(wpm: wpm)
                    // The Morse unit of sample n is `Int(n / fs / dot)`; it changes only every dot
                    // (about 1200 samples), so it is evaluated at its boundaries, with the same formula.
                    let unitAt = { (n: Int) in Int(Double(n) / fs / dot) }
                    let boundary = { (unit: Int) -> Int in   // the first sample of the next unit
                        var b = Int(Double(unit + 1) * fs * dot)
                        while b > 0 && unitAt(b - 1) > unit { b -= 1 }
                        while unitAt(b) <= unit { b += 1 }
                        return b
                    }
                    let first = sampleIndex
                    var unit = unitAt(first)
                    var next = boundary(unit) - first   // as an index into this block
                    var key: Float = pattern[unit % pattern.count] ? 1 : 0
                    for k in 0..<count {
                        if k == next {
                            unit = unitAt(first + k)
                            next = boundary(unit) - first
                            key = pattern[unit % pattern.count] ? 1 : 0
                        }
                        env += (key - env) * 0.002
                        // Key-up decays towards 0; stop at 1e-7 rather than run into subnormal floats
                        // (slow on x86; the difference is far below the noise).
                        if env < 1e-7 { env = 0 }
                        let amp = amplitude * env
                        out[k].real += amp * Float(c.re)
                        out[k].imag += amp * Float(c.im)
                        c = (c.re * r.re - c.im * r.im, c.re * r.im + c.im * r.re)
                    }
                }
                phases[si] = (phase + w * Double(count)).truncatingRemainder(dividingBy: 2 * .pi)
                envelopes[si] = env
            }
        }
        sampleIndex += count
        return block
    }
}
