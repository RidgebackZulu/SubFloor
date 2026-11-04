import Foundation

/// The run the engine currently has going.
public struct ActiveRun: Hashable, Sendable {
    public var scheduleID: UUID
    public var window: DateInterval
    public var kind: ScheduleKind
    public var startedEarly: Bool
    public init(scheduleID: UUID, window: DateInterval, kind: ScheduleKind, startedEarly: Bool) {
        self.scheduleID = scheduleID; self.window = window; self.kind = kind; self.startedEarly = startedEarly
    }
}

/// One window of one schedule. A settled key never starts (again).
public struct RunKey: Hashable, Sendable {
    public var scheduleID: UUID
    public var window: DateInterval
    public init(scheduleID: UUID, window: DateInterval) { self.scheduleID = scheduleID; self.window = window }
}

public enum PlannerAction: Equatable, Sendable {
    case start(UUID, window: DateInterval, late: Bool)
    case preempt(running: UUID, by: UUID, window: DateInterval)     // a broadcast takes the radio from a watch
    case end(UUID)                                                  // the running window closed
    case log(UUID, RunOutcome, at: Date)                            // missed or overlapped
}

/// Pure decisions: no state, no clock. The run engine feeds it each tick and acts on what comes back.
public enum SchedulePlanner {
    public static let pulseLead: TimeInterval = 300
    /// A gap between ticks longer than this means the Mac slept.
    public static let sleepGap: TimeInterval = 30
    /// More than this past a window's start is a late start.
    static let lateAfter: TimeInterval = 5

    /// Decisions for one tick, in the order: `.end`, missed logs, `.start`/`.preempt`, overlapped logs.
    /// `lastTick` nil means launch. `lastAlive` is the last time SubFloor was known running (from the session),
    /// for windows that ended while it wasn't. `settled` are windows that must not start (again): the engine adds
    /// one when the owner stopped it, it was logged overlapped, or it was missed or cut short. Only enabled
    /// schedules count, and nothing starts or is logged while `on` is false.
    public static func tick(schedules: [Schedule], on: Bool, now: Date, lastTick: Date?, lastAlive: Date?,
                            running: ActiveRun?, settled: Set<RunKey>) -> [PlannerAction] {
        var actions: [PlannerAction] = []
        var holder = running
        if let r = running, now >= r.window.end {
            actions.append(.end(r.scheduleID))
            holder = nil
        }
        guard on else { return actions }
        let enabled = schedules.filter(\.enabled)

        // Windows that came and went unrun.
        let missedFrom: Date?
        let missedOutcome: RunOutcome
        if let lastTick {
            missedFrom = now.timeIntervalSince(lastTick) > sleepGap ? lastTick : nil
            missedOutcome = .missedAsleep
        } else {
            missedFrom = lastAlive
            missedOutcome = .missedNotRunning
        }
        if let from = missedFrom, from < now {
            var missed: [(Date, UUID)] = []
            for s in enabled {
                for w in ScheduleClock.windows(of: s, from: from, to: now) where w.end > from && w.end <= now {
                    let isRunning = running?.scheduleID == s.id && running?.window == w
                    if !isRunning && !settled.contains(RunKey(scheduleID: s.id, window: w)) {
                        missed.append((w.end, s.id))
                    }
                }
            }
            for (_, id) in missed.sorted(by: { $0.0 < $1.0 }) { actions.append(.log(id, missedOutcome, at: now)) }
        }

        // Windows open now that nobody is running.
        var candidates: [(schedule: Schedule, window: DateInterval)] = []
        for s in enabled {
            for w in ScheduleClock.windows(of: s, from: now, to: now.addingTimeInterval(1)) where w.start <= now {
                let isRunning = holder?.scheduleID == s.id && holder?.window == w
                if !isRunning && !settled.contains(RunKey(scheduleID: s.id, window: w)) { candidates.append((s, w)) }
            }
        }
        // Broadcasts first, then the earlier `created`.
        candidates.sort {
            if $0.schedule.kind != $1.schedule.kind { return $0.schedule.kind == .broadcast }
            if $0.schedule.created != $1.schedule.created { return $0.schedule.created < $1.schedule.created }
            return $0.schedule.id.uuidString < $1.schedule.id.uuidString
        }
        func overlapped(_ losers: some Sequence<(schedule: Schedule, window: DateInterval)>, with name: String) {
            for l in losers { actions.append(.log(l.schedule.id, .overlapped(with: name), at: now)) }
        }

        if let current = holder {
            let name = schedules.first { $0.id == current.scheduleID }?.name ?? ""
            if current.kind == .watch, let winner = candidates.first, winner.schedule.kind == .broadcast {
                actions.append(.preempt(running: current.scheduleID, by: winner.schedule.id, window: winner.window))
                overlapped(candidates.dropFirst().filter { $0.schedule.kind == .broadcast }, with: winner.schedule.name)
            } else if current.kind == .broadcast {
                // A preempted watch just waits; only another broadcast is turned away.
                overlapped(candidates.filter { $0.schedule.kind == .broadcast }, with: name)
            } else {
                overlapped(candidates, with: name)
            }
        } else if let winner = candidates.first {
            actions.append(.start(winner.schedule.id, window: winner.window,
                                  late: now.timeIntervalSince(winner.window.start) > lateAfter))
            overlapped(candidates.dropFirst(), with: winner.schedule.name)
        }
        return actions
    }

    /// The enabled schedules that run next (windows ending after `now`, so one running now counts), up to three,
    /// ordered by window start.
    public static func next(_ schedules: [Schedule], after now: Date) -> [(Schedule, DateInterval)] {
        let upcoming = schedules.filter(\.enabled).compactMap { s in
            ScheduleClock.nextWindow(of: s, after: now).map { (s, $0) }
        }
        let sorted = upcoming.sorted {
            $0.1.start != $1.1.start ? $0.1.start < $1.1.start : $0.0.created < $1.0.created
        }
        return Array(sorted.prefix(3))
    }

    /// True when the switch is on and an enabled window is open now or starts within 24 h.
    public static func needsKeepAwake(_ schedules: [Schedule], on: Bool, now: Date) -> Bool {
        guard on else { return false }
        let horizon = now.addingTimeInterval(24 * 3600)
        return schedules.filter(\.enabled).contains { s in
            ScheduleClock.nextWindow(of: s, after: now).map { $0.start <= horizon } ?? false
        }
    }

    /// The names of other enabled schedules whose windows overlap `s`'s in the next 14 days.
    public static func overlaps(of s: Schedule, in all: [Schedule], now: Date) -> [String] {
        let end = now.addingTimeInterval(14 * 86_400)
        let mine = ScheduleClock.windows(of: s, from: now, to: end)
        var names: [String] = []
        for other in all where other.enabled && other.id != s.id && !names.contains(other.name) {
            let theirs = ScheduleClock.windows(of: other, from: now, to: end)
            if mine.contains(where: { a in theirs.contains { b in a.start < b.end && b.start < a.end } }) {
                names.append(other.name)
            }
        }
        return names
    }
}

/// What the Schedule button is showing.
public enum ScheduleButtonState: Equatable, Sendable {
    case off(waiting: Int)
    case later([TickerItem])
    case soon(TickerItem, secondsLeft: Int)
    case recording(TickerItem, elapsed: Int, marginDb: Float, until: Date)
    case watching(TickerItem, caught: Int, until: Date)
}

public struct TickerItem: Equatable, Sendable {
    public var name: String
    public var start: Date
    public var frequencyHz: Double?
    public var lowHz: Double?
    public var highHz: Double?
    public var mode: String?
    public init(name: String, start: Date, frequencyHz: Double? = nil, lowHz: Double? = nil, highHz: Double? = nil,
                mode: String? = nil) {
        self.name = name; self.start = start; self.frequencyHz = frequencyHz
        self.lowHz = lowHz; self.highHz = highHz; self.mode = mode
    }
}

public enum TickerText {
    private static let separator = " · "

    public static func text(_ s: ScheduleButtonState, zone: TimeZone) -> String {
        switch s {
        case .off(let waiting):
            return "off · \(waiting) \(waiting == 1 ? "schedule" : "schedules") waiting"
        case .later(let items):
            guard !items.isEmpty else { return "nothing scheduled" }
            let parts = items.prefix(3).map { "\(clock($0.start, zone)) · \(describe($0, withMode: false))" }
            return "next " + parts.joined(separator: " · then ")
        case .soon(let item, let secondsLeft):
            let seconds = max(0, secondsLeft)
            return "in \(seconds / 60):" + String(format: "%02d", seconds % 60)
                + " · \(describe(item, withMode: true)) · click to start now"
        case .recording(let item, _, let marginDb, let until):
            return [describe(item, withMode: true), "until \(clock(until, zone))",
                    "squelch \(number(Double(marginDb))) dB over the noise"].joined(separator: separator)
        case .watching(let item, let caught, let until):
            let count = caught == 0 ? "none caught yet" : "\(caught) caught tonight"
            return [describe(item, withMode: false), "quiet now", count, "until \(clock(until, zone))"]
                .joined(separator: separator)
        }
    }

    /// `Name · 9435 kHz AM`, or `Name · 6900–7000 kHz` for a band.
    private static func describe(_ item: TickerItem, withMode: Bool) -> String {
        var frequency = ""
        if let f = item.frequencyHz {
            frequency = "\(number(f / 1000)) kHz"
        } else if let low = item.lowHz, let high = item.highHz {
            frequency = "\(number(low / 1000))–\(number(high / 1000)) kHz"
        }
        if withMode, !frequency.isEmpty, let mode = item.mode { frequency += " " + mode.uppercased() }
        return frequency.isEmpty ? item.name : item.name + separator + frequency
    }

    /// No decimals when whole, else one.
    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private static func clock(_ date: Date, _ zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
