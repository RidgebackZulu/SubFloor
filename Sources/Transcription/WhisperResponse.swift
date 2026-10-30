import Foundation

/// An OpenRouter `verbose_json` speech-to-text reply, as Whisper returns it. Only the fields the
/// classifier and the word strip use are modelled; the rest (`id`, `seek`, `tokens`, `temperature`,
/// `task`) is ignored on decode. The sidecar keeps the reply whole as a `JSONValue` (see
/// `TranscriptChunk.raw`), so a better classifier can re-run over it later without paying to transcribe again.
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
///
/// The reply is stored exactly as it came (`raw`, saved under `"response"`), and read through `response`,
/// which is decoded from it. A sidecar whose reply does not decode as a `WhisperResponse` is unreadable.
public struct TranscriptChunk: Codable, Equatable, Sendable {
    public var offsetSeconds: Double
    /// The reply as OpenRouter sent it, every field kept.
    public let raw: JSONValue
    /// The reply as the classifier and the strip read it.
    public let response: WhisperResponse

    /// A chunk from a reply as it came. Throws when it is not a Whisper reply.
    public init(offsetSeconds: Double, raw: JSONValue) throws {
        self.offsetSeconds = offsetSeconds
        self.raw = raw
        self.response = try raw.decode(WhisperResponse.self)
    }

    /// A chunk from a decoded reply, keeping only what `WhisperResponse` models (tests and hand-built replies).
    public init(offsetSeconds: Double, response: WhisperResponse) {
        self.offsetSeconds = offsetSeconds
        // Encoding fails only for a NaN or infinite time, which no reply carries; such a chunk saves no reply.
        self.raw = (try? JSONValue(encoding: response)) ?? .null
        self.response = response
    }

    private enum CodingKeys: String, CodingKey { case offsetSeconds, response }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(offsetSeconds: c.decode(Double.self, forKey: .offsetSeconds), raw: c.decode(JSONValue.self, forKey: .response))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(offsetSeconds, forKey: .offsetSeconds)
        try c.encode(raw, forKey: .response)
    }
}
