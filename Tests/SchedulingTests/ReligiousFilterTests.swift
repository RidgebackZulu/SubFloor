import Testing
import Foundation
@testable import Scheduling

@Test(arguments: ["Trans World Radio", "Adventist World Radio", "FEBC Radio", "Radio Vaticana", "Bible Voice Broadcasting",
                  "Follow the Bible", "Hope Radio", "Brother Stair", "Voz Missionaria", "Mystery for Joy", "Hope of Israel",
                  "Evang. Missionsgemeinden", "HCJB", "Family Radio", "KNLS", "Voice of Hope", "WWCR", "WTWW", "WINB",
                  "Gospel for Asia", "Christian Vision", "Radio Faith", "Missionswerk", "Église catholique", "Islamic Republic Radio Quran",
                  "Jesus Saves", "Church of God", "World Harvest Hope", "Rádio Católica", "Radio Cattolica"])
func religiousStationsAreCaught(_ name: String) { #expect(ReligiousFilter.bundled.isReligious(name)) }

@Test(arguments: ["WRMI", "WRMI Okeechobee", "WBCQ", "Sound of Hope", "Hopen Island Meteo", "Voice of Korea", "Radio Habana Cuba",
                  "China Radio International", "Radio Free Asia", "Voice of America", "Radio Mashaal"])
func secularStationsPass(_ name: String) { #expect(!ReligiousFilter.bundled.isReligious(name)) }

@Test func matchingRulesOnACustomFilter() {
    let filter = ReligiousFilter(denylist: ["Ministry X"], keywords: ["Christ"], allowlist: ["Christmas Radio"])
    #expect(filter.isReligious("Ministry X Radio"))            // denylist: substring
    #expect(filter.isReligious("Christian Hour"))              // keyword: start of a word
    #expect(!filter.isReligious("Mistchrist Radio"))           // keyword is not matched mid-word
    #expect(!filter.isReligious("Christmas Radio Christ"))     // allowlist wins over keyword
    #expect(filter.isReligious("CHRÍST Radio"))                // case and diacritics are folded
}

@Test(arguments: ["Radio YHWH", "Pescador Preacher", "WMLK Bethel, PA", "WBCQ World's Last Chance", "Radio Maria",
                  "Assemblies of Yahweh", "Iglesia Ni Cristo", "Igreja Universal", "Muslim World Voice", "Allah Akbar Radio",
                  "Radio Cristiana", "Rádio Cristã"])
func religiousStationsFromTheB26ReviewAreCaught(_ name: String) { #expect(ReligiousFilter.bundled.isReligious(name)) }

@Test(arguments: ["WBCQ The Planet", "WRMI Radio Miami", "Radio Cristóbal"])
func theAllowlistOnlyCancelsKeywordHits(_ name: String) { #expect(!ReligiousFilter.bundled.isReligious(name)) }

@Test func theAllowlistDoesNotOverrideTheDenylist() {
    let filter = ReligiousFilter(denylist: ["Last Chance"], keywords: ["Christ"], allowlist: ["WBCQ"])
    #expect(filter.isReligious("WBCQ World's Last Chance"))   // denylist first
    #expect(!filter.isReligious("WBCQ Christmas Show"))        // the allowlist cancels a keyword hit
}

@Test func theBundledNorthAmericaTimetableHasNoReligiousStation() {
    let t = Timetable(data: Timetable.bundledData(), season: EiBiSeason(year: 2026, half: .b))
    let names = Set(t.broadcasts.map(\.station))
    for banned in ["Radio YHWH", "Pescador Preacher", "WMLK Bethel, PA", "WBCQ World's Last Chance"] {
        #expect(!names.contains(banned), "\(banned)")
    }
    let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
    for name in names {
        #expect(!ReligiousFilter.bundled.denylist.contains { fold(name).contains(fold($0)) }, "\(name)")
    }
}
