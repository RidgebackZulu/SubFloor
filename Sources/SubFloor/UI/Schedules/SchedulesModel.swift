import Foundation
import IOKit.ps
import Observation
import Scheduling

/// Whether the Mac runs on battery (the keep-awake note turns amber).
enum PowerSource {
    static func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}

/// What the Schedules window shows and does, apart from the drawing: rows, the timetable search, the notes, the
/// credit line, and the add, toggle and delete actions. Errors the owner should see land in `message`.
@MainActor @Observable
final class SchedulesModel {
    static let keepAwakeNote = "SubFloor keeps the Mac awake for schedules, but it has to be open, and a Mac with its lid closed and no external display sleeps anyway."
    static let transcriptionNote = "Transcription is off in Settings, so scheduled recordings get no transcripts."

    @ObservationIgnored let scheduler: Scheduler
    @ObservationIgnored let transcriptionEnabled: () -> Bool
    @ObservationIgnored let isOnBattery: () -> Bool

    var search = ""
    var onTonight = false
    /// The last refusal (a schedule that can't be added or changed), shown in the window.
    var message: String?

    init(scheduler: Scheduler, transcriptionEnabled: @escaping () -> Bool,
         isOnBattery: @escaping () -> Bool = PowerSource.isOnBattery) {
        self.scheduler = scheduler
        self.transcriptionEnabled = transcriptionEnabled
        self.isOnBattery = isOnBattery
    }

    private var now: Date { scheduler.now() }
    private var zone: TimeZone { scheduler.localZone }

    // MARK: My schedules

    var rows: [ScheduleRow] {
        let now = now
        return scheduler.schedules.map { s in
            ScheduleRow(schedule: s, now: now, zone: zone,
                        overlaps: SchedulePlanner.overlaps(of: s, in: scheduler.schedules, now: now))
        }
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard var s = scheduler.schedules.first(where: { $0.id == id }) else { return }
        s.enabled = on
        message = nil
        do { try scheduler.update(s) } catch { message = Self.text(of: error) }
    }

    func delete(_ id: UUID) {
        message = nil
        scheduler.delete(id)
    }

    // MARK: Notes

    /// Amber while the Mac is on battery.
    var keepAwakeIsAmber: Bool { isOnBattery() }
    /// Shown while transcription is off.
    var transcriptionNoteText: String? { transcriptionEnabled() ? nil : Self.transcriptionNote }

    // MARK: Timetable

    /// The timetable's rows for the search words and the On tonight filter, in the timetable's order (or, for On
    /// tonight, by start).
    var timetableRows: [TimetableRow] {
        let timetable = scheduler.timetable
        let now = now
        var found = search.trimmingCharacters(in: .whitespaces).isEmpty ? timetable.broadcasts : timetable.search(search)
        if onTonight {
            let tonight = Set(timetable.onTonight(now: now).map(\.id))
            found = found.filter { tonight.contains($0.id) }
        }
        let schedules = scheduler.schedules
        return found.map { b in
            var row = TimetableRow(broadcast: b, zone: zone, now: now)
            row.added = Self.isAdded(b, in: schedules, now: now)
            return row
        }
    }

    /// A schedule carries the broadcast when its timetable key has the same station and language, starts at
    /// the same UTC time of day and runs the same days (frequencies may have been edited, and the key's season moves on).
    static func isAdded(_ b: TimetableBroadcast, in schedules: [Schedule], now: Date) -> Bool {
        schedules.contains { s in
            guard let key = s.timetableKey, key.station == b.station, key.language == b.language else { return false }
            return ScheduleWhen.utcMinutes(of: s, now: now) == b.start.hour * 60 + b.start.minute && s.days == b.days
        }
    }

    /// Adds the broadcast as the owner's schedule (`source` `.timetable`, with its timetable key).
    func add(_ row: TimetableRow) {
        message = nil
        do { try scheduler.add(scheduler.timetable.schedule(from: row.broadcast, now: now, addedBy: nil)) }
        catch { message = Self.text(of: error) }
    }

    /// `Timetable: EiBi, by Eike Bierwirth (eibispace.de) · season B26 · checked 2 days ago`
    var creditLine: String {
        let base = "Timetable: EiBi, by Eike Bierwirth (eibispace.de) · season \(scheduler.timetable.season.name.uppercased())"
        guard let checked = scheduler.timetableCheckedAt else { return base + " · bundled copy" }
        return base + " · checked " + Self.ago(from: checked, to: now)
    }

    static func ago(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        func unit(_ n: Int, _ name: String) -> String { "\(n) \(name)\(n == 1 ? "" : "s") ago" }
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return unit(Int(seconds / 60), "minute") }
        if seconds < 86_400 { return unit(Int(seconds / 3600), "hour") }
        return unit(Int(seconds / 86_400), "day")
    }

    // MARK: The editor

    /// Saves `draft` as a new schedule, or over `original`. Nil when it saved, else the text to show.
    func save(_ draft: ScheduleDraft, replacing original: Schedule?) -> String? {
        do {
            // Onto the schedule as it is now: a run, an agent or a relink may have changed it since the editor opened.
            let current = original.map { o in scheduler.schedules.first { $0.id == o.id } ?? o }
            let s = try draft.build(replacing: current, now: now)
            if original == nil { try scheduler.add(s) } else { try scheduler.update(s) }
            return nil
        } catch { return Self.text(of: error) }
    }

    /// "Overlaps with A, B" while the draft builds and overlaps another enabled schedule.
    func overlapText(for draft: ScheduleDraft, replacing original: Schedule?) -> String? {
        guard let s = try? draft.build(replacing: original, now: now) else { return nil }
        let names = SchedulePlanner.overlaps(of: s, in: scheduler.schedules, now: now)
        return names.isEmpty ? nil : "Overlaps with \(names.joined(separator: ", "))"
    }

    private static func text(of error: Error) -> String { (error as? ScheduleError)?.message ?? error.localizedDescription }
}

/// The editor's fields. `build` makes the schedule, or throws the `ScheduleError` whose message the editor shows.
struct ScheduleDraft: Equatable {
    enum Repeat: String, CaseIterable, Identifiable {
        case weekly = "Weekly", monthly = "Monthly", once = "Once"
        var id: String { rawValue }
    }

    var kind: ScheduleKind = .broadcast
    var name = ""
    /// kHz, comma-separated.
    var frequencies = ""
    var lowKHz = ""
    var highKHz = ""
    var mode: ScheduleMode = .am
    var start = TimeOfDay(hour: 20, minute: 0)
    /// Minutes, as typed: the field is text, so Save sees what's in it even before the field commits.
    var duration = "30"
    var repeats: Repeat = .weekly
    var weekdays: Set<Weekday> = Set(Weekday.allCases)
    var ordinal = 1
    var monthlyWeekday: Weekday = .sa
    var onceDate = ScheduleDate(year: 2026, month: 1, day: 1)
    var timeZone: String
    var enabled = true
    var marginDb = 8.0

    /// A new broadcast in `zone`, on the next whole hour, once-date today.
    init(zone: TimeZone, now: Date) {
        timeZone = zone.identifier
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour], from: now)
        start = TimeOfDay(hour: ((c.hour ?? 19) + 1) % 24, minute: 0)
        onceDate = ScheduleDate(year: c.year!, month: c.month!, day: c.day!)
    }

    init(_ s: Schedule) {
        kind = s.kind
        name = s.name
        frequencies = s.frequenciesHz.map(kHzText).joined(separator: ", ")
        lowKHz = s.lowHz.map(kHzText) ?? ""
        highKHz = s.highHz.map(kHzText) ?? ""
        mode = s.mode
        start = s.start
        duration = String(s.durationMinutes)
        timeZone = s.timeZone
        enabled = s.enabled
        marginDb = Double(s.squelchMarginDb)
        switch s.days {
        case .weekly(let set): repeats = .weekly; weekdays = set
        case .monthly(let o, let d): repeats = .monthly; ordinal = o; monthlyWeekday = d
        case .once(let d): repeats = .once; onceDate = d
        }
    }

    func build(replacing original: Schedule?, now: Date) throws -> Schedule {
        func bad(_ text: String) -> ScheduleError { .invalid(text) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw bad("name can't be empty.") }
        if let problem = Scheduler.timeZoneProblem(timeZone) { throw bad(problem) }
        guard let typed = Int(duration.trimmingCharacters(in: .whitespaces)) else {
            throw bad("Duration is in whole minutes, e.g. 30.")
        }
        // Capped so the live overlap check can't overflow; `Scheduler.validate` gives the real limits.
        let durationMinutes = min(typed, 1_000_000)

        func khz(_ text: String) -> Double? {
            Double(text.trimmingCharacters(in: .whitespaces)).map { ($0 * 1000).rounded() }
        }
        var hz: [Double] = []
        var low: Double?, high: Double?
        switch kind {
        case .broadcast:
            let parts = frequencies.split(separator: ",", omittingEmptySubsequences: false)
            let parsed = parts.map { khz(String($0)) }
            guard !parts.isEmpty, !parsed.contains(where: { $0 == nil }) else {
                throw bad("Frequencies are in kHz, comma-separated, e.g. 9435, 9455.")
            }
            hz = parsed.compactMap { $0 }
        case .watch:
            guard let l = khz(lowKHz), let h = khz(highKHz) else { throw bad("A watch needs low and high (kHz).") }
            low = l; high = h
        }

        let days: ScheduleDays
        switch repeats {
        case .weekly:
            guard !weekdays.isEmpty else { throw bad("Pick at least one day.") }
            days = .weekly(weekdays)
        case .monthly: days = .monthly(ordinal: ordinal, weekday: monthlyWeekday)
        case .once: days = .once(onceDate)
        }

        var s = original ?? Schedule(kind: kind, name: trimmed, mode: mode, start: start, durationMinutes: durationMinutes,
                                     timeZone: timeZone, days: days, created: now)
        s.kind = kind; s.name = trimmed; s.frequenciesHz = hz; s.lowHz = low; s.highHz = high; s.mode = mode
        s.start = start; s.durationMinutes = durationMinutes; s.timeZone = timeZone; s.days = days
        s.enabled = enabled; s.squelchMarginDb = Float(marginDb)
        return s   // `Scheduler.add`/`update` check the rest, with the same texts as the MCP tools
    }
}
