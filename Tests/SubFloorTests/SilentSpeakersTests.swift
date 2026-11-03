import Testing
@testable import SubFloor

/// The test run plays nothing through the speakers: the radio's output and the recording player run at no volume.
@Suite struct SilentSpeakersTests {
    @Test func testsPlayNothingAloud() {
        #expect(AudioOutput.speakersSilenced)
        #expect(AudioOutput().engine.mainMixerNode.outputVolume == 0)
    }
}
