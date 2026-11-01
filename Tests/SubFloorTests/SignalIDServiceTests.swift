import Accelerate
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

    /// Waits (letting the main actor run) until `condition` holds or `seconds` pass. The bound only ends a failing
    /// wait: one that holds returns at once, however loaded the run (I2).
    private func eventually(_ seconds: Double = 120, _ condition: () -> Bool) async -> Bool {
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
    nonisolated private static func snapshot(_ spec: SynthSpec, seconds: Double, offsetHz: Double,
                                 snrDb: Double = 20, seed: UInt64 = 3) -> IQSnapshot {
        IQSnapshot(samples: SignalSynth.make(spec, sampleRate: 48_000, seconds: seconds, snrDb: snrDb,
                                             offsetHz: offsetHz, seed: seed),
                   sampleRate: 48_000, endTime: Date())
    }

    /// A snapshot provider that gives the newest of `snap` (all of it when it is shorter than asked for, as a ring
    /// filling since a retune would), counting its reads (not the millisecond probe of the ring's rate before each).
    /// The "full" snapshots are 3.1 s: the service asks for 3 s and the 50 ms it drops after a retune.
    nonisolated private static func provider(_ snap: IQSnapshot, calls: Locked<Int>? = nil) -> SignalIDService.SnapshotProvider {
        { lastSeconds in
            if lastSeconds > SignalIDService.probeSeconds { calls?.withLock { $0 += 1 } }
            var newest = snap
            newest.samples = Array(snap.samples.suffix(2 * Int((lastSeconds * snap.sampleRate).rounded())))
            return newest
        }
    }

    /// The longer read from `snap`: its newest `lastSeconds`, a piece at a time.
    nonisolated private static func chunks(_ snap: IQSnapshot) -> SignalIDService.ChunkProvider {
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

    /// USB at 14.074 MHz, for FT8 decodes, with the modem's reset for the tune taken out of its queue here (the rows
    /// a test shows next are never cleared by that reset's batch landing late), and the service's clock held at
    /// `now`: a decode's age is the test's, however long a loaded run takes to identify (a slot 20 s old went past
    /// the 60 s while the full suite starved the main actor).
    private func tuneForFT8(_ m: AppModel, now: Date) {
        m.setMode(.usb)
        m.tune(to: 14_074_000)
        _ = m.engine.modemEvents.drain()
        m.signalID.now = { now }
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
    nonisolated private static func stub(name: String? = nil, alternatives: [ModeMatch] = [], widthHz: Double = 100,
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

    /// Nil means no data: nothing in the ring. With the radio stopped the ring still holds what it heard last, and
    /// that is read (the spec's "uses whatever is in the ring, or says there is no data").
    @Test func noDataIsNil() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        m.signalID.snapshotProvider = { _ in nil }
        #expect(await m.signalID.identify(atHz: m.centerHz + 5_000) == nil)
        m.stop()
        #expect(await m.signalID.identify(atHz: m.centerHz + 5_000) == nil)
        let snap = Self.snapshot(.rtty(), seconds: 3.1, offsetHz: 5_000)
        m.signalID.snapshotProvider = Self.provider(snap)
        m.signalID.chunkProvider = Self.chunks(snap)
        let id = try #require(await m.signalID.identify(atHz: m.centerHz + 5_000))
        #expect(id.best?.name == "RTTY", "\(id.label)")
    }

    /// A point on the same signal within 5 s reuses the result, and an empty point its own; a point elsewhere, or a
    /// retune, runs it again.
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
        // "No signal" is kept for its point: asked again (a get_cursor poll), it isn't read again.
        _ = await m.signalID.identify(atHz: m.centerHz - 9_000)
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
        let now = Date()
        tuneForFT8(m, now: now)
        // FT8 reports tone 0; the signal's centre is 3.5 tones (21.9 Hz) above it.
        let rf = m.modemBox.rfHz(forAudio: 1_500 + 3.5 * FT8Encoder.toneSpacing)
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
        let now = Date()
        tuneForFT8(m, now: now)
        let rf = m.modemBox.rfHz(forAudio: 1_500 + 3.5 * FT8Encoder.toneSpacing)
        var log = DecodeLog()
        log.apply(signals: nil, text: [], slotDecodes: [
            SlotDecode(mode: .ft8, slotStart: now.addingTimeInterval(-20), frequencyHz: 1_500, snrDb: -12,
                       timeOffset: 0.2, message: "CQ K1ABC FN42"),
        ], now: now)
        m.showDecodeLog(log)
        m.signalID.snapshotProvider = Self.provider(Self.snapshot(.noise, seconds: 3.1, offsetHz: 0))
        func identify(_ analysis: @escaping SignalIDService.Analysis) async throws -> SignalIdentity {
            m.showDecodeLog(log)
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

    /// A retune while the analysis runs: the answer is dropped (nil), and nothing is cached for the old centre. The
    /// analysis waits (bounded, 120 s) for the test's gate, opened after the retune: no race against its length.
    @Test func aRetuneWhileItRunsDropsTheAnswer() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let asked = Locked<[Double]>([])
        let retuned = Locked(false), started = Locked(false)
        m.signalID.snapshotProvider = Self.provider(Self.snapshot(.noise, seconds: 3.1, offsetHz: 0))
        let inner = Self.stub(asked: asked)
        m.signalID.analysis = { iq, rate, centre, at, width, spectrum, longer in
            started.withLock { $0 = true }
            let deadline = Date().addingTimeInterval(120)
            while !retuned.withLock({ $0 }), Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            return inner(iq, rate, centre, at, width, spectrum, longer)
        }
        let at = m.centerHz + 5_000
        let running = Task { await m.signalID.identify(atHz: at) }
        #expect(await eventually { started.withLock { $0 } })
        m.setVFO(m.centerHz + 0.6 * m.sampleRate)
        retuned.withLock { $0 = true }
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
        #expect(await eventually { r.status.preRollFill >= 1 })
        let second = Locked<(frames: Int, rate: Double)?>(nil)
        m.signalID.analysis = { iq, rate, centre, at, _, _, longer in
            if longer != nil { second.withLock { $0 = (iq.count / 2, rate) } }
            return SignalIdentity(measurement: SignalMeasurement(offsetHz: at - centre, occupiedBandwidthHz: 50,
                                                                 family: .carrier, seconds: 3),
                                  needsLongerRead: longer == nil)
        }
        let id = try #require(await m.signalID.identify(atHz: m.vfoHz + 1_000))
        let got = try #require(second.withLock { $0 }, "no longer read: \(id.note ?? "no note")")
        let seconds = Double(got.frames) / got.rate
        #expect(seconds > 4 && seconds <= 5.01, "\(seconds) s")
    }

    /// R26: the longer read is never held at the radio's rate. A 16 s read of a 2 MS/s capture comes off the ring
    /// in pieces of at most 0.5 s and is cut to a 48 kHz channel around the signal as it comes: the second pass
    /// gets 16 s at 250 kS/s (32 MB), centred on the signal, with the signal where it should be in it, and its
    /// measurement comes back in the capture's frame. (Above 1 MS/s the first read is a channel too, I1: the
    /// snapshot is only probed for the ring's rate.)
    @Test func longerReadIsChannelisedPieceByPiece() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let fs = 2_000_000.0, signalHz = 10_000.0, toneHz = 11_000.0   // a tone 1 kHz above the signal's centre
        let captureCentre = m.centerHz
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
            guard longer != nil else {   // the first pass, on its own channel: the signal in that channel's frame
                return SignalIdentity(measurement: SignalMeasurement(offsetHz: captureCentre + signalHz - centre,
                                                                     occupiedBandwidthHz: 50, family: .carrier,
                                                                     seconds: 3),
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
        #expect(firstAsked.withLock { $0 } <= SignalIDService.probeSeconds)   // never the capture whole
        #expect(asked.withLock { $0 } >= 16)
        #expect(largestPiece.withLock { $0 } <= 1_000_000)
        #expect(got.rate == 250_000)
        #expect(got.frames == 4_000_000, "\(got.frames)")
        // The peak, from the same read made directly: the channel as reserved before the read (and never
        // outgrown, so never reallocated by doubling) and one piece, its bytes and its floats (at most float32's
        // 8 bytes a frame each).
        // (Off the main actor: 16 s at 2 MS/s through the channel would hold up every main-actor test meanwhile.)
        let barrier = TuneBarrier()
        barrier.end(centerHz: m.centerHz)
        let chunks = m.signalID.chunkProvider
        let direct = await Task.detached {
            SignalIDService.longerRead(offsetHz: signalHz, widthHz: 50, tuning: barrier.current, sampleRate: fs,
                                       chunks: chunks, barrier: barrier)
        }.value
        guard case .read(let long) = direct else {
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
        #expect(abs(id.measurement.offsetHz - (signalHz + 3)) < 1e-6)
    }

    /// The snapshot and the analysis run off the main thread, and the main actor keeps running meanwhile: a probe
    /// on it counts a tick every 10 ms, and the analysis does not return until a tick has come after it began (it
    /// gives up after 120 s, and the test says so). No wall-clock window: how long other suites hold the main actor
    /// doesn't matter, only that it runs while the analysis is waiting.
    @Test func nothingOnTheMainThread() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let offMain = Locked((snapshot: true, analysis: true))
        let ticks = Locked(0)
        let ticked = Locked(false)
        let snap = Self.snapshot(.rtty(), seconds: 3.1, offsetHz: 5_000)
        m.signalID.snapshotProvider = { _ in
            let main = Thread.isMainThread
            offMain.withLock { $0.snapshot = $0.snapshot && !main }
            return snap
        }
        let analysis = Self.stub()
        m.signalID.analysis = { iq, rate, centre, at, width, spectrum, longer in
            let main = Thread.isMainThread
            offMain.withLock { $0.analysis = $0.analysis && !main }
            let before = ticks.withLock { $0 }
            let deadline = Date().addingTimeInterval(120)
            while ticks.withLock({ $0 }) <= before, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            ticked.withLock { $0 = ticks.withLock { $0 } > before }
            return analysis(iq, rate, centre, at, width, spectrum, longer)
        }
        let probe = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                ticks.withLock { $0 += 1 }
            }
        }
        let id = await m.signalID.identify(atHz: m.centerHz + 5_000)
        probe.cancel()
        #expect(id != nil)
        #expect(offMain.withLock { $0.snapshot && $0.analysis })
        #expect(ticked.withLock { $0 }, "the main actor never ran while the analysis waited")
    }

    /// The dwell (a gate here: Task 7's is `dwellSeconds`) starts it; a move of more than 3 px cancels it and starts
    /// the dwell again, a smaller one doesn't; leaving clears it. Every state is one the test holds: no wall clock.
    @Test func hoverDwellsAndMovesCancel() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let asked = Locked<[Double]>([])
        let dwells = Locked(0), dwellsEnded = Locked(0), open = Locked(false)
        m.signalID.snapshotProvider = Self.provider(Self.snapshot(.noise, seconds: 3.1, offsetHz: 0))
        m.signalID.analysis = Self.stub(asked: asked)
        m.signalID.dwell = {
            dwells.withLock { $0 += 1 }
            while !open.withLock({ $0 }), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            dwellsEnded.withLock { $0 += 1 }
        }

        m.hover(at: CGPoint(x: 0.50, y: 0.2), viewSize: Self.view)
        m.hover(at: CGPoint(x: 0.52, y: 0.2), viewSize: Self.view)   // 20 px: the first dwell is cancelled
        let hz = m.hover!.hz
        #expect(!m.signalID.hoverPending && m.signalID.hoverIdentity == nil)
        #expect(await eventually { dwells.withLock { $0 } == 2 && dwellsEnded.withLock { $0 } == 1 })
        #expect(asked.withLock { $0 }.isEmpty)
        open.withLock { $0 = true }                                   // the rest ends the second dwell
        #expect(await eventually { m.signalID.hoverIdentity != nil })
        #expect(asked.withLock { $0 } == [hz])
        #expect(!m.signalID.hoverPending)
        let shown = try #require(m.signalID.hoverIdentity)
        #expect(abs(shown.measurement.offsetHz - (hz - m.centerHz)) < 1e-6)

        m.hover(at: CGPoint(x: 0.5215, y: 0.2), viewSize: Self.view)   // 1.5 px: the same point, no new dwell
        #expect(dwells.withLock { $0 } == 2)
        #expect(m.signalID.hoverIdentity == shown)

        open.withLock { $0 = false }
        m.hover(at: CGPoint(x: 0.53, y: 0.2), viewSize: Self.view)   // 8.5 px: a new point, dwelling
        #expect(m.signalID.hoverIdentity == nil)
        #expect(await eventually { dwells.withLock { $0 } == 3 })
        m.hover(at: nil, viewSize: Self.view)                         // leaving cancels that dwell
        #expect(await eventually { dwellsEnded.withLock { $0 } == 3 })
        await Task.yield()
        #expect(asked.withLock { $0.count } == 1)
        #expect(m.signalID.hoverIdentity == nil && !m.signalID.hoverPending)
    }

    /// A move while an identification runs cancels it: its answer never shows, the new point's does. The first
    /// point's analysis holds until it is cancelled (`hoverPending` meanwhile), so the move always lands mid-run.
    @Test func aNewHoverCancelsTheRunningOne() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let asked = Locked<[Double]>([])
        let started = Locked(false), cancelled = Locked(false)
        m.signalID.snapshotProvider = Self.provider(Self.snapshot(.noise, seconds: 3.1, offsetHz: 0))
        m.signalID.dwell = {}
        let inner = Self.stub(asked: asked)
        m.hover(at: CGPoint(x: 0.3, y: 0.2), viewSize: Self.view)
        let first = m.hover!.hz
        m.signalID.analysis = { iq, rate, centre, at, width, spectrum, longer in
            if at == first {
                started.withLock { $0 = true }
                let deadline = Date().addingTimeInterval(120)
                while !Task.isCancelled, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
                cancelled.withLock { $0 = Task.isCancelled }
            }
            return inner(iq, rate, centre, at, width, spectrum, longer)
        }

        #expect(await eventually { started.withLock { $0 } })
        #expect(m.signalID.hoverPending)
        m.hover(at: CGPoint(x: 0.7, y: 0.2), viewSize: Self.view)
        let second = m.hover!.hz
        #expect(!m.signalID.hoverPending)
        #expect(await eventually { m.signalID.hoverIdentity != nil })
        let id = try #require(m.signalID.hoverIdentity)
        #expect(abs(id.measurement.offsetHz - (second - m.centerHz)) < 1e-6)
        // The first was cancelled mid-run (its analysis saw it), then the second ran.
        #expect(cancelled.withLock { $0 })
        #expect(asked.withLock { $0 } == [first, second])
    }

    /// The demo source's own ring, HamItUp on: the centre handed to the analysis is in display Hz (the first read's
    /// channel around the point, I1: not the hardware's, LO Hz above), the rate the channel's, and the IQ no more than
    /// the ring holds since the toggle's retune.
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
        #expect(await eventually { r.headFrame > before + Int(0.3 * m.sampleRate) })
        let at = m.vfoHz + 1_000
        let id = await m.signalID.identify(atHz: at)
        let head = r.headFrame
        #expect(id != nil)
        let got = try #require(seen.withLock { $0 })
        #expect(m.upconverter.enabled && m.centerHz < m.upconverter.loHz)
        // The channel is centred on the point (to the app spectrum's nearest bin, under 1 kHz at 2 MS/s).
        #expect(abs(got.centre - at) < 1_000, "\(got.centre) for \(at)")
        #expect(got.at == at)
        #expect(m.sampleRate > SignalIDService.channelAboveRate && got.rate < m.sampleRate)
        let decimation = Int((m.sampleRate / got.rate).rounded())
        #expect(got.frames > 0 && got.frames * decimation <= head - before + decimation,
                "\(got.frames) × \(decimation) of \(head - before)")
    }

    // MARK: One at a time, and small (I1)

    /// Identifications asked for together run one after another, never side by side, on the service's own queue
    /// (not the cooperative pool): each analysis here sleeps, and a second running meanwhile would be counted.
    @Test func identificationsNeverOverlap() async {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let running = Locked(0), most = Locked(0), runs = Locked(0), queues = Locked<Set<String>>([])
        m.signalID.snapshotProvider = Self.provider(Self.snapshot(.noise, seconds: 3.1, offsetHz: 0))
        let inner = Self.stub(widthHz: 0, family: .noise, note: "No signal")   // a point each: none reused
        m.signalID.analysis = { iq, rate, centre, at, width, spectrum, longer in
            let now = running.withLock { $0 += 1; return $0 }
            most.withLock { $0 = max($0, now) }
            _ = queues.withLock { $0.insert(String(cString: __dispatch_queue_get_label(nil))) }
            Thread.sleep(forTimeInterval: 0.02)
            runs.withLock { $0 += 1 }
            running.withLock { $0 -= 1 }
            return inner(iq, rate, centre, at, width, spectrum, longer)
        }
        let service = m.signalID, centre = m.centerHz
        let asked = (0..<6).map { k in Task { await service.identify(atHz: centre + 1_000 * Double(k)) } }
        for task in asked { _ = await task.value }
        #expect(runs.withLock { $0 } == 6)
        #expect(most.withLock { $0 } == 1, "\(most.withLock { $0 }) ran at once")
        #expect(queues.withLock { $0 } == ["app.subfloor.signal-id"], "\(queues.withLock { $0 })")
    }

    /// The I1 bound: one identification at the RSP1B's 10 MS/s holds at most 100 MB more than the ring. The first
    /// read never takes the capture whole (the snapshot is only probed for the ring's rate): it comes off the ring a
    /// piece at a time and is cut to a channel around the point as it comes, 3.05 s at 1.25 MS/s. Its peak is that
    /// channel, sized once (30.5 MB), and one piece (1 M frames: 8 MB of floats, and the ring's own 4 MB of int16 it
    /// is decoded from), 43 MB, asserted under 64 MB; the identifier then works on the channel (30.5 MB in, asserted
    /// under 32 MB), its own buffers (the 48 kHz local view, the measurement window, the spectra) a few MB more. The
    /// old read held 244 MB of floats, 122 MB of int16 while converting, and copies of both in the identifier. The
    /// answer is the same: the carrier where it is.
    @Test func aTenMSsIdentificationStaysSmall() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let fs = 10_000_000.0, toneHz = 1_234_560.0   // whole cycles in each 1 M-frame piece: one continuous tone
        let tone = await Task.detached {   // off the main actor, as everything heavy here
            var wave = [Float](repeating: 0, count: 2_000_000)
            for k in 0..<1_000_000 {
                let phase = 2 * Double.pi * toneHz * Double(k) / fs
                wave[2 * k] = Float(0.1 * cos(phase))
                wave[2 * k + 1] = Float(0.1 * sin(phase))
            }
            return wave
        }.value
        let wholeAsked = Locked(0.0), largestPiece = Locked(0), analysed = Locked<(floats: Int, rate: Double)?>(nil)
        m.signalID.snapshotProvider = { seconds in
            wholeAsked.withLock { $0 = max($0, seconds) }
            let frames = Int((seconds * fs).rounded())
            return IQSnapshot(samples: [Float](repeating: 0, count: 2 * frames), sampleRate: fs, endTime: Date())
        }
        // Each piece the tone and fresh noise (uniform, 0.1 peak: a noise floor the extent can stand on; noise
        // repeated piece after piece would be a comb of lines 10 Hz apart).
        let chunks: SignalIDService.ChunkProvider = { seconds, chunkFrames, visit in
            let frames = Int((seconds * fs).rounded())
            var noise = [Int16](repeating: 0, count: tone.count)
            var piece = [Float](repeating: 0, count: tone.count)
            var done = 0
            while done < frames {
                let n = min(chunkFrames, frames - done, tone.count / 2)
                largestPiece.withLock { $0 = max($0, n) }
                noise.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
                vDSP_vflt16(noise, 1, &piece, 1, vDSP_Length(2 * n))
                var scale = Float(0.1 / 32768)
                vDSP_vsmul(piece, 1, &scale, &piece, 1, vDSP_Length(2 * n))
                vDSP_vadd(piece, 1, tone, 1, &piece, 1, vDSP_Length(2 * n))
                guard piece[0..<(2 * n)].withUnsafeBufferPointer(visit) else { return nil }
                done += n
            }
            return IQRead(frames: frames, sampleRate: fs, endTime: Date())
        }
        m.signalID.chunkProvider = chunks
        m.signalID.analysis = { iq, rate, centre, at, width, spectrum, longer in
            analysed.withLock { $0 = (iq.count, rate) }
            return SignalIdentifier.identify(iq: iq, sampleRate: rate, captureCenterHz: centre, atHz: at,
                                             bandwidthHz: width, spectrumDb: spectrum, longer: longer)
        }
        // The first pass only: a carrier asks for the longer read (it could be WSPR), which is R26's (its own test).
        let id = try #require(await m.signalID.identify(atHz: m.centerHz + toneHz, longerRead: false))
        let input = try #require(analysed.withLock { $0 })
        #expect(wholeAsked.withLock { $0 } <= SignalIDService.probeSeconds)
        #expect(input.rate == 1_250_000)
        #expect(input.floats * MemoryLayout<Float>.size <= 32 << 20, "\(input.floats) floats analysed")
        #expect(id.measurement.family == .carrier, "\(id.label)")
        #expect(abs(id.measurement.offsetHz - toneHz) < 5, "\(id.measurement.offsetHz)")
        // The read's peak: the channel as the read reserves it (sized once for what it asks; that it is never
        // outgrown is `longerReadIsChannelisedPieceByPiece`'s) and one piece, its floats and the ring's int16.
        let plan = try #require(SignalIDService.firstChannel(pointHz: toneHz, bandwidthHz: nil, spectrumDb: nil, rate: fs))
        let extractor = ChannelExtractor(sampleRate: fs, offsetHz: plan.offsetHz, bandwidthHz: plan.windowHz, sharp: false)
        extractor.reserve(inputFrames: Int(((SignalIDService.firstSeconds + SignalIDService.settleSeconds) * fs).rounded()))
        let channelBytes = extractor.reservedFloats * MemoryLayout<Float>.size
        let pieceBytes = largestPiece.withLock { $0 } * (8 + 4)
        #expect(extractor.rate == input.rate)
        #expect(channelBytes + pieceBytes <= 64 << 20, "peak \(channelBytes + pieceBytes) bytes")
    }

    /// A point outside the capture the ring's IQ holds, while that is another capture's than the model shows (a
    /// hardware tune that failed leaves the IQ at the old centre): "Too soon after tuning", not a signal from
    /// elsewhere aliased there. A point it holds is read there as usual.
    @Test func aPointTheIQDoesNotHoldIsTooSoon() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let calls = Locked(0)
        let snap = Self.snapshot(.rtty(), seconds: 3.1, offsetHz: 5_000)
        m.signalID.snapshotProvider = Self.provider(snap, calls: calls)
        m.signalID.chunkProvider = Self.chunks(snap)
        // A failed retune: the IQ is still the old capture's, 100 kHz below the one the model shows.
        let old = m.centerHz - 100_000
        m.signalID.retuneBegins()
        m.signalID.retuned(displayCenterHz: old)
        let outside = try #require(await m.signalID.identify(atHz: m.centerHz + 30_000))
        #expect(outside.note == SignalIdentifier.tooSoonNote && outside.best == nil, "\(outside.label)")
        #expect(calls.withLock { $0 } == 0)   // nothing read for it
        let inside = try #require(await m.signalID.identify(atHz: old + 5_000))
        #expect(inside.best?.name == "RTTY", "\(inside.label)")
        #expect(calls.withLock { $0 } == 1)
    }

    /// I1's channelised first read gives the answers the whole capture gives: 3 s at 2 MS/s holding an NFM voice,
    /// identified there and at an empty frequency, read whole and as the channel around the point; with
    /// `SUBFLOOR_SIGNALID_MATRIX=1` an RTTY too (the heavy Signal ID sweeps wait for it, ruling R32). Off the main
    /// actor: the other tests' models run on it meanwhile.
    @Test nonisolated func theChannelledFirstReadKeepsTheAnswer() throws {
        let clock = ContinuousClock(), start = clock.now
        let full = ProcessInfo.processInfo.environment["SUBFLOOR_SIGNALID_MATRIX"] == "1"
        let fs = 2_000_000.0, centre = 446_000_000.0
        var iq = SignalSynth.make(.nfmVoice(deviationHz: 5000), sampleRate: fs, seconds: 3.1, snrDb: 20,
                                  offsetHz: 250_000, seed: 7)
        if full {
            let rtty = SignalSynth.make(.rtty(), sampleRate: fs, seconds: 3.1, snrDb: .infinity, offsetHz: -300_000,
                                        seed: 8)
            for k in iq.indices { iq[k] += 0.3 * rtty[k] }
        }
        let snap = IQSnapshot(samples: iq, sampleRate: fs, endTime: Date())
        let barrier = TuneBarrier()
        barrier.end(centerHz: centre)
        let analysis: SignalIDService.Analysis = { iq, rate, centre, at, width, spectrum, longer in
            SignalIdentifier.identify(iq: iq, sampleRate: rate, captureCenterHz: centre, atHz: at, bandwidthHz: width,
                                      spectrumDb: spectrum, longer: longer)
        }
        for point in full ? [250_000.0, -300_000, 600_000] : [250_000, 600_000] {
            func run(whole: Bool) throws -> SignalIdentity {
                try #require(SignalIDService.run(atHz: centre + point, bandwidthHz: nil, spectrum: nil, longer: false,
                                                 provider: Self.provider(snap), chunks: Self.chunks(snap),
                                                 analysis: analysis, barrier: barrier, whole: whole)).identity
            }
            let whole = try run(whole: true), channel = try run(whole: false)
            let label = "at \(point): whole \(whole.label), channel \(channel.label)"
            #expect(channel.best?.name == whole.best?.name, "\(label)")
            #expect(channel.measurement.family == whole.measurement.family, "\(label)")
            #expect(channel.note == whole.note, "\(label)")
            #expect(abs(channel.measurement.offsetHz - whole.measurement.offsetHz) < 50, "\(label)")
            let width = whole.measurement.occupiedBandwidthHz
            #expect(abs(channel.measurement.occupiedBandwidthHz - width) <= 0.05 * max(width, 100), "\(label)")
            print("theChannelledFirstReadKeepsTheAnswer: \(label) (\(clock.now - start))")
        }
    }
}
