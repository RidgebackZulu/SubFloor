import Foundation
import Testing
import Transcription
@testable import Recording
@testable import SubFloor

/// The Recordings search: which recordings a query leaves lit, which it fades, and how ◀ ▶ walk the matches.
@Suite struct RecordingsSearchTests {
    // 2026-10-27 and 2026-10-28, UTC.
    private static let day1 = Date(timeIntervalSince1970: 1_793_059_200)
    private static let day2 = day1.addingTimeInterval(86_400)

    private static let a = "SubFloor_20261027_060000Z_11175000Hz_USB.flac"   // "dust" on day 1
    private static let b = "SubFloor_20261027_090000Z_11175000Hz_USB.flac"   // other speech
    private static let c = "SubFloor_20261028_030000Z_11175000Hz_USB.flac"   // "dust" on day 2
    private static let d = "SubFloor_20261028_050000Z_11175000Hz_USB.flac"   // never transcribed
    private static let live = "SubFloor_20261028_070000Z_11175000Hz_USB.flac"

    private func transcript(_ file: String, _ text: String) -> StoredTranscript {
        let words = text.split(separator: " ").enumerated().map {
            WhisperResponse.Word(word: String($0.element), start: Double($0.offset), end: Double($0.offset) + 0.5)
        }
        let response = WhisperResponse(text: text, language: "en", duration: Double(words.count) + 1,
                                       segments: [WhisperResponse.Segment(start: 0, end: Double(words.count), text: text,
                                                                          avgLogprob: -0.2, noSpeechProb: 0.01, compressionRatio: 1.2)],
                                       words: words)
        return StoredTranscript(file: file, model: "m", language: "en", createdAt: Date(timeIntervalSince1970: 0),
                                durationSeconds: 30, costUSD: nil, note: nil,
                                chunks: [TranscriptChunk(offsetSeconds: 0, response: response)])
    }

    private var catalog: RecordingsCatalog {
        RecordingsCatalog(files: [Self.a, Self.b, Self.c, Self.d, Self.live],
                          live: LiveRecording(file: Self.live, start: Self.day2.addingTimeInterval(7 * 3600), seconds: 5,
                                              frequencyHz: 11_175_000, mode: "USB", auto: true))
    }

    private var index: TranscriptIndex {
        var i = TranscriptIndex()
        i.set(transcript(Self.a, "heavy dust on the antenna today"))
        i.set(transcript(Self.b, "weather report for the northern coast"))
        i.set(transcript(Self.c, "the DUST storm is moving east"))
        i.set(transcript(Self.live, "dust is mentioned here too"))
        return i
    }

    @Test func matchesAcrossDays() {
        let m = RecordingsSearch(query: "dust").matches(catalog: catalog, index: index)
        #expect(m.map(\.file) == [Self.a, Self.c])   // two days, sorted; the one in progress is left out
        #expect(RecordingsCatalog.utcDayStart(m[0].start) != RecordingsCatalog.utcDayStart(m[1].start))
        #expect(RecordingsSearch(query: "storm dust").matches(catalog: catalog, index: index).map(\.file) == [Self.c])
    }

    @Test func dimmedOnlyWhenActive() {
        let all = catalog.allRecordings
        #expect(RecordingsSearch(query: "").dimmed(all, index: index).isEmpty)
        #expect(RecordingsSearch(query: "   ").dimmed(all, index: index).isEmpty)
        #expect(!RecordingsSearch(query: "   ").isActive)
        let search = RecordingsSearch(query: "dust")
        #expect(search.isActive)
        // The non-matching (b), the untranscribed (d) and the one in progress fade; the matches stay lit.
        #expect(search.dimmed(all, index: index) == [Self.b, Self.d, Self.live])
        // The listener's pick is never faded, even when it does not match.
        #expect(search.dimmed(all, index: index, keeping: Self.b) == [Self.d, Self.live])
        #expect(search.dimmed(all, index: index, keeping: Self.a) == [Self.b, Self.d, Self.live])
        #expect(RecordingsSearch(query: "").dimmed(all, index: index, keeping: Self.b).isEmpty)
    }

    @Test func stepWraps() {
        let m = RecordingsSearch(query: "dust").matches(catalog: catalog, index: index)
        #expect(RecordingsSearch.step(m, from: m[1], forward: true)?.file == Self.a)    // last -> first
        #expect(RecordingsSearch.step(m, from: m[0], forward: false)?.file == Self.c)   // first -> last
        #expect(RecordingsSearch.step(m, from: m[0], forward: true)?.file == Self.c)
        #expect(RecordingsSearch.step(m, from: m[1], forward: false)?.file == Self.a)
        #expect(RecordingsSearch.step(m, from: nil, forward: true)?.file == Self.a)
        #expect(RecordingsSearch.step(m, from: nil, forward: false)?.file == Self.c)
        // Not itself a match: forward takes the next one after it in time, backward the one before.
        let b = catalog.recording(Self.b)!
        #expect(RecordingsSearch.step(m, from: b, forward: true)?.file == Self.c)
        #expect(RecordingsSearch.step(m, from: b, forward: false)?.file == Self.a)
    }

    @Test func steppingStartsFromTheSelectionOrTheShownDay() {
        let m = RecordingsSearch(query: "dust").matches(catalog: catalog, index: index)   // a on day 1, c on day 2
        func go(_ selected: String?, _ day: Date, forward: Bool) -> String? {
            let origin = RecordingsSearch.stepOrigin(m, selected: selected, dayStart: day, forward: forward)
            return RecordingsSearch.step(m, from: origin, forward: forward)?.file
        }
        // A selected match: step from it.
        #expect(go(Self.a, Self.day2, forward: true) == Self.c)
        #expect(go(Self.c, Self.day1, forward: false) == Self.a)
        // Nothing selected, or a selection that is no match: the shown day decides.
        #expect(go(nil, Self.day2, forward: true) == Self.c)     // first match from that day on
        #expect(go(Self.b, Self.day2, forward: true) == Self.c)
        #expect(go(nil, Self.day2, forward: false) == Self.a)    // last match before that day
        #expect(go(nil, Self.day1, forward: true) == Self.a)
        #expect(go(nil, Self.day1, forward: false) == Self.c)    // none before: wraps to the last
        #expect(go(nil, Self.day2.addingTimeInterval(86_400), forward: true) == Self.a)   // none from then on: wraps
    }

    @Test func noMatchesDisablesStepping() {
        let search = RecordingsSearch(query: "zebra")
        let m = search.matches(catalog: catalog, index: index)
        #expect(m.isEmpty)
        #expect(RecordingsSearch.step(m, from: nil, forward: true) == nil)
        #expect(RecordingsSearch.step([], from: catalog.recording(Self.a), forward: false) == nil)
        // Everything fades: nothing matched.
        #expect(search.dimmed(catalog.allRecordings, index: index) == Set(catalog.allRecordings.map(\.file)))
    }

    @Test func matchCountReadsSingularAndPlural() {
        #expect(RecordingsSearch.countText(0) == "0 matches")
        #expect(RecordingsSearch.countText(1) == "1 match")
        #expect(RecordingsSearch.countText(2) == "2 matches")
    }
}
