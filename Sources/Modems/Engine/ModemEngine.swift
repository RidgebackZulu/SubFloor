import Accelerate
import DSPCore
import Foundation
import simd

/// What one `ModemEngine.process` call produced.
public struct ModemOutput: Sendable {
    /// New text since the previous call, at most one entry per signal key, in no particular order.
    public var text: [DecodedText]
    /// Every tracked signal (plus an untracked cursor), non-nil at most every 0.5 s of audio, and on
    /// the first call after `resetForBoxMove()` (then empty).
    public var signals: [SignalSnapshot]?
    /// 12 kHz audio for the speakers, one sample per input sample.
    public var listenAudio: [Float]
    /// The cursor bench, non-nil at most every 1/30 s of audio while the cursor is locked.
    public var cursor: CursorFrame?

    public init(text: [DecodedText] = [], signals: [SignalSnapshot]? = nil, listenAudio: [Float] = [],
                cursor: CursorFrame? = nil) {
        self.text = text
        self.signals = signals
        self.listenAudio = listenAudio
        self.cursor = cursor
    }
}

/// The headless multi-signal modem: tracker, per-signal streaming decoders, auto-detect, cursor and
/// listen audio, for the 12 kHz audio of one modem box.
///
/// **Signals and keys.** Every signal the `SignalTracker` follows is reported under its track id
/// (positive, never reused). A cursor locked where there is no track gets a provisional key
/// (negative, never reused) until a track appears within its lock range: the cursor then binds to
/// that track and its decoder carries on under the track's id. A decoder's text is only ever
/// reported under its own signal's key, and a decoder never moves to another signal.
///
/// **Decoder assignment** (re-evaluated every 2048 samples, and before a call after a command or a
/// settings change):
/// - Mode off (`settings.mode == nil`): no decoders, no classification; the tracker keeps running.
/// - Auto-detect off: every track gets the selected streaming mode. A slot mode runs no streaming
///   decoders (the slot recorder handles it).
/// - Auto-detect on: each track is classified once it has been seen for 2 s (retried every 2 s while
///   unclassified, re-classified every 10 s while active, at most 2 per step), from the box audio
///   since 6 s before it was first seen (at most 16 s), and gets a decoder of its classified
///   streaming mode; unknown and slot-mode signals get none. The selected mode is the cursor's
///   fallback while its signal is unclassified. A classification only replaces a known mode when two
///   in a row agree on the new one, and "unknown" never clears a known mode.
/// - Priority: the cursor first, always (even with no track: it decodes at its locked frequency),
///   then by SNR, up to `maxDecoders` in all. Hysteresis keeps decoders from thrashing: a signal
///   that has a decoder counts 3 dB stronger, a decoder younger than 5 s is only displaced by the
///   cursor, and quiet tracks rank below every active one.
/// - A new decoder is primed with the box audio since 1.5 s before its track was first seen (at most
///   16 s), so a signal's text is complete from the start even though classification takes 2 s. At
///   most 16 s of priming audio is decoded per 2048-sample step (the cursor's is never deferred);
///   other new decoders wait for the next step.
/// - Decoders are created at their track's frequency and follow it with their own AFC. When the track
///   drifts beyond half the mode's lock range from where its decoder started, a successor decoder is
///   started at the new frequency (primed with the last 3 s) and runs alongside, its text unreported
///   (it repeats the current decoder's). It takes over once its last 6 live characters match the
///   current decoder's (both locked on the same signal), or regardless when the drift reaches 90% of
///   the lock range.
/// - A removed track's decoder is dropped.
///
/// **Listen audio.** With the cursor locked and `audioWide` off: the cursor signal through a
/// `listenWidthHz` band-pass (complex shift, filter, shift back), with the width of the cursor's
/// decoding mode, its classified mode, or the fallback mode. Otherwise the raw box audio. Switching
/// cross-fades over 20 ms.
///
/// **Time.** `process` takes the UTC time of each block's first sample when the caller knows it;
/// the classifier's FT8 slot check uses it.
///
/// **Slots.** Every timed block also goes to a `SlotRecorder` (150 s of audio). A block without a
/// time, a jump in `sampleIndex` and `resetForBoxMove()` are gaps to it, so a slot spanning one is
/// skipped, never decoded partially. `dueSlotJobs(now:)` returns the slots that are complete, for
/// the slot modes wanted: none unless `slotModesEnabled` and a mode is selected; with auto-detect
/// on, every slot mode (FT8 and WSPR decode every slot regardless); with it off, the selected mode if
/// it is a slot mode. A mode not wanted at the previous call starts with the slot in progress, so
/// switching to it never returns a backlog of old slots.
///
/// **Chunk size.** The engine splits its input at the tracker's 2048-sample frame boundaries and
/// makes every decision there, so the decoders, the tracks and the text do not depend on how the
/// caller chunks the audio (commands and settings changes take effect at the next call).
///
/// Not thread-safe: confine an instance to one thread (the modem thread).
public final class ModemEngine {
    // MARK: Constants

    /// Box audio kept for classification and decoder priming.
    public static let historySeconds = 16.0
    /// Box audio kept for slot decoding: a WSPR slot plus margin.
    public static let slotRetainSeconds = 150.0
    /// Decisions are made every `stepSamples` (the tracker's hop).
    static let stepSamples = 2_048
    static let signalsIntervalSeconds = 0.5
    static let cursorIntervalSeconds = 1.0 / 30
    static let classifyAfterSeconds = 2.0
    static let reclassifySeconds = 10.0
    static let retryClassifySeconds = 2.0
    static let classificationsPerStep = 2
    /// The classifier capture starts this long before a track was first seen, so that an FT8 onset is
    /// in it (measured: the tracker first sees an FT8-like signal 1.7 to 5.1 s after its onset).
    static let captureLeadSeconds = 6.0
    static let primeLeadSeconds = 1.5
    static let provisionalPrimeSeconds = 2.0
    static let successorPrimeSeconds = 3.0
    static let primeBudgetSeconds = 16.0
    static let incumbentBonusDb: Float = 3
    static let tenureSeconds = 5.0
    static let quietPenaltyDb: Float = 1_000
    static let protectedBonusDb: Float = 10_000
    static let handoverStart = 0.5
    static let handoverForce = 0.9
    static let agreementHz = 3.0
    /// A successor takes over once its last this many live characters match the current decoder's.
    static let agreementCharacters = 6
    /// Snap range for a cursor click when no mode gives one (spec: ±25 Hz).
    static let defaultLockRangeHz = 25.0
    static let crossfadeSamples = 240

    // MARK: Public state

    public let sampleRate: Double
    public let maxDecoders: Int

    public var settings: ModemSettings {
        didSet {
            guard settings != oldValue else { return }
            if settings.mode == nil { unlockCursor() }
            if settings.mode != oldValue.mode || settings.autoDetect != oldValue.autoDetect { dirty = true }
        }
    }

    /// The key the cursor's signal is reported under: its track id, or a provisional (negative) key
    /// while no track is at the cursor. Nil when unlocked.
    public var cursorTrackID: Int? { cursor?.key }

    // MARK: Private state

    private let tracker: SignalTracker
    private let analyzer: CursorAnalyzer
    private let listen: ListenFilter
    let slotRecorder: SlotRecorder

    private struct Cursor {
        var key: Int
        /// Bound track; nil while provisional.
        var trackID: Int?
        var frequencyHz: Double
    }

    private var cursor: Cursor?
    private var nextProvisionalKey = -1

    private final class Slot {
        var key: Int
        let mode: ModeID
        var decoder: any SignalDecoder
        var originHz: Double
        let createdAt: Int
        var successor: (any SignalDecoder)?
        var successorOriginHz = 0.0
        /// Live text of the current decoder and of its successor since the successor started.
        var currentText = ""
        var successorText = ""

        init(key: Int, mode: ModeID, decoder: any SignalDecoder, originHz: Double, createdAt: Int) {
            self.key = key
            self.mode = mode
            self.decoder = decoder
            self.originHz = originHz
            self.createdAt = createdAt
        }
    }

    /// In creation order (deterministic iteration).
    private var slots: [Slot] = []
    /// Per key, the mode of its last dropped decoder and the position up to which that decoder had
    /// decoded: a new decoder in the same mode primes only from there, so no text is reported twice.
    private var covered: [Int: (mode: ModeID, until: Int)] = [:]

    private struct ClassState {
        var classification: Classification?
        var lastAttempt: Int
        var pendingMode: ModeID?
    }

    private var classes: [Int: ClassState] = [:]

    /// Box audio history, indexed by absolute sample position modulo its size.
    private var history: [Float]
    private var capture: [Float] = []
    /// Samples processed since the last reset (the tracker's `samplesSeen`).
    private var position = 0
    private var dirty = false
    private var forceSignals = true
    private var lastSignalsAt: Int?
    private var lastCursorFrameAt: Int?
    private var timeAnchor: (position: Int, time: Date)?
    private var nextSampleIndex: Int?

    // Listen path.
    private var narrowGain: Float = 0
    private var listenWidthHz = 0.0
    private var narrowScratch: [Float]

    // Per-call output.
    private var textOut: [DecodedText] = []
    private var snrCache: (step: Int, hz: Double, snr: Float)?

    // Diagnostics (tests).
    private(set) var decodersCreated = 0
    private(set) var classificationsRun = 0
    private(set) var gaps = 0

    // MARK: Init

    public init(sampleRate: Double = 12_000, maxDecoders: Int = 40) {
        precondition(maxDecoders >= 1, "the cursor always needs a decoder")
        self.sampleRate = sampleRate
        self.maxDecoders = maxDecoders
        settings = ModemSettings()
        tracker = SignalTracker(sampleRate: sampleRate)
        analyzer = CursorAnalyzer(sampleRate: sampleRate)
        listen = ListenFilter(sampleRate: sampleRate)
        slotRecorder = SlotRecorder(sampleRate: sampleRate, retainSeconds: Self.slotRetainSeconds)
        history = .init(repeating: 0, count: Int(Self.historySeconds * sampleRate) + Self.stepSamples)
        narrowScratch = .init(repeating: 0, count: Self.stepSamples)
    }

    // MARK: Commands

    /// Locks the cursor at `hz`: on the nearest track within its mode's lock range, else (ruling R8)
    /// on the strongest not-yet-confirmed signal within the selected mode's lock range, else at
    /// exactly `hz`.
    public func lockCursor(atAudioHz hz: Double) {
        unlockCursor()
        let candidates = tracker.tracks.filter { abs($0.frequencyHz - hz) <= lockRange(forTrack: $0.id) }
        if let t = candidates.min(by: { abs($0.frequencyHz - hz) < abs($1.frequencyHz - hz) }) {
            cursor = Cursor(key: t.id, trackID: t.id, frequencyHz: slot(t.id)?.decoder.frequencyHz ?? t.frequencyHz)
        } else {
            let range = settings.mode?.lockRangeHz ?? Self.defaultLockRangeHz
            let f = tracker.strongestPeak(near: hz, within: range) ?? hz
            cursor = Cursor(key: nextProvisionalKey, trackID: nil, frequencyHz: f)
            nextProvisionalKey -= 1
        }
        analyzer.reset()
        dirty = true
    }

    public func unlockCursor() {
        guard let c = cursor else { return }
        cursor = nil
        if c.trackID == nil { dropSlot(c.key) }
        dirty = true
    }

    /// Moves the cursor to the next track up (`direction > 0`) or down (`< 0`) in frequency, quiet
    /// tracks included. Unlocked, it goes to the lowest (up) or highest (down) track. At either end
    /// it stays put (no wrap-around: a jump across the whole box is never what an arrow key means).
    public func nudgeCursor(_ direction: Int) {
        guard direction != 0 else { return }
        let tracks = tracker.tracks.sorted { $0.frequencyHz < $1.frequencyHz }
        let target: Track?
        if let c = cursor {
            let f = c.trackID.flatMap { id in tracks.first { $0.id == id }?.frequencyHz } ?? c.frequencyHz
            target = direction > 0
                ? tracks.first { $0.frequencyHz > f && $0.id != c.trackID }
                : tracks.last { $0.frequencyHz < f && $0.id != c.trackID }
        } else {
            target = direction > 0 ? tracks.first : tracks.last
        }
        guard let t = target else { return }
        unlockCursor()
        cursor = Cursor(key: t.id, trackID: t.id, frequencyHz: slot(t.id)?.decoder.frequencyHz ?? t.frequencyHz)
        analyzer.reset()
        dirty = true
    }

    /// Clears tracks, decoders, classifications, the cursor and all audio history (the box moved),
    /// slot audio included: no slot that started before the move is ever returned. Keys keep
    /// increasing, so nothing decoded before can be reported under a later signal; the next output's
    /// `signals` is empty.
    public func resetForBoxMove() {
        tracker.reset()
        slotRecorder.reset()
        slots.removeAll()
        covered.removeAll()
        classes.removeAll()
        cursor = nil
        position = 0
        for i in history.indices { history[i] = 0 }
        analyzer.reset()
        listen.reset()
        narrowGain = 0
        timeAnchor = nil
        nextSampleIndex = nil
        textOut.removeAll()
        snrCache = nil
        forceSignals = true
        lastSignalsAt = nil
        lastCursorFrameAt = nil
        dirty = false
    }

    // MARK: Processing

    /// Consumes box audio. `sampleIndex` is the index of `audio[0]` in the caller's box-audio stream
    /// (a jump marks lost audio; the streaming decoders simply carry on). `firstSampleTime` is the UTC
    /// time of `audio[0]`, when known; the block goes to the slot recorder with it (without it, it is
    /// a gap there).
    public func process(_ audio: UnsafeBufferPointer<Float>, sampleIndex: Int, firstSampleTime: Date? = nil) -> ModemOutput {
        if let expected = nextSampleIndex, sampleIndex != expected {
            gaps += 1
            slotRecorder.markGap()
        }
        nextSampleIndex = sampleIndex + audio.count
        if let t = firstSampleTime {
            timeAnchor = (position, t)
            appendSlotAudio(audio, firstSampleTime: t)
        } else if !audio.isEmpty {
            slotRecorder.markGap()
        }
        textOut.removeAll(keepingCapacity: true)
        var listenAudio = [Float](repeating: 0, count: audio.count)
        if dirty { manage() }

        var i = 0
        while i < audio.count {
            let take = min(audio.count - i, Self.stepSamples - position % Self.stepSamples)
            let block = UnsafeBufferPointer(rebasing: audio[i..<(i + take)])
            processBlock(block, listenInto: &listenAudio, at: i)
            position += take
            i += take
            if position % Self.stepSamples == 0 { manage() }
        }

        var out = ModemOutput(text: textOut, listenAudio: listenAudio)
        if forceSignals || lastSignalsAt.map({ position - $0 >= Int(Self.signalsIntervalSeconds * sampleRate) }) ?? true {
            out.signals = snapshots()
            lastSignalsAt = position
            forceSignals = false
        }
        if cursor != nil, lastCursorFrameAt.map({ position - $0 >= Int(Self.cursorIntervalSeconds * sampleRate) }) ?? true {
            out.cursor = cursorFrame()
            lastCursorFrameAt = position
        }
        return out
    }

    // MARK: Slots

    /// Records box audio for the slot modes; `process` calls it for every timed block, so call it
    /// directly only for audio that does not go through `process`.
    public func appendSlotAudio(_ audio: UnsafeBufferPointer<Float>, firstSampleTime: Date) {
        slotRecorder.append(audio, firstSampleTime: firstSampleTime)
    }

    /// The complete slots due at `now` for the slot modes the settings want (see **Slots** above),
    /// each returned once. Decode them off the modem thread (`SlotJob.decode`).
    public func dueSlotJobs(now: Date) -> [SlotJob] {
        slotRecorder.dueSlots(modes: wantedSlotModes(), now: now)
    }

    func wantedSlotModes() -> [any SlotModem.Type] {
        guard settings.slotModesEnabled, let mode = settings.mode else { return [] }
        if settings.autoDetect { return ModemCatalog.slot }
        return mode.isSlotMode ? ModemCatalog.slot.filter { $0.id == mode } : []
    }

    private func processBlock(_ block: UnsafeBufferPointer<Float>, listenInto listenAudio: inout [Float], at offset: Int) {
        // History.
        var w = position % history.count
        for x in block {
            history[w] = x
            w += 1
            if w == history.count { w = 0 }
        }
        tracker.process(block)

        for s in slots {
            let text = s.decoder.process(block)
            emit(text, key: s.key)
            if let next = s.successor {
                s.currentText += text
                s.successorText += next.process(block)
                // Only the tails are compared.
                if s.currentText.count > 64 { s.currentText = String(s.currentText.suffix(Self.agreementCharacters)) }
                if s.successorText.count > 64 { s.successorText = String(s.successorText.suffix(Self.agreementCharacters)) }
            }
        }

        // Listen audio and the bench.
        let n = block.count
        if let c = cursor {
            let width = listenWidth()
            if width != listenWidthHz {
                listen.configure(widthHz: width)
                listenWidthHz = width
            }
            analyzer.retune(c.frequencyHz)
        }
        let narrowWanted = cursor != nil && !settings.audioWide
        if cursor != nil || narrowGain > 0 {
            narrowScratch.withUnsafeMutableBufferPointer { nb in
                listen.process(block, centerHz: cursor?.frequencyHz ?? listen.centerHz,
                               into: UnsafeMutableBufferPointer(rebasing: nb[0..<n]))
            }
            if cursor != nil {
                narrowScratch.withUnsafeBufferPointer { analyzer.process(box: block, narrow: UnsafeBufferPointer(rebasing: $0[0..<n])) }
            }
        }
        let step = 1 / Float(Self.crossfadeSamples)
        for k in 0..<n {
            if narrowWanted { narrowGain = min(1, narrowGain + step) } else { narrowGain = max(0, narrowGain - step) }
            let raw = block[k]
            listenAudio[offset + k] = narrowGain == 0 ? raw : narrowGain * narrowScratch[k] + (1 - narrowGain) * raw
        }
        if cursor == nil && narrowGain == 0 && listenWidthHz != 0 {
            // Fully faded back to wide: the filter restarts clean on the next lock.
            listen.reset()
            listenWidthHz = 0
        }
    }

    private func emit(_ text: String, key: Int) {
        guard !text.isEmpty else { return }
        if let i = textOut.firstIndex(where: { $0.trackID == key }) {
            textOut[i].text += text
        } else {
            textOut.append(DecodedText(trackID: key, text: text))
        }
    }

    // MARK: Management

    private func manage() {
        dirty = false
        let tracks = tracker.tracks
        var byID: [Int: Track] = [:]
        for t in tracks { byID[t.id] = t }

        // Forget removed tracks.
        for s in slots where s.key > 0 && byID[s.key] == nil { dropSlot(s.key) }
        classes = classes.filter { byID[$0.key] != nil }
        covered = covered.filter { $0.key < 0 ? $0.key == cursor?.key : byID[$0.key] != nil }

        updateCursor(byID)
        if settings.autoDetect, settings.mode != nil { runClassifications(tracks) }
        handovers(byID)
        allocate(tracks)
        if let c = cursor, let s = slot(c.key) { cursor?.frequencyHz = s.decoder.frequencyHz }
    }

    /// Keeps the cursor on its signal: follows its track, rebinds when the track merged away or was
    /// removed, and binds a provisional cursor to a track that appeared at it.
    private func updateCursor(_ byID: [Int: Track]) {
        guard var c = cursor else { return }
        if let id = c.trackID, let t = byID[id] {
            c.frequencyHz = slot(id)?.decoder.frequencyHz ?? t.frequencyHz
            cursor = c
            return
        }
        let range = lockRange(forMode: cursorMode())
        let nearest = byID.values
            .filter { abs($0.frequencyHz - c.frequencyHz) <= range }
            .min { (abs($0.frequencyHz - c.frequencyHz), $0.id) < (abs($1.frequencyHz - c.frequencyHz), $1.id) }
        if let t = nearest {
            if c.trackID == nil, let s = slot(c.key) {
                // Adoption: the provisional decoder carries on as the track's, unless it has one.
                if slot(t.id) == nil { s.key = t.id } else { dropSlot(c.key) }
            }
            c = Cursor(key: t.id, trackID: t.id, frequencyHz: slot(t.id)?.decoder.frequencyHz ?? t.frequencyHz)
        } else if c.trackID != nil {
            // The track is gone: carry on, provisionally, where it was.
            c = Cursor(key: nextProvisionalKey, trackID: nil, frequencyHz: c.frequencyHz)
            nextProvisionalKey -= 1
        }
        cursor = c
    }

    private func runClassifications(_ tracks: [Track]) {
        let after = Int(Self.classifyAfterSeconds * sampleRate)
        let retry = Int(Self.retryClassifySeconds * sampleRate)
        let again = Int(Self.reclassifySeconds * sampleRate)
        let due = tracks.filter { t in
            guard !t.isQuiet, position - t.firstSeenSample >= after else { return false }
            guard let st = classes[t.id] else { return true }
            guard t.lastActiveSample > st.lastAttempt else { return false }
            let wait = st.classification?.mode == nil ? retry : again
            return position - st.lastAttempt >= wait
        }
        let cursorTrack = cursor?.trackID
        let ordered = due.sorted { a, b in
            let ka = (a.id == cursorTrack ? 0 : 1, classes[a.id]?.lastAttempt ?? Int.min, a.id)
            let kb = (b.id == cursorTrack ? 0 : 1, classes[b.id]?.lastAttempt ?? Int.min, b.id)
            return ka < kb
        }
        for t in ordered.prefix(Self.classificationsPerStep) { classify(t) }
    }

    private func classify(_ t: Track) {
        let lead = Int(Self.captureLeadSeconds * sampleRate)
        let start = max(t.firstSeenSample - lead, position - Int(Self.historySeconds * sampleRate), 0)
        let count = position - start
        guard count >= Int(Self.classifyAfterSeconds * sampleRate) else { return }
        copyHistory(from: start, count: count, into: &capture)
        let result = SignalClassifier.classify(track: t, audio: capture[0..<count], sampleRate: sampleRate,
                                               utcSecondOfMinute: utcSecondOfMinute(at: start))
        classificationsRun += 1
        var st = classes[t.id] ?? ClassState(classification: nil, lastAttempt: position, pendingMode: nil)
        st.lastAttempt = position
        if let known = st.classification?.mode {
            if result.mode == known {
                st.classification = result
                st.pendingMode = nil
            } else if let m = result.mode {
                if st.pendingMode == m {
                    st.classification = result
                    st.pendingMode = nil
                } else {
                    st.pendingMode = m
                }
            }
        } else {
            st.classification = result
        }
        classes[t.id] = st
    }

    /// Starts and completes successor decoders for drifting signals.
    private func handovers(_ byID: [Int: Track]) {
        for s in slots {
            let range = s.mode.lockRangeHz
            let reference = byID[s.key]?.frequencyHz ?? s.decoder.frequencyHz
            if s.successor == nil {
                guard abs(reference - s.originHz) > Self.handoverStart * range else { continue }
                // The decoder's own AFC estimate is the more precise when it agrees with the track.
                let current = s.decoder.frequencyHz
                let hz = abs(current - reference) <= Self.agreementHz ? current : reference
                let d = makeDecoder(s.mode, at: hz)
                prime(d, from: position - Int(Self.successorPrimeSeconds * sampleRate)) { _ in }
                s.successor = d
                s.successorOriginHz = hz
                // Its primed text repeats what the current decoder already reported; only live text counts.
                s.currentText = ""
                s.successorText = ""
            }
            guard let next = s.successor else { continue }
            let agreed = s.successorText.count >= Self.agreementCharacters
                && s.successorText.suffix(Self.agreementCharacters) == s.currentText.suffix(Self.agreementCharacters)
            if agreed || abs(reference - s.originHz) > Self.handoverForce * range {
                s.decoder = next
                s.originHz = s.successorOriginHz
                s.successor = nil
                s.currentText = ""
                s.successorText = ""
            }
        }
    }

    /// Assigns decoders: the cursor first, then by SNR with hysteresis, up to `maxDecoders`.
    private func allocate(_ tracks: [Track]) {
        let cursorKey = cursor?.key
        // Decoders in the wrong mode (or none wanted) go.
        for s in slots {
            let wanted = s.key == cursorKey ? cursorMode() : tracks.first { $0.id == s.key }.flatMap { trackMode($0) }
            if wanted != s.mode { dropSlot(s.key) }
        }
        var budget = Int(Self.primeBudgetSeconds * sampleRate)
        var capacity = maxDecoders
        if let key = cursorKey, let mode = cursorMode() {
            if slot(key) == nil {
                let start = cursor?.trackID.flatMap { id in tracks.first { $0.id == id } }.map(primeStart)
                    ?? position - Int(Self.provisionalPrimeSeconds * sampleRate)
                createSlot(key: key, mode: mode, at: cursor!.frequencyHz, primeFrom: start, budget: &budget)
            }
            capacity -= 1
        }

        let tenure = Int(Self.tenureSeconds * sampleRate)
        var ranked: [(score: Float, track: Track, mode: ModeID)] = []
        for t in tracks where t.id != cursorKey {
            guard let mode = trackMode(t) else { continue }
            var score = t.snrDb
            if let s = slot(t.id) {
                score += Self.incumbentBonusDb
                if position - s.createdAt < tenure { score += Self.protectedBonusDb }
            }
            if t.isQuiet { score -= Self.quietPenaltyDb }
            ranked.append((score, t, mode))
        }
        ranked.sort { $0.score != $1.score ? $0.score > $1.score : $0.track.id < $1.track.id }
        let keep = ranked.prefix(max(capacity, 0))
        let keepIDs = Set(keep.map(\.track.id))
        for s in slots where s.key != cursorKey && !keepIDs.contains(s.key) { dropSlot(s.key) }
        for r in keep where slot(r.track.id) == nil {
            guard budget > 0 else { break }
            createSlot(key: r.track.id, mode: r.mode, at: r.track.frequencyHz, primeFrom: primeStart(r.track),
                       budget: &budget)
        }
    }

    private func primeStart(_ t: Track) -> Int {
        t.firstSeenSample - Int(Self.primeLeadSeconds * sampleRate)
    }

    private func createSlot(key: Int, mode: ModeID, at hz: Double, primeFrom requested: Int, budget: inout Int) {
        var start = requested
        if let c = covered[key], c.mode == mode { start = max(start, c.until) }
        let d = makeDecoder(mode, at: hz)
        let s = Slot(key: key, mode: mode, decoder: d, originHz: hz, createdAt: position)
        slots.append(s)
        budget -= prime(d, from: start) { self.emit($0, key: key) }
    }

    private func makeDecoder(_ mode: ModeID, at hz: Double) -> any SignalDecoder {
        decodersCreated += 1
        return ModemCatalog.streaming(mode)!.makeDecoder(frequencyHz: hz, sampleRate: sampleRate)
    }

    /// Feeds `d` the history from `start` (clamped to what is kept) to now; returns the samples fed.
    @discardableResult
    private func prime(_ d: any SignalDecoder, from start: Int, text: (String) -> Void) -> Int {
        let first = max(start, position - Int(Self.historySeconds * sampleRate), 0)
        var a = first
        while a < position {
            let at = a % history.count
            let n = min(position - a, history.count - at, 4_096)
            history.withUnsafeBufferPointer { h in text(d.process(UnsafeBufferPointer(rebasing: h[at..<(at + n)]))) }
            a += n
        }
        return position - first
    }

    private func dropSlot(_ key: Int) {
        guard let i = slots.firstIndex(where: { $0.key == key }) else { return }
        covered[key] = (slots[i].mode, position)
        slots.remove(at: i)
    }

    private func slot(_ key: Int) -> Slot? { slots.first { $0.key == key } }

    // MARK: Modes

    /// The streaming mode a (non-cursor) track should be decoded in, or nil for none.
    private func trackMode(_ t: Track) -> ModeID? {
        guard let selected = settings.mode else { return nil }
        if !settings.autoDetect { return selected.isSlotMode ? nil : selected }
        guard let m = classes[t.id]?.classification?.mode, !m.isSlotMode else { return nil }
        return m
    }

    /// The streaming mode for the cursor's signal: its classified mode, else the fallback.
    private func cursorMode() -> ModeID? {
        guard let c = cursor, let selected = settings.mode else { return nil }
        let fallback = selected.isSlotMode ? nil : selected
        guard settings.autoDetect, let id = c.trackID, let m = classes[id]?.classification?.mode else { return fallback }
        return m.isSlotMode ? nil : m
    }

    /// The mode shown for a signal: its decoder's, else its classification's (slot modes included),
    /// else the streaming mode it would be decoded in (the selected mode with auto-detect off, the
    /// fallback for the cursor).
    private func displayMode(key: Int) -> ModeID? {
        if let s = slot(key) { return s.mode }
        if settings.autoDetect, let m = classes[key]?.classification?.mode { return m }
        guard let selected = settings.mode, !selected.isSlotMode else { return nil }
        return !settings.autoDetect || key == cursor?.key ? selected : nil
    }

    private func lockRange(forTrack id: Int) -> Double {
        lockRange(forMode: displayMode(key: id) ?? settings.mode)
    }

    private func lockRange(forMode mode: ModeID?) -> Double {
        mode?.lockRangeHz ?? Self.defaultLockRangeHz
    }

    private func listenWidth() -> Double {
        guard let c = cursor else { return 0 }
        let mode = slot(c.key)?.mode ?? displayMode(key: c.key) ?? settings.mode
        return (mode ?? .cw).listenWidthHz
    }

    // MARK: Output

    private func snapshots() -> [SignalSnapshot] {
        var out: [SignalSnapshot] = []
        for t in tracker.tracks {
            let s = slot(t.id)
            out.append(SignalSnapshot(id: t.id, frequencyHz: t.frequencyHz, snrDb: t.snrDb, mode: displayMode(key: t.id),
                                      submode: s?.decoder.submode ?? classes[t.id]?.classification?.submode ?? "",
                                      isQuiet: t.isQuiet, isCursor: t.id == cursor?.key))
        }
        if let c = cursor, c.trackID == nil {
            out.append(SignalSnapshot(id: c.key, frequencyHz: c.frequencyHz, snrDb: estimatedSNR(at: c.frequencyHz),
                                      mode: displayMode(key: c.key), submode: slot(c.key)?.decoder.submode ?? "",
                                      isQuiet: false, isCursor: true))
        }
        return out
    }

    private func cursorFrame() -> CursorFrame? {
        guard let c = cursor else { return nil }
        let s = slot(c.key)
        let track = c.trackID.flatMap { id in tracker.tracks.first { $0.id == id } }
        let mode = s?.mode ?? displayMode(key: c.key)
        let submode = s?.decoder.submode ?? c.trackID.flatMap { classes[$0]?.classification?.submode } ?? mode?.label ?? ""
        return analyzer.frame(frequencyHz: c.frequencyHz, snrDb: track?.snrDb ?? estimatedSNR(at: c.frequencyHz),
                              submode: submode, symbolRate: mode.flatMap(Self.symbolRate),
                              constellation: s?.decoder.constellation() ?? [])
    }

    static func symbolRate(_ mode: ModeID) -> Double? {
        switch mode {
        case .psk31: 31.25
        case .rtty: 45.45
        case .ft8: 6.25
        case .wspr: 12_000.0 / 8_192
        case .cw: nil
        }
    }

    /// SNR (2.5 kHz noise bandwidth) of whatever lies within the listen width around `hz`, from the
    /// tracker's averaged spectrum and noise floor: for a cursor with no track. Cached per step.
    private func estimatedSNR(at hz: Double) -> Float {
        let step = position / Self.stepSamples
        if let c = snrCache, c.step == step, c.hz == hz { return c.snr }
        let snr = measureSNR(at: hz)
        snrCache = (step, hz, snr)
        return snr
    }

    private func measureSNR(at hz: Double) -> Float {
        let spectrum = tracker.averagedSpectrumDb
        let floor = tracker.noiseFloor
        let bin = tracker.binHz
        let half = max(listenWidth(), ModeID.cw.listenWidthHz) / 2
        let lo = max(1, Int(((hz - half) / bin).rounded(.down)))
        let hi = min(spectrum.count - 1, Int(((hz + half) / bin).rounded(.up)))
        guard lo <= hi else { return -.infinity }
        var excess = 0.0, noise = 0.0
        for k in lo...hi {
            let p = pow(10, Double(spectrum[k]) / 10)
            excess += max(p - Double(floor[k]), 0)
            noise += Double(floor[k])
        }
        noise /= Double(hi - lo + 1)
        guard noise > 0 else { return -.infinity }
        return Float(10 * log10(max(excess, 1e-30) / (noise * 2_500 / bin)))
    }

    // MARK: History and time

    private func copyHistory(from start: Int, count: Int, into out: inout [Float]) {
        if out.count < count { out = .init(repeating: 0, count: count) }
        for k in 0..<count { out[k] = history[(start + k) % history.count] }
    }

    private func utcSecondOfMinute(at sample: Int) -> Double? {
        guard let a = timeAnchor else { return nil }
        let t = a.time.timeIntervalSince1970 + Double(sample - a.position) / sampleRate
        let s = t.truncatingRemainder(dividingBy: 60)
        return s < 0 ? s + 60 : s
    }

    // MARK: Test access

    /// Keys of the signals that have a decoder, in creation order.
    var decoderKeys: [Int] { slots.map(\.key) }

    func decoderMode(_ key: Int) -> ModeID? { slot(key)?.mode }

    func classification(ofTrack id: Int) -> Classification? { classes[id]?.classification }

    var currentTracks: [Track] { tracker.tracks }
}

/// The narrow listen filter: shift the cursor to 0 Hz, low-pass to ±width/2 while decimating to
/// 1 kHz, interpolate back to the audio rate, shift back up and take the real part. The decimating
/// filter (Blackman-Harris, −6 dB at ±width/2, transition width/2, at most 1023 taps) is computed at
/// 1 kHz only, and the polyphase interpolator (12 phases of 11 taps, images from 800 Hz stopped) is
/// cheap, so the whole path costs a few percent of a single full-rate filter.
final class ListenFilter {
    let sampleRate: Double
    private(set) var centerHz = 0.0
    private let factor: Int
    private var widthHz = 250.0
    private var down = NCO()
    private var up = NCO()
    private var decimator: ComplexDecimator
    private let phases: [[Float]]
    private var recent: [SIMD2<Float>]
    private var recentHead = 0
    private var mix: [DSPComplex]
    private var baseband: [DSPComplex] = []
    /// Interpolated samples not yet output (fewer than `factor`).
    private var fifo: [SIMD2<Float>]
    private var fifoCount = 0
    private var upScratch: [DSPComplex]

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        let factor = max(1, Int((sampleRate / 1_000).rounded()))
        self.factor = factor
        let rate = sampleRate / Double(factor)
        decimator = Self.makeDecimator(sampleRate: sampleRate, factor: factor, widthHz: 250)
        // Interpolator prototype: passes ±200 Hz (the widest listen filter's half-width), stops the
        // images from rate − 200 Hz.
        let taps = FIRDesign.tapCount(transition: (rate - 400) / sampleRate)
        let perPhase = (taps + factor - 1) / factor
        var h = FIRDesign.lowpass(taps: taps, cutoff: 0.5 * rate / sampleRate)
        h += [Float](repeating: 0, count: perPhase * factor - h.count)
        let gain = Float(factor)
        phases = (0..<factor).map { p in (0..<perPhase).map { k in gain * h[p + factor * k] } }
        recent = .init(repeating: .zero, count: perPhase)
        mix = .init(repeating: DSPComplex(real: 0, imag: 0), count: ModemEngine.stepSamples)
        fifo = .init(repeating: .zero, count: factor)
        upScratch = .init(repeating: DSPComplex(real: 0, imag: 0), count: ModemEngine.stepSamples + 2 * factor)
    }

    private static func makeDecimator(sampleRate: Double, factor: Int, widthHz: Double) -> ComplexDecimator {
        let half = widthHz / 2
        let taps = FIRDesign.tapCount(transition: half / sampleRate)
        return ComplexDecimator(taps: FIRDesign.lowpass(taps: max(taps, factor), cutoff: half / sampleRate), factor: factor)
    }

    func configure(widthHz: Double) {
        self.widthHz = widthHz
        decimator = Self.makeDecimator(sampleRate: sampleRate, factor: factor, widthHz: widthHz)
    }

    func reset() {
        decimator = Self.makeDecimator(sampleRate: sampleRate, factor: factor, widthHz: widthHz)
        for i in recent.indices { recent[i] = .zero }
        recentHead = 0
        fifoCount = 0
        down = NCO(frequency: -centerHz, sampleRate: sampleRate)
        up = NCO(frequency: centerHz, sampleRate: sampleRate)
    }

    /// Filters `x` (at most `ModemEngine.stepSamples`) around `centerHz` into `out` (same count).
    func process(_ x: UnsafeBufferPointer<Float>, centerHz hz: Double, into out: UnsafeMutableBufferPointer<Float>) {
        let n = x.count
        precondition(n <= mix.count && out.count == n)
        if hz != centerHz {
            centerHz = hz
            down.setFrequency(-hz, sampleRate: sampleRate)
            up.setFrequency(hz, sampleRate: sampleRate)
        }
        for i in 0..<n { mix[i] = DSPComplex(real: x[i], imag: 0) }
        mix.withUnsafeMutableBufferPointer { down.mix(UnsafeMutableBufferPointer(rebasing: $0[0..<n])) }
        baseband.removeAll(keepingCapacity: true)
        mix.withUnsafeBufferPointer { decimator.process(UnsafeBufferPointer(rebasing: $0[0..<n]), into: &baseband) }

        // Leftover interpolated samples first, then `factor` per new baseband sample.
        var produced = 0
        for k in 0..<fifoCount { upScratch[produced] = DSPComplex(real: fifo[k].x, imag: fifo[k].y); produced += 1 }
        let size = recent.count
        for z in baseband {
            recent[recentHead] = SIMD2(z.real, z.imag)
            for p in 0..<factor {
                var acc = SIMD2<Float>.zero
                var idx = recentHead
                for c in phases[p] {
                    acc += c * recent[idx]
                    idx = idx == 0 ? size - 1 : idx - 1
                }
                upScratch[produced] = DSPComplex(real: acc.x, imag: acc.y)
                produced += 1
            }
            recentHead = (recentHead + 1) % size
        }
        // The decimator emits one sample per `factor` inputs from the first, so `produced` ≥ n.
        let used = min(n, produced)
        upScratch.withUnsafeMutableBufferPointer { up.mix(UnsafeMutableBufferPointer(rebasing: $0[0..<used])) }
        for i in 0..<used { out[i] = 2 * upScratch[i].real }
        for i in used..<n { out[i] = 0 }
        // A rebuilt decimator (`configure`) restarts its output phase, so it can emit one baseband
        // sample more than the input so far accounts for. Output is capped at the input count, so
        // that surplus would stay in the FIFO for good and pile up with every width change: drop it,
        // keeping the FIFO under `factor` samples (a skip of under 1 ms, during a filter change).
        let keep = min(produced - used, factor - 1)
        let skip = produced - used - keep
        fifoCount = keep
        for k in 0..<keep { fifo[k] = SIMD2(upScratch[used + skip + k].real, upScratch[used + skip + k].imag) }
    }
}
