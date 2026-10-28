import Foundation
import Testing
@testable import Recording

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingsCatalogTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A UTC instant, with fractional seconds.
private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Double) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    let base = c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: 0))!
    return base.addingTimeInterval(s)
}

/// UTC midnight.
private func day(_ y: Int, _ mo: Int, _ d: Int) -> Date { utc(y, mo, d, 0, 0, 0) }

private let usb = "SubFloor_20261027_183219Z_11175000Hz_USB.flac"
private let am = "SubFloor_20261027_090000Z_6925000Hz_AM.flac"

@Suite struct RecordingsCatalogTests {
    @Test func parsesRecordingNames() {
        let n = RecordingFileName.parse("SubFloor_20261027_183219Z_11175000Hz_USB.flac")!
        #expect(n.start == utc(2026, 10, 27, 18, 32, 19)); #expect(n.frequencyHz == 11_175_000)
        #expect(n.label == "USB"); #expect(n.fileExtension == "flac"); #expect(n.isAudio)
        #expect(RecordingFileName.parse("SubFloor_20261027_183219Z_11175000Hz_USB_2.wav")?.label == "USB")
        #expect(RecordingFileName.parse("SubFloor_20261027_150938Z_11125000Hz_IQ.wav")?.isAudio == false)
        #expect(RecordingFileName.parse("SubFloor_20261027_183219Z_11175000Hz_USB.txt")?.isAudio == false)
        #expect(RecordingFileName.parse("notes.txt") == nil)
        #expect(RecordingFileName.parse("SubFloor_2026_bad.flac") == nil)
        #expect(RecordingFileName.parse("SubFloor_20261327_183219Z_11175000Hz_USB.flac") == nil)
        #expect(RecordingFileName.parse("SubFloor_20261027_183219Z_11175000Hz_USB_x.flac") == nil)
    }

    @Test func laneTitles() {
        #expect(RecordingsCatalog.laneTitle(frequencyHz: 11_175_000, mode: "USB") == "11.175 MHz USB")
        #expect(RecordingsCatalog.laneTitle(frequencyHz: 6_925_000, mode: "AM") == "6.925 MHz AM")
        #expect(RecordingsCatalog.laneTitle(frequencyHz: 7_000_000, mode: "LSB") == "7.000 MHz LSB")
        #expect(RecordingsCatalog.laneTitle(frequencyHz: 14_074_500, mode: "USB") == "14.0745 MHz USB")
    }

    @Test func logEntriesWinOverTheName() {
        var c = RecordingsCatalog(files: [usb])
        c.apply([.recording(file: usb, start: utc(2026, 10, 27, 18, 32, 18.75), seconds: 61.5,
                            frequencyHz: 11_175_000, mode: "USB", auto: true)])
        let r = c.recording(usb)!
        #expect(r.start == utc(2026, 10, 27, 18, 32, 18.75))
        #expect(r.seconds == 61.5); #expect(r.auto); #expect(r.mode == "USB")
        #expect(r.laneID == "11175000 USB"); #expect(!r.inProgress)
        #expect(c.recordings(onUTCDay: day(2026, 10, 27)) == [r])
    }

    @Test func autoStartedWithoutEndHasNoLength() {
        var c = RecordingsCatalog(files: [usb])
        c.apply([.autoStarted(file: usb, start: utc(2026, 10, 27, 18, 32, 18.5), frequencyHz: 11_175_000, mode: "USB")])
        let r = c.recording(usb)!
        #expect(r.seconds == nil); #expect(r.auto); #expect(!r.heard)
        #expect(r.start == utc(2026, 10, 27, 18, 32, 18.5))
        #expect(c.unheardFiles == [usb])
    }

    @Test func recordingEntryReplacesAutoStarted() {
        var c = RecordingsCatalog(files: [usb])
        c.apply([.autoStarted(file: usb, start: utc(2026, 10, 27, 18, 32, 18.5), frequencyHz: 11_175_000, mode: "USB")])
        c.apply([.recording(file: usb, start: utc(2026, 10, 27, 18, 32, 18.5), seconds: 30, frequencyHz: 11_175_000, mode: "USB", auto: true)])
        #expect(c.recording(usb)?.seconds == 30)
        #expect(c.unheardCount == 1)
    }

    @Test func filesWithoutLogEntriesAreHeardAndManual() {
        let part2 = "SubFloor_20261027_183219Z_11175000Hz_USB_2.wav"
        let c = RecordingsCatalog(files: [usb, part2, "notes.txt", "SubFloor_20261027_150938Z_11125000Hz_IQ.wav"])
        let all = c.recordings(onUTCDay: day(2026, 10, 27))
        #expect(all.map(\.file) == [usb, part2])
        #expect(all.allSatisfy { $0.heard && !$0.auto && $0.seconds == nil && $0.mode == "USB" && $0.frequencyHz == 11_175_000 })
        #expect(c.unheardCount == 0)
        #expect(c.files == [usb, part2, "notes.txt", "SubFloor_20261027_150938Z_11125000Hz_IQ.wav"])
    }

    @Test func deletedFilesVanish() {
        var c = RecordingsCatalog(files: [usb, am])
        c.apply([
            .recording(file: usb, start: utc(2026, 10, 27, 18, 32, 19), seconds: 10, frequencyHz: 11_175_000, mode: "USB", auto: true),
            .recording(file: am, start: utc(2026, 10, 27, 9, 0, 0), seconds: 10, frequencyHz: 6_925_000, mode: "AM", auto: true),
        ])
        #expect(c.unheardCount == 2)
        c.setFiles([am])
        #expect(c.recording(usb) == nil)
        #expect(c.recordings(onUTCDay: day(2026, 10, 27)).map(\.file) == [am])
        #expect(c.unheardCount == 1)
        c.setFiles([usb, am])   // it comes back, with its log facts
        #expect(c.recording(usb)?.seconds == 10)
    }

    @Test func heardInALaterDaysLogCounts() {
        var c = RecordingsCatalog(files: [usb])
        c.apply([.recording(file: usb, start: utc(2026, 10, 27, 18, 32, 19), seconds: 10, frequencyHz: 11_175_000, mode: "USB", auto: true)])
        #expect(c.unheardFiles == [usb])
        c.apply([.heard(file: usb, at: utc(2026, 10, 28, 8, 0, 0))])
        #expect(c.recording(usb)?.heard == true)
        #expect(c.unheardFiles.isEmpty)
        #expect(c.recordings(onUTCDay: day(2026, 10, 28)).isEmpty)
    }

    @Test func unheardCountsOnlyFinishedRecordings() {
        let live = LiveRecording(file: usb, start: utc(2026, 10, 27, 18, 32, 19), seconds: 5, frequencyHz: 11_175_000, mode: "USB", auto: true)
        var c = RecordingsCatalog(files: [usb, am], live: live)
        c.apply([
            .autoStarted(file: usb, start: live.start, frequencyHz: 11_175_000, mode: "USB"),
            .recording(file: am, start: utc(2026, 10, 27, 9, 0, 0), seconds: 10, frequencyHz: 6_925_000, mode: "AM", auto: true),
        ])
        let r = c.recording(usb)!
        #expect(r.inProgress); #expect(!r.heard); #expect(r.seconds == 5); #expect(r.auto)
        #expect(c.unheardFiles == [am])
        #expect(c.unheardCount == 1)
        c.setLive(nil)   // it ends: now it counts
        #expect(c.recording(usb)?.inProgress == false)
        #expect(c.unheardFiles == [am, usb].sorted())
    }

    @Test func liveRecordingAppearsBeforeTheListingDoes() {
        let live = LiveRecording(file: usb, start: utc(2026, 10, 27, 18, 32, 19), seconds: 2.5, frequencyHz: 11_175_000, mode: "USB", auto: false)
        let c = RecordingsCatalog(files: [], live: live)
        let r = c.recordings(onUTCDay: day(2026, 10, 27))
        #expect(r.map(\.file) == [usb]); #expect(r.first?.seconds == 2.5); #expect(r.first?.inProgress == true)
        #expect(c.lanes(onUTCDay: day(2026, 10, 27)).map(\.id) == ["11175000 USB"])
    }

    @Test func lanesPerFrequencyAndMode() {
        let files = [
            "SubFloor_20261027_100000Z_11175000Hz_USB.flac",
            "SubFloor_20261027_110000Z_6925000Hz_USB.flac",
            "SubFloor_20261027_120000Z_6925000Hz_AM.flac",
            "SubFloor_20261027_130000Z_11175000Hz_USB.flac",
        ]
        let c = RecordingsCatalog(files: files)
        let lanes = c.lanes(onUTCDay: day(2026, 10, 27))
        #expect(lanes.map(\.title) == ["6.925 MHz AM", "6.925 MHz USB", "11.175 MHz USB"])
        #expect(lanes.map(\.id) == ["6925000 AM", "6925000 USB", "11175000 USB"])
        #expect(lanes.map(\.frequencyHz) == [6_925_000, 6_925_000, 11_175_000])
        #expect(c.lanes(onUTCDay: day(2026, 10, 28)).isEmpty)
    }

    @Test func popsByUTCDay() {
        var c = RecordingsCatalog()
        c.apply([
            .pop(at: utc(2026, 10, 28, 0, 0, 0.5), seconds: 0.2, frequencyHz: 146_520_000, mode: "NFM"),
            .pop(at: utc(2026, 10, 27, 23, 59, 59.9), seconds: 0.3, frequencyHz: 146_520_000, mode: "NFM"),
            .pop(at: utc(2026, 10, 27, 1, 0, 0), seconds: 0.1, frequencyHz: 7_000_000, mode: "LSB"),
        ])
        let pops = c.pops(onUTCDay: day(2026, 10, 27))
        #expect(pops == [CatalogPop(at: utc(2026, 10, 27, 1, 0, 0), seconds: 0.1, frequencyHz: 7_000_000, mode: "LSB"),
                         CatalogPop(at: utc(2026, 10, 27, 23, 59, 59.9), seconds: 0.3, frequencyHz: 146_520_000, mode: "NFM")])
        #expect(c.pops(onUTCDay: day(2026, 10, 28)).count == 1)
    }

    @Test func recordingCrossingMidnightStaysOnItsStartDay() {
        let name = "SubFloor_20261027_233000Z_11175000Hz_USB.flac"
        var c = RecordingsCatalog(files: [name])
        c.apply([.recording(file: name, start: utc(2026, 10, 27, 23, 30, 0), seconds: 3600, frequencyHz: 11_175_000, mode: "USB", auto: false)])
        #expect(c.recordings(onUTCDay: day(2026, 10, 27)).map(\.file) == [name])
        #expect(c.recordings(onUTCDay: day(2026, 10, 28)).isEmpty)
    }

    @Test func measuredSecondsFillLegacyLengths() {
        var c = RecordingsCatalog(files: [usb])
        #expect(c.recording(usb)?.seconds == nil)
        c.setMeasuredSeconds(42, for: usb)
        #expect(c.recording(usb)?.seconds == 42)
        c.apply([.recording(file: usb, start: utc(2026, 10, 27, 18, 32, 19), seconds: 7, frequencyHz: 11_175_000, mode: "USB", auto: false)])
        #expect(c.recording(usb)?.seconds == 7)   // the log's length wins over a measurement
    }

    @Test func recordingsAreSortedByStart() {
        let c = RecordingsCatalog(files: [usb, am])
        #expect(c.recordings(onUTCDay: day(2026, 10, 27)).map(\.file) == [am, usb])
    }

    @Test func theDayFollowsTheLogNotTheName() {
        // The name says the 27th; the log says the recording began a second before midnight on the 26th.
        let name = "SubFloor_20261027_000000Z_11175000Hz_USB.flac"
        var c = RecordingsCatalog(files: [name])
        #expect(c.recordings(onUTCDay: day(2026, 10, 27)).map(\.file) == [name])
        c.apply([.autoStarted(file: name, start: utc(2026, 10, 26, 23, 59, 59), frequencyHz: 11_175_000, mode: "USB")])
        #expect(c.recordings(onUTCDay: day(2026, 10, 27)).isEmpty)
        #expect(c.recordings(onUTCDay: day(2026, 10, 26)).map(\.file) == [name])
        c.setFiles([])
        #expect(c.recordings(onUTCDay: day(2026, 10, 26)).isEmpty)
        #expect(c.unheardCount == 0)
        c.setFiles([name])   // back, with its log facts and unheard again
        #expect(c.recordings(onUTCDay: day(2026, 10, 26)).map(\.file) == [name])
        #expect(c.unheardFiles == [name])
    }

    @Test func anUnchangedListingIsNotAChange() {
        var c = RecordingsCatalog(files: [usb, am])
        let same = c.setFiles([am, usb]), fewer = c.setFiles([am])
        #expect(!same)
        #expect(fewer)
        #expect(c.files == [am])
    }

    @Test func aLineAppliedTwiceCountsOnce() {
        let pop = RecordingLogEntry.pop(at: utc(2026, 10, 27, 1, 0, 0.25), seconds: 0.2, frequencyHz: 7_000_000, mode: "LSB")
        let rec = RecordingLogEntry.recording(file: usb, start: utc(2026, 10, 27, 18, 32, 19), seconds: 10,
                                              frequencyHz: 11_175_000, mode: "USB", auto: true)
        var c = RecordingsCatalog(files: [usb], entries: [pop, rec])
        c.apply([pop, rec])
        #expect(c.pops(onUTCDay: day(2026, 10, 27)).count == 1)
        #expect(c.recordings(onUTCDay: day(2026, 10, 27)).count == 1)
        #expect(c.unheardCount == 1)
    }

    @Test func anAbsurdLoggedFrequencyDoesNotTrap() {
        var c = RecordingsCatalog(files: [usb, am])
        c.apply([
            .recording(file: usb, start: utc(2026, 10, 27, 18, 32, 19), seconds: 10, frequencyHz: 1e300, mode: "USB", auto: true),
            .recording(file: am, start: utc(2026, 10, 27, 9, 0, 0), seconds: 10, frequencyHz: -1e300, mode: "AM", auto: true),
        ])
        let lanes = c.lanes(onUTCDay: day(2026, 10, 27))
        #expect(lanes.count == 2)
        #expect(Set(lanes.map(\.id)).count == 2)
    }

    @Test func allEntriesReadsEveryDay() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = RecordingLog(folder: dir)
        #expect(try log.allEntries().isEmpty)
        let later = RecordingLogEntry.heard(file: usb, at: utc(2026, 10, 28, 8, 0, 0))
        let earlier = RecordingLogEntry.recording(file: usb, start: utc(2026, 10, 27, 18, 32, 19), seconds: 10,
                                                  frequencyHz: 11_175_000, mode: "USB", auto: true)
        try log.append([later])
        try log.append([earlier])
        try "not json\n".write(to: log.fileURL(forUTCDay: day(2026, 10, 26)), atomically: true, encoding: .utf8)
        try "ignored".write(to: dir.appendingPathComponent(".subfloor/notes.txt"), atomically: true, encoding: .utf8)
        #expect(try log.allEntries() == [earlier, later])
    }

    @Test func oneUnreadableDayDoesNotLoseTheOthers() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = RecordingLog(folder: dir)
        let a = RecordingLogEntry.heard(file: usb, at: utc(2026, 10, 26, 8, 0, 0))
        let b = RecordingLogEntry.heard(file: am, at: utc(2026, 10, 27, 8, 0, 0))
        try log.append([a, b])
        let bad = log.fileURL(forUTCDay: day(2026, 10, 26))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: bad.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bad.path) }
        let read = log.readableEntries()
        #expect(read.entries == [b])
        #expect(read.failure != nil)
        #expect(throws: (any Error).self) { try log.allEntries() }   // the strict read still fails
    }

    @Test func anEntryAsLoggedMatchesItsLineReadBack() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = RecordingLog(folder: dir)
        let pop = RecordingLogEntry.pop(at: Date(timeIntervalSince1970: 1_793_100_000.123456789), seconds: 0.2,
                                        frequencyHz: 7_000_000, mode: "LSB")
        try log.append([pop])
        let back = try log.allEntries()
        #expect(back != [pop])            // the file keeps milliseconds
        #expect(back == [pop.asLogged])
    }
}
