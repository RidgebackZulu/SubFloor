import Foundation
import Modems
import SubFloorCore

/// One change `AppModel` makes to the engine's modem, in the order it makes them (also what its
/// test hook records).
enum ModemEngineUpdate: Equatable, Sendable {
    case boxDialOffset(Double?)
    case settings(ModemSettings)
    case command(ModemCommand)
}

/// The modem state `AppModel` keeps, as a pure value: the box, the user's settings and the
/// cursor, and the engine updates they imply. `AppModel` is a thin wrapper that supplies the
/// capture span and source, applies `takeEngineUpdates` to the `DSPEngine`, and feeds back epochs
/// and snapshots.
///
/// **Engine state.** The engine gets the box's dial offset from the capture centre, nil while the
/// box is outside the capture span (`ModemBox.isInside`), so decoding stops there and resumes (with
/// a reset) when a retune or a move brings it back; and the user's settings with
/// `slotModesEnabled` off for file sources. `takeEngineUpdates` sends only what changed since the
/// last call: settings, then the offset, then the queued commands, so a command follows the reset
/// the settings or offset caused.
///
/// **The cursor.** Locking (a click in the box, a row, ←/→) sets `cursorAudioHz` at once and sends
/// the command; snapshots then follow the engine's cursor (its snap to a track, its AFC). After a
/// lock, a snapshot cursor farther than `lockAcceptHz` from the click is from before the lock and
/// is ignored, until one is accepted. The engine unlocks the cursor on every box reset (a new
/// epoch), so the cursor is dropped here when an epoch newer than the one its command was issued in
/// is observed (`commandsSent(inEpoch:)`, `observeEpoch`), when the box leaves the span, and when
/// the mode is switched off.
struct ModemControl: Equatable, Sendable {
    /// The box's first dial: 20 m FT8.
    static let defaultDialHz = 14_074_000.0
    /// See **The cursor**: the widest lock range (RTTY's 30 Hz).
    static let lockAcceptHz = 30.0
    /// A click in the box this close to the locked cursor unlocks it: this fraction of the view's
    /// span (a few points), at most `cursorClickMaxHz`.
    static let cursorClickFraction = 0.004
    static let cursorClickMaxHz = 10.0

    var box = ModemBox(dialHz: ModemControl.defaultDialHz)
    /// The user's settings, as persisted (`engineSettings` sets `slotModesEnabled`).
    var settings = ModemSettings()
    /// The locked cursor's audio frequency; nil when unlocked.
    private(set) var cursorAudioHz: Double?

    private enum CursorWait: Equatable, Sendable {
        case none
        /// Locked at this audio frequency; no snapshot accepted yet.
        case lock(Double)
        /// Nudged; the next snapshot cursor is the new one.
        case nudge
    }

    /// A lock or nudge was asked for and not undone (the cursor may still be unknown after a nudge).
    private var cursorExpected = false
    private var cursorWait = CursorWait.none
    /// The epoch the cursor's last command was issued in (nil until it is sent).
    private var cursorEpoch: UInt64?
    private var stampCursorEpoch = false
    private var commands: [ModemCommand] = []
    /// What the engine was last sent (nil: nothing yet).
    private var sentOffset: Double??
    private var sentSettings: ModemSettings?

    init(box: ModemBox = ModemBox(dialHz: ModemControl.defaultDialHz), settings: ModemSettings = ModemSettings()) {
        self.box = box
        self.settings = settings
    }

    // MARK: Derived

    func isBoxActive(captureCenter: Double, captureSpan: Double) -> Bool {
        box.isInside(captureCenter: captureCenter, captureSpan: captureSpan)
    }

    /// The box dial minus the capture centre, or nil while the box is outside the span.
    func dialOffset(captureCenter: Double, captureSpan: Double) -> Double? {
        isBoxActive(captureCenter: captureCenter, captureSpan: captureSpan) ? box.dialHz - captureCenter : nil
    }

    func engineSettings(isFileSource: Bool) -> ModemSettings {
        var s = settings
        s.slotModesEnabled = !isFileSource
        return s
    }

    /// The grab tab's label: "≡ PSK31 · 3 kHz", or "AUTO · 3 kHz" with auto-detect on.
    var grabTabLabel: String {
        if settings.autoDetect { return "AUTO · 3 kHz" }
        return "≡ \(settings.mode?.label ?? "MODEM") · 3 kHz"
    }

    // MARK: Settings

    mutating func setMode(_ mode: ModeID?) {
        settings.mode = mode
        if mode == nil { dropCursor() }
    }

    mutating func setAutoDetect(_ on: Bool) { settings.autoDetect = on }
    mutating func setAudioWide(_ on: Bool) { settings.audioWide = on }

    // MARK: Box

    /// Drags the box by `hz` (see `ModemBox.move(byHz:keepingInsideCaptureCenter:span:)`).
    mutating func moveBox(byHz hz: Double, captureCenter: Double, captureSpan: Double) {
        guard hz.isFinite else { return }
        box.move(byHz: hz, keepingInsideCaptureCenter: captureCenter, span: captureSpan)
    }

    /// Centres the box on `rf` (the view's centre), clamped to the capture span.
    mutating func recenter(on rf: Double, captureCenter: Double, captureSpan: Double) {
        box = ModemBox.centered(on: rf, clampedToCaptureCenter: captureCenter, span: captureSpan)
    }

    // MARK: Cursor

    /// Locks the cursor at RF `rf` inside the box, while the modem is on and the box active.
    mutating func lock(atRF rf: Double, boxActive: Bool) {
        guard settings.mode != nil, boxActive, rf.isFinite, box.contains(rf: rf) else { return }
        let audio = box.audioHz(forRF: rf)
        cursorAudioHz = audio
        cursorExpected = true
        cursorWait = .lock(audio)
        queueCursorCommand(.lock(audioHz: audio))
    }

    /// A click in the box at RF `rf` with the view `spanHz` wide: on the locked cursor it unlocks
    /// it, anywhere else it locks there.
    mutating func click(atRF rf: Double, spanHz: Double, boxActive: Bool) {
        if let c = cursorAudioHz,
           abs(box.audioHz(forRF: rf) - c) <= min(spanHz * Self.cursorClickFraction, Self.cursorClickMaxHz) {
            unlock()
        } else {
            lock(atRF: rf, boxActive: boxActive)
        }
    }

    mutating func unlock() {
        guard cursorExpected else { return }
        dropCursor()
        commands.append(.unlock)
    }

    /// Moves the cursor `steps` tracked signals up (positive) or down.
    mutating func nudge(_ steps: Int, boxActive: Bool) {
        guard settings.mode != nil, boxActive, steps != 0 else { return }
        cursorExpected = true
        cursorWait = .nudge
        queueCursorCommand(.nudge(steps))
    }

    /// A row was clicked: the cursor's row unlocks it, any other locks on its signal.
    mutating func select(_ row: DecodeRow, boxActive: Bool) {
        if row.isCursor {
            unlock()
            return
        }
        var audio = row.frequencyHz
        if let mode = row.mode, let slotStart = row.utcTime {
            // A slot row: its decoder's frequency (FT8: tone 0) to the signal's centre.
            audio = DecodeLog.signalCentreHz(of: SlotDecode(mode: mode, slotStart: slotStart, frequencyHz: row.frequencyHz,
                                                            snrDb: row.snrDb, timeOffset: 0, message: ""))
        }
        lock(atRF: box.rfHz(forAudio: audio), boxActive: boxActive)
    }

    // MARK: Engine

    /// The engine updates since the previous call (see **Engine state**). Dropping the box out of
    /// the span, or the mode off, drops the cursor.
    mutating func takeEngineUpdates(captureCenter: Double, captureSpan: Double, isFileSource: Bool) -> [ModemEngineUpdate] {
        var out: [ModemEngineUpdate] = []
        let s = engineSettings(isFileSource: isFileSource)
        if sentSettings != s {
            out.append(.settings(s))
            sentSettings = s
        }
        let offset = dialOffset(captureCenter: captureCenter, captureSpan: captureSpan)
        if sentOffset != .some(offset) {
            out.append(.boxDialOffset(offset))
            sentOffset = .some(offset)
        }
        if offset == nil || s.mode == nil {
            dropCursor()
            commands.removeAll { $0 != .unlock }
        }
        out += commands.map { .command($0) }
        commands.removeAll()
        return out
    }

    /// Applies `takeEngineUpdates` to `engine` and notes its epoch; returns the updates applied.
    @discardableResult
    mutating func sync(_ engine: DSPEngine, captureCenter: Double, captureSpan: Double,
                       isFileSource: Bool) -> [ModemEngineUpdate] {
        let updates = takeEngineUpdates(captureCenter: captureCenter, captureSpan: captureSpan, isFileSource: isFileSource)
        for u in updates {
            switch u {
            case .boxDialOffset(let offset): engine.update(modemBoxDialOffset: offset)
            case .settings(let s): engine.update(modemSettings: s)
            case .command(let c): engine.modemCommand(c)
            }
        }
        commandsSent(inEpoch: engine.modemEvents.epoch)
        return updates
    }

    /// One drained batch of the engine's output into `log`, the way `ModemEventQueue` documents it
    /// (the log is cleared only here, from the batch), and the cursor follows its snapshot.
    mutating func take(_ batch: ModemEventQueue.Batch, into log: inout DecodeLog, now: Date) {
        observeEpoch(batch.epoch)
        guard !batch.isEmpty else { return }
        if let cutoff = batch.clearedAt { log.clear(at: cutoff) }
        log.apply(signals: batch.signals, text: batch.text, slotDecodes: batch.slotDecodes, now: now)
        apply(signals: batch.signals)
    }

    /// The updates from `takeEngineUpdates` were applied, and the engine is now in `epoch`.
    mutating func commandsSent(inEpoch epoch: UInt64) {
        if stampCursorEpoch {
            cursorEpoch = epoch
            stampCursorEpoch = false
        }
        observeEpoch(epoch)
    }

    /// The engine is in `epoch`: a cursor locked in an older one was unlocked by a reset.
    mutating func observeEpoch(_ epoch: UInt64) {
        guard cursorExpected, !stampCursorEpoch, let c = cursorEpoch, c < epoch else { return }
        dropCursor()
    }

    /// Follows the engine's cursor in a snapshot (nil: none this time).
    mutating func apply(signals: [SignalSnapshot]?) {
        guard cursorExpected, let s = signals?.first(where: { $0.isCursor }) else { return }
        if case .lock(let hz) = cursorWait, abs(s.frequencyHz - hz) > Self.lockAcceptHz { return }
        cursorWait = .none
        cursorAudioHz = s.frequencyHz
    }

    private mutating func queueCursorCommand(_ c: ModemCommand) {
        commands.append(c)
        stampCursorEpoch = true
    }

    private mutating func dropCursor() {
        cursorAudioHz = nil
        cursorExpected = false
        cursorWait = .none
        cursorEpoch = nil
        stampCursorEpoch = false
    }
}
