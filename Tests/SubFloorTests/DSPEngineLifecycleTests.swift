import AVFoundation
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
                print("engine start failed in round \(round) (tolerated, no audio device): \(error)")
                engine.stop()
                return
            }
            #expect(waitForFrame(engine))
            engine.stop()
        }
    }

    /// The DSP thread feeds the audio tap that `listen` reads; a new run starts it over.
    @Test func theAudioTapHearsEachRunFromItsStart() {
        let engine = DSPEngine()
        let rx = Receiver.Config(inputRate: 2_000_000, offsetHz: 100_000, mode: .usb, bandwidthHz: 2_700)
        let origin = AudioTap.Mark(total: 0, open: 0)
        func heard(after mark: AudioTap.Mark) -> Bool {
            for _ in 0..<40 {
                Thread.sleep(forTimeInterval: 0.05)
                if engine.audioTap.mark().total > mark.total { return true }
            }
            return false
        }
        do {
            try engine.start(source: SyntheticSource(sampleRate: 2_000_000, centerFrequency: 14_100_000), receiver: rx,
                             spectrum: SpectrumSettings(), volume: 0.1)
        } catch {
            print("engine start failed (tolerated, no audio device): \(error)")
            engine.stop()
            return
        }
        #expect(heard(after: origin))
        #expect(!engine.audioTap.samples(since: origin).isEmpty)
        engine.stop()
        let firstRun = engine.audioTap.mark()
        do {
            try engine.start(source: SyntheticSource(sampleRate: 2_000_000, centerFrequency: 14_100_000), receiver: rx,
                             spectrum: SpectrumSettings(), volume: 0.1)
        } catch {
            print("engine restart failed (tolerated, no audio device): \(error)")
            engine.stop()
            return
        }
        defer { engine.stop() }
        // Only the second run's audio, however far back the mark is.
        #expect(engine.audioTap.samples(since: origin).count <= engine.audioTap.mark().total - firstRun.total)
        #expect(heard(after: firstRun))
        let now = engine.audioTap.mark()
        #expect(engine.audioTap.samples(since: origin).count <= now.total - firstRun.total)
    }

    @Test func audioRestartsAfterConfigurationChange() {
        let audio = AudioOutput()
        do { try audio.start() } catch {
            print("audio start failed (tolerated, no audio device): \(error)")
            return
        }
        defer { audio.stop() }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: audio.engine)
        #expect(audio.engine.isRunning)
        audio.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: audio.engine)
        #expect(!audio.engine.isRunning)
    }
}
