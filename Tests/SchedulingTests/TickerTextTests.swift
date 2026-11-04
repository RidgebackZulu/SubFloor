import Foundation
import Testing
@testable import Scheduling

private let chicago = TimeZone(identifier: "America/Chicago")!
// 21:00 CST on 3 Nov 2026 is 03:00 UTC on the 4th.
private func at(_ hhmm: String) -> Date {
    let parts = hhmm.split(separator: ":").map { Int($0)! }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = chicago
    return calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: parts[0], minute: parts[1]))!
}

@Suite struct TickerTextTests {
    @Test func tickerTexts() {
        let korea = TickerItem(name: "Voice of Korea", start: at("21:00"), frequencyHz: 9_435_000, mode: "AM")
        let cuba = TickerItem(name: "Radio Habana Cuba", start: at("23:30"), frequencyHz: 6_000_000, mode: "AM")
        let pirates = TickerItem(name: "Pirates", start: at("19:00"), lowHz: 6_900_000, highHz: 7_000_000)
        let piratesStation = TickerItem(name: "Pirates", start: at("19:00"), frequencyHz: 6_925_000, mode: "USB")

        func text(_ s: ScheduleButtonState) -> String { TickerText.text(s, zone: chicago) }
        #expect(text(.off(waiting: 4)) == "off · 4 schedules waiting")
        #expect(text(.off(waiting: 1)) == "off · 1 schedule waiting")
        #expect(text(.later([korea, cuba])) == "next 21:00 · Voice of Korea · 9435 kHz · then 23:30 · Radio Habana Cuba · 6000 kHz")
        #expect(text(.later([pirates])) == "next 19:00 · Pirates · 6900–7000 kHz")
        #expect(text(.later([korea, cuba, pirates, korea])) ==
                "next 21:00 · Voice of Korea · 9435 kHz · then 23:30 · Radio Habana Cuba · 6000 kHz · then 19:00 · Pirates · 6900–7000 kHz")
        #expect(text(.soon(korea, secondsLeft: 272)) == "in 4:32 · Voice of Korea · 9435 kHz AM · click to start now")
        #expect(text(.soon(korea, secondsLeft: 45)) == "in 0:45 · Voice of Korea · 9435 kHz AM · click to start now")
        #expect(text(.recording(korea, elapsed: 600, marginDb: 8, until: at("21:30"))) ==
                "Voice of Korea · 9435 kHz AM · until 21:30 · squelch 8 dB over the noise")
        #expect(text(.watching(pirates, caught: 2, until: at("02:00"))) ==
                "Pirates · 6900–7000 kHz · quiet now · 2 caught tonight · until 02:00")
        #expect(text(.watching(pirates, caught: 1, until: at("02:00"))).contains("1 caught tonight"))
        #expect(text(.watching(pirates, caught: 0, until: at("02:00"))).contains("none caught yet"))
        #expect(text(.recording(piratesStation, elapsed: 5, marginDb: 8, until: at("02:00"))) ==
                "Pirates · 6925 kHz USB · until 02:00 · squelch 8 dB over the noise")
    }

    @Test func fractionalKilohertzShowsOneDecimal() {
        let item = TickerItem(name: "Test", start: at("21:00"), frequencyHz: 6_925_500, mode: "USB")
        #expect(TickerText.text(.soon(item, secondsLeft: 60), zone: chicago) == "in 1:00 · Test · 6925.5 kHz USB · click to start now")
    }
}
