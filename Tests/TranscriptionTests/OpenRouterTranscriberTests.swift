import Foundation
import Testing
@testable import Transcription

/// Records every request and answers from a script; never touches the network.
private final class StubTransport: HTTPTransport, @unchecked Sendable {
    enum Step { case reply(Int, Data), fail(Error) }
    private let lock = NSLock()
    private var steps: [Step]
    private var sent: [URLRequest] = []

    init(_ steps: [Step]) { self.steps = steps }
    convenience init(status: Int, body: Data = Data()) { self.init([.reply(status, body)]) }

    var requests: [URLRequest] { lock.withLock { sent } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let step: Step = lock.withLock {
            sent.append(request)
            return steps.count > 1 ? steps.removeFirst() : steps[0]
        }
        switch step {
        case .fail(let error): throw error
        case .reply(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
    }
}

private func fixtureData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func chunk(offset: Double = 0, seconds: Double = 10) -> PreparedChunk {
    PreparedChunk(offsetSeconds: offset, seconds: seconds, wav: Data([1, 2, 3, 4]))
}

/// The request's JSON body.
private func body(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func errorBody(_ message: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["error": ["message": message]])
}

private func transcriber(_ transport: StubTransport, key: String = "k-test", language: String? = "en") -> OpenRouterTranscriber {
    OpenRouterTranscriber(apiKey: key, model: "openai/whisper-large-v3", language: language, transport: transport)
}

/// The error `transcribe` throws, or nil if it succeeded.
private func failure(_ t: OpenRouterTranscriber) async -> TranscriptionError? {
    do { _ = try await t.transcribe(chunk()); return nil } catch { return error as? TranscriptionError }
}

@Suite struct OpenRouterTranscriberTests {
    @Test func requestShape() throws {
        let t = transcriber(StubTransport(status: 200))
        let c = chunk()
        let r = try t.request(for: c)
        #expect(r.httpMethod == "POST")
        #expect(r.url == OpenRouterTranscriber.endpoint)
        #expect(r.url?.absoluteString == "https://openrouter.ai/api/v1/audio/transcriptions")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer k-test")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(r.timeoutInterval == 90)
        let json = try body(r)
        #expect(json["model"] as? String == "openai/whisper-large-v3")
        let audio = try #require(json["input_audio"] as? [String: Any])
        #expect(audio["format"] as? String == "wav")
        #expect(Data(base64Encoded: try #require(audio["data"] as? String)) == c.wav)
        #expect(json["response_format"] as? String == "verbose_json")
        #expect(json["timestamp_granularities"] as? [String] == ["word", "segment"])
        #expect(json["language"] as? String == "en")
    }

    @Test func autoLanguageOmitsKey() throws {
        let r = try transcriber(StubTransport(status: 200), language: nil).request(for: chunk())
        let json = try body(r)
        #expect(json["language"] == nil)
    }

    @Test func decodesFixture() async throws {
        let stub = StubTransport(status: 200, body: try fixtureData("voice-clip-32s"))
        let response = try await transcriber(stub).transcribe(chunk())
        #expect(response.words?.count == 46)
    }

    @Test func unreadableReplyIsBadRequest() async {
        let e = await failure(transcriber(StubTransport(status: 200, body: Data("not json".utf8))))
        #expect(e == .badRequest("Unreadable reply from OpenRouter"))
    }

    @Test func statusMapping() async {
        #expect(await failure(transcriber(StubTransport(status: 401))) == .rejectedKey)
        #expect(await failure(transcriber(StubTransport(status: 403))) == .rejectedKey)
        #expect(await failure(transcriber(StubTransport(status: 402))) == .outOfCredit)
        #expect(await failure(transcriber(StubTransport(status: 429))) == .transient("OpenRouter is busy (HTTP 429)"))
        #expect(await failure(transcriber(StubTransport(status: 408))) == .transient("OpenRouter is busy (HTTP 408)"))
        #expect(await failure(transcriber(StubTransport(status: 503))) == .transient("OpenRouter is busy (HTTP 503)"))
        #expect(await failure(transcriber(StubTransport(status: 400, body: errorBody("bad format")))) == .badRequest("bad format"))
        #expect(await failure(transcriber(StubTransport(status: 400, body: Data("<html>".utf8)))) == .badRequest("HTTP 400"))
        let offline = await failure(transcriber(StubTransport([.fail(URLError(.notConnectedToInternet))])))
        guard case .transient = offline else { Issue.record("expected transient, got \(String(describing: offline))"); return }
    }

    @Test func retryability() {
        #expect(TranscriptionError.transient("x").isRetryable)
        #expect(!TranscriptionError.rejectedKey.isRetryable)
        #expect(!TranscriptionError.outOfCredit.isRetryable)
        #expect(!TranscriptionError.badRequest("x").isRetryable)
        #expect(TranscriptionError.rejectedKey.message == "OpenRouter rejected the key")
        #expect(TranscriptionError.outOfCredit.message == "OpenRouter account is out of credit")
    }

    @Test func errorMessagesNeverContainKey() async throws {
        let key = "sk-or-secret"
        let echo = StubTransport(status: 400, body: errorBody("Invalid key \(key) for model"))
        let e = try #require(await failure(transcriber(echo, key: key)))
        #expect(e.message.contains("•••"))
        #expect(!e.message.contains(key))

        let urlError = URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "failed for \(key)"])
        let t = try #require(await failure(transcriber(StubTransport([.fail(urlError)]), key: key)))
        #expect(!t.message.contains(key))
        #expect(t.message.contains("•••"))
    }

    @Test func silentNeedsNoRequest() async throws {
        let stub = StubTransport(status: 200)
        let s = try await transcriber(stub).transcribe(file: "a.wav", audio: .silent, now: Date(timeIntervalSince1970: 5))
        #expect(stub.requests.isEmpty)
        #expect(s.note == "silent")
        #expect(s.chunks.isEmpty)
        #expect(s.durationSeconds == 0)
        #expect(s.costUSD == nil)
        #expect(s.version == 1)
        #expect(s.file == "a.wav")
        #expect(s.createdAt == Date(timeIntervalSince1970: 5))
        #expect(s.language == "en")
    }

    @Test func tooShortNeedsNoRequest() async throws {
        let stub = StubTransport(status: 200)
        let s = try await transcriber(stub).transcribe(file: "a.wav", audio: .tooShort(seconds: 0.3), now: Date())
        #expect(stub.requests.isEmpty)
        #expect(s.note == "too short")
        #expect(s.durationSeconds == 0.3)
        #expect(s.chunks.isEmpty)
    }

    @Test func chunksSentInOrderWithOffsets() async throws {
        func reply(_ text: String, cost: Double?) -> Data {
            try! JSONEncoder().encode(WhisperResponse(text: text, usage: .init(seconds: 1, cost: cost)))
        }
        let stub = StubTransport([.reply(200, reply("first", cost: 0.25)), .reply(200, reply("second", cost: 0.5))])
        let audio = PreparedAudio.chunks([chunk(offset: 0, seconds: 112), chunk(offset: 112, seconds: 20)])
        let s = try await transcriber(stub, language: nil).transcribe(file: "long.wav", audio: audio, now: Date())
        #expect(stub.requests.count == 2)
        #expect(s.chunks.map(\.response.text) == ["first", "second"])
        #expect(s.chunks[1].offsetSeconds == 112)
        #expect(s.durationSeconds == 132)
        #expect(s.costUSD == 0.75)
        #expect(s.language == nil)
        #expect(s.note == nil)
        #expect(s.model == "openai/whisper-large-v3")
    }

    @Test func costNilWhenUnreported() async throws {
        let body = try JSONEncoder().encode(WhisperResponse(text: "hi"))
        let s = try await transcriber(StubTransport(status: 200, body: body))
            .transcribe(file: "a.wav", audio: .chunks([chunk()]), now: Date())
        #expect(s.costUSD == nil)
    }

    @Test func storedTranscriptRoundTrips() throws {
        let s = StoredTranscript(version: 1, file: "a.wav", model: "m", language: nil, createdAt: Date(timeIntervalSince1970: 0),
                                 durationSeconds: 3, costUSD: 0.1, note: nil,
                                 chunks: [TranscriptChunk(offsetSeconds: 0, response: WhisperResponse(text: "x"))])
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(StoredTranscript.self, from: data) == s)
    }

    @Test func constants() {
        #expect(OpenRouterTranscriber.defaultModel == "openai/whisper-large-v3")
        #expect(OpenRouterTranscriber.requestTimeout == 90)
        #expect(OpenRouterTranscriber.pricePerSecond["openai/whisper-large-v3"] == 0.000008)
    }
}
