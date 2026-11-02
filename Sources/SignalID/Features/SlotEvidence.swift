import Foundation

/// How well a signal's transmissions fit one slot grid: `fit` (0…1) for slots `periodSeconds` long, each holding a
/// transmission about `lengthSeconds` long.
public struct SlotFit: Codable, Sendable, Equatable {
    public var periodSeconds: Double
    public var lengthSeconds: Double
    /// The share of what the read shows of its transmissions (where they start, end and how long they last) that fits the
    /// grid, under one clock error. 0 when the read shows no edge at all.
    public var fit: Float
    /// How many of those fit: one edge alone fits FT4's grid by chance two times in three.
    public var events: Int

    public init(periodSeconds: Double, lengthSeconds: Double, fit: Float, events: Int) {
        self.periodSeconds = periodSeconds
        self.lengthSeconds = lengthSeconds
        self.fit = fit
        self.events = events
    }
}

/// Timing evidence for the slot modes (FT8: 15 s slots, FT4: 7.5 s): their transmissions start `startSeconds` into a
/// slot on UTC boundaries and last a fixed time.
///
/// A read's on-times are first made transmissions (`transmissions`): blips under `blipSeconds` dropped, and gaps under
/// `gapSeconds` joined (a fade, or a receiver's gain stepping down: slot modes leave at least 2.4 s between theirs). Each
/// is turned into events, judged against the grid:
/// - **a start** the read shows (not cut by its beginning) should lie `startSeconds` into a slot;
/// - **an end** it shows should lie `startSeconds` + the length into one;
/// - **how long** it lasts: one that lasts longer than the length (a continuous signal, two slots' worth) isn't a
///   transmission of the mode, and none of its events fit; one that shows both ends is one more event, which fits when
///   it lasts the length. A shorter one may be a transmission faded at an end: its edges are still judged as they are.
///
/// The Mac's clock can be off by up to `clockToleranceSeconds`, and a station's own timing and the map's resolution add a
/// little more to each event (`eventToleranceSeconds`). Every event of a read shares the clock's error: the fit is the
/// largest share of events that agree under one error within the clock's tolerance.
///
/// Timing alone never names a mode: 2 s is a large share of a 7.5 s slot, so a random start fits FT4's grid two times in
/// three. `SignalIdentifier` only lets a good fit of at least two events (`SlotFit.events`) add to a match whose tones
/// already fit.
enum SlotEvidence {
    static let clockToleranceSeconds = 2.0
    /// A slot mode's transmission starts this far into its slot.
    static let startSeconds = 0.5
    static let eventToleranceSeconds = 0.5
    static let lengthToleranceSeconds = 0.75
    static let gapSeconds = 2.0
    static let blipSeconds = 0.25
    /// An edge this near the read's own start or end is where the read was cut, not where the signal was.
    static let readEdgeSeconds = 0.25
    static let clockStepSeconds = 0.05

    /// How well `onTimes` (seconds within a read `readSeconds` long whose last sample was on the air at `readEnd`) fit
    /// slots `period` long holding transmissions `length` long. Nil without a true time.
    static func fit(onTimes: [ClosedRange<Double>], readEnd: Date?, readSeconds: Double, period: Double,
                    length: Double) -> SlotFit? {
        guard let readEnd, period > 0 else { return nil }
        let readStart = readEnd.timeIntervalSince1970 - readSeconds
        // Where `t` (seconds in the read) falls against a target point of the slot, wrapped to ±half a slot.
        func error(_ t: Double, target: Double) -> Double {
            var e = (readStart + t - target).truncatingRemainder(dividingBy: period)
            if e < -period / 2 { e += period }
            if e >= period / 2 { e -= period }
            return e
        }
        var timed: [Double] = []
        var failed = 0, fitting = 0
        for run in transmissions(onTimes) {
            let starts = run.lowerBound > readEdgeSeconds
            let ends = run.upperBound < readSeconds - readEdgeSeconds
            let seconds = run.upperBound - run.lowerBound
            guard seconds <= length + lengthToleranceSeconds else {
                // Not one of the mode's transmissions: its edges speak against the grid, and so does its length.
                failed += max(1, (starts ? 1 : 0) + (ends ? 1 : 0))
                continue
            }
            // Both ends shown: its length fits, or is one event against (a fade may have cut it; its edges say which).
            if starts && ends {
                if abs(seconds - length) <= lengthToleranceSeconds { fitting += 1 } else { failed += 1 }
            }
            if starts { timed.append(error(run.lowerBound, target: startSeconds)) }
            if ends { timed.append(error(run.upperBound, target: startSeconds + length)) }
        }
        let total = timed.count + failed + fitting
        guard total > 0 else { return SlotFit(periodSeconds: period, lengthSeconds: length, fit: 0, events: 0) }
        var agreeing = 0
        var clock = -clockToleranceSeconds
        while clock <= clockToleranceSeconds + 1e-9 {
            agreeing = max(agreeing, timed.filter { abs($0 - clock) <= eventToleranceSeconds }.count)
            clock += clockStepSeconds
        }
        return SlotFit(periodSeconds: period, lengthSeconds: length, fit: Float(agreeing + fitting) / Float(total),
                       events: agreeing + fitting)
    }

    /// On-times as transmissions, in order: those under `blipSeconds` dropped, those closer than `gapSeconds` joined.
    static func transmissions(_ onTimes: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for run in onTimes.sorted(by: { $0.lowerBound < $1.lowerBound }) where run.upperBound - run.lowerBound >= blipSeconds {
            if let last = out.last, run.lowerBound - last.upperBound < gapSeconds {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, run.upperBound)
            } else {
                out.append(run)
            }
        }
        return out
    }

    /// The fit of `onTimes` to each slot row's grid; none without a true time.
    static func all(onTimes: [ClosedRange<Double>], readEnd: Date?, readSeconds: Double) -> [SlotFit] {
        ModeTable.rows.filter { $0.slotted && $0.slotPeriodSeconds > 0 }
            .compactMap { fit(onTimes: onTimes, readEnd: readEnd, readSeconds: readSeconds, period: $0.slotPeriodSeconds,
                              length: $0.slotSeconds) }
    }
}
