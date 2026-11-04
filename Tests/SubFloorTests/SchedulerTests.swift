import DSPCore
import Foundation
import Recording
import Scheduling
import SDRplayKit
import SubFloorCore
import Testing
@testable import SubFloor

/// The run engine: the master switch, the store rules, and broadcast runs on the fake RSP (AM 0.05 at 10 MHz and
/// 0.01 at 9.5 MHz over noise). The scheduler's clock is a `TestClock` the tests move, and `tick()` is called by hand
/// (the model's scheduler doesn't tick itself here). A broadcast is a `.once` schedule on today's UTC date whose
/// window opens at the clock's time. Without an audio device the engine can't start and the run tests are skipped.
@MainActor
@Suite(.serialized)
struct SchedulerTests {
    /// The scheduler's `now`, moved by the test.
    @MainActor final class TestClock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private static let timing = Scheduler.Timing(pickSeconds: 3, spotSeconds: 0.5, quietCloseSeconds: 5,
                                                 rspTimeout: .seconds(5))
    private static let dallas = TimeZone(identifier: "America/Chicago")!

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorScheduler-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fakeRSP() -> SyntheticSource {
        SyntheticSource(signals: [.init(frequency: 10_000_000, amplitude: 0.05, kind: .am(toneHz: 1_000)),
                                  .init(frequency: 9_500_000, amplitude: 0.01, kind: .am(toneHz: 700))])
    }

    /// A whole minute, so a window can open exactly on it.
    private static func minute(_ d: Date) -> Date {
        Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    private func makeModel(fakeRSP: Bool = true, defaults: UserDefaults? = nil, dir: URL? = nil,
                           clock: TestClock? = nil,
                           openRSP: @escaping @Sendable () throws -> SDRplayDevice = { throw SDRplayError.noDevice })
        -> (AppModel, TestClock) {
        let dir = dir ?? tempDir()
        let clock = clock ?? TestClock(Self.minute(Date()))
        let m = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                         defaults: defaults ?? UserDefaults(suiteName: UUID().uuidString)!,
                         openRSP: openRSP, rspOpenTimeout: .seconds(2),
                         decodeHistoryFolder: dir.appendingPathComponent("decodes"),
                         fakeRSP: fakeRSP ? Self.fakeRSP() : nil,
                         makeScheduler: { store in
                             Scheduler(store: store, timing: Self.timing, now: { clock.now }, localZone: Self.dallas,
                                       autoTick: false)
                         })
        m.recording.folderPath = dir.appendingPathComponent("rec").path
        m.recording.autoTiming = AutoRecordTiming(startAfter: 0.5, stopAfter: 30, keepGapsUpTo: 8)
        return (m, clock)
    }

    /// A broadcast whose window opens `opensIn` seconds from the clock (its scheduled start a minute after that).
    private func broadcast(_ frequencies: [Double] = [10_000_000], name: String = "Radio Test", opensIn: TimeInterval = 0,
                           minutes: Int = 5, clock: TestClock) -> Schedule {
        let start = clock.now.addingTimeInterval(opensIn + ScheduleClock.broadcastLead)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        return Schedule(kind: .broadcast, name: name, frequenciesHz: frequencies, mode: .am,
                        start: TimeOfDay(hour: c.hour!, minute: c.minute!), durationMinutes: minutes, timeZone: "UTC",
                        days: .once(ScheduleDate(year: c.year!, month: c.month!, day: c.day!)), created: clock.now)
    }

    private func window(_ s: Schedule, _ clock: TestClock) -> DateInterval {
        ScheduleClock.windows(of: s, from: clock.now.addingTimeInterval(-86_400), to: clock.now.addingTimeInterval(86_400))[0]
    }

    /// Runs the main run loop (the stats timer and main-actor tasks) until `done`, for at most `timeout` seconds.
    @discardableResult
    private func wait(upTo timeout: Double, until done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() {
            if Date() >= end { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// True when the engine can run the fake RSP (an audio device exists); leaves the radio stopped.
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

    /// Adds `s`, turns the switch on and ticks: the run starts, and is waited for until it records.
    private func startAndRecord(_ m: AppModel, _ s: Schedule) async throws -> Bool {
        try m.scheduler.add(s)
        m.scheduler.isOn = true
        await m.scheduler.tick()
        #expect(m.scheduler.running?.scheduleID == s.id)
        let recording = await wait(upTo: 40) { m.scheduler.currentRun?.phase == .recording }
        #expect(recording, "phase \(String(describing: m.scheduler.currentRun?.phase))")
        return recording
    }

    /// Moves the clock to the window's end and ticks: the run ends and gives the radio back.
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

    // MARK: The switch and the store

    @Test func firstLaunchIsOffWithTheDefaultWatch() {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        #expect(m.scheduler.isOn == false)
        #expect(m.scheduler.schedules.count == 1)
        let watch = m.scheduler.schedules[0]
        #expect(watch.name == "Pirates" && watch.kind == .watch && !watch.enabled)
        #expect(watch.timeZone == "America/Chicago")
        #expect(m.scheduler.buttonState == .off(waiting: 0))
        #expect(m.scheduler.busyMessage == nil)
    }

    @Test func switchStateIsSaved() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let dir = tempDir()
        let (m, _) = makeModel(defaults: defaults, dir: dir)
        m.scheduler.isOn = true
        m.shutdown()
        let (again, _) = makeModel(defaults: defaults, dir: dir)
        defer { again.shutdown() }
        #expect(again.scheduler.isOn)
        again.scheduler.isOn = false
        again.shutdown()
        let (third, _) = makeModel(defaults: defaults, dir: dir)
        defer { third.shutdown() }
        #expect(!third.scheduler.isOn)
    }

    @Test func religiousAddIsRefused() {
        let (m, clock) = makeModel()
        defer { m.shutdown() }
        #expect(throws: ScheduleError.religious("Trans World Radio")) {
            try m.scheduler.add(broadcast(name: "Trans World Radio", clock: clock))
        }
        #expect(ScheduleError.religious("Trans World Radio").message == "The owner doesn't want religious broadcasts.")
        #expect(m.scheduler.schedules.count == 1)
    }

    @Test func atMost200Schedules() throws {
        let (m, clock) = makeModel()
        defer { m.shutdown() }
        for i in 1..<ScheduleStore.maxSchedules {
            try m.scheduler.add(broadcast(name: "Station \(i)", opensIn: 3_600, clock: clock))
        }
        #expect(m.scheduler.schedules.count == 200)
        #expect(throws: ScheduleError.tooMany) { try m.scheduler.add(broadcast(name: "One more", clock: clock)) }
        #expect(ScheduleError.tooMany.message == "There are already 200 schedules: delete some first.")
        // Saved: a fresh store reads them all.
        #expect(m.scheduler.store.load(localZone: "UTC").0.count == 200)
    }

    @Test func addAndUpdateAreValidated() throws {
        let (m, clock) = makeModel()
        defer { m.shutdown() }
        var s = broadcast(clock: clock)
        s.frequenciesHz = []
        #expect(throws: ScheduleError.invalid("frequencies must be 1 to 8 frequencies between 1 kHz and 2000 MHz.")) { try m.scheduler.add(s) }
        s.frequenciesHz = [500]
        #expect(throws: ScheduleError.invalid("frequencies must be 1 to 8 frequencies between 1 kHz and 2000 MHz.")) { try m.scheduler.add(s) }
        s.frequenciesHz = [10_000_000]
        s.durationMinutes = 361
        #expect(throws: ScheduleError.invalid("A broadcast can be at most 6 hours.")) { try m.scheduler.add(s) }
        s.durationMinutes = 30
        s.timeZone = "Mars/Olympus"
        #expect(throws: ScheduleError.invalid("Unknown time zone Mars/Olympus.")) { try m.scheduler.add(s) }
        var w = m.scheduler.schedules[0]
        w.highHz = 7_500_000
        #expect(throws: ScheduleError.invalid("A watch's span must be 10 to 400 kHz.")) { try m.scheduler.update(w) }
        w.highHz = 7_000_000
        w.durationMinutes = 721
        #expect(throws: ScheduleError.invalid("A watch can be at most 12 hours.")) { try m.scheduler.update(w) }
        w.durationMinutes = 420
        w.enabled = true
        try m.scheduler.update(w)
        #expect(m.scheduler.schedules[0].enabled)
        // A watch's edges are tunable frequencies.
        w.lowHz = 500
        w.highHz = 100_500
        #expect(throws: ScheduleError.invalid("frequencies must be 1 to 8 frequencies between 1 kHz and 2000 MHz.")) { try m.scheduler.update(w) }
        w.lowHz = 1_999_990_000
        w.highHz = 2_000_090_000
        #expect(throws: ScheduleError.invalid("frequencies must be 1 to 8 frequencies between 1 kHz and 2000 MHz.")) { try m.scheduler.update(w) }
        // An id already in use.
        let first = broadcast(clock: clock)
        try m.scheduler.add(first)
        var copy = broadcast(name: "Another", clock: clock)
        copy.id = first.id
        #expect(throws: ScheduleError.invalid("A schedule with that id already exists.")) { try m.scheduler.add(copy) }
        #expect(m.scheduler.schedules.filter { $0.id == first.id }.count == 1)
        #expect(ScheduleError.invalid("x").message == "x")
    }

    @Test func offForHoursThenOnLogsNothing() async throws {
        let (m, clock) = makeModel()
        defer { m.shutdown() }
        let s = broadcast(opensIn: 60, minutes: 5, clock: clock)
        try m.scheduler.add(s)
        await m.scheduler.tick()
        // Two hours pass with the switch off, ticking every second as the timer does (sampled here).
        for _ in 0..<(2 * 3_600 / 20) {
            clock.now = clock.now.addingTimeInterval(20)
            await m.scheduler.tick()
        }
        m.scheduler.isOn = true
        await m.scheduler.tick()
        #expect(lastRun(m, s) == nil)
        #expect(m.scheduler.running == nil)
    }

    // MARK: Broadcasts

    @Test func emptyFrequencyMakesNoFile() async throws {
        let (m, clock) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        let s = broadcast([9_990_000], clock: clock)
        guard try await startAndRecord(m, s) else { return }
        // Long enough for a file to open if the squelch let anything through.
        await wait(upTo: 3) { false }
        await endWindow(m, s, clock)
        #expect(lastRun(m, s) == .nothingHeard(watch: false))
        #expect(try labelled(m, s).isEmpty)
    }

    @Test func signalMakesOneLabelledFile() async throws {
        let (m, clock) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        let s = broadcast([10_000_000], name: "Voice of Test", clock: clock)
        guard try await startAndRecord(m, s) else { return }
        #expect(await wait(upTo: 15) { m.scheduler.currentRun?.files.count == 1 })
        #expect(m.autoRecordState == .scheduled)
        if case .recording(let item, _, let margin, let until) = m.scheduler.buttonState {
            #expect(item.name == "Voice of Test" && item.frequencyHz == 10_000_000 && margin == 8)
            #expect(until == window(s, clock).end)
        } else { Issue.record("button \(m.scheduler.buttonState)") }
        #expect(m.scheduler.busyMessage?.hasPrefix("SubFloor is recording a scheduled broadcast until ") == true)
        await endWindow(m, s, clock)
        let lines = try labelled(m, s)
        #expect(lines.count == 1, "\(lines)")
        guard case .recorded(let seconds, let files)? = lastRun(m, s) else {
            Issue.record("lastRun \(String(describing: lastRun(m, s)))")
            return
        }
        #expect(files == 1)
        #expect(seconds > 0 && seconds == lines.first?.seconds)
        let file = try #require(lines.first?.file)
        #expect(await wait(upTo: 5) { m.library.catalog.recording(file)?.scheduleName == "Voice of Test" })
        #expect(m.autoRecordState == .off)
    }

    @Test func strongestOfThreeIsPicked() async throws {
        let (m, clock) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        let s = broadcast([9_990_000, 9_500_000, 10_000_000], clock: clock)
        clock.now = clock.now.addingTimeInterval(ScheduleClock.broadcastLead)   // on air: the pick runs at once
        guard try await startAndRecord(m, s) else { return }
        #expect(m.scheduler.currentRun?.frequencyHz == 10_000_000)
        #expect(m.vfoHz == 10_000_000)
        #expect(await wait(upTo: 15) { m.scheduler.currentRun?.files.count == 1 })
        await endWindow(m, s, clock)
        let lines = try labelled(m, s)
        #expect(lines.map { $0.frequencyHz } == [10_000_000])
    }

    @Test func ticksThroughASetupWithSeveralFrequencies() async throws {
        let (m, clock) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        let s = broadcast([9_990_000, 9_500_000, 10_000_000], clock: clock)
        clock.now = clock.now.addingTimeInterval(ScheduleClock.broadcastLead)
        try m.scheduler.add(s)
        m.scheduler.isOn = true
        // The timer's ticks through the floor and the pick, at ten a second: the run's own tunes are not the owner's.
        await m.scheduler.tick()
        let end = Date().addingTimeInterval(40)
        while m.scheduler.running != nil, m.scheduler.currentRun?.phase != .recording, Date() < end {
            try? await Task.sleep(for: .milliseconds(100))
            await m.scheduler.tick()
        }
        #expect(m.scheduler.currentRun?.phase == .recording)
        #expect(m.scheduler.currentRun?.frequencyHz == 10_000_000)
        await endWindow(m, s, clock)
        #expect(lastRun(m, s) != .stoppedByYou)
    }

    @Test func ownerRetuneWhileWaitingToGoOnAirStopsTheRun() async throws {
        let (m, clock) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        let s = broadcast([9_990_000, 10_000_000], clock: clock)   // the clock stays in the lead minute
        try m.scheduler.add(s)
        m.scheduler.isOn = true
        await m.scheduler.tick()
        #expect(await wait(upTo: 40) { m.scheduler.currentRun?.phase == .picking })
        m.setVFO(10_020_000)
        // Seen by the run itself, with no tick.
        #expect(await wait(upTo: 5) { m.scheduler.running == nil })
        #expect(lastRun(m, s) == .stoppedByYou)
        #expect(m.vfoHz == 10_020_000)   // stays where the owner put it
        #expect(m.isRunning && m.sourceKind == .sdrplay)
    }

    @Test func ownerRetuneDuringThePickStopsTheRun() async throws {
        let (m, clock) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        let s = broadcast([9_990_000, 9_500_000, 10_000_000], clock: clock)
        clock.now = clock.now.addingTimeInterval(ScheduleClock.broadcastLead)   // on air: the hops start at once
        try m.scheduler.add(s)
        m.scheduler.isOn = true
        await m.scheduler.tick()
        #expect(await wait(upTo: 40) { m.scheduler.currentRun?.phase == .picking })
        m.setVFO(10_020_000)
        #expect(await wait(upTo: 10) { m.scheduler.running == nil })
        #expect(lastRun(m, s) == .stoppedByYou)
        #expect(m.vfoHz == 10_020_000)
    }

    @Test func squelchIsFloorPlusMargin() async throws {
        let (m, clock) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        let s = broadcast([10_000_000], clock: clock)
        guard try await startAndRecord(m, s) else { return }
        let floor = try #require(m.scheduler.currentRun?.floorDb)
        #expect(floor > -150 && floor < -20)
        #expect(abs(m.squelchDb - (floor + 8)) <= 0.5)
        #expect(m.squelchEnabled)
        await endWindow(m, s, clock)
    }

    @Test func radioIsRestoredIncludingStopped() async throws {
        let (m, clock) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        m.useSource(.synthetic)
        m.stop()
        m.tune(to: 14_200_000)
        m.setMode(.usb)
        m.squelchEnabled = false
        m.squelchDb = -95
        m.autoRecordEnabled = false
        let before = m.saveRadio()
        #expect(!before.running && before.source == .synthetic)
        let s = broadcast([10_000_000], clock: clock)
        guard try await startAndRecord(m, s) else { return }
        #expect(m.isRunning && m.sourceKind == .sdrplay)
        #expect(m.upconverter.enabled)   // HamItUp on below 30 MHz
        #expect(m.sessionRadioOverride == before)
        await endWindow(m, s, clock)
        #expect(m.saveRadio() == before)
        #expect(!m.isRunning)
        #expect(m.preferredSource == .synthetic)
        #expect(m.vfoHz == 14_200_000 && m.mode == .usb)
        #expect(!m.squelchEnabled && m.squelchDb == -95 && !m.autoRecordEnabled)
        #expect(m.sessionRadioOverride == nil)
        #expect(m.scheduler.radioTakenAt == nil)
    }

    @Test func liveAudioMutedDuringRunOnly() async throws {
        let (m, clock) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        let s = broadcast([10_000_000], clock: clock)
        guard try await startAndRecord(m, s) else { return }
        #expect(m.scheduleMuted)
        #expect(m.effectiveVolume == 0)
        await endWindow(m, s, clock)
        #expect(!m.scheduleMuted)

        // Started early from the ticker: it plays.
        let early = broadcast([10_000_000], name: "Early", opensIn: 120, clock: clock)
        try m.scheduler.add(early)
        await m.scheduler.tick()
        guard case .soon(let item, let secondsLeft) = m.scheduler.buttonState else {
            Issue.record("button \(m.scheduler.buttonState)")
            return
        }
        #expect(item.name == "Early" && secondsLeft == 120)
        m.scheduler.startEarly()
        #expect(m.scheduler.running?.scheduleID == early.id && m.scheduler.running?.startedEarly == true)
        #expect(await wait(upTo: 40) { m.scheduler.currentRun?.phase == .recording })
        #expect(!m.scheduleMuted)
        await endWindow(m, early, clock)
        #expect(!m.scheduleMuted)
    }

    @Test func schedulerWinsOverOwnersAutoAndManual() async throws {
        let (m, clock) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        m.useSource(.sdrplay)
        if !m.isRunning { m.start() }
        m.tune(to: 7_100_000)
        m.squelchEnabled = true
        m.autoRecordEnabled = true
        m.startRecording(.audio)
        #expect(await wait(upTo: 5) { m.isRecording(.audio) && m.recordingStatus[.audio]?.url != nil })
        let manual = try #require(m.recordingStatus[.audio]?.url)
        let s = broadcast([10_000_000], clock: clock)
        guard try await startAndRecord(m, s) else { return }
        #expect(!m.isRecording(.audio))
        #expect(FileManager.default.fileExists(atPath: manual.path))   // its file is kept
        #expect(m.autoRecordState == .scheduled)
        await endWindow(m, s, clock)
        #expect(m.autoRecordEnabled)   // the owner's Auto is back
        #expect(m.vfoHz == 7_100_000)
    }

    @Test func ownerRetuneStopsTheRun() async throws {
        let (m, clock) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        let s = broadcast([10_000_000], clock: clock)
        guard try await startAndRecord(m, s) else { return }
        m.setVFO(10_020_000)
        await m.scheduler.tick()
        await m.scheduler.runTask?.value
        #expect(m.scheduler.running == nil)
        #expect(lastRun(m, s) == .stoppedByYou)
        #expect(m.vfoHz == 10_020_000)   // stays where the owner put it
        #expect(m.isRunning && m.sourceKind == .sdrplay && m.mode == .am)
        #expect(!m.scheduleMuted)
        clock.now = clock.now.addingTimeInterval(5)
        await m.scheduler.tick()
        #expect(m.scheduler.running == nil)   // not taken back
    }

    @Test func deletingTheRunningScheduleEndsIt() async throws {
        let (m, clock) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        m.squelchDb = -97
        let before = m.saveRadio()   // stopped, the RSP chosen, 14.2 MHz USB
        let s = broadcast([10_000_000], clock: clock)
        guard try await startAndRecord(m, s) else { return }
        m.scheduler.delete(s.id)
        await m.scheduler.runTask?.value
        #expect(m.scheduler.running == nil)
        #expect(m.scheduler.lastOutcome == .stoppedByYou)
        #expect(!m.scheduler.schedules.contains { $0.id == s.id })
        // The owner didn't touch the radio: all of it goes back.
        #expect(m.saveRadio() == before)
        #expect(!m.isRunning)
        #expect(!m.scheduleMuted)
        #expect(m.scheduleRecording == nil)
    }

    @Test func stopRunRestoresAStoppedDemoRadio() async throws {
        let (m, clock) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        m.useSource(.synthetic)
        m.stop()
        m.tune(to: 14_200_000)
        m.setMode(.usb)
        let before = m.saveRadio()
        let s = broadcast([10_000_000], clock: clock)
        guard try await startAndRecord(m, s) else { return }
        m.scheduler.stopRun()
        await m.scheduler.runTask?.value
        #expect(lastRun(m, s) == .stoppedByYou)
        #expect(m.saveRadio() == before)
        #expect(!m.isRunning && m.preferredSource == .synthetic)
        #expect(m.vfoHz == 14_200_000 && m.mode == .usb)
        #expect(!m.scheduleMuted)
        await m.scheduler.tick()
        #expect(m.scheduler.running == nil)   // that window stays stopped
    }

    @Test func switchOffMidRunEndsIt() async throws {
        let (m, clock) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        let s = broadcast([10_000_000], clock: clock)
        guard try await startAndRecord(m, s) else { return }
        let before = try #require(m.sessionRadioOverride)
        m.scheduler.isOn = false
        await m.scheduler.runTask?.value
        #expect(m.scheduler.running == nil)
        #expect(lastRun(m, s) == .stoppedByYou)
        #expect(!m.scheduleMuted && m.scheduleRecording == nil)
        #expect(m.saveRadio() == before && !m.isRunning)   // put back fully
        m.scheduler.isOn = true
        await m.scheduler.tick()
        #expect(m.scheduler.running == nil)   // that window stays stopped
    }

    @Test func switchOnMidWindowStartsLate() async throws {
        let (m, clock) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        let s = broadcast([10_000_000], opensIn: -600, minutes: 30, clock: clock)
        try m.scheduler.add(s)
        await m.scheduler.tick()
        #expect(m.scheduler.running == nil)
        m.scheduler.isOn = true
        await m.scheduler.tick()
        #expect(m.scheduler.running?.scheduleID == s.id)
        #expect(await wait(upTo: 40) { m.scheduler.currentRun?.phase == .recording })
        await endWindow(m, s, clock)
    }

    @Test func noRSPIsLoggedAsMissed() async throws {
        let (m, clock) = makeModel(fakeRSP: false)
        defer { m.shutdown() }
        m.useSource(.synthetic)
        m.tune(to: 14_200_000)
        let before = m.saveRadio()
        let s = broadcast([10_000_000], clock: clock)
        try m.scheduler.add(s)
        m.scheduler.isOn = true
        await m.scheduler.tick()
        await m.scheduler.runTask?.value
        #expect(lastRun(m, s) == .missedNoRSP)
        #expect(m.saveRadio() == before)
        #expect(m.banner?.message == "A schedule was missed: the RSP wasn't connected.")
        #expect(!m.scheduleMuted)
        await m.scheduler.tick()
        #expect(m.scheduler.running == nil)   // not tried again in this window
    }

    @Test func startRSPForScheduleGivesUpOnQuit() async {
        // An open that hangs: quitting while a run waits for it ends the wait (it would otherwise last the open's life).
        let (m, _) = makeModel(fakeRSP: false, openRSP: {
            Thread.sleep(forTimeInterval: 60)
            throw SDRplayError.noDevice
        })
        final class Answer { var value: Bool? }
        let answer = Answer()
        Task { answer.value = await m.startRSPForSchedule(timeout: .milliseconds(100)) }
        #expect(await wait(upTo: 5) { m.rspConnection == .opening })
        m.shutdown()
        #expect(await wait(upTo: 5) { answer.value != nil })
        #expect(answer.value == false)
        #expect(!m.isRunning)
    }

    @Test func quitMidRunLogsWhatWasRecorded() async throws {
        let (m, clock) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        let s = broadcast([10_000_000], clock: clock)
        guard try await startAndRecord(m, s) else { return }
        #expect(await wait(upTo: 15) { m.scheduler.currentRun?.files.count == 1 })
        m.shutdown()
        guard case .recorded(_, let files)? = lastRun(m, s) else {
            Issue.record("lastRun \(String(describing: lastRun(m, s)))")
            return
        }
        #expect(files == 1)
        // Saved: a fresh read of the store has it.
        let stored = m.scheduler.store.load(localZone: "UTC").0.first { $0.id == s.id }
        #expect(stored?.lastRun?.outcome == lastRun(m, s))
        await wait(upTo: 0.5) { false }
        #expect(!m.isRunning)
    }

    @Test func quitMidTeardownDoesNotRestartTheRadio() async throws {
        let (m, clock) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        m.useSource(.synthetic)   // running on Demo: a restore would start it again
        #expect(m.isRunning)
        let s = broadcast([10_000_000], clock: clock)
        guard try await startAndRecord(m, s) else { return }
        #expect(await wait(upTo: 15) { m.scheduler.currentRun?.files.count == 1 })
        clock.now = window(s, clock).end
        let ending = Task { await m.scheduler.tick() }
        #expect(await wait(upTo: 5) { m.scheduler.currentRun?.phase == .ending })
        m.shutdown()
        await ending.value
        await wait(upTo: 0.5) { false }
        #expect(!m.isRunning)
        if case .recorded(_, let files)? = lastRun(m, s) { #expect(files == 1) }
        else { Issue.record("lastRun \(String(describing: lastRun(m, s)))") }
    }

    @Test func rspLostMidRun() async throws {
        let (m, clock) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        let s = broadcast([10_000_000], clock: clock)
        guard try await startAndRecord(m, s) else { return }
        clock.now = clock.now.addingTimeInterval(120)
        m.simulateDeviceRemovedForTesting()
        await m.scheduler.tick()
        await m.scheduler.runTask?.value
        #expect(lastRun(m, s) == .rspLost(afterSeconds: 120))
        #expect(!m.isRunning)   // not restarted, on Demo or anything
        #expect(!m.scheduleMuted)
        #expect(m.scheduleRecording == nil)
    }

    @Test func lowDiskEndsTheRun() async throws {
        let (m, clock) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        let s = broadcast([10_000_000], clock: clock)
        guard try await startAndRecord(m, s) else { return }
        m.freeSpaceProbe = { _ in 50_000_000 }
        m.checkRecordingsDiskSpace()
        await m.scheduler.runTask?.value
        #expect(lastRun(m, s) == .lowDisk)
        #expect(m.scheduleRecording == nil && !m.scheduleMuted)
    }

    @Test func keepAwakeActivities() async throws {
        let (m, clock) = makeModel()
        defer { m.shutdown() }
        guard canRun(m) else { return }
        try m.scheduler.add(broadcast(name: "Later", opensIn: 2 * 3_600, clock: clock))
        #expect(!m.scheduler.isPreventingIdleSleep)
        m.scheduler.isOn = true
        #expect(m.scheduler.isPreventingIdleSleep)
        #expect(!m.scheduler.isHoldingRunActivity)
        let s = broadcast([10_000_000], clock: clock)
        try m.scheduler.add(s)
        await m.scheduler.tick()
        #expect(m.scheduler.isHoldingRunActivity)
        m.scheduler.isOn = false
        await m.scheduler.runTask?.value
        #expect(!m.scheduler.isPreventingIdleSleep)
        #expect(!m.scheduler.isHoldingRunActivity)
    }
}
