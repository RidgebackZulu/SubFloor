import Foundation
import Scheduling
import Testing
@testable import SubFloor

/// The Schedules window's pure parts: row texts, the timetable tab's search and Add, the notes, the credit line and the
/// editor's draft. The clock is noon in Dallas on Wed 4 Nov 2026 (18:00 UTC, CST).
@MainActor
@Suite(.serialized)
struct SchedulesWindowTests {
    private static let noon = ISO8601DateFormatter().date(from: "2026-11-04T18:00:00Z")!
    private static let dallas = TimeZone(identifier: "America/Chicago")!

    /// Temp folders made by this test, removed when it ends (the suite value is created per test).
    private final class Folders: @unchecked Sendable {
        var urls: [URL] = []
        deinit { for url in urls { try? FileManager.default.removeItem(at: url) } }
    }
    private let folders = Folders()

    private func tempDir(_ prefix: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        folders.urls.append(dir)
        return dir
    }

    private func makeScheduler() -> Scheduler {
        let dir = tempDir("SubFloorSchedUI")
        let s = Scheduler(store: ScheduleStore(url: dir.appendingPathComponent("schedules.json")),
                          now: { Self.noon }, localZone: Self.dallas, autoTick: false)
        for existing in s.schedules { s.delete(existing.id) }   // the first-launch default watch
        return s
    }

    private func model(_ s: Scheduler, transcription: Bool = true, battery: Bool = false) -> SchedulesModel {
        SchedulesModel(scheduler: s, transcriptionEnabled: { transcription }, isOnBattery: { battery })
    }

    private func schedule(_ name: String = "Night pirates", kind: ScheduleKind = .watch, start: TimeOfDay = TimeOfDay(hour: 19, minute: 0),
                          minutes: Int = 420, zone: String = "America/Chicago",
                          days: ScheduleDays = .weekly([.fr, .sa]), addedBy: String? = nil) -> Schedule {
        Schedule(kind: kind, name: name, frequenciesHz: kind == .broadcast ? [6_000_000, 6_100_000] : [],
                 lowHz: kind == .watch ? 6_850_000 : nil, highHz: kind == .watch ? 7_000_000 : nil,
                 mode: kind == .watch ? .auto : .am, start: start, durationMinutes: minutes, timeZone: zone, days: days,
                 addedBy: addedBy, created: Self.noon)
    }

    private func row(_ s: Schedule, overlaps: [String] = []) -> ScheduleRow {
        ScheduleRow(schedule: s, now: Self.noon, zone: Self.dallas, overlaps: overlaps)
    }

    @Test func rowShowsLocalAndUTC() {
        let r = row(schedule())
        #expect(r.when == "Fri, Sat 19:00–02:00 (01:00–08:00 UTC)")
        #expect(r.title == "Night pirates")
        #expect(r.tuning == "6850–7000 kHz · Auto")
        #expect(r.nextRun == "Fri 6 Nov 19:00")
    }

    @Test func whenReadsEachKindOfDays() {
        let daily = schedule(start: TimeOfDay(hour: 9, minute: 0), minutes: 60, days: .weekly(Set(Weekday.allCases)))
        #expect(row(daily).when == "Daily 09:00–10:00 (15:00–16:00 UTC)")
        let weekdays = schedule(start: TimeOfDay(hour: 9, minute: 0), minutes: 60, days: .weekly([.mo, .tu, .we, .th, .fr]))
        #expect(row(weekdays).when == "Mon–Fri 09:00–10:00 (15:00–16:00 UTC)")
        #expect(row(schedule(days: .monthly(ordinal: 1, weekday: .sa))).when.hasPrefix("1st Sat 19:00–02:00"))
        #expect(row(schedule(days: .monthly(ordinal: -1, weekday: .su))).when.hasPrefix("Last Sun 19:00–02:00"))
        let once = schedule(days: .once(ScheduleDate(year: 2026, month: 11, day: 20)))
        #expect(row(once).when == "20 Nov 19:00–02:00 (01:00–08:00 UTC)")
    }

    @Test func aUTCScheduleShowsTheLocalDaysFirst() {
        // Sat 01:00 UTC is Friday evening in Dallas.
        let utc = schedule(start: TimeOfDay(hour: 1, minute: 0), minutes: 60, zone: "UTC", days: .weekly([.sa]))
        #expect(row(utc).when == "Fri 19:00–20:00 (01:00–02:00 UTC)")
        #expect(row(utc).nextRun == "Fri 6 Nov 19:00")
    }

    @Test func nextSkipsAWindowUnderWay() {
        // 11:00–13:00 daily in Dallas, and it's noon: the next run is tomorrow's, as the MCP tools say.
        let daily = schedule(start: TimeOfDay(hour: 11, minute: 0), minutes: 120, days: .weekly(Set(Weekday.allCases)))
        #expect(row(daily).nextRun == "Thu 5 Nov 11:00")
        #expect(ScheduleClock.upcomingWindow(of: daily, after: Self.noon)?.start
                == ISO8601DateFormatter().date(from: "2026-11-05T17:00:00Z"))
    }

    @Test func rowShowsWhoAddedIt() {
        #expect(row(schedule()).addedBy == "you")
        #expect(row(schedule(addedBy: "Claude Code")).addedBy == "Claude Code")
    }

    @Test func rowShowsTheLastOutcomeAndNote() {
        var s = schedule()
        #expect(row(s).lastOutcome == "Not run yet")
        #expect(row(s).note == nil)
        s.lastRun = LastRun(outcome: .recorded(seconds: 1_680, files: 1), at: Self.noon)
        #expect(row(s).lastOutcome == "Recorded 28 min")
        s.timetableNote = .updated(ISO8601DateFormatter().date(from: "2026-11-03T18:00:00Z")!)
        #expect(row(s).note == "Updated from the timetable 3 Nov")
        s.timetableNote = .gone
        #expect(row(s).note == "No longer in the timetable")
        s.timetableNote = .irregular
        #expect(row(s).note == "Irregular in the timetable")
        s.enabled = false
        #expect(row(s).nextRun == "—")
    }

    @Test func overlapIsMarked() throws {
        let scheduler = makeScheduler()
        try scheduler.add(schedule("Night pirates"))
        try scheduler.add(schedule("Late watch", start: TimeOfDay(hour: 22, minute: 0)))
        try scheduler.add(schedule("Morning", start: TimeOfDay(hour: 8, minute: 0), minutes: 30, days: .weekly([.mo])))
        let rows = model(scheduler).rows
        #expect(rows[0].overlapText == "Overlaps with Late watch")
        #expect(rows[1].overlapText == "Overlaps with Night pirates")
        #expect(rows[2].overlapText == nil)
    }

    @Test func timetableAddCreatesALinkedSchedule() throws {
        let scheduler = makeScheduler()
        let m = model(scheduler)
        let first = try #require(m.timetableRows.first { $0.broadcast.frequenciesHz.count > 1 && $0.broadcast.durationMinutes <= 360 })
        #expect(!first.added)
        m.add(first)
        let s = try #require(scheduler.schedules.first)
        #expect(s.source == .timetable && s.addedBy == nil)
        #expect(s.timetableKey?.station == first.station && s.timetableKey?.language == first.language)
        #expect(s.frequenciesHz == first.broadcast.frequenciesHz)
        #expect(m.message == nil)
        #expect(m.timetableRows.first { $0.id == first.id }?.added == true)
        // Another start by the same station isn't marked: the match is station, language and start.
        let others = m.timetableRows.filter {
            $0.station == first.station && $0.language == first.language && $0.broadcast.start != first.broadcast.start
        }
        #expect(others.allSatisfy { !$0.added })
        // A schedule from the owner's own typing has no key, so it marks nothing.
        #expect(m.rows.first?.addedBy == "you")
    }

    @Test func timetableSearchCoversStationLanguageAndCountry() throws {
        let m = model(makeScheduler())
        m.search = "Radio Habana"
        let found = m.timetableRows
        #expect(!found.isEmpty && found.allSatisfy { $0.station.contains("Habana") })
        m.search = "zzzz-nothing"
        #expect(m.timetableRows.isEmpty)
    }

    @Test func onTonightFilters() {
        let scheduler = makeScheduler()
        let m = model(scheduler)
        let all = m.timetableRows
        m.onTonight = true
        let tonight = m.timetableRows
        #expect(!tonight.isEmpty && tonight.count < all.count)
        #expect(Set(tonight.map(\.id)) == Set(scheduler.timetable.onTonight(now: Self.noon).map(\.id)))
    }

    @Test func uncertainRowsAreMarked() throws {
        let scheduler = makeScheduler()
        let rows = model(scheduler).timetableRows
        let odd = try #require(rows.first { $0.broadcast.irregular })
        #expect(odd.uncertain)
        let steady = try #require(rows.first { !$0.broadcast.irregular })
        #expect(!steady.uncertain)
        #expect(steady.when.contains(" UTC)") && steady.frequencies.hasSuffix(" kHz"))
    }

    @Test func notesAppearWhenTheyShould() {
        let scheduler = makeScheduler()
        let quiet = model(scheduler, transcription: true, battery: false)
        #expect(quiet.transcriptionNoteText == nil)
        #expect(!quiet.keepAwakeIsAmber)
        let loud = model(scheduler, transcription: false, battery: true)
        #expect(loud.transcriptionNoteText == "Transcription is off in Settings, so scheduled recordings get no transcripts.")
        #expect(loud.keepAwakeIsAmber)
        #expect(SchedulesModel.keepAwakeNote == "SubFloor keeps the Mac awake for schedules, but it has to be open, and a Mac with its lid closed and no external display sleeps anyway.")
    }

    @Test func creditLineNamesEiBi() {
        let scheduler = makeScheduler()
        let m = model(scheduler)
        #expect(m.creditLine == "Timetable: EiBi, by Eike Bierwirth (eibispace.de) · season B26 · bundled copy")
        scheduler.timetableCheckedAt = Self.noon.addingTimeInterval(-2 * 86_400 - 3_600)
        #expect(m.creditLine == "Timetable: EiBi, by Eike Bierwirth (eibispace.de) · season B26 · checked 2 days ago")
        #expect(SchedulesModel.ago(from: Self.noon.addingTimeInterval(-86_400), to: Self.noon) == "1 day ago")
        #expect(SchedulesModel.ago(from: Self.noon.addingTimeInterval(-7_300), to: Self.noon) == "2 hours ago")
    }

    // MARK: The editor

    private func draft(_ name: String = "Radio Test") -> ScheduleDraft {
        var d = ScheduleDraft(zone: Self.dallas, now: Self.noon)
        d.name = name
        d.frequencies = "6000, 6100.5"
        d.duration = "30"
        return d
    }

    @Test func aNewDraftStartsOnTheNextHourInTheZone() {
        let d = ScheduleDraft(zone: Self.dallas, now: Self.noon)
        #expect(d.start == TimeOfDay(hour: 13, minute: 0))
        #expect(d.onceDate == ScheduleDate(year: 2026, month: 11, day: 4))
        #expect(d.timeZone == "America/Chicago")
    }

    @Test func savingAddsAndThenUpdates() throws {
        let scheduler = makeScheduler()
        let m = model(scheduler)
        #expect(m.save(draft(), replacing: nil) == nil)
        let saved = try #require(scheduler.schedules.first)
        #expect(saved.frequenciesHz == [6_000_000, 6_100_500] && saved.source == .you && saved.addedBy == nil)
        var edit = ScheduleDraft(saved)
        edit.name = "Renamed"
        edit.enabled = false
        #expect(m.save(edit, replacing: saved) == nil)
        #expect(scheduler.schedules.count == 1 && scheduler.schedules[0].name == "Renamed" && !scheduler.schedules[0].enabled)
        #expect(scheduler.schedules[0].id == saved.id && scheduler.schedules[0].created == saved.created)
    }

    @Test func theEditorShowsTheSameRefusalsAsTheTools() {
        let m = model(makeScheduler())
        var d = draft()
        d.timeZone = "Mars/Olympus"
        #expect(m.save(d, replacing: nil) == "Unknown time zone Mars/Olympus: use an IANA name like America/Chicago.")
        #expect(Scheduler.timeZoneProblem("UTC") == nil && Scheduler.timeZoneProblem("America/Chicago") == nil)
        d = draft("Trans World Radio")
        #expect(m.save(d, replacing: nil) == "The owner doesn't want religious broadcasts.")
        d = draft(); d.duration = "420"
        #expect(m.save(d, replacing: nil) == "A broadcast can be at most 6 hours.")
        d = draft(); d.frequencies = "9 kHz"
        #expect(m.save(d, replacing: nil) == "Frequencies are in kHz, comma-separated, e.g. 9435, 9455.")
        d = draft(); d.frequencies = "0.5"
        #expect(m.save(d, replacing: nil) == "frequencies must be 1 to 8 frequencies between 1 kHz and 2000 MHz.")
        d = draft(); d.kind = .watch; d.lowKHz = "7000"; d.highKHz = "7500"
        #expect(m.save(d, replacing: nil) == "A watch's span must be 10 to 400 kHz.")
        d = draft(); d.weekdays = []
        #expect(m.save(d, replacing: nil) == "Pick at least one day.")
        d = draft(); d.name = "  "
        #expect(m.save(d, replacing: nil) == "name can't be empty.")
        d = draft(); d.duration = "half an hour"
        #expect(m.save(d, replacing: nil) == "Duration is in whole minutes, e.g. 30.")
        d = draft(); d.duration = ""
        #expect(m.save(d, replacing: nil) == "Duration is in whole minutes, e.g. 30.")
        d = draft(); d.duration = "0"
        #expect(m.save(d, replacing: nil) == "A schedule must last at least 1 minute.")
    }

    @Test func saveUsesTheTypedDuration() throws {
        let scheduler = makeScheduler()
        let m = model(scheduler)
        var d = draft()
        d.duration = " 45 "   // typed, not yet committed by the field
        #expect(m.save(d, replacing: nil) == nil)
        #expect(scheduler.schedules.first?.durationMinutes == 45)
        #expect(ScheduleDraft(try #require(scheduler.schedules.first)).duration == "45")
    }

    @Test func theEditorShowsOverlapsLive() throws {
        let scheduler = makeScheduler()
        let m = model(scheduler)
        try scheduler.add(schedule("Night pirates"))
        var d = ScheduleDraft(zone: Self.dallas, now: Self.noon)
        d.name = "Mine"; d.kind = .watch; d.lowKHz = "6850"; d.highKHz = "7000"; d.mode = .auto
        d.start = TimeOfDay(hour: 20, minute: 0); d.duration = "60"; d.weekdays = [.fr]
        #expect(m.overlapText(for: d, replacing: nil) == "Overlaps with Night pirates")
        d.weekdays = [.mo]
        #expect(m.overlapText(for: d, replacing: nil) == nil)
        // The schedule being edited doesn't overlap itself.
        let saved = scheduler.schedules[0]
        #expect(m.overlapText(for: ScheduleDraft(saved), replacing: saved) == nil)
    }

    @Test func togglingAndDeleting() throws {
        let scheduler = makeScheduler()
        let m = model(scheduler)
        try scheduler.add(schedule())
        let id = scheduler.schedules[0].id
        m.setEnabled(id, false)
        #expect(!scheduler.schedules[0].enabled)
        m.delete(id)
        #expect(scheduler.schedules.isEmpty)
    }

    @Test func addingABroadcastTheSchedulerRefusesShowsWhy() throws {
        let m = model(makeScheduler())
        let long = try #require(m.timetableRows.first { $0.broadcast.durationMinutes > 360 })
        m.add(long)
        #expect(m.message == "A broadcast can be at most 6 hours.")
        #expect(m.scheduler.schedules.isEmpty)
    }

    @Test func theTimetableCheckTimeReachesTheScheduler() async throws {
        let scheduler = makeScheduler()
        let folder = tempDir("SubFloorTT")
        // A server that answers 404 to everything: no new file, but the check counts.
        let files = TimetableFiles(folder: folder, fetch: TimetableFetch { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        })
        let updater = TimetableUpdater(files: files, scheduler: scheduler)
        #expect(scheduler.timetableCheckedAt == nil)
        await updater.check(now: Self.noon)
        #expect(scheduler.timetableCheckedAt == Self.noon)
        #expect(scheduler.timetable.season.name == "b26")
    }

    @Test func aMonthlyDateThatShiftsShowsItsOwnZone() {
        let utc = schedule(start: TimeOfDay(hour: 1, minute: 0), minutes: 60, zone: "UTC", days: .monthly(ordinal: 1, weekday: .sa))
        #expect(row(utc).when == "1st Sat 01:00–02:00 (UTC)")
    }

    @Test func aSiblingBroadcastWithOtherDaysKeepsItsAddButton() throws {
        let m = model(makeScheduler())
        let b = try #require(m.timetableRows.first { $0.broadcast.durationMinutes <= 360 }?.broadcast)
        var other = b
        other.days = b.days == .weekly([.mo]) ? .weekly([.tu]) : .weekly([.mo])
        let s = m.scheduler.timetable.schedule(from: b, now: Self.noon, addedBy: nil)
        #expect(SchedulesModel.isAdded(b, in: [s], now: Self.noon))
        #expect(!SchedulesModel.isAdded(other, in: [s], now: Self.noon))
    }

    @Test func savingKeepsWhatChangedWhileTheEditorWasOpen() throws {
        let scheduler = makeScheduler()
        let m = model(scheduler)
        try scheduler.add(schedule())
        let opened = scheduler.schedules[0]
        var changed = opened
        changed.lastRun = LastRun(outcome: .stoppedByYou, at: Self.noon)
        changed.addedBy = "Claude Code"
        try scheduler.update(changed)
        var edit = ScheduleDraft(opened)
        edit.name = "Renamed"
        #expect(m.save(edit, replacing: opened) == nil)
        let saved = scheduler.schedules[0]
        #expect(saved.name == "Renamed" && saved.lastRun?.outcome == .stoppedByYou && saved.addedBy == "Claude Code")
    }

    @Test func launchInstallsTheCacheWithoutRelinkingSchedules() async throws {
        let scheduler = makeScheduler()
        let folder = tempDir("SubFloorTT")
        try FileManager.default.copyItem(at: TimetableFiles.bundledURL!, to: folder.appendingPathComponent("sked-b26.csv"))
        let stamp = ISO8601DateFormatter().string(from: Self.noon)
        try Data("{\"season\":\"b26\",\"checkedAt\":\"\(stamp)\",\"fetchedAt\":\"\(stamp)\"}".utf8)
            .write(to: folder.appendingPathComponent("meta.json"))
        // A linked schedule the owner moved to Dallas time: a relink would put it back to UTC.
        let b = try #require(scheduler.timetable.broadcasts.first { $0.durationMinutes <= 360 })
        var linked = scheduler.timetable.schedule(from: b, now: Self.noon, addedBy: nil)
        linked.timeZone = "America/Chicago"
        linked.start = TimeOfDay(hour: 3, minute: 15)
        try scheduler.add(linked)
        let updater = TimetableUpdater(files: TimetableFiles(folder: folder, fetch: TimetableFetch { r in
            (Data(), HTTPURLResponse(url: r.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }), scheduler: scheduler)
        await updater.loadCached()
        #expect(scheduler.schedules == [linked])
        #expect(scheduler.timetableCheckedAt == Self.noon)
    }
}
