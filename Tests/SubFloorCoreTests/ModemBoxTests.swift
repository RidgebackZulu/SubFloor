import Testing
@testable import SubFloorCore

@Suite struct ModemBoxTests {
    @Test func edgesAndMapping() {
        let box = ModemBox(dialHz: 14_070_000)
        #expect(box.lowerHz == 14_070_300)
        #expect(box.upperHz == 14_073_300)
        #expect(box.audioHz(forRF: 14_071_520) == 1_520)
        #expect(box.rfHz(forAudio: box.audioHz(forRF: 14_071_520)) == 14_071_520)
        #expect(box.contains(rf: 14_071_000))
        #expect(!box.contains(rf: 14_070_299))
        #expect(!box.contains(rf: 14_073_301))
    }

    @Test func centeredOnPlacesMiddle() {
        let box = ModemBox.centered(on: 14_072_000)
        #expect(box.centerHz == 14_072_000)
        #expect(box.dialHz == 14_070_200)
    }

    @Test func insideCapture() {
        let span = 2_000_000.0
        let centre = 14_000_000.0
        let box = ModemBox.centered(on: centre)
        #expect(box.isInside(captureCenter: centre, captureSpan: span))
        var moved = box
        moved.move(byHz: 0.46 * span)
        #expect(!moved.isInside(captureCenter: centre, captureSpan: span))
    }

    @Test func upconverterLeavesDisplayMathsUnchanged() {
        let box = ModemBox(dialHz: 14_070_000)
        let up = Upconverter(enabled: true)
        #expect(up.hardware(fromDisplay: box.lowerHz) == box.lowerHz + 125_000_000)
        #expect(up.display(fromHardware: up.hardware(fromDisplay: box.lowerHz)) == box.lowerHz)
    }
}
