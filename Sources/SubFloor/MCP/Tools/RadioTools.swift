import DSPCore
import Foundation
import Modems
import SubFloorCore
import Transcription

/// Status, run/stop, tuning, squelch, the three cursors and the spectrum.
extension SubFloorTools {
    static var radioTools: [SubFloorTool] {
        [
            SubFloorTool("get_status", title: "Get status", readOnly: true, description: """
                SubFloor's radio state in one call: running, source (rsp1b, demo or iq_file) and device; VFO, \
                capture centre and span (Hz); mode and bandwidth; HamItUp on and its LO; squelch on and level, and \
                the signal level now (dBFS, null while stopped); recording and Auto state; decoder mode; \
                transcription on and key present; connected MCP clients. Call this first.
                """) { t, _, _ in t.status() },

            SubFloorTool("start_radio", title: "Start radio", readOnly: false, description: """
                Start the receiver on the owner's chosen source. If the RSP1B can't be opened, the demo signal runs \
                and a note says so. Returns {running, source}.
                """) { t, _, _ in try await t.startRadio() },

            SubFloorTool("stop_radio", title: "Stop radio", readOnly: false, description: """
                Stop the receiver (any recording ends). Returns {running, source}.
                """) { t, _, _ in
                t.model.stop()
                return ["running": .bool(t.model.isRunning), "source": .string(t.model.sourceKind.toolName)]
            },

            SubFloorTool("tune", title: "Tune", readOnly: false, description: """
                Tune SubFloor's receiver. frequency in display Hz (what the listener means), or a string like \
                "7.074 MHz" or "7074k". Optional mode (am, nfm, wfm, usb, lsb, cw; a new mode takes its default \
                bandwidth), bandwidth_hz (clamped to the mode's range) and hamitup: "on", "off" or "auto" (on below \
                30 MHz, otherwise left as it is; omitted: left as it is). The RSP1B tunes 1 kHz – 2 GHz; with \
                HamItUp on the top comes down by its LO. Out of range fails without tuning. \
                Returns {vfo_hz, mode, bandwidth_hz, hamitup}.
                """, properties: [
                    "frequency": .frequencySchema("Display Hz, or a string like \"7.074 MHz\"."),
                    "mode": .enumSchema(DemodMode.allCases.map(\.rawValue), "Demodulator."),
                    "bandwidth_hz": .schema("number", "Passband width in Hz."),
                    "hamitup": .enumSchema(["on", "off", "auto"], "HamItUp upconverter."),
                ], required: ["frequency"]) { t, args, _ in try t.tune(args) },

            SubFloorTool("set_squelch", title: "Set squelch", readOnly: false, description: """
                Turn the squelch on or off (enabled) and set its level (level_dbfs, −140 to 0 dBFS, clamped). \
                Either may be left out. Set it a few dB above the noise: compare signal_dbfs with the squelch \
                shut. Returns {on, level_dbfs, signal_dbfs}.
                """, properties: [
                    "enabled": .schema("boolean", "Squelch on or off."),
                    "level_dbfs": .schema("number", "Opening level in dBFS (−140…0)."),
                ]) { t, args, _ in try t.setSquelch(args) },

            SubFloorTool("get_cursor", title: "Get cursor", readOnly: true, description: """
                What the owner is pointing at: mouse (where the pointer last rested on the spectrum, kept after it \
                leaves, with seconds_ago; null if never), decoder_cursor (the decoder's locked cursor; null when no \
                decoder is on or nothing is locked) and vfo. Each gives hz, level_dbfs (the live spectrum there; \
                for the VFO, the passband's signal level), the nearest bookmark and the decodes within ± half the \
                bandwidth. And signal: what kind of signal is there (identify_signal's answer: family, name or null, \
                confidence, parameters, alternatives), or null with signal_note saying why not (the mouse only if it \
                rested within 30 s). A slow signal's first answer comes with needs_longer_read; ask again in a few \
                seconds for the longer read's.
                """) { t, _, _ in await t.cursor() },

            SubFloorTool("get_spectrum", title: "Get spectrum", readOnly: true, description: """
                Power across from_hz…to_hz (default: the owner's current view) from the live averaged spectrum: \
                points values (16–2048, default 512), each the strongest bin in its slice (dBFS), and up to 20 \
                peaks {hz, level_dbfs, width_hz} at least 6 dB above the window's median, strongest first, with \
                the width at −6 dB. The range must lie inside the capture (get_status: center_hz ± span_hz/2); \
                tune there first otherwise. Needs the radio running.
                """, properties: [
                    "from_hz": .frequencySchema("Lower edge, display Hz."),
                    "to_hz": .frequencySchema("Upper edge, display Hz."),
                    "points": .schema("integer", "How many values (16–2048, default 512)."),
                ]) { t, args, _ in try t.spectrum(args) },
        ]
    }

    // MARK: Status

    var hamitupJSON: JSONValue {
        .object(["on": .bool(model.upconverter.enabled), "lo_hz": .hz(model.upconverter.loHz)])
    }

    /// The signal level in the passband now; null while stopped.
    var signalJSON: JSONValue { model.isRunning ? .db(model.signalDb) : .null }

    func status() -> [String: JSONValue] {
        let m = model
        return [
            "running": .bool(m.isRunning),
            "source": .string(m.sourceKind.toolName),
            "device": .string(m.deviceName),
            "vfo_hz": .hz(m.vfoHz),
            "center_hz": .hz(m.centerHz),
            "span_hz": .hz(m.sampleRate),
            "mode": .string(m.mode.rawValue),
            "bandwidth_hz": .hz(m.bandwidthHz),
            "hamitup": hamitupJSON,
            "squelch": .object(["on": .bool(m.squelchEnabled), "level_dbfs": .db(m.squelchDb)]),
            "signal_dbfs": signalJSON,
            "recording": .object([
                "audio": .bool(m.recordingStatus[.audio]?.isRecording ?? false),
                "iq": .bool(m.recordingStatus[.iq]?.isRecording ?? false),
                "auto_state": .string(m.autoRecordState.toolName),
            ]),
            "decoder": .string(m.modemSettings.mode?.rawValue ?? "off"),
            "transcription": .object(["on": .bool(m.transcriptionSettings.enabled), "has_key": .bool(m.hasAPIKey)]),
            "mcp_clients": .array(connectedClients().map { .string($0) }),
        ]
    }

    // MARK: Start

    /// How long `start_radio` waits for an RSP open in flight (the model gives up on it after 10 s).
    static let rspOpenWait: Duration = .seconds(15)

    func startRadio() async throws -> [String: JSONValue] {
        let m = model
        if !m.isRunning {
            if m.rspConnection != .opening { m.start() }
            let deadline = ContinuousClock.now + Self.rspOpenWait
            while m.rspConnection == .opening && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        guard m.isRunning else {
            if m.rspConnection == .opening {
                throw ToolError("The RSP1B is still opening: call get_status in a few seconds.")
            }
            throw ToolError("The radio did not start: \(m.banner?.message ?? "no reason given"). The owner may need to check SubFloor.")
        }
        var r: [String: JSONValue] = ["running": .bool(true), "source": .string(m.sourceKind.toolName)]
        if m.sourceKind == .synthetic && m.preferredSource == .sdrplay {
            r["note"] = .string("The RSP1B could not be opened, so the demo signal is running.")
        }
        return r
    }

    // MARK: Tune

    /// The display frequencies the RSP1B reaches with `up` (as `AppModel` clamps them).
    static func tunableRange(_ up: Upconverter) -> ClosedRange<Double> {
        max(up.display(fromHardware: RSP1B.frequencyRange.lowerBound), 1_000)...up.display(fromHardware: RSP1B.frequencyRange.upperBound)
    }

    /// Fails unless `hz` is reachable with `up`.
    static func checkTunable(_ hz: Double, _ up: Upconverter) throws {
        let range = tunableRange(up)
        guard !range.contains(hz) else { return }
        let f = FrequencyFormatter.short(hz)
        if up.enabled {
            throw ToolError("\(f) is outside what the RSP1B can tune (1 kHz – 2 GHz): with HamItUp on (LO \(FrequencyFormatter.short(up.loHz))) the top is \(FrequencyFormatter.short(range.upperBound)). Give a lower frequency, or hamitup: \"off\".")
        }
        throw ToolError("\(f) is outside what the RSP1B can tune (1 kHz – 2 GHz). Give display Hz in that range.")
    }

    /// `hamitup` as "on", "off" or "auto" (true and false also do); nil when absent.
    static func hamitupSetting(_ args: ToolArguments) throws -> String? {
        if case .bool(let b)? = args.values["hamitup"] { return b ? "on" : "off" }
        return try args.choice("hamitup", ["on", "off", "auto"])
    }

    /// `current` with the HamItUp `setting` applied for `hz`: "auto" turns it on below 30 MHz when `hz` is
    /// reachable through it, and otherwise leaves it.
    static func upconverter(for hz: Double, setting: String?, current: Upconverter) -> Upconverter {
        var up = current
        switch setting {
        case "on": up.enabled = true
        case "off": up.enabled = false
        case "auto":
            var on = up
            on.enabled = true
            if hz < 30_000_000 && tunableRange(on).contains(hz) { up = on }
        default: break
        }
        return up
    }

    static func demodMode(_ args: ToolArguments) throws -> DemodMode? {
        try args.choice("mode", DemodMode.allCases.map(\.rawValue)).flatMap(DemodMode.init(rawValue:))
    }

    func tune(_ args: ToolArguments) throws -> [String: JSONValue] {
        let m = model
        let hz = try args.required("frequency", args.frequency)
        let mode = try Self.demodMode(args)
        let bandwidth = try args.double("bandwidth_hz")
        let up = Self.upconverter(for: hz, setting: try Self.hamitupSetting(args), current: m.upconverter)
        try Self.checkTunable(hz, up)
        if m.sourceKind == .file {
            let reach = m.sampleRate * 0.45
            guard abs(hz - m.centerHz) <= reach else {
                throw ToolError("An IQ recording is playing, so SubFloor tunes only inside it (\(FrequencyFormatter.short(m.centerHz - reach)) – \(FrequencyFormatter.short(m.centerHz + reach))). The owner can switch SubFloor back to the RSP1B.")
            }
        }
        if up.enabled != m.upconverter.enabled { m.setUpconverter(up.enabled) }
        if let mode { m.setMode(mode) }
        if let bandwidth { m.setBandwidth(bandwidth) }
        m.tune(to: hz)
        return ["vfo_hz": .hz(m.vfoHz), "mode": .string(m.mode.rawValue), "bandwidth_hz": .hz(m.bandwidthHz),
                "hamitup": hamitupJSON]
    }

    // MARK: Squelch

    static let squelchRange: ClosedRange<Double> = -140...0

    func setSquelch(_ args: ToolArguments) throws -> [String: JSONValue] {
        let enabled = try args.bool("enabled")
        let level = try args.double("level_dbfs", in: Self.squelchRange)
        if let level { model.squelchDb = Float(level) }
        if let enabled { model.squelchEnabled = enabled }
        return ["on": .bool(model.squelchEnabled), "level_dbfs": .db(model.squelchDb), "signal_dbfs": signalJSON]
    }

    // MARK: Cursors

    func cursor() async -> [String: JSONValue] {
        let m = model
        let snap = m.isRunning ? m.spectrumSnapshot() : nil
        let half = m.bandwidthHz / 2
        func level(_ hz: Double) -> JSONValue { snap?.level(atHz: hz).map { .db($0) } ?? .null }

        var mouse = JSONValue.null
        if let p = m.lastPointer {
            let age = now().timeIntervalSince(p.at)
            mouse = await withSignal(["hz": .hz(p.hz), "level_dbfs": level(p.hz),
                                      "seconds_ago": .num((age * 10).rounded() / 10),
                                      "nearest_bookmark": nearestBookmark(p.hz, within: half),
                                      "decodes_near": decodesNear(p.hz, within: half)], atHz: p.hz, ageSeconds: age)
        }
        var decoder = JSONValue.null
        if let mode = m.modemSettings.mode, let audio = m.modemCursorAudioHz {
            let hz = m.modemBox.rfHz(forAudio: audio)
            let row = m.decodeLog.liveRows.first { $0.isCursor }
            decoder = await withSignal(["hz": .hz(hz), "audio_hz": .hz(audio), "decoder": .string(mode.rawValue),
                                        "level_dbfs": level(hz), "snr_db": row.map { .db($0.snrDb) }.orNull,
                                        "text": row.map { .string($0.recentText) }.orNull,
                                        "nearest_bookmark": nearestBookmark(hz, within: half),
                                        "decodes_near": decodesNear(hz, within: half)], atHz: hz)
        }
        // The VFO's decodes are those in its passband, which sits beside the carrier in SSB.
        let passband = m.vfoHz + m.mode.passbandOffset(bandwidth: m.bandwidthHz)
        let vfo = await withSignal(["hz": .hz(m.vfoHz), "mode": .string(m.mode.rawValue),
                                    "bandwidth_hz": .hz(m.bandwidthHz), "level_dbfs": signalJSON,
                                    "nearest_bookmark": nearestBookmark(m.vfoHz, within: half),
                                    "decodes_near": decodesNear(passband, within: half)], atHz: passband)
        return ["mouse": mouse, "decoder_cursor": decoder, "vfo": vfo]
    }

    /// The bookmark closest to `hz` within ±`within`, or null.
    func nearestBookmark(_ hz: Double, within: Double) -> JSONValue {
        let near = model.bookmarks.filter { abs($0.frequencyHz - hz) <= within }
        guard let b = near.min(by: { abs($0.frequencyHz - hz) < abs($1.frequencyHz - hz) }) else { return .null }
        return .object(["id": .string(b.id.uuidString), "name": .string(b.name), "frequency_hz": .hz(b.frequencyHz),
                        "offset_hz": .hz(b.frequencyHz - hz), "mode": .string(b.mode.rawValue)])
    }

    /// The decoder's rows (live signals and FT8/WSPR messages) within ±`within` of `hz`, the closest 20.
    func decodesNear(_ hz: Double, within: Double) -> JSONValue {
        let box = model.modemBox
        let rows = (model.decodeLog.liveRows + model.decodeLog.slotRows)
            .map { (rf: box.rfHz(forAudio: $0.frequencyHz), row: $0) }
            .filter { abs($0.rf - hz) <= within }
            .sorted { abs($0.rf - hz) < abs($1.rf - hz) }
            .prefix(20)
        return .array(rows.map { rf, row in
            .object(["hz": .hz(rf), "mode": row.mode.map { .string($0.rawValue) }.orNull, "snr_db": .db(row.snrDb),
                     "text": .string(row.recentText), "utc": row.utcTime.map { .time($0) }.orNull])
        })
    }

    // MARK: Spectrum

    func spectrum(_ args: ToolArguments) throws -> [String: JSONValue] {
        let m = model
        try requireRunning()
        guard let snap = m.spectrumSnapshot() else { throw ToolError("No spectrum yet: try again in a second.") }
        let from = try args.frequency("from_hz") ?? max(m.viewport.lowerHz, snap.lowerHz)
        let to = try args.frequency("to_hz") ?? min(m.viewport.upperHz, snap.upperHz)
        let points = try args.int("points", default: 512, in: 16...2048)
        guard to > from else { throw ToolError("from_hz must be below to_hz.") }
        let short = FrequencyFormatter.short
        let capture = "\(short(snap.lowerHz)) – \(short(snap.upperHz))"
        guard to - from <= snap.spanHz + 1 else {
            throw ToolError("\(short(from)) – \(short(to)) is wider than the capture (\(short(snap.spanHz))): ask for a narrower range.")
        }
        guard from >= snap.lowerHz - 1, to <= snap.upperHz + 1 else {
            throw ToolError("\(short(from)) – \(short(to)) is outside the capture (\(capture)). Tune within it first (tune to about \(short((from + to) / 2))), then call get_spectrum again.")
        }
        let slice = SpectrumSlice(snap, from: from, to: to, points: points)
        return ["from_hz": .hz(from), "to_hz": .hz(to), "bin_hz": .num(slice.binHz),
                "levels_dbfs": .array(slice.levels.map { .db($0) }),
                "peaks": .array(slice.peaks.map {
                    .object(["hz": .hz($0.hz), "level_dbfs": .db($0.level), "width_hz": .hz($0.widthHz)])
                })]
    }
}

extension SpectrumSnapshot {
    var binHz: Double { spanHz / Double(average.count) }
    var lowerHz: Double { centerHz - spanHz / 2 }
    var upperHz: Double { centerHz + spanHz / 2 }
    func hz(ofBin i: Int) -> Double { lowerHz + Double(i) * binHz }
    /// The bin index `hz` falls at, fractional.
    func position(ofHz hz: Double) -> Double { (hz - lowerHz) / binHz }

    /// The level of the bin nearest `hz`; nil outside the capture.
    func level(atHz hz: Double) -> Float? {
        let i = Int(position(ofHz: hz).rounded())
        return average.indices.contains(i) ? average[i] : nil
    }
}

/// `points` levels across `from…to` of a snapshot, each the strongest bin in its slice (a slice narrower
/// than a bin takes the bin at its middle), and the peaks among them.
struct SpectrumSlice {
    struct Peak: Equatable {
        var hz: Double
        var level: Float
        var widthHz: Double
    }

    static let maxPeaks = 20
    /// A peak stands this far above the window's median; its width is measured this far below its top.
    static let peakDb: Float = 6

    /// The width of one point.
    let binHz: Double
    let levels: [Float]
    /// Strongest first. `hz` is the strongest bin's in the peak's point.
    let peaks: [Peak]

    init(_ s: SpectrumSnapshot, from: Double, to: Double, points: Int) {
        let n = s.average.count, w = (to - from) / Double(points)
        var levels = [Float](repeating: 0, count: points), best = [Int](repeating: 0, count: points)
        for k in 0..<points {
            let lo = from + Double(k) * w
            // The bins whose centres lie in [lo, lo + w).
            var first = Int((s.position(ofHz: lo) - 0.5).rounded(.up))
            var last = Int((s.position(ofHz: lo + w) - 0.5).rounded(.up)) - 1
            first = min(max(first, 0), n - 1)
            last = min(max(last, 0), n - 1)
            if last < first {
                first = min(max(Int(s.position(ofHz: lo + w / 2).rounded()), 0), n - 1)
                last = first
            }
            var b = first
            for i in first...last where s.average[i] > s.average[b] { b = i }
            levels[k] = s.average[b]
            best[k] = b
        }
        binHz = w
        self.levels = levels

        let median = levels.sorted()[points / 2], top = points - 1
        let candidates = levels.indices.filter { i in
            levels[i] >= median + Self.peakDb && (i == 0 || levels[i] > levels[i - 1])
                && (i == top || levels[i] >= levels[i + 1])
        }.sorted { levels[$0] > levels[$1] }
        var peaks: [Peak] = [], taken: [ClosedRange<Int>] = []
        for i in candidates where peaks.count < Self.maxPeaks && !taken.contains(where: { $0.contains(i) }) {
            let floor = levels[i] - Self.peakDb
            var l = i, r = i
            while l > 0 && levels[l - 1] >= floor { l -= 1 }
            while r < top && levels[r + 1] >= floor { r += 1 }
            taken.append(l...r)
            peaks.append(Peak(hz: s.hz(ofBin: best[i]), level: levels[i], widthHz: Double(r - l + 1) * w))
        }
        self.peaks = peaks
    }
}

extension SourceKind {
    /// The source as tools name it.
    var toolName: String {
        switch self {
        case .sdrplay: "rsp1b"
        case .synthetic: "demo"
        case .file: "iq_file"
        }
    }
}

extension AppModel.AutoRecordState {
    /// The state as tools name it.
    var toolName: String {
        switch self {
        case .off: "off"
        case .armed: "armed"
        case .recording: "recording"
        case .needsSquelch: "needs_squelch"
        case .needsRadio: "needs_radio"
        case .demoSource: "demo_source"
        case .paused: "paused"
        }
    }
}
