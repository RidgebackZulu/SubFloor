@preconcurrency import AVFoundation
import Foundation

/// One WAV-encoded slice of a recording, ready to upload.
public struct PreparedChunk: Equatable, Sendable {
    /// Where this slice starts in the recording, in seconds.
    public var offsetSeconds: Double
    /// Length of the slice in seconds.
    public var seconds: Double
    /// 16 kHz mono 16-bit PCM WAV, header included.
    public var wav: Data

    public init(offsetSeconds: Double, seconds: Double, wav: Data) {
        self.offsetSeconds = offsetSeconds
        self.seconds = seconds
        self.wav = wav
    }
}

/// What a recording turns into before it is sent for transcription.
public enum PreparedAudio: Equatable, Sendable {
    /// Every sample is exactly zero: nothing to send.
    case silent
    /// Shorter than `TranscriptionAudio.minSendSeconds`: not worth a request.
    case tooShort(seconds: Double)
    /// One or more WAV chunks of at most `TranscriptionAudio.maxChunkSeconds`, in order.
    case chunks([PreparedChunk])
}

/// Downsamples recordings to 16 kHz mono, cuts them into chunks at quiet points and WAV-encodes each one.
public enum TranscriptionAudio {
    public static let sampleRate = 16_000.0
    /// Longest chunk sent in one request.
    public static let maxChunkSeconds = 120.0
    /// A cut is searched for in this much audio before the chunk limit.
    public static let cutSearchSeconds = 15.0
    /// Cuts fall at the start of a window this long.
    public static let cutWindowSeconds = 0.1
    /// Anything shorter is reported as noise instead of being sent.
    public static let minSendSeconds = 0.5

    /// Reads `url` (any format `AVAudioFile` opens), converts it to 16 kHz mono and prepares it.
    public static func prepare(url: URL) throws -> PreparedAudio {
        prepare(samples: try samples16k(url: url))
    }

    /// Prepares samples that are already 16 kHz mono.
    ///
    /// Checks in order: all zero → `.silent`; under `minSendSeconds` → `.tooShort`; otherwise chunks.
    /// Each cut is the start of the quietest 100 ms window (first one on ties) in the last 15 s before the
    /// 120 s limit; the next chunk starts there, and whatever is left once it fits in 120 s is the last chunk.
    public static func prepare(samples: [Float]) -> PreparedAudio {
        if !samples.contains(where: { $0 != 0 }) { return .silent }
        let rate = Int(sampleRate)
        if Double(samples.count) / sampleRate < minSendSeconds {
            return .tooShort(seconds: Double(samples.count) / sampleRate)
        }
        let limit = Int(maxChunkSeconds) * rate
        var starts = [0]
        while samples.count - starts.last! > limit {
            starts.append(starts.last! + cutPoint(samples, from: starts.last!, limit: limit))
        }
        let ends = starts.dropFirst() + [samples.count]
        return .chunks(zip(starts, ends).map { start, end in
            PreparedChunk(offsetSeconds: Double(start) / sampleRate, seconds: Double(end - start) / sampleRate,
                          wav: wav(samples[start..<end]))
        })
    }

    /// Offset, relative to `from`, of the quietest `cutWindowSeconds` window starting in
    /// `[limit − cutSearchSeconds, limit)`. Strict `<` keeps the first on ties.
    private static func cutPoint(_ samples: [Float], from: Int, limit: Int) -> Int {
        let window = Int((cutWindowSeconds * sampleRate).rounded())
        let first = limit - Int(cutSearchSeconds * sampleRate)
        var best = first, bestEnergy = Double.infinity
        var offset = first
        while offset < limit {
            var energy = 0.0
            for i in (from + offset)..<(from + offset + window) { energy += Double(samples[i]) * Double(samples[i]) }
            if energy < bestEnergy { bestEnergy = energy; best = offset }
            offset += window
        }
        return best
    }

    /// A 44-byte RIFF header plus 16-bit little-endian mono PCM at 16 kHz. Samples are clamped to ±1.
    public static func wav(_ samples: ArraySlice<Float>) -> Data {
        let dataBytes = samples.count * 2
        var d = Data(capacity: 44 + dataBytes)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(1); u32(Int(sampleRate)); u32(Int(sampleRate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        var body = [Int16](); body.reserveCapacity(samples.count)
        for s in samples { body.append(Int16((max(-1, min(1, s)) * 32_767).rounded())) }
        for v in body { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        return d
    }

    /// Streams the file through an `AVAudioConverter` to 16 kHz mono Float32.
    private static func samples16k(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target)
        else { throw AudioPrepError.unsupportedFormat }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        let inFrames: AVAudioFrameCount = 65_536
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inFrames),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 32_768)
        else { throw AudioPrepError.unsupportedFormat }

        var result = [Float]()
        result.reserveCapacity(Int(Double(file.length) * sampleRate / file.processingFormat.sampleRate) + 1)
        /// The converter calls its input block synchronously; this carries a read failure out of it.
        final class ReadFailure: @unchecked Sendable { var error: Error? }
        let failure = ReadFailure()
        while true {
            var convertError: NSError?
            let status = converter.convert(to: output, error: &convertError) { _, status in
                // `read` throws at end of file, so ask only for the frames that remain.
                let remaining = file.length - file.framePosition
                guard remaining > 0 else { status.pointee = .endOfStream; return nil }
                do {
                    try file.read(into: input, frameCount: AVAudioFrameCount(min(Int64(inFrames), remaining)))
                } catch {
                    failure.error = error; status.pointee = .endOfStream; return nil
                }
                status.pointee = .haveData
                return input
            }
            if let error = failure.error { throw error }
            if status == .error { throw convertError ?? AudioPrepError.conversionFailed }
            if output.frameLength > 0, let p = output.floatChannelData?[0] {
                result.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(output.frameLength)))
            }
            if status == .endOfStream { break }
        }
        return result
    }
}

/// Why a recording could not be read for transcription.
public enum AudioPrepError: Error, Equatable, Sendable {
    case unsupportedFormat
    case conversionFailed
}
