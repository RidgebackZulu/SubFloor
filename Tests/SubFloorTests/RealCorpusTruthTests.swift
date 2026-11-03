import Accelerate
import DSPCore
import Foundation
import Modems
import Recording
import SignalID
import Synchronization
import Testing
@testable import SubFloor

/// The FT8 truth in the real-signal corpus (`Tests/SignalIDTests/Fixtures/Real`), from SubFloor's own decoder, kept
/// apart from the code it scores: each clip is SSB-demodulated around the FT8 group and its 15 s slots decoded. A
/// decode's message passed the LDPC and CRC, so it proves FT8, and its frequency says where the trace is.
///
/// It takes about 30 CPU-seconds in a debug build, and the truth only changes with the manifest, so it runs only with
/// `SUBFLOOR_SIGNALID_REAL=1`. So does `fskTrialDecode`, Signal ID's trial decode on the real 2-FSK.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SUBFLOOR_SIGNALID_REAL"] == "1"))
struct RealCorpusTruthTests {
    /// Dial for the demodulation: the display reads low, and this puts the group (14.0731–14.0762 MHz) at
    /// about 1100–4200 Hz of audio.
    static let dialHz = 14_072_000.0
    static let audioBand = 200.0...5000.0
    /// The channel demodulated: 0…6 kHz of audio.
    static let channelHz = 6000.0
    /// The file's first sample is 18:18:44Z; slots start at 18:18:45, 18:19:00 and 18:19:15.
    static let slots = [1.0, 16.0, 31.0]

    struct Manifest: Decodable {
        struct Recording: Decodable {
            struct Clip: Decodable { let name: String; let part: String; let startSeconds: Double; let seconds: Double }
            let file: String
            let tag: String
            let captureRate: Double
            let captureCenterHz: Double
            let clipCenterHz: Double
            let clips: [Clip]
        }
        struct Point: Decodable {
            let clip: String
            let atHz: Double
            let endSeconds: Double
            let truth: String
            let parameters: [String: Double]?
            let how: String
            let transmitting: Bool
        }
        let recordings: [Recording]
        let points: [Point]
    }

    static var folder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SignalIDTests/Fixtures/Real")
    }

    static func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
    }

    /// The clips' IQ for `range` of the recording, across clip boundaries. The clips are 62.5 kS/s with 44-byte headers.
    static func iq(_ clips: [Manifest.Recording.Clip], seconds range: Range<Double>, rate: Double) throws -> [Float] {
        var out: [Float] = []
        for clip in clips.sorted(by: { $0.startSeconds < $1.startSeconds }) {
            let from = max(range.lowerBound, clip.startSeconds), to = min(range.upperBound, clip.startSeconds + clip.seconds)
            guard from < to else { continue }
            let data = try Data(contentsOf: folder.appendingPathComponent(clip.name + ".wav"))
            let first = 44 + 4 * Int(((from - clip.startSeconds) * rate).rounded())
            let last = min(data.count, 44 + 4 * Int(((to - clip.startSeconds) * rate).rounded()))
            data[first..<last].withUnsafeBytes { raw in
                out.append(contentsOf: raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 })
            }
        }
        return out
    }

    /// USB audio on `dialHz`.
    static func audio(_ iq: [Float], rate: Double, clipCenterHz: Double) -> (samples: [Float], rate: Double) {
        let channel = Channel.extract(iq, sampleRate: rate, offsetHz: dialHz + channelHz / 2 - clipCenterHz,
                                      bandwidthHz: channelHz)
        var nco = NCO(frequency: channelHz / 2, sampleRate: channel.rate)
        var z = channel.samples
        z.withUnsafeMutableBufferPointer { nco.mix($0) }
        return (z.map(\.real), channel.rate)
    }

    @Test func ft8TruthDecodes() throws {
        let manifest = try Self.manifest()
        let recording = try #require(manifest.recordings.first { $0.tag == "14MHz" })
        let start = try #require(ISO8601DateFormatter().date(from: "2026-11-01T18:18:44Z"))
        var decoded: [(slot: Double, rfHz: Double, message: String)] = []
        for slot in Self.slots {
            let iq = try Self.iq(recording.clips, seconds: slot..<(slot + 15), rate: 62_500)
            let audio = Self.audio(iq, rate: 62_500, clipCenterHz: recording.clipCenterHz)
            let decodes = FT8Modem.decode(samples: audio.samples, sampleRate: audio.rate,
                                          slotStart: start.addingTimeInterval(slot), audioBand: Self.audioBand)
            for d in decodes {
                let rfHz = Self.dialHz + d.frequencyHz
                decoded.append((slot, rfHz, d.message))
                print(String(format: "ft8TruthDecodes: slot t=%.0f tone0 %.1f Hz dt %+.2f snr %.0f [radio text] %@",
                             slot, rfHz, d.timeOffset, d.snrDb, d.message))
            }
            print("ft8TruthDecodes: slot t=\(slot): \(decodes.count) decodes from \(Double(iq.count / 2) / 62_500) s")
        }
        #expect(!decoded.isEmpty)
        // Every trace the manifest calls decoded was: the corpus's FT8 truth stands on SubFloor's decoder.
        let claimed = manifest.points.filter { $0.truth == "FT8" && $0.how.hasPrefix("decoded") }
        #expect(!claimed.isEmpty)
        for point in claimed {
            let toneZero = try #require(point.parameters?["toneZeroHz"]), slot = try #require(point.parameters?["slotSeconds"])
            #expect(decoded.contains { $0.slot == slot && abs($0.rfHz - toneZero) < 3 && point.how.contains($0.message) },
                    "no decode in slot \(slot) at \(toneZero) Hz")
        }
    }

    /// The card's trial decode on the real FT8 points: each decoded point's trace read as the card reads it (the newest 3 s,
    /// and the 16 s longer read, from the recording at its time) and its trial made on the ring up to then (28 s at
    /// most). A message names a trace only when that trace was on the air in its slot: no trace may get a message of the
    /// slot of the other parity (stations keep theirs), and a point's own trace named in its own slot must have its own
    /// message. Prints how many were confirmed.
    @Test func ft8TrialAttribution() throws {
        let manifest = try Self.manifest()
        let recording = try #require(manifest.recordings.first { $0.tag == "14MHz" })
        let rate = 62_500.0, centre = recording.clipCenterHz
        let start = try #require(ISO8601DateFormatter().date(from: "2026-11-01T18:18:44Z"))
        let length = recording.clips.map { $0.startSeconds + $0.seconds }.max() ?? 0
        let all = try Self.iq(recording.clips, seconds: 0..<length, rate: rate)
        let points = manifest.points.filter { $0.truth == "FT8" && $0.how.hasPrefix("decoded") }
        let barrier = TuneBarrier()
        barrier.end(centerHz: centre)
        // The boxes read and the slots decoded, carried from point to point as the service does; and how many times
        // the decoder ran.
        var known: [SignalIDDecoding.BoxRead] = [], slots: [SignalIDDecoding.SlotDecodes] = []
        let runs = Mutex(0)
        var decoders = SignalIDDecoding.Decoders.standard
        let standard = decoders.ft8
        decoders.ft8 = { audio, slot in runs.withLock { $0 += 1 }; return standard(audio, slot) }
        var tried = 0, confirmed = 0, members = 0, right = 0, unverified = 0
        var wrong: [String] = []
        for point in points {
            guard let clip = recording.clips.first(where: { $0.name == point.clip }),
                  let pointSlot = point.parameters?["slotSeconds"] else { continue }
            let t = clip.startSeconds + point.endSeconds
            let endFrame = Int((t * rate).rounded())
            let iq = Array(all.prefix(2 * endFrame))
            func newest(_ seconds: Double) -> [Float] { Array(iq.suffix(2 * Int((seconds * rate).rounded()))) }
            let endTime = start.addingTimeInterval(t)
            // The card's read: the newest 3 s, then (asked for) the 16 s longer read.
            var identity = SignalIdentifier.identify(iq: newest(3), sampleRate: rate, captureCenterHz: centre, atHz: point.atHz,
                                                     bandwidthHz: nil, spectrumDb: nil, longer: nil, pointRadiusHz: 60,
                                                     endTime: endTime)
            if identity.needsLongerRead {
                let long = newest(16), seconds = Double(long.count / 2) / rate
                identity = SignalIdentifier.identify(iq: long, sampleRate: rate, captureCenterHz: centre, atHz: point.atHz,
                                                     bandwidthHz: nil, spectrumDb: nil, longer: { (long, seconds) },
                                                     pointRadiusHz: 60, endTime: endTime)
            }
            guard let plan = SignalIDDecoding.plan(for: identity, centerHz: centre) else { continue }
            let read: SignalIDService.ChunkProvider = { lastSeconds, chunkFrames, visit in
                let frames = min(iq.count / 2, Int((lastSeconds * rate).rounded()))
                let tail = iq.suffix(2 * frames)
                var at = tail.startIndex
                while at < tail.endIndex {
                    let to = min(at + 2 * max(1, chunkFrames), tail.endIndex)
                    guard tail[at..<to].withUnsafeBufferPointer(visit) else { return nil }
                    at = to
                }
                return IQRead(frames: frames, sampleRate: rate, endTime: endTime)
            }
            tried += 1
            guard let made = SignalIDDecoding.attempt(for: identity, plan: plan, state: barrier.current, trueTime: true,
                                                      known: known, slots: slots, chunks: read, barrier: barrier,
                                                      decoders: decoders, cancelled: { false })
            else { continue }
            if let box = made.box {
                known.removeAll { $0.dialHz == box.dialHz }
                known.append(box)
            }
            if let slot = made.slot { slots = SignalIDDecoding.keeping(slots, slot) }
            let named = SignalIDDecoding.applied(made, to: identity, centerHz: centre)
            guard let decodedSlot = made.slotStart?.timeIntervalSince(start) else { continue }
            // Slots 15 s apart alternate parity.
            func otherParity(_ a: Double, _ b: Double) -> Bool { Int(((a - b) / 15).rounded()) % 2 != 0 }
            // Every trace named (the point's own, and any under it): against the decoded points on it.
            let traces: [SignalIdentity] = [named] + named.signals
            for trace in traces where trace.decodedText != nil {
                guard let text = trace.decodedText else { continue }
                let isOwn = trace.measurement.offsetHz == named.measurement.offsetHz
                if !isOwn { members += 1 } else if trace == named { confirmed += 1 } else { continue }
                let hz = centre + trace.measurement.offsetHz
                let reach = max(trace.measurement.occupiedBandwidthHz, trace.measurement.bandwidth6dBHz) / 2 + 6.25
                let there = points.filter { p -> Bool in
                    let toneZero: Double = p.parameters?["toneZeroHz"] ?? 0
                    return abs(toneZero + 21.875 - hz) <= reach
                }
                let sameSlot = there.filter { $0.parameters?["slotSeconds"] == decodedSlot }
                let label = String(format: "%.1f Hz at %.1f s (slot %.0f decoded)", hz, t, decodedSlot)
                if sameSlot.contains(where: { $0.how.contains("\"\(text)\"") }) {
                    right += 1
                } else if !sameSlot.isEmpty {
                    wrong.append("\(label): another station's message")
                } else if !there.isEmpty, there.allSatisfy({ otherParity(decodedSlot, $0.parameters?["slotSeconds"] ?? 0) }) {
                    wrong.append("\(label): its stations are on the other parity")
                } else {
                    unverified += 1
                }
            }
        }
        print("ft8TrialAttribution: \(points.count) decoded points, \(tried) tried: \(confirmed) points' own traces and "
              + "\(members) members named by a decode (\(right) checked against a decoded point on them, \(unverified) with "
              + "none there), \(runs.withLock { $0 }) decoder runs over \(known.count) boxes, \(wrong.count) wrong")
        for line in wrong { print("ft8TrialAttribution wrong: \(line)") }
        #expect(wrong.isEmpty)
    }

    /// The trial decode on the real 2-FSK at 11.688 MHz (75 Bd, 850 Hz): what the RTTY decoder prints from it, at the
    /// keying measured, and how it reads. It must never be named RTTY unless that reads; so far it doesn't (no text
    /// kept, still `2-FSK`). Prints the decoder's output over the whole recording, and the trial's at two times, the
    /// way the card makes it (the newest 10 s before then).
    @Test func fskTrialDecode() throws {
        let manifest = try Self.manifest()
        let recording = try #require(manifest.recordings.first { $0.tag == "11.7MHz" })
        let rate = 62_500.0
        let start = try #require(ISO8601DateFormatter().date(from: "2026-11-01T18:41:42Z"))
        let all = try Self.iq(recording.clips, seconds: 0..<24, rate: rate)
        let centreHz = (11_687_797.0 + 11_688_646.0) / 2
        // The whole recording through the decoder at 75 Bd and 850 Hz.
        let whole = SignalIDDecoding.demodulate(all, sampleRate: rate,
                                                dialOffsetHz: centreHz - SignalIDDecoding.streamAudioHz - recording.clipCenterHz)
        let raw = SignalIDDecoding.Decoders.standard.stream(.rtty(baud: 75, shiftHz: 850), whole)
        let text = SignalIDDecoding.clean(raw)
        print(String(format: "fskTrialDecode: whole recording, 75 Bd 850 Hz: %d characters, score %.2f [radio text] %@",
                     text.count, Double(ReadableText.score(text)), text))
        for end in [12.0, 24.0] {
            let iq = Array(all.prefix(2 * Int(end * rate)))
            let read: SignalIDService.ChunkProvider = { lastSeconds, chunkFrames, visit in
                let frames = min(iq.count / 2, Int((lastSeconds * rate).rounded()))
                let newest = iq.suffix(2 * frames)
                var at = newest.startIndex
                while at < newest.endIndex {
                    let to = min(at + 2 * max(1, chunkFrames), newest.endIndex)
                    guard newest[at..<to].withUnsafeBufferPointer(visit) else { return nil }
                    at = to
                }
                return IQRead(frames: frames, sampleRate: rate, endTime: start.addingTimeInterval(end))
            }
            let first = SignalIdentifier.identify(iq: Array(iq.suffix(2 * Int(3 * rate))), sampleRate: rate,
                                                  captureCenterHz: recording.clipCenterHz, atHz: 11_688_646,
                                                  bandwidthHz: nil, spectrumDb: nil, longer: nil)
            let barrier = TuneBarrier()
            barrier.end(centerHz: recording.clipCenterHz)
            let texts = Mutex<[(SignalIDDecoding.Stream, String)]>([])
            var decoders = SignalIDDecoding.Decoders.standard
            decoders.stream = { stream, audio in
                let out = SignalIDDecoding.Decoders.standard.stream(stream, audio)
                texts.withLock { $0.append((stream, SignalIDDecoding.clean(out))) }
                return out
            }
            let plan = try #require(SignalIDDecoding.plan(for: first, centerHz: recording.clipCenterHz), "\(first.label)")
            let made = try #require(SignalIDDecoding.attempt(for: first, plan: plan, state: barrier.current, trueTime: true,
                                                             known: [], chunks: read, barrier: barrier, decoders: decoders,
                                                             cancelled: { false }))
            let named = SignalIDDecoding.applied(made, to: first, centerHz: recording.clipCenterHz)
            for (stream, said) in texts.withLock({ $0 }) {
                print(String(format: "fskTrialDecode: at %.0f s, %@: score %.2f [radio text] %@", end, "\(stream)",
                             Double(ReadableText.score(said)), said))
            }
            print("fskTrialDecode: at \(end) s: \(first.label) → \(named.label)")
            #expect(named.best?.name != "RTTY" || named.decodedText != nil)
            #expect(named.decodedText == nil, "the real 2-FSK read as text: \(named.decodedText ?? "")")
            #expect(named == first && named.label.hasPrefix("2-FSK · 75 Bd · "), "\(named.label)")
        }
    }
}

// MARK: The card with its trial decode

/// The card's row of the scorecard (`RealCorpusTests.printScorecard`): every FT8 point of the corpus as the owner's card
/// makes it, on the recordings themselves at their 1 MS/s, through the service's own read (`SignalIDService.run`: the
/// newest 3 s, then the 16 s longer read) and its trial decode (`SignalIDDecoding.attempt`, the ring read as the app's
/// default IQ pre-roll plans it), the points taken in the order of their time with the boxes and slots kept from one to
/// the next as the service keeps them. Its first answer is the hover's; the card must name FT8 at least as often, never a
/// wrong name, and never give a trace another station's message. `SUBFLOOR_SIGNALID_CARD_ROWS=<path>` writes its rows
/// there for the scorecard.
extension RealCorpusTruthTests {
    /// One of the owner's recordings on disk, read as the ring would hand it over at a moment of it.
    struct RecordingRing: Sendable {
        let url: URL
        let dataOffset: Int
        let frames: Int
        let rate: Double
        let start: Date
        /// The most the ring holds, in frames.
        let capacity: Int

        init(file: String, rate: Double, start: Date, capacity: Int) throws {
            url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/SubFloor/\(file)")
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let head = try handle.read(upToCount: 4096) ?? Data()
            var at = 12, found: (Int, Int)?
            func u32(_ k: Int) -> Int { Int(head[k..<(k + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian) }
            while at + 8 <= head.count {
                let id = String(decoding: head[at..<(at + 4)], as: UTF8.self), size = u32(at + 4)
                if id == "data" { found = (at + 8, size); break }
                at += 8 + size + size % 2
            }
            guard let (offset, size) = found else { throw CocoaError(.fileReadCorruptFile) }
            dataOffset = offset
            frames = size / 4
            self.rate = rate
            self.start = start
            self.capacity = capacity
        }

        /// Frames `range` as interleaved Floats in ±1.
        func read(_ range: Range<Int>, from handle: FileHandle) throws -> [Float] {
            try handle.seek(toOffset: UInt64(dataOffset + 4 * range.lowerBound))
            let data = try handle.read(upToCount: 4 * range.count) ?? Data()
            var out = [Float](repeating: 0, count: data.count / 2)
            data.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return }
                vDSP_vflt16(base, 1, &out, 1, vDSP_Length(out.count))
            }
            var scale: Float = 32768
            vDSP_vsdiv(out, 1, &scale, &out, 1, vDSP_Length(out.count))
            return out
        }

        /// The newest frames up to `lastSeconds` when the ring ends at `endFrame`, as far back as it holds.
        func span(_ lastSeconds: Double, endFrame: Int) -> Range<Int> {
            let oldest = max(0, endFrame - capacity)
            return max(oldest, endFrame - Int((lastSeconds * rate).rounded()))..<endFrame
        }

        func endTime(_ endFrame: Int) -> Date { start.addingTimeInterval(Double(endFrame) / rate) }

        func snapshots(endFrame: Int) -> SignalIDService.SnapshotProvider {
            { lastSeconds in
                let range = span(lastSeconds, endFrame: endFrame)
                guard !range.isEmpty, let handle = try? FileHandle(forReadingFrom: url),
                      let samples = try? read(range, from: handle) else { return nil }
                try? handle.close()
                return IQSnapshot(samples: samples, sampleRate: rate, endTime: endTime(endFrame), endFrame: endFrame)
            }
        }

        func chunks(endFrame: Int) -> SignalIDService.ChunkProvider {
            { lastSeconds, chunkFrames, visit in
                let range = span(lastSeconds, endFrame: endFrame)
                guard !range.isEmpty, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
                defer { try? handle.close() }
                var at = range.lowerBound
                while at < range.upperBound {
                    let to = min(range.upperBound, at + max(1, chunkFrames))
                    guard let piece = try? read(at..<to, from: handle),
                          piece.withUnsafeBufferPointer(visit) else { return nil }
                    at = to
                }
                return IQRead(frames: range.count, sampleRate: rate, endTime: endTime(endFrame), endFrame: endFrame)
            }
        }
    }

    /// A scorecard row, as `RealCorpusTests.ScoreRow` reads it.
    struct CardRow: Codable {
        var path: String
        var part: String
        var truth = "FT8"
        var windows = 0
        var right = 0
        var wrong = 0
        var others: [String: Int] = [:]
    }

    /// What a card answer is called, for the tally of the windows not named FT8: as `RealCorpusTests.shortLabel` puts it
    /// (the family and the width to 100 Hz).
    static func shortLabel(_ id: SignalIdentity) -> String {
        if id.comb != nil { return "Interference comb" }
        if let best = id.best { return best.name }
        let m = id.measurement
        if m.occupiedBandwidthHz == 0 { return id.note ?? "none" }
        let width = (m.occupiedBandwidthHz / 100).rounded() * 100
        let hz = width < 1000 ? "\(Int(width)) Hz" : String(format: "%.1f kHz", width / 1000)
        return "\(SignalIdentity.familyName(m)) · \(hz)"
    }

    /// How long the service takes to give its first answer on the recordings (meant for a release build): from the
    /// request to `onFirst` (or to the answer, when there is no longer read), the ring read from the recording as the ring
    /// would hand it over, through `SignalIDService.run`. Cold: the capture's comb found from the app's spectrum first, as
    /// on the first hover after a tune; warm: the comb known, as for the next 5 s. 4 held-out points of each truth, at
    /// the default radius and FT8's at the owner's zoom too. Prints each kind's median and slowest; asserts nothing, and
    /// takes minutes, so it also wants `SUBFLOOR_SIGNALID_TIMING=1`, as `RealCorpusTests.releaseTimings` does.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SUBFLOOR_SIGNALID_TIMING"] == "1"))
    func serviceFirstAnswerTiming() throws {
        let manifest = try Self.manifest()
        let finder: SignalIDService.CombFinder = { CaptureComb.find(spectrumDb: $0, sampleRate: $1, centerHz: $2) }
        var lines: [String] = []
        for recording in manifest.recordings {
            let start = try #require(Self.startUTC(recording.file))
            let rate = recording.captureRate, centre = recording.captureCenterHz
            let ring = try RecordingRing(file: recording.file, rate: rate, start: start, capacity: Int(40 * rate))
            let data = try Data(contentsOf: Self.folder.appendingPathComponent("\(recording.tag)-heldOut.bin"))
            let spectrum = SpectrumSnapshot(centerHz: centre, spanHz: rate,
                                            average: data.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) })
            let clips = Dictionary(uniqueKeysWithValues: recording.clips.filter { $0.part == "heldOut" }.map { ($0.name, $0) })
            let held = manifest.points.filter { clips[$0.clip] != nil && ($0.transmitting || $0.truth == "none") }
            let barrier = TuneBarrier()
            barrier.end(centerHz: centre)
            for (truth, radius) in [("FT8", nil), ("FT8", 345.0), ("FT4", nil), ("2-FSK", nil), ("comb", nil), ("none", nil)] as [(String, Double?)] {
                let mine = held.filter { $0.truth == truth }
                guard !mine.isEmpty else { continue }
                let picks = stride(from: 0, to: mine.count, by: max(1, mine.count / 4)).prefix(4).map { mine[$0] }
                var cold: [Double] = [], warm: [Double] = []
                for point in picks {
                    let endFrame = Int(((clips[point.clip]!.startSeconds + point.endSeconds) * rate).rounded())
                    var known: SignalIDService.KnownComb?
                    for pass in 0..<2 {
                        let request = SignalIDService.Request(atHz: point.atHz, bandwidthHz: nil, radiusHz: radius, spectrum: spectrum,
                                                              longer: true, modelCenterHz: centre, trueTime: true, comb: known)
                        let began = ContinuousClock.now
                        let firstAt = Mutex<ContinuousClock.Instant?>(nil)
                        let outcome = SignalIDService.run(request, provider: ring.snapshots(endFrame: endFrame),
                                                          chunks: ring.chunks(endFrame: endFrame), analysis: SignalIDService.identifier,
                                                          combFinder: finder, barrier: barrier,
                                                          onFirst: { _, _ in firstAt.withLock { $0 = ContinuousClock.now } })
                        let done = ContinuousClock.now
                        let elapsed = (firstAt.withLock { $0 } ?? done) - began
                        let msTaken = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
                        if pass == 0 { cold.append(msTaken) } else { warm.append(msTaken) }
                        known = outcome?.comb ?? SignalIDService.KnownComb(state: barrier.current,
                                                                           reading: .init(comb: finder(spectrum.average, rate, centre)))
                    }
                }
                cold.sort(); warm.sort()
                let line = String(format: "serviceFirstAnswerTiming %@ %@ r %@: cold median %.0f ms, slowest %.0f ms; warm median %.0f ms, slowest %.0f ms",
                                  recording.tag, truth, radius.map { "\(Int($0)) Hz" } ?? "default", cold[cold.count / 2], cold.last!,
                                  warm[warm.count / 2], warm.last!)
                lines.append(line)
                print(line)
            }
        }
        #expect(!lines.isEmpty)
    }

    /// `SubFloor_YYYYMMDD_HHMMSSZ_…`: the first sample's time.
    static func startUTC(_ file: String) -> Date? {
        let parts = file.split(separator: "_")
        guard parts.count >= 3 else { return nil }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyyMMdd HHmmss'Z'"
        return format.date(from: "\(parts[1]) \(parts[2])")
    }

    @Test func cardWithDecode() throws {
        let manifest = try Self.manifest()
        let recording = try #require(manifest.recordings.first { $0.tag == "14MHz" })
        // The recording's start, from its file name (as `serviceFirstAnswerTiming` takes it).
        let start = try #require(Self.startUTC(recording.file))
        let rate = recording.captureRate, centre = recording.captureCenterHz
        // The app's IQ ring at its defaults (`RecordingSettings`: 30 s of pre-roll, int16 IQ, 2 GiB at most).
        let defaults = RecordingSettings()
        let plan = StreamRecorder.plan(sampleRate: rate, bytesPerFrame: 4, preRollSeconds: defaults.preRollSeconds,
                                       memoryLimitBytes: defaults.iqMemoryLimitBytes)
        let ring = try RecordingRing(file: recording.file, rate: rate, start: start, capacity: plan.capacityBytes / 4)
        func spectrum(_ part: String) throws -> SpectrumSnapshot {
            let data = try Data(contentsOf: Self.folder.appendingPathComponent("\(recording.tag)-\(part).bin"))
            let db = data.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
            return SpectrumSnapshot(centerHz: centre, spanHz: rate, average: db)
        }
        let spectra = try ["tuning": spectrum("tuning"), "heldOut": spectrum("heldOut")]
        let clips = Dictionary(uniqueKeysWithValues: recording.clips.map { ($0.name, $0) })
        let ft8 = manifest.points.filter { $0.truth == "FT8" && clips[$0.clip] != nil }
        let decodedPoints = ft8.filter { $0.how.hasPrefix("decoded") }
        func time(_ p: Manifest.Point) -> Double { clips[p.clip]!.startSeconds + p.endSeconds }
        let ordered = ft8.sorted { time($0) < time($1) }
        let barrier = TuneBarrier()
        barrier.end(centerHz: centre)
        let runs = Mutex(0)
        var decoders = SignalIDDecoding.Decoders.standard
        let standard = decoders.ft8
        decoders.ft8 = { audio, slot in runs.withLock { $0 += 1 }; return standard(audio, slot) }
        var boxes: [SignalIDDecoding.BoxRead] = [], slots: [SignalIDDecoding.SlotDecodes] = []
        var first: [String: CardRow] = [:], card: [String: CardRow] = [:]
        var wrongNames: [String] = [], otherMessages: [String] = []
        var own = 0, members = 0, checked = 0, unverified = 0
        for point in ordered {
            let part = clips[point.clip]!.part
            let t = time(point), endFrame = Int((t * rate).rounded())
            let request = SignalIDService.Request(atHz: point.atHz, bandwidthHz: nil, spectrum: spectra[part], longer: true,
                                                  modelCenterHz: centre, trueTime: true)
            let chunks = ring.chunks(endFrame: endFrame)
            let finder: SignalIDService.CombFinder = { CaptureComb.find(spectrumDb: $0, sampleRate: $1, centerHz: $2) }
            guard let outcome = SignalIDService.run(request, provider: ring.snapshots(endFrame: endFrame), chunks: chunks,
                                                    analysis: SignalIDService.identifier, combFinder: finder,
                                                    barrier: barrier) else {
                Issue.record("no answer at \(point.atHz) Hz, \(time(point)) s")
                continue
            }
            let hover = outcome.identity
            var named = hover
            var made: SignalIDDecoding.Attempt?
            if let trial = SignalIDDecoding.plan(for: hover, centerHz: centre) {
                made = SignalIDDecoding.attempt(for: hover, plan: trial, state: barrier.current, trueTime: true,
                                                known: boxes, slots: slots, chunks: chunks, barrier: barrier,
                                                decoders: decoders, cancelled: { false })
            }
            if let made {
                // Kept as the service keeps them.
                if let box = made.box {
                    boxes.removeAll {
                        $0.dialHz == box.dialHz || box.map.readEndUTC - $0.map.readEndUTC > SignalIDDecoding.boxReuseSeconds
                    }
                    boxes.append(box)
                }
                if let slot = made.slot { slots = SignalIDDecoding.keeping(slots, slot) }
                named = SignalIDDecoding.applied(made, to: hover, centerHz: centre)
            }
            let label = String(format: "%.1f Hz at %.1f s", point.atHz, t)
            // No name the truth rules out, on the point's answer or any signal under it (FT8's frequencies hold FT8 alone).
            for answer in [named] + named.signals {
                if let best = answer.best, best.confidence >= SignalIdentifier.nameThreshold, best.name != "FT8" {
                    wrongNames.append("\(label): \(best.name) in \(named.label)")
                }
            }
            // Each message against the decoded points on its trace in its slot (as `ft8TrialAttribution` checks them).
            if let made, let decodedSlot = made.slotStart?.timeIntervalSince(start) {
                for trace in [named] + named.signals {
                    guard let text = trace.decodedText else { continue }
                    if trace.measurement.offsetHz == named.measurement.offsetHz { own += 1 } else { members += 1 }
                    let hz = centre + trace.measurement.offsetHz
                    let reach = max(trace.measurement.occupiedBandwidthHz, trace.measurement.bandwidth6dBHz) / 2 + 6.25
                    let sameSlot = decodedPoints.filter { p in
                        abs((p.parameters?["toneZeroHz"] ?? 0) + 21.875 - hz) <= reach && p.parameters?["slotSeconds"] == decodedSlot
                    }
                    if sameSlot.contains(where: { $0.how.contains("\"\(text)\"") }) {
                        checked += 1
                    } else if !sameSlot.isEmpty {
                        otherMessages.append(String(format: "%@: %.1f Hz, slot %.0f", label, hz, decodedSlot))
                    } else {
                        unverified += 1
                    }
                }
            }
            func count(_ rows: inout [String: CardRow], _ id: SignalIdentity, _ path: String) {
                var row = rows[part] ?? CardRow(path: path, part: part)
                if point.transmitting {
                    row.windows += 1
                    if id.best?.name == "FT8" { row.right += 1 } else { row.others[Self.shortLabel(id), default: 0] += 1 }
                }
                if ([id] + id.signals).contains(where: {
                    ($0.best?.confidence ?? 0) >= SignalIdentifier.nameThreshold && $0.best?.name != "FT8"
                }) { row.wrong += 1 }
                rows[part] = row
            }
            count(&first, hover, "Card's first answer (service, before its decode), 1 MS/s")
            count(&card, named, "Card with its trial decode, 1 MS/s")
        }
        for part in ["tuning", "heldOut"] {
            for row in [first[part], card[part]].compactMap({ $0 }) {
                print(String(format: "cardWithDecode %@ %@: %d/%d named FT8 (%.0f%%), %d wrong names; others %@", part,
                             row.path, row.right, row.windows, 100 * Double(row.right) / Double(max(1, row.windows)),
                             row.wrong, "\(row.others.sorted { $0.value > $1.value })"))
            }
            #expect((card[part]?.right ?? 0) >= (first[part]?.right ?? 0), "\(part): the card names FT8 less than the hover")
        }
        print("cardWithDecode: ring \(plan.capacityBytes / 4) frames (\(Double(plan.capacityBytes / 4) / rate) s); "
              + "\(ordered.count) FT8 points, \(runs.withLock { $0 }) decoder runs over \(boxes.count) boxes kept; messages on "
              + "\(own) points' own traces and \(members) members: \(checked) checked against a decoded point, \(unverified) "
              + "with none there, \(otherMessages.count) another station's")
        for line in wrongNames { print("cardWithDecode wrong name: \(line)") }
        for line in otherMessages { print("cardWithDecode another station's message: \(line)") }
        #expect(wrongNames.isEmpty)
        #expect(otherMessages.isEmpty)
        if let path = ProcessInfo.processInfo.environment["SUBFLOOR_SIGNALID_CARD_ROWS"] {
            let rows = ["tuning", "heldOut"].flatMap { [first[$0], card[$0]].compactMap { $0 } }
            try JSONEncoder().encode(rows).write(to: URL(fileURLWithPath: path))
        }
    }
}
