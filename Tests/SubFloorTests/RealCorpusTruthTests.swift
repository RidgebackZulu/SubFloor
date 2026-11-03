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
