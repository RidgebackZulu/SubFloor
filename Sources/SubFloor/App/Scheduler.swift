import DSPCore
import Foundation
import Observation
import Scheduling
import SignalID

/// Why `Scheduler.add` or `update` refused a schedule. `message` is the text the owner and agents see.
enum ScheduleError: Error, Equatable {
    case tooMany
    case religious(String)
    case invalid(String)

    var message: String {
        switch self {
        case .tooMany: "There are already \(ScheduleStore.maxSchedules) schedules: delete some first."
        case .religious: "The owner doesn't want religious broadcasts."
        case .invalid(let text): text
        }
    }
}

/// The run engine, owned by `AppModel` like `SignalIDService`: once a second it asks the planner what is due and
/// carries it out, one run at a time (`BroadcastRun` drives the radio, for broadcasts and watches). Every outcome is
/// saved on the schedule's `lastRun` and written to the store.
///
/// The planner is stateless; the engine keeps the windows that must not start again (`settled`), the last tick and
/// when SubFloor was last known running (`schedulerAlive` in the session). It keeps ticking while the switch is off,
/// so turning it on after hours off doesn't read the gap as sleep.
@MainActor @Observable
final class Scheduler {
    struct Timing: Equatable {
        var tick: Duration = .seconds(1)
        var pickSeconds: Double = 30        // choosing among several frequencies
        var spotSeconds: Double = 3
        var quietCloseSeconds: Double = 600 // a broadcast's stopAfter
        var watchRefloorSeconds: Double = 600
        var rejectSeconds: Double = 600
        var rspTimeout: Duration = .seconds(15)
    }

    @ObservationIgnored let store: ScheduleStore
    @ObservationIgnored let timing: Timing
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored let localZone: TimeZone
    /// False in tests, which call `tick()` by hand.
    @ObservationIgnored private let autoTick: Bool
    @ObservationIgnored private weak var model: AppModel?

    private(set) var schedules: [Schedule]
    /// The master switch (saved in the session; off at first launch). Turning it off ends a run as `.stoppedByYou`.
    var isOn = false {
        didSet {
            guard isOn != oldValue, model != nil else { return }
            if !isOn { endRun(.stoppedByYou) }
            model?.saveSessionIfChanged()
            updateKeepAwake()
            refreshButton()
        }
    }
    private(set) var running: ActiveRun?
    /// When the current run took the radio (agents' interrupted calls say `a schedule took the radio`).
    private(set) var radioTakenAt: Date?
    private(set) var buttonState: ScheduleButtonState = .off(waiting: 0)

    /// The run in progress, its radio work and what it has recorded.
    @ObservationIgnored private(set) var currentRun: BroadcastRun?
    /// The current run's whole life, setup to teardown; done once it has given the radio back.
    @ObservationIgnored private(set) var runTask: Task<Void, Never>?
    /// The last outcome logged by a run that ended (test hook: a deleted schedule has no `lastRun`).
    @ObservationIgnored private(set) var lastOutcome: RunOutcome?
    /// Stamped once a minute while SubFloor runs and saved in the session; read at launch for windows missed while
    /// it wasn't running.
    @ObservationIgnored private(set) var aliveStamp: Date?
    /// Signal ID for a watch's candidate (tests stub it).
    @ObservationIgnored var identify: @MainActor (_ hz: Double) async -> SignalIdentity? = { _ in nil }

    @ObservationIgnored private var settled: Set<RunKey> = []
    /// Watches a broadcast took the radio from, with what they had recorded in their window: carried into the run that
    /// resumes the window, or logged as its outcome if the window ends first.
    @ObservationIgnored private var pausedWatches: [RunKey: BroadcastRun.Recorded] = [:]
    @ObservationIgnored private var lastTick: Date?
    @ObservationIgnored private var launchAlive: Date?
    /// The window the ticker pulses for (`startEarly`).
    @ObservationIgnored private var soonWindow: (schedule: Schedule, window: DateInterval)?
    @ObservationIgnored private var tickChain: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var idleActivity: NSObjectProtocol?
    @ObservationIgnored private var runActivity: NSObjectProtocol?
    @ObservationIgnored private var loadResult: ScheduleStore.LoadResult
    @ObservationIgnored private var saveBlocked = false
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored private var loadedTimetable: Timetable?

    init(store: ScheduleStore, timing: Timing = Timing(), now: @escaping () -> Date = Date.init,
         localZone: TimeZone = .current, autoTick: Bool = true) {
        self.store = store
        self.timing = timing
        self.now = now
        self.localZone = localZone
        self.autoTick = autoTick
        let (loaded, result) = store.load(localZone: localZone.identifier)
        schedules = loaded
        loadResult = result
        saveBlocked = result == .corruptNotPreserved
        identify = { [weak self] hz in
            await self?.model?.signalID.identify(atHz: hz, radiusHz: 5_000, longerRead: false, priority: .background)
        }
    }

    /// The North America timetable: the bundled season, parsed on first use, until `timetableUpdated` replaces it.
    var timetable: Timetable {
        if let loadedTimetable { return loadedTimetable }
        let t = Timetable(data: Timetable.bundledData(), season: EiBiSeason(year: 2026, half: .b))
        loadedTimetable = t
        return t
    }

    /// The session's switch and alive stamp, before `attach` (from `AppModel.restoreSession`).
    func restoreSession(on: Bool, alive: Date?) {
        isOn = on
        aliveStamp = alive
        launchAlive = alive
    }

    func attach(to model: AppModel) {
        self.model = model
        model.onLowDiskStop = { [weak self] in self?.endRun(.lowDisk) }
        model.onLogged = { [weak self] entries in self?.currentRun?.logged(entries) }
        switch loadResult {
        case .recoveredFromCorrupt:
            model.show(Banner(kind: .warning, message: "The schedules file was unreadable. It was backed up as \(store.lastBackupURL?.lastPathComponent ?? "schedules.corrupt-<timestamp>.json") and the default watch was restored."))
        case .corruptNotPreserved:
            model.show(Banner(kind: .error, message: Self.saveBlockedMessage))
        case .loaded, .createdDefaults:
            break
        }
        updateKeepAwake()
        refreshButton()
        guard autoTick else { return }
        let step = timing.tick
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: step)
            }
        }
    }

    /// App quit: the timer and a run in progress stop where they are (the session already holds the owner's radio).
    /// A run cut short logs what it has recorded so far, and the store is saved.
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        if let run = currentRun, let model, let outcome = run.outcomeAtQuit(model, now: now()) {
            record(outcome, for: run.schedule.id, at: now())
            lastOutcome = outcome
        }
        save()
        timerTask?.cancel()
        currentRun?.setupTask?.cancel()
        runTask?.cancel()
        endActivity(&idleActivity)
        endActivity(&runActivity)
    }

    // MARK: Schedules

    static let saveBlockedMessage = "The schedules file is unreadable and could not be backed up. Changes to schedules will not be saved until the file is fixed or removed."

    func add(_ s: Schedule) throws {
        guard schedules.count < ScheduleStore.maxSchedules else { throw ScheduleError.tooMany }
        guard !schedules.contains(where: { $0.id == s.id }) else {
            throw ScheduleError.invalid("A schedule with that id already exists.")
        }
        try Self.validate(s)
        schedules.append(s)
        schedulesChanged()
    }

    /// Updating the running schedule's tuning (or switching it off) ends its run as `.stoppedByYou`.
    func update(_ s: Schedule) throws {
        guard let i = schedules.firstIndex(where: { $0.id == s.id }) else { throw ScheduleError.invalid("No schedule has that id.") }
        try Self.validate(s)
        let old = schedules[i]
        schedules[i] = s
        if currentRun?.schedule.id == s.id,
           old.kind != s.kind || old.frequenciesHz != s.frequenciesHz || old.mode != s.mode
            || old.lowHz != s.lowHz || old.highHz != s.highHz || !s.enabled {
            endRun(.stoppedByYou)
        }
        schedulesChanged()
    }

    /// Deleting the running schedule ends its run as `.stoppedByYou`.
    func delete(_ id: UUID) {
        guard schedules.contains(where: { $0.id == id }) else { return }
        schedules.removeAll { $0.id == id }
        if currentRun?.schedule.id == id { endRun(.stoppedByYou) }
        schedulesChanged()
    }

    /// Replaces the timetable (a weekly update): relinks timetable schedules and saves.
    func timetableUpdated(_ t: Timetable) {
        loadedTimetable = t
        schedules = t.relink(schedules, now: now())
        schedulesChanged()
    }

    /// The checks the editor and the MCP tools rely on, with the texts they show.
    static func validate(_ s: Schedule) throws {
        if ReligiousFilter.bundled.isReligious(s.name) { throw ScheduleError.religious(s.name) }
        guard TimeZone(identifier: s.timeZone) != nil else { throw ScheduleError.invalid("Unknown time zone \(s.timeZone).") }
        guard s.durationMinutes >= 1 else { throw ScheduleError.invalid("A schedule must last at least 1 minute.") }
        let tunable: (Double) -> Bool = { $0.isFinite && (1_000...2_000_000_000).contains($0) }
        let frequencyText = "frequencies must be 1 to 8 frequencies between 1 kHz and 2000 MHz."
        switch s.kind {
        case .broadcast:
            guard (1...8).contains(s.frequenciesHz.count), s.frequenciesHz.allSatisfy(tunable) else {
                throw ScheduleError.invalid(frequencyText)
            }
            guard s.durationMinutes <= 6 * 60 else { throw ScheduleError.invalid("A broadcast can be at most 6 hours.") }
        case .watch:
            if let low = s.lowHz, !tunable(low) { throw ScheduleError.invalid(frequencyText) }
            if let high = s.highHz, !tunable(high) { throw ScheduleError.invalid(frequencyText) }
            guard let low = s.lowHz, let high = s.highHz, low.isFinite, high.isFinite,
                  (10_000...400_000).contains(high - low) else {
                throw ScheduleError.invalid("A watch's span must be 10 to 400 kHz.")
            }
            guard s.durationMinutes <= 12 * 60 else { throw ScheduleError.invalid("A watch can be at most 12 hours.") }
        }
    }

    private func schedulesChanged() {
        save()
        updateKeepAwake()
        refreshButton()
    }

    private func save() {
        guard !saveBlocked else {
            model?.show(Banner(kind: .error, message: Self.saveBlockedMessage))
            return
        }
        do { try store.save(schedules) } catch {
            model?.show(Banner(kind: .error, message: "Could not save schedules: \(error.localizedDescription)"))
        }
    }

    private func record(_ outcome: RunOutcome, for id: UUID, at: Date) {
        guard let i = schedules.firstIndex(where: { $0.id == id }) else { return }
        schedules[i].lastRun = LastRun(outcome: outcome, at: at)
        save()
    }

    // MARK: Ticking

    /// Runs one tick now (tests; the timer calls it every `timing.tick`). Ticks run one after another: a tick that
    /// ends a run waits for it to give the radio back before starting the next.
    func tick() async {
        let previous = tickChain
        let task = Task { [weak self] in
            await previous?.value
            await self?.tickNow()
        }
        tickChain = task
        await task.value
    }

    private func tickNow() async {
        guard let model, !isShutDown else { return }
        var now = now()
        if let run = currentRun, run.endReason == nil, let reason = run.check(model) { endRun(reason) }
        if currentRun?.endReason != nil {
            await runTask?.value
            guard !isShutDown else { return }
            now = self.now()   // the teardown took a while
        }

        let actions = SchedulePlanner.tick(schedules: schedules, on: isOn, now: now, lastTick: lastTick,
                                           lastAlive: launchAlive, running: running, settled: settled)
        lastTick = now
        for action in actions {
            switch action {
            case .end(let id):
                guard running?.scheduleID == id else { continue }
                endRun(.windowEnd)
                await runTask?.value
            case .log(let id, let outcome, let at):
                record(outcome, for: id, at: at)
                if case .overlapped = outcome, let s = schedules.first(where: { $0.id == id }) {
                    for w in ScheduleClock.windows(of: s, from: now, to: now.addingTimeInterval(1)) where w.start <= now {
                        settled.insert(RunKey(scheduleID: id, window: w))
                    }
                }
            case .start(let id, let window, _):
                if let s = schedules.first(where: { $0.id == id }) { startRun(s, window: window, early: false) }
            case .preempt(_, let by, let window):
                endRun(.preempted)
                await runTask?.value
                if let s = schedules.first(where: { $0.id == by }) { startRun(s, window: window, early: false) }
            }
        }
        if aliveStamp.map({ now.timeIntervalSince($0) >= 60 || $0 > now }) ?? true {
            aliveStamp = now
            model.saveSessionIfChanged()
        }
        for (key, recorded) in pausedWatches where key.window.end <= now && running?.scheduleID != key.scheduleID {
            pausedWatches[key] = nil
            let seconds = recorded.files.compactMap { recorded.secondsByFile[$0] }.reduce(0, +)
            record(recorded.files.isEmpty ? .nothingHeard(watch: true) : .recorded(seconds: seconds, files: recorded.files.count),
                   for: key.scheduleID, at: now)
        }
        settled = settled.filter { $0.window.end > now.addingTimeInterval(-86_400) }
        updateKeepAwake()
        refreshButton()
    }

    // MARK: Runs

    /// Starts `s`'s `window` now: takes the radio and records, or watches (see `BroadcastRun`). Nothing happens while a
    /// run is going. A watch resuming after a broadcast carries on with what it had recorded in the window.
    func startRun(_ s: Schedule, window: DateInterval, early: Bool) {
        guard currentRun == nil, !isShutDown, let model else { return }
        let run = BroadcastRun(schedule: s, window: window, early: early, takenAt: now())
        if let paused = pausedWatches.removeValue(forKey: RunKey(scheduleID: s.id, window: window)) { run.carry(paused) }
        currentRun = run
        running = ActiveRun(scheduleID: s.id, window: window, kind: s.kind, startedEarly: early)
        radioTakenAt = run.takenAt
        if runActivity == nil {
            runActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "A schedule is recording")
        }
        refreshButton()
        runTask = Task { [weak self] in
            let timing = self?.timing ?? Timing()
            let identify: @MainActor (Double) async -> SignalIdentity? = { hz in await self?.identify(hz) }
            let setup = Task { await run.setUp(model, timing: timing, identify: identify) { self?.now() ?? Date() } }
            run.setupTask = setup
            await setup.value
            while run.endReason == nil {
                if Task.isCancelled { return }   // quitting
                try? await Task.sleep(for: .milliseconds(100))
            }
            if Task.isCancelled { return }
            let outcome = await run.tearDown(model, now: self?.now() ?? Date())
            self?.finish(run, outcome)
        }
    }

    /// Ends the current run for `reason`; its teardown follows on `runTask`.
    func endRun(_ reason: BroadcastRun.EndReason) {
        guard let run = currentRun, run.endReason == nil else { return }
        run.endReason = reason
        run.setupTask?.cancel()
    }

    private func finish(_ run: BroadcastRun, _ outcome: RunOutcome?) {
        guard currentRun === run, !isShutDown else { return }   // quitting logged it already
        if let outcome {
            record(outcome, for: run.schedule.id, at: now())
            lastOutcome = outcome
        }
        if run.endReason?.settles == true { settled.insert(RunKey(scheduleID: run.schedule.id, window: run.window)) }
        if run.endReason == .preempted, run.schedule.kind == .watch {
            pausedWatches[RunKey(scheduleID: run.schedule.id, window: run.window)] = run.recorded
        }
        if outcome == .missedNoRSP {
            model?.show(Banner(kind: .error, message: "A schedule was missed: the RSP wasn't connected."))
        }
        currentRun = nil
        running = nil
        radioTakenAt = nil
        endActivity(&runActivity)
        updateKeepAwake()
        refreshButton()
    }

    /// The ticker clicked while it pulses: starts that schedule's window now, not muted.
    func startEarly() {
        guard isOn, currentRun == nil, case .soon = buttonState, let soon = soonWindow else { return }
        startRun(soon.schedule, window: soon.window, early: true)
    }

    /// The left part clicked during a run: ends this run only.
    func stopRun() { endRun(.stoppedByYou) }

    // MARK: What the owner sees

    /// "SubFloor is recording a scheduled broadcast until 21:30" / "SubFloor is on a pirate watch until 02:00"; nil when idle.
    var busyMessage: String? {
        guard let r = running else { return nil }
        let until = Self.clock(r.window.end, localZone)
        return r.kind == .broadcast ? "SubFloor is recording a scheduled broadcast until \(until)"
                                    : "SubFloor is on a pirate watch until \(until)"
    }

    private func refreshButton() {
        let now = now()
        var state: ScheduleButtonState
        soonWindow = nil
        if !isOn {
            state = .off(waiting: schedules.filter(\.enabled).count)
        } else if let run = currentRun, let model {
            if run.schedule.kind == .watch, run.phase != .recording {
                state = .watching(Self.item(run.schedule, run.window), caught: run.files.count, until: run.window.end)
            } else {
                state = .recording(Self.item(run.schedule, run.window, frequencyHz: run.frequencyHz, mode: run.stationMode),
                                   elapsed: Int(run.elapsed(model)), marginDb: run.schedule.squelchMarginDb,
                                   until: run.window.end)
            }
        } else {
            let next = SchedulePlanner.next(schedules, after: now)
                .filter { !settled.contains(RunKey(scheduleID: $0.0.id, window: $0.1)) }
            if let (s, w) = next.first, w.start > now, w.start.timeIntervalSince(now) <= SchedulePlanner.pulseLead {
                soonWindow = (s, w)
                state = .soon(Self.item(s, w), secondsLeft: Int(w.start.timeIntervalSince(now).rounded(.up)))
            } else {
                state = .later(next.map { Self.item($0.0, $0.1) })
            }
        }
        if state != buttonState { buttonState = state }
    }

    /// A broadcast shows its scheduled start, frequency and mode; a watch its band, with no mode, or while it records
    /// a station (`mode` given) that station's frequency and mode.
    private static func item(_ s: Schedule, _ w: DateInterval, frequencyHz: Double? = nil,
                             mode: DemodMode? = nil) -> TickerItem {
        switch s.kind {
        case .broadcast:
            TickerItem(name: s.name, start: w.start.addingTimeInterval(ScheduleClock.broadcastLead),
                       frequencyHz: frequencyHz ?? s.frequenciesHz.first,
                       mode: BroadcastRun.demodMode(s.mode).rawValue)
        case .watch:
            if let mode, let frequencyHz {
                TickerItem(name: s.name, start: w.start, frequencyHz: frequencyHz, mode: mode.rawValue)
            } else {
                TickerItem(name: s.name, start: w.start, lowHz: s.lowHz, highHz: s.highHz, mode: nil)
            }
        }
    }

    private static func clock(_ date: Date, _ zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    // MARK: Keeping the Mac awake

    /// Test hook: the idle-sleep activity, held while the switch is on and a window is open or starts within 24 h.
    var isPreventingIdleSleep: Bool { idleActivity != nil }
    /// Test hook: the `.userInitiated` activity held during a run.
    var isHoldingRunActivity: Bool { runActivity != nil }

    private func updateKeepAwake() {
        let wanted = !isShutDown && SchedulePlanner.needsKeepAwake(schedules, on: isOn, now: now())
        if wanted, idleActivity == nil {
            idleActivity = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled,
                                                                 reason: "A schedule runs within 24 hours")
        } else if !wanted {
            endActivity(&idleActivity)
        }
    }

    private func endActivity(_ activity: inout NSObjectProtocol?) {
        guard let a = activity else { return }
        ProcessInfo.processInfo.endActivity(a)
        activity = nil
    }
}
