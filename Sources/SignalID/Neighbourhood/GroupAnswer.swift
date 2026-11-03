import DSPCore
import Foundation

// Several signals under the point: one answer that describes them all (`SignalIdentifier.underThePoint`), and its label.

extension SignalIdentity {
    /// `label` for several signals: the group's form when every one reads as its slot mode, otherwise the named modes by
    /// count and the unknown last (`Several signals: FT8 ×4, unknown ×7`). One whose name is inherited counts as its mode.
    var groupLabel: String {
        let names = signals.map(\.countedName)
        if let span = groupSpanHz, let name = names.first ?? nil, names.allSatisfy({ $0 == name }) {
            return "\(name) · \(signals.count) signals · \(Self.span(span, centreHz: captureCenterHz ?? 0))"
        }
        // Named modes first, the most first (ties by name), and the unknown last.
        let counts = Dictionary(grouping: names.compactMap { $0 }) { $0 }.mapValues(\.count)
        var parts = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { "\($0.key) ×\($0.value)" }
        let unknown = names.filter { $0 == nil }.count
        if unknown > 0 { parts.append("unknown ×\(unknown)") }
        return "Several signals: " + parts.joined(separator: ", ")
    }

    /// The mode a group's label counts this signal under: its name, or the one it inherited (`nameInherited`).
    var countedName: String? { best?.name ?? (nameInherited ? alternatives.first?.name : nil) }

    /// `14.0731–14.0755 MHz`, `474.2–475.0 kHz`: a span relative to `centreHz`, in display Hz.
    static func span(_ span: ClosedRange<Double>, centreHz: Double) -> String {
        let lower = centreHz + span.lowerBound, upper = centreHz + span.upperBound
        if abs(lower) >= 1_000_000 { return String(format: "%.4f–%.4f MHz", lower / 1e6, upper / 1e6) }
        return String(format: "%.1f–%.1f kHz", lower / 1e3, upper / 1e3)
    }

}

extension SignalIdentifier {
    /// At most this many signals under the point are measured in the first pass: the point's own and the strongest others.
    static let firstPassMeasured = 3
    /// Signals of one slot mode this close together (edge to edge) are one connected group.
    static let groupGapHz = 400.0
    /// An unmeasured trace takes a measured one's slot mode only when its width on the map is within this share of that
    /// one's: FT4's traces read about twice FT8's, and two FT8 stations side by side as one trace wider still.
    static let inheritWidthShare = 0.3
    /// With a true time, an unmeasured trace's own transmissions must fit the slot mode's slots this well (a share of its
    /// events, so one at least): timing that tells nothing lends nothing.
    static let inheritSlotFit: Float = 0.55
    /// A name taken from a measured neighbour, on its timing and width alone, is never a name: it stays this sure, under
    /// `nameThreshold` (a station keying up within the clocks' 2 s of an FT8 shares both).
    static let inheritedConfidence: Float = 0.65

    /// `point` (the answer for the signal nearest the point) with every other signal under the point (`signals`): the
    /// lines and FSKs `SignalGrouper` found within `radiusHz` of it, except an interference comb's lines (`isCombLine`),
    /// which are no signals. Fewer than two of them leaves `point` as it is (but a comb's line at the point beside one
    /// other gives that one's answer), and so does a point inside an area (voice, AM): that signal is the point's. A
    /// cancelled task gets `cancelledNote`.
    /// - The point's own is the one its answer lies on (the strongest of equals), and whatever lies inside its answer (a
    ///   carrier's sidebands, an FSK's tones): so is what lies inside another one's. When the point's own is a comb's line,
    ///   the answer is the nearest of the others.
    /// - Up to `firstPassMeasured` are measured, the point's own and then the strongest, as the point is
    ///   (`memberAnswer`).
    /// - When the names among them are one slot mode's (FT8, FT4) alone, the signals are its whole connected group
    ///   (`groupGapHz` apart at most, as far as the view goes), and `groupSpanHz` its span.
    /// - One not measured takes the slot-mode name of the nearest measured one it fits the same slot and width as
    ///   (`fitsSameSlot`); otherwise it is unknown, until it is measured itself.
    static func underThePoint(_ point: SignalIdentity, first: [Float], sampleRate: Double, captureCenterHz: Double,
                              hood: Neighbourhood, view: NeighbourhoodView, signals: [SignalCandidate], pointHz: Double,
                              radiusHz: Double, seconds: Double, endTime: Date?, readsTones: Bool,
                              combLinesHz: [Double]) -> SignalIdentity {
        func isComb(_ c: SignalCandidate) -> Bool {
            c.tones == nil && c.traces.count == 1
                && InterferenceComb.isCombLine(c.traces[0], view: view, map: hood.map, linesHz: combLinesHz)
        }
        func distance(_ c: SignalCandidate, from hz: Double) -> Double { max(0, c.lowerHz - hz, hz - c.upperHz) }
        // A point inside an area (voice, AM) is that signal's alone.
        guard !view.areas.contains(where: { $0.lowerHz...$0.upperHz ~= pointHz }) else { return point }
        let near = signals.filter { $0.kind != .area && distance($0, from: pointHz) <= radiusHz }
        let inRadius = near.filter { !isComb($0) }
        // The point's own: where its answer lies.
        let at = point.measurement.offsetHz
        guard let own = near.min(by: {
            (distance($0, from: at), -level($0)) < (distance($1, from: at), -level($1))
        }) else { return point }
        // A comb's line at the point is no signal of them: the others are measured as many, and the nearest is the answer.
        // Only when the answer at the point is the comb's: a station on a comb place keeps its own.
        let onComb = isComb(own) && point.comb != nil
        func answer(_ c: SignalCandidate) -> SignalIdentity {
            memberAnswer(c, first: first, sampleRate: sampleRate, captureCenterHz: captureCenterHz, hood: hood, view: view,
                         signals: signals, seconds: seconds, endTime: endTime, readsTones: readsTones)
        }
        guard inRadius.count >= 2 else {
            guard onComb, let other = inRadius.first else { return point }
            return Task.isCancelled ? cancelled(point.measurement) : answer(other)
        }
        var measured: [(candidate: SignalCandidate, identity: SignalIdentity)] = onComb ? [] : [(own, point)]
        func taken(_ c: SignalCandidate) -> Bool { measured.contains { $0.candidate == c || holds($0.identity, c) } }
        for c in inRadius.sorted(by: { level($0) > level($1) }) where measured.count < firstPassMeasured && !taken(c) {
            let identity = Task.isCancelled ? cancelled(point.measurement) : answer(c)
            if identity.note == cancelledNote { return identity }
            measured.append((c, identity))
        }
        let names = Set(measured.compactMap { $0.identity.best?.name })
        let mode = names.count == 1 ? names.first.flatMap(ModeTable.row).flatMap { $0.slotted ? $0 : nil } : nil

        // The signals: those in the radius, or a slot mode's whole connected group.
        var members = inRadius
        if mode != nil {
            var span = (lower: inRadius.map(\.lowerHz).min()!, upper: inRadius.map(\.upperHz).max()!)
            var grew = true
            while grew {
                grew = false
                for c in signals where c.kind != .area && !members.contains(c) && !isComb(c)
                    && max(c.lowerHz - span.upper, span.lower - c.upperHz) <= groupGapHz {
                    members.append(c)
                    span = (min(span.lower, c.lowerHz), max(span.upper, c.upperHz))
                    grew = true
                }
            }
        }
        var answers = measured.map(\.identity)
        var spans = measured.map { ($0.candidate.lowerHz, $0.candidate.upperHz) }
        for c in members where !taken(c) {
            let centre = (c.lowerHz + c.upperHz) / 2
            let from = measured.filter { entry in
                guard let row = entry.identity.best.flatMap({ ModeTable.row($0.name) }), row.slotted else { return false }
                return fitsSameSlot(c, as: entry.candidate, readSeconds: seconds, endTime: endTime, row: row)
            }.min { abs($0.identity.measurement.offsetHz - centre) < abs($1.identity.measurement.offsetHz - centre) }
            answers.append(unmeasured(c, seconds: seconds, captureCenterHz: captureCenterHz, from: from?.identity,
                                      endTime: endTime))
            spans.append((c.lowerHz, c.upperHz))
        }
        guard answers.count >= 2 else { return point }
        var out = point
        if onComb, let nearest = measured.min(by: {
            (distance($0.candidate, from: pointHz), -level($0.candidate)) < (distance($1.candidate, from: pointHz), -level($1.candidate))
        }) {
            out = nearest.identity
        }
        out.signals = answers.sorted { $0.measurement.offsetHz < $1.measurement.offsetHz }
        if mode != nil { out.groupSpanHz = spans.map(\.0).min()!...spans.map(\.1).max()! }
        out.captureCenterHz = captureCenterHz
        return out
    }

    /// A candidate's strength: its strongest line over the noise.
    static func level(_ c: SignalCandidate) -> Double { c.traces.map(\.snrDb).max() ?? -.infinity }

    /// Whether `c`'s middle lies inside what `identity` answered for: part of that signal.
    static func holds(_ identity: SignalIdentity, _ c: SignalCandidate) -> Bool {
        let m = identity.measurement
        return m.occupiedBandwidthHz > 0 && abs((c.lowerHz + c.upperHz) / 2 - m.offsetHz) <= m.occupiedBandwidthHz / 2
    }

    /// One of several signals under the point, measured and named as the point is on the first pass: an FSK by its tones
    /// when they show a speed, otherwise its extent (`located`) measured, a narrow trace's tones read as the point's are.
    static func memberAnswer(_ c: SignalCandidate, first: [Float], sampleRate: Double, captureCenterHz: Double,
                             hood: Neighbourhood, view: NeighbourhoodView, signals: [SignalCandidate], seconds: Double,
                             endTime: Date?, readsTones: Bool) -> SignalIdentity {
        let centre = (c.lowerHz + c.upperHz) / 2
        if c.tones != nil, let read = DirectFSK.Tones(c, signals: signals, noiseDb: view.noiseDb)?
            .reading(SignalMeasurer.interleaved(hood.samples), rate: hood.rate, zeroHz: hood.centreHz),
           read.reading.baud != nil {
            return identify(read.measurement(seconds: seconds), rfHz: captureCenterHz + read.offsetHz)
        }
        // A line of the view's own is found at its middle; a station `SignalGrouper` found, or an FSK, is given.
        let line = c.tones == nil && c.traces.count == 1 && view.traces.contains(c.traces[0]) ? c.traces[0] : nil
        guard let found = located(view, signal: line == nil ? c : nil, signals: signals, map: hood.map, pointHz: centre,
                                  radiusHz: (c.upperHz - c.lowerHz) / 2) else {
            return unmeasured(c, seconds: seconds, captureCenterHz: captureCenterHz, from: nil, endTime: endTime)
        }
        let narrow = line.flatMap { mayBeNarrowMFSK($0) ? ($0, hood.map) : nil }
        let pass = firstMeasurement(first, sampleRate: sampleRate, captureCenterHz: captureCenterHz,
                                    seed: (found.offsetHz, found.widthHz), ceiling: found.ceiling, narrow: narrow,
                                    pointHz: centre, seconds: seconds, endTime: endTime, readsTones: readsTones,
                                    tonesTakeTurns: false)
        return pass.cancelled ? cancelled(pass.m) : pass.identity
    }

    /// A signal under the point that wasn't measured: unknown, with `from`'s slot-mode name as its likely one (its only
    /// alternative, at `inheritedConfidence`, and `nameInherited`) when it fits `from`'s slot and width. With a true time
    /// (`endTime`, when the read's last sample was on the air), a single line's on-times are its `onAir`.
    static func unmeasured(_ c: SignalCandidate, seconds: Double, captureCenterHz: Double,
                           from: SignalIdentity?, endTime: Date? = nil) -> SignalIdentity {
        let width = c.upperHz - c.lowerHz
        var m = SignalMeasurement(offsetHz: (c.lowerHz + c.upperHz) / 2, occupiedBandwidthHz: width,
                                  bandwidth6dBHz: width, snrDb: level(c), family: .unknown, seconds: seconds,
                                  notes: ["Not measured: one of several signals under the point"])
        if c.tones == nil, c.traces.count == 1 {
            m.onAir = SlotEvidence.onAir(onTimes: c.traces[0].onTimes, readEnd: endTime, readSeconds: seconds)
        }
        guard let from, let name = from.best else { return SignalIdentity(measurement: m) }
        let at = String(format: "%.0f Hz", captureCenterHz + from.measurement.offsetHz)
        m.notes = ["Not measured: its transmissions and width are those of the \(name.name) at \(at)"]
        let likely = ModeMatch(name: name.name, confidence: min(name.confidence, inheritedConfidence), evidence: [
            "the same slot and width as the \(name.name) at \(at), which was measured: likely \(name.name), not measured",
        ])
        return SignalIdentity(measurement: m, alternatives: [likely], nameInherited: true)
    }

    /// Whether `c` fits the same slot as `measured` and is as wide, on positive evidence: a line each, within
    /// `inheritWidthShare` of its width on the map, starting and stopping where it does within the clock's tolerance
    /// (`SlotEvidence.clockToleranceSeconds`: stations' clocks differ that much), with no starts or stops of its own (a
    /// key's), and at least one start or stop for them to agree on: two lines on for the whole read (inside a slot, or a
    /// PSK beside an FT8) share no timing at all. With a true time (`endTime`), its own on-times fit `row`'s slots too
    /// (`inheritSlotFit`).
    static func fitsSameSlot(_ c: SignalCandidate, as measured: SignalCandidate, readSeconds: Double, endTime: Date?,
                             row: ModeRow) -> Bool {
        guard c.tones == nil, measured.tones == nil, let line = c.traces.first, let model = measured.traces.first else {
            return false
        }
        let width = line.upperHz - line.lowerHz, modelWidth = model.upperHz - model.lowerHz
        guard abs(width - modelWidth) <= inheritWidthShare * modelWidth else { return false }
        func edges(_ onTimes: [ClosedRange<Double>]) -> (starts: [Double], ends: [Double]) {
            let runs = onTimes.filter { $0.upperBound - $0.lowerBound >= SlotEvidence.blipSeconds }
            return (runs.map(\.lowerBound).filter { $0 > SlotEvidence.readEdgeSeconds },
                    runs.map(\.upperBound).filter { $0 < readSeconds - SlotEvidence.readEdgeSeconds })
        }
        func agree(_ a: [Double], _ b: [Double]) -> Bool {
            a.count == b.count && zip(a.sorted(), b.sorted()).allSatisfy { abs($0 - $1) <= SlotEvidence.clockToleranceSeconds }
        }
        let mine = edges(line.onTimes), theirs = edges(model.onTimes)
        guard agree(mine.starts, theirs.starts), agree(mine.ends, theirs.ends),
              !mine.starts.isEmpty || !mine.ends.isEmpty else { return false }
        if endTime != nil {
            guard let fit = SlotEvidence.fit(onTimes: line.onTimes, readEnd: endTime, readSeconds: readSeconds,
                                             period: row.slotPeriodSeconds, length: row.slotSeconds),
                  fit.fit >= inheritSlotFit else { return false }
        }
        return true
    }
}
