import DSPCore
import Foundation
import Recording
import SDRplayKit
import SignalID
import SubFloorCore
import Synchronization
import Testing
import Transcription
@testable import SubFloor

/// A value shared with the closures the service runs off the main actor.
private final class Shared<Value: Sendable>: Sendable {
    private let value: Mutex<Value>
    init(_ value: Value) { self.value = Mutex(value) }
    func withLock<R>(_ body: (inout Value) -> R) -> R { value.withLock { body(&$0) } }
}

/// `identify_signal`, `identify_signals` and `get_cursor`'s `signal`, called as an agent would, on a demo-source
/// model. The IQ is a stub snapshot through `SignalIDService.snapshotProvider` and the analysis a stub through
/// `analysis` (the identifier has its own tests); the spectrum a scan reads, and the wait for the ring, are the
/// tools' own hooks. No server is started: the tools are called directly.
@MainActor
@Suite(.serialized)
struct MCPSignalToolsTests {
    private func makeModel() -> AppModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorSignalTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                         defaults: UserDefaults(suiteName: UUID().uuidString)!,
                         openRSP: { throw SDRplayError.noDevice }, rspOpenTimeout: .seconds(10),
                         decodeHistoryFolder: dir.appendingPathComponent("decodes"))
        m.recording.folderPath = dir.appendingPathComponent("rec").path
        return m
    }

    /// A model running the demo source with Signal ID stubbed, or nil where the engine can't start (no audio
    /// device: tolerated, as elsewhere).
    private func runningModel(analysis: SignalIDService.Analysis? = nil) -> (AppModel, SubFloorTools)? {
        let m = makeModel()
        m.useSource(.synthetic)
        guard m.isRunning else {
            print("engine did not start (tolerated, no audio device)")
            m.shutdown()
            return nil
        }
        m.tune(to: 14_100_000)
        let zeros = IQSnapshot(samples: [Float](repeating: 0, count: 2 * 48_000 * 4), sampleRate: 48_000, endTime: Date())
        m.signalID.snapshotProvider = { _ in zeros }
        m.signalID.chunkProvider = { _, chunkFrames, visit in
            let frames = min(chunkFrames, 48_000)
            _ = zeros.samples.withUnsafeBufferPointer { visit(UnsafeBufferPointer(rebasing: $0[0..<(2 * frames)])) }
            return IQRead(frames: frames, sampleRate: 48_000, endTime: Date())
        }
        m.signalID.analysis = analysis ?? Self.rtty()
        let tools = SubFloorTools(model: m)
        tools.ringReady = { _ in true }   // no wait for the demo's ring to fill
        return (m, tools)
    }

    /// A stub analysis: a 100 Hz wide RTTY, centred where it was asked.
    private static func rtty(widthHz: Double = 100, seconds: Double = 0) -> SignalIDService.Analysis {
        { _, _, centre, at, _, _, _ in
            if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
            return SignalIdentity(measurement: SignalMeasurement(offsetHz: at - centre, occupiedBandwidthHz: widthHz,
                                                                 bandwidth6dBHz: widthHz / 2, snrDb: 24, family: .fsk,
                                                                 familyConfidence: 0.9, symbolRate: 45.45, fskShiftHz: 170,
                                                                 toneCount: 2, seconds: 3),
                                  best: ModeMatch(name: "RTTY", confidence: 0.91, evidence: ["45.45 Bd", "170 Hz shift"]),
                                  alternatives: [ModeMatch(name: "Olivia", confidence: 0.31, evidence: [])])
        }
    }

    private func call(_ tools: SubFloorTools, _ name: String, _ arguments: [String: JSONValue] = [:],
                      client: String = "test-agent 1.0") async -> MCPToolResult {
        await tools.call(name, arguments: arguments, client: client)
    }

    /// Waits (letting the main actor run) until `condition` holds or `seconds` pass.
    private func eventually(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return condition() }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// A spectrum of the capture the model has now: a flat floor and a 30 dB line at each of `lines` (display Hz)
    /// inside it.
    private static func spectrum(of m: AppModel, lines: [Double]) -> SpectrumSnapshot {
        let span = m.sampleRate, bins = 4096
        var average = [Float](repeating: -100, count: bins)
        for (i, _) in average.enumerated() where i % 2 == 0 { average[i] = -101 }   // not perfectly flat
        let lower = m.centerHz - span / 2
        for hz in lines {
            let i = Int(((hz - lower) / span * Double(bins)).rounded())
            if average.indices.contains(i) { average[i] = -70 }
        }
        return SpectrumSnapshot(centerHz: m.centerHz, spanHz: span, average: average)
    }

    private struct Tuning: Equatable {
        var vfo: Double, mode: DemodMode, bandwidth: Double, hamitup: Bool, lo: Double
        @MainActor init(_ m: AppModel) {
            vfo = m.vfoHz; mode = m.mode; bandwidth = m.bandwidthHz; hamitup = m.upconverter.enabled; lo = m.upconverter.loHz
        }
    }

    // MARK: identify_signal

    @Test func identifySignalReturnsTheIdentity() async {
        guard let (m, tools) = runningModel() else { return }
        defer { m.shutdown() }
        let before = Tuning(m), centre = m.centerHz, sequence = m.signalID.tuning.current.sequence
        let hz = m.centerHz + 5_000
        let r = await call(tools, "identify_signal", ["frequency": .number(hz)])
        #expect(!r.isError, "\(r.content)")
        let s = r.structured
        #expect(s?["ok"]?.bool == true)
        #expect(s?["name"]?.string == "RTTY")
        #expect(s?["family"]?.string == "2-FSK")
        #expect(s?["confidence"]?.double == 0.91)
        #expect(abs((s?["hz"]?.double ?? 0) - hz) <= 1)
        #expect(s?["label"]?.string?.hasPrefix("RTTY") == true)
        #expect(s?["confirmed_by_decode"]?.bool == false)
        #expect(s?["needs_longer_read"]?.bool == false)
        #expect(s?["parameters"]?["symbol_rate_bd"]?.double == 45.45)
        #expect(s?["parameters"]?["shift_hz"]?.double == 170)
        #expect(s?["alternatives"]?.array?.first?["name"]?.string == "Olivia")
        // It never retunes.
        #expect(Tuning(m) == before)
        #expect(m.centerHz == centre)
        #expect(m.signalID.tuning.current.sequence == sequence)
        #expect(tools.tools.first { $0.name == "identify_signal" }?.readOnly == true)
        // A frequency as a string, and a bandwidth for the read.
        let text = await call(tools, "identify_signal", ["frequency": .string("14.105 MHz"), "bandwidth_hz": .number(500)])
        #expect(!text.isError, "\(text.content)")
    }

    @Test func identifySignalRefusesWhatItCannotRead() async {
        let stopped = makeModel()
        let tools = SubFloorTools(model: stopped)
        let off = await call(tools, "identify_signal", ["frequency": .number(14_100_000)])
        #expect(off.isError)
        #expect(off.content.contains("start_radio"))

        guard let (m, tools) = runningModel() else { return }
        defer { m.shutdown() }
        let far = await call(tools, "identify_signal", ["frequency": .number(m.centerHz + m.sampleRate)])
        #expect(far.isError)
        #expect(far.content.contains("outside the capture"))
        #expect(far.content.contains("identify_signals"))
        let missing = await call(tools, "identify_signal")
        #expect(missing.isError)
        #expect(missing.content.contains("frequency"))
    }

    // MARK: identify_signals

    @Test func scanWithinTheViewLeavesTheRadio() async {
        guard let (m, tools) = runningModel() else { return }
        defer { m.shutdown() }
        let lines = [m.centerHz - 300_000, m.centerHz + 40_000, m.centerHz + 400_000]
        tools.scanSpectrum = { Self.spectrum(of: m, lines: lines) }
        let before = Tuning(m), centre = m.centerHz, sequence = m.signalID.tuning.current.sequence
        // The owner is recording: a scan inside the capture needs no retune, so it is allowed.
        m.startRecording(.audio)
        defer { m.stopRecording(.audio) }
        let r = await call(tools, "identify_signals",
                           ["from_hz": .number(m.centerHz - 450_000), "to_hz": .number(m.centerHz + 450_000)])
        #expect(!r.isError, "\(r.content)")
        let s = r.structured
        #expect(s?["pieces"]?.double == 1)
        #expect(s?["restored"]?.bool == true)
        #expect(s?["stopped_early"] == nil)
        let found = s?["signals"]?.array ?? []
        #expect(found.count == 3, "\(found)")
        // Lowest first, each with an identity, in display Hz.
        let hzs = found.compactMap { $0["hz"]?.double }
        #expect(hzs == hzs.sorted())
        for (hz, line) in zip(hzs, lines) { #expect(abs(hz - line) < 2_000, "\(hz) vs \(line)") }
        #expect(found.first?["identity"]?["name"]?.string == "RTTY")
        // The radio did not move.
        #expect(Tuning(m) == before)
        #expect(m.centerHz == centre)
        #expect(m.signalID.tuning.current.sequence == sequence)
        #expect(tools.lastRadioChange == nil)
    }

    @Test func scanKeepsToTheLevelAndCount() async {
        guard let (m, tools) = runningModel() else { return }
        defer { m.shutdown() }
        let lines = [m.centerHz - 300_000, m.centerHz + 40_000, m.centerHz + 400_000]
        tools.scanSpectrum = { Self.spectrum(of: m, lines: lines) }
        let range: [String: JSONValue] = ["from_hz": .number(m.centerHz - 450_000), "to_hz": .number(m.centerHz + 450_000)]
        let two = await call(tools, "identify_signals", range.merging(["max_signals": .number(2)]) { a, _ in a })
        #expect(two.structured?["signals"]?.array?.count == 2)
        #expect(two.structured?["truncated"]?.bool == true)
        // The lines stand 30 dB over the floor: 40 dB asks for more than there is.
        let strict = await call(tools, "identify_signals", range.merging(["min_snr_db": .number(40)]) { a, _ in a })
        #expect(strict.structured?["signals"]?.array == [])
    }

    @Test func scanAcrossPiecesRestoresTheTuning() async {
        guard let (m, tools) = runningModel() else { return }
        defer { m.shutdown() }
        m.setUpconverter(true)
        m.setMode(.lsb)
        m.setBandwidth(2_400)
        m.tune(to: 7_150_000)
        let before = Tuning(m), centre = m.centerHz
        let span = m.sampleRate
        let from = 6_000_000.0, to = from + 2.5 * span
        let lines = [from + 0.4 * span, from + 1.3 * span, from + 2.2 * span]
        tools.scanSpectrum = { Self.spectrum(of: m, lines: lines) }
        let visited = Shared<[Double]>([])
        tools.ringReady = { _ in
            visited.withLock { $0.append(m.centerHz) }
            return true
        }
        let r = await call(tools, "identify_signals", ["from_hz": .number(from), "to_hz": .number(to)], client: "scan-agent 1")
        #expect(!r.isError, "\(r.content)")
        let s = r.structured
        // It stepped: three pieces, three different centres, none of them where it began.
        #expect(s?["pieces"]?.double == 3)
        let centres = visited.withLock { $0 }
        #expect(centres.count == 3 && Set(centres).count == 3, "\(centres)")
        #expect(!centres.contains(centre))
        // And found each line, once, in display Hz (HamItUp is on).
        let hzs = (s?["signals"]?.array ?? []).compactMap { $0["hz"]?.double }
        #expect(hzs.count == 3, "\(hzs)")
        for (hz, line) in zip(hzs, lines) { #expect(abs(hz - line) < 2_000, "\(hz) vs \(line)") }
        // It put everything back.
        #expect(s?["restored"]?.bool == true)
        #expect(s?["stopped_early"] == nil)
        #expect(Tuning(m) == before)
        #expect(m.centerHz == centre)
        #expect(m.isRunning)
        // The change is the agent's, to a `listen` that was watching.
        let change = tools.lastRadioChange
        #expect(change?.client == "scan-agent 1")
    }

    @Test func scanRestoresWhenCancelled() async {
        guard let (m, tools) = runningModel() else { return }
        defer { m.shutdown() }
        m.setMode(.am)
        m.tune(to: 9_600_000)
        let before = Tuning(m), centre = m.centerHz
        let span = m.sampleRate
        let from = 6_000_000.0
        tools.scanSpectrum = { Self.spectrum(of: m, lines: []) }
        tools.ringWaitLimit = .seconds(30)
        let task = Task { @MainActor in
            await self.call(tools, "identify_signals", ["from_hz": .number(from), "to_hz": .number(from + 2.5 * span)])
        }
        // The first piece is reached; the second never fills its ring, and the call is cancelled while it waits.
        let waited = Shared(0)
        tools.ringReady = { _ in
            let n = waited.withLock { n -> Int in n += 1; return n }
            if n == 2 { task.cancel() }
            return n < 2
        }
        let r = await task.value
        #expect(r.isError)
        #expect(Tuning(m) == before)
        #expect(m.centerHz == centre)
        // The lock is free again: the next call does not wait.
        #expect(tools.radioWaiting == 0)
        let tuned = await call(tools, "tune", ["frequency": .number(9_610_000)])
        #expect(!tuned.isError)
    }

    @Test func scanRefusesWhileTheOwnerRecords() async {
        guard let (m, tools) = runningModel() else { return }
        defer { m.shutdown() }
        m.tune(to: 7_150_000)
        let before = Tuning(m), centre = m.centerHz, sequence = m.signalID.tuning.current.sequence
        let span = m.sampleRate
        let wide: [String: JSONValue] = ["from_hz": .number(6_000_000), "to_hz": .number(6_000_000 + 2.5 * span)]
        let exact = "The owner is recording: scan only within the current view, or ask the owner"

        m.startRecording(.audio)
        m.refreshRecordingStatus()
        #expect(m.recordingStatus[.audio]?.isRecording == true)
        let r = await call(tools, "identify_signals", wide)
        #expect(r.isError)
        #expect(r.content == exact)
        #expect(Tuning(m) == before)
        #expect(m.centerHz == centre)
        #expect(m.signalID.tuning.current.sequence == sequence)
        m.stopRecording(.audio)
        #expect(await eventually(3) { m.refreshRecordingStatus(); return !m.isRecordingAny })

        // An IQ recording splits its file at a retune: the same.
        m.startRecording(.iq)
        m.refreshRecordingStatus()
        let iq = await call(tools, "identify_signals", wide)
        #expect(iq.isError)
        #expect(iq.content == exact)
        m.stopRecording(.iq)
        #expect(await eventually(3) { m.refreshRecordingStatus(); return !m.isRecordingAny })

        // And Auto being on.
        m.autoRecordEnabled = true
        let auto = await call(tools, "identify_signals", wide)
        #expect(auto.isError)
        #expect(auto.content == exact)
        #expect(Tuning(m) == before)
        m.autoRecordEnabled = false
    }

    @Test func scanStopsWhenTheOwnerRetunes() async {
        guard let (m, tools) = runningModel() else { return }
        defer { m.shutdown() }
        m.tune(to: 7_150_000)
        let span = m.sampleRate
        let from = 6_000_000.0
        let lines = [from + 0.4 * span, from + 1.3 * span, from + 2.2 * span]
        tools.scanSpectrum = { Self.spectrum(of: m, lines: lines) }
        // The owner tunes elsewhere as the second piece's ring fills.
        let calls = Shared(0)
        tools.ringReady = { _ in
            let n = calls.withLock { n -> Int in n += 1; return n }
            if n == 2 { m.tune(to: 3_573_000) }
            return true
        }
        let r = await call(tools, "identify_signals", ["from_hz": .number(from), "to_hz": .number(from + 2.5 * span)])
        #expect(!r.isError, "\(r.content)")
        let s = r.structured
        #expect(s?["stopped_early"]?.string?.contains("owner") == true, "\(String(describing: s?["stopped_early"]))")
        // What the first piece found is kept; the owner's tuning is left alone, not fought.
        #expect(s?["pieces"]?.double == 1)
        #expect(s?["signals"]?.array?.count == 1)
        #expect(s?["restored"]?.bool == false)
        #expect(m.vfoHz == 3_573_000)
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func scanChecksItsArguments() async {
        guard let (m, tools) = runningModel() else { return }
        defer { m.shutdown() }
        let before = Tuning(m)
        let backwards = await call(tools, "identify_signals", ["from_hz": .number(7_100_000), "to_hz": .number(7_000_000)])
        #expect(backwards.isError)
        #expect(backwards.content.contains("from_hz must be below to_hz"))
        let missing = await call(tools, "identify_signals", ["from_hz": .number(7_000_000)])
        #expect(missing.isError)
        #expect(missing.content.contains("to_hz"))
        let unreachable = await call(tools, "identify_signals", ["from_hz": .number(1.9e9), "to_hz": .number(2.4e9)])
        #expect(unreachable.isError)
        #expect(unreachable.content.contains("outside what the RSP1B can tune"))
        let huge = await call(tools, "identify_signals", ["from_hz": .number(1e6), "to_hz": .number(1.5e9)])
        #expect(huge.isError)
        #expect(huge.content.contains("narrower"))
        #expect(Tuning(m) == before)

        let stopped = makeModel()
        let off = await call(SubFloorTools(model: stopped), "identify_signals",
                             ["from_hz": .number(7_000_000), "to_hz": .number(7_100_000)])
        #expect(off.isError)
        #expect(off.content.contains("start_radio"))
    }

    // MARK: get_cursor

    @Test func cursorCarriesSignal() async {
        guard let (m, tools) = runningModel() else { return }
        defer { m.shutdown() }
        m.setMode(.usb)
        m.tune(to: m.centerHz + 20_000)
        m.hover(at: CGPoint(x: 0.3, y: 0.1))
        let hovered = m.hover!.hz
        m.hover(at: nil)
        let r = await call(tools, "get_cursor")
        #expect(!r.isError, "\(r.content)")
        let s = r.structured
        let mouse = s?["mouse"]?["signal"]
        #expect(mouse?["name"]?.string == "RTTY")
        #expect(abs((mouse?["hz"]?.double ?? 0) - hovered) <= 1)
        #expect(mouse?["alternatives"]?.array?.first?["name"]?.string == "Olivia")
        #expect(mouse?["parameters"]?["symbol_rate_bd"]?.double == 45.45)
        // The VFO's is its passband's signal (an SSB passband lies beside the carrier).
        let vfo = s?["vfo"]?["signal"]
        #expect(vfo?["name"]?.string == "RTTY")
        let passband = m.vfoHz + m.mode.passbandOffset(bandwidth: m.bandwidthHz)
        #expect(abs((vfo?["hz"]?.double ?? 0) - passband) <= 1)
        // No decoder cursor, so none to identify.
        #expect(s?["decoder_cursor"] == .null)
    }

    @Test func cursorSkipsAMouseOlderThan30Seconds() async {
        guard let (m, tools) = runningModel() else { return }
        defer { m.shutdown() }
        m.hover(at: CGPoint(x: 0.3, y: 0.1))
        m.hover(at: nil)
        let now = Date()
        tools.now = { now.addingTimeInterval(29) }
        let fresh = await call(tools, "get_cursor")
        #expect(fresh.structured?["mouse"]?["signal"]?["name"]?.string == "RTTY")
        #expect(fresh.structured?["mouse"]?["signal_note"] == nil)

        tools.now = { now.addingTimeInterval(31) }
        let stale = await call(tools, "get_cursor")
        let mouse = stale.structured?["mouse"]
        #expect(mouse?["signal"] == .null)
        #expect(mouse?["signal_note"]?.string?.contains("30 s") == true)
        // The position is still reported; the VFO is identified regardless.
        #expect(mouse?["hz"]?.double != nil)
        #expect(stale.structured?["vfo"]?["signal"]?["name"]?.string == "RTTY")
    }

    @Test func cursorSaysWhyThereIsNoSignal() async {
        let m = makeModel()
        let tools = SubFloorTools(model: m)
        m.hover(at: CGPoint(x: 0.3, y: 0.1))
        let r = await call(tools, "get_cursor")
        #expect(r.structured?["mouse"]?["signal"] == .null)
        #expect(r.structured?["mouse"]?["signal_note"]?.string?.contains("stopped") == true)
        #expect(r.structured?["vfo"]?["signal"] == .null)
    }

    /// A slow signal's longer read does not hold the request up: the first answer comes back with
    /// `needs_longer_read`, and the longer read finishes behind it into the cache.
    @Test func cursorDoesNotWaitForTheLongerRead() async {
        let runs = Shared(0)
        let analysis: SignalIDService.Analysis = { iq, rate, centre, at, width, spectrum, longer in
            let n = runs.withLock { n -> Int in n += 1; return n }
            var id = SignalIdentity(measurement: SignalMeasurement(offsetHz: at - centre, occupiedBandwidthHz: 30, snrDb: 20,
                                                                   family: .carrier, familyConfidence: 0.8, seconds: 3))
            if longer == nil && n <= 1 {
                id.needsLongerRead = true
            } else {
                Thread.sleep(forTimeInterval: 1.5)   // the longer read, slowly
                id.best = ModeMatch(name: "WSPR", confidence: 0.9, evidence: [])
            }
            return id
        }
        guard let (m, tools) = runningModel(analysis: analysis) else { return }
        defer { m.shutdown() }
        m.setMode(.usb)
        m.tune(to: m.centerHz + 20_000)
        let started = Date()
        let first = await call(tools, "get_cursor")
        let took = Date().timeIntervalSince(started)
        #expect(took < 1.2, "took \(took) s")
        let signal = first.structured?["vfo"]?["signal"]
        #expect(signal?["needs_longer_read"]?.bool == true, "\(String(describing: signal))")
        #expect(signal?["name"] == .null)
        // A second call while it runs gets the same, at once.
        let again = await call(tools, "get_cursor")
        #expect(again.structured?["vfo"]?["signal"]?["needs_longer_read"]?.bool == true)
        // Later, the longer read's answer is the cached one.
        #expect(await eventually(8) { tools.cursorReads.isEmpty })
        let later = await call(tools, "get_cursor")
        #expect(later.structured?["vfo"]?["signal"]?["name"]?.string == "WSPR")
        #expect(later.structured?["vfo"]?["signal"]?["needs_longer_read"]?.bool == false)
    }

    // MARK: Descriptors

    @Test func signalToolSchemasSuitStrictClients() {
        let tools = SubFloorTools(model: makeModel()).tools
        let one = tools.first { $0.name == "identify_signal" }!
        let many = tools.first { $0.name == "identify_signals" }!
        #expect(one.readOnly)
        #expect(!many.readOnly)
        #expect(one.inputSchema["required"]?.array == [.string("frequency")])
        #expect(many.inputSchema["required"]?.array == [.string("from_hz"), .string("to_hz")])
        // Frequencies take a number or a string (as `tune` does); counts are integers, the rest numbers.
        #expect(one.inputSchema["properties"]?["frequency"]?["anyOf"]?.array?.count == 2)
        #expect(one.inputSchema["properties"]?["bandwidth_hz"]?["type"]?.string == "number")
        #expect(many.inputSchema["properties"]?["from_hz"]?["anyOf"]?.array?.count == 2)
        #expect(many.inputSchema["properties"]?["to_hz"]?["anyOf"]?.array?.count == 2)
        #expect(many.inputSchema["properties"]?["min_snr_db"]?["type"]?.string == "number")
        #expect(many.inputSchema["properties"]?["max_signals"]?["type"]?.string == "integer")
        for tool in [one, many] {
            #expect(tool.inputSchema["additionalProperties"] == nil)
            for (key, property) in tool.inputSchema["properties"]?.object ?? [:] {
                if case .array? = property["type"] { Issue.record("\(tool.name).\(key) has a type array") }
                #expect(property["description"]?.string?.isEmpty == false, "\(tool.name).\(key)")
            }
        }
    }
}
