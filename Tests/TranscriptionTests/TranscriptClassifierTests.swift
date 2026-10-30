import Foundation
import Testing
@testable import Transcription

/// A real OpenRouter Whisper reply saved from one of the owner's recordings.
private func fixture(_ name: String) throws -> WhisperResponse {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(WhisperResponse.self, from: Data(contentsOf: url))
}

private func classify(_ name: String, offset: Double = 0) throws -> ClassifiedTranscript {
    TranscriptClassifier.classify([TranscriptChunk(offsetSeconds: offset, response: try fixture(name))])
}

/// A reply with one segment and no per-segment confidence signals unless given.
private func reply(text: String, start: Double = 0, end: Double = 5, avgLogprob: Double? = nil,
                   noSpeechProb: Double? = nil, compressionRatio: Double? = nil,
                   words: [WhisperResponse.Word]? = nil) -> WhisperResponse {
    WhisperResponse(text: text, language: nil, duration: end, segments: [
        .init(start: start, end: end, text: text, avgLogprob: avgLogprob,
              noSpeechProb: noSpeechProb, compressionRatio: compressionRatio)],
                    words: words, usage: nil)
}

@Suite struct TranscriptClassifierTests {
    @Test func voiceClipIsVoice() throws {
        let t = try classify("voice-clip-32s")
        #expect(t.verdict == .voice)
        #expect(t.words.contains { $0.text == "Dustmob," })
        #expect(t.words.last?.text != "sorry.")
        #expect(t.words.count == 44)
    }

    @Test func clockClipIsVoice() throws {
        let t = try classify("SubFloor_20261028_140122Z_11175000Hz_USB")
        #expect(t.verdict == .voice)
        #expect(t.words.count == 27)
    }

    @Test func borderlineClipIsVoice() throws {
        let t = try classify("SubFloor_20261027_200017Z_11175000Hz_USB")
        #expect(t.verdict == .voice)
        #expect(t.text == "I see. This is All right. Hi. Monogram. Now.")
    }

    @Test(arguments: [
        "SubFloor_20261028_015603Z_10086000Hz_AM",
        "SubFloor_20261028_025305Z_11175000Hz_USB",
        "SubFloor_20261028_031415Z_11175000Hz_USB",
        "SubFloor_20261028_134251Z_11175000Hz_USB",
    ])
    func noiseClipsArePossibleNoise(name: String) throws {
        let t = try classify(name)
        #expect(t.verdict == .possibleNoise)
        #expect(t.words.isEmpty)
    }

    @Test func stockPhraseDropped() {
        let words = [WhisperResponse.Word(word: " Thank", start: 0, end: 1),
                     .init(word: " you", start: 1, end: 2),
                     .init(word: " for", start: 2, end: 3),
                     .init(word: " watching!", start: 3, end: 4)]
        let r = reply(text: " Thank you for watching!", avgLogprob: -0.2, words: words)
        let t = TranscriptClassifier.classify([TranscriptChunk(offsetSeconds: 0, response: r)])
        #expect(t.words.isEmpty)
        #expect(t.verdict == .possibleNoise)
    }

    @Test func missingSignalsSkipChecks() {
        let r = reply(text: " this is kilo one two", start: 10, end: 15)
        let t = TranscriptClassifier.classify([TranscriptChunk(offsetSeconds: 0, response: r)])
        #expect(t.verdict == .voice)
        #expect(t.words.map(\.text) == ["this", "is", "kilo", "one", "two"])
        for (i, w) in t.words.enumerated() {
            #expect(abs(w.start - (10 + Double(i))) < 1e-9)
            #expect(abs(w.end - (11 + Double(i))) < 1e-9)
        }
    }

    @Test func chunkOffsetsShiftWords() throws {
        let plain = try classify("voice-clip-32s")
        let shifted = try classify("voice-clip-32s", offset: 120)
        let first = try #require(shifted.words.first)
        #expect(abs(first.start - 121.23) < 0.01)
        #expect(shifted.words.count == plain.words.count)
        #expect(zip(plain.words, shifted.words).allSatisfy { abs($1.start - $0.start - 120) < 1e-9 && abs($1.end - $0.end - 120) < 1e-9 })
    }

    @Test func emptyIsPossibleNoise() {
        let t = TranscriptClassifier.classify([])
        #expect(t.verdict == .possibleNoise)
        #expect(t.words.isEmpty)
        #expect(t.text.isEmpty)
    }

    @Test func eachSignalDropsItsSegment() {
        let text = " one two three four"
        for (lp, ns, cr) in [(-1.01, 0.0, 1.0), (-0.3, 0.61, 1.0), (-0.3, 0.0, 2.41)] {
            let r = reply(text: text, avgLogprob: lp, noSpeechProb: ns, compressionRatio: cr)
            #expect(TranscriptClassifier.classify([.init(offsetSeconds: 0, response: r)]).words.isEmpty)
        }
        // exactly at a limit is kept
        let edge = reply(text: text, avgLogprob: -1.0, noSpeechProb: 0.6, compressionRatio: 2.4)
        #expect(TranscriptClassifier.classify([.init(offsetSeconds: 0, response: edge)]).words.count == 4)
    }

    @Test func annotationsAreRecognised() {
        for s in ["*car engine noise*", "[BLANK_AUDIO]", "(music)", "*Humming* [noise] .", ".", "", "  ...  "] {
            #expect(TranscriptClassifier.isAnnotation(s), "\(s)")
        }
        for s in ["hello", "Hi.", "(music) hello", "*a* b"] {
            #expect(!TranscriptClassifier.isAnnotation(s), "\(s)")
        }
    }

    @Test func normalizeStripsPunctuationAndCase() {
        #expect(TranscriptClassifier.normalize("  Thank   YOU, for watching! ") == "thank you for watching")
        #expect(TranscriptClassifier.normalize("Subtitles by the Amara.org community") == "subtitles by the amaraorg community")
        #expect(TranscriptClassifier.normalize("...") == "")
    }

    @Test func fewWordsIsNotVoice() {
        let r = reply(text: " roger that", avgLogprob: -0.3)
        let t = TranscriptClassifier.classify([.init(offsetSeconds: 0, response: r)])
        #expect(t.words.count == 2)
        #expect(t.verdict == .possibleNoise)
    }

    /// Whisper splits an annotation into words (" *car", " engine", " noise*"). Inside a segment that passes the
    /// confidence checks, the words between the marks are dropped with the marks, so "engine noise" never counts
    /// towards Voice.
    @Test func annotationWordsInsideAKeptSegmentAreDropped() {
        let words = [WhisperResponse.Word(word: " *car", start: 0, end: 0.5), .init(word: " engine", start: 0.5, end: 1),
                     .init(word: " noise*", start: 1, end: 1.5), .init(word: " Roger.", start: 2, end: 2.5),
                     .init(word: " (static", start: 3, end: 3.5), .init(word: " hiss)", start: 3.5, end: 4),
                     .init(word: " [music", start: 4, end: 4.2), .init(word: " playing]", start: 4.2, end: 4.6)]
        let r = reply(text: " *car engine noise* Roger. (static hiss) [music playing]", avgLogprob: -0.3, words: words)
        let t = TranscriptClassifier.classify([TranscriptChunk(offsetSeconds: 0, response: r)])
        #expect(t.words.map(\.text) == ["Roger."])
        #expect(t.verdict == .possibleNoise)

        // The same without word timing: the segment's own words are filtered the same way.
        let pseudo = reply(text: " *car engine noise* Roger, this is kilo.", avgLogprob: -0.3)
        #expect(TranscriptClassifier.classify([.init(offsetSeconds: 0, response: pseudo)]).words.map(\.text)
                == ["Roger,", "this", "is", "kilo."])

        // A span never runs into the next segment.
        let two = WhisperResponse(text: "", segments: [
            .init(start: 0, end: 1, text: " *Humming", avgLogprob: -0.3), .init(start: 1, end: 3, text: " one two three", avgLogprob: -0.3)])
        #expect(TranscriptClassifier.classify([.init(offsetSeconds: 0, response: two)]).words.map(\.text) == ["one", "two", "three"])
    }

    /// A stock phrase behind an annotation is still a stock phrase.
    @Test func stockPhraseBehindAnAnnotationIsDropped() {
        let r = reply(text: " *music* Thank you.", avgLogprob: -0.3,
                      words: [.init(word: " *music*", start: 0, end: 1), .init(word: " Thank", start: 1, end: 2), .init(word: " you.", start: 2, end: 3)])
        #expect(TranscriptClassifier.classify([.init(offsetSeconds: 0, response: r)]).words.isEmpty)
    }

    @Test func whisperResponseDecodesSnakeCaseKeys() throws {
        let json = #"{"text":"a","segments":[{"id":0,"start":1,"end":2,"text":"a","avg_logprob":-0.5,"no_speech_prob":0.1,"compression_ratio":1.2}]}"#
        let r = try JSONDecoder().decode(WhisperResponse.self, from: Data(json.utf8))
        let s = try #require(r.segments?.first)
        #expect(s.avgLogprob == -0.5 && s.noSpeechProb == 0.1 && s.compressionRatio == 1.2)
        let back = try JSONDecoder().decode(WhisperResponse.self, from: JSONEncoder().encode(r))
        #expect(back == r)
    }
}
