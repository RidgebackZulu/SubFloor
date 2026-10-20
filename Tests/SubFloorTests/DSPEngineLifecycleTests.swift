import DSPCore
import Foundation
import Testing
@testable import SubFloor

@Suite(.serialized) struct DSPEngineLifecycleTests {
    private func waitForFrame(_ engine: DSPEngine) -> Bool {
        var a = [Float](), p = [Float]()
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.05)
            if engine.frames.read(after: 0, average: &a, peak: &p) != nil { return true }
        }
        return false
    }

    @Test func startStopRestartProducesFrames() {
        let engine = DSPEngine()
        let rx = Receiver.Config(inputRate: 2_000_000, offsetHz: 100_000, mode: .usb, bandwidthHz: 2_700)
        for round in 1...2 {
            let source = SyntheticSource(sampleRate: 2_000_000, centerFrequency: 14_100_000)
            do {
                try engine.start(source: source, receiver: rx, spectrum: SpectrumSettings(), volume: 0.1)
            } catch {
                // No usable audio device in this process: start must have cleaned up.
                Issue.record("engine start failed in round \(round) (tolerated): \(error)")
                engine.stop()
                return
            }
            #expect(waitForFrame(engine))
            engine.stop()
        }
    }
}
