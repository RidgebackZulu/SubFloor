import Testing
@testable import Scheduling

@Test func outcomeTexts() {
    #expect(RunOutcome.recorded(seconds: 28 * 60 + 10, files: 1).text == "Recorded 28 min")
    #expect(RunOutcome.recorded(seconds: 14 * 60, files: 3).text == "Recorded 3 transmissions, 14 min")
    #expect(RunOutcome.recorded(seconds: 20, files: 1).text == "Recorded 1 min")
    #expect(RunOutcome.recorded(seconds: 14 * 60 + 40, files: 1).text == "Recorded 15 min")
    #expect(RunOutcome.nothingHeard(watch: false).text == "Nothing heard: the squelch never opened")
    #expect(RunOutcome.nothingHeard(watch: true).text == "Nothing heard: no voice came on")
    #expect(RunOutcome.missedNoRSP.text == "Missed: the RSP wasn't connected")
    #expect(RunOutcome.missedNotRunning.text == "Missed: SubFloor wasn't running")
    #expect(RunOutcome.missedAsleep.text == "Missed: the Mac was asleep")
    #expect(RunOutcome.stoppedByYou.text == "Stopped by you")
    #expect(RunOutcome.overlapped(with: "Radio Habana Cuba").text == "Overlapped with Radio Habana Cuba")
    #expect(RunOutcome.rspLost(afterSeconds: 12 * 60).text == "The RSP disconnected after 12 min")
    #expect(RunOutcome.lowDisk.text == "Stopped: less than 100 MB free")
}
