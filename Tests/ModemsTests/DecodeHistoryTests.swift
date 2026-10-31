import Foundation
import Testing
@testable import Modems

// Times are UTC; `day0` is 2026-10-01 00:00:00Z.

private let day0 = Date(timeIntervalSince1970: 1_790_812_800)

private func tempFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("DecodeHistoryTests-\(UUID().uuidString)")
}

private func heard(_ t: TimeInterval, mode: ModeID = .ft8, rfHz: Double = 14_074_000 + 1_500, snr: Float = -10,
                   _ message: String) -> HeardDecode {
    HeardDecode.from(SlotDecode(mode: mode, slotStart: day0.addingTimeInterval(t), frequencyHz: 1_500,
                                snrDb: snr, timeOffset: 0, message: message), rfHz: rfHz)
}

private func files(_ folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
}

struct DecodeHistoryTests {
    @Test func parsesTheMessageIntoTheRecord() throws {
        let h = heard(0, "CQ K1ABC FN42")
        #expect(h.mode == "ft8")
        #expect(h.kind == "cq")
        #expect(h.from == "K1ABC")
        #expect(h.grid == "FN42")
        #expect(abs(try #require(h.lat) - 42.5) < 0.01)
        #expect(abs(try #require(h.lon) - -71.0) < 0.01)
        #expect(h.audioHz == 1_500)
        #expect(h.rfHz == 14_075_500)
        #expect(h.time == day0)
        let free = heard(0, "TNX BOB 73 GL")
        #expect(free.kind == "other")
        #expect(free.from == nil && free.lat == nil)
    }

    @Test func appendsToTheUTCDayFile() {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = DecodeHistory(folder: folder, now: { day0.addingTimeInterval(2 * 86_400) })
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        history.append([heard(-10, "CQ K1ABC FN42"), heard(10, "CQ W1AW FN31")])
        history.flush()
        // 23:59:50Z on 2026-09-30 and 00:00:10Z on 2026-10-01.
        #expect(files(folder) == ["2026-09-30.jsonl", "2026-10-01.jsonl"])
        #expect(history.decodes(since: .distantPast).count == 2)
    }

    @Test func queriesNewestFirstAndByMode() {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = DecodeHistory(folder: folder, now: { day0.addingTimeInterval(3_600) })
        history.append([heard(0, "CQ K1ABC FN42"), heard(30, mode: .wspr, "W1AW FN31 37"), heard(15, "CQ N0CALL EM10")])
        let all = history.decodes(since: day0)
        #expect(all.map(\.from) == ["W1AW", "N0CALL", "K1ABC"])
        #expect(history.decodes(since: day0, mode: "ft8").map(\.from) == ["N0CALL", "K1ABC"])
        #expect(history.decodes(since: day0.addingTimeInterval(10), until: day0.addingTimeInterval(20)).map(\.from) == ["N0CALL"])
    }

    @Test func readsBackWhatAnEarlierRunWrote() {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let now: @Sendable () -> Date = { day0.addingTimeInterval(3_600) }
        let first = DecodeHistory(folder: folder, now: now)
        first.append([heard(0, "CQ K1ABC FN42")])
        first.flush()
        let second = DecodeHistory(folder: folder, now: now)
        #expect(second.decodes(since: day0).map(\.from) == ["K1ABC"])
        second.append([heard(60, "CQ W1AW FN31")])
        #expect(second.decodes(since: day0).map(\.from) == ["W1AW", "K1ABC"])
    }

    @Test func olderThanAWeekComesFromTheDayFiles() {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = DecodeHistory(folder: folder, now: { day0 })
        writer.append([heard(0, "CQ K1ABC FN42")])
        writer.flush()
        let reader = DecodeHistory(folder: folder, now: { day0.addingTimeInterval(20 * 86_400) })
        #expect(reader.decodes(since: day0.addingTimeInterval(-60)).map(\.from) == ["K1ABC"])
        #expect(reader.decodes(since: day0.addingTimeInterval(86_400)).isEmpty)
    }

    @Test func stationsKeepBestSnrLatestGridAndBands() throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = DecodeHistory(folder: folder, now: { day0.addingTimeInterval(3_600) })
        history.append([
            heard(0, rfHz: 7_075_000, snr: -20, "CQ K1ABC FN42"),
            heard(60, rfHz: 14_075_000, snr: -5, "CQ K1ABC FN43"),
            heard(90, rfHz: 14_075_000, snr: -8, "W9XYZ K1ABC -08"),
            heard(120, rfHz: 14_075_000, snr: -15, "CQ W1AW FN31"),
            heard(130, rfHz: 14_075_000, snr: -15, "TNX BOB 73 GL"),
        ])
        let stations = history.stations(since: day0)
        #expect(stations.map(\.call) == ["W1AW", "K1ABC"])
        let k1abc = try #require(stations.last)
        #expect(k1abc.bestSnrDb == -5)
        #expect(k1abc.bands == ["40m", "20m"])
        #expect(k1abc.count == 3)
        #expect(k1abc.grid == "FN43")
        #expect(abs(try #require(k1abc.lat) - 43.5) < 0.01)
        #expect(k1abc.lastHeard == day0.addingTimeInterval(90))
        #expect(history.stations(since: day0.addingTimeInterval(100)).map(\.call) == ["W1AW"])
    }

    @Test func stationsCanBeLimitedToOneMode() {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = DecodeHistory(folder: folder, now: { day0.addingTimeInterval(3_600) })
        history.append([
            heard(0, "CQ K1ABC FN42"),
            heard(30, mode: .wspr, rfHz: 14_097_000, "W1AW FN31 37"),
            heard(60, "CQ N0CALL EM10"),
        ])
        #expect(history.stations(since: day0, mode: "ft8").map(\.call) == ["N0CALL", "K1ABC"])
        #expect(history.stations(since: day0, mode: "wspr").map(\.call) == ["W1AW"])
        #expect(Set(history.stations(since: day0).map(\.call)) == ["K1ABC", "N0CALL", "W1AW"])
    }

    @Test func prunesDayFilesOlderThanKeepDays() {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = DecodeHistory(folder: folder, now: { day0 })
        writer.append([heard(0, "CQ K1ABC FN42"), heard(86_400, "CQ K1ABC FN42")])
        writer.flush()
        #expect(files(folder) == ["2026-10-01.jsonl", "2026-10-02.jsonl"])
        let later = DecodeHistory(folder: folder, now: { day0.addingTimeInterval(31 * 86_400) })
        later.flush()
        #expect(files(folder) == ["2026-10-02.jsonl"])
    }

    @Test func survivesACorruptLine() throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let now: @Sendable () -> Date = { day0.addingTimeInterval(3_600) }
        let writer = DecodeHistory(folder: folder, now: now)
        writer.append([heard(0, "CQ K1ABC FN42")])
        writer.flush()
        let url = folder.appendingPathComponent("2026-10-01.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("this is not json\n".utf8))
        try handle.close()
        writer.append([heard(60, "CQ W1AW FN31")])
        writer.flush()
        let reader = DecodeHistory(folder: folder, now: now)
        #expect(reader.decodes(since: day0).map(\.from) == ["W1AW", "K1ABC"])
    }

    @Test func bandNames() {
        #expect(BandPlan.name(forHz: 1_840_000) == "160m")
        #expect(BandPlan.name(forHz: 7_074_000) == "40m")
        #expect(BandPlan.name(forHz: 10_138_700) == "30m")
        #expect(BandPlan.name(forHz: 14_074_000) == "20m")
        #expect(BandPlan.name(forHz: 50_313_000) == "6m")
        #expect(BandPlan.name(forHz: 432_100_000) == "70cm")
        #expect(BandPlan.name(forHz: 9_000_000) == nil)
    }
}
