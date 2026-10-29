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
