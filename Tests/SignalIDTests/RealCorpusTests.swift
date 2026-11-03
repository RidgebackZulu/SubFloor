import Foundation
import Testing
@testable import SignalID

/// The score on real signals: the corpus (`RealCorpus`) is sound, and what Signal ID makes of it.
///
/// `SUBFLOOR_SIGNALID_MAKE_CLIPS=1` cuts the clips and spectra from the owner's recordings,
/// `SUBFLOOR_SIGNALID_BASELINE=1` prints the score over every point, and `SUBFLOOR_SIGNALID_REAL=1` runs the points
/// through the 1 MS/s read on the recordings themselves and asserts the held-out targets there. `Fixtures/Real/truth_analysis.py` repeats the hand truth.
@Suite(.serialized) struct RealCorpusTests {
    static let environment = ProcessInfo.processInfo.environment

    /// Every point names a real clip and a time inside it, every clip fits the repo, every recording has both parts.
    @Test func manifestIsSound() throws {
        let manifest = try RealCorpus.manifest()
        #expect(!manifest.recordings.isEmpty)
        var seconds: [String: Double] = [:]
        for recording in manifest.recordings {
            for part in CorpusPart.allCases {
                #expect(recording.clips.contains { $0.part == part }, "\(recording.tag) has no \(part) clip")
            }
            #expect(recording.startUTC != nil, "\(recording.file) gives no time")
            for clip in recording.clips {
                seconds[clip.name] = clip.seconds
                #expect(clip.seconds <= 16)
                let size = try RealCorpus.resource(clip.file).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max
                #expect(size < 4_200_000, "\(clip.name) is \(size) bytes")
            }
        }
        for point in manifest.points {
            let length = try #require(seconds[point.clip], "\(point.clip) is no clip")
            #expect((1...length).contains(point.endSeconds), "\(point.clip) at \(point.endSeconds) s")
            #expect(!point.how.isEmpty)
        }
        for name in seconds.keys {
            #expect(manifest.points.filter { $0.clip == name && $0.truth == "none" }.count >= 5, "\(name)'s empty points")
        }
        for clip in try RealCorpus.clips() {
            #expect(clip.rate == Self.clipRate)
            #expect(abs(Double(clip.iq.count / 2) / clip.rate - (seconds[clip.name] ?? 0)) < 0.001, "\(clip.name)'s length")
            #expect(clip.captureSpectrumDb.count == Self.spectrumBins)
            #expect(clip.spectrumDb.count == 2048)
        }
        // The file name gives the first sample's time; a clip's start is that plus its offset.
        let held = try #require(try RealCorpus.clips().first { $0.name == "14MHz-heldOut-1" })
        #expect(held.startUTC == ISO8601DateFormatter().date(from: "2026-11-01T18:19:00Z"))
    }

    /// The corpus loads and scores: one counted point of each truth, through the hover's path. (`heldOutTargets` does
    /// the same on the other part by default.)
    @Test(.enabled(if: Sweep.full)) func scoresOnePointPerTruth() throws {
        var picks: [String: CorpusPoint] = [:]
        for point in try RealCorpus.points(.tuning) where RealCorpus.counts(point) && picks[point.truth] == nil {
            picks[point.truth] = point
        }
        #expect(Set(picks.keys) == ["FT8", "FT4", "2-FSK", "none", "comb", "not FSK"])
        let score = try RealCorpus.score(points: Array(picks.values)) { RealCorpus.hover($0, $1) }
        for truth in picks.keys { #expect(score[truth]?.total == 1, "\(truth) wasn't scored") }
    }

    /// The before picture: what the identifier makes of the corpus, per truth and per part. Asserts nothing, and takes
    /// about 5 CPU-minutes in a debug build.
    @Test(.enabled(if: environment["SUBFLOOR_SIGNALID_BASELINE"] == "1")) func baselineScore() throws {
        try Self.printScore("baseline", parts: CorpusPart.allCases) { RealCorpus.hover($0, $1) }
    }

    /// The targets on the held-out part, which is only ever scored, through the hover's path on clips (no decode), and no
    /// wrong name on any truth: FT8 never named FT4, nor the reverse. By default every empty point and one transmitting
    /// window each of FT8, FT4, the FSK and the comb (their windows take the longer read; a second of each, by Task 10's
    /// load pass, only with the matrix);
    /// `SUBFLOOR_SIGNALID_MATRIX=1` asserts over all of them, and prints
    /// how many comb windows were labelled comb (not `No signal`). FT8's and FT4's shares
    /// (`gatedTargets`) are asserted only then, or with `SUBFLOOR_SIGNALID_REAL=1`: two windows say little of a share, and
    /// the default run holds what matters most there, no wrong name. `fullRecordings` asserts the same targets at the
    /// capture's own rate. The rows grow as the tasks that meet them land. The FT8 points again at the owner's zoom
    /// (`RealCorpus.groupTruth`), where the point takes in several stations: right when the label names FT8, and no
    /// signal under the point named anything else (one of them by default, its share, like FT8's own, asserted only
    /// with the matrix or the recordings).
    @Test func heldOutTargets() throws {
        let held = try RealCorpus.points(.heldOut)
        let groups = held.filter { $0.truth == "FT8" }.map(RealCorpus.asGroup)
        // A share of 95% means nothing over 2 points, and an empty point costs little: all of them, always.
        let points = Sweep.full ? held + groups : held.filter { $0.truth == "none" }
            + Self.subset(held.filter { ["FT8", "FT4", "2-FSK", "comb"].contains($0.truth) && RealCorpus.counts($0) },
                          perTruth: 1)
            + Self.subset(groups.filter(RealCorpus.counts), perTruth: 1)
        var wrong: [String] = []
        var combLabels = 0
        let score = try RealCorpus.score(points: points) { clip, point in
            let id = RealCorpus.hover(clip, point)
            Self.expectHeldOut(id, point, "clip path", centerHz: clip.centerHz)
            if RealCorpus.isWrongName(id, point) { wrong.append("\(point.truth) at \(point.atHz) Hz: \(id.label)") }
            if point.truth == "comb", id.comb != nil { combLabels += 1 }
            return id
        }
        if Sweep.full {
            for truth in score.keys.sorted() { print("heldOutTargets \(truth): \(score[truth]!.right)/\(score[truth]!.total) right") }
            print("heldOutTargets comb windows labelled comb: \(combLabels)/\(score["comb"]?.total ?? 0)")
            for line in wrong { print("heldOutTargets wrong: \(line)") }
        }
        Self.expectTargets(score, "clip path", all: Sweep.full || Self.environment["SUBFLOOR_SIGNALID_REAL"] == "1")
        #expect(wrong.isEmpty, "clip path: wrong names at 0.7 or more: \(wrong)")
    }

    /// The share right each truth must reach. A comb line is labelled comb or `No signal` in every window (the spec gives no
    /// share: never named, and never another answer).
    static let targets = ["none": 0.95, "2-FSK": 0.8, "FT8": 0.8, "FT4": 0.8, "comb": 1.0, RealCorpus.groupTruth: 0.8]
    /// The targets a default run doesn't assert (see `heldOutTargets`).
    static let gatedTargets: Set<String> = ["FT8", "FT4", RealCorpus.groupTruth]
    /// The FSK's neighbour, which stays its own signal.
    static let fskNeighbourHz = 11_685_864.0
    static let fskNeighbourReachHz = 500.0
    /// No answer on an empty point may be wider than this.
    static let widestEmptyAnswerHz = 100_000.0

    /// At most `perTruth` points of each truth, spread over its points in manifest order.
    static func subset(_ points: [CorpusPoint], perTruth: Int) -> [CorpusPoint] {
        Dictionary(grouping: points, by: \.truth).values.flatMap { group -> [CorpusPoint] in
            let step = max(1, group.count / perTruth)
            return stride(from: 0, to: group.count, by: step).prefix(perTruth).map { group[$0] }
        }
    }

    static func expectHeldOut(_ id: SignalIdentity, _ point: CorpusPoint, _ path: String, centerHz: Double) {
        // The two slot modes are never taken for each other, at any confidence a name is given at, nor any signal under
        // the point.
        if let other = ["FT8": "FT4", "FT4": "FT8", RealCorpus.groupTruth: "FT4"][point.truth] {
            #expect(([id] + id.signals).allSatisfy { $0.best?.name != other },
                    "\(path): \(point.truth) at \(point.atHz) Hz, \(point.endSeconds) s: \(id.label)")
        }
        // No signal of several under the point is given a width it can't have.
        for signal in id.signals {
            #expect(signal.measurement.occupiedBandwidthHz <= widestEmptyAnswerHz,
                    "\(path): \(point.truth) at \(point.atHz) Hz: \(signal.label) in \(id.label)")
        }
        if point.truth == "none" {
            #expect(id.measurement.occupiedBandwidthHz <= widestEmptyAnswerHz,
                    "\(path): empty point \(point.atHz) Hz: \(id.label)")
        }
        if point.truth == "2-FSK" {
            // The answer's extent stops short of the neighbour.
            let m = id.measurement
            let lower = centerHz + m.offsetHz - m.occupiedBandwidthHz / 2
            #expect(lower > fskNeighbourHz + fskNeighbourReachHz, "\(path): FSK at \(point.atHz) Hz, \(point.endSeconds) s: \(id.label)")
        }
    }

    static func expectTargets(_ score: [String: (right: Int, total: Int)], _ path: String, all: Bool = true,
                              only: Set<String>? = nil) {
        for (truth, target) in targets where (all || !gatedTargets.contains(truth)) && (only?.contains(truth) ?? true) {
            guard let s = score[truth] else {
                Issue.record("\(path): nothing scored for \(truth)")
                continue
            }
            #expect(Double(s.right) >= target * Double(s.total), "\(path): \(truth) \(s.right)/\(s.total)")
        }
    }

    /// The same points through the capture's own read, on the recordings themselves: the owner's 1 MS/s, which the
    /// clips' 62.5 kS/s must not hide. Prints every part's score and asserts the held-out targets. Every empty point;
    /// `SUBFLOOR_SIGNALID_REAL_POINTS=n` keeps the first n points of each other truth, per part (the whole run is about
    /// 30 minutes in a debug build), and `SUBFLOOR_SIGNALID_REAL_TRUTHS=FT8,FT4` only those truths (then only their
    /// targets, and every wrong name among them). The FT8 points at the owner's zoom (`RealCorpus.groupTruth`) are scored
    /// only when named there.
    @Test(.enabled(if: environment["SUBFLOOR_SIGNALID_REAL"] == "1")) func fullRecordings() throws {
        let manifest = try RealCorpus.manifest()
        let allowed = Self.environment["SUBFLOOR_SIGNALID_REAL_POINTS"].flatMap(Int.init)
        let truths = Self.environment["SUBFLOOR_SIGNALID_REAL_TRUTHS"].map { Set($0.split(separator: ",").map(String.init)) }
        var kept: [String: Int] = [:]
        let identify = Self.recordingHover(manifest)
        // The FT8 points at the owner's zoom only when asked for by name: they would double FT8's share of the half hour.
        func trimmed(_ part: CorpusPart) throws -> [CorpusPoint] {
            let points = try RealCorpus.points(part)
            let groups = truths?.contains(RealCorpus.groupTruth) == true
                ? points.filter { $0.truth == "FT8" }.map(RealCorpus.asGroup) : []
            return (points + groups).filter { point in
                if let truths, !truths.contains(point.truth) { return false }
                guard let allowed, point.truth != "none" else { return true }
                let key = "\(part) \(point.truth)"
                kept[key, default: 0] += 1
                return kept[key]! <= allowed
            }
        }
        let clips = try RealCorpus.clips()
        for part in CorpusPart.allCases {
            let points = try trimmed(part)
            var answers: [String: [String: Int]] = [:]
            var wrong: [String] = []
            func note(_ id: SignalIdentity, _ point: CorpusPoint) {
                if RealCorpus.isWrongName(id, point) {
                    wrong.append("\(point.truth) in \(point.clip) at \(point.atHz) Hz, \(point.endSeconds) s: \(id.label)")
                }
            }
            let score = try RealCorpus.score(points: points) { clip, point in
                let id = identify(clip, point)
                answers[point.truth, default: [:]][Self.shortLabel(id), default: 0] += 1
                note(id, point)
                if part == .heldOut {
                    let center = manifest.recordings.first { $0.clips.contains { $0.name == clip.name } }?.captureCenterHz ?? 0
                    Self.expectHeldOut(id, point, "1 MS/s", centerHz: center)
                }
                return id
            }
            // The windows that don't count towards a score can still hold a wrong name.
            for point in points where !RealCorpus.counts(point) {
                let clip = try #require(clips.first { $0.name == point.clip })
                note(identify(clip, point), point)
            }
            for truth in score.keys.sorted() {
                let s = score[truth]!
                print(String(format: "fullRecordings %@ %@: %d/%d right (%.0f%%)", part.rawValue, truth, s.right, s.total,
                             100 * Double(s.right) / Double(max(1, s.total))))
            }
            for truth in answers.keys.sorted() {
                let top = answers[truth]!.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(6)
                    .map { "\($0.key) ×\($0.value)" }
                print("fullRecordings \(part.rawValue) \(truth) answers: \(top.joined(separator: "; "))")
            }
            print("fullRecordings \(part.rawValue) wrong names at 0.7 or more: \(wrong.count)")
            for line in wrong { print("fullRecordings wrong: \(line)") }
            #expect(wrong.isEmpty, "1 MS/s \(part): wrong names at 0.7 or more: \(wrong)")
            if part == .heldOut {
                Self.expectTargets(score.filter { truths?.contains($0.key) ?? true }, "1 MS/s",
                                   only: truths ?? Set(Self.targets.keys).subtracting([RealCorpus.groupTruth]))
            }
        }
    }

    /// The hover's path (`RealCorpus.hover`) at a point of a clip, on the recording the clip was cut from: its 1 MS/s read
    /// ending at the point's time, with the capture's spectrum.
    static func recordingHover(_ manifest: RealCorpus.Manifest) -> (CorpusClip, CorpusPoint) -> SignalIdentity {
        { clip, point in
            guard let recording = manifest.recordings.first(where: { $0.clips.contains { $0.name == clip.name } }),
                  let entry = recording.clips.first(where: { $0.name == clip.name }) else {
                return SignalIdentity(measurement: SignalMeasurement(), note: "no recording")
            }
            let end = entry.startSeconds + point.endSeconds
            return RealCorpus.hover(rate: recording.captureRate, centerHz: recording.captureCenterHz, atHz: point.atHz,
                                    spectrumDb: clip.captureSpectrumDb,
                                    endTime: recording.startUTC?.addingTimeInterval(end),
                                    capture: (clip.captureSpectrumDb, recording.captureRate, recording.captureCenterHz),
                                    radiusHz: point.truth == RealCorpus.groupTruth ? RealCorpus.groupRadiusHz : 60) { seconds in
                (try? RealCorpus.readRecording(recording.file, seconds: max(0, end - seconds)..<end)) ?? []
            }
        }
    }

    /// How long the hover's first answer takes on the recordings (`SUBFLOOR_SIGNALID_TIMING=1`, meant for a release
    /// build): the first pass alone (the newest 3 s at 1 MS/s, the app's spectrum, no longer read) on 6 held-out points of
    /// each truth, and the quick group answer at the owner's zoom (345 Hz) on 6 of FT8's, and on `GroupAnswerTests`' nine
    /// stations. Each the best of three after a first call (also printed). Prints each kind's median and slowest against
    /// the spec's 150 ms; asserts nothing.
    @Test(.enabled(if: environment["SUBFLOOR_SIGNALID_TIMING"] == "1")) func releaseTimings() throws {
        let manifest = try RealCorpus.manifest()
        let held = try RealCorpus.points(.heldOut).filter(RealCorpus.counts)
        let clips = try RealCorpus.clips()
        let clock = ContinuousClock()
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        func report(_ kind: String, _ times: [(first: Double, best: Double)]) {
            let best = times.map(\.best).sorted(), first = times.map(\.first).sorted()
            guard !best.isEmpty else { return }
            print(String(format: "releaseTimings %@: %d points, best of 3 median %.0f ms, slowest %.0f ms; first call median %.0f ms, slowest %.0f ms",
                         kind, best.count, best[best.count / 2], best.last!, first[first.count / 2], first.last!))
        }
        func timed(_ run: () -> SignalIdentity) -> (first: Double, best: Double) {
            let first = ms(clock.measure { _ = run() })
            return (first, (0..<3).map { _ in ms(clock.measure { _ = run() }) }.min()!)
        }
        for truth in ["FT8", "FT4", "2-FSK", "comb", "none", "not FSK", RealCorpus.groupTruth] {
            let points = Self.subset(truth == RealCorpus.groupTruth ? held.filter { $0.truth == "FT8" }.map(RealCorpus.asGroup)
                                                                    : held.filter { $0.truth == truth }, perTruth: 6)
            var times: [(first: Double, best: Double)] = []
            for point in points {
                let clip = try #require(clips.first { $0.name == point.clip })
                let recording = try #require(manifest.recordings.first { $0.clips.contains { $0.name == clip.name } })
                let entry = try #require(recording.clips.first { $0.name == clip.name })
                let end = entry.startSeconds + point.endSeconds
                let iq = try RealCorpus.readRecording(recording.file, seconds: (end - SignalIdentifier.firstSeconds)..<end)
                let radius = truth == RealCorpus.groupTruth ? RealCorpus.groupRadiusHz : SignalIdentifier.defaultRadiusHz
                times.append(timed {
                    SignalIdentifier.identify(iq: iq, sampleRate: recording.captureRate, captureCenterHz: recording.captureCenterHz,
                                              atHz: point.atHz, bandwidthHz: nil, spectrumDb: clip.captureSpectrumDb, longer: nil,
                                              pointRadiusHz: radius, endTime: recording.startUTC?.addingTimeInterval(end),
                                              captureSpectrumDb: clip.captureSpectrumDb, captureRate: recording.captureRate,
                                              captureSpectrumCenterHz: recording.captureCenterHz)
                })
            }
            report(truth == RealCorpus.groupTruth ? "quick group answer, 345 Hz, 1 MS/s" : "first answer, \(truth), 1 MS/s", times)
        }
        report("quick group answer, 345 Hz, nine synthetic FT8 at 6 kS/s", [timed {
            SignalIdentifier.identify(iq: GroupAnswerTests.nine, sampleRate: GroupAnswerTests.rate,
                                      captureCenterHz: GroupAnswerTests.centreHz, atHz: GroupAnswerTests.centreHz, bandwidthHz: nil,
                                      spectrumDb: nil, longer: nil, pointRadiusHz: RealCorpus.groupRadiusHz)
        }])
    }

    /// A strong carrier added to the real 1 MS/s read, 120 kHz from an empty point: still `No signal` there.
    @Test(.enabled(if: environment["SUBFLOOR_SIGNALID_REAL"] == "1")) func aCarrierElsewhereInARealRead() throws {
        let manifest = try RealCorpus.manifest()
        let recording = try #require(manifest.recordings.first { $0.tag == "14MHz" })
        let clip = try #require(try RealCorpus.clips().first { $0.part == .tuning && $0.name.hasPrefix("14MHz") })
        let start = try #require(recording.span(.tuning)).lowerBound
        let read = try RealCorpus.readRecording(recording.file, seconds: (start + 6)..<(start + 9))
        var total = 0.0
        for sample in read { total += Double(sample * sample) }
        total /= Double(read.count / 2)
        let pointHz = 14_072_200 - recording.captureCenterHz
        for times in [0.0, 1, 3, 10, 30, 100] {
            var iq = read
            TraceFinderTests.addCarrier(to: &iq, offsetHz: pointHz + 120_000, rate: recording.captureRate,
                                        amplitude: Float((times * total).squareRoot()))
            for spectrum in [clip.captureSpectrumDb, nil] {
                let id = SignalIdentifier.identify(iq: iq, sampleRate: recording.captureRate,
                                                   captureCenterHz: recording.captureCenterHz, atHz: 14_072_200,
                                                   bandwidthHz: nil, spectrumDb: spectrum, longer: nil)
                #expect(id.note == SignalIdentifier.noSignalNote && id.measurement.occupiedBandwidthHz == 0,
                        "\(times) × the read's power: \(id.label)")
            }
        }
    }

    /// Prints each part's score per truth, what each truth's windows were called, and the wrong names: over every
    /// point of those parts, the windows that don't count towards the score included.
    static func printScore(_ tag: String, parts: [CorpusPart],
                           identify: (CorpusClip, CorpusPoint) -> SignalIdentity) throws {
        var answers: [String: [String: Int]] = [:]
        var wrong: [String] = []
        var seen = 0
        func note(_ id: SignalIdentity, _ point: CorpusPoint) {
            seen += 1
            if RealCorpus.isWrongName(id, point) {
                wrong.append("\(point.truth) in \(point.clip) at \(point.atHz) Hz, \(point.endSeconds) s: \(id.label)")
            }
        }
        let clips = try RealCorpus.clips()
        for part in parts {
            let score = try RealCorpus.score(part) { clip, point in
                let id = identify(clip, point)
                note(id, point)
                answers[point.truth, default: [:]][shortLabel(id), default: 0] += 1
                return id
            }
            for truth in score.keys.sorted() {
                let s = score[truth]!
                print(String(format: "%@ %@ %@: %d/%d right (%.0f%%)", tag, part.rawValue, truth, s.right, s.total,
                             100 * Double(s.right) / Double(max(1, s.total))))
            }
            for point in try RealCorpus.points(part) where !RealCorpus.counts(point) {
                let clip = try #require(clips.first { $0.name == point.clip })
                note(identify(clip, point), point)
            }
        }
        for truth in answers.keys.sorted() {
            let top = answers[truth]!.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(6).map { "\($0.key) ×\($0.value)" }
            print("\(tag) \(truth) answers: \(top.joined(separator: "; "))")
        }
        print("\(tag) wrong names at 0.7 or more: \(wrong.count) of \(seen)")
        for line in wrong.prefix(20) { print("\(tag) wrong: \(line)") }
    }

    /// A label with its width rounded, so answers tally.
    static func shortLabel(_ id: SignalIdentity) -> String {
        if id.comb != nil { return "Interference comb" }
        if let best = id.best { return best.name }
        let m = id.measurement
        if m.occupiedBandwidthHz == 0 { return id.note ?? "none" }
        return "\(SignalIdentity.familyName(m)) · \(SignalIdentity.hz((m.occupiedBandwidthHz / 100).rounded() * 100))"
    }

    // MARK: The scorecard

    /// One row of the scorecard: what one path made of one part's windows of one truth. `windows` and `right` are over the
    /// windows that count (`RealCorpus.counts`), `wrong` over all of them, `others` what the counted windows not right were
    /// called (`shortLabel`).
    struct ScoreRow: Codable, Equatable {
        var path = ""
        var part = ""
        var truth = ""
        var windows = 0
        var right = 0
        var wrong = 0
        var others: [String: Int] = [:]
    }

    /// Every one of `points` through `identify`, tallied per truth into rows of `path` and `part`.
    static func tally(_ points: [CorpusPoint], path: String, part: CorpusPart,
                      identify: (CorpusClip, CorpusPoint) -> SignalIdentity) throws -> [ScoreRow] {
        let clips = try RealCorpus.clips()
        var rows: [String: ScoreRow] = [:]
        for point in points {
            guard let clip = clips.first(where: { $0.name == point.clip }) else { throw RealCorpus.CorpusError.missing(point.clip) }
            let id = identify(clip, point)
            var row = rows[point.truth] ?? ScoreRow(path: path, part: part.rawValue, truth: point.truth)
            if RealCorpus.counts(point) {
                row.windows += 1
                if RealCorpus.isRight(id, point) { row.right += 1 } else { row.others[shortLabel(id), default: 0] += 1 }
            }
            if RealCorpus.isWrongName(id, point) { row.wrong += 1 }
            rows[point.truth] = row
        }
        return rows.values.sorted { $0.truth < $1.truth }
    }

    /// The order of the scorecard's tables, and what each truth takes to be right (`RealCorpus.isRight`).
    static let scorecardTruths: [(truth: String, title: String, right: String)] = [
        ("FT8", "FT8", "named FT8, in a window while it transmits"),
        ("FT4", "FT4", "named FT4, in a window while it transmits"),
        (RealCorpus.groupTruth, "FT8 at the owner's zoom (345 Hz radius)", "the label names FT8, alone or among others"),
        ("2-FSK", "The 11.688 MHz 2-FSK", "2-FSK, shift within 3% and speed within 1% of 850 Hz and 75 Bd, no mode's name"),
        ("not FSK", "Its neighbour and the space beside it", "not called FSK"),
        ("comb", "Interference comb lines", "labelled comb, or No signal; never a mode"),
        ("none", "Empty points", "No signal (and never wider than 100 kHz)"),
    ]

    /// The scorecard for the pull request: one Markdown table per truth, a row per path and part (`rows`, the card's among
    /// them), with the share right against the target where one is asserted (the held-out part), the wrong names at 0.7
    /// or more over every window, and what else the windows were called.
    static func printScorecard(_ rows: [ScoreRow], notes: [String] = []) -> String {
        var out = ["# Signal ID on real signals: the scorecard", ""]
        out += notes.map { "- \($0)" }
        let wrong = rows.map(\.wrong).reduce(0, +)
        out += ["- Wrong names at 0.7 or more, over every window of every row: \(wrong).", ""]
        for (truth, title, right) in scorecardTruths {
            let mine = rows.filter { $0.truth == truth }
            guard !mine.isEmpty else { continue }
            let target = targets[truth].map { $0 >= 1 ? "every window" : String(format: "≥ %.0f%%", 100 * $0) }
            out += ["## \(title)", "",
                    "Right: \(right). Target on the held-out part: \(target ?? "none").", "",
                    "| Path | Part | Windows | Right | Share | Target | Wrong names | Other answers |",
                    "| --- | --- | ---: | ---: | ---: | --- | ---: | --- |"]
            for row in mine {
                let share = row.windows == 0 ? "—" : String(format: "%.0f%%", 100 * Double(row.right) / Double(row.windows))
                var against = "—"
                if row.part == CorpusPart.heldOut.rawValue, let t = targets[truth], row.windows > 0 {
                    against = (Double(row.right) >= t * Double(row.windows) ? "met" : "**missed**") + " (\(target ?? ""))"
                }
                let others = row.others.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(5)
                    .map { "\($0.key) ×\($0.value)" }.joined(separator: "; ")
                out.append("| \(row.path) | \(row.part == "heldOut" ? "held-out" : row.part) | \(row.windows) | \(row.right) | "
                           + "\(share) | \(against) | \(row.wrong) | \(others.isEmpty ? "—" : others) |")
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    /// The scorecard over every point of both parts, through the hover's path on the clips and on the recordings at their
    /// 1 MS/s, FT8's points at the owner's zoom too, with the card's rows when `SUBFLOOR_SIGNALID_CARD_ROWS=<path>` holds
    /// them (`RealCorpusTruthTests.cardWithDecode` writes them; Signal ID's tests can't run the trial decode). Printed, and
    /// written to `SUBFLOOR_SIGNALID_SCORECARD_OUT=<path>`. It needs the recordings, and asserts nothing: `heldOutTargets`
    /// and `fullRecordings` hold the targets. `SUBFLOOR_SIGNALID_SCORECARD=1`.
    @Test(.enabled(if: environment["SUBFLOOR_SIGNALID_SCORECARD"] == "1")) func scorecard() throws {
        let manifest = try RealCorpus.manifest()
        var rows: [ScoreRow] = []
        let paths: [(String, (CorpusClip, CorpusPoint) -> SignalIdentity)] = [
            ("Hover, clips (62.5 kS/s)", { RealCorpus.hover($0, $1) }),
            ("Hover, recordings (1 MS/s)", Self.recordingHover(manifest)),
        ]
        for (path, identify) in paths {
            for part in CorpusPart.allCases {
                let points = try RealCorpus.points(part)
                let groups = points.filter { $0.truth == "FT8" }.map(RealCorpus.asGroup)
                rows += try Self.tally(points + groups, path: path, part: part, identify: identify)
            }
        }
        if let file = Self.environment["SUBFLOOR_SIGNALID_CARD_ROWS"] {
            rows += try JSONDecoder().decode([ScoreRow].self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        }
        let order = ["Hover, clips (62.5 kS/s)", "Hover, recordings (1 MS/s)",
                     "Card's first answer (service, before its decode), 1 MS/s", "Card with its trial decode, 1 MS/s"]
        rows.sort { a, b in
            let pa = order.firstIndex(of: a.path) ?? order.count, pb = order.firstIndex(of: b.path) ?? order.count
            return (a.part == "heldOut" ? 1 : 0, pa, a.path) < (b.part == "heldOut" ? 1 : 0, pb, b.path)
        }
        let card = Self.printScorecard(rows, notes: [
            "Two recordings of the owner's, at 1 MS/s: 14.024 MHz (20 m FT8 and FT4, and an interference comb) and "
                + "11.733 MHz (one 2-FSK emitter, 75 Bd and 850 Hz, and its neighbour). The FSK's two parts are one "
                + "emitter split by time: FSK has been tested on one emitter, and new recordings are the true test.",
            "Thresholds were tuned on each recording's tuning part only; the held-out part is only scored. A window is one "
                + "identification at a point and time (points every 3 s along each trace); a signal's windows count while it "
                + "transmits.",
            "Modes tested on real signals: FT8, FT4 and one 2-FSK. Not tested on real signals (no recording yet): ham "
                + "RTTY at 45.45 Bd, CW, SSB on a busy band, PSK31 and the rest of the mode table.",
            "The hover never decodes. The card's rows are FT8's points through the service and its trial decode, the IQ "
                + "ring as the app's default pre-roll plans it.",
        ])
        print(card)
        if let out = Self.environment["SUBFLOOR_SIGNALID_SCORECARD_OUT"] {
            try card.write(toFile: out, atomically: true, encoding: .utf8)
        }
    }

    /// Cuts the clips and the capture spectra from the owner's recordings into the source tree. The points in the
    /// manifest are kept; only its `recordings` drive this.
    @Test(.enabled(if: environment["SUBFLOOR_SIGNALID_MAKE_CLIPS"] == "1")) func makeClips() throws {
        let manifest = try RealCorpus.manifest()
        for recording in manifest.recordings {
            let offsetHz = recording.clipCenterHz - recording.captureCenterHz
            let bandwidthHz = Self.clipRate / 4
            #expect(Channel.outputRate(sampleRate: recording.captureRate, bandwidthHz: bandwidthHz) == Self.clipRate)
            for clip in recording.clips {
                // A margin read and dropped, so the filters' edges don't land on the clip's ends.
                let margin = Self.marginSamples / Self.clipRate
                let before = min(margin, clip.startSeconds)
                let iq = try RealCorpus.readRecording(recording.file, seconds: (clip.startSeconds - before)
                                                      ..< (clip.startSeconds + clip.seconds + margin))
                let cut = Channel.extract(iq, sampleRate: recording.captureRate, offsetHz: offsetHz,
                                          bandwidthHz: bandwidthHz, sharp: false)
                let skip = Int((before * cut.rate).rounded())
                let frames = Int((clip.seconds * cut.rate).rounded())
                let samples = cut.samples[skip..<min(cut.samples.count, skip + frames)]
                let floats = samples.withUnsafeBufferPointer { z in
                    z.withMemoryRebound(to: Float.self) { Array($0) }
                }
                try RealCorpus.writeWAV(floats, rate: cut.rate, to: RealCorpus.sourceFolder.appendingPathComponent(clip.file))
                print("makeClips: \(clip.file): \(samples.count) frames at \(cut.rate) S/s")
            }
            for part in CorpusPart.allCases {
                let span = try #require(recording.span(part))
                let iq = try RealCorpus.readRecording(recording.file, seconds: span)
                let db = PowerSpectrum.average(iq, size: Self.spectrumBins, maxFrames: .max, hop: Self.spectrumBins / 2)
                let data = db.withUnsafeBytes { Data($0) }
                try data.write(to: RealCorpus.sourceFolder.appendingPathComponent(recording.spectrumFile(part)))
                print("makeClips: \(recording.spectrumFile(part)): \(db.count) bins over \(span) s")
            }
        }
    }

    static let clipRate = 62_500.0
    static let marginSamples = 6250.0
    static let spectrumBins = 32_768
}
