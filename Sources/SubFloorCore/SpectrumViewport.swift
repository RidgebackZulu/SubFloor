import Foundation

/// The visible slice of the captured span. Pure view state: changing it never retunes the radio.
public struct SpectrumViewport: Equatable, Sendable {
    public private(set) var captureCenterHz: Double
    public private(set) var captureSpanHz: Double
    public private(set) var centerHz: Double
    public private(set) var spanHz: Double

    public init(captureCenterHz: Double, captureSpanHz: Double) {
        self.captureCenterHz = captureCenterHz
        self.captureSpanHz = captureSpanHz
        centerHz = captureCenterHz
        spanHz = captureSpanHz
    }

    public var minimumSpanHz: Double { max(captureSpanHz / 2_000, 200) }
    public var lowerHz: Double { centerHz - spanHz / 2 }
    public var upperHz: Double { centerHz + spanHz / 2 }
    private var captureLowerHz: Double { captureCenterHz - captureSpanHz / 2 }
    public var startFractionOfCapture: Double { (lowerHz - captureLowerHz) / captureSpanHz }
    public var widthFractionOfCapture: Double { spanHz / captureSpanHz }

    public func fraction(ofHz hz: Double) -> Double { (hz - lowerHz) / spanHz }
    public func hz(atFraction f: Double) -> Double { lowerHz + f * spanHz }

    public mutating func zoom(by factor: Double, anchorFraction: Double) {
        let anchorHz = hz(atFraction: anchorFraction)
        spanHz = min(max(spanHz * factor, minimumSpanHz), captureSpanHz)
        centerHz = anchorHz - anchorFraction * spanHz + spanHz / 2
        clamp()
    }

    public mutating func pan(byFraction f: Double) {
        centerHz += f * spanHz
        clamp()
    }

    public mutating func reset() {
        centerHz = captureCenterHz
        spanHz = captureSpanHz
    }

    public mutating func setCapture(centerHz newCenter: Double, spanHz newSpan: Double) {
        let offset = centerHz - captureCenterHz
        captureCenterHz = newCenter
        captureSpanHz = newSpan
        spanHz = min(max(spanHz, minimumSpanHz), newSpan)
        centerHz = newCenter + offset
        clamp()
    }

    public mutating func ensureVisible(_ hz: Double) {
        let margin = spanHz * 0.05
        if hz < lowerHz + margin { centerHz = hz - margin + spanHz / 2 }
        if hz > upperHz - margin { centerHz = hz + margin - spanHz / 2 }
        clamp()
    }

    private mutating func clamp() {
        let lo = captureLowerHz + spanHz / 2
        let hi = captureCenterHz + captureSpanHz / 2 - spanHz / 2
        centerHz = min(max(centerHz, lo), hi)
    }
}

public enum RulerScale {
    /// A 1/2/5 × 10ⁿ step giving roughly one label per 110 points.
    public static func step(span: Double, width: Double) -> Double {
        let target = span / max(width / 110, 1)
        let magnitude = pow(10, floor(log10(target)))
        for m in [1.0, 2, 5] where m * magnitude >= target { return m * magnitude }
        return 10 * magnitude
    }

    public static func ticks(lower: Double, upper: Double, step: Double) -> [Double] {
        Array(stride(from: (lower / step).rounded(.up) * step, through: upper, by: step))
    }

    /// MHz label with just enough decimals for `step`.
    public static func label(_ hz: Double, step: Double) -> String {
        let decimals = max(0, Int(ceil(-log10(step / 1e6) - 1e-9)))
        var s = String(format: "%.\(decimals)f", hz / 1e6)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}
