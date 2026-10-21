import Foundation
import Modems
import SubFloorCore

/// The modem panel's text: everything the views show, as pure functions (`ModemPanelTests`).
enum ModemPanelFormat {
    /// The mode segment's choices: Off, then every mode.
    static let modeChoices: [ModeID?] = [nil] + ModeID.allCases.map { $0 }

    static let benchPlaceholder = "Click a signal inside the box to analyse it"
    static let offHint = "Pick a mode to decode every signal inside the modem box"

    /// A mode segment's label: "Off" or the mode's name.
    static func label(of mode: ModeID?) -> String { mode?.label ?? "Off" }

    /// An audio frequency in whole Hz with a thousands separator: "1,520 Hz".
    static func frequency(_ hz: Double) -> String { FrequencyFormatter.audio(hz) }

    /// An audio frequency to 0.1 Hz: "1,520.3 Hz" (non-finite: "0.0 Hz").
    static func preciseFrequency(_ hz: Double) -> String {
        let tenths = hz.isFinite ? Int(max(0, min(hz, 1e9)) * 10 + 0.5) : 0
        return String(FrequencyFormatter.audio(Double(tenths / 10)).dropLast(3)) + ".\(tenths % 10) Hz"
    }

    /// The box's dial frequency: "14.074.000 USB".
    static func dial(_ box: ModemBox) -> String { FrequencyFormatter.grouped(box.dialHz) + " USB" }

    /// A signed whole-dB SNR: "+12 dB", "-4 dB".
    static func snr(_ db: Float) -> String {
        guard db.isFinite else { return "— dB" }
        return signedInt(db) + " dB"
    }

    /// `HHMMSS` of a UTC time, whatever the local time zone.
    static func utcHHMMSS(_ date: Date) -> String { DecodeLog.utcHHMMSS(date) }

    /// A slot row: "HHMMSS  SNR  freq  message" in fixed-width columns (SNR 3 wide, the frequency 8
    /// wide, right-aligned), for a monospaced font: "143215  -12  1,520 Hz  CQ K1ABC FN42".
    static func slotRow(_ row: DecodeRow) -> String {
        let time = row.utcTime.map(utcHHMMSS) ?? "------"
        let snr = row.snrDb.isFinite ? signedInt(row.snrDb) : "—"
        return time + "  " + padLeft(snr, 3) + "  " + padLeft(frequency(row.frequencyHz), 8) + "  "
            + singleLine(row.recentText)
    }

    /// A live row's mode: its submode ("QPSK31", "CW 18WPM"), else its mode, else "?" (unclassified).
    static func modeLabel(_ row: DecodeRow) -> String {
        if !row.submode.isEmpty { return row.submode }
        return row.mode?.label ?? "?"
    }

    /// `text` on one line: every line break becomes a space.
    static func singleLine(_ text: String) -> String {
        guard text.contains(where: \.isNewline) else { return text }
        return String(text.map { $0.isNewline ? " " : $0 })
    }

    static func signalCount(_ n: Int) -> String { n == 1 ? "1 signal" : "\(n) signals" }

    /// The floating pill over held rows: "4 new ↓", or nil when none are held.
    static func newRowsPill(_ held: Int) -> String? { held > 0 ? "\(held) new ↓" : nil }

    /// Where `mode`'s current UTC slot is at `date` (nil for a streaming mode).
    static func slotProgress(_ mode: ModeID, at date: Date) -> SlotProgress? {
        guard let length = ModemCatalog.slot(mode)?.slotSeconds else { return nil }
        let start = SlotRecorder.slotStart(for: date, slotSeconds: length)
        let elapsed = min(max(date.timeIntervalSince(start), 0), length)
        return SlotProgress(mode: mode, length: length, elapsed: elapsed)
    }

    private static func signedInt(_ v: Float) -> String {
        let n = Int(v.rounded())
        return n < 0 ? "\(n)" : "+\(n)"
    }

    private static func padLeft(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
    }
}

/// How far through its UTC slot a slot mode is (FT8 15 s, WSPR 120 s).
struct SlotProgress: Equatable {
    var mode: ModeID
    var length: Double
    var elapsed: Double

    /// 0 at the slot's start, towards 1 at its end.
    var fraction: Double { length > 0 ? elapsed / length : 0 }
    /// Whole seconds to the next slot, rounded up.
    var secondsRemaining: Int { Int((length - elapsed).rounded(.up)) }
    /// "FT8 12 s".
    var text: String { "\(mode.label) \(secondsRemaining) s" }
}

/// A message under the control strip.
enum ModemPanelMessage: Equatable, Hashable {
    /// FT8/WSPR are wanted but the source is an IQ file.
    case needsLiveRadio
    /// The box is outside the captured span: decoding has stopped.
    case boxOutsideSpan
    /// Slot modes are running and the system clock is this far from network time (seconds to add
    /// to it; positive: it is behind).
    case clock(offset: Double)

    var text: String {
        switch self {
        case .needsLiveRadio: "FT8/WSPR need a live radio"
        case .boxOutsideSpan: "Modem box is outside the captured band"
        case .clock(let offset):
            "System clock is \(String(format: "%.1f", abs(offset))) s \(offset > 0 ? "slow" : "fast")"
                + " — FT8/WSPR need it within 1 s of UTC"
        }
    }

    /// Whether the message carries a Re-center button.
    var offersRecenter: Bool { self == .boxOutsideSpan }

    var isWarning: Bool { self != .needsLiveRadio }
}

/// The control strip's state, from `AppModel`'s modem state (`AppModel.modemPanelStatus`). It holds
/// only state that changes when the user changes something (not the decode log, which changes at
/// 10 Hz): the views whose bodies read it hold segmented pickers, which SwiftUI re-measures (slowly)
/// whenever such a body runs. The log's counts are read by the small views that show them.
struct ModemPanelStatus: Equatable {
    /// `|clockOffset|` beyond this warns.
    static let clockTolerance = 1.0

    var mode: ModeID?
    var autoDetect: Bool
    var isFileSource: Bool
    var boxActive: Bool
    var clockOffset: Double?
    var box: ModemBox

    var isOn: Bool { mode != nil }

    /// Whether FT8/WSPR are wanted by the settings (the picked mode, or auto-detect), live radio or not.
    private var wantsSlotModes: Bool {
        guard let mode else { return false }
        return autoDetect || mode.isSlotMode
    }

    /// The slot modes decoding now, in catalog order, whose progress the strip shows: none for a
    /// file source or while the box is inactive.
    var slotModes: [ModeID] {
        guard wantsSlotModes, !isFileSource, boxActive, let mode else { return [] }
        return ModemCatalog.slot.map { $0.id }.filter { autoDetect || $0 == mode }
    }

    var messages: [ModemPanelMessage] {
        guard isOn else { return [] }
        var out: [ModemPanelMessage] = []
        if isFileSource && wantsSlotModes { out.append(.needsLiveRadio) }
        if !boxActive { out.append(.boxOutsideSpan) }
        if let offset = clockOffset, abs(offset) > Self.clockTolerance, !slotModes.isEmpty {
            out.append(.clock(offset: offset))
        }
        return out
    }

    var dialText: String { ModemPanelFormat.dial(box) }
}

/// The bench panes' amber readouts.
struct BenchReadouts: Equatable {
    /// WAVEFORM: the frequency to 0.1 Hz.
    var waveform: String
    /// MICRO SPECTRUM: the SNR.
    var spectrum: String
    /// IQ: the detected mode and its symbol rate.
    var iq: String

    init(_ frame: CursorFrame) {
        waveform = ModemPanelFormat.preciseFrequency(frame.frequencyHz)
        spectrum = "SNR " + ModemPanelFormat.snr(frame.snrDb)
        var parts: [String] = []
        if !frame.submode.isEmpty { parts.append(frame.submode) }
        if let rate = frame.symbolRate, rate.isFinite { parts.append(String(format: "%.4g Bd", rate)) }
        iq = parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

/// The bench's latest frame from the `CursorFrameStore`, on the main thread (one per bench view).
/// Nothing is shown while the cursor is unlocked; a frame from before an unlock never returns
/// (the store's sequence only grows), and a box reset that discards the store's frame clears it.
final class CursorBenchFeed {
    private var sequence: UInt64 = 0
    private(set) var frame: CursorFrame?

    init() {}

    /// The frame to draw now.
    @discardableResult
    func update(from store: CursorFrameStore, cursorLocked: Bool) -> CursorFrame? {
        guard cursorLocked else {
            frame = nil
            if let (s, _) = store.read(after: sequence) { sequence = s }
            return nil
        }
        if let (s, f) = store.read(after: sequence) {
            sequence = s
            frame = f
        } else if !store.hasFrame {
            frame = nil
        }
        return frame
    }
}

/// The bench panes' shapes in unit coordinates (x right, y down, 0…1), for the views to scale.
enum BenchGeometry {
    /// The waveform's peak, as a fraction of the pane height either side of the middle.
    static let waveformAmplitude = 0.42
    /// dB from the strongest bin to the pane's bottom.
    static let spectrumRangeDb: Float = 60
    /// Headroom above the strongest bin.
    static let spectrumTopMargin = 0.08
    /// The largest IQ component, as a fraction of the pane's smaller side from the centre.
    static let iqRadius = 0.45

    /// One point per sample, peak-normalised about the middle (empty below 2 samples).
    static func waveform(_ samples: [Float]) -> [SIMD2<Double>] {
        guard samples.count > 1 else { return [] }
        let peak = Double(samples.reduce(Float(0)) { $1.isFinite ? max($0, abs($1)) : $0 })
        let scale = peak > 1e-9 ? waveformAmplitude / peak : 0
        let last = Double(samples.count - 1)
        return samples.enumerated().map { i, v in
            SIMD2(Double(i) / last, 0.5 - (v.isFinite ? Double(v) : 0) * scale)
        }
    }

    /// One point per bin: the strongest at `spectrumTopMargin`, `spectrumRangeDb` below it at the
    /// bottom (and anything lower, or not finite, on the bottom).
    static func spectrum(_ db: [Float]) -> [SIMD2<Double>] {
        guard !db.isEmpty else { return [] }
        let top = db.reduce(-Float.infinity) { $1.isFinite ? max($0, $1) : $0 }
        let last = Double(max(db.count - 1, 1))
        return db.enumerated().map { i, v in
            let below = top.isFinite && v.isFinite ? Double((top - v) / spectrumRangeDb) : 1
            let y = spectrumTopMargin + min(max(below, 0), 1) * (1 - spectrumTopMargin)
            return SIMD2(db.count == 1 ? 0.5 : Double(i) / last, y)
        }
    }

    struct IQPoint: Equatable {
        /// In a unit square (the view centres a square of its smaller side).
        var point: SIMD2<Double>
        /// Older points fade: 1 for the newest.
        var opacity: Double
    }

    /// The points about the centre, scaled so the largest component reaches `iqRadius`, I right
    /// and Q up; oldest first and faintest.
    static func iq(_ points: [SIMD2<Float>]) -> [IQPoint] {
        guard !points.isEmpty else { return [] }
        let peak = Double(points.reduce(Float(0)) { m, p in
            p.x.isFinite && p.y.isFinite ? max(m, abs(p.x), abs(p.y)) : m
        })
        let scale = peak > 1e-9 ? iqRadius / peak : 0
        let n = Double(points.count)
        return points.enumerated().map { k, p in
            let ok = p.x.isFinite && p.y.isFinite
            let i = ok ? Double(p.x) : 0, q = ok ? Double(p.y) : 0
            return IQPoint(point: SIMD2(0.5 + i * scale, 0.5 - q * scale), opacity: Double(k + 1) / n)
        }
    }
}
