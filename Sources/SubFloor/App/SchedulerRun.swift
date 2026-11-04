import DSPCore
import Foundation
import Recording
import Scheduling

/// One broadcast run's radio work: it takes the radio, starts the RSP, measures the noise floor on each frequency,
/// picks the strongest, records with the squelch the margin above the floor, and gives the radio back.
///
/// `Scheduler` owns it: `setUp` runs as its own task (cancelled when the run is ended early, so a floor measurement
/// stops at once), `check` is called every tick, and `tearDown` once the run has an `endReason`.
@MainActor
final class BroadcastRun {
    enum Phase: Equatable { case taking, measuring, picking, recording, ending, ended }

    enum EndReason: Equatable {
        case windowEnd, stoppedByYou, noRSP, rspLost, lowDisk
        /// A watch making way for a broadcast: no outcome, and its window may start again.
        case preempted

        /// The window must not start again.
        var settles: Bool { self != .windowEnd && self != .preempted }
        /// Everything goes back, the tuning and running radio included. When the owner stopped the run, or the RSP or
        /// the disk did, only what the owner didn't touch goes back (`AppModel.restoreRadio(_:full:)`).
        var restoresFully: Bool { self == .windowEnd || self == .noRSP || self == .preempted }
    }

    /// What the radio should show after the run's own last change. The VFO and centre aren't checked while the floor
    /// is measured or the frequencies are compared (nil), since those move the VFO.
    @MainActor private struct Expected {
        var vfoHz: Double?
        var centerHz: Double?
        var mode: DemodMode
        var bandwidthHz: Double

        func matches(_ m: AppModel) -> Bool {
            func same(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.5 } ?? true }
            return same(vfoHz, m.vfoHz) && same(centerHz, m.centerHz) && m.mode == mode
                && abs(m.bandwidthHz - bandwidthHz) < 0.5
        }
    }

    let schedule: Schedule
    let window: DateInterval
    /// Started from the ticker: the live audio plays.
    let early: Bool
    let takenAt: Date
    private(set) var phase: Phase = .taking
    var endReason: EndReason?
    var setupTask: Task<Void, Never>?
    /// The owner's radio, put back at the end.
    private(set) var saved: AppModel.SavedRadio?
    /// The floor measured on each frequency (dBFS).
    private(set) var floors: [Double: Float] = [:]
    /// The level read on each frequency when there were several.
    private(set) var levels: [Double: Float] = [:]
    /// The frequency recorded, and its floor, once chosen.
    private(set) var frequencyHz: Double?
    private(set) var floorDb: Float?
    /// The files labelled with this schedule while the run was current, in order, and the length of each that ended.
    private(set) var files: [String] = []
    private var secondsByFile: [String: Double] = [:]
    private var rspLostBefore: Date?
    private var expected: Expected?
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

    private var live: Bool { endReason == nil && !Task.isCancelled }

    // MARK: Setup

    func setUp(_ m: AppModel, timing: Scheduler.Timing, now: @escaping () -> Date) async {
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
        guard live else { return }

        guard await m.startRSPForSchedule(timeout: timing.rspTimeout) else {
            if endReason == nil { endReason = .noRSP }
            return
        }
        guard live else { return }
        radioIsOurs = true

        let mode = Self.demodMode(schedule.mode)
        let frequencies = schedule.frequenciesHz
        m.setMode(mode)
        m.setBandwidth(mode.defaultBandwidth)
        m.squelchEnabled = true
        expected = Expected(mode: m.mode, bandwidthHz: m.bandwidthHz)

        // Several frequencies get 2 spots each, so up to 8 fit in the lead minute as nearly as they can.
        phase = .measuring
        for hz in frequencies {
            tune(m, to: hz)
            if let floor = await m.measureNoiseFloor(near: hz, spots: frequencies.count > 1 ? 2 : 3,
                                                     spotSeconds: timing.spotSeconds) {
                floors[hz] = floor
            }
            guard live else { return }
        }

        var chosen = frequencies[0]
        if frequencies.count > 1 {
            phase = .picking
            let onAir = window.start.addingTimeInterval(ScheduleClock.broadcastLead)
            while now() < onAir {
                guard live else { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            chosen = await strongest(m, of: frequencies, secondsEach: timing.pickSeconds / Double(frequencies.count))
            guard live else { return }
        }

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
        expected = Expected(vfoHz: m.vfoHz, centerHz: m.centerHz, mode: m.mode, bandwidthHz: m.bandwidthHz)
        phase = .recording
    }

    /// HamItUp as the agents' `auto` sets it (on below 30 MHz when reachable through it), then the tune.
    private func tune(_ m: AppModel, to hz: Double) {
        let up = SubFloorTools.upconverter(for: hz, setting: "auto", current: m.upconverter)
        if up.enabled != m.upconverter.enabled { m.setUpconverter(up.enabled) }
        m.tune(to: hz)
    }

    /// The frequency furthest above its floor among those at least the margin over it, else the first. Each is listened
    /// to for `secondsEach`: the first third lets the AGC and the channel filter settle, the rest is read.
    private func strongest(_ m: AppModel, of frequencies: [Double], secondsEach: Double) async -> Double {
        var best: (hz: Double, over: Float)?
        for hz in frequencies {
            tune(m, to: hz)
            try? await Task.sleep(for: .seconds(secondsEach / 3))
            var reads: [Float] = []
            let end = Date().addingTimeInterval(secondsEach * 2 / 3)
            repeat {
                guard live else { return frequencies[0] }
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
        if m.isRecording(.audio) || m.isRecording(.iq) { return .stoppedByYou }
        if !m.isRunning || m.sourceKind != .sdrplay { return .stoppedByYou }
        if let expected, !expected.matches(m) { return .stoppedByYou }
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

    /// Seconds recorded so far: the files that ended, and the one being written if it is this run's.
    func elapsed(_ m: AppModel) -> Double {
        var total = secondsByFile.values.reduce(0, +)
        if let s = m.recordingStatus[.audio], s.isRecording, s.isAuto, let file = s.url?.lastPathComponent,
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
                return !open && (reason != .windowEnd || files.allSatisfy { secondsByFile[$0] != nil })
            }
        }
        let outcome: RunOutcome? = switch reason {
        case .windowEnd:
            files.isEmpty ? .nothingHeard(watch: false)
                          : .recorded(seconds: files.compactMap { secondsByFile[$0] }.reduce(0, +), files: files.count)
        case .stoppedByYou: .stoppedByYou
        case .noRSP: .missedNoRSP
        case .rspLost: .rspLost(afterSeconds: now.timeIntervalSince(takenAt))
        case .lowDisk: .lowDisk
        case .preempted: nil
        }
        if let saved {
            m.restoreRadio(saved, full: reason.restoresFully)
        } else {
            m.sessionRadioOverride = nil
            m.scheduleMuted = false
        }
        phase = .ended
        return outcome
    }

    /// Polls the recorders until `done`, for at most `seconds`.
    private func settle(_ m: AppModel, upTo seconds: Double, until done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while true {
            m.refreshRecordingStatus()
            if done() || Date() >= end { return }
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return }
        }
    }

    private static func median(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s[s.count / 2]
    }
}
