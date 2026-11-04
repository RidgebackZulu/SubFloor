import Testing
import Foundation
@testable import Scheduling

private let chicago = "America/Chicago"

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("subfloor-\(UUID())/schedules.json")
}

private func backupFiles(in dir: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter {
        $0.lastPathComponent.hasPrefix("schedules.corrupt-") && $0.lastPathComponent.hasSuffix(".json")
    }
}

private func broadcast(_ name: String = "Radio Habana Cuba", frequencies: [Double] = [5_040_000]) -> Schedule {
    Schedule(kind: .broadcast, name: name, frequenciesHz: frequencies, mode: .am,
             start: TimeOfDay(hour: 22, minute: 0), durationMinutes: 30, timeZone: "UTC",
             days: .weekly([.mo, .we]), created: Date(timeIntervalSince1970: 1_700_000_000))
}

private func watch(low: Double, high: Double) -> Schedule {
    Schedule(kind: .watch, name: "Watch", lowHz: low, highHz: high, mode: .auto,
             start: TimeOfDay(hour: 19, minute: 0), durationMinutes: 60, timeZone: chicago,
             days: .weekly([.fr]), created: Date(timeIntervalSince1970: 1_700_000_000))
}

@Test func firstLaunchMakesTheDefaultWatchSwitchedOff() {
    let (schedules, result) = ScheduleStore(url: tempURL()).load(localZone: chicago)
    #expect(result == .createdDefaults)
    #expect(schedules.count == 1)
    let w = schedules[0]
    #expect(w.enabled == false)
    #expect(w.name == "Pirates")
    #expect(w.kind == .watch)
    #expect(w.lowHz == 6_900_000 && w.highHz == 7_000_000)
    #expect(w.mode == .auto)
    #expect(w.days == .weekly([.fr, .sa]))
    #expect(w.start == TimeOfDay(hour: 19, minute: 0))
    #expect(w.durationMinutes == 420)
    #expect(w.timeZone == chicago)
    #expect(w.squelchMarginDb == 8)
    #expect(w.source == .you)
    #expect(w.addedBy == nil)
}

@Test func saveAndLoadRoundTrip() throws {
    let url = tempURL()
    var b = broadcast(frequencies: [5_040_000, 6_000_000])
    b.lastRun = LastRun(outcome: .recorded(seconds: 600, files: 2), at: Date(timeIntervalSince1970: 1_700_003_600))
    b.timetableKey = TimetableKey(station: "RHC", language: "S", season: "b26")
    b.timetableNote = .updated(Date(timeIntervalSince1970: 1_700_000_100))
    let w = watch(low: 6_900_000, high: 7_000_000)
    try ScheduleStore(url: url).save([b, w])
    let (loaded, result) = ScheduleStore(url: url).load(localZone: chicago)
    #expect(result == .loaded)
    #expect(loaded == [b, w])
}

@Test func corruptFileIsKeptAsideAndDefaultsReturn() throws {
    let url = tempURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{ nope".utf8).write(to: url)
    let store = ScheduleStore(url: url)
    let (loaded, result) = store.load(localZone: chicago)
    #expect(result == .recoveredFromCorrupt)
    #expect(loaded.count == 1 && loaded[0].name == "Pirates" && loaded[0].enabled == false)
    let backups = try backupFiles(in: url.deletingLastPathComponent())
    #expect(backups.count == 1)
    #expect(store.lastBackupURL?.lastPathComponent == backups.first?.lastPathComponent)
    #expect(try backups.map { try Data(contentsOf: $0) } == [Data("{ nope".utf8)])
}

@Test func secondCorruptionNeverOverwritesTheFirstBackup() throws {
    let url = tempURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{ nope".utf8).write(to: url)
    #expect(ScheduleStore(url: url).load(localZone: chicago).1 == .recoveredFromCorrupt)
    try Data("{ second".utf8).write(to: url)
    #expect(ScheduleStore(url: url).load(localZone: chicago).1 == .recoveredFromCorrupt)
    let backups = try backupFiles(in: url.deletingLastPathComponent())
    #expect(backups.count == 2)
    #expect(Set(backups.map(\.path)).count == 2)
    #expect(Set(try backups.map { try String(contentsOf: $0, encoding: .utf8) }) == ["{ nope", "{ second"])
}

@Test func invalidRowsAreDropped() throws {
    let url = tempURL()
    let good = broadcast("Good")
    let tooMany = broadcast("Nine", frequencies: (1...9).map { Double($0) * 1_000_000 })
    let none = broadcast("None", frequencies: [])
    let wide = watch(low: 6_900_000, high: 7_400_001)
    let narrow = watch(low: 7_000_000, high: 7_005_000)
    let edge = watch(low: 7_000_000, high: 7_400_000)
    try ScheduleStore(url: url).save([tooMany, good, none, wide, narrow, edge])
    let (loaded, result) = ScheduleStore(url: url).load(localZone: chicago)
    #expect(result == .loaded)
    #expect(loaded.map(\.name) == ["Good", "Watch"])
    #expect(loaded[1].highHz == 7_400_000)
}

@Test func aFileWhoseEveryRowIsInvalidLoadsEmpty() throws {
    let url = tempURL()
    try ScheduleStore(url: url).save([broadcast("Nine", frequencies: (1...9).map { Double($0) * 1_000_000 })])
    let (loaded, result) = ScheduleStore(url: url).load(localZone: chicago)
    #expect(result == .loaded)
    #expect(loaded.isEmpty)
}
