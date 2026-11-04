import DSPCore
import Foundation
import Scheduling
import SignalID
import SubFloorCore

/// Which of a watch's candidates are voice, by Signal ID's answer.
enum VoiceCheck {
    /// The mode to record a watch's candidate in: am → .am, usb → .usb, lsb → .lsb, fm with a .voice envelope → .nfm;
    /// anything else (carrier, fsk, psk, mfsk, ofdm, ook, noise, unknown, fm without voice) → nil.
    ///
    /// FM's voice shows in its demodulated audio (`audioEnvelope`); its RF envelope is steady, but either counts.
    static func recordMode(_ id: SignalIdentity) -> DemodMode? {
        let m = id.measurement
        switch m.family {
        case .am: return .am
        case .usb: return .usb
        case .lsb: return .lsb
        case .fm: return m.audioEnvelope == .voice || m.envelope == .voice ? .nfm : nil
        case .noise, .carrier, .wfm, .ook, .fsk, .mfsk, .psk, .ofdm, .unknown: return nil
        }
    }
}

/// A pirate watch's body (spec: Pirate watches): the capture centred on the span, a floor per mode, then once a second
/// the span's spectrum through `WatchDetector`. A candidate Signal ID calls voice is recorded with the owner's Auto
/// timing until it ends; then the watch goes back to watching. One station at a time: while one records the detector
/// isn't fed. Every change the watch makes to the radio is `note`d, so an owner's change still ends the run.
///
/// Its durations (the hold, rejections, the refloor and the give-up) run on monotonic time, which a change of the
/// Mac's clock doesn't move: `ContinuousClock` for its own deadlines, and `monotonicNow` for the detector's dates.
extension BroadcastRun {
    /// How long after Auto's start after a station's squelch may stay shut before the watch gives up on it.
    static let squelchWaitSeconds: Double = 5
    /// An SSB station's suppressed carrier lies about this far beyond the edge of its visible voice.
    static let ssbCarrierGapHz: Double = 300

    /// Monotonic time as a `Date` (the system uptime), for `WatchDetector`'s `at:` and `until:`.
    static var monotonicNow: Date { Date(timeIntervalSinceReferenceDate: ProcessInfo.processInfo.systemUptime) }

    func watch(_ m: AppModel, timing: Scheduler.Timing,
               identify: @MainActor (Double) async -> SignalIdentity?) async {
        guard let low = schedule.lowHz, let high = schedule.highHz else { return }
        let middle = (low + high) / 2
        m.squelchEnabled = true
        tune(m, to: middle)
        note(m)
        // The span inside the capture's usable part: all of it, unless the capture is narrowed by decimation.
        let usable = m.sampleRate * TuningPlanner.usableFraction
        let from = max(low, m.centerHz - usable), to = min(high, m.centerHz + usable)
        guard to > from else { return }
        var detector = WatchDetector(lowHz: from, highHz: to)

        phase = .measuring
        guard await measureFloors(m, near: middle, timing: timing) else { return }
        var refloorAt = ContinuousClock.now + .seconds(timing.watchRefloorSeconds)
        phase = .watching
        while proceed(m) {
            if ContinuousClock.now >= refloorAt {
                phase = .measuring
                guard await measureFloors(m, near: middle, timing: timing) else { return }
                refloorAt = ContinuousClock.now + .seconds(timing.watchRefloorSeconds)
                phase = .watching
            }
            guard let snapshot = await m.currentSpectrumSnapshot(), proceed(m) else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            let slice = SpectrumSlice(snapshot, from: from, to: to, points: max(1, Int((to - from) / 250)))
            guard let c = detector.feed(levels: slice.levels, fromHz: from, binHz: slice.binHz,
                                          at: Self.monotonicNow).first else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            let answer = await identify(c.hz)
            guard proceed(m) else { return }
            guard let answer, let mode = VoiceCheck.recordMode(answer) else {
                // No answer (the radio was busy): tried again shortly. Not voice: left alone for `rejectSeconds`.
                let seconds = answer == nil ? WatchDetector.holdSeconds * 2 : timing.rejectSeconds
                detector.reject(c.hz, until: Self.monotonicNow.addingTimeInterval(seconds))
                continue
            }
            let heard = await record(c, in: mode, m, timing: timing)
            guard live else { return }
            // A station that was heard may come back soon as a new transmission; one that never opened the squelch
            // is left alone for `rejectSeconds`.
            let seconds = heard ? WatchDetector.holdSeconds * 2 : timing.rejectSeconds
            detector.reject(c.hz, until: Self.monotonicNow.addingTimeInterval(seconds))
            m.setVFO(middle)
            note(m)
            phase = .watching
        }
    }

    /// Where the VFO goes for a station: an SSB signal's dial is its suppressed carrier, `ssbCarrierGapHz` below its
    /// low edge (USB) or above its high edge (LSB), so the passband covers the voice; anything else is tuned at its
    /// centre.
    static func dial(for c: WatchCandidate, mode: DemodMode) -> Double {
        switch mode {
        case .usb: c.hz - c.widthHz / 2 - ssbCarrierGapHz
        case .lsb: c.hz + c.widthHz / 2 + ssbCarrierGapHz
        default: c.hz
        }
    }

    /// USB's floor (which stands for LSB) and AM's, on 2 quiet spots each near `hz`; the VFO ends on `hz`. False when
    /// the run ended meanwhile.
    private func measureFloors(_ m: AppModel, near hz: Double, timing: Scheduler.Timing) async -> Bool {
        for mode in [DemodMode.usb, .am] {
            guard await measureFloor(m, in: mode, near: hz, timing: timing) else { return false }
        }
        return true
    }

    /// The floor in `mode` at its default bandwidth, with the VFO on `hz` (where the measurement puts it back); a spot
    /// with no quiet place near it keeps the floor it had. False when the run ended meanwhile, or the owner changed
    /// the radio (which ends it).
    private func measureFloor(_ m: AppModel, in mode: DemodMode, near hz: Double, timing: Scheduler.Timing) async -> Bool {
        guard proceed(m) else { return false }
        m.setMode(mode)
        m.setBandwidth(mode.defaultBandwidth)
        m.setVFO(hz)
        note(m)
        movingVFO = true
        let floor = await m.measureNoiseFloor(near: hz, spots: 2, spotSeconds: timing.spotSeconds)
        movingVFO = false
        guard proceed(m) else { return false }
        if let floor { modeFloors[mode] = floor }
        return true
    }

    /// Records the station `c` in `mode`, with the squelch that mode's floor plus the margin and the owner's Auto timing
    /// as it is, and waits for its recording to end (the squelch shut for Auto's stop after). The phase is `recording`
    /// only once the recorder records. True when a recording was made; false when none opened within Auto's start
    /// after plus `squelchWaitSeconds`, there is no floor for the mode, or the run ended (whose teardown then closes
    /// the recording).
    private func record(_ c: WatchCandidate, in mode: DemodMode, _ m: AppModel, timing: Scheduler.Timing) async -> Bool {
        let hz = Self.dial(for: c, mode: mode)
        guard proceed(m) else { return false }
        m.setMode(mode)
        m.setBandwidth(mode.defaultBandwidth)
        note(m)
        // NFM's floor is measured the first time an FM voice is found, near it.
        if mode == .nfm, modeFloors[.nfm] == nil {
            guard await measureFloor(m, in: .nfm, near: hz, timing: timing) else { return false }
        }
        guard let floor = modeFloors[mode == .lsb ? .usb : mode], proceed(m) else { return false }
        m.setVFO(hz)
        m.squelchDb = floor + schedule.squelchMarginDb
        frequencyHz = hz
        stationMode = mode
        floorDb = floor
        let auto = m.recording.autoTiming
        m.scheduleRecording = AppModel.ScheduleRecording(tag: schedule.tag, timing: auto)
        note(m)

        let giveUp = ContinuousClock.now + .seconds(auto.startAfter + Self.squelchWaitSeconds)
        var opened = false
        while proceed(m) {
            let status = m.engine.audioRecorder.status
            if status.isRecording && status.isAuto {
                opened = true
                phase = .recording
            } else if opened || ContinuousClock.now >= giveUp {
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard live else { return opened }
        m.scheduleRecording = nil
        frequencyHz = nil
        stationMode = nil
        floorDb = nil
        return opened
    }
}
