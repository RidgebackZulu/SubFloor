import Testing
@testable import SubFloorCore

private func make() -> SpectrumViewport { SpectrumViewport(captureCenterHz: 14_000_000, captureSpanHz: 2_000_000) }

@Test func startsShowingFullCapture() {
    let v = make()
    #expect(v.lowerHz == 13_000_000 && v.upperHz == 15_000_000)
    #expect(v.startFractionOfCapture == 0 && v.widthFractionOfCapture == 1)
}

@Test func zoomKeepsAnchorFrequencyUnderCursor() {
    var v = make()
    let anchor = v.hz(atFraction: 0.25)
    v.zoom(by: 0.5, anchorFraction: 0.25)
    #expect(v.spanHz == 1_000_000)
    #expect(abs(v.hz(atFraction: 0.25) - anchor) < 1e-6)
}

@Test func zoomAndPanAreClampedToCapture() {
    var v = make()
    v.zoom(by: 10, anchorFraction: 0.5)
    #expect(v.spanHz == 2_000_000)
    v.zoom(by: 1e-9, anchorFraction: 0.5)
    #expect(v.spanHz == v.minimumSpanHz)
    v.zoom(by: 100_000, anchorFraction: 0.5)
    v.zoom(by: 0.1, anchorFraction: 0.5)
    v.pan(byFraction: 100)
    #expect(v.upperHz == 15_000_000)
    v.pan(byFraction: -100)
    #expect(v.lowerHz == 13_000_000)
}

@Test func recaptureKeepsSpanAndEnsuresVisibility() {
    var v = make()
    v.zoom(by: 0.1, anchorFraction: 0.5)
    v.setCapture(centerHz: 20_000_000, spanHz: 2_000_000)
    #expect(v.spanHz == 200_000)
    #expect(v.lowerHz >= 19_000_000 && v.upperHz <= 21_000_000)
    v.ensureVisible(20_900_000)
    #expect(v.lowerHz <= 20_900_000 && v.upperHz >= 20_900_000)
}

/// A bookmark retune: the new capture at the same span, centred on the VFO (clamped to the capture).
@Test func centerKeepsSpan() {
    var v = make()
    v.zoom(by: 0.05, anchorFraction: 0.2)
    v.setCapture(centerHz: 7_200_000, spanHz: 2_000_000)
    v.center(on: 7_074_000)
    #expect(v.spanHz == 100_000)
    #expect(abs(v.centerHz - 7_074_000) < 1e-6)
    v.center(on: 6_200_000)
    #expect(v.spanHz == 100_000 && v.lowerHz == 6_200_000)
}

@Test func rulerScaleChoosesNiceSteps() {
    #expect(RulerScale.step(span: 2_000_000, width: 1_100) == 200_000)
    #expect(RulerScale.step(span: 10_000, width: 1_100) == 1_000)
    #expect(RulerScale.ticks(lower: 14_010_000, upper: 14_050_000, step: 20_000) == [14_020_000, 14_040_000])
    #expect(RulerScale.label(14_200_000, step: 200_000) == "14.2")
    #expect(RulerScale.label(14_074_000, step: 1_000) == "14.074")
}
