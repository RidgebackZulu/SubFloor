import Foundation
import Testing
@testable import Transcription

/// A fresh empty folder standing in for a recordings folder; remove it with `defer`.
private func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "transcript-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func sample(_ file: String, text: String = "hello there") -> StoredTranscript {
    StoredTranscript(file: file, model: "m", language: "en", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                     durationSeconds: 4.5, costUSD: 0.00004, note: nil,
                     chunks: [TranscriptChunk(offsetSeconds: 0, response: WhisperResponse(text: text))])
}

@Suite struct TranscriptStoreTests {
    @Test func writeThenReadAll() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = sample("a.wav"), b = sample("b.wav", text: "second")
        try TranscriptStore.write(a, in: folder)
        try TranscriptStore.write(b, in: folder)

        #expect(FileManager.default.fileExists(atPath: folder.appending(path: ".subfloor/transcripts/a.wav.json").path))
        #expect(TranscriptStore.url(for: "b.wav", in: folder) == TranscriptStore.directory(in: folder).appending(path: "b.wav.json"))
        #expect(TranscriptStore.readAll(in: folder) == ["a.wav": a, "b.wav": b])
    }

    @Test func missingDirectoryReadsEmpty() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(TranscriptStore.readAll(in: folder).isEmpty)
    }

    @Test func rewriteReplacesTheSidecar() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try TranscriptStore.write(sample("a.wav", text: "old"), in: folder)
        let newer = sample("a.wav", text: "new")
        try TranscriptStore.write(newer, in: folder)
        #expect(TranscriptStore.readAll(in: folder) == ["a.wav": newer])
    }

    @Test func sidecarIsReadableJSON() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try TranscriptStore.write(sample("a.wav"), in: folder)
        let text = try String(contentsOf: TranscriptStore.url(for: "a.wav", in: folder), encoding: .utf8)
        #expect(text.contains("\"createdAt\" : \"2023-11-14T22:13:20Z\""))
        #expect(text.contains("\n"))
        #expect(try #require(text.range(of: "\"chunks\"")).lowerBound < #require(text.range(of: "\"file\"")).lowerBound)
    }

    @Test func corruptSidecarSkipped() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try TranscriptStore.write(sample("good.wav"), in: folder)
        try Data("not json {".utf8).write(to: TranscriptStore.url(for: "bad.wav", in: folder))
        try Data("ignored".utf8).write(to: TranscriptStore.directory(in: folder).appending(path: "notes.txt"))
        let all = TranscriptStore.readAll(in: folder)
        #expect(all.count == 1)
        #expect(all["good.wav"] != nil)
    }

    /// The reply is kept whole, not just the fields the classifier reads: Whisper's per-segment `temperature`,
    /// `tokens`, `seek` and `id`, and the top-level `task`, survive a write, a read and a second write.
    @Test func rawReplySurvivesWriteThenReadAll() async throws {
        let first = try makeFolder(), second = try makeFolder()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let fixture = try fixtureData("voice-clip-32s")
        let stub = StubTransport(status: 200, body: fixture)
        let t = OpenRouterTranscriber(apiKey: "k-test", model: "openai/whisper-large-v3", language: "en", transport: stub)
        let audio = PreparedAudio.chunks([PreparedChunk(offsetSeconds: 0, seconds: 32, wav: Data([1, 2, 3, 4]))])
        try TranscriptStore.write(try await t.transcribe(file: "voice.wav", audio: audio, now: Date()), in: first)
        let read = try #require(TranscriptStore.readAll(in: first)["voice.wav"])
        try TranscriptStore.write(read, in: second)

        func reply(_ data: Data) throws -> [String: Any] {
            let sidecar = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let chunks = try #require(sidecar["chunks"] as? [[String: Any]])
            return try #require(chunks.first?["response"] as? [String: Any])
        }
        let sent = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        let kept = try reply(Data(contentsOf: TranscriptStore.url(for: "voice.wav", in: second)))
        #expect(kept["task"] as? String == "transcribe")
        let sentSegment = try #require((sent["segments"] as? [[String: Any]])?.first)
        let keptSegment = try #require((kept["segments"] as? [[String: Any]])?.first)
        #expect(keptSegment["temperature"] as? Double == sentSegment["temperature"] as? Double)
        #expect(keptSegment["temperature"] != nil)
        #expect(keptSegment["tokens"] as? [Int] == sentSegment["tokens"] as? [Int])
        #expect((keptSegment["tokens"] as? [Int])?.isEmpty == false)
        #expect(keptSegment["seek"] as? Int == sentSegment["seek"] as? Int && keptSegment["seek"] != nil)
        #expect(keptSegment["id"] != nil)
        // What the classifier reads is still there, decoded from the kept reply.
        #expect(read.chunks.first?.response.words?.count == 46)
    }

    @Test func jsonValueKeepsEveryKind() throws {
        let json = #"{"a":true,"b":1,"c":-0.5470000000000001,"d":null,"e":[0,"x",false],"f":{"g":50364}}"#
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(v == .object(["a": .bool(true), "b": .number(1), "c": .number(-0.5470000000000001), "d": .null,
                              "e": .array([.number(0), .string("x"), .bool(false)]), "f": .object(["g": .number(50364)])]))
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(v)) == v)
    }

    @Test func sidecarNeverContainsKey() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = "sk-or-secret"
        let stub = StubTransport(status: 200, body: try fixtureData("voice-clip-32s"))
        let t = OpenRouterTranscriber(apiKey: key, model: "openai/whisper-large-v3", language: "en", transport: stub)
        let audio = PreparedAudio.chunks([PreparedChunk(offsetSeconds: 0, seconds: 32, wav: Data([1, 2, 3, 4]))])
        let stored = try await t.transcribe(file: "voice.wav", audio: audio, now: Date(timeIntervalSince1970: 5))
        try TranscriptStore.write(stored, in: folder)

        let bytes = try Data(contentsOf: TranscriptStore.url(for: "voice.wav", in: folder))
        #expect(!bytes.isEmpty)
        #expect(bytes.range(of: Data(key.utf8)) == nil)
        #expect(stub.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)")   // the stub did see it
    }
}
