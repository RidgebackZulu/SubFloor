import Foundation

/// One row of the modem panel: a tracked signal (live row) or one decoded FT8/WSPR message (slot row).
public struct DecodeRow: Identifiable, Sendable, Equatable {
    /// The signal's key for a live row: its track id, or the engine's provisional (negative) key for
    /// a cursor with no track. Slot rows use ids from `Int.min` upwards, which never meet either.
    public var id: Int
    /// Audio frequency: the track's centre; for a slot row the decoder's (FT8: tone 0, WSPR: centre).
    public var frequencyHz: Double
    public var mode: ModeID?
    public var submode: String
    public var snrDb: Float
    /// The last `DecodeLog.recentCharacters` characters of `history` (for the cursor row while slot
    /// messages claim it: those messages instead).
    public var recentText: String
    /// The last `DecodeLog.historyCharacters` characters decoded.
    public var history: String
    public var isQuiet: Bool
    public var isCursor: Bool
    /// The slot's start (UTC) for a slot row; nil for a live row.
    public var utcTime: Date?

    public init(id: Int, frequencyHz: Double, mode: ModeID?, submode: String, snrDb: Float, recentText: String,
                history: String, isQuiet: Bool, isCursor: Bool, utcTime: Date?) {
        self.id = id
        self.frequencyHz = frequencyHz
        self.mode = mode
        self.submode = submode
        self.snrDb = snrDb
        self.recentText = recentText
        self.history = history
        self.isQuiet = isQuiet
        self.isCursor = isCursor
        self.utcTime = utcTime
    }
}

/// The modem panel's rows, built from the engine's output (pure; the main thread owns it).
///
/// **Live rows** are the tracked signals: the cursor's row first, then the rest ascending by
/// frequency. A row's sort key is its frequency when it was inserted and never changes, so rows
/// never reorder while visible: a drifting signal keeps its place (showing its new frequency) until
/// it is removed and returns as a new track. Ties keep insertion order. The cursor's row is pinned
/// first while it is the cursor and returns to its own place afterwards.
///
/// **Snapshots.** `signals` nil means no snapshot this time (the engine sends one at most every
/// 0.5 s), and changes no row. A snapshot lists every signal: it inserts new rows, updates
/// frequency, SNR, mode, quiet and cursor of the others, and removes the rows it does not list (an
/// empty one removes them all). A quiet row stays in place, dimmed, until the tracker drops it.
///
/// **Text** goes to its key's row and is kept as the last 160 (`recentText`) and 4000 (`history`)
/// Characters, trimmed on grapheme-cluster boundaries. Text for a key with no row yet (text can
/// precede the first snapshot listing its signal by 0.5 s, and the engine's batches mix outputs) is
/// buffered and becomes the row's starting text when a snapshot lists the key; buffered text not
/// claimed within `pendingTextSeconds` of its last arrival is dropped (keys are never reused, so it
/// belonged to a signal that is gone). When a provisional cursor row disappears in the same
/// snapshot that inserts a new cursor row within `carryOverHz` of it, the engine has moved the
/// cursor's decoder to the track that appeared there; the provisional row's text moves to the new
/// row. (A cursor rebinding to a track that already had a row keeps that row's text alone.)
///
/// **Holding.** While `holdNew` is set (the pointer is over the list) new rows are held: kept and
/// fed text and snapshots like any row, but not shown, and counted by `heldNewCount`, until
/// `releaseHeld()` or `holdNew` is cleared. A row that unfolds while holding is held the same way.
/// The cursor's row is never held (a held row that becomes the cursor shows at once).
///
/// **Slot rows** are the FT8/WSPR messages, one per decode, newest slot first (then ascending
/// frequency), at most `maxSlotRows`. Each decode also *claims* its signal: a live track within
/// `claimToleranceHz` of the signal's centre (FT8 reports tone 0, so its centre is 3.5 tones higher;
/// WSPR reports its centre) is folded (hidden) until 3 slots plus `claimMarginSeconds` after the
/// slot's start. That covers a station's off slot and the decoding time of its next one, so a
/// signal transmitting every other slot stays folded throughout. The cursor's row is never folded:
/// while claimed it shows the claiming messages (`HHMMSS message` per line, oldest first, the
/// newest that fit in 160 characters) and their mode; its `history` keeps its own text.
///
/// **Clearing.** `clear(at:)` (the box moved) empties every row, held and buffered text included,
/// and from then on ignores slot decodes of slots that started before that time: a slot job running
/// when the box moved finishes later, and its messages are the old box's. (The engine never returns
/// a slot that started before `resetForBoxMove()`, so a valid decode always starts after the move.)
///
/// **Cost.** `apply` is O(rows + text + claims) per call (O(text) when there is no snapshot and no
/// slot decode or claim expiry): rows are found through an id index, rebuilt only when rows come or
/// go, and text is appended and trimmed in place with character counts kept incrementally.
public struct DecodeLog: Sendable {
    // MARK: Constants

    public static let recentCharacters = 160
    public static let historyCharacters = 4_000
    public static let maxSlotRows = 200
    /// A live track this close to a slot decode's signal centre is that signal.
    public static let claimToleranceHz = 10.0
    /// A claim lasts this long beyond 3 slots from its slot's start.
    public static let claimMarginSeconds = 10.0
    /// Buffered text for a key no snapshot lists is dropped this long after it last grew.
    public static let pendingTextSeconds = 5.0
    /// The widest lock range (RTTY's 30 Hz): how far a provisional cursor can bind to a track.
    static let carryOverHz = 30.0

    // MARK: Public state

    /// Set while the pointer is over the list: new rows wait (see **Holding**). Clearing it releases them.
    public var holdNew = false {
        didSet { if !holdNew { releaseHeld() } }
    }

    /// Held rows (not text) that `releaseHeld()` would show.
    public private(set) var heldNewCount = 0

    /// Newest slot first, at most `maxSlotRows`.
    public private(set) var slotRows: [DecodeRow] = []

    /// The cursor's row first, then the visible rows in their frozen order.
    public var liveRows: [DecodeRow] {
        var out: [DecodeRow] = []
        out.reserveCapacity(entries.count)
        for e in entries where e.row.isCursor { out.append(display(e)) }
        for e in entries where !e.row.isCursor && !e.isHeld && !e.isFolded { out.append(e.row) }
        return out
    }

    // MARK: Private state

    private struct Entry {
        var row: DecodeRow
        /// Frozen at insertion: the frequency then, and the insertion order.
        let sortHz: Double
        let sequence: Int
        var recentCount: Int
        var historyCount: Int
        var isHeld: Bool
        var isFolded = false
        /// The snapshot generation that last listed the row.
        var seen: Int
        /// While the row is the cursor and slot messages claim it: their text and mode.
        var claimText: String?
        var claimMode: ModeID?

        mutating func append(_ s: String) {
            DecodeLog.append(s, to: &row.recentText, count: &recentCount, limit: DecodeLog.recentCharacters)
            DecodeLog.append(s, to: &row.history, count: &historyCount, limit: DecodeLog.historyCharacters)
        }
    }

    /// Sorted by (`sortHz`, `sequence`).
    private var entries: [Entry] = []
    /// Row id → index in `entries`.
    private var index: [Int: Int] = [:]
    private var nextSequence = 0
    private var generation = 0

    private struct Pending {
        var text: String
        var count: Int
        var updated: Date
    }

    private var pending: [Int: Pending] = [:]

    private struct Claim {
        var centreHz: Double
        var until: Date
        var slotStart: Date
        var frequencyHz: Double
        var mode: ModeID
        var message: String
    }

    /// Sorted by `centreHz`.
    private var claims: [Claim] = []
    private var nextClaimExpiry: Date?
    private var slotCutoff = Date.distantPast
    private var slotSerial = 0

    public init() {}

    // MARK: Updates

    /// Applies one batch of engine output (see the type's notes). `now` is the current UTC time.
    public mutating func apply(signals: [SignalSnapshot]?, text: [DecodedText], slotDecodes: [SlotDecode], now: Date) {
        var claimsChanged = expireClaims(now: now)
        if !slotDecodes.isEmpty { claimsChanged = addSlotDecodes(slotDecodes, now: now) || claimsChanged }
        if let signals { applySnapshot(signals) }
        for t in text where !t.text.isEmpty { appendText(t.text, key: t.trackID, now: now) }
        expirePending(now: now)
        if signals != nil || claimsChanged {
            updateFolding()
            countHeld()
        }
    }

    /// Shows every held row.
    public mutating func releaseHeld() {
        for i in entries.indices where entries[i].isHeld { entries[i].isHeld = false }
        heldNewCount = 0
    }

    /// Removes every row, held and buffered text, and ignores slot decodes of slots that started
    /// before `now` from then on (the cutoff never moves back). `holdNew` is kept.
    public mutating func clear(at now: Date = Date()) {
        entries.removeAll(keepingCapacity: true)
        index.removeAll(keepingCapacity: true)
        pending.removeAll()
        slotRows.removeAll(keepingCapacity: true)
        claims.removeAll(keepingCapacity: true)
        nextClaimExpiry = nil
        heldNewCount = 0
        slotCutoff = max(slotCutoff, now)
    }

    /// The live row of a signal key, held or folded included, as `liveRows` would show it.
    public func row(forTrack id: Int) -> DecodeRow? {
        index[id].map { display(entries[$0]) }
    }

    // MARK: Snapshots

    private mutating func applySnapshot(_ signals: [SignalSnapshot]) {
        generation &+= 1
        let provisionalCursor = entries.first { $0.row.isCursor && $0.row.id < 0 }
        var newcomers: [SignalSnapshot] = []
        for s in signals {
            guard let i = index[s.id] else {
                if let k = newcomers.firstIndex(where: { $0.id == s.id }) { newcomers[k] = s } else { newcomers.append(s) }
                continue
            }
            entries[i].row.frequencyHz = s.frequencyHz
            entries[i].row.snrDb = s.snrDb
            entries[i].row.mode = s.mode
            entries[i].row.submode = s.submode
            entries[i].row.isQuiet = s.isQuiet
            entries[i].row.isCursor = s.isCursor
            if s.isCursor { entries[i].isHeld = false }
            entries[i].seen = generation
        }
        var changed = false
        var newCursor: Int?
        for s in newcomers {
            insert(s)
            changed = true
            if s.isCursor { newCursor = s.id }
        }
        let before = entries.count
        entries.removeAll { $0.seen != generation }
        if entries.count != before { changed = true }
        if changed { rebuildIndex() }

        // A provisional cursor whose decoder moved to the track that appeared at it.
        if let old = provisionalCursor, index[old.row.id] == nil, let id = newCursor, let i = index[id],
           abs(entries[i].row.frequencyHz - old.row.frequencyHz) <= Self.carryOverHz, !old.row.history.isEmpty {
            var history = old.row.history
            var count = old.historyCount
            Self.append(entries[i].row.history, to: &history, count: &count, limit: Self.historyCharacters)
            entries[i].row.history = history
            entries[i].historyCount = count
            (entries[i].row.recentText, entries[i].recentCount) = Self.recent(of: history, count: count)
        }
    }

    private mutating func insert(_ s: SignalSnapshot) {
        var history = ""
        var count = 0
        if let p = pending.removeValue(forKey: s.id) {
            history = p.text
            count = p.count
        }
        let (recent, recentCount) = Self.recent(of: history, count: count)
        let e = Entry(row: DecodeRow(id: s.id, frequencyHz: s.frequencyHz, mode: s.mode, submode: s.submode,
                                     snrDb: s.snrDb, recentText: recent, history: history, isQuiet: s.isQuiet,
                                     isCursor: s.isCursor, utcTime: nil),
                      sortHz: s.frequencyHz, sequence: nextSequence, recentCount: recentCount, historyCount: count,
                      isHeld: holdNew && !s.isCursor, seen: generation)
        nextSequence += 1
        // After every row with a key ≤ this one's (later sequences sort after equal frequencies).
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if entries[mid].sortHz <= e.sortHz { lo = mid + 1 } else { hi = mid }
        }
        entries.insert(e, at: lo)
    }

    private mutating func rebuildIndex() {
        index.removeAll(keepingCapacity: true)
        for (i, e) in entries.enumerated() { index[e.row.id] = i }
    }

    private mutating func countHeld() {
        var n = 0
        for e in entries where e.isHeld && !e.isFolded { n += 1 }
        heldNewCount = n
    }

    // MARK: Text

    private mutating func appendText(_ text: String, key: Int, now: Date) {
        if let i = index[key] {
            entries[i].append(text)
            return
        }
        // Taken out and put back so that its text is uniquely referenced while it grows.
        var p = pending.removeValue(forKey: key) ?? Pending(text: "", count: 0, updated: now)
        Self.append(text, to: &p.text, count: &p.count, limit: Self.historyCharacters)
        p.updated = now
        pending[key] = p
    }

    private mutating func expirePending(now: Date) {
        guard !pending.isEmpty else { return }
        let oldest = now.addingTimeInterval(-Self.pendingTextSeconds)
        guard pending.values.contains(where: { $0.updated < oldest }) else { return }
        pending = pending.filter { $0.value.updated >= oldest }
    }

    /// Appends `s` to `text`, whose length in Characters is `count`, and drops the oldest Characters
    /// beyond `limit`, in place. The count stays exact without recounting `text`: appending can only
    /// change the segmentation from the old last Character on (grapheme breaks depend on what
    /// precedes them, and segmenting from a known break gives the same clusters), so the new count
    /// is the old one less 1 plus the count of that last Character followed by `s`; cutting at a
    /// Character boundary leaves the rest's clusters as they were.
    static func append(_ s: String, to text: inout String, count: inout Int, limit: Int) {
        guard !s.isEmpty else { return }
        if let last = text.last {
            var junction = String(last)
            junction += s
            count += junction.count - 1
        } else {
            count = s.count
        }
        text += s
        if count > limit {
            let cut = text.index(text.startIndex, offsetBy: count - limit)
            text.removeSubrange(text.startIndex..<cut)
            count = limit
        }
    }

    /// The last `recentCharacters` of `history` (whose length is `count`) and their count.
    private static func recent(of history: String, count: Int) -> (String, Int) {
        count <= recentCharacters ? (history, count) : (String(history.suffix(recentCharacters)), recentCharacters)
    }

    // MARK: Slots

    /// The audio frequency of a slot decode's signal centre, where the tracker sees it: FT8 reports
    /// tone 0 of its 8 tones, WSPR (and anything else) its centre.
    public static func signalCentreHz(of d: SlotDecode) -> Double {
        d.mode == .ft8 ? d.frequencyHz + 3.5 * FT8Encoder.toneSpacing : d.frequencyHz
    }

    /// Adds the decodes' rows and claims; returns whether the claims changed.
    private mutating func addSlotDecodes(_ decodes: [SlotDecode], now: Date) -> Bool {
        let fresh = decodes.enumerated()
            .filter { $0.element.slotStart >= slotCutoff }
            .sorted { a, b in
                if a.element.slotStart != b.element.slotStart { return a.element.slotStart > b.element.slotStart }
                if a.element.frequencyHz != b.element.frequencyHz { return a.element.frequencyHz < b.element.frequencyHz }
                return a.offset < b.offset
            }
            .map(\.element)
        guard !fresh.isEmpty else { return false }

        var claimsChanged = false
        for d in fresh {
            let slotSeconds = ModemCatalog.slot(d.mode)?.slotSeconds ?? FT8Modem.slotSeconds
            let until = d.slotStart.addingTimeInterval(3 * slotSeconds + Self.claimMarginSeconds)
            guard until > now else { continue }
            let c = Claim(centreHz: Self.signalCentreHz(of: d), until: until, slotStart: d.slotStart,
                          frequencyHz: d.frequencyHz, mode: d.mode, message: d.message)
            claims.insert(c, at: claimBound { $0.centreHz <= c.centreHz })
            nextClaimExpiry = min(nextClaimExpiry ?? until, until)
            claimsChanged = true
        }

        // Merge (both newest slot first, then ascending frequency; kept rows first on a tie).
        func before(_ a: DecodeRow, _ b: DecodeRow) -> Bool {
            a.utcTime! != b.utcTime! ? a.utcTime! > b.utcTime! : a.frequencyHz < b.frequencyHz
        }
        let added = fresh.map { makeSlotRow($0) }
        var merged: [DecodeRow] = []
        merged.reserveCapacity(min(slotRows.count + added.count, Self.maxSlotRows))
        var i = 0, j = 0
        while merged.count < Self.maxSlotRows && (i < slotRows.count || j < added.count) {
            if j < added.count && (i == slotRows.count || before(added[j], slotRows[i])) {
                merged.append(added[j])
                j += 1
            } else {
                merged.append(slotRows[i])
                i += 1
            }
        }
        slotRows = merged
        return claimsChanged
    }

    /// The next slot row's id: from `Int.min` upwards, never reused (not even by `clear`). The
    /// engine's provisional keys count down from −1, so the two would meet only after some 4.6 × 10¹⁸
    /// of each.
    private mutating func makeSlotRow(_ d: SlotDecode) -> DecodeRow {
        defer { slotSerial += 1 }
        return DecodeRow(id: Int.min + slotSerial, frequencyHz: d.frequencyHz, mode: d.mode, submode: "",
                         snrDb: d.snrDb, recentText: d.message, history: d.message, isQuiet: false,
                         isCursor: false, utcTime: d.slotStart)
    }

    /// Drops the claims that lapsed by `now`; returns whether any did.
    private mutating func expireClaims(now: Date) -> Bool {
        guard let next = nextClaimExpiry, now >= next else { return false }
        claims.removeAll { $0.until <= now }
        nextClaimExpiry = claims.map(\.until).min()
        return true
    }

    /// The index of the first claim for which `isBelow` is false (`isBelow` holds for a prefix).
    private func claimBound(_ isBelow: (Claim) -> Bool) -> Int {
        var lo = 0, hi = claims.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if isBelow(claims[mid]) { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// The claims within `claimToleranceHz` of `hz`.
    private func claims(near hz: Double) -> Range<Int> {
        let lo = claimBound { $0.centreHz < hz - Self.claimToleranceHz }
        var hi = lo
        while hi < claims.count && claims[hi].centreHz <= hz + Self.claimToleranceHz { hi += 1 }
        return lo..<hi
    }

    private mutating func updateFolding() {
        for i in entries.indices {
            let near = claims.isEmpty ? 0..<0 : claims(near: entries[i].row.frequencyHz)
            if entries[i].row.isCursor {
                entries[i].isFolded = false
                if near.isEmpty {
                    entries[i].claimText = nil
                    entries[i].claimMode = nil
                } else {
                    (entries[i].claimText, entries[i].claimMode) = claimMessages(near)
                }
                continue
            }
            entries[i].claimText = nil
            entries[i].claimMode = nil
            let folded = !near.isEmpty
            // Reappearing would shift the list under the pointer like a new row.
            if entries[i].isFolded && !folded && holdNew { entries[i].isHeld = true }
            entries[i].isFolded = folded
        }
    }

    /// The cursor row's text and mode while `range` of the claims claim it.
    private func claimMessages(_ range: Range<Int>) -> (String, ModeID) {
        let near = claims[range].sorted { a, b in
            a.slotStart != b.slotStart ? a.slotStart < b.slotStart : a.frequencyHz < b.frequencyHz
        }
        var lines: [String] = []
        var total = 0
        for c in near.reversed() {
            let line = Self.utcHHMMSS(c.slotStart) + " " + c.message
            let add = line.count + (lines.isEmpty ? 0 : 1)
            if total + add > Self.recentCharacters {
                if lines.isEmpty { lines.append(String(line.suffix(Self.recentCharacters))) }
                break
            }
            lines.append(line)
            total += add
        }
        return (lines.reversed().joined(separator: "\n"), near.last!.mode)
    }

    /// `HHMMSS` of a UTC time (whatever the local time zone).
    public static func utcHHMMSS(_ d: Date) -> String {
        var s = Int(d.timeIntervalSince1970.rounded(.down)) % 86_400
        if s < 0 { s += 86_400 }
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return two(s / 3_600) + two(s / 60 % 60) + two(s % 60)
    }

    private func display(_ e: Entry) -> DecodeRow {
        guard let text = e.claimText else { return e.row }
        var row = e.row
        row.recentText = text
        row.mode = e.claimMode
        return row
    }
}
