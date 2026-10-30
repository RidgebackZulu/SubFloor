import Foundation

/// A word that survived the classifier, timed against the whole recording file.
public struct TranscriptWord: Codable, Equatable, Sendable {
    /// The word with surrounding spaces trimmed; punctuation is kept.
    public var text: String
    /// File-relative seconds.
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// What a transcript says about a recording. Only ever a label: nothing is deleted on either one.
public enum TranscriptVerdict: String, Codable, Sendable {
    /// Real words came back.
    case voice
    /// Nothing usable came back: noise, or speech too weak to transcribe.
    case possibleNoise
}

/// The kept words of a recording and the verdict they earn.
public struct ClassifiedTranscript: Equatable, Sendable {
    public var verdict: TranscriptVerdict
    public var words: [TranscriptWord]
    /// The kept words joined by single spaces.
    public var text: String

    public init(verdict: TranscriptVerdict, words: [TranscriptWord], text: String) {
        self.verdict = verdict
        self.words = words
        self.text = text
    }
}

/// The guard against Whisper's invented text on noise ("Thank you for watching", "*car engine
/// noise*", a lone "."). It is a pure function over the stored raw replies, so it is applied when a
/// transcript is loaded and can change later without re-transcribing anything.
public enum TranscriptClassifier {
    /// A segment more likely than this to hold no speech is dropped.
    public static let maxNoSpeechProb = 0.6
    /// A segment less confident than this is dropped.
    public static let minAvgLogprob = -1.0
    /// A segment more repetitive than this (Whisper looping) is dropped.
    public static let maxCompressionRatio = 2.4
    /// Kept words needed for a recording to count as voice.
    public static let minVoiceWords = 3
    /// Whisper's habitual output on silence, normalized (see `normalize`).
    public static let stockPhrases: Set<String> = [
        "thank you", "thanks for watching", "thank you for watching", "thank you so much for watching",
        "please subscribe", "subtitles by the amaraorg community", "you", "bye",
    ]

    /// Lowercased, with punctuation and symbols removed, whitespace collapsed and the ends trimmed.
    public static func normalize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.lowercased().unicodeScalars {
            if scalar.properties.isWhitespace { out.append(" ") }
            else if isPunctuationOrSymbol(scalar) { continue }
            else { out.append(scalar) }
        }
        return String(out).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// True when nothing is left of `s` once its `*…*`, `[…]` and `(…)` spans and punctuation are removed.
    public static func isAnnotation(_ s: String) -> Bool {
        normalize(withoutAnnotations(s)).isEmpty
    }

    /// `s` with its closed `*…*`, `[…]` and `(…)` spans replaced by spaces.
    static func withoutAnnotations(_ s: String) -> String {
        s.replacing(/\*[^*]*\*|\[[^\]]*\]|\([^)]*\)/, with: " ")
    }

    /// Drops the segments that look like invented text, keeps the words that fall inside the rest,
    /// and shifts every time by its chunk's offset. Fewer than `minVoiceWords` words is possible noise.
    public static func classify(_ chunks: [TranscriptChunk]) -> ClassifiedTranscript {
        let words = chunks.flatMap(keptWords)
        let text = words.map(\.text).joined(separator: " ")
        return ClassifiedTranscript(verdict: words.count >= minVoiceWords ? .voice : .possibleNoise,
                                    words: words, text: text)
    }

    // MARK: - Internals

    private static func isPunctuationOrSymbol(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: true
        default: false
        }
    }

    /// A segment survives when every signal it carries is within bounds, and its text, once its annotations
    /// are taken out, is neither empty nor a stock phrase. A signal it does not carry is not checked.
    private static func keeps(_ seg: WhisperResponse.Segment) -> Bool {
        if let p = seg.noSpeechProb, p > maxNoSpeechProb { return false }
        if let lp = seg.avgLogprob, lp < minAvgLogprob { return false }
        if let r = seg.compressionRatio, r > maxCompressionRatio { return false }
        let n = normalize(withoutAnnotations(seg.text))
        return !n.isEmpty && !stockPhrases.contains(n)
    }

    /// The kept segments' words, each word given to the first kept segment its middle falls in. Whisper splits
    /// an annotation into words (" *car", " engine", " noise*"), so a `*`, `(` or `[` opened in one word is
    /// followed across the segment's words, and every word from the opening mark to the closing one is
    /// dropped. A span never runs past its segment.
    private static func keptWords(in chunk: TranscriptChunk) -> [TranscriptWord] {
        let kept = (chunk.response.segments ?? []).filter(keeps)
        guard !kept.isEmpty else { return [] }
        let offset = chunk.offsetSeconds
        let timed: [(segment: Int, word: WhisperResponse.Word)]
        if let words = chunk.response.words, !words.isEmpty {
            timed = words.compactMap { w in
                let mid = (w.start + w.end) / 2
                return kept.firstIndex { mid >= $0.start && mid <= $0.end }.map { ($0, w) }
            }
        } else {
            // A model without word timing: spread each segment's text.
            timed = kept.enumerated().flatMap { i, seg in pseudoWords(of: seg).map { (i, $0) } }
        }
        var segment = -1
        var closer: Character?   // the mark that ends the open span, if one is open
        return timed.compactMap { seg, w in
            if seg != segment { segment = seg; closer = nil }
            let text = w.word.trimmingCharacters(in: .whitespacesAndNewlines)
            let wasInSpan = closer != nil
            closer = spanCloser(after: text, from: closer)
            guard !wasInSpan, closer == nil, !normalize(text).isEmpty, !isAnnotation(text) else { return nil }
            return TranscriptWord(text: text, start: w.start + offset, end: w.end + offset)
        }
    }

    /// The closing mark still awaited once `text` is read, starting with `closer` awaited: nil when no
    /// annotation is left open.
    private static func spanCloser(after text: String, from closer: Character?) -> Character? {
        var closer = closer
        for ch in text {
            if let c = closer {
                if ch == c { closer = nil }
            } else {
                switch ch {
                case "*": closer = "*"
                case "(": closer = ")"
                case "[": closer = "]"
                default: break
                }
            }
        }
        return closer
    }

    /// The segment's words, each given an equal share of the segment's time span.
    private static func pseudoWords(of seg: WhisperResponse.Segment) -> [WhisperResponse.Word] {
        let parts = seg.text.split(whereSeparator: \.isWhitespace)
        guard !parts.isEmpty else { return [] }
        let step = (seg.end - seg.start) / Double(parts.count)
        return parts.enumerated().map { i, part in
            .init(word: String(part), start: seg.start + step * Double(i), end: seg.start + step * Double(i + 1))
        }
    }
}
