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
extension BroadcastRun {
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
        var refloorAt = Date().addingTimeInterval(timing.watchRefloorSeconds)
        phase = .watching
        while proceed(m) {
            if Date() >= refloorAt {
                phase = .measuring
                guard await measureFloors(m, near: middle, timing: timing) else { return }
                refloorAt = Date().addingTimeInterval(timing.watchRefloorSeconds)
                phase = .watching
            }
            guard let snapshot = await m.currentSpectrumSnapshot(), proceed(m) else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            let slice = SpectrumSlice(snapshot, from: from, to: to, points: max(1, Int((to - from) / 250)))
            guard let c = detector.feed(levels: slice.levels, fromHz: from, binHz: slice.binHz, at: Date()).first else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            let answer = await identify(c.hz)
            guard proceed(m) else { return }
            guard let answer, let mode = VoiceCheck.recordMode(answer) else {
                // No answer (the radio was busy): tried again shortly. Not voice: left alone for `rejectSeconds`.
                let seconds = answer == nil ? WatchDetector.holdSeconds * 2 : timing.rejectSeconds
                detector.reject(c.hz, until: Date().addingTimeInterval(seconds))
                continue
            }
            let heard = await record(c, in: mode, m, timing: timing)
            guard live else { return }
            // A station that was heard may come back soon as a new transmission; one that never opened the squelch
            // is left alone for `rejectSeconds`.
            detector.reject(c.hz, until: Date().addingTimeInterval(heard ? WatchDetector.holdSeconds * 2 : timing.rejectSeconds))
            m.setVFO(middle)
            note(m)
            phase = .watching
        }
    }

    /// Where the VFO goes for a station: an SSB signal's dial is at its low (USB) or high (LSB) edge, so the passband
    /// covers it; anything else is tuned at its centre.
    static func dial(for c: WatchCandidate, mode: DemodMode) -> Double {
        switch mode {
        case .usb: c.hz - c.widthHz / 2
        case .lsb: c.hz + c.widthHz / 2
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

    /// The floor in `mode` at its default bandwidth; a spot with no quiet place near it keeps the floor it had.
    private func measureFloor(_ m: AppModel, in mode: DemodMode, near hz: Double, timing: Scheduler.Timing) async -> Bool {
        guard proceed(m) else { return false }
        m.setMode(mode)
        m.setBandwidth(mode.defaultBandwidth)
        note(m)
        movingVFO = true
        let floor = await m.measureNoiseFloor(near: hz, spots: 2, spotSeconds: timing.spotSeconds)
        movingVFO = false
        guard live else { return false }
        if let floor { modeFloors[mode] = floor }
        note(m)
        return true
    }

    /// Records the station `c` in `mode`, with the squelch that mode's floor plus the margin and the owner's Auto timing
    /// as it is, and waits for its recording to end (the squelch shut for Auto's stop after). True when a recording was
    /// made; false when the squelch didn't open within Auto's start after and stop after, there is no floor for the
    /// mode, or the run ended (whose teardown then closes the recording).
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
        phase = .recording

        let giveUp = Date().addingTimeInterval(auto.startAfter + auto.stopAfter)
        var opened = false
        while proceed(m) {
            let status = m.engine.audioRecorder.status
            if status.isRecording && status.isAuto {
                opened = true
            } else if opened || Date() >= giveUp {
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
