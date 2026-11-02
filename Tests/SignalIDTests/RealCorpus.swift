import Accelerate
import DSPCore
import Foundation
import Testing
@testable import SignalID

/// Which side of the tuning line a clip is on: thresholds are tuned on `tuning` only, and `heldOut` is only scored.
enum CorpusPart: String, Codable, CaseIterable { case tuning, heldOut }

/// A cut of one of the owner's recordings: `iq` is interleaved, in ±1, and sample 0 is at `startUTC`.
struct CorpusClip {
    let name: String
    let part: CorpusPart
    let iq: [Float]
    let rate: Double
    let centerHz: Double
    let startUTC: Date
    /// The whole capture's average spectrum (FFT-shifted, dB) over this clip's part of the recording.
    let captureSpectrumDb: [Float]
    let captureRate: Double
    let captureCenterHz: Double

    /// `captureSpectrumDb` cut to what the clip spans, as the app's spectrum would be if the capture were the clip.
    var spectrumDb: [Float] {
        let binHz = captureRate / Double(captureSpectrumDb.count)
        let half = Int((rate / 2 / binHz).rounded())
        let centre = captureSpectrumDb.count / 2 + Int(((centerHz - captureCenterHz) / binHz).rounded())
        return Array(captureSpectrumDb[(centre - half)..<(centre + half)])
    }
}

/// One identification: a point on the display at a time, with the app's normal read ending there.
struct CorpusPoint: Codable {
    let clip: String
    let atHz: Double
    /// Within the clip: where the read ends.
    let endSeconds: Double
    /// "FT8", "FT4", "2-FSK", "none", "comb", "not FSK".
    let truth: String
    /// What is known of it. The FSK: "shiftHz", "baud", "baudTolerance". FT8 and FT4 traces: "toneZeroHz", "onSeconds"
    /// (into the recording), and "slotSeconds" and "nearestDecodeHz" on FT8; "baud", "tones", "spacingHz" on FT4.
    let parameters: [String: Double]?
    /// How the truth is known.
    let how: String
    /// The signal is on throughout the window's last 3 s. Signal truths score only these windows.
    let transmitting: Bool
}

/// The real-signal corpus: clips of the owner's recordings, cut small enough for the repo, with a manifest of points
/// whose truth was worked out separately from the code under test (`how` says how). The score Signal ID answers to.
enum RealCorpus {
    struct Manifest: Codable {
        var recordings: [Recording]
        var points: [CorpusPoint]
    }

    /// One recording on the owner's Mac. Its name gives the first sample's time.
    struct Recording: Codable {
        let file: String
        /// Names the recording's saved spectra.
        let tag: String
        let captureRate: Double
        let captureCenterHz: Double
        let clipCenterHz: Double
        let clips: [ClipEntry]

        func spectrumFile(_ part: CorpusPart) -> String { "\(tag)-\(part.rawValue).bin" }

        /// The time span of one part, in seconds into the recording.
        func span(_ part: CorpusPart) -> Range<Double>? {
            let mine = clips.filter { $0.part == part }
            guard let start = mine.map(\.startSeconds).min(),
                  let end = mine.map({ $0.startSeconds + $0.seconds }).max() else { return nil }
            return start..<end
        }

        /// `SubFloor_YYYYMMDD_HHMMSSZ_…`.
        var startUTC: Date? {
            let parts = file.split(separator: "_")
            guard parts.count >= 3 else { return nil }
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.timeZone = TimeZone(identifier: "UTC")
            format.dateFormat = "yyyyMMdd HHmmss'Z'"
            return format.date(from: "\(parts[1]) \(parts[2])")
        }
    }

    struct ClipEntry: Codable {
        let name: String
        let part: CorpusPart
        let startSeconds: Double
        let seconds: Double
        var file: String { name + ".wav" }
    }

    enum CorpusError: Error { case missing(String), badWAV(String) }

    /// The folder the clips live in, in the source tree (the clip maker writes there).
    static var sourceFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Real")
    }

    static func resource(_ file: String) throws -> URL {
        let name = (file as NSString).deletingPathExtension, kind = (file as NSString).pathExtension
        guard let url = Bundle.module.url(forResource: name, withExtension: kind, subdirectory: "Fixtures/Real") else {
            throw CorpusError.missing(file)
        }
        return url
    }

    static func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: resource("manifest.json")))
    }

    private static let loaded: Result<[CorpusClip], Error> = Result {
        var out: [CorpusClip] = []
        for recording in try manifest().recordings {
            guard let start = recording.startUTC else { throw CorpusError.badWAV(recording.file) }
            for entry in recording.clips {
                let wav = try readWAV(resource(entry.file))
                let spectrum = try readSpectrum(resource(recording.spectrumFile(entry.part)))
                out.append(CorpusClip(name: entry.name, part: entry.part, iq: wav.iq, rate: wav.rate,
                                      centerHz: recording.clipCenterHz,
                                      startUTC: start.addingTimeInterval(entry.startSeconds),
                                      captureSpectrumDb: spectrum, captureRate: recording.captureRate,
                                      captureCenterHz: recording.captureCenterHz))
            }
        }
        return out
    }

    /// Every clip, read once and kept.
    static func clips() throws -> [CorpusClip] { try loaded.get() }

    /// The points of one part, or all of them.
    static func points(_ part: CorpusPart?) throws -> [CorpusPoint] {
        let m = try manifest()
        guard let part else { return m.points }
        let names = Set(m.recordings.flatMap(\.clips).filter { $0.part == part }.map(\.name))
        return m.points.filter { names.contains($0.clip) }
    }

    /// Runs `identify` (the hover's path: `hover(_:_:)`) on the points of `part` that count, and returns the share
    /// right per truth: a signal truth's windows count only while it is transmitting.
    static func score(_ part: CorpusPart?, identify: (CorpusClip, CorpusPoint) -> SignalIdentity) throws
        -> [String: (right: Int, total: Int)] {
        try score(points: points(part), identify: identify)
    }

    /// The same, over the given points that count.
    static func score(points: [CorpusPoint], identify: (CorpusClip, CorpusPoint) -> SignalIdentity) throws
        -> [String: (right: Int, total: Int)] {
        let clips = try clips()
        var out: [String: (right: Int, total: Int)] = [:]
        for point in points where counts(point) {
            guard let clip = clips.first(where: { $0.name == point.clip }) else { throw CorpusError.missing(point.clip) }
            let right = isRight(identify(clip, point), point)
            out[point.truth, default: (0, 0)].total += 1
            if right { out[point.truth, default: (0, 0)].right += 1 }
        }
        return out
    }

    /// Whether a point's window scores: empty points have nothing to transmit.
    static func counts(_ point: CorpusPoint) -> Bool { point.transmitting || point.truth == "none" }

    /// What each truth takes to be right.
    /// - A mode: named it. The first build's one row "FT8 / FT4" counts for either until the two are told apart.
    /// - "2-FSK": measured as 2-FSK with the point's shift and speed, and not given another mode's name.
    /// - "none": `No signal`. "comb": labelled a comb or `No signal`, never a mode. "not FSK": not called FSK.
    static func isRight(_ id: SignalIdentity, _ point: CorpusPoint) -> Bool {
        let m = id.measurement
        switch point.truth {
        case "none":
            return id.best == nil && id.note == SignalIdentifier.noSignalNote
        case "comb":
            return id.label.localizedCaseInsensitiveContains("comb")
                || (id.best == nil && id.note == SignalIdentifier.noSignalNote)
        case "not FSK":
            return m.family != .fsk
        case "2-FSK":
            guard m.family == .fsk, (m.toneCount ?? 2) == 2, id.best == nil || id.best?.name == "2-FSK" else { return false }
            let parameters = point.parameters ?? [:]
            guard let shift = m.fskShiftHz ?? m.toneSpacingHz, let rate = m.symbolRate,
                  let trueShift = parameters["shiftHz"], let trueRate = parameters["baud"] else { return false }
            return abs(shift - trueShift) <= 0.03 * trueShift
                && abs(rate - trueRate) <= (parameters["baudTolerance"] ?? 0.01) * trueRate
        default:
            return namesTruth(id.best?.name, point.truth)
        }
    }

    static func namesTruth(_ name: String?, _ truth: String) -> Bool {
        guard let name else { return false }
        return name.components(separatedBy: " / ").contains(truth) || name == truth
    }

    /// A name at 0.7 or more that the point's truth rules out: the worst outcome, whether or not the window counts.
    static func isWrongName(_ id: SignalIdentity, _ point: CorpusPoint) -> Bool {
        guard let best = id.best, best.confidence >= SignalIdentifier.nameThreshold else { return false }
        switch point.truth {
        case "none", "comb": return !best.name.localizedCaseInsensitiveContains("comb")
        case "not FSK": return best.name == "2-FSK" || ModeTable.row(best.name)?.families.contains(.fsk) == true
        case "2-FSK": return best.name != "2-FSK"
        default: return !namesTruth(best.name, point.truth)
        }
    }

    /// As the hover does (`SignalIDService.run`): the newest 3 s, with the app's spectrum; when that asks for it, up to
    /// 16 s cut to a channel around what it measured, and the answer from that with no spectrum. `read` gives the
    /// newest seconds ending at the point's time, as interleaved IQ at `rate`.
    static func hover(rate: Double, centerHz: Double, atHz: Double, spectrumDb: [Float],
                      read: (Double) -> [Float]) -> SignalIdentity {
        let first = SignalIdentifier.identify(iq: read(SignalIdentifier.firstSeconds), sampleRate: rate,
                                              captureCenterHz: centerHz, atHz: atHz, bandwidthHz: nil,
                                              spectrumDb: spectrumDb, longer: nil)
        guard first.needsLongerRead else { return first }
        let m = first.measurement
        let windowHz = max(48_000, 4 * m.occupiedBandwidthHz)
        let whole = read(SignalIdentifier.longSeconds)
        // At this rate a channel that wide doesn't decimate, and the app reads the capture itself.
        let decimates = !DecimationPlan.stages(inputRate: rate, minimumRate: max(4 * windowHz, Channel.minimumRate)).isEmpty
        var iq = whole, longRate = rate, offsetHz = 0.0
        if decimates {
            let long = Channel.extract(whole, sampleRate: rate, offsetHz: m.offsetHz, bandwidthHz: windowHz, sharp: false)
            iq = long.samples.withUnsafeBufferPointer { $0.withMemoryRebound(to: Float.self) { Array($0) } }
            longRate = long.rate
            offsetHz = m.offsetHz
        }
        let seconds = Double(iq.count / 2) / longRate
        var refined = SignalIdentifier.identify(iq: iq, sampleRate: longRate, captureCenterHz: centerHz + offsetHz,
                                                atHz: atHz, bandwidthHz: nil, spectrumDb: nil, longer: { (iq, seconds) })
        refined.measurement.offsetHz += offsetHz
        return refined
    }

    /// `hover` on a clip, at a point's time.
    static func hover(_ clip: CorpusClip, _ point: CorpusPoint) -> SignalIdentity {
        hover(rate: clip.rate, centerHz: clip.centerHz, atHz: point.atHz, spectrumDb: clip.spectrumDb) { seconds in
            let end = 2 * Int((point.endSeconds * clip.rate).rounded())
            let start = max(0, end - 2 * Int((seconds * clip.rate).rounded()))
            return Array(clip.iq[start..<min(end, clip.iq.count)])
        }
    }

    // MARK: Files

    /// A 16-bit stereo (I, Q) WAV, as interleaved Floats in ±1.
    static func readWAV(_ url: URL) throws -> (iq: [Float], rate: Double) {
        let data = try Data(contentsOf: url)
        guard let chunk = dataChunk(data.prefix(4096)), chunk.format.channels == 2, chunk.format.bits == 16 else {
            throw CorpusError.badWAV(url.lastPathComponent)
        }
        let end = min(data.count, chunk.offset + chunk.size)
        return (floats(data[chunk.offset..<end]), chunk.format.rate)
    }

    /// Little-endian 16-bit samples as Floats in ±1, by vDSP: the clips load in a default test run.
    static func floats(_ data: Data) -> [Float] {
        let count = data.count / 2
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            guard let base = samples.baseAddress else { return }
            vDSP_vflt16(base, 1, &out, 1, vDSP_Length(count))
        }
        var scale: Float = 32768
        vDSP_vsdiv(out, 1, &scale, &out, 1, vDSP_Length(count))
        return out
    }

    /// Where a WAV's `data` chunk lies, and its format. Doesn't assume the data starts at 44.
    static func dataChunk(_ header: Data) -> (offset: Int, size: Int, format: (rate: Double, channels: Int, bits: Int))? {
        let data = Data(header)
        func u32(_ at: Int) -> Int { Int(UInt32(littleEndian: data[at..<(at + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })) }
        func u16(_ at: Int) -> Int { Int(UInt16(littleEndian: data[at..<(at + 2)].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })) }
        var at = 12
        var format: (rate: Double, channels: Int, bits: Int)?
        while at + 8 <= data.count {
            let id = String(decoding: data[at..<(at + 4)], as: UTF8.self), size = u32(at + 4)
            if id == "fmt ", at + 24 <= data.count {
                format = (Double(u32(at + 12)), u16(at + 10), u16(at + 22))
            } else if id == "data", let format {
                return (at + 8, size, format)
            }
            at += 8 + size + size % 2
        }
        return nil
    }

    static func writeWAV(_ iq: [Float], rate: Double, to url: URL) throws {
        var out = Data(capacity: 44 + 2 * iq.count)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { out.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { out.append(contentsOf: $0) } }
        let bytes = 2 * iq.count
        out.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); out.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(2); u32(Int(rate)); u32(Int(rate) * 4); u16(4); u16(16)
        out.append(contentsOf: Array("data".utf8)); u32(bytes)
        let ints = iq.map { Int16(max(-32768, min(32767, ($0 * 32768).rounded()))).littleEndian }
        ints.withUnsafeBytes { out.append(contentsOf: $0) }
        try out.write(to: url)
    }

    static func readSpectrum(_ url: URL) throws -> [Float] {
        try Data(contentsOf: url).withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
    }

    /// Frames `range` (seconds) of a full recording on the owner's Mac, as interleaved Floats in ±1.
    static func readRecording(_ file: String, seconds range: Range<Double>) throws -> [Float] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/SubFloor/\(file)")
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let chunk = dataChunk(try handle.read(upToCount: 4096) ?? Data()) else { throw CorpusError.badWAV(file) }
        let frames = chunk.size / 4
        let first = max(0, Int((range.lowerBound * chunk.format.rate).rounded()))
        let last = min(frames, Int((range.upperBound * chunk.format.rate).rounded()))
        guard first < last else { return [] }
        try handle.seek(toOffset: UInt64(chunk.offset + 4 * first))
        let data = try handle.read(upToCount: 4 * (last - first)) ?? Data()
        return floats(data)
    }
}
