import Foundation

/// An OpenRouter `verbose_json` speech-to-text reply, as Whisper returns it. Only the fields the
/// classifier and the word strip use are modelled; the rest (`id`, `seek`, `tokens`, `temperature`,
/// `task`) is ignored on decode. The reply is stored whole in the sidecar, so a better classifier
/// can re-run over it later without paying to transcribe again.
public struct WhisperResponse: Codable, Equatable, Sendable {
    public var text: String
    public var language: String?
    public var duration: Double?
    public var segments: [Segment]?
    public var words: [Word]?
    public var usage: Usage?

    public init(text: String, language: String? = nil, duration: Double? = nil,
                segments: [Segment]? = nil, words: [Word]? = nil, usage: Usage? = nil) {
        self.text = text
        self.language = language
        self.duration = duration
        self.segments = segments
        self.words = words
        self.usage = usage
    }

    /// A phrase Whisper decoded, with its own confidence signals. A model that leaves a signal out
    /// leaves it `nil`, and the classifier skips that check.
    public struct Segment: Codable, Equatable, Sendable {
        public var start: Double, end: Double, text: String
        /// Mean token log-probability: near 0 is confident, below -1 is a guess.
        public var avgLogprob: Double?
        /// Chance the segment holds no speech at all, 0...1.
        public var noSpeechProb: Double?
        /// How compressible the text is; a high ratio means Whisper looped on itself.
        public var compressionRatio: Double?

        public init(start: Double, end: Double, text: String,
                    avgLogprob: Double? = nil, noSpeechProb: Double? = nil, compressionRatio: Double? = nil) {
            self.start = start
            self.end = end
            self.text = text
            self.avgLogprob = avgLogprob
            self.noSpeechProb = noSpeechProb
            self.compressionRatio = compressionRatio
        }

        private enum CodingKeys: String, CodingKey {
            case start, end, text
            case avgLogprob = "avg_logprob"
            case noSpeechProb = "no_speech_prob"
            case compressionRatio = "compression_ratio"
        }
    }

    /// One word with its time in the audio that was sent, in seconds. The text keeps Whisper's
    /// leading space and its punctuation.
    public struct Word: Codable, Equatable, Sendable {
        public var word: String, start: Double, end: Double

        public init(word: String, start: Double, end: Double) {
            self.word = word
            self.start = start
            self.end = end
        }
    }

    /// What the reply cost: seconds of audio billed and dollars.
    public struct Usage: Codable, Equatable, Sendable {
        public var seconds: Double?, cost: Double?

        public init(seconds: Double? = nil, cost: Double? = nil) {
            self.seconds = seconds
            self.cost = cost
        }
    }
}

/// The reply for one piece of a recording, and where that piece starts in the whole file. A short
/// recording is one chunk at offset 0; a long one is cut into pieces that are sent separately.
public struct TranscriptChunk: Codable, Equatable, Sendable {
    public var offsetSeconds: Double
    public var response: WhisperResponse

    public init(offsetSeconds: Double, response: WhisperResponse) {
        self.offsetSeconds = offsetSeconds
        self.response = response
    }
}
