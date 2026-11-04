import DSPCore
import Foundation
import Recording
import Scheduling
import SignalID

/// One run's radio work. It takes the radio and starts the RSP; a broadcast then measures the noise floor on each
/// frequency, picks the strongest and records with the squelch the margin above the floor; a watch watches its span
/// and records the stations that come on with voice (`SchedulerWatch.swift`). At the end it gives the radio back.
///
/// `Scheduler` owns it: `setUp` runs as its own task (cancelled when the run is ended early, so a floor measurement
/// stops at once; a watch's whole watching runs in it), `check` is called every tick, and `tearDown` once the run has
/// an `endReason`.
@MainActor
final class BroadcastRun {
    /// A watch is `watching` between stations and `recording` while one records.
    enum Phase: Equatable { case taking, measuring, picking, watching, recording, ending, ended }

    enum EndReason: Equatable {
        case windowEnd, noRSP, rspLost, lowDisk
        /// The owner ended the run without touching the radio: the ticker's stop, the switch off, or the running
        /// schedule deleted, switched off or retuned.
        case stoppedByYou
        /// The owner changed the radio mid-run: retuned, changed mode or bandwidth, recorded, or stopped it.
        case ownerChangedRadio
        /// A watch making way for a broadcast: no outcome, and its window may start again.
        case preempted

        /// The window must not start again.
        var settles: Bool { self != .windowEnd && self != .preempted }
        /// Everything goes back, the tuning and running radio included, unless the owner changed the radio or the RSP or
        /// the disk ended the run: then only what the owner didn't touch goes back (`AppModel.restoreRadio(_:full:)`),
        /// so the scheduler never fights the owner and doesn't restart a lost RSP.
        var restoresFully: Bool { self != .ownerChangedRadio && self != .rspLost && self != .lowDisk }
    }

    /// What the radio should show after the run's own last change (`note`).
    @MainActor private struct Expected {
        var vfoHz: Double
        var centerHz: Double
        var mode: DemodMode
        var bandwidthHz: Double

        /// `tuning` false: the VFO and centre aren't compared (a floor measurement is moving the VFO).
        func matches(_ m: AppModel, tuning: Bool) -> Bool {
            let tuned = abs(m.vfoHz - vfoHz) < 0.5 && abs(m.centerHz - centerHz) < 0.5
            return (!tuning || tuned) && m.mode == mode && abs(m.bandwidthHz - bandwidthHz) < 0.5
        }
    }

    let schedule: Schedule
    let window: DateInterval
    /// Started from the ticker: the live audio plays.
    let early: Bool
    let takenAt: Date
    var phase: Phase = .taking
    var endReason: EndReason?
    var setupTask: Task<Void, Never>?
    /// The owner's radio, put back at the end.
    private(set) var saved: AppModel.SavedRadio?
    /// The floor measured on each frequency (dBFS).
    private(set) var floors: [Double: Float] = [:]
    /// The level read on each frequency when there were several.
    private(set) var levels: [Double: Float] = [:]
    /// The frequency recorded, and its floor, once chosen; a watch's station while one records.
    var frequencyHz: Double?
    var floorDb: Float?
    /// A watch's floor for each mode it has measured (USB's stands for LSB too).
    var modeFloors: [DemodMode: Float] = [:]
    /// The mode a watch's station is recorded in, while one records.
    var stationMode: DemodMode?
    /// The files labelled with this schedule while the run was current, in order, and the length of each that ended.
    /// A watch resumed after a broadcast starts with what it recorded before (`carry`).
    private(set) var files: [String] = []
    private var secondsByFile: [String: Double] = [:]
    private var rspLostBefore: Date?
    private var expected: Expected?
    /// A floor measurement is in flight: it moves the VFO, so only the mode and bandwidth are compared meanwhile.
    var movingVFO = false
    /// Set once the radio runs on the RSP for the run: from then on a stopped radio or a manual recording is the
    /// owner's doing.
    private var radioIsOurs = false

    init(schedule: Schedule, window: DateInterval, early: Bool, takenAt: Date) {
        self.schedule = schedule
        self.window = window
        self.early = early
        self.takenAt = takenAt
    }

    static func demodMode(_ mode: ScheduleMode) -> DemodMode {
        switch mode {
        case .am, .auto: .am
        case .usb: .usb
        case .lsb: .lsb
        }
    }

    var live: Bool { endReason == nil && !Task.isCancelled }

    /// What a run has recorded: a watch making way for a broadcast hands it to the run that resumes its window.
    struct Recorded {
        var files: [String]
        var secondsByFile: [String: Double]
    }

    var recorded: Recorded { Recorded(files: files, secondsByFile: secondsByFile) }

    func carry(_ r: Recorded) {
        files = r.files + files.filter { !r.files.contains($0) }
        secondsByFile.merge(r.secondsByFile) { mine, _ in mine }
    }

    // MARK: Setup

    /// Takes the radio, then runs the schedule's body: a broadcast's floor, pick and recording, or a watch's watching
    /// (which lasts until the run is ended). `identify` is Signal ID for a watch's candidates.
    func setUp(_ m: AppModel, timing: Scheduler.Timing, identify: @escaping @MainActor (Double) async -> SignalIdentity?,
               now: @escaping () -> Date) async {
        guard await takeRadio(m, timing: timing) else { return }
        switch schedule.kind {
        case .broadcast: await recordBroadcast(m, timing: timing, now: now)
        case .watch: await watch(m, timing: timing, identify: identify)
        }
    }

    /// Saves the owner's radio, mutes, pauses Auto, ends a manual recording and starts the RSP. False when the run
    /// ended meanwhile or there is no RSP (`endReason` says which).
    private func takeRadio(_ m: AppModel, timing: Scheduler.Timing) async -> Bool {
        let owner = m.saveRadio()
        saved = owner
        m.sessionRadioOverride = owner
        rspLostBefore = m.rspLostAt
        if !early { m.scheduleMuted = true }
        // The owner's Auto is paused for the run; the restore puts it, and an agent's limit on it, back.
        m.autoRecordEnabled = false
        // A manual recording, the owner's or an agent's, ends (its file is kept).
        m.stopRecording(.audio)
        m.stopRecording(.iq)
        await settle(m, upTo: 5) { !m.isRecording(.audio) && !m.isRecording(.iq) }
        guard live else { return false }

        guard await m.startRSPForSchedule(timeout: timing.rspTimeout) else {
            if endReason == nil { endReason = .noRSP }
            return false
        }
        guard live else { return false }
        radioIsOurs = true
        return true
    }

    private func recordBroadcast(_ m: AppModel, timing: Scheduler.Timing, now: () -> Date) async {
        let mode = Self.demodMode(schedule.mode)
        let frequencies = schedule.frequenciesHz
        m.setMode(mode)
        m.setBandwidth(mode.defaultBandwidth)
        m.squelchEnabled = true
        note(m)

        // Several frequencies get 2 spots each, so up to 8 fit in the lead minute as nearly as they can. Before each
        // of its own tunes the run checks the owner hasn't changed the radio, so it never retunes over them.
        phase = .measuring
        for hz in frequencies {
            guard proceed(m) else { return }
            tune(m, to: hz)
            movingVFO = true
            let floor = await m.measureNoiseFloor(near: hz, spots: frequencies.count > 1 ? 2 : 3,
                                                  spotSeconds: timing.spotSeconds)
            movingVFO = false
            guard live else { return }
            if let floor { floors[hz] = floor }
            note(m)   // the measurement puts the VFO back on `hz`
        }

        var chosen = frequencies[0]
        if frequencies.count > 1 {
            phase = .picking
            let onAir = window.start.addingTimeInterval(ScheduleClock.broadcastLead)
            while now() < onAir {
                guard proceed(m) else { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let strongest = await strongest(m, of: frequencies,
                                                  secondsEach: timing.pickSeconds / Double(frequencies.count)) else { return }
            chosen = strongest
        }

        guard proceed(m) else { return }
        tune(m, to: chosen)
        frequencyHz = chosen
        // A frequency with no quiet spot near it borrows the others' floor; with none at all the squelch stays as set.
        floorDb = floors[chosen] ?? Self.median(Array(floors.values))
        if let floorDb { m.squelchDb = floorDb + schedule.squelchMarginDb }
        let ownerTiming = m.recording.autoTiming
        m.scheduleRecording = AppModel.ScheduleRecording(
            tag: schedule.tag,
            timing: AutoRecordTiming(startAfter: ownerTiming.startAfter, stopAfter: timing.quietCloseSeconds,
                                     keepGapsUpTo: ownerTiming.keepGapsUpTo))
        note(m)
        phase = .recording
    }

    /// The radio as the run has just left it.
    func note(_ m: AppModel) {
        expected = Expected(vfoHz: m.vfoHz, centerHz: m.centerHz, mode: m.mode, bandwidthHz: m.bandwidthHz)
    }

    /// False when the run must stop setting up: it was ended, or the owner (or the RSP) has changed the radio since
    /// the run's last change, which then ends it.
    func proceed(_ m: AppModel) -> Bool {
        guard live else { return false }
        if let reason = check(m) {
            endReason = reason
            return false
        }
        return true
    }

    /// HamItUp as the agents' `auto` sets it (on below 30 MHz when reachable through it), then the tune.
    func tune(_ m: AppModel, to hz: Double) {
        let up = SubFloorTools.upconverter(for: hz, setting: "auto", current: m.upconverter)
        if up.enabled != m.upconverter.enabled { m.setUpconverter(up.enabled) }
        m.tune(to: hz)
    }

    /// The frequency furthest above its floor among those at least the margin over it, else the first; nil when the run
    /// ended meanwhile. Each is listened to for `secondsEach`: the first third lets the AGC and the channel filter
    /// settle, the rest is read. The owner's changes are watched throughout (a hop is the run's own `note`d tune).
    private func strongest(_ m: AppModel, of frequencies: [Double], secondsEach: Double) async -> Double? {
        var best: (hz: Double, over: Float)?
        for hz in frequencies {
            guard proceed(m) else { return nil }
            tune(m, to: hz)
            note(m)
            try? await Task.sleep(for: .seconds(secondsEach / 3))
            var reads: [Float] = []
            let end = Date().addingTimeInterval(secondsEach * 2 / 3)
            repeat {
                guard proceed(m) else { return nil }
                reads.append(m.engine.stats.withLock { $0.signalDb })
                try? await Task.sleep(for: .milliseconds(100))
            } while Date() < end
            guard let level = Self.median(reads) else { continue }
            levels[hz] = level
            guard let floor = floors[hz] else { continue }
            let over = level - floor
            if over >= schedule.squelchMarginDb, over > (best?.over ?? -.infinity) { best = (hz, over) }
        }
        return best?.hz ?? frequencies[0]
    }

    // MARK: During the run

    /// Why the run must end now, if it must: the RSP was lost, or the owner retuned, changed mode, stopped the radio
    /// or started a recording of their own.
    func check(_ m: AppModel) -> EndReason? {
        m.refreshRecordingStatus()
        if m.rspLostAt != rspLostBefore { return .rspLost }
        guard radioIsOurs else { return nil }
        if m.isRecording(.audio) || m.isRecording(.iq) { return .ownerChangedRadio }
        if !m.isRunning || m.sourceKind != .sdrplay { return .ownerChangedRadio }
        if let expected, !expected.matches(m, tuning: !movingVFO) { return .ownerChangedRadio }
        return nil
    }

    /// Notes the files labelled with this schedule and the lengths logged for them.
    func logged(_ entries: [RecordingLogEntry]) {
        for entry in entries {
            switch entry {
            case .scheduled(let file, let id, _) where id == schedule.id:
                if !files.contains(file) { files.append(file) }
            case .recording(let file, _, let seconds, _, _, _) where files.contains(file):
                secondsByFile[file] = seconds
            default:
                break
            }
        }
    }

    /// Seconds recorded so far: the files whose length is logged, and the latest one (being written, or closed and
    /// not logged yet) if it is this run's.
    func elapsed(_ m: AppModel) -> Double {
        var total = secondsByFile.values.reduce(0, +)
        if let s = m.recordingStatus[.audio], let file = s.url?.lastPathComponent,
           files.contains(file), secondsByFile[file] == nil {
            total += s.duration
        }
        return total
    }

    // MARK: Teardown

    /// Closes the recording, waits (at most 5 s) for it to be logged, gives the radio back and returns the outcome
    /// (nil for a watch making way).
    func tearDown(_ m: AppModel, now: Date) async -> RunOutcome? {
        phase = .ending
        let reason = endReason ?? .windowEnd
        // Before the restore: a mode or VFO change would cut the open recording anyway.
        m.scheduleRecording = nil
        if radioIsOurs {
            await settle(m, upTo: 5) {
                let open = m.engine.audioRecorder.status.isRecording && m.engine.audioRecorder.status.isAuto
                // At the window's end (and for a watch resuming later) the lengths are waited for.
                let lengths = reason == .windowEnd || reason == .preempted
                return !open && (!lengths || files.allSatisfy { secondsByFile[$0] != nil })
            }
        }
        let outcome = outcome(for: reason, now: now, recordedSeconds: files.compactMap { secondsByFile[$0] }.reduce(0, +))
        // Quitting meanwhile: the session already holds the owner's radio, and nothing may start the radio again.
        guard !m.isShutDown else { return outcome }
        if let saved {
            m.restoreRadio(saved, full: reason.restoresFully)
        } else {
            m.sessionRadioOverride = nil
            m.scheduleMuted = false
        }
        phase = .ended
        return outcome
    }

    /// The outcome of a run cut short by quitting: what it has recorded so far, or what ended it.
    func outcomeAtQuit(_ m: AppModel, now: Date) -> RunOutcome? {
        outcome(for: endReason ?? .windowEnd, now: now, recordedSeconds: elapsed(m))
    }

    private func outcome(for reason: EndReason, now: Date, recordedSeconds: Double) -> RunOutcome? {
        switch reason {
        case .windowEnd:
            files.isEmpty ? .nothingHeard(watch: schedule.kind == .watch)
                          : .recorded(seconds: recordedSeconds, files: files.count)
        case .stoppedByYou, .ownerChangedRadio: .stoppedByYou
        case .noRSP: .missedNoRSP
        case .rspLost: .rspLost(afterSeconds: now.timeIntervalSince(takenAt))
        case .lowDisk: .lowDisk
        case .preempted: nil
        }
    }

    /// Polls the recorders until `done`, for at most `seconds`.
    func settle(_ m: AppModel, upTo seconds: Double, until done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while true {
            m.refreshRecordingStatus()
            if done() || Date() >= end { return }
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return }
        }
    }

    static func median(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s[s.count / 2]
    }
}
