import Testing
@testable import SubFloor

/// The Transcription settings section's pure parts: the older-recordings button's text and the key status.
@Suite struct TranscriptionUITests {
    @Test func olderButtonCopy() {
        #expect(TranscriptionFormat.olderButton(count: 237, dollars: 0.0504) == "Transcribe 237 recordings (≈ $0.05)")
        #expect(TranscriptionFormat.olderButton(count: 237, dollars: nil) == "Transcribe 237 recordings")
        #expect(TranscriptionFormat.olderButton(count: 0, dollars: 0) == "All recordings transcribed")
        #expect(TranscriptionFormat.olderButton(count: 0, dollars: nil) == "All recordings transcribed")
        #expect(TranscriptionFormat.olderButton(count: 1, dollars: 0.004) == "Transcribe 1 recording (≈ $0.00)")
        #expect(TranscriptionFormat.olderButton(count: 1, dollars: nil) == "Transcribe 1 recording")
    }

    @Test func keyStatusCopy() {
        #expect(TranscriptionFormat.keyStatus(hasKey: true) == "Key saved ✓")
        #expect(TranscriptionFormat.keyStatus(hasKey: false) == "No key")
    }

    @Test func blankKeyFieldSavesNothing() {
        #expect(TranscriptionFormat.keyToSave("") == nil)
        #expect(TranscriptionFormat.keyToSave("  \n\t ") == nil)
        #expect(TranscriptionFormat.keyToSave("  sk-test \n") == "sk-test")
    }
}
