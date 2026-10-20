import Testing
import Foundation
@testable import Modems

// The log is pure: every test feeds it hand-built snapshots, text and slot decodes. Times are UTC
// seconds since the Unix epoch; `t0` is 08:00:00 UTC, an FT8 and a WSPR slot boundary.

private let t0 = 1_800_000_000.0

private func date(_ t: Double) -> Date { Date(timeIntervalSince1970: t0 + t) }

private func snap(_ id: Int, _ hz: Double, snr: Float = 10, mode: ModeID? = .psk31, quiet: Bool = false,
                  cursor: Bool = false) -> SignalSnapshot {
    SignalSnapshot(id: id, frequencyHz: hz, snrDb: snr, mode: mode, submode: mode == .psk31 ? "BPSK31" : "",
                   isQuiet: quiet, isCursor: cursor)
}

private func slot(_ mode: ModeID, at t: Double, _ hz: Double, _ message: String, snr: Float = -12) -> SlotDecode {
    SlotDecode(mode: mode, slotStart: date(t), frequencyHz: hz, snrDb: snr, timeOffset: 0.1, message: message)
}

private extension DecodeLog {
    mutating func signals(_ s: [SignalSnapshot]?, _ text: [DecodedText] = [], at t: Double = 0) {
        apply(signals: s, text: text, slotDecodes: [], now: date(t))
    }

    mutating func text(_ id: Int, _ s: String, at t: Double = 0) {
        apply(signals: nil, text: [DecodedText(trackID: id, text: s)], slotDecodes: [], now: date(t))
    }

    mutating func slots(_ d: [SlotDecode], at t: Double) {
        apply(signals: nil, text: [], slotDecodes: d, now: date(t))
    }

    var liveIDs: [Int] { liveRows.map(\.id) }
}

/// `s` cut into pieces of 1…`maxPiece` Unicode scalars (so pieces split grapheme clusters), seeded.
private func scalarPieces(_ s: String, maxPiece: Int, seed: UInt64) -> [String] {
    let scalars = Array(s.unicodeScalars)
    var state = seed
    var out: [String] = []
    var i = 0
    while i < scalars.count {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let n = min(1 + Int(state >> 33) % maxPiece, scalars.count - i)
        var piece = String.UnicodeScalarView()
        piece.append(contentsOf: scalars[i..<(i + n)])
        out.append(String(piece))
        i += n
    }
    return out
}

@Suite struct DecodeLogTests {
    // MARK: Order

    @Test func ordersByFrequencyWithCursorPinned() {
        var log = DecodeLog()
        log.signals([snap(3, 1_300), snap(1, 600), snap(2, 900)])
        #expect(log.liveRows.map(\.frequencyHz) == [600, 900, 1_300])
        log.signals([snap(3, 1_300), snap(1, 600), snap(2, 900, cursor: true)], at: 0.5)
        #expect(log.liveIDs == [2, 1, 3])
        #expect(log.liveRows.first?.isCursor == true)
        #expect(log.liveRows.dropFirst().allSatisfy { !$0.isCursor })
    }

    @Test func noReorderOnFrequencyJitter() {
        var log = DecodeLog()
        log.signals([snap(1, 600), snap(2, 900), snap(3, 1_300)])
        // Track 2 drifts up past the 1300 Hz row: its row keeps its place, showing the new frequency.
        for (k, hz) in [1_000.0, 1_200, 1_299, 1_301].enumerated() {
            log.signals([snap(1, 600), snap(2, hz), snap(3, 1_300)], at: 0.5 * Double(k + 1))
            #expect(log.liveIDs == [1, 2, 3])
        }
        #expect(log.row(forTrack: 2)?.frequencyHz == 1_301)
        // It goes quiet (still in place), is removed, and comes back as a new track: now in order.
        log.signals([snap(1, 600), snap(2, 1_301, quiet: true), snap(3, 1_300)], at: 3)
        #expect(log.liveIDs == [1, 2, 3])
        log.signals([snap(1, 600), snap(3, 1_300)], at: 3.5)
        log.signals([snap(1, 600), snap(3, 1_300), snap(4, 1_301)], at: 4)
        #expect(log.liveIDs == [1, 3, 4])
    }

    @Test func insertsNewRowsInFrequencyOrderAmongFrozenRows() {
        var log = DecodeLog()
        log.signals([snap(1, 600), snap(2, 900)])
        // Track 1 has drifted to 1000 Hz; a new 800 Hz track goes by the frozen keys (600, 900).
        log.signals([snap(1, 1_000), snap(2, 900), snap(3, 800)], at: 0.5)
        #expect(log.liveIDs == [1, 3, 2])
        // Equal frozen keys keep insertion order.
        log.signals([snap(1, 1_000), snap(2, 900), snap(3, 800), snap(4, 800)], at: 1)
        #expect(log.liveIDs == [1, 3, 4, 2])
    }

    @Test func cursorMovesFromOneTrackToAnother() {
        var log = DecodeLog()
        log.signals([snap(1, 600), snap(2, 900, cursor: true), snap(3, 1_300)])
        #expect(log.liveIDs == [2, 1, 3])
        log.signals([snap(1, 600), snap(2, 900), snap(3, 1_300, cursor: true)], at: 0.5)
        // The old cursor row returns to its frozen place; the new one is pinned.
        #expect(log.liveIDs == [3, 1, 2])
        #expect(log.liveRows.map(\.isCursor) == [true, false, false])
        log.signals([snap(1, 600), snap(2, 900), snap(3, 1_300)], at: 1)
        #expect(log.liveIDs == [1, 2, 3])
    }

    // MARK: Snapshots

    @Test func quietAndRemoval() {
        var log = DecodeLog()
        log.signals([snap(1, 600), snap(2, 900)])
        log.signals([snap(1, 600), snap(2, 900, quiet: true)], at: 0.5)
        #expect(log.row(forTrack: 2)?.isQuiet == true)
        #expect(log.row(forTrack: 1)?.isQuiet == false)
        log.signals([snap(1, 600)], at: 1)
        #expect(log.liveIDs == [1])
        #expect(log.row(forTrack: 2) == nil)
    }

    @Test func quietRowRevivesInPlace() {
        var log = DecodeLog()
        log.signals([snap(1, 600), snap(2, 900), snap(3, 1_300)])
        log.text(2, "hello ")
        log.signals([snap(1, 600), snap(2, 1_350, quiet: true), snap(3, 1_300)], at: 20)
        #expect(log.liveIDs == [1, 2, 3])
        log.signals([snap(1, 600), snap(2, 1_350), snap(3, 1_300)], at: 25)
        log.text(2, "again", at: 25)
        #expect(log.liveIDs == [1, 2, 3])
        let row = log.row(forTrack: 2)
        #expect(row?.isQuiet == false)
        #expect(row?.recentText == "hello again")
    }

    @Test func snapshotUpdatesRowFields() {
        var log = DecodeLog()
        log.signals([snap(1, 600, snr: 3, mode: nil)])
        #expect(log.row(forTrack: 1)?.mode == nil)
        log.signals([SignalSnapshot(id: 1, frequencyHz: 601.5, snrDb: 7, mode: .rtty, submode: "45.45/170",
                                    isQuiet: false, isCursor: false)], at: 0.5)
        let r = log.row(forTrack: 1)
        #expect(r?.frequencyHz == 601.5)
        #expect(r?.snrDb == 7)
        #expect(r?.mode == .rtty)
        #expect(r?.submode == "45.45/170")
        #expect(r?.utcTime == nil)
    }

    @Test func nilSignalsKeepRowsEmptySignalsRemoveThem() {
        var log = DecodeLog()
        log.signals([snap(1, 600), snap(2, 900)])
        // No snapshot this time (the engine sends one at most every 0.5 s): nothing is removed.
        for k in 1...10 { log.signals(nil, at: 0.1 * Double(k)) }
        log.text(1, "abc", at: 1.1)
        #expect(log.liveIDs == [1, 2])
        #expect(log.row(forTrack: 1)?.recentText == "abc")
        // An empty snapshot means there are no tracks.
        log.signals([], at: 1.5)
        #expect(log.liveRows.isEmpty)
        #expect(log.row(forTrack: 1) == nil)
    }

    // MARK: Text

    @Test func textAppendsAndTrims() {
        var log = DecodeLog()
        log.signals([snap(1, 600)])
        log.text(1, "CQ ")
        log.text(1, "DE ")
        #expect(log.row(forTrack: 1)?.recentText == "CQ DE ")
        #expect(log.row(forTrack: 1)?.history == "CQ DE ")
        var sent = "CQ DE "
        var k = 0
        while sent.count < 5_000 {
            let piece = "w\(k % 10)xyz "
            sent += piece
            log.text(1, piece, at: 0.1 * Double(k))
            k += 1
        }
        // One large piece too (longer than both limits on its own).
        let big = String(repeating: "0123456789", count: 450)
        sent += big
        log.text(1, big, at: 600)
        log.text(1, "end", at: 600.1)
        sent += "end"
        let r = log.row(forTrack: 1)
        #expect(r?.recentText.count == DecodeLog.recentCharacters)
        #expect(r?.history.count == DecodeLog.historyCharacters)
        #expect(r?.recentText == String(sent.suffix(160)))
        #expect(r?.history == String(sent.suffix(4_000)))
        #expect(DecodeLog.recentCharacters == 160 && DecodeLog.historyCharacters == 4_000)
    }

    /// Text arrives split anywhere between Unicode scalars (a decoder may emit "\r" then "\n", a
    /// base letter then its combining mark, half a flag). The trimmed text is exactly the last 160 /
    /// 4000 Characters of everything sent, and never starts with a broken grapheme cluster.
    @Test func trimsOnCharacterBoundaries() {
        let units = ["e\u{301}", "\r\n", "🇫🇮", "🇸🇪", "👩‍👩‍👧‍👦", "a", " ", "\u{1F44D}\u{1F3FD}", "ñ", "ก\u{E49}", "x\u{308}\u{301}"]
        var state: UInt64 = 1_307
        var full = ""
        for _ in 0..<6_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            full += units[Int(state >> 33) % units.count]
        }
        // A lone regional indicator too, so flags straddle different pairings.
        full = "🇺" + full
        for seed in [UInt64(1), 2, 3] {
            var log = DecodeLog()
            log.signals([snap(1, 600)])
            for (k, piece) in scalarPieces(full, maxPiece: 7, seed: seed).enumerated() {
                log.text(1, piece, at: 0.01 * Double(k))
            }
            let r = log.row(forTrack: 1)
            #expect(r?.recentText == String(full.suffix(160)))
            #expect(r?.history == String(full.suffix(4_000)))
            #expect(r?.recentText.count == 160)
            #expect(r?.history.count == 4_000)
            // Each kept Character is a whole cluster of the original text.
            let first = r.flatMap { $0.history.first }.map(String.init)
            let isFlagPart = first.map { $0.unicodeScalars.allSatisfy { (0x1F1E6...0x1F1FF).contains($0.value) } } ?? false
            #expect(first.map { units.contains($0) } == true || isFlagPart, "\(String(describing: first))")
        }
    }

    @Test func textBeforeItsRowIsBufferedIntoIt() {
        var log = DecodeLog()
        // Text for track 5 before any snapshot has it (it can precede the first snapshot by 0.5 s).
        log.text(5, "early ", at: 0)
        log.text(5, "bird ", at: 0.2)
        #expect(log.row(forTrack: 5) == nil)
        #expect(log.liveRows.isEmpty)
        log.signals([snap(5, 1_000)], [DecodedText(trackID: 5, text: "sings")], at: 0.4)
        #expect(log.row(forTrack: 5)?.recentText == "early bird sings")
        #expect(log.row(forTrack: 5)?.history == "early bird sings")
        // Text in the same call as the snapshot that first lists the row.
        log.signals([snap(5, 1_000), snap(6, 1_500)], [DecodedText(trackID: 6, text: "six")], at: 0.9)
        #expect(log.row(forTrack: 6)?.recentText == "six")
        // Buffered text is trimmed like a row's.
        log.text(7, String(repeating: "z", count: 5_000), at: 1)
        log.signals([snap(5, 1_000), snap(6, 1_500), snap(7, 2_000)], at: 1.4)
        #expect(log.row(forTrack: 7)?.history.count == 4_000)
        #expect(log.row(forTrack: 7)?.recentText.count == 160)
    }

    @Test func bufferedTextForAnUnlistedKeyExpires() {
        var log = DecodeLog()
        log.signals([snap(1, 600)])
        // Late text for a track that the snapshots no longer list (removed in between).
        log.text(9, "orphan", at: 0)
        log.signals([snap(1, 600)], at: DecodeLog.pendingTextSeconds + 0.5)
        log.signals([snap(1, 600), snap(9, 900)], at: DecodeLog.pendingTextSeconds + 1)
        #expect(log.row(forTrack: 9)?.recentText == "")
        // Within the expiry it is kept.
        log.text(10, "kept", at: 20)
        log.signals([snap(1, 600), snap(9, 900), snap(10, 1_000)], at: 20 + DecodeLog.pendingTextSeconds - 0.5)
        #expect(log.row(forTrack: 10)?.recentText == "kept")
    }

    /// A cursor locked where there is no track has a provisional negative key, listed in the
    /// snapshots (`isCursor`) and carrying the decoder's text. When a track appears there, the engine
    /// moves the decoder to the track's id; the cursor's text so far moves to the new row.
    @Test func provisionalCursorKeyRows() {
        var log = DecodeLog()
        log.signals([snap(1, 600), snap(2, 900)])
        // The lock happens between snapshots; its text arrives first.
        log.text(-1, "tu ", at: 0.2)
        log.signals([snap(1, 600), snap(2, 900), snap(-1, 1_510, mode: .cw, cursor: true)], at: 0.5)
        #expect(log.liveIDs == [-1, 1, 2])
        log.text(-1, "es 73 ", at: 0.6)
        #expect(log.row(forTrack: -1)?.recentText == "tu es 73 ")
        // A track appears 4 Hz away and the cursor binds to it.
        log.signals([snap(1, 600), snap(2, 900), snap(3, 1_514, mode: .cw, cursor: true)],
                    [DecodedText(trackID: 3, text: "gl")], at: 1)
        #expect(log.liveIDs == [3, 1, 2])
        #expect(log.row(forTrack: -1) == nil)
        #expect(log.row(forTrack: 3)?.recentText == "tu es 73 gl")
        #expect(log.row(forTrack: 3)?.history == "tu es 73 gl")

        // Not carried over: a provisional cursor that is unlocked and a new, distant cursor track.
        log.signals([snap(1, 600), snap(2, 900), snap(3, 1_514, mode: .cw), snap(-2, 2_500, cursor: true)],
                    [DecodedText(trackID: -2, text: "zzz")], at: 1.5)
        log.signals([snap(1, 600), snap(2, 900), snap(3, 1_514, mode: .cw), snap(4, 700, cursor: true)], at: 2)
        #expect(log.row(forTrack: 4)?.recentText == "")
        #expect(log.row(forTrack: -2) == nil)
        // Nor to a cursor track that already had a row.
        log.signals([snap(1, 600), snap(2, 900), snap(3, 1_514, mode: .cw), snap(4, 700), snap(-3, 905, cursor: true)],
                    [DecodedText(trackID: -3, text: "qqq")], at: 2.5)
        log.signals([snap(1, 600), snap(2, 900, cursor: true), snap(3, 1_514, mode: .cw), snap(4, 700)], at: 3)
        #expect(log.row(forTrack: 2)?.recentText == "")
    }

    // MARK: Holding new rows

    @Test func heldNew() {
        var log = DecodeLog()
        log.signals([snap(1, 600), snap(3, 1_300)])
        log.holdNew = true
        log.signals([snap(1, 600), snap(2, 900), snap(3, 1_300)], at: 0.5)
        #expect(log.heldNewCount == 1)
        #expect(log.liveIDs == [1, 3])
        log.releaseHeld()
        #expect(log.heldNewCount == 0)
        #expect(log.liveIDs == [1, 2, 3])
        // Setting holdNew false releases too.
        log.signals([snap(1, 600), snap(2, 900), snap(3, 1_300), snap(4, 2_000)], at: 1)
        #expect(log.heldNewCount == 1)
        #expect(log.liveIDs == [1, 2, 3])
        log.holdNew = false
        #expect(log.heldNewCount == 0)
        #expect(log.liveIDs == [1, 2, 3, 4])
        // Releasing with nothing held, or holding again, changes nothing visible.
        log.releaseHeld()
        log.holdNew = true
        #expect(log.liveIDs == [1, 2, 3, 4])
    }

    @Test func heldRowsKeepTextAndCountRows() {
        var log = DecodeLog()
        log.signals([snap(1, 600)])
        log.holdNew = true
        log.signals([snap(1, 600), snap(2, 900)], [DecodedText(trackID: 2, text: "one ")], at: 0.5)
        for k in 0..<5 { log.text(2, "x", at: 0.6 + 0.1 * Double(k)) }
        // Many texts, one held row.
        #expect(log.heldNewCount == 1)
        #expect(log.row(forTrack: 2)?.recentText == "one xxxxx", "held rows still accumulate text")
        // Snapshots keep updating a held row; one that disappears leaves the count.
        log.signals([snap(1, 600), snap(2, 905, quiet: true), snap(3, 1_200)], at: 1)
        #expect(log.heldNewCount == 2)
        #expect(log.row(forTrack: 2)?.isQuiet == true)
        log.signals([snap(1, 600), snap(3, 1_200)], at: 1.5)
        #expect(log.heldNewCount == 1)
        log.releaseHeld()
        #expect(log.liveIDs == [1, 3])
    }

    @Test func cursorRowIsNeverHeld() {
        var log = DecodeLog()
        log.signals([snap(1, 600)])
        log.holdNew = true
        // A new row that is the cursor shows at once, pinned.
        log.signals([snap(1, 600), snap(-1, 1_000, cursor: true)], at: 0.5)
        #expect(log.liveIDs == [-1, 1])
        #expect(log.heldNewCount == 0)
        // A held row that becomes the cursor is released.
        log.signals([snap(1, 600), snap(-1, 1_000, cursor: true), snap(2, 900)], at: 1)
        #expect(log.heldNewCount == 1)
        log.signals([snap(1, 600), snap(2, 900, cursor: true)], at: 1.5)
        #expect(log.heldNewCount == 0)
        #expect(log.liveIDs == [2, 1])
        // It stays visible after the cursor leaves it.
        log.signals([snap(1, 600), snap(2, 900)], at: 2)
        #expect(log.liveIDs == [1, 2])
    }

    // MARK: Slot rows

    @Test func slotRowsNewestFirstAndCapped() {
        var log = DecodeLog()
        for k in 0..<250 {
            log.slots([slot(.ft8, at: 15 * Double(k), 1_000 + Double(k), "CQ K\(k) FN42")], at: 15 * Double(k) + 16)
        }
        let rows = log.slotRows
        #expect(rows.count == DecodeLog.maxSlotRows)
        #expect(DecodeLog.maxSlotRows == 200)
        #expect(rows.first?.recentText == "CQ K249 FN42")
        #expect(rows.last?.recentText == "CQ K50 FN42")
        #expect(rows.allSatisfy { $0.utcTime != nil && $0.mode == .ft8 && !$0.isCursor && $0.history == $0.recentText })
        #expect(zip(rows, rows.dropFirst()).allSatisfy { $0.utcTime! > $1.utcTime! })
        #expect(rows.first?.utcTime == date(15 * 249))
        #expect(rows.first?.frequencyHz == 1_249)
        #expect(rows.first?.snrDb == -12)
        #expect(log.liveRows.isEmpty)
    }

    @Test func slotRowsOrderBySlotThenFrequency() {
        var log = DecodeLog()
        log.slots([slot(.ft8, at: 105, 1_200, "B"), slot(.ft8, at: 105, 800, "A")], at: 121)
        // A WSPR slot that started earlier arrives later: it goes below the newer FT8 slot.
        log.slots([slot(.wspr, at: 0, 1_500, "K1ABC FN42 37")], at: 122)
        log.slots([slot(.ft8, at: 120, 900, "C")], at: 136)
        #expect(log.slotRows.map(\.recentText) == ["C", "A", "B", "K1ABC FN42 37"])
        // A decode older than every kept row, with the list full, is dropped.
        for k in 0..<200 { log.slots([slot(.ft8, at: 1_000 + 15 * Double(k), 1_000, "N\(k)")], at: 4_000) }
        log.slots([slot(.ft8, at: 15, 1_000, "too old")], at: 4_001)
        #expect(log.slotRows.count == 200)
        #expect(!log.slotRows.contains { $0.recentText == "too old" })
    }

    /// Slot rows use negative ids from the bottom of `Int`; the engine's provisional cursor keys
    /// count down from −1. Neither can meet the other, and slot ids are never reused, not even after
    /// `clear()`, so a view's row identity is never confused.
    @Test func slotRowIDsNeverCollide() {
        var log = DecodeLog()
        let provisional = (1...300).map { snap(-$0, 300 + 10 * Double($0), cursor: $0 == 1) }
        log.signals(provisional)
        var seen = Set<Int>()
        for round in 0..<3 {
            for k in 0..<120 {
                log.slots([slot(.ft8, at: 15 * Double(k + 200 * round), 500, "R\(round) \(k)"),
                           slot(.ft8, at: 15 * Double(k + 200 * round), 700, "R\(round) \(k)b")],
                          at: 15 * Double(k + 200 * round) + 16)
            }
            let ids = log.slotRows.map(\.id)
            #expect(Set(ids).count == ids.count)
            #expect(ids.allSatisfy { $0 < 0 && $0 < -1_000_000_000 })
            #expect(Set(ids).isDisjoint(with: log.liveRows.map(\.id)))
            #expect(seen.isDisjoint(with: ids), "slot ids are never reused")
            seen.formUnion(ids)
            #expect(log.row(forTrack: -1)?.isCursor == true)
            log.clear(at: date(0))
            log.signals(provisional)
        }
        for id in seen { #expect(log.row(forTrack: id) == nil) }
    }

    @Test func slotClaimedTrackFolded() {
        var log = DecodeLog()
        // FT8 reports tone 0; a tracked FT8 signal is at its centre, tone 0 + 21.875 Hz.
        let ft8Centre = 1_000 + 3.5 * FT8Encoder.toneSpacing
        log.signals([snap(1, 600), snap(2, ft8Centre + 6, mode: .ft8), snap(3, 1_000), snap(4, 1_510, mode: nil),
                     snap(5, 1_525, mode: nil)], at: 15)
        #expect(log.liveIDs == [1, 3, 2, 4, 5])
        log.slots([slot(.ft8, at: 0, 1_000, "CQ K1ABC FN42"), slot(.wspr, at: -120, 1_502, "K1ABC FN42 37")], at: 16)
        // Track 2 (6 Hz from the FT8 centre) and track 4 (8 Hz from the WSPR centre) are folded;
        // track 3, at the FT8 tone 0 but 21.9 Hz from its centre, and track 5 (23 Hz) are not.
        #expect(log.liveIDs == [1, 3, 5])
        #expect(log.row(forTrack: 2) != nil, "a folded track keeps its row, only hidden")
        // The claim holds through the station's off slot and its next decode.
        log.signals([snap(1, 600), snap(2, ft8Centre + 9.5, mode: .ft8), snap(3, 1_000), snap(4, 1_510, mode: nil),
                     snap(5, 1_525, mode: nil)], at: 45)
        #expect(log.liveIDs == [1, 3, 5])
        log.signals([snap(1, 600), snap(2, ft8Centre + 10.5, mode: .ft8), snap(3, 1_000), snap(4, 1_510, mode: nil),
                     snap(5, 1_525, mode: nil)], at: 45.5)
        #expect(log.liveIDs == [1, 3, 2, 5], "beyond ±10 Hz")
        // An FT8 claim lasts until 3 slots + 10 s after its slot start; WSPR's likewise.
        log.signals([snap(1, 600), snap(2, ft8Centre, mode: .ft8), snap(3, 1_000), snap(4, 1_510, mode: nil),
                     snap(5, 1_525, mode: nil)], at: 54.9)
        #expect(log.liveIDs == [1, 3, 5])
        log.signals(nil, at: 55)
        #expect(log.liveIDs == [1, 3, 2, 5])
        log.signals(nil, at: -120 + 370 - 0.1)
        #expect(log.liveIDs == [1, 3, 2, 5])
        log.signals(nil, at: -120 + 370)
        #expect(log.liveIDs == [1, 3, 2, 4, 5])
    }

    @Test func unfoldedTrackIsHeldWhileHolding() {
        var log = DecodeLog()
        log.signals([snap(1, 600), snap(2, 1_022, mode: .ft8)], at: 15)
        log.slots([slot(.ft8, at: 0, 1_000, "CQ K1ABC FN42")], at: 16)
        log.holdNew = true
        #expect(log.heldNewCount == 0, "a folded row is not a held one")
        log.signals(nil, at: 60)
        // The row reappearing would shift the list under the pointer: it waits like a new one.
        #expect(log.liveIDs == [1])
        #expect(log.heldNewCount == 1)
        log.holdNew = false
        #expect(log.liveIDs == [1, 2])
    }

    @Test func cursorOnSlotSignalShowsLatestMessages() {
        var log = DecodeLog()
        log.signals([snap(1, 600), snap(2, 1_022, mode: .psk31, cursor: true)], [DecodedText(trackID: 2, text: "garble")], at: 14)
        #expect(log.liveRows.first?.recentText == "garble")
        log.slots([slot(.ft8, at: 0, 1_000, "CQ K1ABC FN42"), slot(.ft8, at: 0, 1_400, "CQ W9XYZ EN50")], at: 16)
        log.slots([slot(.ft8, at: 30, 1_001, "K1ABC W9XYZ -05")], at: 46)
        let row = log.liveRows.first
        #expect(row?.id == 2 && row?.isCursor == true, "the cursor's row is never folded")
        #expect(row?.mode == .ft8)
        #expect(row?.recentText == "080000 CQ K1ABC FN42\n080030 K1ABC W9XYZ -05")
        #expect(row?.history == "garble", "history keeps the decoder's own text")
        #expect(log.row(forTrack: 2) == row)
        // Once the claims lapse, the row shows its own text again.
        log.signals(nil, at: 30 + 55)
        #expect(log.liveRows.first?.recentText == "garble")
        #expect(log.liveRows.first?.mode == .psk31)
        // The newest messages win when they do not all fit in 160 characters.
        var decodes: [SlotDecode] = []
        for k in 0..<12 { decodes.append(slot(.ft8, at: 90, 1_000 + 0.1 * Double(k), "MESSAGE NUMBER \(k)")) }
        log.slots(decodes, at: 106)
        let text = log.liveRows.first?.recentText ?? ""
        #expect(text.count <= 160)
        #expect(text.hasSuffix("080130 MESSAGE NUMBER 11"))
        #expect(!text.contains("NUMBER 0\n") && text.hasPrefix("080130 "))
    }

    // MARK: Lookup and clearing

    @Test func rowForTrack() {
        var log = DecodeLog()
        #expect(log.row(forTrack: 1) == nil)
        log.signals([snap(1, 600), snap(2, 900, cursor: true)], [DecodedText(trackID: 1, text: "hi")])
        #expect(log.row(forTrack: 1)?.recentText == "hi")
        #expect(log.row(forTrack: 1)?.frequencyHz == 600)
        #expect(log.row(forTrack: 2)?.isCursor == true)
        #expect(log.row(forTrack: 3) == nil)
        // Held rows are found too.
        log.holdNew = true
        log.signals([snap(1, 600), snap(2, 900, cursor: true), snap(3, 1_200)], at: 0.5)
        #expect(log.row(forTrack: 3)?.frequencyHz == 1_200)
        #expect(!log.liveIDs.contains(3))
        // Slot rows are not tracks.
        log.slots([slot(.ft8, at: 0, 1_000, "CQ")], at: 16)
        #expect(log.slotRows.first.flatMap { log.row(forTrack: $0.id) } == nil)
    }

    /// `clear()` (the box moved) empties every row, held and buffered text included, and slot
    /// decodes of slots that started before it are ignored from then on: a slot job started before a
    /// box move finishes later, and its messages are the old box's.
    @Test func clearRemovesEverythingAndDropsStaleSlots() {
        var log = DecodeLog()
        log.signals([snap(1, 600, cursor: true), snap(2, 900)], [DecodedText(trackID: 1, text: "old")], at: 10)
        log.holdNew = true
        log.signals([snap(1, 600, cursor: true), snap(2, 900), snap(3, 1_200)], at: 10.5)
        log.text(4, "pending", at: 10.6)
        log.slots([slot(.ft8, at: 0, 1_000, "OLD SLOT")], at: 16)
        log.clear(at: date(20))
        #expect(log.liveRows.isEmpty && log.slotRows.isEmpty && log.heldNewCount == 0)
        #expect(log.holdNew, "the pointer is still where it was")
        // A late result from a job of a slot before the move, and the engine's empty snapshot.
        log.apply(signals: [], text: [], slotDecodes: [slot(.ft8, at: 15, 1_000, "STALE")], now: date(31))
        #expect(log.slotRows.isEmpty)
        log.slots([slot(.wspr, at: 0, 1_500, "STALE WSPR")], at: 121)
        #expect(log.slotRows.isEmpty)
        // A later snapshot for track 4 gets none of the cleared buffered text.
        log.holdNew = false
        log.signals([snap(4, 800)], at: 21)
        #expect(log.row(forTrack: 4)?.recentText == "")
        // Slots that start at or after the move are kept.
        log.slots([slot(.ft8, at: 30, 1_000, "NEW")], at: 46)
        #expect(log.slotRows.map(\.recentText) == ["NEW"])
        // A clear earlier than the last one does not lower the cutoff.
        log.clear(at: date(0))
        log.slots([slot(.ft8, at: 15, 1_000, "STALE")], at: 47)
        #expect(log.slotRows.isEmpty)
    }
}
