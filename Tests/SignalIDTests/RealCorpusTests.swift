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

    /// The corpus loads and scores: one counted point of each truth, through the hover's path.
    @Test func scoresOnePointPerTruth() throws {
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

    /// The targets on the held-out part, which is only ever scored, through the hover's path on clips. By default at
    /// most 2 points per truth; `SUBFLOOR_SIGNALID_MATRIX=1` asserts over all of them. `fullRecordings` asserts the
    /// same targets at the capture's own rate. The rows grow as the tasks that meet them land.
    @Test func heldOutTargets() throws {
        let held = try RealCorpus.points(.heldOut).filter { Self.heldOutTruths.contains($0.truth) }
        let points = Sweep.full ? held : Self.subset(held, perTruth: 2)
        let score = try RealCorpus.score(points: points) { clip, point in
            let id = RealCorpus.hover(clip, point)
            Self.expectHeldOut(id, point, "clip path")
            return id
        }
        Self.expectTargets(score, "clip path")
    }

    /// The truths `heldOutTargets` holds to their targets so far.
    static let heldOutTruths: Set<String> = ["none"]
    /// The share right each truth must reach.
    static let targets = ["none": 0.95]
    /// No answer on an empty point may be wider than this.
    static let widestEmptyAnswerHz = 100_000.0

    /// At most `perTruth` points of each truth, spread over its points in manifest order.
    static func subset(_ points: [CorpusPoint], perTruth: Int) -> [CorpusPoint] {
        Dictionary(grouping: points, by: \.truth).values.flatMap { group -> [CorpusPoint] in
            let step = max(1, group.count / perTruth)
            return stride(from: 0, to: group.count, by: step).prefix(perTruth).map { group[$0] }
        }
    }

    static func expectHeldOut(_ id: SignalIdentity, _ point: CorpusPoint, _ path: String) {
        if point.truth == "none" {
            #expect(id.measurement.occupiedBandwidthHz <= widestEmptyAnswerHz,
                    "\(path): empty point \(point.atHz) Hz: \(id.label)")
        }
    }

    static func expectTargets(_ score: [String: (right: Int, total: Int)], _ path: String) {
        for (truth, target) in targets {
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
    /// 30 minutes in a debug build).
    @Test(.enabled(if: environment["SUBFLOOR_SIGNALID_REAL"] == "1")) func fullRecordings() throws {
        let manifest = try RealCorpus.manifest()
        let allowed = Self.environment["SUBFLOOR_SIGNALID_REAL_POINTS"].flatMap(Int.init)
        var kept: [String: Int] = [:]
        let identify = { (clip: CorpusClip, point: CorpusPoint) -> SignalIdentity in
            guard let recording = manifest.recordings.first(where: { $0.clips.contains { $0.name == clip.name } }),
                  let entry = recording.clips.first(where: { $0.name == clip.name }) else {
                return SignalIdentity(measurement: SignalMeasurement(), note: "no recording")
            }
            let end = entry.startSeconds + point.endSeconds
            return RealCorpus.hover(rate: recording.captureRate, centerHz: recording.captureCenterHz, atHz: point.atHz,
                                    spectrumDb: clip.captureSpectrumDb) { seconds in
                (try? RealCorpus.readRecording(recording.file, seconds: max(0, end - seconds)..<end)) ?? []
            }
        }
        func trimmed(_ part: CorpusPart) throws -> [CorpusPoint] {
            try RealCorpus.points(part).filter { point in
                guard let allowed, point.truth != "none" else { return true }
                let key = "\(part) \(point.truth)"
                kept[key, default: 0] += 1
                return kept[key]! <= allowed
            }
        }
        for part in CorpusPart.allCases {
            let points = try trimmed(part)
            var answers: [String: [String: Int]] = [:]
            var wrong: [String] = []
            let score = try RealCorpus.score(points: points) { clip, point in
                let id = identify(clip, point)
                answers[point.truth, default: [:]][Self.shortLabel(id), default: 0] += 1
                if RealCorpus.isWrongName(id, point) {
                    wrong.append("\(point.truth) in \(point.clip) at \(point.atHz) Hz, \(point.endSeconds) s: \(id.label)")
                }
                if part == .heldOut { Self.expectHeldOut(id, point, "1 MS/s") }
                return id
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
            for line in wrong.prefix(20) { print("fullRecordings wrong: \(line)") }
            if part == .heldOut { Self.expectTargets(score, "1 MS/s") }
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
        if let best = id.best { return best.name }
        let m = id.measurement
        if m.occupiedBandwidthHz == 0 { return id.note ?? "none" }
        return "\(SignalIdentity.familyName(m)) · \(SignalIdentity.hz((m.occupiedBandwidthHz / 100).rounded() * 100))"
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
