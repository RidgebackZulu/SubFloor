import Testing
import Foundation
@testable import Scheduling

private let day: TimeInterval = 86_400
/// 2026-11-03 12:00 UTC, in season b26.
private let nov3 = Date(timeIntervalSince1970: 1_793_707_200)

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { _requests } }
    func add(_ r: URLRequest) { lock.withLock { _requests.append(r) } }
}

private func reply(_ url: URL?, _ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: url ?? URL(string: "http://eibispace.de/")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}

/// A stub that answers each request with `answer(request)` and records it. Never touches the network.
private func stub(_ recorder: Recorder, _ answer: @escaping @Sendable (URLRequest) -> (Data, Int, [String: String])) -> TimetableFetch {
    TimetableFetch { request in
        recorder.add(request)
        let (data, status, headers) = answer(request)
        return (data, reply(request.url, status, headers: headers))
    }
}

private func tempFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("timetable-\(UUID().uuidString)", isDirectory: true)
}

private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
    EiBi.utc.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
}

/// The bundled file's first `count` lines, cut on the bytes (the file is Latin-1 with CRLF line ends).
private func firstLines(_ count: Int) -> Data {
    var seen = 0
    let end = good.firstIndex { byte in
        if byte == 0x0A { seen += 1 }
        return seen == count
    }
    return good.prefix(through: end!)
}

private let good = Timetable.bundledData()

@Suite struct TimetableFilesTests {
    @Test func firstLoadUsesTheBundledFile() {
        let files = TimetableFiles(folder: tempFolder(), fetch: stub(Recorder()) { _ in (Data(), 500, [:]) })
        let t = files.load()
        #expect(t.season == EiBiSeason(year: 2026, half: .b))
        #expect(t.broadcasts.count == Timetable(data: good, season: t.season).broadcasts.count)
        #expect(!t.broadcasts.isEmpty)
        #expect(files.meta == nil)
    }

    @Test func fetchesWithValidatorsAndCaches() async throws {
        let rec = Recorder()
        let folder = tempFolder()
        let files = TimetableFiles(folder: folder, fetch: stub(rec) { r in
            r.value(forHTTPHeaderField: "If-None-Match") == "\"x\"" ? (Data(), 304, [:])
                : (good, 200, ["ETag": "\"x\"", "Last-Modified": "Mon, 02 Nov 2026 10:00:00 GMT"])
        })
        let t = try #require(await files.updateIfDue(now: nov3))
        #expect(t.season.name == "b26")
        let first = rec.requests[0]
        #expect(first.url?.absoluteString == "http://eibispace.de/dx/sked-b26.csv")
        #expect(first.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(first.value(forHTTPHeaderField: "User-Agent") == "SubFloor")
        #expect(try Data(contentsOf: folder.appendingPathComponent("sked-b26.csv")) == good)
        let meta = try #require(files.meta)
        #expect(meta.etag == "\"x\"" && meta.lastModified == "Mon, 02 Nov 2026 10:00:00 GMT")
        #expect(meta.season == "b26" && meta.fetchedAt == nov3 && meta.checkedAt == nov3)

        // A new instance reads the same meta from disk; 8 days later it asks with the validators.
        let again = TimetableFiles(folder: folder, fetch: stub(rec) { _ in (Data(), 304, [:]) })
        #expect(again.meta == meta)
        _ = await again.updateIfDue(now: nov3 + 8 * day)
        let second = try #require(rec.requests.last)
        #expect(second.value(forHTTPHeaderField: "If-None-Match") == "\"x\"")
        #expect(second.value(forHTTPHeaderField: "If-Modified-Since") == "Mon, 02 Nov 2026 10:00:00 GMT")
        #expect(again.load().season.name == "b26")
    }

    @Test func notModifiedOnlyStampsTheCheck() async throws {
        let rec = Recorder()
        let folder = tempFolder()
        let first = TimetableFiles(folder: folder, fetch: stub(rec) { _ in (good, 200, ["ETag": "\"x\""]) })
        _ = await first.updateIfDue(now: nov3)
        let before = try Data(contentsOf: folder.appendingPathComponent("sked-b26.csv"))
        let files = TimetableFiles(folder: folder, fetch: stub(rec) { _ in (Data(), 304, [:]) })
        let result = await files.updateIfDue(now: nov3 + 8 * day)
        #expect(result == nil)
        let meta = try #require(files.meta)
        #expect(meta.checkedAt == nov3 + 8 * day && meta.fetchedAt == nov3 && meta.etag == "\"x\"")
        #expect(try Data(contentsOf: folder.appendingPathComponent("sked-b26.csv")) == before)
    }

    @Test func notDueWithinAWeek() async {
        let rec = Recorder()
        let folder = tempFolder()
        let files = TimetableFiles(folder: folder, fetch: stub(rec) { _ in (good, 200, [:]) })
        _ = await files.updateIfDue(now: nov3)
        #expect(rec.requests.count == 1)
        let result = await files.updateIfDue(now: nov3 + 2 * day)
        #expect(result == nil && rec.requests.count == 1)
    }

    @Test func seasonChangeoverFetchesTheNextSeason() async throws {
        let rec = Recorder()
        let folder = tempFolder()
        // Checked the day before a27 began (2027-03-28 01:00 UTC), so the weekly rule alone wouldn't fire.
        let seed = TimetableFiles(folder: folder, fetch: stub(rec) { _ in (good, 200, [:]) })
        _ = await seed.updateIfDue(now: utc(2027, 3, 27))
        #expect(seed.meta?.season == "b26" && rec.requests.count == 1)
        let files = TimetableFiles(folder: folder, fetch: stub(rec) { _ in (good, 200, [:]) })
        let result = try #require(await files.updateIfDue(now: utc(2027, 3, 29)))
        #expect(result.season.name == "a27")
        #expect(rec.requests.count == 2 && rec.requests.last?.url?.lastPathComponent == "sked-a27.csv")
        #expect(files.meta?.season == "a27")
        // The b26 validators belong to another season, so none are sent.
        #expect(rec.requests.last?.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func missingSeasonFallsBackToTheOther() async throws {
        let rec = Recorder()
        let files = TimetableFiles(folder: tempFolder(), fetch: stub(rec) { r in
            r.url?.lastPathComponent == "sked-a27.csv" ? (Data(), 404, [:]) : (good, 200, [:])
        })
        let t = try #require(await files.updateIfDue(now: utc(2027, 3, 29)))
        #expect(rec.requests.map { $0.url?.lastPathComponent } == ["sked-a27.csv", "sked-b26.csv"])
        #expect(t.season.name == "b26" && files.meta?.season == "b26")
    }

    @Test func garbageFetchKeepsTheOldTimetable() async throws {
        let rec = Recorder()
        let files = TimetableFiles(folder: tempFolder(), fetch: stub(rec) { _ in (Data("<html>captive portal</html>".utf8), 200, ["ETag": "\"bad\""]) })
        let bundledCount = files.load().broadcasts.count
        let result = await files.updateIfDue(now: nov3)
        #expect(result == nil)
        #expect(files.load().broadcasts.count == bundledCount)
        let meta = try #require(files.meta)
        #expect(meta.season == "b26" && meta.etag == nil && meta.fetchedAt == nil && meta.checkedAt == nov3)
        // The check counts: not due again for a week.
        _ = await files.updateIfDue(now: nov3 + day)
        #expect(rec.requests.count == 1)
    }

    @Test func truncatedFetchIsRejected() async throws {
        let truncated = firstLines(300)
        let files = TimetableFiles(folder: tempFolder(), fetch: stub(Recorder()) { _ in (truncated, 200, [:]) })
        #expect(await files.updateIfDue(now: nov3) == nil)
        #expect(files.meta?.fetchedAt == nil)
    }

    @Test func halfRuleRejectsAShrunkenFile() async throws {
        // 1,100 rows pass the minimum but are under half of the 8,900-odd bundled rows.
        let shrunk = firstLines(1_100)
        #expect(EiBi.parse(shrunk).rows.count >= TimetableFiles.minimumRows)
        let files = TimetableFiles(folder: tempFolder(), fetch: stub(Recorder()) { _ in (shrunk, 200, [:]) })
        #expect(await files.updateIfDue(now: nov3) == nil)
    }

    @Test func aSameSeasonRefreshNeeds80PercentOfTheRows() async throws {
        let rows = EiBi.parse(good).rows.count
        // 75 % of the bundled b26 rows: more than half, but a refresh of the same season needs 80 %.
        let short = firstLines(rows * 3 / 4)
        let files = TimetableFiles(folder: tempFolder(), fetch: stub(Recorder()) { _ in (short, 200, [:]) })
        #expect(await files.updateIfDue(now: nov3) == nil)
        #expect(files.meta?.fetchedAt == nil)
        let enough = firstLines(rows * 17 / 20)   // 85 %
        let again = TimetableFiles(folder: tempFolder(), fetch: stub(Recorder()) { _ in (enough, 200, [:]) })
        #expect(await again.updateIfDue(now: nov3) != nil)
    }

    @Test func aNewSeasonKeepsTheHalfRule() async throws {
        // 60 % of the b26 rows, as a27: a new season may be smaller.
        let smaller = firstLines(EiBi.parse(good).rows.count * 3 / 5)
        let files = TimetableFiles(folder: tempFolder(), fetch: stub(Recorder()) { _ in (smaller, 200, [:]) })
        let t = try #require(await files.updateIfDue(now: utc(2027, 3, 29)))
        #expect(t.season.name == "a27")
    }

    @Test func aCheckStampedInTheFutureIsDue() async throws {
        let rec = Recorder()
        let folder = tempFolder()
        // The Mac's clock was a month ahead at the last check.
        let seed = TimetableFiles(folder: folder, fetch: stub(rec) { _ in (good, 200, [:]) })
        _ = await seed.updateIfDue(now: nov3 + 30 * day)
        #expect(seed.meta?.checkedAt == nov3 + 30 * day && rec.requests.count == 1)
        let files = TimetableFiles(folder: folder, fetch: stub(rec) { _ in (Data(), 304, [:]) })
        _ = await files.updateIfDue(now: nov3)
        #expect(rec.requests.count == 2)
        #expect(files.meta?.checkedAt == nov3)
    }

    @Test func networkErrorLeavesMetaAloneSoTheNextLaunchRetries() async throws {
        struct Down: Error {}
        let rec = Recorder()
        let files = TimetableFiles(folder: tempFolder(), fetch: TimetableFetch { r in rec.add(r); throw Down() })
        #expect(await files.updateIfDue(now: nov3) == nil)
        #expect(files.meta == nil)
        _ = await files.updateIfDue(now: nov3 + 60)
        #expect(rec.requests.count == 2)
    }

    @Test func corruptCacheFallsBackToTheBundledFile() throws {
        let folder = tempFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: folder.appendingPathComponent("sked-b26.csv"))
        let meta = TimetableMeta(season: "b26", etag: nil, lastModified: nil, checkedAt: nov3, fetchedAt: nov3)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meta).write(to: folder.appendingPathComponent("meta.json"))
        let files = TimetableFiles(folder: folder, fetch: stub(Recorder()) { _ in (Data(), 500, [:]) })
        #expect(files.meta == meta)
        let t = files.load()
        #expect(!t.broadcasts.isEmpty)
        #expect(t.broadcasts.count == Timetable(data: good, season: t.season).broadcasts.count)
    }

    @Test func fallbackNeverReplacesANewerCache() async throws {
        let rec = Recorder()
        let folder = tempFolder()
        let seed = TimetableFiles(folder: folder, fetch: stub(rec) { _ in (good, 200, [:]) })
        _ = await seed.updateIfDue(now: utc(2027, 3, 29))
        #expect(seed.meta?.season == "a27")
        let later = utc(2027, 4, 10)
        let files = TimetableFiles(folder: folder, fetch: stub(rec) { r in
            r.url?.lastPathComponent == "sked-a27.csv" ? (Data(), 404, [:]) : (good, 200, [:])
        })
        #expect(await files.updateIfDue(now: later) == nil)
        #expect(files.meta?.season == "a27" && files.meta?.checkedAt == later)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("sked-a27.csv").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("sked-b26.csv").path))
    }

    @Test func failedMetaWriteKeepsThePreviousFiles() async throws {
        let rec = Recorder()
        let folder = tempFolder()
        let seed = TimetableFiles(folder: folder, fetch: stub(rec) { _ in (good, 200, [:]) })
        _ = await seed.updateIfDue(now: utc(2027, 3, 27))
        let files = TimetableFiles(folder: folder, fetch: stub(rec) { _ in (good, 200, [:]) })
        let before = try #require(files.meta)
        // Occupy the meta path with a directory so the write fails.
        let metaURL = folder.appendingPathComponent("meta.json")
        try FileManager.default.removeItem(at: metaURL)
        try FileManager.default.createDirectory(at: metaURL, withIntermediateDirectories: false)
        #expect(await files.updateIfDue(now: utc(2027, 3, 29)) == nil)
        #expect(files.meta == before)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("sked-b26.csv").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("sked-a27.csv").path))
    }

    @Test func plistAllowsHTTPForEiBiOnly() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/SubFloor/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let ats = try #require(plist["NSAppTransportSecurity"] as? [String: Any])
        let domains = try #require(ats["NSExceptionDomains"] as? [String: Any])
        #expect(Set(domains.keys) == ["eibispace.de"])
        let eibi = try #require(domains["eibispace.de"] as? [String: Any])
        #expect(eibi["NSExceptionAllowsInsecureHTTPLoads"] as? Bool == true)
        #expect(eibi["NSIncludesSubdomains"] as? Bool == false)
        #expect(ats["NSAllowsArbitraryLoads"] == nil)
        #expect(plist["NSBluetoothAlwaysUsageDescription"] != nil)
    }
}
