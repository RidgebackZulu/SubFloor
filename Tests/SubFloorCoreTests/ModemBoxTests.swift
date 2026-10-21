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

        // Boundaries at +-0.45 x span: the box edge on the limit is inside, 1 Hz further out is not.
        let limit = 0.45 * span
        let upperLimit = ModemBox(dialHz: centre + limit - ModemBox.audioHigh)
        #expect(upperLimit.isInside(captureCenter: centre, captureSpan: span))
        var justOutsideHigh = upperLimit
        justOutsideHigh.move(byHz: 1)
        #expect(!justOutsideHigh.isInside(captureCenter: centre, captureSpan: span))
        let lowerLimit = ModemBox(dialHz: centre - limit - ModemBox.audioLow)
        #expect(lowerLimit.isInside(captureCenter: centre, captureSpan: span))
        var justOutsideLow = lowerLimit
        justOutsideLow.move(byHz: -1)
        #expect(!justOutsideLow.isInside(captureCenter: centre, captureSpan: span))
    }

    @Test func upconverterLeavesDisplayMathsUnchanged() {
        let box = ModemBox(dialHz: 14_070_000)
        let up = Upconverter(enabled: true)
        #expect(up.hardware(fromDisplay: box.lowerHz) == box.lowerHz + 125_000_000)
        #expect(up.display(fromHardware: up.hardware(fromDisplay: box.lowerHz)) == box.lowerHz)
    }

    @Test func centeredClampedToCapture() {
        let centre = 14_000_000.0, span = 2_000_000.0
        let free = ModemBox.centered(on: 14_250_000, clampedToCaptureCenter: centre, span: span)
        #expect(free.centerHz == 14_250_000)
        let high = ModemBox.centered(on: 14_999_000, clampedToCaptureCenter: centre, span: span)
        #expect(high.upperHz == centre + 0.45 * span)
        #expect(high.isInside(captureCenter: centre, captureSpan: span))
        let low = ModemBox.centered(on: 12_000_000, clampedToCaptureCenter: centre, span: span)
        #expect(low.lowerHz == centre - 0.45 * span)
        #expect(low.isInside(captureCenter: centre, captureSpan: span))
        // A span too narrow for the box: centred on the capture.
        let tiny = ModemBox.centered(on: 14_100_000, clampedToCaptureCenter: centre, span: 2_000)
        #expect(tiny.centerHz == centre)
    }

    @Test func moveKeepsAnInsideBoxInside() {
        let centre = 14_000_000.0, span = 2_000_000.0
        var box = ModemBox.centered(on: centre)
        box.move(byHz: 1_000, keepingInsideCaptureCenter: centre, span: span)
        #expect(box.centerHz == centre + 1_000)
        box.move(byHz: 5_000_000, keepingInsideCaptureCenter: centre, span: span)
        #expect(box.upperHz == centre + 0.45 * span)
        box.move(byHz: -5_000_000, keepingInsideCaptureCenter: centre, span: span)
        #expect(box.lowerHz == centre - 0.45 * span)

        // Outside already (after a retune): it moves freely, and is held once it is back inside.
        var outside = ModemBox(dialHz: 16_000_000)
        outside.move(byHz: -100_000, keepingInsideCaptureCenter: centre, span: span)
        #expect(outside.dialHz == 15_900_000)
        outside.move(byHz: -1_100_000, keepingInsideCaptureCenter: centre, span: span)
        #expect(outside.dialHz == 14_800_000)
        #expect(outside.isInside(captureCenter: centre, captureSpan: span))
        outside.move(byHz: 500_000, keepingInsideCaptureCenter: centre, span: span)
        #expect(outside.upperHz == centre + 0.45 * span)
    }
}

// MARK: - Following the receiver's passband

@Test func upperSidebandDialIsTheVFOAndTheBandIsThePassbandAboveIt() throws {
    // USB, 2.7 kHz: the passband is VFO+100 … VFO+2800.
    let f = try #require(ModemBox.following(passband: 14_074_100...14_076_800, vfoHz: 14_074_000, upperSideband: true))
    #expect(f.box.dialHz == 14_074_000)
    #expect(f.audioBand == 300...2_800, "the box carries 300 Hz and up")
    // Wider than the box: clipped to it.
    let wide = try #require(ModemBox.following(passband: 14_074_100...14_078_100, vfoHz: 14_074_000, upperSideband: true))
    #expect(wide.audioBand == 300...3_300)
}

@Test func otherModesCoverThePassbandFromItsLowerEdge() throws {
    // LSB 2.4 kHz below the VFO, CW 500 Hz around it: the band starts at 300 Hz.
    let lsb = try #require(ModemBox.following(passband: 7_071_500...7_073_900, vfoHz: 7_074_000, upperSideband: false))
    #expect(lsb.box.dialHz == 7_071_200)
    #expect(lsb.audioBand == 300...2_700)
    #expect(lsb.box.rfHz(forAudio: lsb.audioBand.lowerBound) == 7_071_500)
    let cw = try #require(ModemBox.following(passband: 14_029_750...14_030_250, vfoHz: 14_030_000, upperSideband: false))
    #expect(cw.audioBand == 300...800)
    // AM 10 kHz: its middle 3 kHz.
    let am = try #require(ModemBox.following(passband: 9_995_000...10_005_000, vfoHz: 10_000_000, upperSideband: false))
    #expect(am.audioBand == 300...3_300)
    #expect(am.box.centerHz == 10_000_000)
}

@Test func nothingToDecodeIsNil() {
    // USB with the passband below 300 Hz above the dial (narrow, 100…250 Hz).
    #expect(ModemBox.following(passband: 14_074_100...14_074_250, vfoHz: 14_074_000, upperSideband: true) == nil)
    // Just under the minimum band.
    #expect(ModemBox.following(passband: 14_074_100...14_074_349, vfoHz: 14_074_000, upperSideband: true) == nil)
    #expect(ModemBox.following(passband: 14_074_100...14_074_350, vfoHz: 14_074_000, upperSideband: true) != nil)
}
