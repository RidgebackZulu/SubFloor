import DSPCore
import Foundation
import SignalID
import SubFloorCore
import Transcription

/// A longer read `get_cursor` started whose first answer it returned: the first answer, for the calls that come
/// while it runs.
@MainActor
final class CursorRead {
    var first: SignalIdentity?
}

/// Signal ID for agents: `identify_signal`, `identify_signals`, and the `signal` of `get_cursor`'s cursors.
extension SubFloorTools {
    static var signalTools: [SubFloorTool] {
        [
            SubFloorTool("identify_signal", title: "Identify a signal", readOnly: true, description: """
                What kind of signal is at frequency (display Hz, inside the capture), from the last few seconds of \
                IQ: its family and parameters (bandwidth, SNR, symbol rate, shift, tones...), a name only when \
                SubFloor is at least 70% sure (RTTY, FT8, WSPR, DMR...), up to 3 other candidates, and whether a \
                running decoder confirmed it. It never guesses: below 70% you get the family and its parameters. \
                bandwidth_hz is the signal's width if you know it. Never retunes. Slow signals (under 50 Hz wide, \
                keyed under 10 WPM, WSPR, FT8 slots) are read again over up to 16 s: that is in this answer. \
                Returns {hz, label, family, name, confidence, parameters, alternatives, tune, ...}.
                """, properties: [
                    "frequency": .frequencySchema("Display Hz, or a string like \"7.074 MHz\". Inside the capture."),
                    "bandwidth_hz": .schema("number", "The signal's width in Hz, if known."),
                ], required: ["frequency"]) { t, args, _ in try await t.identifySignal(args) },

            SubFloorTool("identify_signals", title: "Identify every signal in a range", readOnly: false, locksRadio: false, description: """
                Find every signal from from_hz to to_hz (display Hz) and identify each. Inside the current capture \
                (get_status: center_hz ± span_hz/2) it does not touch the radio. Across a wider range it steps the \
                radio across it, one capture at a time, dwelling about 3.5 s on each so the IQ fills (at most 60 \
                pieces), holds the radio lock, and puts the VFO, mode, bandwidth and HamItUp back afterwards. The \
                owner hears each step. It refuses while the owner is recording or Auto is on (a retune would split \
                the file), and it stops early, without undoing, if the owner retunes. min_snr_db (default 10) is \
                how far a line stands over the floor; max_signals (default 40, up to 200). Log what it finds with \
                add_bookmark. Returns {signals: [{hz, level_dbfs, identity}], pieces, restored, stopped_early?}.
                """, properties: [
                    "from_hz": .frequencySchema("Lower edge, display Hz."),
                    "to_hz": .frequencySchema("Upper edge, display Hz."),
                    "min_snr_db": .schema("number", "A signal must stand this many dB over the floor (default 10)."),
                    "max_signals": .schema("integer", "At most this many signals (default 40, up to 200)."),
                ], required: ["from_hz", "to_hz"]) { t, args, client in try await t.identifySignals(args, client: client) },
        ]
    }

    // MARK: JSON

    /// Two decimals.
    private static func round2(_ x: Double) -> JSONValue { .num((x * 100).rounded() / 100) }

    /// The identity as agents read it. `signalHz` is where the signal is (its centre when it has an extent, else the
    /// frequency asked about); `includeHz` leaves it out where the caller shows it beside.
    func identityJSON(_ id: SignalIdentity, signalHz: Double, includeHz: Bool = true) -> [String: JSONValue] {
        let m = id.measurement
        var out: [String: JSONValue] = [
            "label": .string(id.label),
            "family": .string(id.summary["Family"] ?? "Unknown"),
            "name": id.best.map { .string($0.name) }.orNull,
            "confidence": id.best.map { Self.round2(Double($0.confidence)) }.orNull,
            "family_confidence": Self.round2(Double(m.familyConfidence)),
            "confirmed_by_decode": .bool(id.confirmedByDecode),
            "needs_longer_read": .bool(id.needsLongerRead),
            "note": id.note.map { .string($0) }.orNull,
            "parameters": Self.parametersJSON(m),
            "alternatives": .array(id.alternatives.map {
                .object(["name": .string($0.name), "confidence": Self.round2(Double($0.confidence))])
            }),
        ]
        if includeHz { out["hz"] = .hz(signalHz) }
        if let best = id.best { out["evidence"] = .array(best.evidence.map { .string($0) }) }
        // What to give `tune` or `add_bookmark` to listen to it (the card's Tune does the same).
        if SignalIDText.canBookmark(id) {
            let plan = SignalIDTuning.plan(for: id, atHz: signalHz)
            if let demod = plan.demod {
                out["tune"] = .object(["frequency": .hz(plan.vfoHz), "mode": .string(demod.rawValue),
                                       "bandwidth_hz": plan.bandwidthHz.map { .hz($0) }.orNull])
            }
        }
        return out
    }

    private static func parametersJSON(_ m: SignalMeasurement) -> JSONValue {
        var p: [String: JSONValue] = [:]
        if m.occupiedBandwidthHz > 0 {
            p["bandwidth_hz"] = .hz(m.occupiedBandwidthHz)
            p["bandwidth_6db_hz"] = .hz(m.bandwidth6dBHz)
            p["snr_db"] = .db(Float(m.snrDb))
            p["envelope"] = .string(m.envelope.rawValue)
        }
        func put(_ key: String, _ value: Double?) { if let value { p[key] = round2(value) } }
        put("symbol_rate_bd", m.symbolRate)
        put("shift_hz", m.fskShiftHz)
        put("tones", m.toneCount.map(Double.init))
        put("tone_spacing_hz", m.toneSpacingHz)
        put("psk_order", m.pskOrder.map(Double.init))
        put("carrier_spacing_hz", m.ofdmSpacingHz)
        put("deviation_hz", m.fmDeviationHz)
        put("wpm", m.cwWPM)
        put("burst_period_s", m.burstPeriodSeconds)
        put("burst_duty", m.burstDuty)
        put("period_s", m.modulationPeriodSeconds)
        if !m.subcarriersHz.isEmpty { p["subcarriers_hz"] = .array(m.subcarriersHz.map { .hz($0) }) }
        if let audio = m.audioEnvelope { p["audio"] = .string(audio.rawValue) }
        if m.seconds > 0 { p["read_seconds"] = .num((m.seconds * 10).rounded() / 10) }
        if !m.notes.isEmpty { p["notes"] = .array(m.notes.map { .string($0) }) }
        return .object(p)
    }

    /// Where the signal an identity describes is: the centre of its band, else the frequency asked about.
    func signalHz(_ id: SignalIdentity, askedHz: Double) -> Double {
        id.measurement.occupiedBandwidthHz > 0 ? model.signalID.tuning.current.centerHz + id.measurement.offsetHz : askedHz
    }

    // MARK: identify_signal

    func identifySignal(_ args: ToolArguments) async throws -> [String: JSONValue] {
        let m = model
        try requireRunning()
        let hz = try args.required("frequency", args.frequency)
        let bandwidth = try args.double("bandwidth_hz", in: 1...max(m.sampleRate, 2))
        guard inCapture(hz) else {
            let short = FrequencyFormatter.short
            throw ToolError("\(short(hz)) is outside the capture (\(short(m.centerHz - m.sampleRate / 2)) – \(short(m.centerHz + m.sampleRate / 2))). Tune within it first (about \(short(hz))), or use identify_signals across a wider range.")
        }
        let id = await m.signalID.identify(atHz: hz, bandwidthHz: bandwidth)
        try Task.checkCancellation()
        guard let id else {
            throw ToolError("Nothing to read yet: the radio was just started or retuned, or the owner retuned meanwhile. Try again in a second.")
        }
        return identityJSON(id, signalHz: signalHz(id, askedHz: hz))
    }

    /// Whether `hz` lies in the capture the IQ ring holds.
    func inCapture(_ hz: Double) -> Bool { abs(hz - model.centerHz) <= model.sampleRate / 2 }

    // MARK: get_cursor

    /// A mouse position older than this many seconds is not identified.
    static let mouseIdentifySeconds = 30.0

    /// `signal` (and `signal_note` when there is none) for a cursor at `hz`, added to `cursor`. A cursor `ageSeconds`
    /// old is identified only if it is at most `mouseIdentifySeconds`.
    func withSignal(_ cursor: [String: JSONValue], atHz hz: Double, ageSeconds: Double? = nil) async -> JSONValue {
        var out = cursor
        let (signal, note) = await cursorSignal(atHz: hz, ageSeconds: ageSeconds)
        out["signal"] = signal.orNull
        if signal == nil { out["signal_note"] = .string(note ?? "No signal data.") }
        return .object(out)
    }

    private func cursorSignal(atHz hz: Double, ageSeconds: Double?) async -> (JSONValue?, String?) {
        let short = FrequencyFormatter.short
        guard model.isRunning else { return (nil, "The radio is stopped: nothing to read.") }
        if let age = ageSeconds, age > Self.mouseIdentifySeconds {
            return (nil, "The pointer last rested on the spectrum \(Int(age.rounded())) s ago, more than \(Int(Self.mouseIdentifySeconds)) s: not identified. Ask the owner to point at the signal, or call identify_signal with its frequency.")
        }
        guard inCapture(hz) else {
            return (nil, "\(short(hz)) is outside the current capture: tune there first, then call identify_signal.")
        }
        guard let id = await quickIdentity(atHz: hz) else {
            return (nil, "Nothing to read yet: the radio was just started or retuned. Try again in a second.")
        }
        return (.object(identityJSON(id, signalHz: signalHz(id, askedHz: hz))), nil)
    }

    /// The identity at `hz` without waiting for the longer read: when the first pass asks for one, its answer
    /// (`needsLongerRead`) is returned at once and the longer read finishes in the background, into the service's
    /// cache for the next call. Calls that come while one runs get the first answer again, not another read.
    func quickIdentity(atHz hz: Double) async -> SignalIdentity? {
        let key = Int((hz / 25).rounded())
        if let running = cursorReads[key], let first = running.first { return first }
        let service = model.signalID
        let gate = FirstAnswer()
        let read = CursorRead()
        Task { @MainActor [weak self] in
            let answer = await service.identify(atHz: hz) { first in
                read.first = first
                self?.cursorReads[key] = read
                gate.resolve(first)
            }
            gate.resolve(answer)
            if let self, self.cursorReads[key] === read { self.cursorReads[key] = nil }
        }
        return await gate.wait()
    }

    /// The first of several answers: the waiter gets whichever is resolved first.
    @MainActor private final class FirstAnswer {
        private var continuation: CheckedContinuation<SignalIdentity?, Never>?
        private var answered = false
        private var value: SignalIdentity?

        func wait() async -> SignalIdentity? {
            if answered { return value }
            return await withCheckedContinuation { continuation = $0 }
        }

        func resolve(_ answer: SignalIdentity?) {
            guard !answered else { return }
            answered = true
            value = answer
            continuation?.resume(returning: answer)
            continuation = nil
        }
    }

    // MARK: identify_signals

    /// The most pieces a scan steps through (about 3.5 s each).
    static let scanMaxPieces = 60
    /// A scan's wait for the IQ ring: the first pass reads this much, and the 50 ms it drops after a retune.
    static let scanRingSeconds = SignalIDService.firstSeconds + SignalIDService.settleSeconds + 0.05
    /// The most a scan lists as its own notes.
    private static let maxScanNotes = 10

    /// What a scan watches for, to see the owner's hand: the tuning it left, and whether the radio runs.
    struct ScanTuning: Equatable {
        var running: Bool
        var vfoHz: Double
        var centerHz: Double
        var mode: DemodMode
        var bandwidthHz: Double
        var hamitup: Bool
        var loHz: Double
    }

    func scanTuning() -> ScanTuning {
        let m = model
        return ScanTuning(running: m.isRunning, vfoHz: m.vfoHz, centerHz: m.centerHz, mode: m.mode,
                          bandwidthHz: m.bandwidthHz, hamitup: m.upconverter.enabled, loHz: m.upconverter.loHz)
    }

    /// How far a scan has gone with the radio: whether it moved it, and whether the owner took it over.
    private final class ScanRun {
        var stepped = false
        var abandoned = false
    }

    /// Why the owner has taken the radio from a scan that left it as `expected`, or nil. A scan inside the capture
    /// (`strict` false) minds only a change of the capture itself: the VFO is the owner's.
    private func ownerChange(from expected: ScanTuning, strict: Bool) -> String? {
        let now = scanTuning()
        guard now != expected else { return nil }
        if !now.running { return "The radio was stopped by the owner." }
        let short = FrequencyFormatter.short
        if strict || now.centerHz != expected.centerHz || now.hamitup != expected.hamitup || now.loHz != expected.loHz {
            if now.vfoHz != expected.vfoHz { return "The owner retuned to \(short(now.vfoHz))." }
            if now.mode != expected.mode { return "The owner changed the mode to \(now.mode.label)." }
            if now.bandwidthHz != expected.bandwidthHz { return "The owner changed the bandwidth." }
            return "The owner changed the capture or HamItUp."
        }
        return nil
    }

    /// The tool: validates, then scans. Inside the capture it doesn't touch the radio and takes no lock; across a
    /// wider range it holds the radio lock for the whole scan, so no other agent's call changes the radio between
    /// the steps (and the call's own radio-change bookkeeping, which would blame the agent for an owner's retune,
    /// is left out: `noteRadioChange` after each step does it).
    func identifySignals(_ args: ToolArguments, client: String) async throws -> [String: JSONValue] {
        try requireRunning()
        let from = try args.required("from_hz", args.frequency)
        let to = try args.required("to_hz", args.frequency)
        guard to > from else { throw ToolError("from_hz must be below to_hz.") }
        let minSNR = try args.double("min_snr_db", default: 10, in: 0...60)
        let maxSignals = try args.int("max_signals", default: 40, in: 1...200)
        let scan = { [self] (locked: Bool) async throws -> [String: JSONValue] in
            try await scanRange(from: from, to: to, minSNR: minSNR, maxSignals: maxSignals, locked: locked, client: client)
        }
        return try await withinCapture(from, to) ? scan(false) : withRadio { try await scan(true) }
    }

    /// Whether `from…to` lies inside the capture the radio has now.
    private func withinCapture(_ from: Double, _ to: Double) -> Bool {
        let half = model.sampleRate / 2
        return from >= model.centerHz - half - 1 && to <= model.centerHz + half + 1
    }

    /// `locked`: the radio lock is held (a scan that steps needs it).
    private func scanRange(from: Double, to: Double, minSNR: Double, maxSignals: Int, locked: Bool,
                           client: String) async throws -> [String: JSONValue] {
        let m = model
        try requireRunning()   // it may have stopped while this waited for the lock
        let short = FrequencyFormatter.short

        let span = m.sampleRate
        let capture = (m.centerHz - span / 2)...(m.centerHz + span / 2)
        let within = withinCapture(from, to)
        guard within || locked else { throw ToolError("The capture changed meanwhile: call identify_signals again.") }
        let usable = span * TuningPlanner.usableFraction * 2
        let pieces = within ? 1 : Int(((to - from) / usable).rounded(.up))
        if !within {
            // Retuning would split the owner's IQ file and cut an Auto recording.
            m.refreshRecordingStatus()
            if m.recordingStatus.values.contains(where: \.isRecording) || m.autoRecordEnabled {
                throw ToolError("The owner is recording: scan only within the current view, or ask the owner")
            }
            guard m.sourceKind != .file else {
                throw ToolError("An IQ recording is playing, so SubFloor scans only inside it (\(short(capture.lowerBound)) – \(short(capture.upperBound))). The owner can switch SubFloor back to the RSP1B.")
            }
            try Self.checkTunable(from, m.upconverter)
            try Self.checkTunable(to, m.upconverter)
            guard pieces <= Self.scanMaxPieces else {
                throw ToolError("\(short(from)) – \(short(to)) needs \(pieces) steps of \(short(usable)); at most \(Self.scanMaxPieces) (\(short(Double(Self.scanMaxPieces) * usable))). Ask for a narrower range.")
            }
        }

        let start = scanTuning(), run = ScanRun()
        var found: [(hz: Double, level: Float, identity: SignalIdentity)] = []
        var extents: [ClosedRange<Double>] = []
        var notes: [String] = []
        var stopped: String?, truncated = false, scanned = 0
        func note(_ text: String) { if notes.count < Self.maxScanNotes { notes.append(text) } }

        do {
            pieceLoop: for k in 0..<pieces {
                var cover = from...to
                var expected = start
                if !within {
                    let width = (to - from) / Double(pieces)
                    cover = (from + Double(k) * width)...(from + Double(k + 1) * width)
                    // The capture's centre at the piece's middle: the VFO sits a DC offset above it.
                    m.tune(to: (cover.lowerBound + cover.upperBound) / 2 + TuningPlanner.dcOffset(sampleRate: span),
                           keepZoom: true)
                    run.stepped = true
                    noteRadioChange(by: client)
                    expected = scanTuning()
                    if let why = try await waitForRing(expected) {
                        stopped = why
                        run.abandoned = true
                        break pieceLoop
                    }
                }
                guard let snap = try await spectrumAtCapture(expected, strict: !within) else {
                    if let why = ownerChange(from: expected, strict: !within) {
                        stopped = why
                        run.abandoned = !within
                        break pieceLoop
                    }
                    note("No spectrum for \(short(cover.lowerBound)) – \(short(cover.upperBound)): skipped.")
                    continue
                }
                scanned += 1

                // The lines of this piece: the usable part of the capture, within what was asked.
                let edge = within ? 0 : span * (0.5 - TuningPlanner.usableFraction)
                let lo = max(cover.lowerBound, snap.lowerHz + edge), hi = min(cover.upperBound, snap.upperHz - edge)
                guard hi - lo > 16 * snap.binHz else { continue }
                let points = min(2048, max(16, Int(((hi - lo) / snap.binHz).rounded())))
                let slice = SpectrumSlice(snap, from: lo, to: hi, points: points)
                let floor = slice.levels.sorted()[points / 2]
                for peak in slice.peaks where peak.level >= floor + Float(minSNR) {
                    if found.count >= maxSignals {
                        truncated = true
                        break pieceLoop
                    }
                    // A line inside a signal already identified (a tone of an FSK, a sideband) is that signal.
                    if extents.contains(where: { $0.contains(peak.hz) }) { continue }
                    if let why = ownerChange(from: expected, strict: !within) {
                        stopped = why
                        run.abandoned = !within
                        break pieceLoop
                    }
                    let identity = await m.signalID.identify(atHz: peak.hz)
                    try Task.checkCancellation()
                    guard let identity else {
                        if let why = ownerChange(from: expected, strict: !within) {
                            stopped = why
                            run.abandoned = !within
                            break pieceLoop
                        }
                        note("\(short(peak.hz)): nothing to read.")
                        continue
                    }
                    let m1 = identity.measurement
                    if m1.family == .noise { continue }   // "No signal": a line that was not one
                    let hz = signalHz(identity, askedHz: peak.hz)
                    if m1.occupiedBandwidthHz > 0 {
                        let half = max(m1.occupiedBandwidthHz, m1.bandwidth6dBHz) / 2
                        extents.append((hz - half)...(hz + half))
                    }
                    found.append((hz, peak.level, identity))
                }
            }
        } catch {
            restoreScan(start, run, client: client)
            throw error
        }
        let restored = restoreScan(start, run, client: client)

        var result: [String: JSONValue] = [
            "from_hz": .hz(from), "to_hz": .hz(to),
            "signals": .array(found.sorted { $0.hz < $1.hz }.map { f in
                .object(["hz": .hz(f.hz), "level_dbfs": .db(f.level),
                         "identity": .object(identityJSON(f.identity, signalHz: f.hz, includeHz: false))])
            }),
            "pieces": .number(Double(scanned)),
            "restored": .bool(restored),
        ]
        if let stopped { result["stopped_early"] = .string(stopped) }
        if truncated { result["truncated"] = .bool(true) }
        if !notes.isEmpty { result["notes"] = .array(notes.map { .string($0) }) }
        return result
    }

    /// Waits until the IQ ring holds the first pass's read since the last retune, up to `ringWaitLimit` (then the
    /// answer says how much it read). Returns why to stop if the owner took the radio meanwhile.
    private func waitForRing(_ expected: ScanTuning) async throws -> String? {
        let deadline = ContinuousClock.now + ringWaitLimit
        while !ringReady(Self.scanRingSeconds) {
            if let why = ownerChange(from: expected, strict: true) { return why }
            if ContinuousClock.now >= deadline { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        return ownerChange(from: expected, strict: true)
    }

    /// The averaged spectrum of the capture the radio has now: the app's frames from before a retune carry the old
    /// centre, so it waits (up to 3 s) for one that is the new capture's. Nil if none comes.
    private func spectrumAtCapture(_ expected: ScanTuning, strict: Bool) async throws -> SpectrumSnapshot? {
        let m = model
        let deadline = ContinuousClock.now + .seconds(3)
        while true {
            if let s = scanSpectrum(), abs(s.centerHz - m.centerHz) < 0.5, abs(s.spanHz - m.sampleRate) < 0.5,
               s.average.count >= 64 {
                return s
            }
            if ownerChange(from: expected, strict: strict) != nil || ContinuousClock.now >= deadline { return nil }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Puts the VFO, mode, bandwidth and HamItUp back (and the capture where it was) after a scan that stepped.
    /// Not when the owner took the radio over meanwhile: that is theirs. Returns whether the radio is as it began.
    @discardableResult
    private func restoreScan(_ start: ScanTuning, _ run: ScanRun, client: String) -> Bool {
        let m = model
        if run.stepped && !run.abandoned {
            if m.upconverter.enabled != start.hamitup { m.setUpconverter(start.hamitup) }
            if m.mode != start.mode { m.setMode(start.mode) }
            // The capture where it was, then the VFO inside it where it was.
            m.tune(to: start.centerHz + TuningPlanner.dcOffset(sampleRate: m.sampleRate), keepZoom: true)
            m.setVFO(start.vfoHz)
            if m.bandwidthHz != start.bandwidthHz { m.setBandwidth(start.bandwidthHz) }
            noteRadioChange(by: client)
        }
        let now = scanTuning()
        guard !run.abandoned else { return false }
        return !run.stepped || (now.vfoHz == start.vfoHz && now.mode == start.mode
            && now.bandwidthHz == start.bandwidthHz && now.hamitup == start.hamitup)
    }
}
