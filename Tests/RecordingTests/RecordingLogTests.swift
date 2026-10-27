import Foundation
import Testing
@testable import Recording

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingLogTests-\(UUID().uuidString)", isDirectory: true)
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

private func lines(_ url: URL) throws -> [String] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
}

@Suite struct RecordingLogTests {
    @Test func entriesRoundTripThroughTheDayFile() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = RecordingLog(folder: dir)
        let start = utc(2026, 10, 26, 14, 30, 0.25)
        let entries: [RecordingLogEntry] = [
            .recording(file: "SubFloor_20261026_143000Z_146520000Hz_NFM.wav", start: start, seconds: 12.5, frequencyHz: 146_520_000, mode: "NFM", auto: true),
            .pop(at: utc(2026, 10, 26, 14, 31, 5.5), seconds: 0.3, frequencyHz: 146_520_000, mode: "NFM"),
            .heard(file: "SubFloor_20261026_143000Z_146520000Hz_NFM.wav", at: utc(2026, 10, 26, 15, 0, 1.125)),
        ]
        try log.append(entries)
        #expect(try log.entries(forUTCDay: start) == entries)
        #expect(log.fileURL(forUTCDay: start) == dir.appendingPathComponent(".subfloor/2026-10-26.jsonl"))
        let written = try lines(log.fileURL(forUTCDay: start))
        #expect(written.count == 3)
        #expect(written[0].contains("\"start\":\"2026-10-26T14:30:00.250Z\""))
        #expect(written[0].contains("\"file\":\"SubFloor_20261026_143000Z_146520000Hz_NFM.wav\""))
    }

    @Test func entriesLandInTheirUTCDay() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = RecordingLog(folder: dir)
        let pop1 = RecordingLogEntry.pop(at: utc(2026, 10, 26, 23, 59, 59.5), seconds: 0.2, frequencyHz: 100e6, mode: "WFM")
        let rec = RecordingLogEntry.recording(file: "a.wav", start: utc(2026, 10, 26, 23, 59, 50), seconds: 30, frequencyHz: 100e6, mode: "WFM", auto: true)
        let pop2 = RecordingLogEntry.pop(at: utc(2026, 10, 27, 0, 0, 0.2), seconds: 0.2, frequencyHz: 100e6, mode: "WFM")
        try log.append([pop1, rec, pop2])
        let day26 = utc(2026, 10, 26, 12, 0, 0), day27 = utc(2026, 10, 27, 12, 0, 0)
        #expect(try log.entries(forUTCDay: day26) == [pop1, rec])
        #expect(try log.entries(forUTCDay: day27) == [pop2])
        #expect(log.fileURL(forUTCDay: day27).lastPathComponent == "2026-10-27.jsonl")
    }

    @Test func appendKeepsEarlierLines() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let day = utc(2026, 10, 26, 8, 0, 0)
        let a = RecordingLogEntry.pop(at: day, seconds: 0.1, frequencyHz: 1e6, mode: "AM")
        let b = RecordingLogEntry.heard(file: "x.wav", at: day.addingTimeInterval(60))
        try RecordingLog(folder: dir).append([a])
        try RecordingLog(folder: dir).append([b])
        try RecordingLog(folder: dir).append([])
        #expect(try RecordingLog(folder: dir).entries(forUTCDay: day) == [a, b])
    }

    @Test func aDayWithNoFileIsEmpty() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try RecordingLog(folder: dir).entries(forUTCDay: utc(2026, 1, 1, 0, 0, 0)) == [])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".subfloor").path))
    }

    @Test func aCorruptLineIsSkipped() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = RecordingLog(folder: dir)
        let day = utc(2026, 10, 26, 8, 0, 0)
        let a = RecordingLogEntry.pop(at: day, seconds: 0.1, frequencyHz: 1e6, mode: "AM")
        let b = RecordingLogEntry.pop(at: day.addingTimeInterval(5), seconds: 0.2, frequencyHz: 1e6, mode: "AM")
        try log.append([a])
        let handle = try FileHandle(forWritingTo: log.fileURL(forUTCDay: day))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"pop\",\"at\":\n\nnot json at all\n{\"type\":\"mystery\"}\n".utf8))
        try handle.close()
        try log.append([b])
        #expect(try log.entries(forUTCDay: day) == [a, b])
    }

    @Test func aTornLastLineDoesNotSwallowTheNextEntry() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = RecordingLog(folder: dir)
        let day = utc(2026, 10, 26, 8, 0, 0)
        let a = RecordingLogEntry.pop(at: day, seconds: 0.1, frequencyHz: 1e6, mode: "AM")
        let b = RecordingLogEntry.pop(at: day.addingTimeInterval(5), seconds: 0.2, frequencyHz: 1e6, mode: "AM")
        try log.append([a])
        let handle = try FileHandle(forWritingTo: log.fileURL(forUTCDay: day))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"pop\",\"at\":\"2026".utf8))   // no newline
        try handle.close()
        try log.append([b])
        #expect(try log.entries(forUTCDay: day) == [a, b])
    }
}
