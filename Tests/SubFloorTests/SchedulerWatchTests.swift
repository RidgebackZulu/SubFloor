import DSPCore
import Foundation
import Recording
import Scheduling
import SDRplayKit
import SignalID
import SubFloorCore
import Testing
@testable import SubFloor

/// Pirate watches on the fake RSP: a watch over 6900–7000 kHz, with by default an AM tone at 6925 kHz and a bare carrier
/// at 6955 kHz over noise. Signal ID is stubbed by frequency (the real one is never called here), so a tone AM stands in
/// for voice. The scheduler's clock is a `TestClock` and `tick()` is called by hand, as in `SchedulerTests`; the watch's
/// own timing (the hold, rejections, the give-up, the refloor) runs on monotonic time, and Auto's on the recorder's, so
/// the tests wait for them in real time. Without an audio device the engine can't start and the run tests are skipped.
@MainActor
@Suite(.serialized)
struct SchedulerWatchTests {
    @MainActor final class TestClock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    /// Signal ID's stand-in: the answer for the nearest stubbed frequency within 3 kHz, and every frequency asked about.
    @MainActor final class SignalIDStub {
        var answers: [Double: SignalIdentity] = [:]
        private(set) var asked: [Double] = []

        func identify(_ hz: Double) -> SignalIdentity? {
            asked.append(hz)
            return answers.filter { abs($0.key - hz) <= 3_000 }.min { abs($0.key - hz) < abs($1.key - hz) }?.value
        }

        func asked(near hz: Double) -> Int { asked.filter { abs($0 - hz) <= 3_000 }.count }
    }

    private static let timing = Scheduler.Timing(pickSeconds: 3, spotSeconds: 0.5, quietCloseSeconds: 5,
                                                 watchRefloorSeconds: 600, rejectSeconds: 600, rspTimeout: .seconds(5))
    private static let dallas = TimeZone(identifier: "America/Chicago")!
    private static let am6925 = SyntheticSource.Signal(frequency: 6_925_000, amplitude: 0.05, kind: .am(toneHz: 1_000))
    private static let carrier6955 = SyntheticSource.Signal(frequency: 6_955_000, amplitude: 0.05, kind: .carrier)

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorWatch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func minute(_ d: Date) -> Date {
        Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    private func makeModel(signals: [SyntheticSource.Signal] = [am6925, carrier6955])
        -> (AppModel, TestClock, SignalIDStub) {
        let dir = tempDir()
        let clock = TestClock(Self.minute(Date()))
        let m = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                         defaults: UserDefaults(suiteName: UUID().uuidString)!,
                         openRSP: { throw SDRplayError.noDevice }, rspOpenTimeout: .seconds(2),
                         decodeHistoryFolder: dir.appendingPathComponent("decodes"),
                         fakeRSP: SyntheticSource(signals: signals),
                         makeScheduler: { store in
                             Scheduler(store: store, timing: Self.timing, now: { clock.now }, localZone: Self.dallas,
                                       autoTick: false)
                         })
        m.recording.folderPath = dir.appendingPathComponent("rec").path
        // The owner's Auto timing, which a watch's stations are recorded with as it is.
        m.recording.autoTiming = AutoRecordTiming(startAfter: 0.5, stopAfter: 3, keepGapsUpTo: 1)
        let stub = SignalIDStub()
        m.scheduler.identify = { hz in stub.identify(hz) }
        return (m, clock, stub)
    }

    private static func identity(_ family: SignalFamily, envelope: EnvelopeKind = .steady,
                                 audioEnvelope: EnvelopeKind? = nil) -> SignalIdentity {
        SignalIdentity(measurement: SignalMeasurement(occupiedBandwidthHz: 6_000, snrDb: 30, envelope: envelope,
                                                      family: family, familyConfidence: 0.9, seconds: 0.5,
                                                      audioEnvelope: audioEnvelope))
    }

    /// A watch over 6900–7000 kHz whose window opens at the clock's time (a watch's window is exact).
    private func watch(name: String = "Pirates test", minutes: Int = 30, marginDb: Float = 8,
                       clock: TestClock) -> Schedule {
        let (start, date) = Self.utc(clock.now)
        return Schedule(kind: .watch, name: name, frequenciesHz: [], lowHz: 6_900_000, highHz: 7_000_000, mode: .auto,
                        start: start, durationMinutes: minutes, timeZone: "UTC", days: .once(date),
                        squelchMarginDb: marginDb, created: clock.now)
    }

    /// A broadcast whose window opens at the clock's time (its scheduled start a minute later).
    private func broadcast(_ hz: Double, name: String, minutes: Int, clock: TestClock) -> Schedule {
        let (start, date) = Self.utc(clock.now.addingTimeInterval(ScheduleClock.broadcastLead))
        return Schedule(kind: .broadcast, name: name, frequenciesHz: [hz], mode: .am, start: start,
                        durationMinutes: minutes, timeZone: "UTC", days: .once(date), created: clock.now)
    }

    private static func utc(_ d: Date) -> (TimeOfDay, ScheduleDate) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        return (TimeOfDay(hour: c.hour!, minute: c.minute!), ScheduleDate(year: c.year!, month: c.month!, day: c.day!))
    }

    private func window(_ s: Schedule, _ clock: TestClock) -> DateInterval {
        ScheduleClock.windows(of: s, from: clock.now.addingTimeInterval(-86_400), to: clock.now.addingTimeInterval(86_400))[0]
    }

    @discardableResult
    private func wait(upTo timeout: Double, until done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() {
            if Date() >= end { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func canRun(_ m: AppModel) -> Bool {
        let source = m.preferredSource
        m.useSource(.sdrplay)
        if !m.isRunning { m.start() }
        let ok = m.isRunning
        m.stop()
        m.useSource(source)
        m.stop()
        if !ok { print("engine did not start (tolerated, no audio device)") }
        return ok
    }

    /// Adds `s`, turns the switch on and ticks: the watch starts, and is waited for until it watches.
    private func startWatching(_ m: AppModel, _ s: Schedule) async throws -> Bool {
        try m.scheduler.add(s)
        m.scheduler.isOn = true
        await m.scheduler.tick()
        #expect(m.scheduler.running?.scheduleID == s.id)
        let watching = await wait(upTo: 40) { m.scheduler.currentRun?.phase == .watching }
        #expect(watching, "phase \(String(describing: m.scheduler.currentRun?.phase))")
        return watching
    }

    private func endWindow(_ m: AppModel, _ s: Schedule, _ clock: TestClock) async {
        clock.now = window(s, clock).end
        await m.scheduler.tick()
        await m.scheduler.runTask?.value
        #expect(m.scheduler.running == nil)
    }

    private func lastRun(_ m: AppModel, _ s: Schedule) -> RunOutcome? {
        m.scheduler.schedules.first { $0.id == s.id }?.lastRun?.outcome
    }

    /// The `.recording` lines today (UTC) of files labelled with `s`.
    private func labelled(_ m: AppModel, _ s: Schedule) throws -> [(file: String, frequencyHz: Double, seconds: Double)] {
        let entries = try m.recordingLog.entries(forUTCDay: Date())
        let files = Set(entries.compactMap { if case .scheduled(let f, s.id, _) = $0 { f } else { nil } })
        return entries.compactMap {
            if case .recording(let f, _, let seconds, let hz, _, _) = $0, files.contains(f) { (f, hz, seconds) } else { nil }
        }
    }

    // MARK: Stations

    @Test func amVoiceIsFoundTunedAndRecorded() async throws {
        let (m, clock, stub) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        stub.answers = [6_925_000: Self.identity(.am, envelope: .voice), 6_955_000: Self.identity(.carrier)]
        let s = watch(clock: clock)
        guard try await startWatching(m, s) else { return }
        // Watching: centred on the span, both edges inside the capture's usable part.
        let usable = m.sampleRate * TuningPlanner.usableFraction
        #expect(abs(6_900_000 - m.centerHz) <= usable && abs(7_000_000 - m.centerHz) <= usable)
        await m.scheduler.tick()   // the button follows the run on each tick
        if case .watching(let item, let caught, let until) = m.scheduler.buttonState {
            #expect(item.name == "Pirates test" && item.lowHz == 6_900_000 && item.highHz == 7_000_000 && item.mode == nil)
            #expect(caught == 0 && until == window(s, clock).end)
        } else { Issue.record("button \(m.scheduler.buttonState)") }
        let floors = try #require(m.scheduler.currentRun?.modeFloors)
        #expect(floors[.usb] != nil && floors[.am] != nil)

        #expect(await wait(upTo: 20) { m.scheduler.currentRun?.phase == .recording })
        #expect(abs(m.vfoHz - 6_925_000) <= 500)
        #expect(m.mode == .am && m.bandwidthHz == DemodMode.am.defaultBandwidth)
        #expect(abs(m.squelchDb - (floors[.am]! + 8)) <= 0.5)
        #expect(m.scheduleRecording?.timing == m.recording.autoTiming)   // the owner's Auto timing, stop after included
        #expect(await wait(upTo: 15) { m.scheduler.currentRun?.files.count == 1 })
        await m.scheduler.tick()   // the button follows the run on each tick
        if case .recording(let item, _, let margin, _) = m.scheduler.buttonState {
            #expect(item.name == "Pirates test" && item.mode == "am" && margin == 8)
            #expect(abs((item.frequencyHz ?? 0) - 6_925_000) <= 500)
        } else { Issue.record("button \(m.scheduler.buttonState)") }
        #expect(stub.asked(near: 6_925_000) == 1)

        await endWindow(m, s, clock)
        let lines = try labelled(m, s)
        #expect(lines.count == 1, "\(lines)")
        #expect(abs((lines.first?.frequencyHz ?? 0) - 6_925_000) <= 500)
        guard case .recorded(let seconds, let files)? = lastRun(m, s) else {
            Issue.record("lastRun \(String(describing: lastRun(m, s)))")
            return
        }
        #expect(files == 1 && seconds > 0)
        let file = try #require(lines.first?.file)
        #expect(await wait(upTo: 5) { m.library.catalog.recording(file)?.scheduleName == "Pirates test" })
    }

    @Test func ssbVoiceIsRecordedInUSB() async throws {
        let (m, clock, stub) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        stub.answers = [6_925_000: Self.identity(.usb, envelope: .voice), 6_955_000: Self.identity(.carrier)]
        let s = watch(clock: clock)
        guard try await startWatching(m, s) else { return }
        #expect(await wait(upTo: 20) { m.scheduler.currentRun?.phase == .recording })
        #expect(m.mode == .usb && m.bandwidthHz == DemodMode.usb.defaultBandwidth)
        // The dial sits 300 Hz below the signal's low edge (its suppressed carrier), so the passband covers it.
        #expect(m.vfoHz < 6_925_000 && m.vfoHz > 6_920_000, "vfo \(m.vfoHz)")
        let floor = try #require(m.scheduler.currentRun?.modeFloors[.usb])
        #expect(abs(m.squelchDb - (floor + 8)) <= 0.5)
        #expect(await wait(upTo: 15) { m.scheduler.currentRun?.files.count == 1 })
        await m.scheduler.tick()   // the button follows the run on each tick
        if case .recording(let item, _, _, _) = m.scheduler.buttonState { #expect(item.mode == "usb") }
        else { Issue.record("button \(m.scheduler.buttonState)") }
        await endWindow(m, s, clock)
        if case .recorded(_, let files)? = lastRun(m, s) { #expect(files == 1) }
        else { Issue.record("lastRun \(String(describing: lastRun(m, s)))") }
    }

    @Test func carrierAndFSKAreIgnored() async throws {
        // Two wide signals, so both are candidates: Signal ID calls one FSK and the other a carrier.
        let (m, clock, stub) = makeModel(signals: [Self.am6925,
                                                   .init(frequency: 6_955_000, amplitude: 0.05, kind: .am(toneHz: 800))])
        defer { m.shutdown() }
        guard canRun(m) else { return }
        stub.answers = [6_925_000: Self.identity(.fsk), 6_955_000: Self.identity(.carrier)]
        let s = watch(clock: clock)
        guard try await startWatching(m, s) else { return }
        #expect(await wait(upTo: 20) { stub.asked(near: 6_925_000) == 1 && stub.asked(near: 6_955_000) == 1 })
        // Both still on and standing: each spot is rejected for `rejectSeconds`, so neither is asked about again
        // (a nil answer's short rejection, 6 s, would have let them back by now).
        await wait(upTo: 10) { false }
        #expect(stub.asked(near: 6_925_000) == 1 && stub.asked(near: 6_955_000) == 1, "\(stub.asked)")
        #expect(m.scheduler.currentRun?.phase == .watching)
        #expect(m.scheduleRecording == nil)
        await endWindow(m, s, clock)
        #expect(lastRun(m, s) == .nothingHeard(watch: true))
        #expect(try labelled(m, s).isEmpty)
    }

    @Test func peakAtTheBandEdgeIsIgnored() async throws {
        let (m, clock, stub) = makeModel(signals: [.init(frequency: 7_000_500, amplitude: 0.05, kind: .am(toneHz: 1_000))])
        defer { m.shutdown() }
        guard canRun(m) else { return }
        stub.answers = [7_000_500: Self.identity(.am, envelope: .voice)]
        let s = watch(clock: clock)
        guard try await startWatching(m, s) else { return }
        // Longer than the hold several times over.
        await wait(upTo: 8) { false }
        #expect(stub.asked.isEmpty, "\(stub.asked)")
        #expect(m.scheduler.currentRun?.phase == .watching)
        await endWindow(m, s, clock)
        #expect(lastRun(m, s) == .nothingHeard(watch: true))
    }

    @Test func firstStationIsKeptWhileTwoAreOn() async throws {
        // Both come on together; the first found (the lower, on the same frame) is kept until it ends.
        let (m, clock, stub) = makeModel(signals: [Self.am6925,
                                                   .init(frequency: 6_940_000, amplitude: 0.05, kind: .am(toneHz: 700))])
        defer { m.shutdown() }
        guard canRun(m) else { return }
        stub.answers = [6_925_000: Self.identity(.am, envelope: .voice), 6_940_000: Self.identity(.am, envelope: .voice)]
        let s = watch(clock: clock)
        guard try await startWatching(m, s) else { return }
        #expect(await wait(upTo: 20) { m.scheduler.currentRun?.files.count == 1 })
        // The other stays on and standing for several holds: the watch stays with the first.
        await wait(upTo: 6) { false }
        #expect(abs(m.vfoHz - 6_925_000) <= 500)
        #expect(stub.asked(near: 6_940_000) == 0, "\(stub.asked)")
        #expect(m.scheduler.currentRun?.files.count == 1)
        await endWindow(m, s, clock)
        let lines = try labelled(m, s)
        #expect(lines.count == 1 && abs((lines.first?.frequencyHz ?? 0) - 6_925_000) <= 500, "\(lines)")
    }

    @Test func aStationThatEndsGoesBackToWatching() async throws {
        let (m, clock, stub) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        stub.answers = [6_925_000: Self.identity(.am, envelope: .voice), 6_955_000: Self.identity(.carrier)]
        let s = watch(clock: clock)
        guard try await startWatching(m, s) else { return }
        #expect(await wait(upTo: 20) {
            m.scheduler.currentRun?.files.count == 1 && m.scheduler.currentRun?.phase == .recording
        })
        // The station goes quiet (the squelch above it): after Auto's stop after the file closes and the watch goes back.
        m.squelchDb = 0
        #expect(await wait(upTo: 15) { m.scheduleRecording == nil })
        #expect(m.scheduler.currentRun?.phase == .watching)
        #expect(m.vfoHz == 6_950_000)   // the span's middle
        await m.scheduler.tick()   // the button follows the run on each tick
        if case .watching(_, let caught, _) = m.scheduler.buttonState { #expect(caught == 1) }
        else { Issue.record("button \(m.scheduler.buttonState)") }
        // Still on the air: after its short rejection it is caught again, as a second transmission.
        #expect(await wait(upTo: 25) { m.scheduler.currentRun?.files.count == 2 })
        #expect(stub.asked(near: 6_925_000) == 2)
        await endWindow(m, s, clock)
        if case .recorded(_, let files)? = lastRun(m, s) { #expect(files == 2) }
        else { Issue.record("lastRun \(String(describing: lastRun(m, s)))") }
    }

    @Test func aStationThatNeverOpensTheSquelchIsGivenUp() async throws {
        let (m, clock, stub) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        stub.answers = [6_925_000: Self.identity(.am, envelope: .voice), 6_955_000: Self.identity(.carrier)]
        let s = watch(marginDb: 200, clock: clock)   // a squelch nothing opens
        guard try await startWatching(m, s) else { return }
        #expect(await wait(upTo: 20) { m.scheduleRecording != nil })   // tuned to the station
        // Start after + 5 s (5.5 s) with nothing recorded: back to watching, the spot rejected for `rejectSeconds`.
        // Never `recording` meanwhile, so the ticker doesn't say so.
        var sawRecording = false
        #expect(await wait(upTo: 15) {
            if m.scheduler.currentRun?.phase == .recording { sawRecording = true }
            return m.scheduleRecording == nil
        })
        #expect(!sawRecording)
        #expect(m.scheduler.currentRun?.phase == .watching)
        await wait(upTo: 10) { false }
        #expect(stub.asked(near: 6_925_000) == 1, "\(stub.asked)")
        #expect(m.scheduler.currentRun?.files.isEmpty == true)
        await endWindow(m, s, clock)
        #expect(lastRun(m, s) == .nothingHeard(watch: true))
    }

    @Test func ownerRetuneWhileAStationRecordsStopsTheWatch() async throws {
        let (m, clock, stub) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        stub.answers = [6_925_000: Self.identity(.am, envelope: .voice), 6_955_000: Self.identity(.carrier)]
        let s = watch(clock: clock)
        guard try await startWatching(m, s) else { return }
        #expect(await wait(upTo: 20) { m.scheduler.currentRun?.files.count == 1 })
        m.setVFO(6_980_000)
        #expect(await wait(upTo: 5) { m.scheduler.running == nil })
        #expect(lastRun(m, s) == .stoppedByYou)
        #expect(m.vfoHz == 6_980_000)   // stays where the owner put it
        #expect(!m.scheduleMuted && m.scheduleRecording == nil)
        await m.scheduler.tick()
        #expect(m.scheduler.running == nil)   // not taken back
    }

    @Test func ownerRetuneWhileWatchingStopsTheWatch() async throws {
        let (m, clock, _) = makeModel(signals: [])
        defer { m.shutdown() }
        guard canRun(m) else { return }
        let s = watch(clock: clock)
        guard try await startWatching(m, s) else { return }
        m.setMode(.usb)
        #expect(await wait(upTo: 5) { m.scheduler.running == nil })
        #expect(lastRun(m, s) == .stoppedByYou)
        #expect(m.mode == .usb)
    }

    // MARK: Overlaps

    @Test func broadcastPreemptsAndTheWatchResumes() async throws {
        let (m, clock, stub) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        stub.answers = [6_925_000: Self.identity(.am, envelope: .voice), 6_955_000: Self.identity(.carrier)]
        let w = watch(minutes: 60, clock: clock)
        guard try await startWatching(m, w) else { return }
        #expect(await wait(upTo: 20) { m.scheduler.currentRun?.files.count == 1 })

        // A broadcast's window opens: it takes the radio, ending the station's recording with its file kept.
        clock.now = clock.now.addingTimeInterval(60)
        let b = broadcast(6_925_000, name: "Radio Test", minutes: 5, clock: clock)
        try m.scheduler.add(b)
        await m.scheduler.tick()
        #expect(m.scheduler.running?.scheduleID == b.id)
        #expect(lastRun(m, w) == nil)   // no outcome: the watch only paused
        let kept = try labelled(m, w)
        #expect(kept.count == 1, "\(kept)")
        let onDisk = FileManager.default.enumerator(atPath: m.recording.folderPath ?? "")?.allObjects as? [String] ?? []
        #expect(kept.first.map { file in onDisk.contains { $0.hasSuffix(file.file) } } == true, "\(onDisk)")
        #expect(await wait(upTo: 40) { m.scheduler.currentRun?.phase == .recording })
        #expect(m.scheduler.busyMessage?.hasPrefix("SubFloor is recording a scheduled broadcast") == true)

        // The broadcast ends; on the same tick the watch starts again late in its window, and catches the station again.
        clock.now = window(b, clock).end
        await m.scheduler.tick()
        #expect(m.scheduler.running?.scheduleID == w.id)
        #expect(lastRun(m, b) != nil)
        #expect(await wait(upTo: 40) { m.scheduler.currentRun?.files.count == 2 })
        await endWindow(m, w, clock)
        // The window's outcome counts the transmission caught before the broadcast too.
        if case .recorded(_, let files)? = lastRun(m, w) { #expect(files == 2) }
        else { Issue.record("lastRun \(String(describing: lastRun(m, w)))") }
    }

    @Test func watchPausedToItsEndLogsWhatItCaught() async throws {
        let (m, clock, stub) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        stub.answers = [6_925_000: Self.identity(.am, envelope: .voice), 6_955_000: Self.identity(.carrier)]
        let w = watch(minutes: 3, clock: clock)
        guard try await startWatching(m, w) else { return }
        #expect(await wait(upTo: 20) { m.scheduler.currentRun?.files.count == 1 })
        clock.now = clock.now.addingTimeInterval(60)
        let b = broadcast(6_925_000, name: "Radio Test", minutes: 5, clock: clock)
        try m.scheduler.add(b)
        await m.scheduler.tick()
        #expect(m.scheduler.running?.scheduleID == b.id)
        // The watch's window ends while the broadcast still runs: what it caught is its outcome.
        clock.now = window(w, clock).end
        await m.scheduler.tick()
        if case .recorded(_, let files)? = lastRun(m, w) { #expect(files == 1) }
        else { Issue.record("lastRun \(String(describing: lastRun(m, w)))") }
        #expect(m.scheduler.running?.scheduleID == b.id)
    }

    // MARK: Voice

    @Test func ssbDialIsTheSuppressedCarrier() {
        let c = WatchCandidate(hz: 6_925_000, widthHz: 2_400, overFloorDb: 20)
        #expect(BroadcastRun.dial(for: c, mode: .usb) == 6_923_500)   // low edge 6923.8 − 300 Hz
        #expect(BroadcastRun.dial(for: c, mode: .lsb) == 6_926_500)   // high edge 6926.2 + 300 Hz
        #expect(BroadcastRun.dial(for: c, mode: .am) == 6_925_000)
        #expect(BroadcastRun.dial(for: c, mode: .nfm) == 6_925_000)
    }

    @Test(arguments: [SignalFamily.am, .usb, .lsb, .fm, .carrier, .fsk, .psk, .mfsk, .ofdm, .ook, .noise, .unknown])
    func voiceCheckFamilies(_ f: SignalFamily) {
        let plain = Self.identity(f)
        let voiced = Self.identity(f, envelope: .voice, audioEnvelope: .voice)
        let expected: DemodMode? = switch f {
        case .am: .am
        case .usb: .usb
        case .lsb: .lsb
        default: nil
        }
        #expect(VoiceCheck.recordMode(plain) == expected)
        #expect(VoiceCheck.recordMode(voiced) == (f == .fm ? .nfm : expected))
        // FM with speech in its demodulated audio (its RF envelope is steady).
        if f == .fm { #expect(VoiceCheck.recordMode(Self.identity(.fm, audioEnvelope: .voice)) == .nfm) }
    }
}
