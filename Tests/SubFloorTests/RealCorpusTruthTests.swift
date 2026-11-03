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
            struct Clip: Decodable { let name: String; let startSeconds: Double; let seconds: Double }
            let tag: String
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
        var known: [SignalIDDecoding.BoxRead] = []
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
                                                      known: known, chunks: read, barrier: barrier, cancelled: { false })
            else { continue }
            if let box = made.box {
                known.removeAll { $0.dialHz == box.dialHz }
                known.append(box)
            }
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
              + "none there), \(known.count) slot decodes, \(wrong.count) wrong")
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
