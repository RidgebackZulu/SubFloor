import Foundation

/// What the UI needs to know about one transcript: its verdict, the kept words and a searchable form of the text.
public struct TranscriptSummary: Equatable, Sendable {
    public var verdict: TranscriptVerdict
    public var words: [TranscriptWord]
    public var text: String
    /// `text` through `TranscriptSearch.normalize`, ready to match terms against.
    public var searchText: String
    /// The language Whisper reported, or nil.
    public var spokenLanguage: String?
    /// The English translation's text, or nil when there is none. `searchText` covers it as well as `text`.
    public var english: String?
    /// The translation's kept words, timed against the recording; nil when there is no translation.
    public var englishWords: [TranscriptWord]?
    /// Why a wanted translation is missing, or nil.
    public var translationNote: String?

    public init(verdict: TranscriptVerdict, words: [TranscriptWord], text: String,
                spokenLanguage: String? = nil, english: String? = nil,
                englishWords: [TranscriptWord]? = nil, translationNote: String? = nil) {
        self.verdict = verdict
        self.words = words
        self.text = text
        self.spokenLanguage = spokenLanguage
        self.english = english
        self.englishWords = englishWords
        self.translationNote = translationNote
        self.searchText = TranscriptSearch.normalize(english.map { text + " " + $0 } ?? text)
    }
}

/// An in-memory view of a folder's sidecars, keyed by recording file name. Each transcript is run
/// through the classifier when it is added, so the verdict always reflects the current rules.
public struct TranscriptIndex: Equatable, Sendable {
    private var summaries: [String: TranscriptSummary] = [:]

    public init(_ stored: [String: StoredTranscript] = [:]) {
        for t in stored.values { set(t) }
    }

    /// Classifies `t` and files it under its recording, replacing any earlier entry. Search covers the
    /// original's words and the translation's.
    public mutating func set(_ t: StoredTranscript) {
        let c = TranscriptClassifier.classify(t.chunks)
        // A translation whose words were all dropped has nothing to show: treat it as none for display.
        let english = t.translation == nil ? [] : TranscriptClassifier.classify(t.englishChunks).words
        summaries[t.file] = TranscriptSummary(verdict: c.verdict, words: c.words, text: c.text,
                                              spokenLanguage: t.spokenLanguage, english: t.translation?.text,
                                              englishWords: english.isEmpty ? nil : english,
                                              translationNote: t.translationNote)
    }

    public func summary(_ file: String) -> TranscriptSummary? { summaries[file] }

    public func contains(_ file: String) -> Bool { summaries[file] != nil }

    /// Every recording that has a transcript.
    public var files: Dictionary<String, TranscriptSummary>.Keys { summaries.keys }

    /// True when the recording has a transcript and every term appears in its text. An empty `terms`
    /// matches any transcribed recording, so a blank query filters nothing; an untranscribed one never matches.
    public func matches(_ file: String, terms: [String]) -> Bool {
        guard let s = summaries[file] else { return false }
        return terms.allSatisfy { s.searchText.contains($0) }
    }
}

/// Matching for the search field: forgiving about case, accents and punctuation.
public enum TranscriptSearch {
    /// Case- and diacritic-folded, punctuation removed, whitespace collapsed.
    public static func normalize(_ s: String) -> String {
        TranscriptClassifier.normalize(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
    }

    /// The query's words, normalized. Blank (or all punctuation) gives `[]`, which means no filter.
    public static func terms(_ query: String) -> [String] {
        normalize(query).split(separator: " ").map(String.init)
    }

    /// True when the word, normalized, contains any of `terms`. Used to light up words in the transcript strip.
    public static func wordMatches(_ word: String, terms: [String]) -> Bool {
        let w = normalize(word)
        return terms.contains { w.contains($0) }
    }
}
