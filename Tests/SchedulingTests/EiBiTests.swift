import Testing
import Foundation
@testable import Scheduling

func fixtureData(_ name: String) throws -> Data {
    let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
    let url = try #require(Bundle.module.url(forResource: parts[0], withExtension: parts[1], subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func utcDate(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

@Suite struct EiBiTests {
    @Test func parsesTheFixtureAndCountsBadRows() throws {
        let (rows, dropped) = EiBi.parse(try fixtureData("sked-b26-cut.csv"))
        #expect(dropped == 5)
        #expect(rows.contains { $0.station == "Rádio Nacional" })        // Latin-1 decoded
        #expect(rows.allSatisfy { !$0.station.isEmpty && $0.kHz >= 10 })
    }

    @Test func rowFieldsAreRead() throws {
        let (rows, _) = EiBi.parse(try fixtureData("sked-b26-cut.csv"))
        let r = try #require(rows.first { $0.station == "Test Dated" })
        #expect(r.kHz == 5240)
        #expect(r.start == TimeOfDay(hour: 3, minute: 0) && r.end == TimeOfDay(hour: 4, minute: 0))
        #expect(r.persistence == 6)
        #expect(r.startField == "0111" && r.stopField == "3101")
        #expect(r.target == "NAm" && r.language == "E" && r.country == "USA")
    }

    @Test(arguments: [("", ScheduleDays.weekly(Set(Weekday.allCases)), false), ("Mo-Fr", .weekly([.mo, .tu, .we, .th, .fr]), false),
                      ("Sa-Mo", .weekly([.sa, .su, .mo]), false), ("1245", .weekly([.mo, .tu, .th, .fr]), false),
                      ("1.Sa", .monthly(ordinal: 1, weekday: .sa), false), ("Last7", .monthly(ordinal: -1, weekday: .su), false),
                      ("LastSa", .monthly(ordinal: -1, weekday: .sa), false), ("Mo,We", .weekly([.mo, .we]), false),
                      ("SaSu", .weekly([.sa, .su]), false), ("altFr", .weekly([.fr]), true), ("Mo-Fr irr", .weekly([.mo, .tu, .we, .th, .fr]), true),
                      ("15Sep", .once(.init(year: 2026, month: 9, day: 15)), false), ("10Jan", .once(.init(year: 2027, month: 1, day: 10)), false),
                      ("irr", .weekly(Set(Weekday.allCases)), true), ("USB", .weekly(Set(Weekday.allCases)), false),
                      ("tent", .weekly(Set(Weekday.allCases)), true), ("Tu USB", .weekly([.tu]), false)])
    func dayForms(_ field: String, _ days: ScheduleDays, _ irregular: Bool) {
        let r = EiBi.days(field, season: .init(year: 2026, half: .b))
        #expect(r?.days == days); #expect(r?.irregular == irregular)
    }

    @Test(arguments: ["Xx", "Mo-Xx", "8", "Mo foo"])
    func unusableDays(_ field: String) { #expect(EiBi.days(field, season: .init(year: 2026, half: .b)) == nil) }

    @Test func seasonNamesAndChangeover() {
        let b26 = EiBiSeason.current(at: utcDate("2026-11-03T12:00:00Z"))
        #expect(b26 == EiBiSeason(year: 2026, half: .b) && b26.name == "b26")
        #expect(b26.url.absoluteString == "http://eibispace.de/dx/sked-b26.csv")
        #expect(EiBiSeason.current(at: utcDate("2027-03-28T01:00:00Z")).name == "a27")
        #expect(EiBiSeason.current(at: utcDate("2027-03-28T00:59:00Z")).name == "b26")
        #expect(EiBiSeason.current(at: utcDate("2027-10-31T01:00:00Z")).name == "b27")
        #expect(b26.next.name == "a27" && b26.next.next.name == "b27")
        #expect(b26.previous.name == "a26" && b26.previous.previous.name == "b25")
        #expect(b26.startsAt == utcDate("2026-10-25T01:00:00Z"))
    }

    @Test func datesFollowTheSeasonsYears() {
        let b = EiBiSeason(year: 2026, half: .b), a = EiBiSeason(year: 2027, half: .a)
        #expect(EiBi.date("2810", in: b) == ScheduleDate(year: 2026, month: 10, day: 28))
        #expect(EiBi.date("2312", in: b) == ScheduleDate(year: 2026, month: 12, day: 23))
        #expect(EiBi.date("0501", in: b) == ScheduleDate(year: 2027, month: 1, day: 5))
        #expect(EiBi.date("1506", in: a) == ScheduleDate(year: 2027, month: 6, day: 15))
        #expect(EiBi.date("[0923]", in: b) == nil)       // a "last heard" note, not a date
        #expect(EiBi.date("", in: b) == nil)
        #expect(EiBi.date("3102", in: b) == nil)
    }
}
