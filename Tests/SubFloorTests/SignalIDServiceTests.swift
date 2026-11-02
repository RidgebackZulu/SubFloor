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
/// One test at a time: most run the demo radio (a core each in a debug build), and two dozen of them at once beside
/// the rest of the suite starved it (I2, ruling R32).
@MainActor
@Suite(.serialized)
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

    /// The real identifier, counting its first passes (the identifications run: not a longer read's or a look-back's).
    private static func counting(_ runs: Locked<Int>) -> SignalIDService.Analysis {
        { a in
            if a.longer == nil { runs.withLock { $0 += 1 } }
            return SignalIDService.identifier(a)
        }
    }

    /// A stub analysis: a 100 Hz signal centred where it was asked, named `name` when given.
    nonisolated private static func stub(name: String? = nil, alternatives: [ModeMatch] = [], widthHz: Double = 100,
                             family: SignalFamily = .fsk, note: String? = nil, seconds: Double = 0,
                             asked: Locked<[Double]>? = nil) -> SignalIDService.Analysis {
        { a in
            let (centre, at) = (a.captureCenterHz, a.atHz)
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
        // RTTY's numbers, away from the amateur segments: not shown to be RTTY.
        #expect(id.label.hasPrefix("2-FSK · 45.45 Bd · 170 Hz shift"), "\(id.label)")
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
        #expect(id.label.hasPrefix("2-FSK · 45.45 Bd"), "\(id.label)")
    }

    /// A point on the same signal within 5 s reuses the result, and an empty point its own; a point elsewhere, or a
    /// retune, runs it again.
    @Test func cacheReusesNearbyPoints() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let runs = Locked(0)
        // 16 s and more: the empty point's look-back reads all it asks for, so its "No signal" is kept.
        let snap = Self.snapshot(.rtty(), seconds: 16.1, offsetHz: 5_000)
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
        let ft8 = ModeMatch(name: "FT8", confidence: 0.5, evidence: [])
        m.signalID.analysis = Self.stub(alternatives: [ft8], widthHz: 50)

        let id = try #require(await m.signalID.identify(atHz: rf + 5))
        #expect(id.confirmedByDecode)
        #expect(id.best?.name == "FT8")
        #expect(id.best?.confidence == 1)
        #expect(!id.alternatives.contains { $0.name == "FT8" })

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
        // 16 s and more: "No signal" looks back over all it asks for, and stays "No signal".
        let noise = Self.snapshot(.noise, seconds: 16.1, offsetHz: 0)
        m.signalID.snapshotProvider = Self.provider(noise)
        m.signalID.chunkProvider = Self.chunks(noise)
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
        #expect(fsk.confirmedByDecode && fsk.best?.name == "FT8" && fsk.best?.confidence == 1)
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
        m.signalID.analysis = { a in
            started.withLock { $0 = true }
            let deadline = Date().addingTimeInterval(120)
            while !retuned.withLock({ $0 }), Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            return inner(a)
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
        m.signalID.chunkProvider = { seconds, _, _ in
            // The longer reads (not the comb's short read of the ring, which fails too).
            if seconds > SignalIDService.firstSeconds { reads.withLock { $0 += 1 } }
            return nil
        }
        m.signalID.analysis = { a in
            let (centre, at) = (a.captureCenterHz, a.atHz)
            return SignalIdentity(measurement: SignalMeasurement(offsetHz: at - centre, occupiedBandwidthHz: 50,
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
        m.signalID.analysis = { a in
            let (iq, rate, centre, at, longer) = (a.iq, a.sampleRate, a.captureCenterHz, a.atHz, a.longer)
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
        m.signalID.analysis = { a in
            let (iq, rate, centre, longer) = (a.iq, a.sampleRate, a.captureCenterHz, a.longer)
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
        m.signalID.analysis = { a in
            let main = Thread.isMainThread
            offMain.withLock { $0.analysis = $0.analysis && !main }
            let before = ticks.withLock { $0 }
            let deadline = Date().addingTimeInterval(120)
            while ticks.withLock({ $0 }) <= before, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            ticked.withLock { $0 = ticks.withLock { $0 } > before }
            return analysis(a)
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
        m.signalID.analysis = { a in
            let at = a.atHz
            if at == first {
                started.withLock { $0 = true }
                let deadline = Date().addingTimeInterval(120)
                while !Task.isCancelled, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
                cancelled.withLock { $0 = Task.isCancelled }
            }
            return inner(a)
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
        m.signalID.analysis = { a in
            let (iq, rate, centre, at) = (a.iq, a.sampleRate, a.captureCenterHz, a.atHz)
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
        m.signalID.analysis = { a in
            let now = running.withLock { $0 += 1; return $0 }
            most.withLock { $0 = max($0, now) }
            _ = queues.withLock { $0.insert(String(cString: __dispatch_queue_get_label(nil))) }
            Thread.sleep(forTimeInterval: 0.02)
            runs.withLock { $0 += 1 }
            running.withLock { $0 -= 1 }
            return inner(a)
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
        m.signalID.analysis = { a in
            analysed.withLock { $0 = (a.iq.count, a.sampleRate) }
            return SignalIDService.identifier(a)
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
        #expect(inside.label.hasPrefix("2-FSK · 45.45 Bd"), "\(inside.label)")
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
        let analysis: SignalIDService.Analysis = { a in
            SignalIDService.identifier(a)
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

    // MARK: Whose request goes first (Task 7)

    /// Waits (bounded, 120 s) until `flag` is set; `cancellable`: a cancellation ends it too.
    nonisolated private static func hold(_ flag: Locked<Bool>, cancellable: Bool = false) {
        let deadline = Date().addingTimeInterval(120)
        while !flag.withLock({ $0 }), !(cancellable && Task.isCancelled), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    /// A background job running and one queued, then the owner's: the owner's runs next (the running one is stopped
    /// for it and asked again, ahead of the queued one). The running one ignores the cancellation, so all of them are
    /// queued while it holds.
    @Test func ownerGoesAheadOfQueuedWork() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let started = Locked<[Double]>([]), release = Locked(false)
        let service = m.signalID, centre = m.centerHz
        let running = centre + 1_000, queued = centre + 2_000, owner = centre + 3_000
        m.signalID.snapshotProvider = Self.provider(Self.snapshot(.noise, seconds: 3.1, offsetHz: 0))
        let inner = Self.stub()
        m.signalID.analysis = { a in
            started.withLock { $0.append(a.atHz) }
            if a.atHz == running { Self.hold(release) }
            return inner(a)
        }
        let first = Task { await service.identify(atHz: running) }
        #expect(await eventually { started.withLock { $0 } == [running] })
        let second = Task { await service.identify(atHz: queued) }
        #expect(await eventually { service.queue.waiting == 1 })
        let third = Task { await service.identify(atHz: owner, priority: .owner) }
        #expect(await eventually { service.queue.waiting == 2 })
        release.withLock { $0 = true }
        let answers = [await third.value, await second.value, await first.value]
        #expect(answers.allSatisfy { $0 != nil })
        #expect(started.withLock { $0 } == [running, owner, running, queued], "\(started.withLock { $0 })")
    }

    /// Two hovers queued: the newer replaces the older at once (nil), and only it runs.
    @Test func newerHoverReplacesOlder() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let started = Locked<[Double]>([]), release = Locked(false)
        let service = m.signalID, centre = m.centerHz
        let running = centre + 1_000, older = centre + 2_000, newer = centre + 3_000
        m.signalID.snapshotProvider = Self.provider(Self.snapshot(.noise, seconds: 3.1, offsetHz: 0))
        let inner = Self.stub()
        m.signalID.analysis = { a in
            started.withLock { $0.append(a.atHz) }
            if a.atHz == running { Self.hold(release) }
            return inner(a)
        }
        let busy = Task { await service.identify(atHz: running) }
        #expect(await eventually { started.withLock { $0 } == [running] })
        let first = Task { await service.identify(atHz: older, priority: .owner, hover: true) }
        #expect(await eventually { service.queue.waiting == 1 })
        let second = Task { await service.identify(atHz: newer, priority: .owner, hover: true) }
        #expect(await first.value == nil)   // replaced while the queue still holds
        release.withLock { $0 = true }
        let answers = [await second.value, await busy.value]
        #expect(answers.allSatisfy { $0 != nil })
        #expect(started.withLock { $0 } == [running, newer, running], "\(started.withLock { $0 })")
    }

    /// A running background job stops at its next cancellation check when the owner asks; the owner's answer comes,
    /// and the background one, its caller still waiting, is asked again and answers.
    @Test func ownerStopsBackgroundAtNextCheck() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let started = Locked<[Double]>([]), stopped = Locked(false), never = Locked(false)
        let service = m.signalID, centre = m.centerHz
        let background = centre + 1_000, owner = centre + 3_000
        m.signalID.snapshotProvider = Self.provider(Self.snapshot(.noise, seconds: 3.1, offsetHz: 0))
        let inner = Self.stub()
        m.signalID.analysis = { a in
            let n = started.withLock { $0.append(a.atHz); return $0.count }
            if n == 1 {
                Self.hold(never, cancellable: true)
                stopped.withLock { $0 = Task.isCancelled }
            }
            return inner(a)
        }
        let job = Task { await service.identify(atHz: background) }
        #expect(await eventually { started.withLock { $0 } == [background] })
        let answer = await service.identify(atHz: owner, priority: .owner)
        #expect(answer.map { abs($0.measurement.offsetHz - 3_000) < 1e-6 } == true)
        #expect(stopped.withLock { $0 }, "the background job never saw the cancellation")
        #expect(await job.value != nil)
        #expect(started.withLock { $0 } == [background, owner, background], "\(started.withLock { $0 })")
    }

    /// A queued identification whose caller is cancelled leaves the queue at once (nil while the running one still
    /// holds) and never runs.
    @Test func aCancelledQueuedOneLeavesAtOnce() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let started = Locked<[Double]>([]), release = Locked(false), returned = Locked(false)
        let service = m.signalID, centre = m.centerHz
        let running = centre + 1_000, queued = centre + 2_000
        m.signalID.snapshotProvider = Self.provider(Self.snapshot(.noise, seconds: 3.1, offsetHz: 0))
        let inner = Self.stub()
        m.signalID.analysis = { a in
            started.withLock { $0.append(a.atHz) }
            if a.atHz == running { Self.hold(release) }
            return inner(a)
        }
        let busy = Task { await service.identify(atHz: running) }
        #expect(await eventually { started.withLock { $0 } == [running] })
        let waiting = Task { () -> SignalIdentity? in
            let id = await service.identify(atHz: queued)   // background: the running one isn't stopped for it
            returned.withLock { $0 = true }
            return id
        }
        #expect(await eventually { service.queue.waiting == 1 })
        waiting.cancel()
        #expect(await eventually(10) { returned.withLock { $0 } }, "a cancelled queued caller waited for its turn")
        #expect(service.queue.waiting == 0)
        release.withLock { $0 = true }
        let answers = [await waiting.value, await busy.value]
        #expect(answers[0] == nil && answers[1] != nil)
        #expect(started.withLock { $0 } == [running], "\(started.withLock { $0 })")
    }

    /// The owner's, the background's and hovers asked together: never two at once, every caller but a replaced hover
    /// answered, all on the service's queue.
    @Test func oneAtATime() async {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let running = Locked(0), most = Locked(0), queues = Locked<Set<String>>([])
        m.signalID.snapshotProvider = Self.provider(Self.snapshot(.noise, seconds: 3.1, offsetHz: 0))
        let inner = Self.stub()
        m.signalID.analysis = { a in
            let now = running.withLock { $0 += 1; return $0 }
            most.withLock { $0 = max($0, now) }
            _ = queues.withLock { $0.insert(String(cString: __dispatch_queue_get_label(nil))) }
            Thread.sleep(forTimeInterval: 0.02)
            running.withLock { $0 -= 1 }
            return inner(a)
        }
        let service = m.signalID, centre = m.centerHz
        let asked = (0..<8).map { k in
            Task { () -> SignalIdentity? in
                let at = centre + 1_000 * Double(k)
                switch k % 3 {
                case 0: return await service.identify(atHz: at)
                case 1: return await service.identify(atHz: at, priority: .owner)
                default: return await service.identify(atHz: at, priority: .owner, hover: true)
                }
            }
        }
        var answered = 0
        for task in asked where await task.value != nil { answered += 1 }
        #expect(answered >= 6, "\(answered) of 8 answered")   // the hovers but the last may be replaced
        #expect(most.withLock { $0 } == 1, "\(most.withLock { $0 }) ran at once")
        #expect(queues.withLock { $0 } == ["app.subfloor.signal-id"], "\(queues.withLock { $0 })")
    }

    // MARK: A silent moment isn't an empty frequency (Task 7)

    /// `seconds` of noise at 48 kS/s (unit power) with an RTTY 20 dB over it in 250 Hz, `offsetHz` from the centre, on
    /// only from `on.lowerBound` to `on.upperBound` seconds; heard up to `endTime`.
    nonisolated private static func burst(seconds: Double, on: ClosedRange<Double>, offsetHz: Double,
                                          endTime: Date = Date()) -> IQSnapshot {
        let rate = 48_000.0
        var iq = SignalSynth.make(.noise, sampleRate: rate, seconds: seconds, snrDb: 0, seed: 21)
        let rtty = SignalSynth.make(.rtty(), sampleRate: rate, seconds: seconds, snrDb: .infinity, offsetHz: offsetHz, seed: 22)
        let gain = Float((pow(10, 20.0 / 10) * 250 / rate).squareRoot())
        for k in 0..<(iq.count / 2) where on ~= Double(k) / rate {
            iq[2 * k] += gain * rtty[2 * k]
            iq[2 * k + 1] += gain * rtty[2 * k + 1]
        }
        return IQSnapshot(samples: iq, sampleRate: rate, endTime: endTime)
    }

    /// The longer read from `snap`, as `chunks`, but heard up to `endTime`.
    nonisolated private static func chunks(_ snap: IQSnapshot, endTime: Date) -> SignalIDService.ChunkProvider {
        let inner = chunks(snap)
        return { seconds, frames, visit in
            inner(seconds, frames, visit).map { IQRead(frames: $0.frames, sampleRate: $0.sampleRate, endTime: endTime) }
        }
    }

    /// A stub that says "No signal" everywhere, recording each analysis: its IQ's length and end time.
    nonisolated private static func silence(_ seen: Locked<[(seconds: Double, endTime: Date?, longer: Bool)]>)
        -> SignalIDService.Analysis {
        { a in
            seen.withLock { $0.append((Double(a.iq.count / 2) / a.sampleRate, a.endTime, a.longer != nil)) }
            return SignalIdentity(measurement: SignalMeasurement(offsetHz: a.atHz - a.captureCenterHz, family: .noise,
                                                                 seconds: 3),
                                  note: SignalIdentifier.noSignalNote)
        }
    }

    /// An RTTY heard 7 to 13 s ago, silent since: not "No signal" but the RTTY, saying how long it has been silent; the
    /// first answer ("No signal") is out first, as measuring.
    @Test func silentNewest3sLooksBack() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let snap = Self.burst(seconds: 16.1, on: 3.1...9.1, offsetHz: 5_000)
        m.signalID.snapshotProvider = Self.provider(snap)
        m.signalID.chunkProvider = Self.chunks(snap)
        let firsts = Locked<[String]>([])
        let id = try #require(await m.signalID.identify(atHz: m.centerHz + 5_000) { first in
            firsts.withLock { $0.append(first.label) }
        })
        #expect(id.measurement.family == .fsk && abs(id.measurement.offsetHz - 5_000) < 50, "\(id.label)")
        #expect(id.note?.contains("Silent for the last") == true, "\(id.note ?? "no note")")
        #expect(firsts.withLock { $0 } == [SignalIdentifier.noSignalNote], "\(firsts.withLock { $0 })")
    }

    /// Nothing in 16 s: "No signal", having looked back `firstSeconds` at a time, each window ending where it ends; kept
    /// for the point.
    @Test func noSignalAfterLookingBack() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let end = Date().addingTimeInterval(-30)
        let snap = IQSnapshot(samples: [Float](repeating: 0, count: 2 * Int(16.1 * 48_000)), sampleRate: 48_000,
                              endTime: end)
        let calls = Locked(0)
        m.signalID.snapshotProvider = Self.provider(snap, calls: calls)
        m.signalID.chunkProvider = Self.chunks(snap, endTime: end.addingTimeInterval(0.2))
        m.signalID.sourceKind = { .sdrplay }
        let seen = Locked<[(seconds: Double, endTime: Date?, longer: Bool)]>([])
        m.signalID.analysis = Self.silence(seen)
        let at = m.centerHz + 5_000
        let id = try #require(await m.signalID.identify(atHz: at))
        #expect(id.label == SignalIdentifier.noSignalNote && id.note == SignalIdentifier.noSignalNote, "\(id.label)")
        let windows = seen.withLock { $0 }.dropFirst()
        #expect(windows.map { Int($0.seconds.rounded()) } == [13, 10, 7, 4, 1], "\(windows.map(\.seconds))")
        let ends = windows.compactMap { $0.endTime?.timeIntervalSince(end) }
        #expect(ends.count == 5 && zip(ends, [-2.8, -5.8, -8.8, -11.8, -14.8]).allSatisfy { abs($0 - $1) < 1e-6 }, "\(ends)")
        #expect(windows.allSatisfy { $0.longer })
        _ = await m.signalID.identify(atHz: at)
        #expect(calls.withLock { $0 } == 1)   // kept
    }

    /// The radio stopped: the ring's IQ is read, and the analysis gets when it was heard, not now; the longer read
    /// gets its own read's end time.
    @Test func stoppedRadioUsesTheRing() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        m.stop()
        let heard = Date().addingTimeInterval(-600), longEnd = heard.addingTimeInterval(0.7)
        let snap = Self.burst(seconds: 3.1, on: 0...3.1, offsetHz: 5_000, endTime: heard)
        m.signalID.snapshotProvider = Self.provider(snap)
        m.signalID.chunkProvider = Self.chunks(snap, endTime: longEnd)
        m.signalID.sourceKind = { .sdrplay }
        let ends = Locked<[Date?]>([])
        let inner = Self.stub()
        m.signalID.analysis = { a in
            ends.withLock { $0.append(a.endTime) }
            var id = inner(a)
            id.needsLongerRead = a.longer == nil
            return id
        }
        #expect(await m.signalID.identify(atHz: m.centerHz + 5_000) != nil)
        #expect(ends.withLock { $0 } == [heard, longEnd], "\(ends.withLock { $0 })")
    }

    /// A 5 s ring: the look-back reads what it holds (less the 50 ms after the barrier), says so, and isn't kept.
    @Test func shortRingSaysSo() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let snap = IQSnapshot(samples: [Float](repeating: 0, count: 2 * 5 * 48_000), sampleRate: 48_000, endTime: Date())
        let calls = Locked(0)
        m.signalID.snapshotProvider = Self.provider(snap, calls: calls)
        m.signalID.chunkProvider = Self.chunks(snap)
        let seen = Locked<[(seconds: Double, endTime: Date?, longer: Bool)]>([])
        m.signalID.analysis = Self.silence(seen)
        let id = try #require(await m.signalID.identify(atHz: m.centerHz + 5_000))
        let said = String(format: "Looked back %.1f s of the 16 s asked for", 4.95)
        #expect(id.note == "\(SignalIdentifier.noSignalNote); \(said)", "\(id.note ?? "no note")")
        #expect(seen.withLock { $0.map { ($0.seconds * 100).rounded() / 100 } } == [3, 1.95], "\(seen.withLock { $0 })")
        _ = await m.signalID.identify(atHz: m.centerHz + 5_000)
        #expect(calls.withLock { $0 } == 2)   // not kept: the ring is filling
    }

    /// A retune during the look-back drops the answer (nil), and nothing is kept for the old centre.
    @Test func retuneDuringLookBackDropsIt() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let snap = IQSnapshot(samples: [Float](repeating: 0, count: 2 * Int(16.1 * 48_000)), sampleRate: 48_000,
                              endTime: Date())
        m.signalID.snapshotProvider = Self.provider(snap)
        m.signalID.chunkProvider = Self.chunks(snap)
        let started = Locked(false), retuned = Locked(false)
        let seen = Locked<[(seconds: Double, endTime: Date?, longer: Bool)]>([])
        let inner = Self.silence(seen)
        m.signalID.analysis = { a in
            if a.longer != nil {   // a look-back window
                started.withLock { $0 = true }
                Self.hold(retuned)
            }
            return inner(a)
        }
        let at = m.centerHz + 5_000
        let running = Task { await m.signalID.identify(atHz: at) }
        #expect(await eventually { started.withLock { $0 } })
        m.setVFO(m.centerHz + 0.6 * m.sampleRate)
        retuned.withLock { $0 = true }
        #expect(await running.value == nil)
        #expect(seen.withLock { $0.count } == 2)   // the first pass and the window it was in: no more
    }

    /// Only the RSP's samples carry a true time: an IQ file and the demo source give the analysis none (no slots).
    @Test func filePlaybackGetsNoSlots() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let snap = Self.snapshot(.noise, seconds: 3.1, offsetHz: 0)
        m.signalID.snapshotProvider = Self.provider(snap)
        let ends = Locked<[Date?]>([])
        let inner = Self.stub()
        m.signalID.analysis = { a in
            ends.withLock { $0.append(a.endTime) }
            return inner(a)
        }
        #expect(m.sourceKind == .synthetic)
        _ = await m.signalID.identify(atHz: m.centerHz + 5_000)   // the model's own: the demo source
        for kind in [SourceKind.file, .sdrplay] {
            m.signalID.invalidateCache()
            m.signalID.sourceKind = { kind }
            _ = await m.signalID.identify(atHz: m.centerHz + 5_000)
        }
        #expect(ends.withLock { $0 } == [nil, nil, snap.endTime], "\(ends.withLock { $0 })")
    }

    /// Hover and card ask within 4 view points' worth of Hz at the zoom: 1380 Hz at 345 Hz a point, 40 Hz at 10.
    /// Agents' get the identifier's default (nil).
    @Test func radiusFollowsZoom() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        m.signalID.snapshotProvider = Self.provider(Self.snapshot(.noise, seconds: 3.1, offsetHz: 0))
        m.signalID.dwell = {}
        let radii = Locked<[Double?]>([])
        let inner = Self.stub()
        m.signalID.analysis = { a in
            radii.withLock { $0.append(a.pointRadiusHz) }
            return inner(a)
        }
        for (k, hzPerPoint) in [345.0, 10].enumerated() {
            let view = CGSize(width: m.viewport.spanHz / hzPerPoint, height: 500)
            m.hover(at: CGPoint(x: 0.3 + 0.2 * Double(k), y: 0.2), viewSize: view)
            #expect(await eventually { radii.withLock { $0.count } == 2 * k + 1 })
            m.openIDCard(atUnit: CGPoint(x: 0.35 + 0.2 * Double(k), y: 0.2), viewSize: view)
            #expect(await eventually { radii.withLock { $0.count } == 2 * k + 2 })
        }
        _ = await m.signalID.identify(atHz: m.centerHz - 9_000)
        // The same point at another radius isn't the answer kept for it: the signals under it differ.
        _ = await m.signalID.identify(atHz: m.centerHz - 9_000, radiusHz: 1_380)
        let asked = radii.withLock { $0 }
        #expect(asked.count == 6 && zip(asked.prefix(4), [1380.0, 1380, 40, 40]).allSatisfy { abs(($0 ?? 0) - $1) < 1e-6 }
                && asked[4] == nil && asked[5] == 1_380, "\(asked)")
    }

    /// A tune that failed leaves the IQ at the old centre: a point it doesn't hold is "Too soon" for the first second,
    /// then says the radio isn't there, and that isn't kept.
    @Test func failedTuneNoteAfterGrace() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let probes = Locked(0), clock = Locked(Date())
        let snap = Self.snapshot(.rtty(), seconds: 3.1, offsetHz: 5_000)
        let inner = Self.provider(snap)
        m.signalID.snapshotProvider = { seconds in
            if seconds <= SignalIDService.probeSeconds { probes.withLock { $0 += 1 } }
            return inner(seconds)
        }
        m.signalID.now = { clock.withLock { $0 } }
        let old = m.centerHz - 100_000
        m.signalID.retuneBegins()
        m.signalID.retuned(displayCenterHz: old)    // the IQ at the old centre
        m.signalID.retuneBegins()
        m.signalID.retuned(displayCenterHz: nil)    // the tune that failed
        let outside = m.centerHz + 30_000
        let soon = try #require(await m.signalID.identify(atHz: outside))
        #expect(soon.note == SignalIdentifier.tooSoonNote, "\(soon.label)")
        clock.withLock { $0 += 1.5 }
        let failed = try #require(await m.signalID.identify(atHz: outside))
        #expect(failed.note == SignalIDService.notAtFrequencyNote && failed.label == SignalIDService.notAtFrequencyNote,
                "\(failed.label)")
        let before = probes.withLock { $0 }
        let again = try #require(await m.signalID.identify(atHz: outside))
        #expect(again.note == SignalIDService.notAtFrequencyNote)
        #expect(probes.withLock { $0 } == before + 1)   // read again: not kept
        // A tune that works forgets it (here the IQ stays the old centre's: "Too soon" again), and a point the IQ holds
        // is identified there throughout.
        m.signalID.retuneBegins()
        m.signalID.retuned(displayCenterHz: old)
        clock.withLock { $0 += 1.5 }
        let worked = try #require(await m.signalID.identify(atHz: outside))
        #expect(worked.note == SignalIdentifier.tooSoonNote, "\(worked.label)")
        let held = try #require(await m.signalID.identify(atHz: old + 5_000))
        #expect(held.label.hasPrefix("2-FSK · 45.45 Bd"), "\(held.label)")
    }

    // MARK: The comb, the frame and the group's first answer (Task 7)

    /// The comb is found once for the capture, not for each point: kept 5 s for the tuning, found again after that and
    /// after a retune, and handed to every analysis. With no app spectrum of the capture it is found on the ring's newest
    /// IQ, at the app's resolution.
    @Test func combIsFoundOncePerSpectrum() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        m.signalID.snapshotProvider = Self.provider(Self.snapshot(.noise, seconds: 3.1, offsetHz: 0))
        m.signalID.chunkProvider = Self.chunks(Self.snapshot(.noise, seconds: 3.1, offsetHz: 0))
        let clock = Locked(Date())
        m.signalID.now = { clock.withLock { $0 } }
        let found = Locked<[Int]>([])
        let comb = CaptureComb(info: CombInfo(spacingHz: 6000, lineCount: 9), linesHz: [m.centerHz + 6000])
        m.signalID.combFinder = { db, _, _ in
            found.withLock { $0.append(db.count) }
            return comb
        }
        let given = Locked<[CaptureComb?]>([])
        let inner = Self.stub()
        m.signalID.analysis = { a in
            given.withLock { $0.append(a.comb) }
            return inner(a)
        }
        for k in 0..<3 { _ = await m.signalID.identify(atHz: m.centerHz + 1_000 * Double(k)) }
        #expect(found.withLock { $0 } == [CaptureComb.spectrumSize])
        clock.withLock { $0 += SignalIDService.combSeconds + 1 }
        _ = await m.signalID.identify(atHz: m.centerHz + 4_000)
        #expect(found.withLock { $0.count } == 2)
        m.signalID.retuneBegins()
        m.signalID.retuned(displayCenterHz: m.centerHz)
        _ = await m.signalID.identify(atHz: m.centerHz + 5_000)
        #expect(found.withLock { $0.count } == 3)
        #expect(given.withLock { $0 }.count == 5 && given.withLock { $0 }.allSatisfy { $0 == comb })
    }

    /// The frame (carried item 5): an answer measured on a channel comes back with its measurement, its signals and its
    /// group's span all moved into the capture's frame, and `captureCenterHz` the capture's centre.
    @Test func aGroupAnswerComesBackInTheCaptureFrame() {
        let member = { (offset: Double) in
            SignalIdentity(measurement: SignalMeasurement(offsetHz: offset, occupiedBandwidthHz: 50, family: .mfsk))
        }
        let onChannel = SignalIdentity(measurement: SignalMeasurement(offsetHz: 10, occupiedBandwidthHz: 50, family: .mfsk),
                                       signals: [member(-200), member(10), member(300)], groupSpanHz: -225...325,
                                       captureCenterHz: 14_074_000)
        let out = SignalIDService.recentred(onChannel, by: 74_000, captureCenterHz: 14_000_000)
        #expect(out.measurement.offsetHz == 74_010)
        #expect(out.signals.map(\.measurement.offsetHz) == [73_800, 74_010, 74_300])
        #expect(out.groupSpanHz == 73_775...74_325)
        #expect(out.captureCenterHz == 14_000_000)
        #expect(out.label == onChannel.label, "\(out.label) vs \(onChannel.label)")
        // One signal stays as it was, but for its offset.
        let one = SignalIDService.recentred(member(10), by: 74_000, captureCenterHz: 14_000_000)
        #expect(one.measurement.offsetHz == 74_010 && one.captureCenterHz == nil && one.signals.isEmpty)
    }

    /// The quick hover on a group whose members it couldn't name on 3 s (`unknown ×3`): it asks for the longer read
    /// though the point's own wants none, shows that first answer as measuring, and the longer read's replaces it.
    @Test func aGroupsFirstAnswerIsMeasuring() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        m.signalID.snapshotProvider = Self.provider(Self.snapshot(.noise, seconds: 3.1, offsetHz: 0))
        m.signalID.chunkProvider = Self.chunks(Self.snapshot(.noise, seconds: 3.1, offsetHz: 0))
        m.signalID.dwell = {}
        let hold = Locked(false)
        m.signalID.analysis = { a in
            let refined = a.longer != nil
            if refined { Self.hold(hold) }
            let centre = a.atHz - a.captureCenterHz
            func member(_ dx: Double) -> SignalIdentity {
                var m = SignalMeasurement(offsetHz: centre + dx, occupiedBandwidthHz: 50, family: refined ? .mfsk : .unknown,
                                          seconds: 3)
                m.toneCount = refined ? 8 : nil
                return SignalIdentity(measurement: m,
                                      best: refined ? ModeMatch(name: "FT8", confidence: 0.9, evidence: []) : nil,
                                      needsLongerRead: !refined)
            }
            let members = [member(-100), member(0), member(100)]
            var id = members[1]
            id.best = ModeMatch(name: "FT8", confidence: 0.9, evidence: [])
            id.needsLongerRead = false
            id.signals = members
            id.groupSpanHz = refined ? (centre - 125)...(centre + 125) : nil
            id.captureCenterHz = a.captureCenterHz
            return id
        }
        m.hover(at: CGPoint(x: 0.4, y: 0.2), viewSize: Self.view)
        #expect(await eventually { m.signalID.hoverMeasuring })
        let first = try #require(m.signalID.hoverIdentity)
        #expect(first.label == "Several signals: unknown ×3", "\(first.label)")
        #expect(SignalIDText.hoverLine(identity: first, pending: false, measuring: true)?.hasSuffix("measuring…") == true)
        hold.withLock { $0 = true }
        #expect(await eventually { !m.signalID.hoverMeasuring && m.signalID.hoverIdentity != first })
        let final = try #require(m.signalID.hoverIdentity)
        #expect(final.label.hasPrefix("FT8 · 3 signals"), "\(final.label)")
    }

    /// A group answer's members as measured on a read centred `centre` (its `captureCenterHz`), `dx` apart about the
    /// point; `width` > 0, so no look-back.
    nonisolated private static func group(_ a: SignalIDService.AnalysisInput, needsLongerRead: Bool = false) -> SignalIdentity {
        let at = a.atHz - a.captureCenterHz
        let members = [-100.0, 0, 100].map {
            SignalIdentity(measurement: SignalMeasurement(offsetHz: at + $0, occupiedBandwidthHz: 50, family: .mfsk, seconds: 3),
                           best: ModeMatch(name: "FT8", confidence: 0.9, evidence: []))
        }
        var id = members[1]
        id.signals = members
        id.groupSpanHz = (at - 125)...(at + 125)
        id.captureCenterHz = a.captureCenterHz
        id.needsLongerRead = needsLongerRead
        return id
    }

    /// Whether `id` is `group`'s answer for `hz` in the capture's frame at `centre`.
    private static func inCaptureFrame(_ id: SignalIdentity?, hz: Double, centre: Double) -> Bool {
        guard let id else { return false }
        let at = hz - centre
        return abs(id.measurement.offsetHz - at) < 1e-6 && id.captureCenterHz == centre
            && zip(id.signals.map(\.measurement.offsetHz), [at - 100, at, at + 100]).allSatisfy { abs($0 - $1) < 1e-6 }
            && id.groupSpanHz.map { abs($0.lowerBound - (at - 125)) < 1e-6 && abs($0.upperBound - (at + 125)) < 1e-6 } == true
    }

    /// The capture's own rate (2 MS/s, the demo source's): the first read is a channel around the point, the comb is
    /// found on the app's spectrum (none of the ring read for it), and a group answer measured on the channel comes back
    /// in the capture's frame.
    @Test func theFirstReadsChannelKeepsTheFrame() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        #expect(await eventually { m.spectrumSnapshot() != nil })
        let fs = m.sampleRate
        try #require(fs > SignalIDService.channelAboveRate)
        m.signalID.snapshotProvider = { seconds in
            IQSnapshot(samples: [Float](repeating: 0, count: 2 * Int(seconds * fs)), sampleRate: fs, endTime: Date())
        }
        let piece = [Float](repeating: 0, count: 2 << 19), asked = Locked<[Double]>([])
        m.signalID.chunkProvider = { seconds, chunkFrames, visit in
            asked.withLock { $0.append(seconds) }
            let frames = Int((seconds * fs).rounded())
            var done = 0
            while done < frames {
                let n = min(chunkFrames, frames - done, piece.count / 2)
                guard piece[0..<(2 * n)].withUnsafeBufferPointer(visit) else { return nil }
                done += n
            }
            return IQRead(frames: frames, sampleRate: fs, endTime: Date())
        }
        let found = Locked<[Int]>([]), centres = Locked<[Double]>([])
        m.signalID.combFinder = { db, _, _ in
            found.withLock { $0.append(db.count) }
            return nil
        }
        m.signalID.analysis = { a in
            centres.withLock { $0.append(a.captureCenterHz) }
            return Self.group(a)
        }
        let hz = m.centerHz + 250_000
        let id = await m.signalID.identify(atHz: hz, longerRead: false)
        #expect(Self.inCaptureFrame(id, hz: hz, centre: m.centerHz), "\(String(describing: id))")
        #expect(centres.withLock { $0 }.allSatisfy { abs($0 - hz) < 1_000 }, "a channel's centre: \(centres.withLock { $0 })")
        #expect(found.withLock { $0 } == [m.spectrumSnapshot()?.average.count ?? -1], "\(found.withLock { $0 })")
        #expect(asked.withLock { $0 }.allSatisfy { $0 >= SignalIDService.firstSeconds }, "\(asked.withLock { $0 })")
    }

    /// At 500 kS/s the first read is the whole capture, and the longer read and the look-back are channels around the
    /// signal and the point: a group answer measured on either comes back in the capture's frame.
    @Test func theLongerReadsChannelKeepsTheFrame() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let fs = 500_000.0
        let snap = IQSnapshot(samples: [Float](repeating: 0, count: 2 * Int(16.1 * fs)), sampleRate: fs, endTime: Date())
        m.signalID.snapshotProvider = Self.provider(snap)
        m.signalID.chunkProvider = Self.chunks(snap)
        let refined = m.centerHz + 100_000, silent = m.centerHz - 120_000
        let centres = Locked<[Double]>([])
        m.signalID.analysis = { a in
            centres.withLock { $0.append(a.captureCenterHz) }
            if a.atHz == silent && a.longer == nil {   // nothing now; the group, looking back
                return SignalIdentity(measurement: SignalMeasurement(offsetHz: a.atHz - a.captureCenterHz, family: .noise),
                                      note: SignalIdentifier.noSignalNote)
            }
            return Self.group(a, needsLongerRead: a.longer == nil)
        }
        let long = await m.signalID.identify(atHz: refined)
        #expect(Self.inCaptureFrame(long, hz: refined, centre: m.centerHz), "\(String(describing: long))")
        let back = await m.signalID.identify(atHz: silent)
        #expect(Self.inCaptureFrame(back, hz: silent, centre: m.centerHz), "\(String(describing: back))")
        // The first reads on the capture's centre, the others on channels around the signal and the point.
        let seen = centres.withLock { $0 }
        #expect(seen.count == 4 && seen[0] == m.centerHz && seen[2] == m.centerHz
                && abs(seen[1] - refined) < 1 && abs(seen[3] - silent) < 1, "\(seen)")
    }
}
