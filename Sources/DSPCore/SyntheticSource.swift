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
    private var timer: DispatchSourceTimer?
    private var sampleIndex = 0
    private var phases: [Double]
    private var envelopes: [Float]
    private var keyPatterns: [[Bool]]
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
    }

    public func setSampleRate(_ hz: Double) { lock.withLock { _sampleRate = hz } }
    public func setCenterFrequency(_ hz: Double) throws { lock.withLock { _center = hz } }

    public func start(_ handler: @escaping @Sendable (UnsafeBufferPointer<DSPComplex>) -> Void) throws {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        t.setEventHandler { [unowned self] in
            let block = makeBlock(count: Int(sampleRate / 100))
            block.withUnsafeBufferPointer { handler($0) }
        }
        timer = t
        t.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func noise() -> Float {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        let a = Float(rng & 0xFFFF) / 65_535
        let b = Float((rng >> 16) & 0xFFFF) / 65_535
        return (a + b - 1) * noiseAmplitude
    }

    func makeBlock(count: Int) -> [DSPComplex] {
        let (fs, center) = lock.withLock { (_sampleRate, _center - _antennaOffset) }
        var block = (0..<count).map { _ in DSPComplex(real: noise(), imag: noise()) }
        for (si, signal) in signals.enumerated() {
            let offset = signal.frequency - center
            guard abs(offset) < fs / 2 else { continue }
            let w = 2 * Double.pi * offset / fs
            var phase = phases[si]
            var env = envelopes[si]
            for k in 0..<count {
                let t = Double(sampleIndex + k) / fs
                var amp = signal.amplitude
                var ph = phase
                switch signal.kind {
                case .carrier:
                    break
                case .am(let tone):
                    amp *= Float(1 + 0.6 * sin(2 * .pi * tone * t))
                case .fm(let tone, let deviation):
                    ph += deviation / tone * sin(2 * .pi * tone * t)
                case .ssbTone(let audio):
                    ph += 2 * .pi * audio * t
                case .cw(_, let wpm):
                    let pattern = keyPatterns[si]
                    let unit = Int(t / MorseCode.dotSeconds(wpm: wpm)) % pattern.count
                    env += ((pattern[unit] ? 1 : 0) - env) * 0.002
                    amp *= env
                }
                block[k].real += amp * Float(cos(ph))
                block[k].imag += amp * Float(sin(ph))
                phase += w
            }
            phases[si] = phase.truncatingRemainder(dividingBy: 2 * .pi)
            envelopes[si] = env
        }
        sampleIndex += count
        return block
    }
}
