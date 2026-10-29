import Foundation
import Testing
@testable import Transcription

private func stored(_ file: String, fixture name: String) throws -> StoredTranscript {
    let response = try JSONDecoder().decode(WhisperResponse.self, from: fixtureData(name))
    return StoredTranscript(file: file, model: "m", language: "en", createdAt: Date(timeIntervalSince1970: 0),
                            durationSeconds: response.duration ?? 0, costUSD: nil, note: nil,
                            chunks: [TranscriptChunk(offsetSeconds: 0, response: response)])
}

/// A transcript whose only reply says `text`, with no confidence signals.
private func spoken(_ file: String, _ text: String) -> StoredTranscript {
    let response = WhisperResponse(text: text, duration: 5,
                                   segments: [.init(start: 0, end: 5, text: text)], words: nil, usage: nil)
    return StoredTranscript(file: file, model: "m", language: nil, createdAt: Date(timeIntervalSince1970: 0),
                            durationSeconds: 5, costUSD: nil, note: nil,
                            chunks: [TranscriptChunk(offsetSeconds: 0, response: response)])
}

@Suite struct TranscriptIndexTests {
    @Test func indexClassifiesOnLoad() throws {
        let index = TranscriptIndex(["voice.wav": try stored("voice.wav", fixture: "voice-clip-32s")])
        let summary = try #require(index.summary("voice.wav"))
        #expect(summary.verdict == .voice)
        #expect(summary.searchText.contains("dustmob"))
        #expect(!summary.words.isEmpty)
        #expect(index.contains("voice.wav"))
    }

    @Test func labelledWithoutSendingIsPossibleNoise() {
        let silent = StoredTranscript(file: "s.wav", model: "m", language: nil, createdAt: Date(), durationSeconds: 0,
                                      costUSD: nil, note: "silent", chunks: [])
        var index = TranscriptIndex()
        index.set(silent)
        #expect(index.summary("s.wav")?.verdict == .possibleNoise)
        #expect(index.summary("s.wav")?.text == "")
    }

    @Test func setReplacesAnEntry() {
        var index = TranscriptIndex(["a.wav": spoken("a.wav", "one two three")])
        index.set(spoken("a.wav", "four five six"))
        #expect(index.summary("a.wav")?.text == "four five six")
    }

    @Test func multiTermAnd() throws {
        let index = TranscriptIndex(["clock.wav": try stored("clock.wav", fixture: "SubFloor_20261028_140122Z_11175000Hz_USB")])
        #expect(index.matches("clock.wav", terms: TranscriptSearch.terms("dust traffic")))
        #expect(!index.matches("clock.wav", terms: TranscriptSearch.terms("dust banana")))
    }

    @Test func diacriticAndCase() {
        let index = TranscriptIndex(["a.wav": spoken("a.wav", "meet me at the cafe now")])
        #expect(index.matches("a.wav", terms: TranscriptSearch.terms("CAFÉ")))
        #expect(TranscriptSearch.wordMatches("Café,", terms: TranscriptSearch.terms("cafe")))
        #expect(!TranscriptSearch.wordMatches("tea", terms: TranscriptSearch.terms("cafe")))
        #expect(TranscriptSearch.normalize("  Crème-Brûlée!  ") == "cremebrulee")
    }

    @Test func blankQueryIsNoFilter() {
        #expect(TranscriptSearch.terms("   ") == [])
        #expect(TranscriptSearch.terms("") == [])
        #expect(TranscriptSearch.terms("  Dust   Traffic ") == ["dust", "traffic"])
        #expect(TranscriptSearch.terms("!!!") == [])
    }

    @Test func unknownFileNeverMatches() {
        let index = TranscriptIndex()
        #expect(index.summary("nope.wav") == nil)
        #expect(!index.contains("nope.wav"))
        #expect(!index.matches("nope.wav", terms: ["a"]))
        #expect(!index.matches("nope.wav", terms: []))
    }
}
