import CoreGraphics
import Foundation
import Testing
import Transcription
@testable import SubFloor

/// The transcript strip's pure parts: where each word sits under the waveform, which badge a recording gets,
/// and what the strip says for each state of a recording.
@Suite struct TranscriptStripTests {
    private func word(_ text: String, _ start: Double, _ end: Double? = nil) -> TranscriptWord {
        TranscriptWord(text: text, start: start, end: end ?? start + 0.3)
    }

    private func place(_ words: [TranscriptWord], visible: ClosedRange<Double> = 0...10, width: CGFloat = 1000,
                       wordWidth: CGFloat = 40) -> [PlacedWord] {
        TranscriptStripLayout.place(words, visible: visible, width: width) { _ in wordWidth }
    }

    // MARK: Placement

    @Test func placeSpreadsWords() {
        let placed = place([word("a", 0), word("b", 1), word("c", 2)])
        #expect(placed == [PlacedWord(index: 0, x: 0, line: 0), PlacedWord(index: 1, x: 100, line: 0),
                           PlacedWord(index: 2, x: 200, line: 0)])
    }

    @Test func placeOverlapGoesToLine1ThenHides() {
        let placed = place([word("a", 0), word("b", 0.1), word("c", 0.2)], width: 40)
        #expect(placed.map(\.line) == [0, 1])
        #expect(placed.map(\.index) == [0, 1])
    }

    @Test func placeReusesALineOnceItsWordHasEnded() {
        // The third word starts after the first has ended (40 + gap), so it goes back to line 0.
        let placed = place([word("a", 0), word("b", 0.1), word("c", 1)])
        #expect(placed.map(\.line) == [0, 1, 0])
    }

    @Test func placeSkipsOffscreen() {
        let placed = place([word("early", 3), word("in", 6), word("late", 11)], visible: 5...10)
        #expect(placed.map(\.index) == [1])
        #expect(placed.first?.x == 200)     // (6 − 5) / 5 of 1000
    }

    @Test func placeKeepsTheGapBetweenWords() {
        // 40 wide + 6 gap: a word 40 pt after the first still collides; one 50 pt after does not.
        #expect(place([word("a", 0), word("b", 0.4)]).map(\.line) == [0, 1])
        #expect(place([word("a", 0), word("b", 0.5)]).map(\.line) == [0, 0])
    }

    /// At whole-file zoom a search match is placed before everything else, so its green highlight shows: the
    /// other words fit around it, on either line, or are left out.
    @Test func aMatchIsPlacedFirst() {
        let words = [word("a", 0), word("b", 1), word("match", 2)]   // at x 0, 4 and 8 across 40 pt
        // Without priority the third word is hidden: both lines are taken.
        #expect(place(words, width: 40).map(\.index) == [0, 1])
        let placed = TranscriptStripLayout.place(words, visible: 0...10, width: 40, measure: { _ in 40 }, priority: { $0 == 2 })
        #expect(placed == [PlacedWord(index: 0, x: 0, line: 1), PlacedWord(index: 2, x: 8, line: 0)])

        // Around a match at x 50 (4 wide + 6 gap): a word that ends before it still goes on line 0, one that would
        // run into it goes to line 1, and one that would run into both lines' words is left out.
        let spread = [word("a", 0), word("b", 0.3), word("c", 0.45), word("d", 0.47), word("match", 0.5)]
        let around = TranscriptStripLayout.place(spread, visible: 0...10, width: 1000, measure: { _ in 4 },
                                                 priority: { $0 == 4 })
        #expect(around.map { [$0.index, $0.line] } == [[0, 0], [1, 0], [2, 1], [4, 0]])

        // Matches crowd only each other: two on top of each other take both lines, a third is left out.
        let crowd = [word("x", 0), word("y", 0.1), word("z", 0.2), word("w", 5)]
        let matches = TranscriptStripLayout.place(crowd, visible: 0...10, width: 1000, measure: { _ in 40 },
                                                  priority: { _ in true })
        #expect(matches.map { [$0.index, $0.line] } == [[0, 0], [1, 1], [3, 0]])
    }

    @Test func placeWithNothingVisibleIsEmpty() {
        #expect(place([word("a", 1)], visible: 0...0).isEmpty)
        #expect(place([word("a", 1)], width: 0).isEmpty)
        #expect(place([]).isEmpty)
    }

    // MARK: Marks

    @MainActor @Test func marksMerge() throws {
        var index = TranscriptIndex()
        index.set(try Self.stored("voice.flac", voice: true))
        index.set(try Self.stored("noise.flac", voice: false))
        let marks = TranscriptMarks.marks(index: index, states: [
            "bad.flac": .failed("x"), "wait.flac": .queued, "busy.flac": .running,
        ])
        #expect(marks == ["voice.flac": .voice, "noise.flac": .possibleNoise, "bad.flac": .failed("x")])
    }

    @MainActor @Test func aFailureNeverHidesATranscript() throws {
        var index = TranscriptIndex()
        index.set(try Self.stored("voice.flac", voice: true))
        let marks = TranscriptMarks.marks(index: index, states: ["voice.flac": .failed("x")])
        #expect(marks == ["voice.flac": .voice])
    }

    /// A transcript filed under `file`: the saved 32 s voice reply, or a "silent" label with no chunks.
    private static func stored(_ file: String, voice: Bool) throws -> StoredTranscript {
        var chunks: [TranscriptChunk] = []
        if voice {
            let reply = try JSONDecoder().decode(WhisperResponse.self, from: Data(contentsOf: ScriptedTranscriber.voiceFixture))
            chunks = [TranscriptChunk(offsetSeconds: 0, response: reply)]
        }
        return StoredTranscript(file: file, model: "m", language: "en", createdAt: Date(timeIntervalSince1970: 0),
                                durationSeconds: 32, costUSD: nil, note: voice ? nil : "silent", chunks: chunks)
    }

    // MARK: Translated transcripts

    private func koreanTranscript(translation: Bool, note: String? = nil, language: String? = "korean") throws -> StoredTranscript {
        var t = try Self.stored("a.wav", voice: true)
        t.spokenLanguage = language
        if translation {
            t.translation = TranscriptTranslation(model: "m", segments: [
                TranslatedSegment(start: 1, end: 3, text: "Hello there my friend"),
            ], costUSD: nil)
        }
        t.translationNote = note
        return t
    }

    private func summary(_ t: StoredTranscript) -> TranscriptSummary? {
        TranscriptIndex([t.file: t]).summary(t.file)
    }

    @Test func stripShowsTheEnglishWithItsHeader() throws {
        let s = summary(try koreanTranscript(translation: true))
        guard case .words(let words, let text) = TranscriptStripContent.decide(summary: s, state: nil) else {
            Issue.record("expected words"); return
        }
        #expect(text == "Hello there my friend")
        #expect(words.map(\.text) == ["Hello", "there", "my", "friend"])
        #expect(words.first?.start == 1)
        #expect(TranscriptStripHeader.make(summary: s, showOriginal: false)
                == TranscriptStripHeader(text: "Translated from Korean", toggle: "Show original"))
    }

    @Test func toggleShowsTheOriginal() throws {
        let t = try koreanTranscript(translation: true)
        let s = summary(t)
        let original = TranscriptStripContent.decide(summary: s, state: nil, showOriginal: true)
        #expect(original == .words(TranscriptClassifier.classify(t.chunks).words, text: TranscriptClassifier.classify(t.chunks).text))
        #expect(TranscriptStripHeader.make(summary: s, showOriginal: true)
                == TranscriptStripHeader(text: "Translated from Korean", toggle: "Show English"))
    }

    @Test func emptyTranslationShowsNoHeader() throws {
        var t = try koreanTranscript(translation: true)
        t.translation?.segments = [TranslatedSegment(start: 1, end: 3, text: "")]
        let s = summary(t)
        #expect(s?.englishWords == nil)
        #expect(TranscriptStripHeader.make(summary: s, showOriginal: false) == nil)
    }

    @Test func languageNameIsCapitalisedOrUpperCased() {
        #expect(TranscriptStripHeader.languageName("korean") == "Korean")
        #expect(TranscriptStripHeader.languageName("ko") == "KO")
    }

    @Test func untranslatedTranscriptHasNoHeader() throws {
        let english = summary(try koreanTranscript(translation: false, language: "english"))
        #expect(TranscriptStripHeader.make(summary: english, showOriginal: false) == nil)
        let v1 = summary(try koreanTranscript(translation: false, language: nil))
        #expect(TranscriptStripHeader.make(summary: v1, showOriginal: true) == nil)
        #expect(TranscriptStripHeader.make(summary: nil, showOriginal: false) == nil)
    }

    @Test func noteShowsWhenTranslationFailed() throws {
        let note = "Couldn't translate: the reply wasn't a translation."
        let s = summary(try koreanTranscript(translation: false, note: note))
        #expect(TranscriptStripHeader.make(summary: s, showOriginal: false) == TranscriptStripHeader(text: note, toggle: nil))
        // The original words still show.
        if case .words = TranscriptStripContent.decide(summary: s, state: nil) {} else { Issue.record("expected words") }
    }

    // MARK: What the strip says

    @Test func stripContentFollowsTheStateOfTheRecording() {
        let voice = TranscriptSummary(verdict: .voice, words: [word("hi", 1)], text: "hi")
        let noise = TranscriptSummary(verdict: .possibleNoise, words: [], text: "")
        typealias C = TranscriptStripContent
        #expect(C.decide(summary: voice, state: nil) == .words([word("hi", 1)], text: "hi"))
        #expect(C.decide(summary: noise, state: nil) == .noise)
        #expect(C.decide(summary: nil, state: .failed("no network")) == .failed("no network"))
        #expect(C.decide(summary: nil, state: .queued) == .transcribing)
        #expect(C.decide(summary: nil, state: .running) == .transcribing)
        #expect(C.decide(summary: nil, state: nil) == .notTranscribed)
        // Transcribe Again on a transcribed recording: running wins over the old words, queued does not.
        #expect(C.decide(summary: voice, state: .running) == .transcribing)
        #expect(C.decide(summary: voice, state: .queued) == .words([word("hi", 1)], text: "hi"))
    }

    /// A recording waiting in a blocked queue is not being transcribed: it says why, as the chip does.
    @Test func aQueuedRecordingInABlockedQueueSaysWhy() {
        typealias C = TranscriptStripContent
        let voice = TranscriptSummary(verdict: .voice, words: [word("hi", 1)], text: "hi")
        #expect(C.decide(summary: nil, state: .queued, blocked: .rejectedKey) == .failed("OpenRouter rejected the key"))
        #expect(C.decide(summary: nil, state: .queued, blocked: .outOfCredit) == .failed("OpenRouter account is out of credit"))
        #expect(C.decide(summary: nil, state: .queued, blocked: .outOfCredit).message
                == "Couldn't transcribe — OpenRouter account is out of credit")
        #expect(C.decide(summary: nil, state: .queued, blocked: nil) == .transcribing)
        #expect(C.decide(summary: nil, state: .running, blocked: .rejectedKey) == .transcribing)
        #expect(C.decide(summary: voice, state: .queued, blocked: .rejectedKey) == .words([word("hi", 1)], text: "hi"))
        #expect(C.decide(summary: nil, state: nil, blocked: .rejectedKey) == .notTranscribed)
    }

    @Test func fewWordsAreStillPossibleNoise() {
        // The classifier needs 3 kept words for Voice: two words are Possible noise, as the badge says.
        let two = TranscriptSummary(verdict: .possibleNoise, words: [word("hi", 1), word("there", 2)], text: "hi there")
        #expect(TranscriptStripContent.decide(summary: two, state: nil) == .noise)
        #expect(TranscriptStripContent.decide(summary: two, state: .running) == .transcribing)
    }

    @Test func stripAndWaveformShareTheScrubbingRange() {
        var zoom = WaveformZoom()
        zoom.scale = 10
        // A scrub holds the range at the playhead from when it began, wherever the playhead has got to.
        let held = zoom.shownRange(duration: 100, position: 60, anchor: 20)
        #expect(held == zoom.visibleRange(duration: 100, playhead: 20))
        #expect(held != zoom.visibleRange(duration: 100, playhead: 60))
        #expect(zoom.shownRange(duration: 100, position: 60, anchor: nil) == zoom.visibleRange(duration: 100, playhead: 60))
        // The same words land at the same x on either side of a position change while anchored.
        let words = [word("a", 17), word("b", 22)]
        func xs(position: Double) -> [CGFloat] {
            TranscriptStripLayout.place(words, visible: zoom.shownRange(duration: 100, position: position, anchor: 20),
                                        width: 1000) { _ in 10 }.map(\.x)
        }
        #expect(xs(position: 20) == xs(position: 60))
    }

    @Test func stripCopy() {
        #expect(TranscriptStripContent.noise.message == "Possible noise — no clear speech")
        #expect(TranscriptStripContent.failed("no network").message == "Couldn't transcribe — no network")
        #expect(TranscriptStripContent.transcribing.message == "Transcribing…")
        #expect(TranscriptStripContent.notTranscribed.message == "Not transcribed")
    }

    @Test func currentWordIsTheOneBeingSpoken() {
        let w = word("hi", 1, 1.5)
        #expect(!TranscriptStrip.isCurrent(w, position: 0.99))
        #expect(TranscriptStrip.isCurrent(w, position: 1))
        #expect(TranscriptStrip.isCurrent(w, position: 1.49))
        #expect(!TranscriptStrip.isCurrent(w, position: 1.5))
    }
}
