import DSPCore
import Foundation
import Modems
import Testing
@testable import SignalID
@testable import SubFloor

/// Asynchronous (start-stop) RTTY measured from its tones (`DirectFSK`), on `RTTYEncoder`'s audio: a character's 1.5
/// stop bits put its edges on a half-symbol grid, which must still read as its speed, within 1 %, not 7/7.5 of it (the
/// final review's I3). Here, beside `SignalIDDecodingTests`, because the encoder is `Modems`', which `SignalID` can't
/// depend on.
@Suite(.serialized) struct DirectFSKRTTYTests {
    static let rate = 48_000.0

    /// `DirectFSK.measure` on `RTTYEncoder`'s audio: `seconds` of `text` at `baud` and `shiftHz`, as IQ at 48 kS/s with a
    /// little noise, through the channel `measure` reads (`DirectFSK.channel`).
    static func reading(text: String, baud: Double, shiftHz: Double, seconds: Double, reverse: Bool = false) -> FSKReading? {
        let centre = 3_000.0
        let audio = RTTYEncoder.audio(text: text, centerHz: centre, baud: baud, shiftHz: shiftHz, reverse: reverse,
                                      sampleRate: rate, amplitude: 0.1, leadInSeconds: 0.2)
        let noise: Float = 0.002
        let iq = SignalIDDecodingTests.iq(audio: Array(audio.prefix(Int(seconds * rate))), shiftHz: 0, noise: noise)
        // The noise density: `noise` RMS per component, so 2 × noise² over the rate, relative to 1 per Hz.
        let noiseDb = 10 * log10(2 * Double(noise) * Double(noise) / rate)
        let tones = [centre - shiftHz / 2, centre + shiftHz / 2]
        let cut = DirectFSK.channel(iq, rate: rate, tonesHz: tones, neighboursHz: [])
        return DirectFSK.measure(cut.samples, rate: cut.rate, tonesHz: cut.tonesHz, noiseDb: noiseDb)
    }

    /// Amateur RTTY's 45.45 Bd / 170 Hz, and 75 Bd / 850 Hz, each read at its speed and shift.
    @Test(arguments: [(45.45, 170.0), (75, 850)])
    func asynchronousRTTYReadsAtItsSpeed(baud: Double, shiftHz: Double) throws {
        for reverse in [false, true] {
            let reading = try #require(Self.reading(text: SignalIDDecodingTests.weather, baud: baud, shiftHz: shiftHz,
                                                    seconds: 11, reverse: reverse))
            let measured = try #require(reading.baud, "\(baud) Bd\(reverse ? " reversed" : ""): no speed")
            #expect(abs(measured - baud) <= 0.01 * baud, "\(baud) Bd\(reverse ? " reversed" : "") read as \(measured)")
            #expect(abs((reading.shiftHz ?? 0) - shiftHz) <= 0.03 * shiftHz,
                    "\(shiftHz) Hz read as \(String(describing: reading.shiftHz))")
        }
    }
}
