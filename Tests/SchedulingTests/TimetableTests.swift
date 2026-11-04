import Testing
import Foundation
@testable import Scheduling

private let b26 = EiBiSeason(year: 2026, half: .b)

private func fixtureTimetable() throws -> Timetable {
    Timetable(data: try fixtureData("sked-b26-cut.csv"), season: b26)
}

private func row(_ kHz: Double, _ time: String, station: String = "Test One", lang: String = "E", target: String = "NAm",
                 days: String = "") -> EiBiRow {
    let s = TimeOfDay(hour: Int(time.prefix(2))!, minute: Int(time.dropFirst(2).prefix(2))!)
    let e = TimeOfDay(hour: Int(time.dropFirst(5).prefix(2))!, minute: Int(time.suffix(2))!)
    return EiBiRow(kHz: kHz, start: s, end: e, daysField: days, country: "USA", station: station, language: lang,
                   target: target, site: "x", persistence: 1, startField: "", stopField: "")
}

private func table(_ rows: [EiBiRow]) -> Timetable { Timetable(rows: rows, season: b26) }

@Suite struct TimetableTests {
    @Test func midnightCrossingDuration() throws {
        let t = try fixtureTimetable()
        let b = try #require(t.broadcasts.first { $0.station == "Test Midnight" })
        #expect(b.start == TimeOfDay(hour: 23, minute: 30) && b.durationMinutes == 60)
        let all = try #require(t.broadcasts.first { $0.station == "Test AllDay" })
        #expect(all.durationMinutes == 1440)
        #expect(table([row(5000, "0200-0200")]).broadcasts.first?.durationMinutes == 1440)
    }

    @Test func inactiveAndUtilityRowsAreDropped() throws {
        let names = Set(try fixtureTimetable().broadcasts.map(\.station))
        #expect(!names.contains("Test Inactive") && !names.contains("Test Utility"))
        #expect(!names.contains("Test SummerOnly"))        // b26 is a winter season
        #expect(names.contains("Test WinterOnly"))
    }

    @Test func onlyNorthAmericaTargets() throws {
        let names = Set(try fixtureTimetable().broadcasts.map(\.station))
        #expect(!names.contains("Test Europe"))
        #expect(names.contains("Test Two Targets"))        // "Eu,NAm"
        #expect(names.contains("Test Daily") && names.contains("Rádio Nacional"))   // NAm, CAm
        #expect(names.contains("WRMI Radio Miami Int."))   // Car
        #expect(!names.contains("MSF Time from NPL"))
    }

    @Test func rowsMergeIntoOneBroadcast() throws {
        let merged = try fixtureTimetable().broadcasts.filter { $0.station == "Test Merge" }
        #expect(merged.count == 1)
        #expect(merged[0].frequenciesHz == [5_970_400, 7_300_000, 9_550_000])
    }

    @Test func religiousRowsNeverAppear() throws {
        let t = try fixtureTimetable()
        #expect(!t.broadcasts.contains { $0.station.contains("WWCR") })
        #expect(!t.search("").contains { $0.station.contains("WWCR") || $0.station.contains("Mystery") })
    }

    @Test func dayFormsAndDatesCarryThrough() throws {
        let t = try fixtureTimetable()
        func b(_ name: String) throws -> TimetableBroadcast { try #require(t.broadcasts.first { $0.station == name }) }
        #expect(try b("Test Weekdays").days == .weekly([.mo, .tu, .we, .th, .fr]))
        #expect(try b("Test Alternate").irregular)
        #expect(try b("Test OneDay").days == .once(.init(year: 2026, month: 9, day: 15)))
        let dated = try b("Test Dated")
        #expect(dated.startDate == .init(year: 2026, month: 11, day: 1) && dated.endDate == .init(year: 2027, month: 1, day: 31))
    }

    @Test func searchByStationLanguageAndCountry() throws {
        let t = try fixtureTimetable()
        #expect(!t.search("habana").isEmpty && t.search("habana").allSatisfy { $0.station.contains("Habana") })
        #expect(t.search("RADIO  habana cuba").count == t.search("habana").count)
        #expect(t.search("habaná").count == t.search("habana").count)       // accents folded
        let spanish = t.search("", language: "S")
        #expect(!spanish.isEmpty && spanish.allSatisfy { $0.language == "S" })
        let cuba = t.search("", country: "CUB")
        #expect(!cuba.isEmpty && cuba.allSatisfy { $0.country == "CUB" })
        #expect(t.search("zzzz").isEmpty)
    }

    @Test func onTonightUsesTheNext24Hours() {
        let t = table([row(5000, "0100-0200", station: "Soon"), row(5010, "1000-1100", station: "Later"),
                       row(5020, "0100-0200", station: "Only Monday", days: "Mo"),
                       row(5030, "2330-0030", station: "Midnight")])
        // Tuesday 2026-11-03 23:00Z: Soon at 01:00 tomorrow, Later at 10:00 tomorrow, Midnight at 23:30 tonight.
        let names = Set(t.onTonight(now: utcDate("2026-11-03T23:00:00Z")).map(\.station))
        #expect(names == ["Soon", "Later", "Midnight"])
        // Sunday 2026-11-08 23:00Z: the next Monday 01:00 is inside the 24 hours.
        #expect(t.onTonight(now: utcDate("2026-11-08T23:00:00Z")).map(\.station).contains("Only Monday"))
        // 10:30Z Tuesday: Later began at 10:00, its next window is 23.5 hours away, so it still counts; Soon at 01:00 Wednesday too.
        #expect(Set(t.onTonight(now: utcDate("2026-11-03T10:30:00Z")).map(\.station)) == ["Soon", "Later", "Midnight"])
    }

    @Test func scheduleFromABroadcast() throws {
        let t = try fixtureTimetable()
        let b = try #require(t.broadcasts.first { $0.station == "Test Merge" })
        let now = utcDate("2026-11-03T12:00:00Z")
        let s = t.schedule(from: b, now: now, addedBy: "agent")
        #expect(s.kind == .broadcast && s.mode == .am && s.timeZone == "UTC" && s.enabled && s.source == .timetable)
        #expect(s.timetableKey == TimetableKey(station: "Test Merge", language: "E", season: "b26"))
        #expect(s.frequenciesHz == b.frequenciesHz && s.squelchMarginDb == 8 && s.addedBy == "agent")
        #expect(s.start == b.start && s.durationMinutes == b.durationMinutes && s.days == b.days && s.created == now)
        #expect(s.timetableNote == nil)
        let irregular = try #require(t.broadcasts.first { $0.irregular })
        #expect(t.schedule(from: irregular, now: now, addedBy: nil).timetableNote == .irregular)
    }

    @Test func nineFrequenciesKeepTheFirstEight() {
        let t = table((0..<9).map { row(5000 + Double($0) * 10, "0100-0200") })
        let b = t.broadcasts[0]
        #expect(b.frequenciesHz.count == 9)
        #expect(t.schedule(from: b, now: Date(), addedBy: nil).frequenciesHz == Array(b.frequenciesHz.prefix(8)))
    }

    @Test func relinkUpdatesMovedBroadcasts() {
        let old = table([row(5000, "0200-0300")])
        var s = old.schedule(from: old.broadcasts[0], now: utcDate("2026-10-01T00:00:00Z"), addedBy: nil)
        s.timetableKey?.season = "a26"
        let new = table([row(6000, "0230-0330"), row(6010, "0230-0330"), row(7000, "1400-1500")])
        let now = utcDate("2026-11-03T12:00:00Z")
        let out = new.relink([s], now: now)
        #expect(out.count == 1 && out[0].id == s.id)
        #expect(out[0].start == TimeOfDay(hour: 2, minute: 30) && out[0].frequenciesHz == [6_000_000, 6_010_000])
        #expect(out[0].timetableKey?.season == "b26" && out[0].timetableNote == .updated(now) && out[0].enabled)
    }

    @Test func relinkPrefersASharedDayThenTheNearestStart() {
        let old = table([row(5000, "0200-0300", days: "Mo")])
        let s = old.schedule(from: old.broadcasts[0], now: Date(), addedBy: nil)
        let new = table([row(6000, "0200-0300", days: "Sa"), row(7000, "0300-0400", days: "Mo"), row(8000, "0100-0200", days: "Mo")])
        // 01:00 and 03:00 both an hour away on a shared day: the earlier start wins.
        #expect(new.relink([s], now: Date())[0].frequenciesHz == [8_000_000])
    }

    @Test func relinkSwitchesOffGoneBroadcasts() {
        let old = table([row(5000, "0200-0300")])
        let s = old.schedule(from: old.broadcasts[0], now: Date(), addedBy: nil)
        let now = utcDate("2026-11-03T12:00:00Z")
        let out = table([row(6000, "0200-0300", station: "Other")]).relink([s], now: now)
        #expect(!out[0].enabled && out[0].timetableNote == .gone && out[0].frequenciesHz == s.frequenciesHz)
    }

    @Test func relinkLeavesOwnSchedulesAlone() {
        let own = Schedule(kind: .broadcast, name: "Mine", frequenciesHz: [5_000_000], mode: .am,
                           start: TimeOfDay(hour: 1, minute: 0), durationMinutes: 30, timeZone: "UTC",
                           days: .weekly([.mo]), created: Date())
        #expect(table([row(6000, "0200-0300")]).relink([own], now: Date()) == [own])
    }

    @Test func theBundledFileParses() throws {
        let data = Timetable.bundledData()
        let (rows, dropped) = EiBi.parse(data)
        #expect(Double(dropped) < 0.02 * Double(rows.count + dropped))
        let t = Timetable(data: data, season: b26)
        #expect(t.broadcasts.count >= 200)
        #expect(!t.broadcasts.contains { ReligiousFilter.bundled.isReligious($0.station) })
        #expect(t.droppedRows == dropped)
    }
}
