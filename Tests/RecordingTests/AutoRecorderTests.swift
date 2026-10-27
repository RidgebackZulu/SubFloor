import Accelerate
import Foundation
import Testing
@testable import DSPCore
@testable import Recording

/// A real USB `Receiver` at 250 kS/s feeding an `AutoRecorder` block by block, the way the DSP thread
/// does, with tone bursts over seeded noise. The recorder's WAVs are then compared, sample for
/// sample, with the audio the receiver produced.
@Suite struct AutoRecorderTests {
    static let inputRate = 250_000.0
    static let audioRate = 48_000.0
    static let block = 1_008
    static let toneHz = 51_000.0
    static let offsetHz = 50_000.0
    static let fixedNow = Date(timeIntervalSince1970: 1_792_000_000)

    typealias Burst = (start: Double, end: Double)

    // MARK: Signals

    /// Seeded noise (one second per seed) with a tone over each burst.
    static func signal(seconds: Double, bursts: [Burst]) -> [DSPComplex] {
        let total = Int(inputRate * seconds)
        var iq = [DSPComplex]()
        iq.reserveCapacity(total)
        var chunk = 0
        while iq.count < total {
            iq += noise(count: min(Int(inputRate), total - iq.count), sigma: 0.001, seed: 11 + UInt64(chunk))
            chunk += 1
        }
        for burst in bursts {
            let a = Int(burst.start * inputRate), b = min(total, Int(burst.end * inputRate))
            for i in a..<b {
                let p = 2 * Double.pi * toneHz * Double(i) / inputRate
                iq[i].real += 0.05 * Float(cos(p))
                iq[i].imag += 0.05 * Float(sin(p))
            }
        }
        return iq
    }

    /// Seeded complex Gaussian noise, `sigma` per component.
    static func noise(count: Int, sigma: Double, seed: UInt64) -> [DSPComplex] {
        var state = seed
        func uniform() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Double(state >> 11) + 0.5) / Double(1 << 53)
        }
        return (0..<count).map { _ in
            let r = sigma * sqrt(-2 * log(uniform())), t = 2 * Double.pi * uniform()
            return DSPComplex(real: Float(r * cos(t)), imag: Float(r * sin(t)))
        }
    }

    /// `count` bursts of `on` seconds every `period` seconds from `start`.
    static func train(from start: Double, count: Int, on: Double = 0.4, period: Double = 0.6) -> [Burst] {
        (0..<count).map { (start + Double($0) * period, start + Double($0) * period + on) }
    }

    static func receiverConfig(squelchDb: Float?) -> Receiver.Config {
        Receiver.Config(inputRate: inputRate, offsetHz: offsetHz, mode: .usb, bandwidthHz: 2_700, squelchDb: squelchDb)
    }

    /// The channel power of noise alone, from the second half of a run over it.
    static func noiseFloor() -> Float {
        let rx = Receiver(config: receiverConfig(squelchDb: nil))
        let iq = noise(count: Int(inputRate * 0.5), sigma: 0.001, seed: 11)
        var audio = [Float]()
        var levels = [Float]()
        var i = 0
        while i < iq.count {
            let end = min(iq.count, i + block)
            iq[i..<end].withUnsafeBufferPointer { rx.process($0, audio: &audio) }
            levels.append(rx.signalDb)
            i = end
        }
        let tail = levels.suffix(levels.count / 2)
        return tail.reduce(0, +) / Float(tail.count)
    }

    // MARK: Rig

    final class Rig {
        let dir: URL
        let recorder: StreamRecorder
        let auto: AutoRecorder
        let receiver: Receiver
        /// Every audio sample the receiver produced.
        var audio = [Float]()
        /// The audio frame count at the start of every block with the gate open.
        var openBlockStarts = [Int]()
        /// The audio frame count at the end of the last block with the gate open.
        var lastOpenFrame = 0

        init(timing: AutoRecordTiming = AutoRecordTiming(startAfter: 2, stopAfter: 15), enabled: Bool = true) {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("AutoRecorderTests-\(UUID().uuidString)", isDirectory: true)
            try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            recorder = StreamRecorder(kind: .audio, rollsOnContextChange: false)
            recorder.configure(StreamRecorder.Setup(sampleRate: AutoRecorderTests.audioRate, channels: 1, fileFormat: .wav,
                                                    sampleFormat: .float32, preRollSeconds: 30,
                                                    holdbackSeconds: AutoRecordTiming.maxHoldbackSeconds,
                                                    memoryLimitBytes: 1 << 30, folder: dir))
            recorder.now = { AutoRecorderTests.fixedNow }
            auto = AutoRecorder(recorder: recorder)
            auto.configure(.init(enabled: enabled, timing: timing))
            receiver = Receiver(config: AutoRecorderTests.receiverConfig(squelchDb: AutoRecorderTests.noiseFloor() + 10))
        }

        deinit {
            recorder.shutdown()
            try? FileManager.default.removeItem(at: dir)
        }

        /// Pushes `iq` through the receiver and the auto recorder in blocks. `beforeBlock` sees the IQ
        /// index of each block's start and the audio frames so far.
        func run(_ iq: [DSPComplex], beforeBlock: (Int, Int) -> Void = { _, _ in }) {
            var i = 0
            var block = [Float]()
            while i < iq.count {
                let end = min(iq.count, i + AutoRecorderTests.block)
                beforeBlock(i, audio.count)
                block.removeAll(keepingCapacity: true)
                iq[i..<end].withUnsafeBufferPointer { receiver.process($0, audio: &block) }
                let open = receiver.isSquelchOpen
                if open { openBlockStarts.append(audio.count) }
                audio += block
                if open { lastOpenFrame = audio.count }
                block.withUnsafeBufferPointer { auto.process($0, gateOpen: open) }
                i = end
            }
        }

        func waitForWriter(timeout: TimeInterval = 30) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while recorder.status.isRecording || recorder.sessionKind != .none {
                if Date() > deadline { return false }
                Thread.sleep(forTimeInterval: 0.005)
            }
            return true
        }

        func wavs() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        /// Where a file's first sample sits in `audio`, found by matching its first heard sample, and
        /// whether the whole file is exactly that stretch of the stream.
        func locate(_ file: [Float], heardFrom: Int) -> (start: Int, exact: Bool)? {
            guard let inFile = file.firstIndex(where: { $0 != 0 }),
                  let inStream = audio[heardFrom...].firstIndex(where: { $0 != 0 }) else { return nil }
            let start = inStream - inFile
            guard start >= 0, start + file.count <= audio.count else { return nil }
            return (start, file.elementsEqual(audio[start..<start + file.count]))
        }
    }

    static func readWAV(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        let n = (data.count - 44) / 4
        return data[44...].withUnsafeBytes { raw in (0..<n).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) } }
    }

    static func seconds(_ frames: Int) -> Double { Double(frames) / audioRate }

    // MARK: Tests

    @Test func burstsBecomeOneFileAndPopsAreOnlyLogged() throws {
        let pops: [Burst] = [(5, 5.3), (8, 8.3), (11, 11.3)]
        let speech = Self.train(from: 15.3, count: 13)             // 8 s of 0.4 s on, 0.2 s off
        let lastSpeech = speech.last!.end
        let late: Burst = (lastSpeech + 8, lastSpeech + 9)
        let seconds = late.end + 20
        let iq = Self.signal(seconds: seconds, bursts: pops + speech + [late])

        let rig = Rig()
        rig.run(iq)
        #expect(rig.waitForWriter())

        let files = try rig.wavs()
        #expect(files.count == 1, "\(files.count) files")
        guard files.count == 1 else { return }
        let file = try Self.readWAV(files[0])
        #expect(rig.recorder.status.error == nil)

        // The file is exactly a stretch of what the receiver produced.
        let heardFrom = Int(12 * Self.audioRate)
        let found = rig.locate(file, heardFrom: heardFrom)
        #expect(found != nil && found?.exact == true, "the file is a verbatim stretch of the audio")
        guard let found, let firstOpen = rig.openBlockStarts.first(where: { $0 >= heardFrom }) else { return }

        // Pops are not in it: its first non-zero sample is the first speech, and everything before is squelched.
        let firstHeard = file.firstIndex { $0 != 0 }!
        #expect(file[..<firstHeard].allSatisfy { $0 == 0 })
        #expect(found.start + firstHeard >= Int((speech[0].start - 0.2) * Self.audioRate))

        // 0.5 s of lead before the first burst, and 2 s of tail after the gate's last open frame. The
        // gate holds open 0.15 s past a burst (and filters add a little), so from the burst's own end
        // the tail is 2 s plus that.
        let end = found.start + file.count
        let lead = Self.seconds(Int(speech[0].start * Self.audioRate) - found.start)
        let tailFromBurst = Self.seconds(end) - late.end
        #expect(abs(lead - 0.5) <= 0.05, "lead \(lead)")
        #expect(abs(Self.seconds(firstOpen - found.start) - 0.5) <= 0.05, "lead from the gate opening \(Self.seconds(firstOpen - found.start))")
        #expect(abs(Self.seconds(end - rig.lastOpenFrame) - 2.0) <= 0.05, "tail after the gate shut \(Self.seconds(end - rig.lastOpenFrame))")
        #expect(tailFromBurst >= 2.0 - 0.05 && tailFromBurst <= 2.0 + 0.3, "tail after the last burst \(tailFromBurst)")

        // The three pops are logged, with their times and lengths.
        let logged = rig.auto.drainPops()
        #expect(logged.count == 3, "\(logged.count) pops")
        #expect(rig.auto.drainPops().isEmpty, "draining empties the queue")
        #expect(rig.auto.popQueueCapacity > AutoRecorder.popCapacity, "draining keeps the queue's storage")
        guard logged.count == 3 else { return }
        for (pop, burst) in zip(logged, pops) {
            #expect(pop.seconds >= burst.end - burst.start - 0.05 && pop.seconds <= burst.end - burst.start + 0.4, "pop of \(pop.seconds) s")
        }
        // `at` counts back from now by the frames since the pop began: its own length plus the 1.5 s
        // of quiet that proved it was a pop.
        for (pop, burst) in zip(logged, pops) {
            let ago = Self.fixedNow.timeIntervalSince(pop.at)
            let length = burst.end - burst.start
            #expect(ago >= length + AutoRecordTiming.bridge && ago <= length + AutoRecordTiming.bridge + 0.4, "pop logged \(ago) s back")
        }
        #expect(rig.recorder.headFrame == rig.audio.count)
    }

    @Test func turningAutoOffMidRecordingEndsAtLastOpenPlusTail() throws {
        let speech = Self.train(from: 3, count: 10)
        let lastEnd = speech.last!.end
        let iq = Self.signal(seconds: lastEnd + 9, bursts: speech)

        let rig = Rig()
        var configured = false
        rig.run(iq) { i, _ in
            if !configured, Double(i) / Self.inputRate >= lastEnd + 5 {
                configured = true
                rig.auto.configure(.init(enabled: false, timing: AutoRecordTiming(startAfter: 2, stopAfter: 15)))
            }
        }
        #expect(configured)
        #expect(rig.waitForWriter())

        let files = try rig.wavs()
        #expect(files.count == 1, "\(files.count) files")
        guard files.count == 1 else { return }
        let file = try Self.readWAV(files[0])
        let found = rig.locate(file, heardFrom: Int(1 * Self.audioRate))
        #expect(found != nil && found?.exact == true)
        guard let found else { return }
        let end = found.start + file.count
        #expect(abs(Self.seconds(end - rig.lastOpenFrame) - 2.0) <= 0.05, "tail \(Self.seconds(end - rig.lastOpenFrame))")
        #expect(end < Int((lastEnd + 3) * Self.audioRate), "it did not run on to the moment Auto was turned off")
        #expect(rig.auto.config.enabled == false)
    }

    @Test func cutEndsTheRecordingAndCounts() throws {
        let speech = Self.train(from: 2, count: 10)                 // on until 7.8 s
        let iq = Self.signal(seconds: 14, bursts: speech)
        let cutAtSeconds = 6.0

        let rig = Rig()
        var cutFrame: Int?
        rig.run(iq) { i, frames in
            if cutFrame == nil, Double(i) / Self.inputRate >= cutAtSeconds {
                cutFrame = frames
                rig.auto.cut()
            }
        }
        #expect(rig.waitForWriter())

        #expect(rig.auto.cuts == 1)
        let files = try rig.wavs()
        guard let cutFrame else { Issue.record("never cut"); return }
        // The recording ends at the cut, and what is left of the bursts (1.8 s) is too short to start another.
        #expect(files.count == 1, "\(files.count) files")
        guard files.count == 1 else { return }
        let file = try Self.readWAV(files[0])
        let found = rig.locate(file, heardFrom: Int(1 * Self.audioRate))
        #expect(found != nil && found?.exact == true)
        guard let found else { return }
        let end = found.start + file.count
        let oneBlock = Int(Double(Self.block) / Self.inputRate * Self.audioRate) + 1
        #expect(abs(end - cutFrame) <= oneBlock, "ends \(end - cutFrame) frames from the cut (one block is \(oneBlock))")
    }

    @Test func aRecordingAfterACutNeverReachesBackPastIt() throws {
        let before = Self.train(from: 2, count: 8)                  // on until 6.6 s
        let cutAtSeconds = 7.0
        let after = Self.train(from: cutAtSeconds + 0.2, count: 10) // 0.2 s after the cut, until 12.8 s
        let iq = Self.signal(seconds: after.last!.end + 17, bursts: before + after)

        let rig = Rig()
        var cutFrame: Int?
        rig.run(iq) { i, frames in
            if cutFrame == nil, Double(i) / Self.inputRate >= cutAtSeconds {
                cutFrame = frames
                rig.auto.cut()
            }
        }
        #expect(rig.waitForWriter())
        guard let cutFrame else { Issue.record("never cut"); return }

        // Where each file sits in the stream: its first heard sample matched exactly, then the whole file.
        func start(of file: [Float]) -> Int? {
            guard let f = file.firstIndex(where: { $0 != 0 }) else { return nil }
            return rig.audio.indices.first { s in
                rig.audio[s] == file[f] && s >= f && s - f + file.count <= rig.audio.count
                    && file.elementsEqual(rig.audio[(s - f)..<(s - f + file.count)])
            }.map { $0 - f }
        }
        let starts = try rig.wavs().map { try start(of: Self.readWAV($0)) }
        #expect(starts.count == 2, "\(starts.count) files")
        #expect(!starts.contains(nil), "every file is a verbatim stretch of the audio")
        let ordered = starts.compactMap { $0 }.sorted()
        guard ordered.count == 2 else { return }
        #expect(ordered[0] < cutFrame)
        // Without the floor the lead would start it 0.5 s before the burst, 0.3 s before the cut.
        #expect(ordered[1] >= cutFrame, "the second file starts \(Self.seconds(cutFrame - ordered[1])) s before the cut")
    }

    /// Where each file sits in the stream, found by matching it whole; nil for a file that is not a
    /// verbatim stretch of the audio.
    static func starts(of files: [[Float]], in audio: [Float]) -> [Int?] {
        files.map { file in
            guard let f = file.firstIndex(where: { $0 != 0 }) else { return nil }
            return audio.indices.first { s in
                audio[s] == file[f] && s >= f && s - f + file.count <= audio.count
                    && file.elementsEqual(audio[(s - f)..<(s - f + file.count)])
            }.map { $0 - f }
        }
    }

    /// A write error ends an auto recording behind the trigger's back (stood in for here by a plain
    /// stop): Auto stays armed, and later bursts make a new file.
    @Test func autoStaysArmedAfterARecordingEndsBehindItsBack() throws {
        let first = Self.train(from: 2, count: 10)                  // on until 7.8 s
        let endAt = 6.0
        let second = Self.train(from: 12, count: 10)                // on until 17.8 s
        let iq = Self.signal(seconds: second.last!.end + 17, bursts: first + second)

        let rig = Rig()
        var endFrame: Int?
        rig.run(iq) { i, frames in
            if endFrame == nil, Double(i) / Self.inputRate >= endAt {
                #expect(rig.recorder.sessionKind == .auto)
                endFrame = frames
                rig.recorder.stop(wait: true)
                #expect(rig.recorder.sessionKind == .none)
            }
        }
        #expect(rig.waitForWriter())
        guard let endFrame else { Issue.record("never ended"); return }

        let files = try rig.wavs().map(Self.readWAV)
        #expect(files.count == 2, "\(files.count) files")
        let starts = Self.starts(of: files, in: rig.audio)
        #expect(!starts.contains(nil), "every file is a verbatim stretch of the audio")
        guard files.count == 2, let a = starts[0], let b = starts[1] else { return }
        #expect(a + files[0].count <= endFrame, "the first file ends where it was stopped")
        #expect(abs(Self.seconds(b) - (second[0].start - AutoRecordTiming.lead)) <= 0.05, "the second starts 0.5 s before its first burst")
        #expect(rig.recorder.status.isAuto)
    }

    /// The Audio button takes an auto recording over; when it is stopped, Auto picks up again and
    /// later bursts make a new auto file.
    @Test func autoResumesAfterAManualTakeoverEnds() throws {
        let first = Self.train(from: 2, count: 10)                  // on until 7.8 s
        let takeOverAt = 5.0, stopAt = 9.0
        let second = Self.train(from: 12, count: 10)                // on until 17.8 s
        let iq = Self.signal(seconds: second.last!.end + 17, bursts: first + second)

        let rig = Rig()
        var tookOver = false, stopped = false
        var manualWhileHeld = true
        rig.run(iq) { i, _ in
            let t = Double(i) / Self.inputRate
            if !tookOver, t >= takeOverAt {
                tookOver = true
                #expect(rig.recorder.sessionKind == .auto)
                rig.recorder.start()
            } else if tookOver, !stopped, t >= stopAt {
                stopped = true
                rig.recorder.stop(wait: true)
            } else if tookOver, !stopped, rig.recorder.sessionKind != .manual {
                manualWhileHeld = false
            }
        }
        #expect(tookOver && stopped)
        #expect(manualWhileHeld, "the trigger never ended the manual recording")
        #expect(rig.waitForWriter())

        let files = try rig.wavs().map(Self.readWAV)
        #expect(files.count == 2, "\(files.count) files")
        let starts = Self.starts(of: files, in: rig.audio)
        #expect(!starts.contains(nil), "every file is a verbatim stretch of the audio")
        guard files.count == 2, let a = starts[0], let b = starts[1] else { return }
        // The taken-over file runs to the manual stop, not to the trigger's end of the first bursts.
        #expect(Self.seconds(a + files[0].count) >= first.last!.end + 0.5)
        #expect(abs(Self.seconds(b) - (second[0].start - AutoRecordTiming.lead)) <= 0.05, "the second starts 0.5 s before its first burst")
        #expect(rig.recorder.status.isAuto)
    }

    @Test func manualSessionPausesTheTrigger() throws {
        let speech = Self.train(from: 3, count: 10)
        let pop: Burst = (1, 1.3)      // the trigger would log this if it were running
        let iq = Self.signal(seconds: speech.last!.end + 20, bursts: [pop] + speech)

        let rig = Rig()
        rig.recorder.start()
        var manualThroughout = true
        rig.run(iq) { _, _ in if rig.recorder.sessionKind != .manual { manualThroughout = false } }
        #expect(manualThroughout, "the manual session was never taken over or ended")
        rig.recorder.stop(wait: true)
        #expect(rig.waitForWriter())

        let files = try rig.wavs()
        #expect(files.count == 1, "\(files.count) files")
        #expect(rig.auto.drainPops().isEmpty)
        guard files.count == 1 else { return }
        let file = try Self.readWAV(files[0])
        // A manual recording holds the whole stream from its start, bursts and silence alike.
        #expect(file.count > Int(speech.last!.end * Self.audioRate))
        #expect(file.elementsEqual(rig.audio.prefix(file.count)))
        #expect(file.contains { $0 != 0 })
    }
}
