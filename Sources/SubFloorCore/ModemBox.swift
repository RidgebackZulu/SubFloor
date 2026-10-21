import Foundation

/// A 3 kHz USB listening box. Everything is in display Hz (before any upconverter offset):
/// the box covers RF `dial + 300 … dial + 3300`, and a subcarrier's audio frequency is `RF − dial`.
public struct ModemBox: Codable, Equatable, Sendable {
    public static let audioLow = 300.0
    public static let audioHigh = 3300.0

    /// Dial (suppressed-carrier) display frequency in Hz.
    public var dialHz: Double

    public init(dialHz: Double) {
        self.dialHz = dialHz
    }

    public var lowerHz: Double { dialHz + Self.audioLow }
    public var upperHz: Double { dialHz + Self.audioHigh }
    public var centerHz: Double { dialHz + (Self.audioLow + Self.audioHigh) / 2 }

    public func audioHz(forRF rf: Double) -> Double { rf - dialHz }
    public func rfHz(forAudio audio: Double) -> Double { dialHz + audio }
    public func contains(rf: Double) -> Bool { rf >= lowerHz && rf <= upperHz }

    /// A box whose middle is at `rfCenter`.
    public static func centered(on rfCenter: Double) -> ModemBox {
        ModemBox(dialHz: rfCenter - (audioLow + audioHigh) / 2)
    }

    /// True when the whole box lies within ±45% of the capture span from the capture centre.
    public func isInside(captureCenter: Double, captureSpan: Double) -> Bool {
        let limit = 0.45 * captureSpan
        return lowerHz >= captureCenter - limit && upperHz <= captureCenter + limit
    }

    public mutating func move(byHz hz: Double) { dialHz += hz }

    /// The narrowest decode band worth running the modem for.
    public static let minimumBandHz = 50.0

    /// The box, and the audio band it decodes, for a receiver passband: the modem decodes what the
    /// receiver is tuned to.
    /// - Upper sideband: the dial is the VFO, so audio frequencies are the usual USB offsets (FT8 at
    ///   "1500 Hz" is 1500 Hz above the dial), and the band is the passband above it, within the
    ///   box's 300…3300 Hz.
    /// - Any other mode: the box covers the passband from its lower edge (its middle 3 kHz when the
    ///   passband is wider).
    ///
    /// Nil when less than `minimumBandHz` of the passband fits the box.
    public static func following(passband: ClosedRange<Double>, vfoHz: Double,
                                 upperSideband: Bool) -> (box: ModemBox, audioBand: ClosedRange<Double>)? {
        let width = audioHigh - audioLow
        let dial: Double
        if upperSideband {
            dial = vfoHz
        } else if passband.upperBound - passband.lowerBound <= width {
            dial = passband.lowerBound - audioLow
        } else {
            dial = (passband.lowerBound + passband.upperBound) / 2 - (audioLow + audioHigh) / 2
        }
        let low = max(passband.lowerBound - dial, audioLow)
        let high = min(passband.upperBound - dial, audioHigh)
        guard high - low >= minimumBandHz else { return nil }
        return (ModemBox(dialHz: dial), low...high)
    }

    /// A box whose middle is as close to `rfCenter` as keeps it inside the capture span (see
    /// `isInside`); centred on the capture when the span is too narrow for it.
    public static func centered(on rfCenter: Double, clampedToCaptureCenter captureCenter: Double,
                                span captureSpan: Double) -> ModemBox {
        let limit = 0.45 * captureSpan
        let half = (audioHigh - audioLow) / 2
        let lo = captureCenter - limit + half
        let hi = captureCenter + limit - half
        return centered(on: lo <= hi ? min(max(rfCenter, lo), hi) : captureCenter)
    }

    /// Moves the box by `hz`; a box inside the capture span stops at its edge, one outside it
    /// (after a retune) moves freely until it is back inside.
    public mutating func move(byHz hz: Double, keepingInsideCaptureCenter captureCenter: Double,
                              span captureSpan: Double) {
        guard isInside(captureCenter: captureCenter, captureSpan: captureSpan) else {
            dialHz += hz
            return
        }
        let limit = 0.45 * captureSpan
        dialHz = min(max(dialHz + hz, captureCenter - limit - Self.audioLow), captureCenter + limit - Self.audioHigh)
    }
}
