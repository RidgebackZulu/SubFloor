import DSPCore
import Foundation

/// Goertzel tone detector + adaptive threshold + timing classifier.
/// Tracks speed from element lengths; emits characters on 2-dot gaps and spaces on 5-dot gaps.
public final class CWDecoderCore {
    public var pitchHz: Double { didSet { configure() } }
    public let sampleRate: Double
    public private(set) var wpm: Double = 20
    public private(set) var level: Float = 0

    private let blockSize: Int
    private var coefficient = 0.0
    private var s1 = 0.0, s2 = 0.0, filled = 0
    private var noiseFloor = 1e-3
    private var peak = 1e-3
    private var keyDown = false
    private var runBlocks = 0
    private var dotMs = 60.0
    private var symbol = ""
    private var charPending = false
    private var wordPending = false

    public init(sampleRate: Double = 48_000, pitchHz: Double = 700) {
        self.sampleRate = sampleRate
        self.pitchHz = pitchHz
        blockSize = Int(sampleRate * 0.005)
        configure()
    }

    private func configure() { coefficient = 2 * cos(2 * .pi * pitchHz / sampleRate) }

    private var blockMs: Double { Double(blockSize) / sampleRate * 1_000 }

    public func reset() {
        s1 = 0; s2 = 0; filled = 0
        noiseFloor = 1e-3; peak = 1e-3
        keyDown = false; runBlocks = 0; dotMs = 60; wpm = 20
        symbol = ""; charPending = false; wordPending = false
    }

    /// Feeds audio and returns any newly decoded text.
    public func process(_ x: UnsafeBufferPointer<Float>) -> String {
        var out = ""
        for v in x {
            let s0 = Double(v) + coefficient * s1 - s2
            s2 = s1
            s1 = s0
            filled += 1
            if filled == blockSize {
                let power = max(0, s1 * s1 + s2 * s2 - coefficient * s1 * s2)
                step(magnitude: power.squareRoot() / Double(blockSize), out: &out)
                s1 = 0; s2 = 0; filled = 0
            }
        }
        return out
    }

    private func step(magnitude m: Double, out: inout String) {
        if m > peak { peak = m } else { peak += (m - peak) * 0.002 }
        if m < noiseFloor { noiseFloor = m } else { noiseFloor += (m - noiseFloor) * 0.002 }
        let span = peak - noiseFloor
        let threshold = noiseFloor + span * (keyDown ? 0.4 : 0.6)
        let down = m > threshold && peak > noiseFloor * 4
        level = Float(min(1, max(0, (m - noiseFloor) / max(span, 1e-12))))

        if down == keyDown {
            runBlocks += 1
            if !keyDown { checkGap(out: &out) }
            return
        }
        if keyDown { classifyMark(Double(runBlocks) * blockMs) }
        keyDown = down
        runBlocks = 1
    }

    private func classifyMark(_ ms: Double) {
        guard ms >= dotMs * 0.3 else { return }
        if ms < dotMs * 2 {
            symbol += "."
            dotMs += (ms - dotMs) * 0.3
        } else {
            symbol += "-"
            dotMs += (ms / 3 - dotMs) * 0.3
        }
        dotMs = min(max(dotMs, 20), 240)
        wpm = 1_200 / dotMs
        charPending = true
        wordPending = true
    }

    private func checkGap(out: inout String) {
        let ms = Double(runBlocks) * blockMs
        if charPending && ms > dotMs * 2 {
            if !symbol.isEmpty { out.append(MorseCode.reverse[symbol] ?? "*") }
            symbol = ""
            charPending = false
        }
        if wordPending && ms > dotMs * 5 {
            out.append(" ")
            wordPending = false
        }
    }
}
