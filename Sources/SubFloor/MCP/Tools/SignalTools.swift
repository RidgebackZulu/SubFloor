import DSPCore
import Foundation
import SignalID
import SubFloorCore
import Transcription

/// An identification `get_cursor` started: its first answer, for every call at the same point while it runs (one
/// during its first pass waits for that pass instead of starting another; one during its longer read gets the first
/// pass's answer).
@MainActor
final class CursorRead {
    let first = FirstAnswer()
}

/// The first of several answers: every waiter gets whichever is resolved first.
@MainActor
final class FirstAnswer {
    private var waiting: [CheckedContinuation<SignalIdentity?, Never>] = []
    private var answered = false
    private var value: SignalIdentity?

    func wait() async -> SignalIdentity? {
        if answered { return value }
        return await withCheckedContinuation { waiting.append($0) }
    }

    func resolve(_ answer: SignalIdentity?) {
        guard !answered else { return }
        answered = true
        value = answer
        for continuation in waiting { continuation.resume(returning: answer) }
        waiting = []
    }
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
                keyed under 10 WPM, WSPR, FT8 slots) are read again over up to 16 s: that is in this answer. With \
                the radio stopped it reads what the IQ ring heard last. \
                Returns {hz, label, family, name, confidence, parameters, alternatives, tune, ...}.
                """, properties: [
                    "frequency": .frequencySchema("Display Hz, or a string like \"7.074 MHz\". Inside the capture."),
                    "bandwidth_hz": .schema("number", "The signal's width in Hz, if known."),
                ], required: ["frequency"]) { t, args, _ in try await t.identifySignal(args) },

            SubFloorTool("identify_signals", title: "Identify every signal in a range", readOnly: false, locksRadio: false, description: """
                Find every signal from from_hz to to_hz (display Hz) and identify each. Inside the current capture \
                (get_status: center_hz ± span_hz/2) it does not touch the radio. Across a wider range it steps the \
                radio across it, one capture at a time (at most 60 steps), waiting at each until the IQ ring holds about \
                3 s (up to 20 s), then identifying each line: about 4 s a step plus a fraction of a second a signal. \
                A step's ring holds only that 3 s, so a stepped scan makes no longer read: slow signals (FT8, WSPR, \
                slow CW, time signals) come back unnamed with needs_longer_read true (needs_longer_read_hz lists \
                them); tune to one and call identify_signal after about 16 s. Inside the capture they get their \
                longer read. It holds the radio lock and puts the VFO, mode, bandwidth and HamItUp back afterwards; \
                each step restarts the owner's IQ pre-roll. The owner hears each step. It refuses while the owner \
                is recording or Auto is on (a retune would split the \
                file), and stops early, leaving the radio as it is, if the owner retunes or starts recording. \
                min_snr_db (default 10) is how far a line stands over the floor; every such line is identified, \
                up to max_signals (default 40, up to 200): then truncated is set with resume_from_hz, to call again \
                from. Log what it finds with add_bookmark. Returns {signals: [{hz, level_dbfs, identity}], pieces, \
                restored, stopped_early?, truncated?, resume_from_hz?, needs_longer_read_hz?, notes?}.
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
            "family": .string(SignalIdentity.familyName(m)),
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
        let hz = try args.required("frequency", args.frequency)
        let bandwidth = try args.double("bandwidth_hz", in: 1...max(m.sampleRate, 2))
        guard inCapture(hz) else {
            let short = FrequencyFormatter.short
            throw ToolError("\(short(hz)) is outside the capture (\(short(m.centerHz - m.sampleRate / 2)) – \(short(m.centerHz + m.sampleRate / 2))). Tune within it first (about \(short(hz))), or use identify_signals across a wider range.")
        }
        let id = await m.signalID.identify(atHz: hz, bandwidthHz: bandwidth)
        try Task.checkCancellation()
        guard let id else {
            // With the radio stopped the ring is read as it is: nil is an empty one.
            guard m.isRunning else { throw ToolError("The radio is stopped and its IQ ring is empty: call start_radio first.") }
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
        if let age = ageSeconds, age > Self.mouseIdentifySeconds {
            return (nil, "The pointer last rested on the spectrum \(Int(age.rounded())) s ago, more than \(Int(Self.mouseIdentifySeconds)) s: not identified. Ask the owner to point at the signal, or call identify_signal with its frequency.")
        }
        guard inCapture(hz) else {
            return (nil, "\(short(hz)) is outside the current capture: tune there first, then call identify_signal.")
        }
        guard let id = await quickIdentity(atHz: hz) else {
            // With the radio stopped the ring is read as it is (what it heard last): nil is an empty one.
            guard model.isRunning else { return (nil, "The radio is stopped and its IQ ring is empty: nothing to read.") }
            return (nil, "Nothing to read yet: the radio was just started or retuned. Try again in a second.")
        }
        return (.object(identityJSON(id, signalHz: signalHz(id, askedHz: hz))), nil)
    }

    /// The identity at `hz` without waiting for the longer read: when the first pass asks for one, its answer
    /// (`needsLongerRead`) is returned at once and the longer read finishes in the background, into the service's
    /// cache for the next call. Calls that come while one runs (from its start) get its first answer, not another
    /// read.
    func quickIdentity(atHz hz: Double) async -> SignalIdentity? {
        let key = Int((hz / 25).rounded())
        if let running = cursorReads[key] { return await running.first.wait() }
        let service = model.signalID
        let read = CursorRead()
        cursorReads[key] = read
        Task { @MainActor [weak self] in
            let answer = await service.identify(atHz: hz) { read.first.resolve($0) }
            read.first.resolve(answer)
            if let self, self.cursorReads[key] === read { self.cursorReads[key] = nil }
        }
        return await read.first.wait()
    }

    // MARK: identify_signals

    /// The most pieces a scan steps through (about 4 s each).
    static let scanMaxPieces = 60
    /// A scan's wait for the IQ ring: the first pass reads this much, and the 50 ms it drops after a retune.
    static let scanRingSeconds = SignalIDService.firstSeconds + SignalIDService.settleSeconds + 0.05
    /// The finest a scan reads a piece: points across it (the spectrum's own bins, up to this many).
    static let scanMaxPoints = 16_384
    /// A line this many bins from the capture's centre may be the receiver's own DC spike.
    static let dcBins = 4.0
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

    /// A scan's state: whether it moved the radio, what it left it as, and whether it has been told to stop.
    private final class ScanRun {
        /// The scan steps the radio (it is not inside the capture).
        let stepping: Bool
        var stepped = false
        /// The radio is the owner's now: nothing more is written to it, and it is not restored.
        var abandoned = false
        var stopped: String?
        /// The tuning the scan left, or began with: a difference is someone else's doing.
        var expected: ScanTuning

        init(stepping: Bool, expected: ScanTuning) {
            self.stepping = stepping
            self.expected = expected
        }
    }

    /// What has changed since `expected` that a scan must give way to, or nil: a different tuning, mode, bandwidth,
    /// capture or HamItUp, or the radio stopped; and, for a scan that steps, a recording or Auto that has started
    /// (a retune would split the IQ file or cut the Auto recording). A scan inside the capture (`stepping` false)
    /// minds only a change of the capture itself: the VFO is the owner's to move.
    private func change(since expected: ScanTuning, stepping: Bool) -> String? {
        let now = scanTuning()
        let short = FrequencyFormatter.short
        if now != expected {
            if !now.running { return "The radio was stopped." }
            if stepping || now.centerHz != expected.centerHz || now.hamitup != expected.hamitup || now.loHz != expected.loHz {
                if now.vfoHz != expected.vfoHz { return "The radio was retuned to \(short(now.vfoHz))." }
                if now.mode != expected.mode { return "The mode was changed to \(now.mode.label)." }
                if now.bandwidthHz != expected.bandwidthHz { return "The bandwidth was changed." }
                return "The capture or HamItUp was changed."
            }
        }
        if stepping {
            model.refreshRecordingStatus()
            if model.recordingStatus.values.contains(where: \.isRecording) { return "A recording was started." }
            if model.autoRecordEnabled { return "Auto-record was turned on." }
        }
        return nil
    }

    /// The one check every radio write and every answer goes through: true when the scan must stop (and says why in
    /// `run.stopped`). Once stopped it stays stopped. A scan that steps then leaves the radio as it found it.
    private func interrupted(_ run: ScanRun) -> Bool {
        if run.stopped != nil { return true }
        guard let why = change(since: run.expected, stepping: run.stepping) else { return false }
        run.stopped = why
        run.abandoned = run.stepping
        return true
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

        let start = scanTuning(), run = ScanRun(stepping: !within, expected: scanTuning())
        var found: [(hz: Double, level: Float, atCentre: Bool, identity: SignalIdentity)] = []
        var extents: [ClosedRange<Double>] = []
        var notes: [String] = []
        var truncated = false, resume = from, scanned = 0
        func note(_ text: String) { if notes.count < Self.maxScanNotes { notes.append(text) } }

        do {
            pieceLoop: for k in 0..<pieces {
                try Task.checkCancellation()
                if interrupted(run) { break pieceLoop }
                var cover = from...to
                if !within {
                    let width = (to - from) / Double(pieces)
                    cover = (from + Double(k) * width)...(from + Double(k + 1) * width)
                    // The signals found are the limit: the rest of the range is for another call.
                    if found.count >= maxSignals {
                        truncated = true
                        resume = cover.lowerBound
                        break pieceLoop
                    }
                    // The capture's centre at the piece's middle: the VFO sits a DC offset above it.
                    m.tune(to: (cover.lowerBound + cover.upperBound) / 2 + TuningPlanner.dcOffset(sampleRate: span),
                           keepZoom: true)
                    run.stepped = true
                    noteRadioChange(by: client)
                    run.expected = scanTuning()
                    guard try await waitForRing(run) else { break pieceLoop }
                }
                guard let snap = try await spectrumAtCapture(run) else {
                    if run.stopped != nil || interrupted(run) { break pieceLoop }
                    note("No spectrum for \(short(cover.lowerBound)) – \(short(cover.upperBound)): skipped.")
                    continue
                }
                scanned += 1

                // The lines of this piece: the usable part of the capture, within what was asked, at the spectrum's
                // own resolution, every one over the floor, lowest first.
                let edge = within ? 0 : span * (0.5 - TuningPlanner.usableFraction)
                let lo = max(cover.lowerBound, snap.lowerHz + edge), hi = min(cover.upperBound, snap.upperHz - edge)
                guard hi - lo > 16 * snap.binHz else { continue }
                let points = min(Self.scanMaxPoints, max(16, Int(((hi - lo) / snap.binHz).rounded())))
                let slice = SpectrumSlice(snap, from: lo, to: hi, points: points, maxPeaks: points)
                let floor = slice.levels.sorted()[points / 2]
                let lines = slice.peaks.filter { $0.level >= floor + Float(minSNR) }.sorted { $0.hz < $1.hz }
                for peak in lines {
                    // A line inside a signal already identified (a tone of an FSK, a sideband) is that signal.
                    if extents.contains(where: { $0.contains(peak.hz) }) { continue }
                    if found.count >= maxSignals {
                        truncated = true
                        resume = max(from, peak.hz - 2 * snap.binHz)
                        break pieceLoop
                    }
                    if interrupted(run) { break pieceLoop }
                    // A stepped scan's ring holds only the first read since its step: no longer read is made.
                    var identity = await m.signalID.identify(atHz: peak.hz, longerRead: !run.stepping)
                    try Task.checkCancellation()
                    if identity?.note == SignalIdentifier.tooSoonNote {
                        // The ring hadn't filled since a retune: once more when it has.
                        guard try await waitForRing(run) else { break pieceLoop }
                        identity = await m.signalID.identify(atHz: peak.hz, longerRead: !run.stepping)
                        try Task.checkCancellation()
                    }
                    guard let identity else {
                        if interrupted(run) { break pieceLoop }
                        note("\(short(peak.hz)): nothing to read.")
                        continue
                    }
                    let m1 = identity.measurement
                    if m1.family == .noise {
                        // "No signal" is a line that was not one; anything else (too soon after tuning) is said.
                        if identity.note != SignalIdentifier.noSignalNote {
                            note("\(short(peak.hz)): \(identity.note ?? identity.label); not identified.")
                        }
                    } else {
                        let hz = signalHz(identity, askedHz: peak.hz)
                        if m1.occupiedBandwidthHz > 0 {
                            let half = max(m1.occupiedBandwidthHz, m1.bandwidth6dBHz) / 2
                            extents.append((hz - half)...(hz + half))
                        }
                        // The receiver's centre carries a residual zero-IF DC spike.
                        found.append((hz, peak.level, abs(peak.hz - snap.centerHz) <= Self.dcBins * snap.binHz, identity))
                    }
                    // The answer stands, but the owner's change since means no more of the scan.
                    if interrupted(run) { break pieceLoop }
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
                var entry: [String: JSONValue] = ["hz": .hz(f.hz), "level_dbfs": .db(f.level),
                                                  "identity": .object(identityJSON(f.identity, signalHz: f.hz, includeHz: false))]
                if f.atCentre { entry["at_receiver_centre"] = .bool(true) }
                return .object(entry)
            }),
            "pieces": .number(Double(scanned)),
            "restored": .bool(restored),
        ]
        if let stopped = run.stopped { result["stopped_early"] = .string(stopped) }
        if truncated {
            result["truncated"] = .bool(true)
            result["resume_from_hz"] = .hz(resume)
        }
        // A stepped scan made no longer reads: the signals that wanted one, for an agent's follow-up.
        let slow = run.stepping ? found.filter(\.identity.needsLongerRead).map(\.hz).sorted() : []
        if !slow.isEmpty {
            result["needs_longer_read_hz"] = .array(slow.map { .hz($0) })
            notes.append("\(slow.count) signal\(slow.count == 1 ? "" : "s") wanted a longer read than a stepped scan makes (needs_longer_read_hz): tune to one and call identify_signal after about 16 s.")
        }
        if !notes.isEmpty { result["notes"] = .array(notes.map { .string($0) }) }
        return result
    }

    /// Waits until the IQ ring holds the first pass's read since the last retune, up to `ringWaitLimit` (then the
    /// answer says how much it read). False if the scan has to stop meanwhile.
    private func waitForRing(_ run: ScanRun) async throws -> Bool {
        let deadline = ContinuousClock.now + ringWaitLimit
        while !ringReady(Self.scanRingSeconds) {
            if interrupted(run) { return false }
            if ContinuousClock.now >= deadline { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        return !interrupted(run)
    }

    /// The averaged spectrum of the capture the radio has now: the app's frames from before a retune carry the old
    /// centre, so it waits (up to 3 s) for one that is the new capture's. Nil if none comes, or the scan must stop.
    private func spectrumAtCapture(_ run: ScanRun) async throws -> SpectrumSnapshot? {
        let m = model
        let deadline = ContinuousClock.now + .seconds(3)
        while true {
            if let s = scanSpectrum(), abs(s.centerHz - m.centerHz) < 0.5, abs(s.spanHz - m.sampleRate) < 0.5,
               s.average.count >= 64 {
                return interrupted(run) ? nil : s
            }
            if interrupted(run) || ContinuousClock.now >= deadline { return nil }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Puts the VFO, mode, bandwidth and HamItUp back (and the capture where it was) after a scan that stepped,
    /// unless the radio has become someone else's meanwhile (checked here too, last of all, so nothing is written
    /// over it). Returns whether the radio is as it began; a scan that never moved it always is.
    @discardableResult
    private func restoreScan(_ start: ScanTuning, _ run: ScanRun, client: String) -> Bool {
        guard run.stepped else { return true }
        if !run.abandoned { _ = interrupted(run) }
        guard !run.abandoned else { return false }
        let m = model
        if m.upconverter.enabled != start.hamitup { m.setUpconverter(start.hamitup) }
        if m.mode != start.mode { m.setMode(start.mode) }
        // The capture where it was, then the VFO inside it where it was.
        m.tune(to: start.centerHz + TuningPlanner.dcOffset(sampleRate: m.sampleRate), keepZoom: true)
        m.setVFO(start.vfoHz)
        if m.bandwidthHz != start.bandwidthHz { m.setBandwidth(start.bandwidthHz) }
        noteRadioChange(by: client)
        let now = scanTuning()
        return now.vfoHz == start.vfoHz && now.mode == start.mode && now.bandwidthHz == start.bandwidthHz
            && now.hamitup == start.hamitup
    }
}
