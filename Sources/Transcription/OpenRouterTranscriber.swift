import Foundation

/// Sends one request and returns the raw reply. A seam so tests can script replies and never touch
/// the network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The real transport, over `URLSession.shared`.
public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Why a transcription request failed. Reasons never contain the API key.
public enum TranscriptionError: Error, Equatable, Sendable {
    /// 401 or 403: the key is wrong or revoked. Retrying cannot help.
    case rejectedKey
    /// 402: the OpenRouter account has no credit left.
    case outOfCredit
    /// Another 4xx, or a reply that could not be read. Retrying the same audio will fail the same way.
    case badRequest(String)
    /// A busy server or a dropped connection. Worth trying again later.
    case transient(String)

    /// The reason to show the user.
    public var message: String {
        switch self {
        case .rejectedKey: "OpenRouter rejected the key"
        case .outOfCredit: "OpenRouter account is out of credit"
        case .badRequest(let reason), .transient(let reason): reason
        }
    }

    /// Whether the queue should retry later.
    public var isRetryable: Bool {
        if case .transient = self { return true }
        return false
    }
}

/// What is saved beside a recording: every reply, whole, plus enough to re-classify it later.
/// A recording that was labelled without being sent has `note` set and no chunks.
public struct StoredTranscript: Codable, Equatable, Sendable {
    public var version: Int
    public var file: String
    public var model: String
    /// The language asked for, or nil for auto-detect.
    public var language: String?
    public var createdAt: Date
    public var durationSeconds: Double
    /// Dollars billed, or nil when OpenRouter reported none.
    public var costUSD: Double?
    /// "silent" or "too short" when labelled without sending; otherwise nil.
    public var note: String?
    public var chunks: [TranscriptChunk]

    public init(version: Int = 1, file: String, model: String, language: String?, createdAt: Date,
                durationSeconds: Double, costUSD: Double?, note: String?, chunks: [TranscriptChunk]) {
        self.version = version
        self.file = file
        self.model = model
        self.language = language
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.costUSD = costUSD
        self.note = note
        self.chunks = chunks
    }
}

/// Speech-to-text through OpenRouter's `/audio/transcriptions` endpoint.
public struct OpenRouterTranscriber: Sendable {
    public static let endpoint = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!
    public static let defaultModel = "openai/whisper-large-v3"
    /// Seconds to wait for one chunk's reply.
    public static let requestTimeout: TimeInterval = 90
    /// Dollars per second of audio, for the cost estimate shown before a batch is sent.
    public static let pricePerSecond: [String: Double] = ["openai/whisper-large-v3": 0.000008]

    private let apiKey: String
    private let model: String
    private let language: String?
    private let transport: any HTTPTransport

    /// `language` is an ISO 639-1 code, or nil to let the model detect it.
    public init(apiKey: String, model: String, language: String?, transport: any HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.transport = transport
    }

    private struct Body: Encodable {
        struct Audio: Encodable { var data: String, format: String }
        var model: String
        var inputAudio: Audio
        var responseFormat = "verbose_json"
        var timestampGranularities = ["word", "segment"]
        var language: String?

        private enum CodingKeys: String, CodingKey {
            case model, language
            case inputAudio = "input_audio"
            case responseFormat = "response_format"
            case timestampGranularities = "timestamp_granularities"
        }
    }

    /// The HTTP request for one chunk. Throws only if the JSON body cannot be encoded.
    public func request(for chunk: PreparedChunk) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            Body(model: model, inputAudio: .init(data: chunk.wav.base64EncodedString(), format: "wav"), language: language))
        return request
    }

    /// Sends one chunk and decodes the reply. Throws `TranscriptionError`, or `CancellationError`
    /// if the task was cancelled. A `URLError.cancelled` outside a cancelled task is a dropped
    /// connection, so it is `.transient`.
    public func transcribe(_ chunk: PreparedChunk) async throws -> WhisperResponse {
        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport.send(try request(for: chunk))
        } catch let error as CancellationError {
            throw error
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw TranscriptionError.transient(scrub(error.localizedDescription))
        } catch {
            throw TranscriptionError.badRequest(scrub("Could not send the request"))
        }
        switch http.statusCode {
        case 200:
            do { return try JSONDecoder().decode(WhisperResponse.self, from: data) } catch {
                throw TranscriptionError.badRequest("Unreadable reply from OpenRouter")
            }
        case 401, 403: throw TranscriptionError.rejectedKey
        case 402: throw TranscriptionError.outOfCredit
        case 408, 429, 500...599: throw TranscriptionError.transient("OpenRouter is busy (HTTP \(http.statusCode))")
        default: throw TranscriptionError.badRequest(scrub(errorMessage(in: data) ?? "HTTP \(http.statusCode)"))
        }
    }

    /// Sends a prepared recording and gathers the replies. A silent or too-short recording is
    /// labelled without a request.
    public func transcribe(file: String, audio: PreparedAudio, now: Date) async throws -> StoredTranscript {
        func stored(note: String?, seconds: Double, cost: Double?, chunks: [TranscriptChunk]) -> StoredTranscript {
            StoredTranscript(version: 1, file: file, model: model, language: language, createdAt: now,
                             durationSeconds: seconds, costUSD: cost, note: note, chunks: chunks)
        }
        switch audio {
        case .silent:
            return stored(note: "silent", seconds: 0, cost: nil, chunks: [])
        case .tooShort(let seconds):
            return stored(note: "too short", seconds: seconds, cost: nil, chunks: [])
        case .chunks(let prepared):
            var replies: [TranscriptChunk] = []
            for chunk in prepared {
                try Task.checkCancellation()
                replies.append(TranscriptChunk(offsetSeconds: chunk.offsetSeconds, response: try await transcribe(chunk)))
            }
            let costs = replies.compactMap { $0.response.usage?.cost }
            return stored(note: nil, seconds: prepared.reduce(0) { $0 + $1.seconds },
                          cost: costs.isEmpty ? nil : costs.reduce(0, +), chunks: replies)
        }
    }

    /// The app's transcription: reads and prepares the recording at `url`, then sends it, all on a
    /// detached task so the blocking decode never runs on the caller's executor (the main actor).
    /// Arguments: recording file name, its URL, model, language (nil for auto-detect), API key.
    /// Cancelling the caller cancels the work. A recording that cannot be read is `.badRequest`.
    public static let liveTranscribe: @Sendable (String, URL, String, String?, String) async throws -> StoredTranscript = {
        file, url, model, language, apiKey in
        let work = Task.detached(priority: .utility) { () async throws -> StoredTranscript in
            let audio: PreparedAudio
            do { audio = try TranscriptionAudio.prepare(url: url) } catch {
                throw TranscriptionError.badRequest("Couldn't read the recording: \(error.localizedDescription)")
            }
            return try await OpenRouterTranscriber(apiKey: apiKey, model: model, language: language)
                .transcribe(file: file, audio: audio, now: Date())
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    /// `{"error":{"message":"..."}}`, if the body has that shape.
    private func errorMessage(in data: Data) -> String? {
        struct Reply: Decodable { struct Failure: Decodable { var message: String? }; var error: Failure? }
        return (try? JSONDecoder().decode(Reply.self, from: data))?.error?.message
    }

    /// Hides the key if a server or system message echoes it.
    private func scrub(_ reason: String) -> String {
        apiKey.isEmpty ? reason : reason.replacingOccurrences(of: apiKey, with: "•••")
    }
}

/// The key is held privately, but Swift's default description, `dump` and `Mirror` print private
/// stored properties. These print it as "•••", so a transcriber in a log or a debugger shows no key.
extension OpenRouterTranscriber: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "OpenRouterTranscriber(apiKey: •••, model: \(model), language: \(language ?? "auto"))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["apiKey": "•••", "model": model, "language": language as Any,
                                "transport": String(describing: type(of: transport))],
               displayStyle: .struct)
    }
}
