import Foundation
import SubFloorCore
import Testing
@testable import SubFloor

/// The transcription settings (saved with the session) and the OpenRouter key (kept in a key store,
/// never in the session). Fake keys and an in-memory store only.
@MainActor
@Suite(.serialized)
struct TranscriptionSettingsTests {
    private func makeModel(defaults: UserDefaults? = nil, dir: URL? = nil,
                           store: MemoryAPIKeyStore = MemoryAPIKeyStore()) -> (AppModel, URL) {
        let dir = dir ?? FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorSTTTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                         defaults: defaults ?? UserDefaults(suiteName: UUID().uuidString)!,
                         apiKeyStore: store)
        m.recording.folderPath = dir.appendingPathComponent("rec").path
        return (m, dir)
    }

    @Test func settingsPersist() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let (m, dir) = makeModel(defaults: defaults)
        m.transcriptionSettings.model = "other/model"
        m.transcriptionSettings.language = nil
        let stamped = m.transcriptionSettings.enabledSince
        #expect(stamped != nil)
        m.shutdown()   // saves the session
        let (again, _) = makeModel(defaults: defaults, dir: dir)
        defer { again.shutdown() }
        #expect(again.transcriptionSettings.model == "other/model")
        #expect(again.transcriptionSettings.language == nil)
        #expect(again.transcriptionSettings.enabled)
        // The saved stamp comes back; a relaunch does not re-stamp it.
        #expect(again.transcriptionSettings.enabledSince == stamped)
    }

    @Test func oldSessionDecodes() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let (m, dir) = makeModel(defaults: defaults)
        m.skipSilence = false   // a non-default field: it comes back only if the whole session decodes
        m.shutdown()
        // A session saved before transcripts: the same JSON without the `transcription` field.
        let saved = try #require(defaults.data(forKey: "session"))
        var json = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(json.removeValue(forKey: "transcription") != nil)
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "session")
        let before = Date()
        let (again, _) = makeModel(defaults: defaults, dir: dir)
        defer { again.shutdown() }
        #expect(!again.skipSilence)   // the rest of the old session was restored, not dropped
        #expect(again.transcriptionSettings.enabled)
        #expect(again.transcriptionSettings.model == TranscriptionSettings().model)
        #expect(again.transcriptionSettings.language == "en")
        let since = try #require(again.transcriptionSettings.enabledSince)
        #expect(since >= before && since <= Date())
    }

    @Test func firstLaunchStampsEnabledSince() throws {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        let since = try #require(m.transcriptionSettings.enabledSince)
        #expect(since <= Date())
    }

    @Test func toggleOnStampsEnabledSince() async throws {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        let first = try #require(m.transcriptionSettings.enabledSince)
        m.toggleTranscription()
        #expect(!m.transcriptionSettings.enabled)
        #expect(m.transcriptionSettings.enabledSince == first)   // turning off leaves it
        try await Task.sleep(for: .milliseconds(20))
        m.toggleTranscription()
        #expect(m.transcriptionSettings.enabled)
        #expect(try #require(m.transcriptionSettings.enabledSince) > first)
        // Setting the property directly stamps too, and a model change does not.
        m.transcriptionSettings.enabled = false
        try await Task.sleep(for: .milliseconds(20))
        m.transcriptionSettings.enabled = true
        let second = try #require(m.transcriptionSettings.enabledSince)
        m.transcriptionSettings.model = "x/y"
        #expect(m.transcriptionSettings.enabledSince == second)
    }

    @Test func keyNeverInSession() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = MemoryAPIKeyStore()
        let (m, _) = makeModel(defaults: defaults, store: store)
        try m.saveAPIKey("  sk-or-secret \n")
        m.transcriptionSettings.model = "x/y"   // forces a session save
        m.shutdown()
        let data = try #require(defaults.data(forKey: "session"))
        #expect(!String(decoding: data, as: UTF8.self).contains("sk-or-secret"))
        #expect(m.hasAPIKey)
        #expect(store.load() == "sk-or-secret")
    }

    @Test func keyLoadsAtInitAndRemoves() throws {
        let store = MemoryAPIKeyStore(key: "sk-test")
        let (m, _) = makeModel(store: store)
        defer { m.shutdown() }
        #expect(m.hasAPIKey)
        try m.saveAPIKey("   ")   // blank removes
        #expect(!m.hasAPIKey)
        #expect(store.load() == nil)
        try m.saveAPIKey("sk-again")
        try m.removeAPIKey()
        #expect(!m.hasAPIKey && store.load() == nil)
    }

    @Test func importFromEnv() throws {
        let store = MemoryAPIKeyStore()
        let (m, dir) = makeModel(store: store)
        defer { m.shutdown() }
        let good = dir.appendingPathComponent("good.env")
        try "OTHER=1\nOPENROUTER=sk-test\n".write(to: good, atomically: true, encoding: .utf8)
        try m.importAPIKey(fromEnvFileAt: good)
        #expect(m.hasAPIKey)
        #expect(store.load() == "sk-test")

        let bad = dir.appendingPathComponent("bad.env")
        try "OTHER=1\n".write(to: bad, atomically: true, encoding: .utf8)
        #expect(throws: APIKeyImportError.noKey) { try m.importAPIKey(fromEnvFileAt: bad) }
        #expect(store.load() == "sk-test")   // left unchanged
        #expect(throws: (any Error).self) { try m.importAPIKey(fromEnvFileAt: dir.appendingPathComponent("missing.env")) }
        #expect(store.load() == "sk-test")
    }
}
