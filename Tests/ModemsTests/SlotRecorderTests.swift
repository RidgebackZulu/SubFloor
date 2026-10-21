import Testing
import Foundation
@testable import Modems

// Slot timing: all times are UTC seconds since the Unix epoch. `t0` is an even UTC minute, so it
// starts both an FT8 slot and a WSPR slot. Audio is 12 kHz; "ramp" audio holds each sample's own
// index, so a job's samples show exactly which recorded samples it holds.

private let fs = 12_000.0
private let t0 = 1_800_000_000.0

private func date(_ t: Double) -> Date { Date(timeIntervalSince1970: t) }

/// `count` samples whose values are their indices from `first`.
private func ramp(_ count: Int, from first: Int = 0) -> [Float] { (0..<count).map { Float(first + $0) } }

/// Feeds `audio` to `recorder` in chunks (cycling through `chunks` sizes), the first sample at
/// `start`, each chunk stamped by `stamp(time it should have, sample index)`, and asks for due slots
/// after every chunk with `now` = the time just after its last sample. Returns every job.
private func feed(_ recorder: SlotRecorder, _ audio: [Float], start: Double, chunks: [Int] = [1_200],
                  modes: [any SlotModem.Type] = [FT8Modem.self],
                  stamp: (Double, Int) -> Double = { t, _ in t },
                  between: (Int) -> Void = { _ in }) -> [SlotJob] {
    var jobs: [SlotJob] = []
    var i = 0, c = 0
    while i < audio.count {
        let n = min(chunks[c % chunks.count], audio.count - i)
        between(i)
        let t = stamp(start + Double(i) / fs, i)
        audio[i..<(i + n)].withUnsafeBufferPointer { recorder.append($0, firstSampleTime: date(t)) }
        jobs += recorder.dueSlots(modes: modes, now: date(t + Double(n) / fs))
        i += n
        c += 1
    }
    return jobs
}

private func starts(_ jobs: [SlotJob]) -> [Double] { jobs.map { $0.slotStart.timeIntervalSince1970 - t0 } }

@Suite struct SlotRecorderTests {
    @Test func slotBoundaries() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let noon = try #require(utc.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12)))
        func at(_ s: Double) -> Date { noon.addingTimeInterval(s) }
        // FT8: 12:00:16 → 12:00:15.
        #expect(SlotRecorder.slotStart(for: at(16), slotSeconds: FT8Modem.slotSeconds) == at(15))
        #expect(SlotRecorder.slotStart(for: at(15), slotSeconds: 15) == at(15))
        #expect(SlotRecorder.slotStart(for: at(14.999), slotSeconds: 15) == at(0))
        #expect(SlotRecorder.slotStart(for: at(59.9), slotSeconds: 15) == at(45))
        // WSPR: 12:01:30 → 12:00:00 (even minutes).
        #expect(SlotRecorder.slotStart(for: at(90), slotSeconds: WSPRModem.slotSeconds) == at(0))
        #expect(SlotRecorder.slotStart(for: at(120), slotSeconds: 120) == at(120))
        #expect(SlotRecorder.slotStart(for: at(179), slotSeconds: 120) == at(120))
        #expect(SlotRecorder.slotStart(for: at(-0.5), slotSeconds: 120) == at(-120))
    }

    @Test func jobContainsExactSlotSamples() throws {
        // Recording starts 2.3 s before t0, in uneven chunks.
        let recorder = SlotRecorder()
        let audio = ramp(Int(18.3 * fs))
        let jobs = feed(recorder, audio, start: t0 - 2.3, chunks: [1_000, 37, 4_096, 512, 2_048])
        // The slot straddling the start is skipped; the next is complete.
        #expect(starts(jobs) == [0])
        let job = try #require(jobs.first)
        #expect(job.samples.count == 15 * 12_000)
        #expect(job.sampleRate == fs)
        #expect(job.mode.id == .ft8)
        #expect(job.samples.first == Float(27_600))
        #expect(job.samples.last == Float(27_600 + 15 * 12_000 - 1))
        #expect(zip(job.samples, job.samples.dropFirst()).allSatisfy { $1 == $0 + 1 })

        // Chunking does not matter.
        let other = feed(SlotRecorder(), audio, start: t0 - 2.3, chunks: [12_345, 1])
        #expect(other.first?.samples == job.samples)
    }

    @Test func dueOnlyAfterSlotEndPlusMargin() {
        let recorder = SlotRecorder()
        #expect(recorder.dueSlots(modes: [FT8Modem.self], now: date(t0 - 1)).isEmpty)
        let audio = ramp(Int(17 * fs))
        audio.withUnsafeBufferPointer { recorder.append($0, firstSampleTime: date(t0 - 1)) }
        #expect(recorder.dueSlots(modes: [FT8Modem.self], now: date(t0 + 15.49)).isEmpty)
        #expect(starts(recorder.dueSlots(modes: [FT8Modem.self], now: date(t0 + 15.5))) == [0])
        #expect(recorder.dueSlots(modes: [FT8Modem.self], now: date(t0 + 15.6)).isEmpty, "each slot once")
    }

    @Test func waitsForLateAudio() {
        let recorder = SlotRecorder()
        _ = recorder.dueSlots(modes: [FT8Modem.self], now: date(t0 - 0.5))
        let audio = ramp(Int(17 * fs))
        let split = Int(11 * fs)
        audio[..<split].withUnsafeBufferPointer { recorder.append($0, firstSampleTime: date(t0 - 1)) }
        // Due by the clock, but the audio has not all arrived (pipeline latency): wait.
        #expect(recorder.dueSlots(modes: [FT8Modem.self], now: date(t0 + 20)).isEmpty)
        audio[split...].withUnsafeBufferPointer { recorder.append($0, firstSampleTime: date(t0 + 10)) }
        #expect(starts(recorder.dueSlots(modes: [FT8Modem.self], now: date(t0 + 20))) == [0])
    }

    @Test func gapSkipsSlot() throws {
        // A 100 ms timestamp jump at t0 + 22 s, inside the slot from t0 + 15: that slot is skipped,
        // the ones either side are decoded.
        let audio = ramp(Int(47 * fs))
        let jump = Int(23 * fs)
        let jobs = feed(SlotRecorder(), audio, start: t0 - 1) { t, i in i >= jump ? t + 0.1 : t }
        #expect(starts(jobs) == [0, 30])
        // After the jump the stamps run 0.1 s ahead: the slot from t0 + 30 starts 0.1 s earlier in
        // the sample stream.
        let last = try #require(jobs.last)
        #expect(last.samples.first == Float(Int(30.9 * fs)))
        #expect(last.samples.count == 15 * 12_000)
    }

    /// A slot skipped for a gap is reported (once, with its mode and start) so the panel can say so;
    /// a slot already under way when recording began is not, and a reset forgets pending reports.
    @Test func skippedSlotsAreReported() {
        let recorder = SlotRecorder()
        let audio = [Float](repeating: 0, count: Int(47 * fs))
        let jump = Int(23 * fs)
        // Starts at t0 + 5 (the slot from t0 is under way), with a gap inside the slot from t0 + 15.
        let jobs = feed(recorder, audio, start: t0 + 5) { t, i in i >= jump ? t + 0.1 : t }
        #expect(starts(jobs) == [30])
        let skipped = recorder.takeSkipped()
        #expect(skipped == [SlotOutcome(mode: .ft8, slotStart: date(t0 + 15), decodes: nil)])
        #expect(recorder.takeSkipped().isEmpty, "each skip is reported once")

        let again = SlotRecorder()
        _ = feed(again, audio, start: t0 - 1) { t, i in i >= jump ? t + 0.1 : t }
        again.reset()
        #expect(again.takeSkipped().isEmpty)
    }

    @Test(arguments: [0.015, -0.015, -0.1, 0.021])
    func timestampJumps(seconds: Double) {
        let audio = [Float](repeating: 0, count: Int(47 * fs))
        let jump = Int(23 * fs)
        let jobs = feed(SlotRecorder(), audio, start: t0 - 1) { t, i in i >= jump ? t + seconds : t }
        // Up to 20 ms is stamp jitter; more, either way, is a gap.
        #expect(starts(jobs) == (abs(seconds) <= 0.02 ? [0, 15, 30] : [0, 30]), "jump \(seconds) s")
    }

    @Test func markedGapSkipsSlot() {
        let recorder = SlotRecorder()
        let audio = [Float](repeating: 0, count: Int(47 * fs))
        let gap = Int(23 * fs)
        let jobs = feed(recorder, audio, start: t0 - 1, between: { if $0 == gap { recorder.markGap() } })
        #expect(starts(jobs) == [0, 30])
    }

    /// Review Focus 4: no slot spanning a reset (the box moved) is ever returned.
    @Test func resetDiscardsPartialSlot() {
        let recorder = SlotRecorder()
        let audio = ramp(Int(47 * fs))
        let move = Int(23 * fs)
        let jobs = feed(recorder, audio, start: t0 - 1, between: { if $0 == move { recorder.reset() } })
        #expect(starts(jobs) == [0, 30])
        #expect(jobs.last?.samples.first == Float(31 * 12_000))
    }

    @Test func slotStraddlingRecorderStartIsSkipped() {
        let jobs = feed(SlotRecorder(), [Float](repeating: 0, count: Int(26 * fs)), start: t0 + 5)
        #expect(starts(jobs) == [15])
        // Starting within a sample of a boundary counts as having it.
        let exact = feed(SlotRecorder(), [Float](repeating: 0, count: Int(16 * fs)), start: t0 - 0.5 / fs)
        #expect(starts(exact) == [0])
        let late = feed(SlotRecorder(), [Float](repeating: 0, count: Int(16 * fs)), start: t0 + 0.002)
        #expect(late.isEmpty)
    }

    /// A mode asked for again after a break starts with the slot in progress: no backlog of old slots.
    @Test func noBacklogWhenModeReturns() {
        let recorder = SlotRecorder()
        let audio = [Float](repeating: 0, count: Int(120 * fs))
        var jobs: [SlotJob] = []
        var i = 0
        while i < audio.count {
            let n = 1_200
            let t = t0 - 1 + Double(i) / fs
            audio[i..<(i + n)].withUnsafeBufferPointer { recorder.append($0, firstSampleTime: date(t)) }
            let now = t + Double(n) / fs
            // FT8 is wanted until t0 + 31, then not until t0 + 82.
            let wanted = now < t0 + 31 || now > t0 + 82
            jobs += recorder.dueSlots(modes: wanted ? [FT8Modem.self] : [], now: date(now))
            i += n
        }
        #expect(starts(jobs) == [0, 15, 75, 90])
    }

    @Test func memoryIsBoundedAndWSPRSlotsAreCut() {
        // Ten minutes from 7 s before an even minute, in 2048-sample blocks stamped with up to ±5 ms
        // of jitter (every block its own run): the buffer stays at 150 s and the runs bounded.
        let recorder = SlotRecorder(retainSeconds: 150)
        var jitter: UInt64 = 0x2545_F491_4F6C_DD1D
        let block = [Float](repeating: 0, count: 2_048)
        var jobs: [SlotJob] = []
        var maxAnchors = 0
        let total = Int(607 * fs)
        var i = 0
        while i < total {
            jitter ^= jitter << 13; jitter ^= jitter >> 7; jitter ^= jitter << 17
            let wobble = (Double(jitter % 1_001) / 1_000 - 0.5) * 0.01
            let t = t0 - 7 + Double(i) / fs + wobble
            block.withUnsafeBufferPointer { recorder.append($0, firstSampleTime: date(t)) }
            jobs += recorder.dueSlots(modes: [FT8Modem.self, WSPRModem.self], now: date(t0 - 7 + Double(i + 2_048) / fs))
            maxAnchors = max(maxAnchors, recorder.anchorCount)
            i += 2_048
        }
        #expect(recorder.bufferCapacity == 150 * 12_000)
        #expect(recorder.retainedSampleCount <= recorder.bufferCapacity)
        #expect(maxAnchors <= 150 * 12_000 / 2_048 + 2, "\(maxAnchors) runs")
        let wspr = jobs.filter { $0.mode.id == .wspr }, ft8 = jobs.filter { $0.mode.id == .ft8 }
        #expect(starts(wspr) == [0, 120, 240, 360])
        #expect(wspr.allSatisfy { $0.samples.count == 120 * 12_000 })
        #expect(starts(ft8) == (0...38).map { Double($0 * 15) })
    }
}

// MARK: - Engine

/// Feeds `seconds` of `audio` (zeros when nil) through `engine.process` from UTC time `start`, in
/// 4096-sample blocks, asking for due jobs after each. `hook(sampleIndex)` runs before each block
/// and may return a different time stamp, nil for an untimed block, or skip the index ahead.
private func run(_ engine: ModemEngine, seconds: Double, start: Double, audio: [Float]? = nil,
                 hook: (Int) -> (indexJump: Int, timed: Bool) = { _ in (0, true) },
                 beforeBlock: (Int) -> Void = { _ in }) -> [SlotJob] {
    let count = Int(seconds * fs)
    let samples = audio ?? [Float](repeating: 0, count: count)
    var jobs: [SlotJob] = []
    var i = 0, index = 0
    while i < count {
        let n = min(4_096, count - i)
        beforeBlock(i)
        let h = hook(i)
        index += h.indexJump
        let t = start + Double(i) / fs
        _ = samples[i..<(i + n)].withUnsafeBufferPointer {
            engine.process($0, sampleIndex: index, firstSampleTime: h.timed ? date(t) : nil)
        }
        jobs += engine.dueSlotJobs(now: date(t + Double(n) / fs))
        i += n
        index += n
    }
    return jobs
}

@Suite struct ModemEngineSlotTests {
    /// Which slot modes produce jobs: none unless slot modes are enabled and a mode is selected; with
    /// auto-detect every slot mode; without it the selected mode when it is a slot mode.
    static let settingsCases: [(ModemSettings, Set<ModeID>)] = [
        (ModemSettings(mode: .ft8), [.ft8]),
        (ModemSettings(mode: .wspr), [.wspr]),
        (ModemSettings(mode: .psk31), []),
        (ModemSettings(mode: .cw), []),
        (ModemSettings(mode: .psk31, autoDetect: true), [.ft8, .wspr]),
        (ModemSettings(mode: .ft8, autoDetect: true), [.ft8, .wspr]),
        (ModemSettings(mode: nil, autoDetect: true), []),
        (ModemSettings(mode: .ft8, slotModesEnabled: false), []),
        (ModemSettings(mode: .wspr, autoDetect: true, slotModesEnabled: false), []),
    ]

    @Test(arguments: settingsCases)
    func jobsFollowSettings(settings: ModemSettings, expected: Set<ModeID>) {
        let engine = ModemEngine()
        engine.settings = settings
        // 124 s from 3 s before an even minute, straight into the recorder.
        var modes: [ModeID: [Double]] = [:]
        let block = [Float](repeating: 0, count: 6_000)
        for k in 0..<Int(124 * fs / 6_000) {
            let t = t0 - 3 + Double(k) * 0.5
            block.withUnsafeBufferPointer { engine.appendSlotAudio($0, firstSampleTime: date(t)) }
            for job in engine.dueSlotJobs(now: date(t + 0.5)) {
                modes[job.mode.id, default: []].append(job.slotStart.timeIntervalSince1970 - t0)
            }
        }
        #expect(Set(modes.keys) == expected, "\(settings)")
        if expected.contains(.ft8) { #expect(modes[.ft8] == (0...7).map { Double($0 * 15) }) }
        if expected.contains(.wspr) { #expect(modes[.wspr] == [0]) }
    }

    /// End to end: an FT8 signal in the second whole slot, fed through `process` with UTC times,
    /// becomes a due job that `FT8Modem` decodes; the slot straddling the start is skipped.
    @Test func processToDecodedFT8() throws {
        let engine = ModemEngine()
        engine.settings = ModemSettings(mode: .ft8)
        let lead = 4.0
        var clean = [Float](repeating: 0, count: Int(35 * fs))
        let signal = try #require(FT8Encoder.audio(message: "CQ W1AW FN31", audioHz: 1_234))
        for (k, x) in signal.enumerated() { clean[Int((lead + 15) * fs) + k] = x }
        let audio = ModemTestSignals.awgn(clean, snrDb: -12, seed: 1_010, signalPower: 0.125)
        let jobs = run(engine, seconds: 35, start: t0 - lead, audio: audio)
        #expect(starts(jobs) == [0, 15])
        #expect(jobs.allSatisfy { $0.mode.id == .ft8 && $0.samples.count == 15 * 12_000 })
        let decodes = jobs.map { $0.decode(audioBand: 300...3_300) }
        #expect(decodes.first?.isEmpty == true)
        let d = try #require(decodes.last?.first)
        #expect(decodes.last?.count == 1)
        #expect(d.message == "CQ W1AW FN31")
        #expect(d.slotStart == date(t0 + 15))
        #expect(abs(d.frequencyHz - 1_234) < 1)
        #expect(abs(d.timeOffset) < 0.02)
    }

    /// Review Focus 3 and 4: a box move mid-slot discards the partly recorded slot.
    @Test func boxMoveDiscardsPartialSlot() {
        let engine = ModemEngine()
        engine.settings = ModemSettings(mode: .ft8)
        let move = Int(23 * fs) / 4_096 * 4_096
        let jobs = run(engine, seconds: 47, start: t0 - 1, beforeBlock: { if $0 == move { engine.resetForBoxMove() } })
        #expect(starts(jobs) == [0, 30])
    }

    @Test func lostAudioSkipsSlot() {
        // A jump in sampleIndex (overflow) inside the slot from t0 + 15, with the times running on.
        let engine = ModemEngine()
        engine.settings = ModemSettings(mode: .ft8)
        let at = Int(20 * fs) / 4_096 * 4_096
        let jumped = run(engine, seconds: 47, start: t0 - 1, hook: { $0 == at ? (4_096, true) : (0, true) })
        #expect(starts(jumped) == [0, 30])
        // An untimed block.
        let other = ModemEngine()
        other.settings = ModemSettings(mode: .ft8)
        let untimed = run(other, seconds: 47, start: t0 - 1, hook: { $0 == at ? (0, false) : (0, true) })
        #expect(starts(untimed) == [0, 30])
    }
}
