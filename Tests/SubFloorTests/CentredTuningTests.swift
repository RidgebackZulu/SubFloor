import DSPCore
import Foundation
import SubFloorCore
import Testing
@testable import SubFloor

/// The Dial's knob keeps the tuning line still and slides the spectrum; clicks tune anywhere and
/// SSB's passband is drawn from the carrier.
@MainActor
struct CentredTuningTests {
    private func makeModel() -> AppModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                        defaults: UserDefaults(suiteName: UUID().uuidString)!,
                        openRSP: { throw CancellationError() }, rspOpenTimeout: .seconds(10))
    }

    /// Where the VFO sits on screen, as a fraction of the view's width.
    private func linePosition(_ m: AppModel) -> Double { m.viewport.fraction(ofHz: m.vfoHz) }

    @Test func zoomedInTheKnobPansTheViewAndKeepsTheLineCentred() {
        let m = makeModel()
        m.zoom(by: 0.1, anchor: 0.5)
        let center = m.centerHz
        for _ in 0..<20 {
            m.stepVFO(1, stepHz: 1_000)
            #expect(abs(linePosition(m) - 0.5) < 1e-6)
        }
        // A 1 kHz step never runs the view off the capture: no retune.
        #expect(m.centerHz == center)
    }

    @Test func zoomedInTheKnobRetunesWhenTheViewWouldLeaveTheCapture() {
        let m = makeModel()
        m.zoom(by: 0.2, anchor: 0.5)
        let center = m.centerHz, span = m.viewport.spanHz
        // Far enough that a view centred on the VFO runs past the capture's edge.
        let steps = Int((m.sampleRate / 2 - span / 2) / 10_000) + 5
        for _ in 0..<steps { m.stepVFO(1, stepHz: 10_000) }
        #expect(m.centerHz != center)
        #expect(abs(linePosition(m) - 0.5) < 1e-6)
        #expect(abs(m.viewport.spanHz - span) < 1)
    }

    @Test func zoomedOutTheLineStaysPutWhileTheRadioRetunes() {
        let m = makeModel()
        m.resetView()
        m.stepVFO(1, stepHz: 1_000)
        let position = linePosition(m), center = m.centerHz
        for _ in 0..<10 {
            m.stepVFO(1, stepHz: 1_000)
            #expect(abs(linePosition(m) - position) < 1e-6)
        }
        #expect(m.centerHz == center + 10_000)
        // The planner's DC offset: just right of centre.
        #expect(abs(position - (0.5 + TuningPlanner.dcOffset(sampleRate: m.sampleRate) / m.sampleRate)) < 1e-6)
    }

    @Test func theKnobDownwardsAlsoHoldsTheLine() {
        let m = makeModel()
        m.zoom(by: 0.3, anchor: 0.5)
        for _ in 0..<200 {
            m.stepVFO(-1, stepHz: 5_000)
            #expect(abs(linePosition(m) - 0.5) < 1e-6)
        }
    }

    @Test func arrowKeysStillMoveTheLine() {
        // Only the Dial centres; arrow keys keep the old behaviour (the view follows only at its edge).
        let m = makeModel()
        m.zoom(by: 0.1, anchor: 0.5)
        let before = linePosition(m)
        m.stepVFO(3)
        #expect(linePosition(m) != before)
    }

    @Test func ssbPassbandIsDrawnFromTheCarrier() {
        let m = makeModel()
        m.setMode(.usb)
        #expect(m.displayedPassband.lowerBound == m.vfoHz)
        #expect(m.displayedPassband.upperBound == m.passbandRange.upperBound)
        m.setMode(.lsb)
        #expect(m.displayedPassband.upperBound == m.vfoHz)
        #expect(m.displayedPassband.lowerBound == m.passbandRange.lowerBound)
        m.setMode(.am)
        #expect(m.displayedPassband == m.passbandRange)
    }

    @Test func ssbDragsOnlyItsFarEdge() {
        let m = makeModel()
        m.setMode(.usb)
        #expect(m.passbandEdgeFractions?.lower == nil)
        #expect(m.passbandEdgeFractions?.upper != nil)
        m.setMode(.lsb)
        #expect(m.passbandEdgeFractions?.lower != nil)
        #expect(m.passbandEdgeFractions?.upper == nil)
        m.setMode(.am)
        #expect(m.passbandEdgeFractions?.lower != nil && m.passbandEdgeFractions?.upper != nil)
    }

    @Test func spectrumFramesCarryTheCaptureCentre() {
        let store = SpectrumFrameStore()
        store.publish(average: [1, 2], peak: [3, 4], centerHz: 7_100_000)
        var a = [Float](), p = [Float]()
        let frame = store.readFrame(after: 0, average: &a, peak: &p)
        #expect(frame?.centerHz == 7_100_000)
        #expect(a == [1, 2])
        store.publish(average: [1, 2], peak: [3, 4])
        #expect(store.readFrame(after: frame!.sequence, average: &a, peak: &p)?.centerHz.isNaN == true)
    }
}
