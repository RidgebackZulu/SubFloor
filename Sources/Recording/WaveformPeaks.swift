import Accelerate
import AVFoundation
import Foundation
import Synchronization

/// The loudness outline of a recording, one byte per 10 ms: what the Recordings window draws as a waveform and
/// what it finds a click's position in. Reading 1.5 hours of audio takes a while, so it is done off the main
/// actor, a second of audio at a time (never the whole file in memory), and a cache beside the recordings log
/// lets the next look at the same file skip it.
public struct WaveformPeaks: Equatable, Sendable {
    public static let binsPerSecond = 100          // 10 ms bins: a 0.1 s jump spans 10 bins
    public let sampleRate: Double
    public let frames: Int
    public let peaks: [UInt8]                       // max |sample| per bin, 255 = full scale

    public var duration: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }

    /// The cached peaks for `audioFile` if the cache matches its size and modification date, else
    /// computed (and the cache written). Throws for an unreadable file; throws CancellationError
    /// promptly (checked every second of audio) when the calling task is cancelled.
    public static func load(audioFile: URL, cacheFolder: URL) async throws -> WaveformPeaks {
        try await load(audioFile: audioFile, cacheFolder: cacheFolder, worker: { _ in })
    }

    /// What the worker thread reports to a test: that it began, and that it finished, however it finished.
    enum WorkerEvent: Sendable { case started, exited }

    /// `load`, with `worker` called on the worker thread as it begins and as it finishes: a test times how
    /// soon a cancel stops the reading by them.
    ///
    /// The reading is blocking file work, so it runs on a thread of its own rather than on the cooperative
    /// pool, where a busy pool (a full test run, other work in the app) can leave it, and the cancel, waiting
    /// for a thread. A cancel sets a flag the reading checks every second of audio; it then stops and resumes
    /// the caller at once, without needing a pool thread for the work.
    static func load(audioFile: URL, cacheFolder: URL,
                     worker report: @escaping @Sendable (WorkerEvent) -> Void) async throws -> WaveformPeaks {
        let cancelled = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let worker = Thread {
                    report(.started)
                    let result = Result { try loadSynchronously(audioFile: audioFile, cacheFolder: cacheFolder, cancelled: cancelled) }
                    report(.exited)
                    continuation.resume(with: result)
                }
                worker.name = "WaveformPeaks"
                worker.qualityOfService = .userInitiated
                worker.start()
            }
        } onCancel: {
            cancelled.set()   // also called at once, before the body, when the caller is already cancelled
        }
    }

    /// Set once by the caller's cancellation, read by the worker.
    final class CancelFlag: Sendable {
        private let value = Atomic(false)
        func set() { value.store(true, ordering: .relaxed) }
        func check() throws { if value.load(ordering: .relaxed) { throw CancellationError() } }
    }

    // MARK: Loading

    private static func loadSynchronously(audioFile: URL, cacheFolder: URL, cancelled: CancelFlag) throws -> WaveformPeaks {
        try cancelled.check()
        let source = try SourceStamp(audioFile)         // taken before reading: a file that changes meanwhile fails the next match
        let cacheFile = cacheFolder.appendingPathComponent(audioFile.lastPathComponent + ".peaks")
        if let cached = readCache(cacheFile, matching: source) { return cached }
        let peaks = try compute(audioFile, cancelled: cancelled)
        try cancelled.check()
        writeCache(peaks, to: cacheFile, folder: cacheFolder, source: source)   // a speed-up only: failing to write is not failing to load
        return peaks
    }

    /// Frames of audio read per pass, as seconds: also how often cancellation is noticed.
    private static let chunkSeconds = 1.0

    private static func compute(_ audioFile: URL, cancelled: CancelFlag) throws -> WaveformPeaks {
        let file = try AVAudioFile(forReading: audioFile)
        let format = file.processingFormat
        let rate = format.sampleRate
        guard rate > 0, format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * chunkSeconds))
        else { throw CocoaError(.fileReadCorruptFile) }
        var peaks = [UInt8](repeating: 0, count: binCount(frames: Int(file.length), rate: rate))
        var frame = 0
        while file.framePosition < file.length {      // read(into:) throws, rather than returning nothing, once it is at the end
            try cancelled.check()
            try file.read(into: buffer)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let samples = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }   // the first channel
            var done = 0
            while done < n {
                let bin = Int(Double(frame + done) * Double(binsPerSecond) / rate)
                let end = min(n, max(done + 1, binStart(bin + 1, rate: rate) - frame))   // the rest of this bin that this chunk holds
                var peak: Float = 0
                vDSP_maxmgv(samples + done, 1, &peak, vDSP_Length(end - done))
                if bin >= peaks.count { peaks.append(contentsOf: repeatElement(0, count: bin + 1 - peaks.count)) }   // a file longer than it said
                peaks[bin] = max(peaks[bin], UInt8(min(255, (peak * 255).rounded())))
                done = end
            }
            frame += n
        }
        peaks.removeLast(max(0, peaks.count - binCount(frames: frame, rate: rate)))                                 // a file shorter than it said
        return WaveformPeaks(sampleRate: rate, frames: frame, peaks: peaks)
    }

    private static func binCount(frames: Int, rate: Double) -> Int {
        Int((Double(frames) * Double(binsPerSecond) / rate).rounded(.up))
    }

    /// The first frame of bin `bin`.
    private static func binStart(_ bin: Int, rate: Double) -> Int {
        Int((Double(bin) * rate / Double(binsPerSecond)).rounded(.up))
    }

    // MARK: Cache
    //
    // "SFPK", version 1 (UInt32), the source's size (UInt64) and modification time (Float64, seconds since
    // 1970), then the sample rate (Float64) and frames (Int64); the peaks follow. All little-endian.

    private static let magic = Data("SFPK".utf8)
    private static let version: UInt32 = 1
    private static let headerSize = 40
    /// The sample rates a cache entry can hold: anything audio is, with room to spare.
    private static let rateRange: ClosedRange<Double> = 1...10_000_000

    /// What a cache entry must have been made from: the source file's size and modification date.
    private struct SourceStamp {
        let size: UInt64
        let modified: Double

        init(_ url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        }
    }

    private static func readCache(_ cacheFile: URL, matching source: SourceStamp) -> WaveformPeaks? {
        guard let data = try? Data(contentsOf: cacheFile), data.count >= headerSize, data.prefix(4) == magic else { return nil }
        func field<T: FixedWidthInteger>(_ offset: Int, as: T.Type) -> T {
            T(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) })
        }
        let rate = Double(bitPattern: field(24, as: UInt64.self))
        let storedFrames = field(32, as: Int64.self)
        // A damaged or hand-made header must not trap: the rate is checked against real audio rates, and the
        // bin count is worked out in `Double`, before anything is made an `Int`.
        guard field(4, as: UInt32.self) == version, field(8, as: UInt64.self) == source.size,
              Double(bitPattern: field(16, as: UInt64.self)) == source.modified,
              rate.isFinite, rateRange.contains(rate), storedFrames >= 0,
              (Double(storedFrames) * Double(binsPerSecond) / rate).rounded(.up) == Double(data.count - headerSize),
              let frames = Int(exactly: storedFrames)
        else { return nil }
        return WaveformPeaks(sampleRate: rate, frames: frames, peaks: [UInt8](data.dropFirst(headerSize)))
    }

    private static func writeCache(_ peaks: WaveformPeaks, to cacheFile: URL, folder: URL, source: SourceStamp) {
        var data = magic
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append(version); append(source.size); append(source.modified.bitPattern)
        append(peaks.sampleRate.bitPattern); append(Int64(peaks.frames))
        data.append(contentsOf: peaks.peaks)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: cacheFile, options: .atomic)
    }
}
