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
