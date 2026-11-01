import Foundation
import Modems
import Recording
import SDRplayKit
import SignalID
import SubFloorCore
import Synchronization
import Testing
@testable import SubFloor

/// A value shared with the closures the service runs off the main actor.
private final class Locked<Value: Sendable>: Sendable {
    private let value: Mutex<Value>
    init(_ value: Value) { self.value = Mutex(value) }
    func withLock<R>(_ body: (inout Value) -> R) -> R { value.withLock { body(&$0) } }
}

/// Task 7: Signal ID in the app. A demo-source model; the IQ is a synth snapshot through
/// `SignalIDService.snapshotProvider` (and the analysis a stub through `analysis` where the test is about the
/// service, not the identifier), except `readsTheRingAtTheDisplayCentre`, which reads the demo source's own ring.
@MainActor
struct SignalIDServiceTests {
    private static let view = CGSize(width: 1000, height: 500)

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A model running the demo source (never the real RSP), or nil where the engine can't start (no audio
    /// device: tolerated, as elsewhere).
    private func runningModel(preRollSeconds: Double? = nil) -> AppModel? {
        let dir = tempDir()
        let m = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                         defaults: UserDefaults(suiteName: UUID().uuidString)!,
                         openRSP: { throw SDRplayError.noDevice }, decodeHistoryFolder: dir)
        if let preRollSeconds { m.recording.preRollSeconds = preRollSeconds }
        m.useSource(.synthetic)
        guard m.isRunning else {
            print("engine did not start (tolerated, no audio device)")
            m.shutdown()
            return nil
        }
        return m
    }

    /// Waits (letting the main actor run) until `condition` holds or `seconds` pass.
    private func eventually(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline {
                await Task.yield()
                return condition()
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// `seconds` of `spec` at 48 kS/s, `offsetHz` from the capture centre.
    private static func snapshot(_ spec: SynthSpec, seconds: Double, offsetHz: Double,
                                 snrDb: Double = 20, seed: UInt64 = 3) -> IQSnapshot {
        IQSnapshot(samples: SignalSynth.make(spec, sampleRate: 48_000, seconds: seconds, snrDb: snrDb,
                                             offsetHz: offsetHz, seed: seed),
                   sampleRate: 48_000, endTime: Date())
    }

    /// A snapshot provider that gives the newest of `snap` (all of it when it is shorter than asked for, as a ring
    /// filling since a retune would), counting its calls. The "full" snapshots are 3.1 s: the service asks for 3 s
    /// and the 50 ms it drops after a retune.
    private static func provider(_ snap: IQSnapshot, calls: Locked<Int>? = nil) -> SignalIDService.SnapshotProvider {
        { lastSeconds in
            calls?.withLock { $0 += 1 }
            var newest = snap
            newest.samples = Array(snap.samples.suffix(2 * Int((lastSeconds * snap.sampleRate).rounded())))
            return newest
        }
    }

    /// The longer read from `snap`: its newest `lastSeconds`, a piece at a time.
    private static func chunks(_ snap: IQSnapshot) -> SignalIDService.ChunkProvider {
        { lastSeconds, chunkFrames, visit in
            let frames = min(snap.frames, Int((lastSeconds * snap.sampleRate).rounded()))
            let iq = snap.samples.suffix(2 * frames)
            var start = iq.startIndex
            while start < iq.endIndex {
                let end = min(start + 2 * chunkFrames, iq.endIndex)
                guard iq[start..<end].withUnsafeBufferPointer(visit) else { return nil }
                start = end
            }
            return IQRead(frames: frames, sampleRate: snap.sampleRate, endTime: snap.endTime)
        }
    }

    /// The real identifier, counting its runs.
    private static func counting(_ runs: Locked<Int>) -> SignalIDService.Analysis {
        { iq, rate, centre, at, width, spectrum, longer in
            runs.withLock { $0 += 1 }
            return SignalIdentifier.identify(iq: iq, sampleRate: rate, captureCenterHz: centre, atHz: at,
                                             bandwidthHz: width, spectrumDb: spectrum, longer: longer)
        }
    }

    /// A stub analysis: a 100 Hz signal centred where it was asked, named `name` when given.
    private static func stub(name: String? = nil, alternatives: [ModeMatch] = [], widthHz: Double = 100,
                             family: SignalFamily = .fsk, note: String? = nil, seconds: Double = 0,
                             asked: Locked<[Double]>? = nil) -> SignalIDService.Analysis {
        { _, _, centre, at, _, _, _ in
            asked?.withLock { $0.append(at) }
            if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
            return SignalIdentity(measurement: SignalMeasurement(offsetHz: at - centre, occupiedBandwidthHz: widthHz,
                                                                 family: family, familyConfidence: 0.8, seconds: 3),
                                  best: name.map { ModeMatch(name: $0, confidence: 0.8, evidence: []) },
                                  alternatives: alternatives, note: note)
        }
    }

    @Test func identifiesAtAFrequency() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let snap = Self.snapshot(.rtty(), seconds: 3.1, offsetHz: 5_000)
        m.signalID.snapshotProvider = Self.provider(snap)
        m.signalID.chunkProvider = Self.chunks(snap)
        let id = try #require(await m.signalID.identify(atHz: m.centerHz + 5_000))
        #expect(id.best?.name == "RTTY", "\(id.label)")
        #expect(abs(id.measurement.offsetHz - 5_000) < 50, "\(id.measurement.offsetHz)")
        #expect(!id.confirmedByDecode)
    }

    /// Nil means no data: the radio stopped (its ring may still hold IQ), or nothing in the ring.
    @Test func noDataIsNil() async {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        m.signalID.snapshotProvider = { _ in nil }
        #expect(await m.signalID.identify(atHz: m.centerHz + 5_000) == nil)
        m.signalID.snapshotProvider = Self.provider(Self.snapshot(.rtty(), seconds: 3.1, offsetHz: 5_000))
        m.stop()
        #expect(await m.signalID.identify(atHz: m.centerHz + 5_000) == nil)
    }

    /// A point on the same signal within 5 s reuses the result; a point elsewhere, or a retune, runs it again.
    @Test func cacheReusesNearbyPoints() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let runs = Locked(0)
        let snap = Self.snapshot(.rtty(), seconds: 3.1, offsetHz: 5_000)
        m.signalID.snapshotProvider = Self.provider(snap)
        m.signalID.chunkProvider = Self.chunks(snap)
        m.signalID.analysis = Self.counting(runs)
        let first = try #require(await m.signalID.identify(atHz: m.centerHz + 5_000))
        let near = try #require(await m.signalID.identify(atHz: m.centerHz + 5_040))
        #expect(runs.withLock { $0 } == 1)
        #expect(near == first)
        _ = await m.signalID.identify(atHz: m.centerHz - 9_000)   // noise, away from it
        #expect(runs.withLock { $0 } == 2)
        // A retune forgets it.
        m.setVFO(m.centerHz + 0.6 * m.sampleRate)
        _ = await m.signalID.identify(atHz: m.centerHz + 5_000)
        #expect(runs.withLock { $0 } == 3)
    }

    /// Half a second of IQ since the retune: the identifier's note, and nothing cached (the ring is filling).
    @Test func tooSoonAfterTuning() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let calls = Locked(0)
        m.signalID.snapshotProvider = Self.provider(Self.snapshot(.rtty(), seconds: 0.5, offsetHz: 5_000), calls: calls)
        let id = try #require(await m.signalID.identify(atHz: m.centerHz + 5_000))
        #expect(id.note == "Too soon after tuning — try again", "\(id.label)")
        #expect(id.best == nil)
        _ = await m.signalID.identify(atHz: m.centerHz + 5_000)
        #expect(calls.withLock { $0 } == 2)
    }

    /// An FT8 slot decode at the signal, within the last 60 s: confirmed, at 1.0. An older one, or a decode of a
    /// mode the ID named otherwise, doesn't confirm.
    @Test func decodeConfirms() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        m.setMode(.usb)
        m.tune(to: 14_074_000)
        try await Task.sleep(for: .milliseconds(300))   // the modem's reset for the tune (it clears the rows) lands
        // FT8 reports tone 0; the signal's centre is 3.5 tones (21.9 Hz) above it.
        let rf = m.modemBox.rfHz(forAudio: 1_500 + 3.5 * FT8Encoder.toneSpacing)
        let now = Date()
        var log = DecodeLog()
        log.apply(signals: nil, text: [], slotDecodes: [
            SlotDecode(mode: .ft8, slotStart: now.addingTimeInterval(-20), frequencyHz: 1_500, snrDb: -12,
                       timeOffset: 0.2, message: "CQ K1ABC FN42"),
        ], now: now)
        m.showDecodeLog(log)
        m.signalID.snapshotProvider = Self.provider(Self.snapshot(.noise, seconds: 3.1, offsetHz: 0))
        let ft8 = ModeMatch(name: "FT8 / FT4", confidence: 0.5, evidence: [])
        m.signalID.analysis = Self.stub(alternatives: [ft8], widthHz: 50)

        let id = try #require(await m.signalID.identify(atHz: rf + 5))
        #expect(id.confirmedByDecode)
        #expect(id.best?.name == "FT8 / FT4")
        #expect(id.best?.confidence == 1)
        #expect(!id.alternatives.contains { $0.name == "FT8 / FT4" })

        // Named otherwise: no confirmation.
        m.showDecodeLog(log)
        m.signalID.invalidateCache()
        m.signalID.analysis = Self.stub(name: "RTTY", widthHz: 50)
        let rtty = try #require(await m.signalID.identify(atHz: rf))
        #expect(!rtty.confirmedByDecode && rtty.best?.name == "RTTY" && rtty.best?.confidence == 0.8)

        // A decode from two minutes ago: no confirmation.
        var old = DecodeLog()
        old.apply(signals: nil, text: [], slotDecodes: [
            SlotDecode(mode: .ft8, slotStart: now.addingTimeInterval(-120), frequencyHz: 1_500, snrDb: -12,
                       timeOffset: 0.2, message: "CQ K1ABC FN42"),
        ], now: now)
        m.showDecodeLog(old)
        m.signalID.invalidateCache()
        m.signalID.analysis = Self.stub(alternatives: [ft8], widthHz: 50)
        let stale = try #require(await m.signalID.identify(atHz: rf))
        #expect(!stale.confirmedByDecode && stale.best == nil)
    }

    /// R28: with nothing named, a decode confirms only a mode the answer offers, or one whose family it measured;
    /// never "No signal" or "Too weak" (nothing measured to agree with).
    @Test func decodeConfirmsOnlyAConsistentUnnamedSignal() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        m.setMode(.usb)
        m.tune(to: 14_074_000)
        try await Task.sleep(for: .milliseconds(300))   // the modem's reset for the tune (it clears the rows) lands
        let rf = m.modemBox.rfHz(forAudio: 1_500 + 3.5 * FT8Encoder.toneSpacing)
        let now = Date()
        var log = DecodeLog()
        log.apply(signals: nil, text: [], slotDecodes: [
            SlotDecode(mode: .ft8, slotStart: now.addingTimeInterval(-20), frequencyHz: 1_500, snrDb: -12,
                       timeOffset: 0.2, message: "CQ K1ABC FN42"),
        ], now: now)
        m.showDecodeLog(log)
        m.signalID.snapshotProvider = Self.provider(Self.snapshot(.noise, seconds: 3.1, offsetHz: 0))
        func identify(_ analysis: @escaping SignalIDService.Analysis) async throws -> SignalIdentity {
            m.showDecodeLog(log)   // again: the modem's reset for the tune clears the rows when its batch lands
            m.signalID.invalidateCache()
            m.signalID.analysis = analysis
            return try #require(await m.signalID.identify(atHz: rf))
        }
        let noSignal = try await identify(Self.stub(widthHz: 0, family: .noise, note: "No signal"))
        #expect(!noSignal.confirmedByDecode && noSignal.best == nil && noSignal.note == "No signal")
        let tooWeak = try await identify(Self.stub(widthHz: 0, family: .unknown,
                                                   note: "Too weak to identify (SNR 2 dB)"))
        #expect(!tooWeak.confirmedByDecode && tooWeak.best == nil)
        // A PSK signal with no FT8 among its alternatives: inconsistent.
        let psk = try await identify(Self.stub(widthHz: 50, family: .psk))
        #expect(!psk.confirmedByDecode && psk.best == nil)
        // An unnamed FSK (FT8's family) is.
        let fsk = try await identify(Self.stub(widthHz: 50, family: .fsk))
        #expect(fsk.confirmedByDecode && fsk.best?.name == "FT8 / FT4" && fsk.best?.confidence == 1)
    }

    /// A first read shorter than the 3 s asked for (but over the 1 s the identifier needs) says so in `note`, and
    /// isn't cached: the ring is still filling.
    @Test func aShortFirstReadIsSaid() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let calls = Locked(0)
        m.signalID.snapshotProvider = Self.provider(Self.snapshot(.rtty(), seconds: 1.5, offsetHz: 5_000), calls: calls)
        let id = try #require(await m.signalID.identify(atHz: m.centerHz + 5_000))
        // 1.5 s, less the 50 ms after the barrier.
        let said = String(format: "Read %.1f s of the 3 s asked for", 1.45)
        #expect(id.note?.contains(said) == true, "\(id.note ?? "no note")")
        _ = await m.signalID.identify(atHz: m.centerHz + 5_000)
        #expect(calls.withLock { $0 } == 2)
    }

    /// A retune while the analysis runs: the answer is dropped (nil), and nothing is cached for the old centre.
    @Test func aRetuneWhileItRunsDropsTheAnswer() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let asked = Locked<[Double]>([])
        m.signalID.snapshotProvider = Self.provider(Self.snapshot(.noise, seconds: 3.1, offsetHz: 0))
        m.signalID.analysis = Self.stub(seconds: 0.5, asked: asked)
        let at = m.centerHz + 5_000
        let running = Task { await m.signalID.identify(atHz: at) }
        #expect(await eventually { asked.withLock { $0.count } == 1 })
        m.setVFO(m.centerHz + 0.6 * m.sampleRate)
        #expect(await running.value == nil)
        m.signalID.analysis = Self.stub(asked: asked)
        _ = await m.signalID.identify(atHz: at)
        #expect(asked.withLock { $0.count } == 2)
    }

    /// A longer read that fails (the ring overwrote it, or was reconfigured) says so in `note`; the first read's
    /// answer stands, still wanting the longer read, and isn't cached.
    @Test func aFailedLongerReadIsSaid() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let reads = Locked(0)
        m.signalID.snapshotProvider = Self.provider(Self.snapshot(.noise, seconds: 3.1, offsetHz: 0))
        m.signalID.chunkProvider = { _, _, _ in
            reads.withLock { $0 += 1 }
            return nil
        }
        m.signalID.analysis = { _, _, centre, at, _, _, _ in
            SignalIdentity(measurement: SignalMeasurement(offsetHz: at - centre, occupiedBandwidthHz: 50,
                                                          family: .carrier, seconds: 3),
                           needsLongerRead: true)
        }
        let id = try #require(await m.signalID.identify(atHz: m.centerHz + 5_000))
        #expect(id.note == "The longer read failed; this is the first read's answer")
        #expect(id.needsLongerRead)
        _ = await m.signalID.identify(atHz: m.centerHz + 5_000)
        #expect(reads.withLock { $0 } == 2)
    }

    /// I1: a short pre-roll (5 s, under the 16 s asked for) on the demo source's own ring, the writer pushing
    /// throughout: the longer read gets what the ring holds instead of failing against the writer.
    @Test func aShortPreRollGivesTheLongerReadWhatItHolds() async throws {
        guard let m = runningModel(preRollSeconds: 5) else { return }
        defer { m.shutdown() }
        let r = m.engine.iqRecorder
        #expect(await eventually(120) { r.status.preRollFill >= 1 })
        let second = Locked<(frames: Int, rate: Double)?>(nil)
        let fs = m.sampleRate
        m.signalID.analysis = { iq, rate, centre, at, _, _, _ in
            if rate < fs { second.withLock { $0 = (iq.count / 2, rate) } }
            return SignalIdentity(measurement: SignalMeasurement(offsetHz: at - centre, occupiedBandwidthHz: 50,
                                                                 family: .carrier, seconds: 3),
                                  needsLongerRead: rate >= fs)
        }
        let id = try #require(await m.signalID.identify(atHz: m.vfoHz + 1_000))
        let got = try #require(second.withLock { $0 }, "no longer read: \(id.note ?? "no note")")
        let seconds = Double(got.frames) / got.rate
        #expect(seconds > 4 && seconds <= 5.01, "\(seconds) s")
    }

    /// R26: the longer read is never held at the radio's rate. A 16 s read of a 2 MS/s capture comes off the ring
    /// in pieces of at most 0.5 s and is cut to a 48 kHz channel around the signal as it comes: the second pass
    /// gets 16 s at 250 kS/s (32 MB), centred on the signal, with the signal where it should be in it, and its
    /// measurement comes back in the capture's frame.
    @Test func longerReadIsChannelisedPieceByPiece() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let fs = 2_000_000.0, signalHz = 10_000.0, toneHz = 11_000.0   // a tone 1 kHz above the signal's centre
        let firstAsked = Locked(0.0)
        m.signalID.snapshotProvider = { seconds in
            firstAsked.withLock { $0 = max($0, seconds) }
            return IQSnapshot(samples: [Float](repeating: 0, count: 2 * Int(seconds * fs)), sampleRate: fs,
                              endTime: Date())
        }
        // Whole cycles in each 1M-frame piece, so piece after piece is one continuous tone.
        let piece = (0..<1_000_000).flatMap { k -> [Float] in
            let phase = 2 * Double.pi * toneHz * Double(k) / fs
            return [Float(cos(phase)), Float(sin(phase))]
        }
        let largestPiece = Locked(0), asked = Locked(0.0)
        m.signalID.chunkProvider = { seconds, chunkFrames, visit in
            asked.withLock { $0 = seconds }
            let frames = Int((seconds * fs).rounded())
            var done = 0
            while done < frames {
                let n = min(chunkFrames, frames - done, piece.count / 2)
                largestPiece.withLock { $0 = max($0, n) }
                guard piece[0..<(2 * n)].withUnsafeBufferPointer(visit) else { return nil }
                done += n
            }
            return IQRead(frames: frames, sampleRate: fs, endTime: Date())
        }
        let second = Locked<(frames: Int, rate: Double, centre: Double, longer: Int, toneDb: Double)?>(nil)
        m.signalID.analysis = { iq, rate, centre, _, _, _, longer in
            guard rate < fs else {
                return SignalIdentity(measurement: SignalMeasurement(offsetHz: signalHz, occupiedBandwidthHz: 50,
                                                                     family: .carrier, seconds: 3),
                                      needsLongerRead: true)
            }
            // The tone's level at +1 kHz in the channel, over a quieter frequency's (dB).
            func level(_ hz: Double) -> Double {
                var re = 0.0, im = 0.0
                for k in 0..<25_000 {
                    let w = -2 * Double.pi * hz * Double(k) / rate
                    re += Double(iq[2 * k]) * cos(w) - Double(iq[2 * k + 1]) * sin(w)
                    im += Double(iq[2 * k]) * sin(w) + Double(iq[2 * k + 1]) * cos(w)
                }
                return re * re + im * im
            }
            let toneDb = 10 * log10(level(toneHz - signalHz) / max(level(-(toneHz - signalHz)), 1e-30))
            second.withLock { $0 = (iq.count / 2, rate, centre, longer?()?.iq.count ?? 0, toneDb) }
            return SignalIdentity(measurement: SignalMeasurement(offsetHz: 3, occupiedBandwidthHz: 50,
                                                                 family: .carrier, seconds: 16))
        }
        let id = try #require(await m.signalID.identify(atHz: m.centerHz + signalHz))
        let got = try #require(second.withLock { $0 })
        #expect(firstAsked.withLock { $0 } < 3.1)   // the full rate only for the first pass's 3 s
        #expect(asked.withLock { $0 } >= 16)
        #expect(largestPiece.withLock { $0 } <= 1_000_000)
        #expect(got.rate == 250_000)
        #expect(got.frames == 4_000_000, "\(got.frames)")
        // The peak, from the same read made directly: the channel as reserved before the read (and never
        // outgrown, so never reallocated by doubling) and one piece, its bytes and its floats (at most float32's
        // 8 bytes a frame each).
        let barrier = TuneBarrier()
        barrier.end(centerHz: m.centerHz)
        guard case .read(let long) = SignalIDService.longerRead(offsetHz: signalHz, widthHz: 50,
                                                                tuning: barrier.current, sampleRate: fs,
                                                                chunks: m.signalID.chunkProvider,
                                                                barrier: barrier) else {
            Issue.record("no longer read")
            return
        }
        let channelBytes = long.reservedFloats * MemoryLayout<Float>.size
        let pieceBytes = 2 * largestPiece.withLock { $0 } * 8
        #expect(!long.grew)
        #expect(long.iq.count == 2 * got.frames)
        #expect(channelBytes <= 33 << 20, "channel \(channelBytes) bytes reserved")
        #expect(channelBytes + pieceBytes <= 64 << 20, "peak \(channelBytes + pieceBytes) bytes")
        #expect(got.longer == 2 * got.frames)
        #expect(got.centre == m.centerHz + signalHz)
        #expect(got.toneDb > 40, "\(got.toneDb) dB")
        #expect(id.measurement.offsetHz == signalHz + 3)
    }

    /// The snapshot and the analysis run off the main thread, and the main actor keeps running meanwhile: a probe
    /// ticking on it every 10 ms ticks while the (1.5 s) analysis runs. Other suites can hold the main actor for a
    /// while, so it asks for one tick inside the analysis, not for no gap.
    @Test func nothingOnTheMainThread() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let offMain = Locked((snapshot: true, analysis: true))
        let window = Locked<(start: Date, end: Date)?>(nil)
        let snap = Self.snapshot(.rtty(), seconds: 3.1, offsetHz: 5_000)
        m.signalID.snapshotProvider = { _ in
            let main = Thread.isMainThread
            offMain.withLock { $0.snapshot = $0.snapshot && !main }
            return snap
        }
        let analysis = Self.stub(seconds: 1.5)
        m.signalID.analysis = { iq, rate, centre, at, width, spectrum, longer in
            let main = Thread.isMainThread
            offMain.withLock { $0.analysis = $0.analysis && !main }
            let start = Date()
            defer { window.withLock { $0 = (start, Date()) } }
            return analysis(iq, rate, centre, at, width, spectrum, longer)
        }
        // The stall probe: when the main actor ran a tick.
        let probe = Task { @MainActor in
            var ticks: [Date] = []
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                ticks.append(Date())
            }
            return ticks
        }
        try await Task.sleep(for: .milliseconds(50))   // the probe is ticking
        let id = await m.signalID.identify(atHz: m.centerHz + 5_000)
        probe.cancel()
        let ticks = await probe.value
        #expect(id != nil)
        #expect(offMain.withLock { $0.snapshot && $0.analysis })
        let ran = try #require(window.withLock { $0 })
        let during = ticks.filter { $0 > ran.start.addingTimeInterval(0.05) && $0 < ran.end.addingTimeInterval(-0.05) }
        #expect(!during.isEmpty, "the main actor never ran during the \(ran.end.timeIntervalSince(ran.start)) s analysis")
    }

    /// Half a second's dwell starts it (`hoverPending` while it runs); a move of more than 3 px cancels it and
    /// starts the dwell again, a smaller one doesn't; leaving clears it.
    @Test func hoverDwellsAndMovesCancel() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let asked = Locked<[Double]>([])
        m.signalID.snapshotProvider = Self.provider(Self.snapshot(.noise, seconds: 3.1, offsetHz: 0))
        m.signalID.analysis = Self.stub(asked: asked)

        m.hover(at: CGPoint(x: 0.50, y: 0.2), viewSize: Self.view)
        m.hover(at: CGPoint(x: 0.52, y: 0.2), viewSize: Self.view)   // 20 px: the first dwell is cancelled
        let hz = m.hover!.hz
        #expect(!m.signalID.hoverPending && m.signalID.hoverIdentity == nil)
        #expect(await eventually { m.signalID.hoverIdentity != nil })
        #expect(asked.withLock { $0 } == [hz])
        #expect(!m.signalID.hoverPending)
        let shown = try #require(m.signalID.hoverIdentity)
        #expect(abs(shown.measurement.offsetHz - (hz - m.centerHz)) < 1e-6)

        m.hover(at: CGPoint(x: 0.5215, y: 0.2), viewSize: Self.view)   // 1.5 px: the same point
        try await Task.sleep(for: .milliseconds(800))
        #expect(m.signalID.hoverIdentity == shown)
        #expect(asked.withLock { $0.count } == 1)

        m.hover(at: CGPoint(x: 0.53, y: 0.2), viewSize: Self.view)   // 8.5 px: a new point
        #expect(m.signalID.hoverIdentity == nil)
        m.hover(at: nil, viewSize: Self.view)
        try await Task.sleep(for: .milliseconds(800))
        #expect(asked.withLock { $0.count } == 1)
        #expect(m.signalID.hoverIdentity == nil && !m.signalID.hoverPending)
    }

    /// A move while an identification runs cancels it: its answer never shows, the new point's does.
    @Test func aNewHoverCancelsTheRunningOne() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let asked = Locked<[Double]>([])
        m.signalID.snapshotProvider = Self.provider(Self.snapshot(.noise, seconds: 3.1, offsetHz: 0))
        m.signalID.analysis = Self.stub(seconds: 1, asked: asked)

        m.hover(at: CGPoint(x: 0.3, y: 0.2), viewSize: Self.view)
        #expect(await eventually { m.signalID.hoverPending })
        m.hover(at: CGPoint(x: 0.7, y: 0.2), viewSize: Self.view)
        let second = m.hover!.hz
        #expect(!m.signalID.hoverPending)
        #expect(await eventually { m.signalID.hoverIdentity != nil })
        try await Task.sleep(for: .milliseconds(300))   // past the first analysis' end
        let id = try #require(m.signalID.hoverIdentity)
        #expect(abs(id.measurement.offsetHz - (second - m.centerHz)) < 1e-6)
        // The first ran its analysis or, cancelled before it began, never did.
        #expect((1...2).contains(asked.withLock { $0.count }))
    }

    /// The demo source's own ring, HamItUp on: the capture centre handed to the analysis is the display centre
    /// (not the hardware's, LO Hz above), the rate the radio's, and the IQ no more than the ring holds since the
    /// toggle's retune.
    @Test func readsTheRingAtTheDisplayCentre() async throws {
        guard let m = runningModel(preRollSeconds: 5) else { return }
        defer { m.shutdown() }
        let seen = Locked<(frames: Int, rate: Double, centre: Double, at: Double)?>(nil)
        m.signalID.analysis = { iq, rate, centre, at, _, _, _ in
            seen.withLock { $0 = (iq.count / 2, rate, centre, at) }
            return SignalIdentity(measurement: SignalMeasurement(seconds: Double(iq.count / 2) / rate))
        }
        let r = m.engine.iqRecorder
        m.setUpconverter(true)
        let before = r.headFrame
        #expect(await eventually(20) { r.headFrame > before + Int(0.3 * m.sampleRate) })
        let at = m.vfoHz + 1_000
        let id = await m.signalID.identify(atHz: at)
        let head = r.headFrame
        #expect(id != nil)
        let got = try #require(seen.withLock { $0 })
        #expect(m.upconverter.enabled && m.centerHz < m.upconverter.loHz)
        #expect(got.centre == m.centerHz)
        #expect(got.at == at)
        #expect(got.rate == m.sampleRate)
        #expect(got.frames > 0 && got.frames <= head - before, "\(got.frames) of \(head - before)")
    }
}
