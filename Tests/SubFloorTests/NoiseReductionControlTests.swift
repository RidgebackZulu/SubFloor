import Accelerate
import DSPCore
import Foundation
import Recording
import SubFloorCore
import Synchronization
import Testing
@testable import SubFloor

/// Noise reduction on the live radio: the setting is saved with the session, follows the mode, and
/// reaches the speakers (and only the speakers) through the DSP engine.
@MainActor
@Suite(.serialized)
struct NoiseReductionControlTests {
    private func makeModel(defaults: UserDefaults? = nil, dir: URL? = nil) -> (AppModel, URL) {
        let dir = dir ?? FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorNRTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                         defaults: defaults ?? UserDefaults(suiteName: UUID().uuidString)!)
        m.recording.folderPath = dir.appendingPathComponent("rec").path
        return (m, dir)
    }

    // MARK: Model

    @Test func noiseReductionIsSavedAndRestored() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let (m, dir) = makeModel(defaults: defaults)
        m.noiseReduction = NoiseReductionSettings(enabled: true, strength: 0.8)
        m.shutdown()   // saves the session
        let (again, _) = makeModel(defaults: defaults, dir: dir)
        defer { again.shutdown() }
        #expect(again.noiseReduction == NoiseReductionSettings(enabled: true, strength: 0.8))
        #expect(again.noiseReductionAvailable)
    }

    @Test func skipSilenceIsSavedAndStartsOn() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let (m, dir) = makeModel(defaults: defaults)
        #expect(m.skipSilence)
        m.skipSilence = false
        m.shutdown()
        let (again, _) = makeModel(defaults: defaults, dir: dir)
        defer { again.shutdown() }
        #expect(!again.skipSilence)
        #expect(!again.player.skipSilence)
    }

    @Test func olderSessionsStartWithSkipSilenceOn() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let (m, dir) = makeModel(defaults: defaults)
        m.skipSilence = false
        m.shutdown()
        let saved = try #require(defaults.data(forKey: "session"))
        var session = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(session["skipSilence"] != nil)
        session["skipSilence"] = nil
        defaults.set(try JSONSerialization.data(withJSONObject: session), forKey: "session")
        let (again, _) = makeModel(defaults: defaults, dir: dir)
        defer { again.shutdown() }
        #expect(again.skipSilence)
    }

    @Test func olderSessionsStartWithNROffAtMedium() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let (m, dir) = makeModel(defaults: defaults)
        m.noiseReduction = NoiseReductionSettings(enabled: true, strength: 0.9)
        m.shutdown()
        // As an older SubFloor would have saved it.
        let saved = try #require(defaults.data(forKey: "session"))
        var session = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(session["noiseReduction"] != nil)
        session["noiseReduction"] = nil
        defaults.set(try JSONSerialization.data(withJSONObject: session), forKey: "session")
        let (again, _) = makeModel(defaults: defaults, dir: dir)
        defer { again.shutdown() }
        #expect(again.noiseReduction.enabled == false)
        #expect(again.noiseReduction.strength == 0.5)
    }

    @Test func wfmMakesItUnavailableButKeepsTheSetting() {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        m.setMode(.usb)
        m.noiseReduction = NoiseReductionSettings(enabled: true, strength: 0.7)
        #expect(m.noiseReductionAvailable)
        m.setMode(.wfm)
        #expect(!m.noiseReductionAvailable)
        #expect(m.noiseReduction.enabled)
        m.toggleNoiseReduction()   // nothing to toggle in WFM
        #expect(m.noiseReduction.enabled)
        m.setMode(.usb)
        #expect(m.noiseReductionAvailable)
        #expect(m.noiseReduction == NoiseReductionSettings(enabled: true, strength: 0.7))
        m.toggleNoiseReduction()
        #expect(!m.noiseReduction.enabled)
        #expect(m.noiseReduction.strength == 0.7)
    }

    /// The engine is sent the setting as the user made it, not masked by the mode, so it applies the
    /// setting again whenever the mode changes: here through a bookmark, which does not go through
    /// `setMode`.
    @Test func aBookmarkJumpOutOfWFMKeepsTheSettingTheEngineHas() {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        m.setMode(.usb)
        m.noiseReduction = NoiseReductionSettings(enabled: true, strength: 0.6)
        m.setMode(.wfm)
        #expect(!m.noiseReductionAvailable)
        #expect(m.engine.noiseReductionRequest == NoiseReductionSettings(enabled: true, strength: 0.6),
                "the engine keeps the user's setting in WFM and gates it itself")
        m.select(Bookmark(name: "20 m", frequencyHz: 14_200_000, mode: .usb, bandwidthHz: 2_700))
        #expect(m.mode == .usb)
        #expect(m.noiseReductionAvailable)
        #expect(m.noiseReduction.enabled)
        #expect(m.engine.noiseReductionRequest == NoiseReductionSettings(enabled: true, strength: 0.6))
    }

    // MARK: Engine

    @Test func theEngineGetsTheEffectiveSetting() throws {
        let strong = NoiseReductionSettings(enabled: true, strength: 1)
        let off = try run(mode: .usb, noiseReduction: NoiseReductionSettings())
        let on = try run(mode: .usb, noiseReduction: strong)
        let (a, b) = aligned(off.speaker, on.speaker)
        #expect(a.count > 24_000, "captured \(a.count) samples")
        #expect(maxDifference(a, b) > 0.01, "NR on in USB changes the speaker audio")

        let wfmOff = try run(mode: .wfm, noiseReduction: NoiseReductionSettings())
        let wfmOn = try run(mode: .wfm, noiseReduction: strong)
        let (c, d) = aligned(wfmOff.speaker, wfmOn.speaker)
        #expect(c.count > 24_000, "captured \(c.count) samples")
        // Not bit-for-bit: the WFM demodulator's float rounding shifts by ~1e-8 with how the IQ is cut
        // into blocks. NR would move it by ~0.3 (checked by removing the engine's mode gate).
        #expect(maxDifference(c, d) < 1e-4, "NR on in WFM is the same as off")
    }

    @Test func recordingsDoNotGetNR() throws {
        let off = try run(mode: .usb, noiseReduction: NoiseReductionSettings(), recordAudio: true)
        let on = try run(mode: .usb, noiseReduction: NoiseReductionSettings(enabled: true, strength: 1), recordAudio: true)
        let (a, b) = aligned(off.recorded, on.recorded)
        #expect(a.count > 24_000, "recorded \(a.count) samples")
        #expect(maxDifference(a, b) < 1e-4, "the recorder has the audio as heard")
        let (s, t) = aligned(off.speaker, on.speaker)
        #expect(maxDifference(s, t) > 0.01, "and NR was running on the speakers")
    }

    /// A retune or a bandwidth change (a passband drag sends one every few ms) leaves the reducer
    /// running on what it has learnt; only a new mode resets it. A reset fades NR out and back and
    /// restarts the noise estimate, so resetting on bandwidth would leave a drag's hiss unreduced.
    @Test func onlyAModeChangeResetsTheReducer() throws {
        let sink = CaptureSink()
        let engine = DSPEngine(audioSink: sink)
        engine.update(noiseReduction: NoiseReductionSettings(enabled: true, strength: 0.5))
        let rx = Receiver.Config(inputRate: 250_000, offsetHz: 0, mode: .usb, bandwidthHz: 2_700)
        do {
            try engine.start(source: ToneInNoiseSource(), receiver: rx, spectrum: SpectrumSettings(fftSize: 2_048), volume: 0.5)
        } catch {
            print("engine start failed (tolerated, no audio device): \(error)")
            engine.stop()
            return
        }
        defer { engine.stop() }
        func resets() -> Int { engine.noiseReducerResets.load(ordering: .relaxed) }
        /// Waits until the DSP thread has pushed `blocks` more blocks (480 samples each), so a
        /// change made before it has been taken.
        func runOn(_ blocks: Int) -> Bool {
            let target = sink.count + blocks * 480
            return waitUntil(30) { sink.count >= target }
        }
        #expect(runOn(10))

        var changed = rx
        changed.offsetHz = 1_000                 // retune
        engine.update(receiver: changed)
        #expect(runOn(10))
        changed.bandwidthHz = 2_400              // a bandwidth step
        engine.update(receiver: changed)
        #expect(runOn(10))
        for hz in stride(from: 2_350.0, through: 1_800, by: -50) {   // a drag
            changed.bandwidthHz = hz
            engine.update(receiver: changed)
            #expect(runOn(1))
        }
        #expect(runOn(10))
        #expect(resets() == 0, "a retune or bandwidth change reset the reducer \(resets()) times")

        changed.mode = .lsb
        engine.update(receiver: changed)
        #expect(waitUntil(30) { resets() > 0 })
        #expect(resets() == 1, "a mode change resets it once")
    }

    // MARK: Harness

    private struct Captured {
        var speaker: [Float]
        var recorded: [Float]
    }

    /// Runs the engine on the same IQ (a tone in noise) and returns what reached the speakers, and
    /// what the audio recorder wrote when `recordAudio`.
    private func run(mode: DemodMode, noiseReduction: NoiseReductionSettings, recordAudio: Bool = false) throws -> Captured {
        let sink = CaptureSink()
        let engine = DSPEngine(audioSink: sink)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorNREngine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        if recordAudio {
            engine.audioRecorder.configure(StreamRecorder.Setup(
                sampleRate: Receiver.audioRate, channels: StreamKind.audio.channels, fileFormat: .wav, sampleFormat: .float32,
                preRollSeconds: 30, memoryLimitBytes: 64 << 20, folder: folder))
            engine.audioRecorder.setContext(RecordingContext(frequencyHz: 7_100_000, label: "Test", hardware: "Test"))
        }
        engine.update(noiseReduction: noiseReduction)   // before start: start begins with it
        let rx = Receiver.Config(inputRate: 250_000, offsetHz: 0, mode: mode, bandwidthHz: mode.defaultBandwidth)
        do {
            try engine.start(source: ToneInNoiseSource(), receiver: rx, spectrum: SpectrumSettings(fftSize: 2_048), volume: 0.5)
        } catch {
            print("engine start failed (tolerated, no audio device): \(error)")
            engine.stop()
            return Captured(speaker: [], recorded: [])
        }
        if recordAudio { engine.audioRecorder.start() }
        // The source delivers 2 s of IQ and then goes quiet: the audio is what that makes.
        let arrived = waitUntil(30) { sink.count >= 80_000 }
        engine.stop()
        #expect(arrived, "the engine produced \(sink.count) samples")
        return Captured(speaker: sink.samples, recorded: recordAudio ? try readFloatWAV(in: folder) : [])
    }

    private func waitUntil(_ timeout: Double, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() {
            if Date() >= end { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    /// The first `n` samples of both, `n` the shorter length (capped, as the runs differ in how much
    /// they got to before they were stopped).
    private func aligned(_ a: [Float], _ b: [Float]) -> ([Float], [Float]) {
        let n = min(a.count, b.count, 80_000)
        return (Array(a.prefix(n)), Array(b.prefix(n)))
    }

    private func maxDifference(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }

    /// The samples of the (only) mono 32-bit float WAV in `folder`.
    private func readFloatWAV(in folder: URL) throws -> [Float] {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "wav" }
        let url = try #require(files.first, "a WAV was written")
        let data = try Data(contentsOf: url)
        var i = 12   // past RIFF....WAVE
        while i + 8 <= data.count {
            let id = String(decoding: data[i..<(i + 4)], as: UTF8.self)
            let size = data[(i + 4)..<(i + 8)].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            if id == "data" {
                let end = min(data.count, i + 8 + size)
                let bytes = data[(i + 8)..<end]
                return (0..<(bytes.count / 4)).map { k in
                    let o = bytes.startIndex + k * 4
                    let bits = UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
                    return Float(bitPattern: bits)
                }
            }
            i += 8 + size + (size & 1)
        }
        Issue.record("no data chunk in \(url.lastPathComponent)")
        return []
    }
}

/// Keeps every sample pushed to the speakers.
private final class CaptureSink: AudioSink, @unchecked Sendable {
    private let store = Mutex<[Float]>([])
    func push(_ samples: UnsafeBufferPointer<Float>) { store.withLock { $0.append(contentsOf: samples) } }
    var samples: [Float] { store.withLock { $0 } }
    var count: Int { store.withLock { $0.count } }
}

/// The same IQ every time: a tone 1.5 kHz above the tuned frequency in white noise, 2 s of it in
/// 10 ms blocks, then quiet.
private final class ToneInNoiseSource: IQSource, @unchecked Sendable {
    let name = "Tone in noise"
    let sampleRate = 250_000.0
    let centerFrequency = 7_100_000.0
    private let running = Atomic<Bool>(false)
    private var done: DispatchSemaphore?

    func start(_ handler: @escaping @Sendable (UnsafeBufferPointer<DSPComplex>) -> Void) throws {
        stop()
        running.store(true, ordering: .releasing)
        let finished = DispatchSemaphore(value: 0)
        done = finished
        let rate = sampleRate
        Thread { [self] in
            var state: UInt64 = 42
            func gauss() -> Float {
                func next() -> Double {
                    state &+= 0x9E37_79B9_7F4A_7C15
                    var z = state
                    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                    z ^= z >> 31
                    return (Double(z >> 11) + 0.5) / Double(1 << 53)
                }
                return Float((-2 * log(next())).squareRoot() * cos(2 * .pi * next()))
            }
            let blockSize = 2_500, blocks = 200
            var n = 0
            var block = [DSPComplex](repeating: DSPComplex(real: 0, imag: 0), count: blockSize)
            for _ in 0..<blocks {
                guard running.load(ordering: .acquiring) else { break }
                for i in 0..<blockSize {
                    let phase = 2 * Double.pi * 1_500 * Double(n + i) / rate
                    block[i] = DSPComplex(real: 0.02 * Float(cos(phase)) + 0.01 * gauss(), imag: 0.02 * Float(sin(phase)) + 0.01 * gauss())
                }
                n += blockSize
                block.withUnsafeBufferPointer { handler($0) }
                Thread.sleep(forTimeInterval: 0.005)
            }
            while running.load(ordering: .acquiring) { Thread.sleep(forTimeInterval: 0.01) }
            finished.signal()
        }.start()
    }

    func stop() {
        if running.exchange(false, ordering: .acquiringAndReleasing) { done?.wait() }
        done = nil
    }

    func setCenterFrequency(_ hz: Double) throws {}
}
